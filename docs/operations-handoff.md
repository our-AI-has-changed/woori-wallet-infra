# Woori Wallet Infra 인수인계서

## 목적

이 문서는 `woori-wallet-infra` Terraform 저장소를 기준으로 현재 AWS 인프라 구조, 운영 명령, 비용 절감을 위한 전체 종료/재기동 절차, 주요 주의사항을 정리합니다.

## 현재 구조

서비스는 `platform`, `woori`, `wallet` 세 스택으로 나뉩니다.

```text
Client / Mobile App
  -> wallet 전용 API Gateway
  -> shared API Gateway VPC Link
  -> wallet internal NLB
  -> wallet Kubernetes Service
  -> wallet Pod

Client / Mobile App
  -> woori 전용 API Gateway
  -> shared API Gateway VPC Link
  -> woori internal NLB
  -> woori Kubernetes Service
  -> woori Pod
```

`platform` 스택은 공통 인프라를 소유합니다.

```text
VPC
Public Subnets
Private Subnets
Internet Gateway
NAT Gateway
EKS Cluster
EKS Node Group
API Gateway VPC Link
VPC Link Security Group
```

`wallet`, `woori` 스택은 각 서비스별 리소스를 소유합니다.

```text
Kubernetes Namespace
Kubernetes Deployment
Kubernetes Service type=LoadBalancer
Internal NLB
Service API Gateway
API Gateway $default Stage
API Gateway $default Route
API Gateway VPC Link Integration
Optional custom domain
```

## 현재 엔드포인트

현재 API Gateway 기본 엔드포인트는 아래와 같습니다.

```text
wallet docs:
https://hd1h9ei9yd.execute-api.ap-northeast-2.amazonaws.com/docs

woori docs:
https://uz3e54qye8.execute-api.ap-northeast-2.amazonaws.com/docs
```

주의: `platform`까지 destroy 후 다시 apply하면 API Gateway ID가 새로 발급되므로 위 URL은 바뀝니다. 고정 URL이 필요하면 Route53 custom domain을 붙여야 합니다.

## State

Terraform remote state는 S3 backend를 사용합니다.

```text
bucket: woori-wallet-tfstate-655700895912-apne2

keys:
prd/platform/terraform.tfstate
prd/woori/terraform.tfstate
prd/wallet/terraform.tfstate
```

`bootstrap/state` 스택은 state bucket을 관리합니다. 비용 절감을 위해 전체 인프라를 내릴 때도 `bootstrap/state`는 유지하는 것을 권장합니다.

## 기본 운영 명령

루트에서 `SERVICE_MODE` 또는 `STACK_MODE`를 지정해 실행합니다.

```sh
make init SERVICE_MODE=platform
make plan SERVICE_MODE=platform
make apply SERVICE_MODE=platform

make init SERVICE_MODE=woori
make plan SERVICE_MODE=woori
make apply SERVICE_MODE=woori

make init SERVICE_MODE=wallet
make plan SERVICE_MODE=wallet
make apply SERVICE_MODE=wallet
```

출력 확인:

```sh
make output SERVICE_MODE=wallet
make output SERVICE_MODE=woori
make output SERVICE_MODE=platform
```

전체 포맷:

```sh
make fmt
```

## 비용 절감용 전체 종료 절차

비용을 가장 강하게 줄이려면 `wallet`, `woori`, `platform`을 모두 destroy합니다. 단, `bootstrap/state`는 유지합니다.

반드시 서비스 스택을 먼저 내리고 마지막에 `platform`을 내립니다.

```sh
make destroy-all
```

Makefile 내부 순서는 아래와 같습니다.

```sh
make destroy SERVICE_MODE=wallet
make destroy SERVICE_MODE=woori
make destroy SERVICE_MODE=platform
```

직접 Terraform으로 실행할 경우:

```sh
terraform -chdir=services/wallet destroy
terraform -chdir=services/woori destroy
terraform -chdir=services/platform destroy
```

순서가 중요한 이유:

```text
wallet/woori는 EKS cluster, VPC Link, internal NLB에 의존합니다.
platform은 EKS cluster, VPC, NAT Gateway, VPC Link를 소유합니다.
platform을 먼저 지우면 Kubernetes provider가 cluster에 접근하지 못해 서비스 destroy가 꼬일 수 있습니다.
```

Destroy 전에 계획만 확인하려면:

```sh
terraform -chdir=services/wallet plan -destroy
terraform -chdir=services/woori plan -destroy
terraform -chdir=services/platform plan -destroy
```

현재 확인된 destroy plan 기준:

```text
services/wallet: 7개 destroy 예정
services/woori: 7개 destroy 예정
services/platform: 24개 destroy 예정
```

## 재기동 절차

다시 올릴 때는 `platform`을 먼저 만들고, 서비스 스택을 그 다음에 올립니다.

```sh
make apply SERVICE_MODE=platform
make apply SERVICE_MODE=woori
make apply SERVICE_MODE=wallet
```

권장 확인:

```sh
make output SERVICE_MODE=wallet
make output SERVICE_MODE=woori

curl -i "$(terraform -chdir=services/wallet output -raw docs_url)"
curl -i "$(terraform -chdir=services/woori output -raw docs_url)"
```

## 비용 관련 결정사항

현재 기본값은 비용 절감을 위해 아래 구성을 유지합니다.

```text
EKS node group: min 1 / desired 1 / max 1
service replicas: 1
NAT Gateway: 1개
```

이 구성은 저렴하지만 고가용성 구성은 아닙니다. 노드 1대, pod 1개, NAT 1개 중 하나가 장애 나면 서비스 영향이 있을 수 있습니다.

운영 안정성이 더 중요해지면 아래 값을 2 이상으로 조정합니다.

```hcl
# services/platform/terraform.tfvars
node_min_size     = 2
node_desired_size = 2
node_max_size     = 2

# services/wallet/terraform.tfvars 또는 services/woori/terraform.tfvars
replicas = 2
```

NAT Gateway를 AZ별로 늘리면 가용성은 좋아지지만 시간당 비용도 증가합니다.

## 보안 옵션

EKS API endpoint:

```hcl
cluster_endpoint_private_access      = true
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
```

현재는 lockout 방지를 위해 public CIDR 기본값이 열려 있습니다. 운영 환경에서는 관리자 고정 IP 또는 VPN CIDR로 좁히는 것을 권장합니다.

예:

```hcl
cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
```

API Gateway throttling:

```hcl
api_throttling_burst_limit = 100
api_throttling_rate_limit  = 50
```

JWT authorizer는 옵션입니다. 아래 값을 넣으면 API Gateway 레벨 JWT authorizer가 켜집니다.

```hcl
jwt_issuer   = "https://issuer.example.com"
jwt_audience = ["wallet-api"]
```

현재는 backend 인증과 분리되어 있으므로 issuer/audience가 확정되기 전까지 기본값은 비활성화입니다.

## NLB Target Type

현재 기본값은 `instance`입니다.

```hcl
load_balancer_target_type = "instance"
```

이 방식은 아래 흐름으로 동작합니다.

```text
NLB
  -> NodePort
  -> kube-proxy
  -> Pod
```

`ip` target type으로 바꾸면 NLB가 pod IP로 직접 붙는 구조가 될 수 있지만, AWS Load Balancer Controller 구성이 준비된 뒤에 켜는 것을 권장합니다.

```hcl
load_balancer_target_type = "ip"
```

## Custom Domain

Route53 hosted zone이 있으면 서비스별 서브도메인을 붙일 수 있습니다.

```hcl
# services/wallet/terraform.tfvars
custom_domain_name = "wallet-api.example.com"
route53_zone_name  = "example.com"

# services/woori/terraform.tfvars
custom_domain_name = "woori-api.example.com"
route53_zone_name  = "example.com"
```

이 값을 넣으면 서비스 스택에서 아래 리소스를 관리합니다.

```text
ACM certificate
ACM DNS validation record
API Gateway custom domain
API Gateway API mapping
Route53 A alias record
```

현재 AWS 계정에는 Route53 hosted zone이 확인되지 않았습니다. 도메인을 Route53에서 등록하거나 외부 도메인을 Route53 hosted zone으로 연결한 뒤 사용합니다.

## 자주 발생할 수 있는 문제

`platform`을 먼저 destroy한 경우:

```text
wallet/woori destroy가 Kubernetes cluster에 접근하지 못해 실패할 수 있습니다.
```

이 경우 platform을 다시 apply해 cluster 접근을 복구한 뒤 서비스 destroy를 다시 시도합니다.

NLB가 바로 삭제되지 않는 경우:

```text
Kubernetes Service 삭제 후 AWS NLB가 정리되는 데 시간이 걸릴 수 있습니다.
```

서비스 destroy 완료 후 platform destroy를 진행하는 것이 안전합니다.

새로 apply한 뒤 endpoint가 바뀌는 경우:

```text
API Gateway ID, NLB hostname, EKS endpoint는 재생성 시 바뀔 수 있습니다.
```

고정 주소가 필요하면 custom domain을 사용합니다.

## 현재 커밋/작업 상태 참고

현재 구조는 서비스별 API Gateway로 분리되어 있으며, 기존 shared API Gateway는 제거되었습니다. 이후 보안 옵션과 비용 절감 운영 절차가 추가되었습니다.
