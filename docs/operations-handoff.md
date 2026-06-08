# Woori Wallet Infra 인수인계서

이 문서는 `woori-wallet-infra` 저장소를 기준으로 현재 AWS/EKS 인프라 구조, GitOps CD 흐름, 모니터링, DB, 운영 명령, 비용 절감용 종료/재기동 절차를 정리합니다.

## 1. 현재 결론

현재 구조는 다음 원칙으로 정리되어 있습니다.

```text
Terraform은 AWS 인프라와 public edge만 관리한다.
Kubernetes 앱/DB/모니터링은 Argo CD + Helm + manifest로 관리한다.
앱 배포 기준은 ECR image가 아니라 infra repo main 브랜치의 manifest다.
비용 절감을 위해 RDS와 AWS Managed Prometheus/Grafana는 쓰지 않는다.
Grafana 외부 공개는 선택 사항이며 기본 apply-all에서는 만들지 않는다.
```

중요한 기본값:

```text
Region: ap-northeast-2
AWS account: 655700895912
EKS node group: t3.small, min 2 / desired 2 / max 2
NAT Gateway: 1개
app replicas: 1
DB: EKS 내부 MySQL StatefulSet 2개, 각 PVC 5Gi
Prometheus retention: 3d
Prometheus PVC: disabled
Grafana persistence: disabled
```

## 2. 저장소 구조

```text
bootstrap/state
  Terraform remote state S3 bucket bootstrap

infra/platform
  VPC, subnets, NAT Gateway, EKS, managed node group, EBS CSI driver,
  API Gateway VPC Link, shared internal ALB

infra/edge-woori
  woori-backend public API Gateway, ALB listener rule, target group,
  EKS node ASG target group attachment, optional custom domain

infra/edge-wallet
  wallet-backend public API Gateway, ALB listener rule, target group,
  EKS node ASG target group attachment, optional custom domain

infra/edge-monitoring
  Grafana public API Gateway, WAF IP allowlist, ALB listener rule,
  target group, optional custom domain

modules/service-edge
  edge-woori, edge-wallet, edge-monitoring이 공유하는 Terraform module

apps
  Argo CD가 sync하는 app, DB, namespace, StorageClass manifest

addons/argocd
  Argo CD Helm values

addons/monitoring
  kube-prometheus-stack values, dashboard, alert rule, ServiceMonitor

argocd/applications
  Argo CD Application manifest
```

## 3. 전체 아키텍처

서비스별 public API Gateway가 있고, EKS 앞에는 shared internal ALB 1개가 있습니다.

```text
Client / Mobile App
  -> wallet HTTP API Gateway
  -> API Gateway VPC Link
  -> shared internal ALB
  -> Host: wallet.internal listener rule
  -> wallet target group
  -> EKS node NodePort 30080
  -> wallet/wallet-backend Service
  -> wallet-backend Pod

Client / Mobile App
  -> woori HTTP API Gateway
  -> API Gateway VPC Link
  -> shared internal ALB
  -> Host: woori.internal listener rule
  -> woori target group
  -> EKS node NodePort 30081
  -> woori/woori-backend Service
  -> woori-backend Pod

Admin / VPN IP
  -> monitoring HTTP API Gateway
  -> AWS WAF IP allowlist
  -> API Gateway VPC Link
  -> shared internal ALB
  -> Host: grafana.internal listener rule
  -> Grafana target group
  -> EKS node NodePort 30082
  -> monitoring/kube-prometheus-stack-grafana Service
  -> Grafana Pod
```

Terraform edge 스택은 Kubernetes Service를 만들지 않습니다. `apps/` manifest가 NodePort Service를 만들고, Terraform target group이 그 NodePort를 바라봅니다.

서비스별 계약:

| 서비스 | Terraform stack | Kubernetes namespace/service | NodePort | Health check | 내부 Host |
| --- | --- | --- | --- | --- | --- |
| woori-backend | `edge-woori` | `woori/woori-backend` | `30081` | `/api/health` | `woori.internal` |
| wallet-backend | `edge-wallet` | `wallet/wallet-backend` | `30080` | `/api/health` | `wallet.internal` |
| Grafana | `edge-monitoring` | `monitoring/kube-prometheus-stack-grafana` | `30082` | `/api/health` | `grafana.internal` |

API Gateway는 `$default` route를 사용합니다. `/docs`로 들어오면 path rewrite 없이 backend의 `/docs`로 전달됩니다.

## 4. Terraform state

`bootstrap/state`만 local backend로 시작하고, 나머지 스택은 S3 backend를 사용합니다.

```text
bucket: woori-wallet-tfstate-655700895912-apne2

prd/platform/terraform.tfstate
prd/edge-woori/terraform.tfstate
prd/edge-wallet/terraform.tfstate
prd/edge-monitoring/terraform.tfstate
```

주의:

```text
state bucket은 비용이 거의 작고, 전체 destroy 후 재기동을 위해 유지하는 것을 권장합니다.
기존 prd/wallet 또는 prd/woori state에 리소스가 남아 있으면 새 key로 바로 apply하지 않습니다.
그 경우 Terraform이 빈 state로 보고 중복 생성할 수 있으므로 state migrate/import가 먼저 필요합니다.
현재 구조는 destroy 후 새 책임 분리로 전환하는 기준입니다.
```

## 5. Secret과 SSM Parameter

비밀값은 Git에 저장하지 않습니다. 원본은 SSM Parameter Store SecureString입니다.

필수 SSM Parameter:

```text
/woori-wallet/prod/metrics-token
/woori-wallet/prod/woori-db-password
/woori-wallet/prod/woori-db-root-password
/woori-wallet/prod/wallet-db-password
/woori-wallet/prod/wallet-db-root-password
```

Makefile이 SSM 값을 읽어서 Kubernetes Secret을 생성합니다.

```sh
make metrics-secret
make db-secret
make monitoring-secret
make secrets-apply
```

생성되는 Secret:

```text
wallet/metrics-token: METRICS_TOKEN
woori/metrics-token: METRICS_TOKEN
monitoring/metrics-token: METRICS_TOKEN

monitoring/grafana-admin: admin-user, admin-password

woori/woori-db-credentials:
  MYSQL_PASSWORD
  MYSQL_ROOT_PASSWORD
  WOORI_DATABASE_URL

wallet/wallet-db-credentials:
  MYSQL_PASSWORD
  MYSQL_ROOT_PASSWORD
  WALLET_DATABASE_URL

wallet/woori-db-credentials:
  WOORI_DATABASE_URL
```

Secret은 Argo CD가 관리하지 않습니다. 운영 중 Secret이 지워지면 아래 명령으로 다시 복구합니다.

```sh
make secrets-apply
```

Grafana admin password:

```sh
GRAFANA_ADMIN_PASSWORD='change-me-locally' make monitoring-secret
```

기존 Secret을 강제로 회전하려면:

```sh
FORCE_GRAFANA_ADMIN_PASSWORD=yes GRAFANA_ADMIN_PASSWORD='new-password' make monitoring-secret
```

## 6. DB 구조

DB는 비용 절감을 위해 RDS가 아니라 EKS 내부 MySQL pod로 올립니다. MSA 책임 분리를 위해 DB는 서비스별로 분리합니다.

```text
woori-backend
  -> woori-db.woori.svc.cluster.local:3306
  -> database: woori_auth

wallet-backend
  -> wallet-db.wallet.svc.cluster.local:3306
  -> database: wallet_trial

wallet-backend
  -> woori-db.woori.svc.cluster.local:3306
  -> database: woori_auth
```

리소스:

```text
apps/storage/storageclass-gp3.yaml
apps/woori-db/service.yaml
apps/woori-db/statefulset.yaml
apps/wallet-db/service.yaml
apps/wallet-db/statefulset.yaml
```

DB 특징:

```text
MySQL image: mysql:8.4.9-oraclelinux9
StatefulSet replicas: 1
PVC: 5Gi each
StorageClass: woori-wallet-gp3
EBS CSI driver: platform Terraform stack에서 EKS add-on으로 설치
EBS CSI permission: node role 전체가 아니라 IRSA role에 부여
StorageClass reclaimPolicy: Delete
```

주의:

```text
PVC를 삭제하면 EBS volume도 삭제됩니다.
CONFIRM_DATA_DELETE=yes make destroy-all은 DB 데이터를 삭제합니다.
SSM 비밀번호를 바꿔도 기존 PVC의 MySQL 사용자 비밀번호가 자동 변경되지는 않습니다.
운영 DB로 쓰려면 snapshot/backup/restore 절차가 별도로 필요합니다.
```

## 7. GitOps CD 흐름

운영 배포 기준은 infra repo입니다.

```text
infra repo: our-AI-has-changed/woori-wallet-infra
target branch: main
Argo CD app path: apps/
ECR prefix: 655700895912.dkr.ecr.ap-northeast-2.amazonaws.com/our-ai-has-changed
```

배포 흐름:

```text
1. 앱 repo에 코드 push
2. GitHub Actions 테스트/빌드
3. Docker image를 ECR에 ${GITHUB_SHA} tag로 push
4. GitHub Actions가 infra repo의 apps/{service}/deployment.yaml image tag 업데이트
5. infra repo main에 commit
6. Argo CD가 infra repo main 변경 감지
7. EKS에 sync
8. pod가 새 ECR image로 rolling update
```

서비스별 manifest:

```text
wallet-backend -> apps/wallet-backend/deployment.yaml
woori-backend  -> apps/woori-backend/deployment.yaml
wallet-ai      -> apps/wallet-ai/deployment.yaml
mock-mydata    -> apps/mock-mydata/deployment.yaml
```

중요:

```text
ECR에 image만 push해도 배포되지 않습니다.
Argo CD는 ECR이 아니라 infra repo main 브랜치를 봅니다.
infra repo image tag commit이 CD 트리거입니다.
latest tag는 운영 기준으로 권장하지 않습니다.
rollback은 infra repo의 이전 image tag commit으로 되돌립니다.
앱 repo GitHub Actions는 INFRA_REPO_TOKEN secret으로 infra repo에 commit합니다.
INFRA_REPO_TOKEN은 가능하면 infra repo contents: read/write 최소 권한으로 둡니다.
```

## 8. Argo CD

Argo CD는 EKS 생성 후 Helm으로 설치합니다.

```text
chart: argo/argo-cd
chart version: 7.8.27
namespace: argocd
values: addons/argocd/values.yaml
```

명령:

```sh
make argocd-install
make addons-apply
```

Application:

```text
woori-wallet-apps
  source: https://github.com/our-AI-has-changed/woori-wallet-infra.git
  targetRevision: main
  path: apps
  syncPolicy: automated prune/selfHeal

woori-wallet-monitoring
  source 1: prometheus-community/kube-prometheus-stack Helm chart 70.3.0
  source 2: infra repo values reference
  source 3: addons/monitoring manifest
  syncPolicy: automated prune/selfHeal
```

Argo CD server는 기본 `ClusterIP`입니다. 외부 공개하지 않습니다.

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

## 9. 모니터링

AWS Managed Prometheus/Grafana를 쓰지 않고 EKS 내부 `kube-prometheus-stack`을 사용합니다. 이유는 비용 절감입니다.

```text
chart: prometheus-community/kube-prometheus-stack
chart version: 70.3.0
namespace: monitoring
values: addons/monitoring/values.yaml
```

기본 설정:

```text
Prometheus retention: 3d
Prometheus PVC: disabled
Grafana service: NodePort 30082
Grafana persistence: disabled
Alertmanager: ClusterIP, 외부 비공개
Prometheus: ClusterIP, 외부 비공개
```

관측 범위:

```text
EKS node Ready 상태
node CPU / memory / disk 사용량
pod Running / Pending / Failed / CrashLoopBackOff 상태
pod restart count
deployment desired replicas / available replicas
service endpoint 존재 여부
namespace별 CPU / memory 사용량
wallet / woori namespace 리소스 사용량
wallet-backend /metrics 앱 내부 지표
woori-backend /metrics 앱 내부 지표
```

Dashboard:

```text
addons/monitoring/dashboards/wallet-woori-overview.yaml
```

Alert rule:

```text
addons/monitoring/alerts/prometheus-rules.yaml
```

주요 alert 조건:

```text
wallet-backend pod가 2분 이상 없음
woori-backend pod가 2분 이상 없음
pod restart count가 10분 내 증가
node NotReady
deployment available replicas가 desired replicas보다 작음
namespace memory usage가 높은 상태 지속
```

ServiceMonitor:

```text
addons/monitoring/servicemonitors/wallet-backend.yaml
addons/monitoring/servicemonitors/woori-backend.yaml
```

Prometheus scrape 인증:

```text
backend /metrics는 METRICS_TOKEN으로 보호됩니다.
make metrics-secret이 wallet, woori, monitoring namespace에 metrics-token Secret을 만듭니다.
ServiceMonitor는 Authorization: Bearer <token>으로 backend를 scrape합니다.
외부 API Gateway 경로의 /metrics는 ALB에서 403으로 차단합니다.
```

Grafana 확인:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 --decode
```

로컬 3000 포트가 이미 사용 중이면:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3001:80
```

Grafana 외부 공개:

```text
기본 apply-all에서는 edge-monitoring을 만들지 않습니다.
외부 공개가 필요할 때만 ENABLE_GRAFANA_EDGE=yes를 사용합니다.
Prometheus와 Alertmanager는 계속 비공개입니다.
edge-monitoring은 AWS WAF allowlist를 사용합니다.
```

```hcl
# infra/edge-monitoring/terraform.tfvars
admin_allowed_cidrs = ["실제-관리자-또는-VPN-공인IP/32"]
```

```sh
ENABLE_GRAFANA_EDGE=yes make apply-all
make output SERVICE_MODE=edge-monitoring
```

destroy하면 Prometheus 시계열 데이터와 Grafana runtime state는 사라집니다. dashboard, alert rule, ServiceMonitor, Helm values는 Git에 남아 다시 복구됩니다.

## 10. 최초 생성 절차

state bucket bootstrap:

```sh
make init STACK_MODE=state
make plan STACK_MODE=state
make apply STACK_MODE=state
```

Terraform backend init:

```sh
make init SERVICE_MODE=platform
make init SERVICE_MODE=edge-woori
make init SERVICE_MODE=edge-wallet
make init SERVICE_MODE=edge-monitoring
```

전체 apply:

```sh
make apply-all
```

`apply-all` 내부 순서:

```text
1. gitops-guard
2. images-verify
3. terraform apply SERVICE_MODE=platform
4. aws eks update-kubeconfig
5. Helm으로 Argo CD 설치
6. Argo CD Application manifest 적용
7. monitoring Secret 확인 및 Grafana 준비 대기
8. app Secret 확인 및 app/DB 준비 대기
9. terraform apply SERVICE_MODE=edge-woori
10. terraform apply SERVICE_MODE=edge-wallet
11. ENABLE_GRAFANA_EDGE=yes일 때만 terraform apply SERVICE_MODE=edge-monitoring
```

`gitops-guard`는 다음을 확인합니다.

```text
현재 branch가 main인지
작업트리가 깨끗한지
local HEAD가 origin/main과 같은지
```

`images-verify`는 `apps/*/deployment.yaml`이 가리키는 ECR image tag가 실제 ECR에 존재하는지 확인합니다.

수동으로 나눠서 올릴 때:

```sh
make apply SERVICE_MODE=platform
make update-kubeconfig
make argocd-install
make addons-apply
make monitoring-wait
make apps-wait
make apply SERVICE_MODE=edge-woori
make apply SERVICE_MODE=edge-wallet
```

Grafana edge가 필요하면:

```sh
make apply SERVICE_MODE=edge-monitoring
```

## 11. 확인 절차

Kubernetes:

```sh
kubectl get pods -A
kubectl get applications -n argocd
kubectl get svc -n wallet
kubectl get svc -n woori
kubectl get svc -n monitoring
kubectl get endpoints -n wallet wallet-backend
kubectl get endpoints -n woori woori-backend
```

Terraform output:

```sh
make output SERVICE_MODE=platform
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
make output SERVICE_MODE=edge-monitoring
```

API 확인:

```sh
curl -i "$(terraform -chdir=infra/edge-wallet output -raw docs_url)"
curl -i "$(terraform -chdir=infra/edge-woori output -raw docs_url)"
```

Grafana 확인:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

## 12. 전체 종료 절차

비용을 줄이려면 service edge와 platform을 모두 내립니다. `bootstrap/state`는 유지합니다.

권장 명령:

```sh
CONFIRM_DATA_DELETE=yes make destroy-all
```

내부 순서:

```text
1. confirm-data-delete
2. terraform destroy SERVICE_MODE=edge-monitoring
3. terraform destroy SERVICE_MODE=edge-wallet
4. terraform destroy SERVICE_MODE=edge-woori
5. workloads-delete
6. data-delete
7. terraform destroy SERVICE_MODE=platform
```

순서가 중요한 이유:

```text
edge 스택은 platform의 shared ALB, VPC Link, EKS node ASG를 참조합니다.
platform을 먼저 지우면 edge destroy가 꼬일 수 있습니다.
DB PVC는 EBS volume을 만들 수 있으므로 platform destroy 전에 명시적으로 삭제합니다.
```

데이터 삭제 주의:

```text
CONFIRM_DATA_DELETE=yes make destroy-all은 DB PVC를 삭제합니다.
StorageClass reclaimPolicy가 Delete라서 EBS volume도 삭제됩니다.
MySQL 데이터가 필요하면 먼저 백업/snapshot을 떠야 합니다.
```

직접 Terraform으로 나눠서 내릴 때:

```sh
terraform -chdir=infra/edge-monitoring destroy
terraform -chdir=infra/edge-wallet destroy
terraform -chdir=infra/edge-woori destroy
make workloads-delete
CONFIRM_DATA_DELETE=yes make data-delete
terraform -chdir=infra/platform destroy
```

destroy 전에 plan만 볼 때:

```sh
terraform -chdir=infra/edge-monitoring plan -destroy
terraform -chdir=infra/edge-wallet plan -destroy
terraform -chdir=infra/edge-woori plan -destroy
terraform -chdir=infra/platform plan -destroy
```

`destroy-all`은 project Terraform 리소스와 Kubernetes workload/PVC를 대상으로 합니다. AWS 계정의 default VPC/default subnet은 이 프로젝트가 만든 리소스가 아니므로 삭제하지 않습니다. 프로젝트 destroy 후 default VPC가 남아 있어도 NAT Gateway, EKS, ALB, API Gateway, EIP 같은 주요 과금 리소스가 없으면 이 프로젝트 비용은 사실상 내려간 상태로 봅니다.

## 13. 재기동 절차

가장 단순한 재기동:

```sh
make init SERVICE_MODE=platform
make init SERVICE_MODE=edge-woori
make init SERVICE_MODE=edge-wallet
make init SERVICE_MODE=edge-monitoring
make apply-all
```

Grafana 외부 edge까지 같이 올릴 때:

```sh
ENABLE_GRAFANA_EDGE=yes make apply-all
```

재기동 후 확인:

```sh
kubectl get pods -A
kubectl get applications -n argocd
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
curl -i "$(terraform -chdir=infra/edge-wallet output -raw docs_url)"
curl -i "$(terraform -chdir=infra/edge-woori output -raw docs_url)"
```

주의:

```text
platform까지 destroy 후 다시 apply하면 API Gateway ID와 기본 endpoint URL이 바뀔 수 있습니다.
고정 URL이 필요하면 Route53 custom domain을 사용합니다.
```

## 14. Custom Domain

Route53 hosted zone이 있으면 서비스별 서브도메인을 붙일 수 있습니다.

```hcl
# infra/edge-wallet/terraform.tfvars
custom_domain_name = "wallet-api.example.com"
route53_zone_name  = "example.com"

# infra/edge-woori/terraform.tfvars
custom_domain_name = "woori-api.example.com"
route53_zone_name  = "example.com"

# infra/edge-monitoring/terraform.tfvars
custom_domain_name = "grafana.example.com"
route53_zone_name  = "example.com"
```

Terraform이 관리하는 리소스:

```text
ACM certificate
ACM DNS validation record
API Gateway custom domain
API Gateway API mapping
Route53 A alias record
```

도메인이 아직 없다면 Route53에서 새 도메인을 등록하거나, 외부에서 구매한 도메인을 Route53 hosted zone으로 연결해야 합니다.

## 15. 보안 옵션

EKS endpoint:

```hcl
cluster_endpoint_private_access      = true
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
```

현재 기본값은 lockout 방지를 위해 public CIDR이 열려 있습니다. 운영 환경에서는 관리자 고정 IP 또는 VPN CIDR로 좁히는 것을 권장합니다.

```hcl
cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
```

API Gateway throttling:

```hcl
api_throttling_burst_limit = 100
api_throttling_rate_limit  = 50
```

JWT authorizer는 옵션입니다. issuer/audience를 넣으면 API Gateway 레벨 JWT authorizer가 켜집니다.

```hcl
jwt_issuer   = "https://issuer.example.com"
jwt_audience = ["wallet-api"]
```

Grafana public edge는 WAF allowlist를 사용합니다.

```hcl
admin_allowed_cidrs = ["관리자-또는-VPN-공인IP/32"]
```

## 16. 비용 관련 결정사항

비용 절감을 위해 선택한 것:

```text
RDS 대신 EKS 내부 MySQL pod 사용
AWS Managed Prometheus/Grafana 대신 EKS 내부 kube-prometheus-stack 사용
NAT Gateway는 1개만 사용
app replica는 1개 유지
Grafana public edge는 기본 apply-all에서 제외
Prometheus PVC disabled
Grafana persistence disabled
```

비용과 안정성 trade-off:

```text
DB pod는 저렴하지만 backup/restore 책임이 커집니다.
NAT 1개는 저렴하지만 AZ 장애에 약합니다.
replica 1개는 저렴하지만 pod 장애에 약합니다.
node 2대는 Argo CD/모니터링/앱/DB를 같이 올리기 위한 최소 여유입니다.
```

## 17. 자주 발생하는 문제

### `/docs`가 안 나오는 경우

확인 순서:

```sh
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
kubectl get svc -n wallet wallet-backend
kubectl get svc -n woori woori-backend
kubectl get endpoints -n wallet wallet-backend
kubectl get endpoints -n woori woori-backend
```

가능한 원인:

```text
Argo CD가 apps/를 아직 sync하지 않았다.
NodePort Service가 없다.
backend pod가 readiness를 통과하지 못했다.
target group health check가 아직 healthy가 아니다.
```

### `kubectl port-forward ... 3000:80` 실패

로컬 3000 포트가 이미 사용 중인 상태입니다.

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3001:80
```

### `make apply-all`이 GitOps guard에서 실패

`apply-all`은 운영 기준 repo 상태와 cluster 상태가 어긋나는 것을 줄이기 위해 작업트리가 깨끗한 `main` 브랜치에서만 실행합니다.

확인:

```sh
git status --short
git branch --show-current
git fetch origin main
```

### ECR image verify 실패

manifest가 가리키는 image tag가 ECR에 없다는 뜻입니다.

```text
앱 repo GitHub Actions가 ECR push를 완료했는지 확인합니다.
infra repo deployment.yaml image tag가 실제 존재하는 tag인지 확인합니다.
```

### platform을 먼저 destroy한 경우

edge 스택이 platform remote state와 shared ALB/VPC Link를 참조하지 못해 실패할 수 있습니다. 가능하면 platform을 다시 apply해 참조를 복구한 뒤 edge destroy를 다시 실행합니다.

### default VPC가 남아 있는 경우

AWS 계정에는 리전별 default VPC/default subnet이 있을 수 있습니다. 이 프로젝트의 `destroy-all`은 default VPC를 삭제하지 않습니다.

프로젝트 리소스 여부 확인:

```sh
aws ec2 describe-vpcs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=woori-wallet

aws eks list-clusters --region ap-northeast-2

aws elbv2 describe-load-balancers --region ap-northeast-2

aws apigatewayv2 get-apis --region ap-northeast-2
```

default VPC를 삭제하면 다른 실험/미래 리소스에 영향을 줄 수 있습니다. 별도 명시 승인 없이 운영 절차에 포함하지 않습니다.

## 18. 검증 명령

로컬 문법/렌더 검증:

```sh
make fmt
terraform -chdir=infra/platform validate
terraform -chdir=infra/edge-woori validate
terraform -chdir=infra/edge-wallet validate
terraform -chdir=infra/edge-monitoring validate
kubectl kustomize apps
kubectl kustomize addons/monitoring
git diff --check
```

실제 AWS apply/destroy는 비용과 리소스 영향이 있으므로 명시 요청이 있을 때만 실행합니다.
