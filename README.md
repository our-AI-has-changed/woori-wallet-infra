# woori-wallet-infra

Woori Wallet AWS/EKS 인프라와 GitOps 배포 기준을 관리하는 저장소입니다.

운영자가 실제로 인프라를 올리고, 확인하고, 비용 절감을 위해 내리는 절차는 [docs/operations-handoff.md](docs/operations-handoff.md)를 기준으로 봅니다. 이 README는 전체 구조를 빠르게 파악하기 위한 요약입니다.

## 한 줄 요약

```text
Terraform
  -> VPC/EKS/shared internal ALB/API Gateway edge 생성
Argo CD
  -> apps/, addons/monitoring/ GitOps sync
GitHub Actions
  -> 앱 image를 ECR에 push하고 infra repo image tag commit
EKS
  -> backend, ai, mock-mydata, MySQL pod, Prometheus, Grafana 실행
```

## 요구사항

- Terraform 1.15.5
- AWS CLI credential
- kubectl
- Helm
- openssl
- Python 3

## 디렉터리 구조

```text
.
├── Makefile
├── bootstrap/state              # Terraform remote state S3 bucket bootstrap
├── infra
│   ├── platform                 # VPC, EKS, node group, EBS CSI, shared internal ALB, VPC Link
│   ├── edge-woori               # woori API Gateway, ALB rule, target group
│   ├── edge-wallet              # wallet API Gateway, ALB rule, target group
│   └── edge-monitoring          # Grafana API Gateway, WAF allowlist, ALB rule, target group
├── modules/service-edge          # 서비스별 public edge 공통 Terraform 모듈
├── apps                          # Argo CD가 sync하는 앱/DB Kubernetes manifest
├── addons
│   ├── argocd                   # Argo CD Helm values
│   └── monitoring               # kube-prometheus-stack values, dashboards, alerts, ServiceMonitor
├── argocd/applications           # Argo CD Application manifest
└── docs/operations-handoff.md    # 운영 인수인계서
```

## Terraform 책임 분리

| 스택 | 책임 |
| --- | --- |
| `STACK_MODE=state` | Terraform state용 S3 bucket bootstrap |
| `SERVICE_MODE=platform` | VPC, public/private subnet, NAT Gateway 1개, EKS, node group, EBS CSI, shared internal ALB, API Gateway VPC Link |
| `SERVICE_MODE=edge-woori` | woori-backend public API Gateway, ALB listener rule, target group, ASG attachment, optional custom domain |
| `SERVICE_MODE=edge-wallet` | wallet-backend public API Gateway, ALB listener rule, target group, ASG attachment, optional custom domain |
| `SERVICE_MODE=edge-monitoring` | Grafana public API Gateway, WAF IP allowlist, ALB listener rule, target group, optional custom domain |

호환성을 위해 `SERVICE_MODE=woori`, `SERVICE_MODE=wallet`도 각각 `edge-woori`, `edge-wallet`로 매핑됩니다.

## 현재 아키텍처

서비스별 NLB 2개 방식이 아니라, `platform`이 만드는 shared internal ALB 1개를 함께 사용합니다.

```text
Mobile / Client
  -> service-specific HTTP API Gateway
  -> API Gateway VPC Link
  -> shared internal ALB
  -> Host header based listener rule
  -> service target group
  -> EKS node NodePort
  -> Kubernetes Service
  -> Pod
```

서비스별 포트와 라우팅 기준:

| 서비스 | 외부 진입 | 내부 Host header | Kubernetes Service | NodePort |
| --- | --- | --- | --- | --- |
| wallet-backend | `edge-wallet` HTTP API Gateway | `wallet.internal` | `wallet/wallet-backend` | `30080` |
| woori-backend | `edge-woori` HTTP API Gateway | `woori.internal` | `woori/woori-backend` | `30081` |
| Grafana | `edge-monitoring` HTTP API Gateway | `grafana.internal` | `monitoring/kube-prometheus-stack-grafana` | `30082` |

API Gateway는 `$default` route로 들어온 요청을 shared ALB로 넘기고, integration에서 내부 `Host` header를 서비스별 값으로 덮어씁니다. 그래서 `/docs`, `/openapi.json`, 일반 API path는 Gateway path rewrite 없이 backend로 그대로 전달됩니다.

외부 `/metrics` path는 backend 서비스 edge에서 ALB fixed-response rule로 `403` 차단합니다. Prometheus는 외부 Gateway가 아니라 Kubernetes 내부 ServiceMonitor로 `/metrics`를 scrape합니다.

## EKS와 앱

기본값은 비용과 최소 운영 여유를 같이 고려한 구성입니다.

```text
EKS node group: t3.medium, min 2 / desired 2 / max 2
NAT Gateway: 1개
app replicas: 1
DB: EKS 내부 MySQL StatefulSet 2개, 각 PVC 5Gi
```

`t3.small` 2대로는 Argo CD, kube-prometheus-stack, 앱 4개, MySQL DB 2개를 함께 올릴 때 메모리와 pod 수가 부족해 일부 workload가 Pending 상태가 될 수 있습니다. 그래서 현재 기본값은 비용을 크게 늘리지 않으면서 전체 스택이 올라가는 최소 기준인 `t3.medium` 2대로 둡니다.

앱 manifest는 `apps/` 아래에 있습니다.

| 경로 | namespace | 역할 |
| --- | --- | --- |
| `apps/woori-backend` | `woori` | 우리 인증/회원 backend |
| `apps/wallet-backend` | `wallet` | 지갑 backend |
| `apps/wallet-ai` | `wallet` | wallet AI internal service |
| `apps/mock-mydata` | `wallet` | mock MyData internal service |
| `apps/woori-db` | `woori` | `woori_auth` MySQL |
| `apps/wallet-db` | `wallet` | `wallet_trial` MySQL |
| `apps/storage` | cluster-wide | `woori-wallet-gp3` StorageClass |

DB는 RDS가 아니라 EKS pod로 올립니다. 비용 절감이 목적이며, 운영 DB로 쓰려면 별도 backup/snapshot 정책이 필요합니다.

```text
woori-backend  -> woori-db.woori.svc.cluster.local:3306/woori_auth
wallet-backend -> wallet-db.wallet.svc.cluster.local:3306/wallet_trial
wallet-backend -> woori-db.woori.svc.cluster.local:3306/woori_auth
```

## Secret 관리

비밀번호와 token은 Git에 평문으로 저장하지 않습니다. 원본은 SSM Parameter Store SecureString에 둡니다.

```text
/woori-wallet/prod/metrics-token
/woori-wallet/prod/argocd-infra-repo-token
/woori-wallet/prod/woori-db-password
/woori-wallet/prod/woori-db-root-password
/woori-wallet/prod/wallet-db-password
/woori-wallet/prod/wallet-db-root-password
```

클러스터 생성 후 Makefile target이 SSM 값을 읽어 Kubernetes Secret을 만듭니다.

```sh
make ssm-parameters-check
make argocd-repo-secret
make metrics-secret
make db-secret
make monitoring-secret
make secrets-apply
```

처음 테스트 환경을 올릴 때 값이 아직 없으면, 없는 파라미터만 랜덤 SecureString으로 만들 수 있습니다.

```sh
CREATE_MISSING_SSM_PARAMETERS=yes make ssm-parameters-bootstrap
```

이 타깃은 이미 존재하는 SSM 값은 덮어쓰지 않습니다. 운영에서 정해진 DB 비밀번호를 써야 한다면 AWS 콘솔 또는 AWS CLI로 직접 SecureString을 만든 뒤 `make ssm-parameters-check`로 확인합니다.

`/woori-wallet/prod/argocd-infra-repo-token`은 랜덤값으로 만들면 안 됩니다. private infra repo를 읽을 수 있는 GitHub token 또는 GitHub App token을 SecureString으로 직접 넣어야 합니다. 초기 구성은 fine-grained PAT를 사용하고, 최소 권한은 `our-AI-has-changed/woori-wallet-infra` repository `contents: read`입니다.

생성되는 주요 Secret:

```text
argocd/woori-wallet-infra-repo
wallet/metrics-token
woori/metrics-token
monitoring/metrics-token
monitoring/grafana-admin
woori/woori-db-credentials
wallet/wallet-db-credentials
wallet/woori-db-credentials
```

Grafana admin password를 고정하고 싶으면 로컬에서만 아래처럼 넘깁니다.

```sh
GRAFANA_ADMIN_PASSWORD='change-me-locally' make monitoring-secret
```

## GitOps CD

운영 배포 기준 repo는 이 infra repo입니다.

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

서비스별 image manifest:

```text
wallet-backend -> apps/wallet-backend/deployment.yaml
woori-backend  -> apps/woori-backend/deployment.yaml
wallet-ai      -> apps/wallet-ai/deployment.yaml
mock-mydata    -> apps/mock-mydata/deployment.yaml
```

주의:

- ECR에 image만 push해도 Argo CD는 배포하지 않습니다.
- Argo CD는 ECR이 아니라 infra repo `main` 브랜치를 봅니다.
- 운영 기준으로 `latest` tag는 권장하지 않습니다.
- rollback은 infra repo의 이전 image tag commit으로 되돌리는 방식입니다.
- 앱 repo가 infra repo에 commit하려면 `INFRA_REPO_TOKEN` secret이 필요합니다. 최소 권한은 infra repo `contents: read/write`입니다.
- Argo CD가 private infra repo를 읽으려면 `/woori-wallet/prod/argocd-infra-repo-token` SSM 값이 필요합니다. 이 값은 Argo CD repository Secret으로 변환되며, 권한은 infra repo `contents: read`만 주는 것을 권장합니다.

## Argo CD와 모니터링

Argo CD는 EKS 생성 후 Helm chart로 설치합니다.

```text
chart: argo/argo-cd
chart version: 7.8.27
namespace: argocd
values: addons/argocd/values.yaml
```

Argo CD Application을 적용하기 전에 `make argocd-repo-secret`이 SSM의 `/woori-wallet/prod/argocd-infra-repo-token` 값을 읽어 `argocd/woori-wallet-infra-repo` Secret을 만듭니다. 이 Secret이 없으면 private infra repo를 읽지 못해 Application sync가 `authentication required` 또는 `Repository not found`로 실패합니다.

모니터링은 AWS Managed Prometheus/Grafana를 쓰지 않고 EKS 내부 `kube-prometheus-stack`을 사용합니다. 이유는 비용 절감입니다.

```text
chart: prometheus-community/kube-prometheus-stack
chart version: 70.3.0
namespace: monitoring
values: addons/monitoring/values.yaml
Prometheus retention: 3d
Prometheus PVC: disabled
Grafana persistence: disabled
```

destroy 후 Prometheus 시계열 데이터와 Grafana runtime state는 사라집니다. 하지만 Helm values, dashboard, alert rule, ServiceMonitor, Argo CD Application은 Git에 남기 때문에 다시 apply하면 코드 기준으로 복구됩니다.

Grafana 확인:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 --decode
```

로컬 `3000` 포트가 이미 사용 중이면 다른 포트를 씁니다.

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3001:80
```

Grafana만 외부 공개가 필요하면 `edge-monitoring`을 사용합니다. 기본 `apply-all`은 비용과 allowlist 실수를 줄이기 위해 Grafana edge를 만들지 않습니다.

```sh
ENABLE_GRAFANA_EDGE=yes make apply-all
```

이때 `infra/edge-monitoring/terraform.tfvars`의 `admin_allowed_cidrs`를 실제 관리자/VPN 공인 IP CIDR로 먼저 바꿔야 합니다.

## 빠른 시작

처음 한 번 state bucket을 만듭니다.

```sh
make init STACK_MODE=state
make plan STACK_MODE=state
make apply STACK_MODE=state
```

인프라 전체를 올립니다.

```sh
make init SERVICE_MODE=platform
make init SERVICE_MODE=edge-woori
make init SERVICE_MODE=edge-wallet
make init SERVICE_MODE=edge-monitoring
make apply-all
```

`apply-all` 순서:

```text
gitops-guard
images-verify
SSM parameter check/bootstrap
Terraform platform apply
kubeconfig update
Argo CD install
Argo CD infra repo credential apply
Argo CD Application apply
monitoring wait
apps wait
Terraform edge-woori apply
Terraform edge-wallet apply
optional Terraform edge-monitoring apply
```

서비스 endpoint 확인:

```sh
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
make output SERVICE_MODE=edge-monitoring
```

`platform`까지 destroy 후 다시 apply하면 API Gateway 기본 URL은 바뀔 수 있습니다. 고정 URL이 필요하면 Route53 custom domain을 사용합니다.

## 서버 중지와 전체 종료

DB 데이터를 보존하면서 외부 API와 실행 중인 workload만 내릴 때는 아래 명령을 사용합니다.

```sh
make stop-all
```

이 명령은 wallet/woori/Grafana public edge와 Kubernetes app/DB/monitoring/Argo CD workload를 내립니다. DB PVC와 platform 리소스는 유지하므로 MySQL 데이터는 남지만, EKS control plane, NAT Gateway, node group 비용은 계속 발생합니다.

비용 절감을 위해 platform까지 전체 인프라를 내릴 때는 아래 명령을 사용합니다.

```sh
CONFIRM_DATA_DELETE=yes make destroy-all
```

이 명령은 DB PVC를 삭제하므로 MySQL 데이터도 사라집니다. 데이터가 필요하면 먼저 백업/snapshot 절차를 수행해야 합니다.

`destroy-all`은 project Terraform 리소스와 Kubernetes workload/PVC를 대상으로 합니다. AWS 계정의 default VPC/default subnet은 이 프로젝트가 만든 리소스가 아니므로 삭제하지 않습니다.

## Terraform state

`bootstrap/state`만 local backend로 시작하고, 나머지 스택은 S3 backend를 사용합니다.

```text
bucket: woori-wallet-tfstate-655700895912-apne2

prd/platform/terraform.tfstate
prd/edge-woori/terraform.tfstate
prd/edge-wallet/terraform.tfstate
prd/edge-monitoring/terraform.tfstate
```

기존 `prd/wallet/terraform.tfstate` 또는 `prd/woori/terraform.tfstate`에 리소스가 남아 있는 환경에서 새 key로 바로 apply하면 중복 생성될 수 있습니다. 기존 환경이 남아 있다면 state migrate/import를 먼저 해야 합니다.

## 자주 쓰는 명령

```sh
make fmt
make validate SERVICE_MODE=platform
make plan SERVICE_MODE=edge-wallet
make apply SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-wallet

kubectl get pods -A
kubectl get applications -n argocd
kubectl get svc -n wallet
kubectl get svc -n woori
kubectl get svc -n monitoring
```
