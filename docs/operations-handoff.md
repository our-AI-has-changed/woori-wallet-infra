# Woori Wallet Infra 인수인계서

이 문서는 `woori-wallet-infra` 저장소를 기준으로 현재 AWS/EKS 인프라 구조, GitOps CD 흐름, 모니터링, DB, 운영 명령, 비용 절감용 종료/재기동 절차를 정리합니다.

## 0. 인수자 Quick Start

인수자는 아래 순서로 보면 됩니다.

```text
1. README.md와 이 문서의 1~5장을 먼저 읽습니다.
2. AWS CLI, kubectl, helm, terraform, dig가 로컬에 있는지 확인합니다.
3. AWS profile이 655700895912 계정과 ap-northeast-2 리전을 바라보는지 확인합니다.
4. SSM Parameter Store의 필수 SecureString이 있는지 `make ssm-parameters-check`로 확인합니다.
5. Route53 hosted zone `dannis.cloud`는 비용 절감 destroy 대상이 아니므로 유지합니다.
6. 전체를 올릴 때는 깨끗한 main 브랜치에서 `make apply-all`을 사용합니다.
7. 전체를 내릴 때는 Route53을 제외하고 `CONFIRM_DATA_DELETE=yes make destroy-all`을 사용합니다.
```

팀원이 레포를 받아서 작업할 때 Git에 있어야 하는 것은 Terraform 코드, Kubernetes manifest, Argo CD Application, Helm values, 문서입니다. Git에 있으면 안 되는 것은 실제 `terraform.tfvars`, Terraform state, AWS/GitHub/DB/API secret 값입니다.

## 1. 현재 결론

현재 구조는 다음 원칙으로 정리되어 있습니다.

```text
Terraform은 AWS 인프라와 public edge만 관리한다.
Kubernetes 앱/DB/모니터링은 Argo CD + Helm + manifest로 관리한다.
앱 배포 기준은 ECR image가 아니라 infra repo main 브랜치의 manifest다.
비용 절감을 위해 RDS와 AWS Managed Prometheus/Grafana는 쓰지 않는다.
Grafana public edge는 apply-all/stop-all/destroy-all에 항상 포함한다.
Route53 hosted zone은 장기 유지 리소스라 destroy-all에서 제외한다.
```

중요한 기본값:

```text
Region: ap-northeast-2
AWS account: 655700895912
EKS node group: t3.medium, min 2 / desired 2 / max 2
NAT Gateway: 1개
app replicas: 1
DB: EKS 내부 MySQL StatefulSet 2개, 각 PVC 5Gi
Prometheus retention: 3d
Prometheus PVC: disabled
Grafana persistence: disabled
```

`t3.small` 2대 구성은 Argo CD, 모니터링, 앱 4개, MySQL DB 2개를 동시에 올릴 때 메모리와 pod 수 부족으로 workload가 Pending될 수 있습니다. 현재 기본값은 전체 스택을 한 번에 검증할 수 있는 최소 운영 기준으로 `t3.medium` 2대를 사용합니다.

## 2. 저장소 구조

```text
bootstrap/state
  Terraform remote state S3 bucket bootstrap

infra/platform
  VPC, subnets, NAT Gateway, EKS, managed node group, EBS CSI driver,
  API Gateway VPC Link, shared internal ALB

infra/dns
  Route53 public hosted zone for dannis.cloud.
  최초 1회 apply 후 장기 유지하는 기반 리소스입니다.

infra/edge-frontend
  frontend public API Gateway, ALB listener rule, target group,
  EKS node ASG target group attachment, optional custom domain

infra/edge-woori
  woori-backend public API Gateway, ALB listener rule, target group,
  EKS node ASG target group attachment, optional custom domain

infra/edge-wallet
  wallet-backend public API Gateway, ALB listener rule, target group,
  EKS node ASG target group attachment, optional custom domain

infra/edge-monitoring
  Grafana public API Gateway, Lambda authorizer IP allowlist, ALB listener rule,
  target group, optional custom domain

modules/service-edge
  edge-frontend, edge-woori, edge-wallet, edge-monitoring이 공유하는 Terraform module

apps
  Argo CD가 sync하는 app, DB, namespace, StorageClass manifest

addons/argocd
  Argo CD Helm values

addons/external-secrets
  External Secrets Operator Helm values

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
  -> API Gateway Lambda IP authorizer
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
| frontend | `edge-frontend` | `frontend/frontend` | `30083` | `/` | `frontend.internal` |
| woori-backend | `edge-woori` | `woori/woori-backend` | `30081` | `/api/health` | `woori.internal` |
| wallet-backend | `edge-wallet` | `wallet/wallet-backend` | `30080` | `/api/health` | `wallet.internal` |
| Grafana | `edge-monitoring` | `monitoring/kube-prometheus-stack-grafana` | `30082` | `/api/health` | `grafana.internal` |

API Gateway는 `$default` route를 사용합니다. `/docs`로 들어오면 path rewrite 없이 backend의 `/docs`로 전달됩니다.

## 4. Terraform state

`bootstrap/state`만 local backend로 시작하고, 나머지 스택은 S3 backend를 사용합니다.

```text
bucket: woori-wallet-tfstate-655700895912-apne2

prd/platform/terraform.tfstate
prd/dns/terraform.tfstate
prd/edge-frontend/terraform.tfstate
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
/woori-wallet/prod/trial/woori-backend-env
/woori-wallet/prod/trial/wallet-backend-env
/woori-wallet/prod/trial/ai-env
/woori-wallet/prod/argocd-infra-repo-token
/woori-wallet/prod/woori-db-password
/woori-wallet/prod/woori-db-root-password
/woori-wallet/prod/wallet-db-password
/woori-wallet/prod/wallet-db-root-password
```

trial 앱 repo의 현재 `feature/wallet-trial-polish` 구조는 `backend-woori`, `backend-wallet`, `ai`, `app`으로 나뉘어 있습니다. 따라서 backend runtime env도 하나의 공통 `backend-env`가 아니라 woori-backend와 wallet-backend로 분리합니다.

SSM 값 예시:

```env
# /woori-wallet/prod/trial/woori-backend-env
CORS_ORIGINS=https://frontend.dannis.cloud
SOLAPI_API_KEY=
SOLAPI_API_SECRET=
SOLAPI_FROM=
```

```env
# /woori-wallet/prod/trial/wallet-backend-env
CORS_ORIGINS=https://frontend.dannis.cloud
WALLET_AI_URL=http://wallet-ai:8002
```

```env
# /woori-wallet/prod/trial/ai-env
ACTIVE_MODE=cloud
OPENAI_API_KEY=
GEMINI_API_KEY=
NAVER_CLIENT_ID=
NAVER_CLIENT_SECRET=
LANGCHAIN_TRACING_V2=false
LANGCHAIN_API_KEY=
LANGCHAIN_ENDPOINT=https://api.smith.langchain.com
METRICS_ENABLED=true
METRICS_TOKEN=
```

```env
# /woori-wallet/prod/trial/app-env
API_BASE_URL=https://woori-api.dannis.cloud/api
WALLET_API_BASE_URL=https://wallet-api.dannis.cloud/api
WOORI_USER_NAME=홍길동
```

DB URL은 위 dotenv SSM에 넣지 않습니다. EKS에서는 `db-secret` target이 DB password SSM을 읽어서 `WOORI_DATABASE_URL`, `WALLET_DATABASE_URL`을 별도 Kubernetes Secret으로 만듭니다.

backend/AI/metrics runtime secret은 External Secrets Operator가 SSM Parameter Store에서 읽어 Kubernetes Secret으로 동기화합니다. Terraform platform 스택은 ESO용 IRSA role과 SSM/KMS 권한만 만들며, secret 값 자체를 Terraform state에 넣지 않습니다.

`make external-secrets-install`은 ESO Helm chart 설치 후 `addons/external-secrets/cluster-secret-store.yaml`도 적용합니다. 이 Store가 먼저 있어야 apps/monitoring Application의 ExternalSecret이 안정적으로 동기화됩니다.

SSM SecureString이 AWS managed `aws/ssm` key를 쓰면 `external_secrets_kms_key_arns`는 빈 리스트로 둡니다. customer-managed KMS key로 암호화한 Parameter를 쓰는 경우에만 `infra/platform/terraform.tfvars`에 해당 key ARN을 명시합니다.

DB password, Argo CD repo token, Grafana admin password는 bootstrap 단계에서 Makefile이 Kubernetes Secret을 생성합니다.

```sh
make ssm-parameters-check
make external-secrets-install
make argocd-repo-token-check
make argocd-repo-secret
make db-secret
make monitoring-secret
make secrets-apply
```

처음 테스트 환경에서 DB password와 metrics token이 아직 없다면 아래 명령으로 누락된 파라미터만 랜덤 SecureString으로 생성할 수 있습니다.

```sh
CREATE_MISSING_SSM_PARAMETERS=yes make ssm-parameters-bootstrap
```

이 명령은 이미 존재하는 값을 덮어쓰지 않습니다. `woori-backend-env`, `wallet-backend-env`, `ai-env`, `app-env`, Argo CD infra repo token은 실제 설정값이 필요하므로 자동 랜덤 생성 대상이 아닙니다. 운영에서 정해진 DB 비밀번호를 사용해야 한다면 AWS 콘솔 또는 AWS CLI로 SecureString을 직접 만든 뒤 아래 명령으로 확인합니다.

```sh
make ssm-parameters-check
```

`/woori-wallet/prod/argocd-infra-repo-token`은 랜덤값으로 만들면 안 되므로 bootstrap 대상이 아닙니다. private infra repo를 읽을 수 있는 GitHub token 또는 GitHub App token을 SecureString으로 직접 넣습니다. 초기 구성은 fine-grained PAT 기준이며, 최소 권한은 `our-AI-has-changed/woori-wallet-infra` repository `contents: read`입니다. `make argocd-repo-token-check`로 token이 실제 repo를 읽을 수 있는지 미리 검증합니다.

`make apply-all`은 `platform`을 만들기 전에 `ssm-parameters-ensure`를 실행합니다. 기본값은 누락된 SSM Parameter가 있으면 초기에 실패시키는 방식입니다. 자동 생성을 원할 때만 아래처럼 명시합니다.

```sh
CREATE_MISSING_SSM_PARAMETERS=yes make apply-all
```

생성되는 Secret:

```text
argocd/woori-wallet-infra-repo:
  type
  url
  username
  password

wallet/metrics-token: METRICS_TOKEN
wallet/backend-env: .env
wallet/ai-env: .env
woori/metrics-token: METRICS_TOKEN
woori/backend-env: .env
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

runtime secret 연결:

| SSM Parameter | Kubernetes Secret | Pod 주입 방식 |
| --- | --- | --- |
| `/woori-wallet/prod/trial/woori-backend-env` | `woori/backend-env` key `.env` | woori-backend Pod가 `/service/.env`로 mount |
| `/woori-wallet/prod/trial/wallet-backend-env` | `wallet/backend-env` key `.env` | wallet-backend Pod가 `/service/.env`로 mount |
| `/woori-wallet/prod/trial/ai-env` | `wallet/ai-env` key `.env` | wallet-ai Pod가 `/app/.env`로 mount |
| `/woori-wallet/prod/metrics-token` | `wallet/metrics-token`, `woori/metrics-token`, `monitoring/metrics-token` key `METRICS_TOKEN` | backend/wallet-ai env와 Prometheus ServiceMonitor 인증 |

backend/AI env는 현재 trial repo의 `backend-woori/.env.example`, `backend-wallet/.env.example`, `ai/.env.example`에 맞춰 서비스별 dotenv 문자열 한 덩어리입니다. ESO는 이 값을 그대로 Secret의 `.env` 파일 key로 동기화하고, Pod가 파일로 mount합니다. 운영성이 더 좋은 대안은 SSM을 키별로 나누는 방식입니다. 예를 들어 `/woori-wallet/prod/trial/wallet-backend/WALLET_AI_URL`, `/woori-wallet/prod/trial/ai/OPENAI_API_KEY`처럼 분리하면 Deployment에서 `envFrom`으로 받을 수 있고 회전/누락 검증이 쉬워집니다. 대신 SSM Parameter 수와 ExternalSecret mapping이 늘어납니다.

ClusterSecretStore는 `make external-secrets-install`이 관리하고, namespace별 ExternalSecret manifest는 Argo CD가 관리합니다. 운영 중 ESO가 만든 runtime Secret이 지워지면 ExternalSecret reconcile로 복구됩니다. DB/Grafana/Argo CD repo Secret이 지워지면 아래 명령으로 복구합니다.

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

backend/AI runtime secret 회전:

```sh
# 1. SSM Parameter Store 값을 수정
# 2. ESO가 Kubernetes Secret을 갱신할 때까지 대기
kubectl -n wallet get externalsecret backend-env ai-env metrics-token
kubectl -n woori get externalsecret backend-env metrics-token

# 3. 앱 프로세스가 새 .env 값을 읽도록 Pod 재시작
kubectl -n wallet rollout restart deployment/wallet-backend
kubectl -n woori rollout restart deployment/woori-backend
kubectl -n wallet rollout restart deployment/wallet-ai
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
3. frontend는 `/woori-wallet/prod/trial/app-env` SSM 값을 읽어 정적 web image를 빌드
4. Docker image를 ECR에 ${GITHUB_SHA} tag로 push
5. GitHub Actions가 infra repo의 apps/{service}/deployment.yaml image tag 업데이트
6. infra repo main에 commit
7. Argo CD가 infra repo main 변경 감지
8. EKS에 sync
9. pod가 새 ECR image로 rolling update
```

서비스별 manifest:

```text
frontend      -> apps/frontend/deployment.yaml
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
frontend app-env는 EKS Pod runtime secret이 아니라 app repo GitHub Actions build arg입니다.
PR/test job은 AWS에 접근하지 않고 FRONTEND_TEST_API_BASE_URL, FRONTEND_TEST_WALLET_API_BASE_URL, FRONTEND_TEST_WOORI_USER_NAME repo variable 또는 .test.invalid 기본 test 값을 사용합니다.
frontend test가 실제 API를 호출하게 되면 repo variable을 staging/test URL로 바꿉니다.
push/workflow_dispatch 배포 job만 SSM을 읽습니다.
앱 repo GitHub Actions의 AWS_ROLE_TO_ASSUME role에는 ECR push 권한과 /woori-wallet/prod/trial/app-env ssm:GetParameter 권한이 필요합니다.
customer-managed KMS key로 app-env를 암호화했다면 kms:Decrypt 권한도 필요합니다.
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
make argocd-repo-token-check
make argocd-repo-secret
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

private infra repo를 쓰므로 Argo CD Application 적용 전에 repository credential Secret이 필요합니다. `make argocd-repo-secret`은 SSM의 `/woori-wallet/prod/argocd-infra-repo-token` 값을 읽어 `argocd/woori-wallet-infra-repo` Secret을 생성합니다. 이 Secret이 없으면 `authentication required` 또는 `Repository not found`로 sync가 실패합니다.

`make argocd-repo-token-check`는 HTTPS Git URL과 PAT/password 인증 기준입니다. `ARGOCD_INFRA_REPO_OWNER`와 `ARGOCD_INFRA_REPO_NAME`으로 GitHub API read 권한을 확인하며, 기본값은 각각 `our-AI-has-changed`, `woori-wallet-infra`입니다. `ARGOCD_INFRA_REPO_URL`이 가리키는 repo와 owner/name이 다르면 preflight가 실패합니다. SSH repo URL은 현재 Secret 형식에서 지원하지 않습니다. GitHub Enterprise를 쓰면 repo URL은 `https://<enterprise-host>/<org>/<repo>.git`, `ARGOCD_GITHUB_API_URL`은 `https://<enterprise-host>/api/v3` 형태로 함께 설정합니다.

`make argocd-apply`와 `make monitoring-apply`는 Application manifest의 `__ARGOCD_INFRA_REPO_URL__` placeholder를 `ARGOCD_INFRA_REPO_URL` 값으로 렌더링해서 적용합니다. repo URL을 override하는 경우에는 직접 `kubectl apply -f argocd/applications/*.yaml` 대신 Makefile target을 사용합니다.

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
wallet-ai /metrics 앱 내부 지표
```

Dashboard:

```text
addons/monitoring/dashboards/wallet-woori-overview.yaml
```

대시보드 주요 패널:

```text
wallet-backend Pod Up/Down
woori-backend Pod Up/Down
Node Ready
Deployment available / desired replicas
wallet / woori namespace CPU, memory
pod restart count
pod status by phase
wallet-ai HTTP request rate
wallet-ai HTTP p95 latency
wallet-ai HTTP error rate
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
addons/monitoring/servicemonitors/wallet-ai.yaml
addons/monitoring/servicemonitors/wallet-backend.yaml
addons/monitoring/servicemonitors/woori-backend.yaml
```

Prometheus scrape 인증:

```text
backend와 wallet-ai /metrics는 METRICS_TOKEN으로 보호됩니다.
ExternalSecret이 wallet, woori, monitoring namespace에 metrics-token Secret을 동기화합니다.
ServiceMonitor는 Authorization: Bearer <token>으로 wallet-backend, woori-backend, wallet-ai를 scrape합니다.
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
apply-all에서는 edge-monitoring을 항상 만듭니다.
Prometheus와 Alertmanager는 계속 비공개입니다.
edge-monitoring은 API Gateway Lambda REQUEST authorizer allowlist를 사용합니다.
```

```hcl
# infra/edge-monitoring/terraform.tfvars
admin_allowed_cidrs = ["실제-관리자-또는-VPN-공인IP/32"]
```

```sh
make apply-all
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
make init SERVICE_MODE=dns
make init SERVICE_MODE=edge-frontend
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
3. terraform apply SERVICE_MODE=dns
4. route53-zone-check
5. route53-delegation-check
6. ssm-parameters-ensure
7. argocd-repo-token-check
8. terraform apply SERVICE_MODE=platform
9. aws eks update-kubeconfig
10. Helm으로 External Secrets Operator 설치
11. Helm으로 Argo CD 설치
12. Argo CD infra repo credential Secret 적용
13. Argo CD Application manifest 적용
14. monitoring Secret 확인 및 Grafana 준비 대기
15. app Secret 확인 및 app/DB 준비 대기
16. terraform apply SERVICE_MODE=edge-frontend
17. terraform apply SERVICE_MODE=edge-woori
18. terraform apply SERVICE_MODE=edge-wallet
19. terraform apply SERVICE_MODE=edge-monitoring
```

`gitops-guard`는 다음을 확인합니다.

```text
현재 branch가 main인지
작업트리가 깨끗한지
local HEAD가 origin/main과 같은지
```

`images-verify`는 `apps/*/deployment.yaml`이 가리키는 ECR image tag가 실제 ECR에 존재하는지 확인합니다.

`ssm-parameters-ensure`는 필수 SSM Parameter가 있는지 확인합니다. `CREATE_MISSING_SSM_PARAMETERS=yes`가 있으면 DB password와 metrics token의 누락 값만 랜덤 SecureString으로 생성합니다. woori-backend-env, wallet-backend-env, ai-env, app-env, Argo CD infra repo token은 실제 값이 필요하므로 직접 만든 SecureString이 없으면 실패합니다. app-env는 frontend Docker build 시점에 `API_BASE_URL`, `WALLET_API_BASE_URL`, `WOORI_USER_NAME`으로 주입됩니다. 이어서 `argocd-repo-token-check`가 token의 repo read 권한을 확인합니다. 이 검사를 `platform` apply 전에 실행하는 이유는 EKS/NAT를 만든 뒤 Secret 생성이나 Argo CD sync에서 뒤늦게 실패하는 상황을 막기 위해서입니다.

수동으로 나눠서 올릴 때:

```sh
make apply SERVICE_MODE=platform
make update-kubeconfig
make external-secrets-install
make argocd-install
make addons-apply
make monitoring-wait
make apps-wait
make apply SERVICE_MODE=edge-frontend
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
make output SERVICE_MODE=edge-frontend
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
make output SERVICE_MODE=edge-monitoring
```

API 확인:

```sh
curl -i "https://frontend.dannis.cloud"
curl -i "https://wallet-api.dannis.cloud/docs"
curl -i "https://woori-api.dannis.cloud/docs"
```

Grafana 확인:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

## 12. 서버 중지와 전체 종료 절차

DB 데이터를 보존하면서 외부 API와 실행 중인 workload만 내릴 때는 아래 명령을 사용합니다.

```sh
make stop-all
```

`stop-all` 내부 순서:

```text
1. terraform destroy SERVICE_MODE=edge-monitoring
2. terraform destroy SERVICE_MODE=edge-frontend
3. terraform destroy SERVICE_MODE=edge-wallet
4. terraform destroy SERVICE_MODE=edge-woori
5. workloads-delete
```

이 명령은 DB PVC와 platform 리소스를 유지합니다. MySQL 데이터는 남지만, EKS control plane, NAT Gateway, node group 비용은 계속 발생합니다.

비용을 더 줄이려면 service edge와 platform을 모두 내립니다. `bootstrap/state`와 `infra/dns`는 유지합니다.

권장 명령:

```sh
CONFIRM_DATA_DELETE=yes make destroy-all
```

내부 순서:

```text
1. confirm-data-delete
2. terraform destroy SERVICE_MODE=edge-monitoring
3. terraform destroy SERVICE_MODE=edge-frontend
4. terraform destroy SERVICE_MODE=edge-wallet
5. terraform destroy SERVICE_MODE=edge-woori
6. workloads-delete
7. data-delete
8. terraform destroy SERVICE_MODE=platform
```

순서가 중요한 이유:

```text
edge 스택은 platform의 shared ALB, VPC Link, EKS node ASG를 참조합니다.
platform을 먼저 지우면 edge destroy가 꼬일 수 있습니다.
DB PVC는 EBS volume을 만들 수 있으므로 platform destroy 전에 명시적으로 삭제합니다.
DNS hosted zone은 고정 도메인의 name server를 유지하기 위해 `destroy-all`에서 삭제하지 않습니다.
```

데이터 삭제 주의:

```text
CONFIRM_DATA_DELETE=yes make destroy-all은 DB PVC를 삭제합니다.
StorageClass reclaimPolicy가 Delete라서 EBS volume도 삭제됩니다.
MySQL 데이터가 필요하면 먼저 백업/snapshot을 떠야 합니다.
EKS가 아직 존재하거나 삭제 중인데 kubectl 접근이 안 되면 PVC 삭제를 완료로 보지 않고 실패합니다.
```

직접 Terraform으로 나눠서 내릴 때:

```sh
terraform -chdir=infra/edge-monitoring destroy
terraform -chdir=infra/edge-frontend destroy
terraform -chdir=infra/edge-wallet destroy
terraform -chdir=infra/edge-woori destroy
make workloads-delete
CONFIRM_DATA_DELETE=yes make data-delete
terraform -chdir=infra/platform destroy
```

destroy 전에 plan만 볼 때:

```sh
terraform -chdir=infra/edge-monitoring plan -destroy
terraform -chdir=infra/edge-frontend plan -destroy
terraform -chdir=infra/edge-wallet plan -destroy
terraform -chdir=infra/edge-woori plan -destroy
terraform -chdir=infra/platform plan -destroy
```

`destroy-all`은 project Terraform 리소스와 Kubernetes workload/PVC를 대상으로 합니다. `dns` hosted zone은 항상 유지합니다. AWS 계정의 default VPC/default subnet은 이 프로젝트가 만든 리소스가 아니므로 삭제하지 않습니다. 프로젝트 destroy 후 default VPC가 남아 있어도 NAT Gateway, EKS, ALB, API Gateway, EIP 같은 주요 과금 리소스가 없으면 이 프로젝트 비용은 사실상 내려간 상태로 봅니다.

DNS hosted zone을 정말 삭제해야 할 때만 별도 타깃을 사용합니다.

```sh
CONFIRM_DNS_DELETE=yes make destroy-dns
```

이 명령은 비용 절감용 종료 절차가 아닙니다. Route53 hosted zone은 EKS control plane, NAT Gateway, node group보다 비용이 작고, hosted zone을 삭제했다가 다시 만들면 Route53 name server 4개가 바뀔 수 있습니다. name server가 바뀌면 외부 도메인 구매처에 NS 4개를 다시 등록해야 합니다.

## 13. 재기동 절차

가장 단순한 재기동:

```sh
make init SERVICE_MODE=platform
make init SERVICE_MODE=edge-frontend
make init SERVICE_MODE=edge-woori
make init SERVICE_MODE=edge-wallet
make init SERVICE_MODE=edge-monitoring
make apply-all
```

재기동 후 확인:

```sh
kubectl get pods -A
kubectl get applications -n argocd
make output SERVICE_MODE=edge-frontend
make output SERVICE_MODE=edge-wallet
make output SERVICE_MODE=edge-woori
curl -i "$(terraform -chdir=infra/edge-frontend output -raw frontend_url)"
curl -i "$(terraform -chdir=infra/edge-wallet output -raw docs_url)"
curl -i "$(terraform -chdir=infra/edge-woori output -raw docs_url)"
```

주의:

```text
platform까지 destroy 후 다시 apply하면 API Gateway ID와 기본 endpoint URL이 바뀔 수 있습니다.
고정 URL이 필요하면 Route53 custom domain을 사용합니다.
```

## 14. Custom Domain

서비스별 서브도메인은 기본값으로 켜져 있습니다. `platform`까지 destroy 후 다시 apply해도 API Gateway 기본 endpoint는 바뀔 수 있지만, 아래 Route53 custom domain은 같은 주소를 유지합니다.

| 서비스 | Terraform stack | 고정 URL |
| --- | --- | --- |
| frontend | `edge-frontend` | `https://frontend.dannis.cloud` |
| woori-backend | `edge-woori` | `https://woori-api.dannis.cloud` |
| wallet-backend | `edge-wallet` | `https://wallet-api.dannis.cloud` |
| Grafana | `edge-monitoring` | `https://grafana.dannis.cloud` |

```hcl
# infra/edge-wallet/variables.tf
custom_domain_name = "wallet-api.dannis.cloud"
route53_zone_name  = "dannis.cloud"

# infra/edge-woori/variables.tf
custom_domain_name = "woori-api.dannis.cloud"
route53_zone_name  = "dannis.cloud"

# infra/edge-frontend/variables.tf
custom_domain_name = "frontend.dannis.cloud"
route53_zone_name  = "dannis.cloud"

# infra/edge-monitoring/variables.tf
custom_domain_name = "grafana.dannis.cloud"
route53_zone_name  = "dannis.cloud"
```

Terraform이 관리하는 리소스:

```text
ACM certificate
ACM DNS validation record
API Gateway custom domain
API Gateway API mapping
Route53 A alias record
```

전제 조건:

```text
infra/dns 스택이 dannis.cloud public Route53 hosted zone을 생성합니다.
외부 등록기관에서 산 도메인이라면 NS record를 Route53 hosted zone의 name server로 위임해야 합니다.
외부 도메인 구매처에는 A record가 아니라 make output SERVICE_MODE=dns에 나오는 Route53 name server 4개를 등록합니다.
infra/dns state가 없거나 zone_id가 비어 있으면 edge apply 단계에서 DNS remote state 조회가 실패합니다.
apply-all은 platform 비용 리소스 생성 전에 dns apply, make route53-zone-check, make route53-delegation-check를 먼저 실행합니다.
make output SERVICE_MODE=dns로 Route53 name server를 확인합니다.
edge 스택은 Route53 hosted zone 이름 조회 대신 infra/dns remote state의 zone_id를 사용합니다.
edge 스택을 개별 apply할 때도 Makefile의 apply target이 route53-zone-check와 route53-delegation-check를 먼저 실행합니다.
custom domain을 임시로 끈 edge apply만 필요하면 EDGE_CUSTOM_DOMAIN_ENABLED=no를 명시합니다.
dig가 없는 환경에서는 NS 위임 검사를 실패시킵니다.
```

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

Grafana public edge는 Lambda authorizer IP allowlist를 사용합니다.

```hcl
admin_allowed_cidrs = ["관리자-또는-VPN-공인IP/32"]
```

주의:

```text
HTTP API Gateway route는 한 route에 하나의 authorizer만 연결할 수 있습니다.
현재 service-edge module에서는 IP allowlist가 설정되면 Lambda REQUEST authorizer가 우선 적용되고 JWT authorizer는 꺼집니다.
즉 IP allowlist와 JWT authorizer를 동시에 같은 route에 걸지는 않습니다.
```

## 16. 비용 관련 결정사항

비용 절감을 위해 선택한 것:

```text
RDS 대신 EKS 내부 MySQL pod 사용
AWS Managed Prometheus/Grafana 대신 EKS 내부 kube-prometheus-stack 사용
NAT Gateway는 1개만 사용
app replica는 1개 유지
Grafana public edge는 apply-all/stop-all/destroy-all에 포함하되 관리자 IP allowlist로 제한
Prometheus PVC disabled
Grafana persistence disabled
```

비용과 안정성 trade-off:

```text
DB pod는 저렴하지만 backup/restore 책임이 커집니다.
NAT 1개는 저렴하지만 AZ 장애에 약합니다.
replica 1개는 저렴하지만 pod 장애에 약합니다.
node 2대는 Argo CD/모니터링/앱/DB를 같이 올리기 위한 최소 여유입니다.
node type은 `t3.medium`을 기본값으로 둡니다. `t3.small`은 더 저렴하지만 현재 전체 스택에서는 메모리와 pod 수가 부족할 수 있습니다.
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

### `db-secret` 또는 `ssm-parameters-check` 실패

필수 SSM Parameter가 없거나 권한이 부족한 상태입니다.

확인:

```sh
make ssm-parameters-check
```

누락된 값을 테스트용 랜덤값으로 만들 때:

```sh
CREATE_MISSING_SSM_PARAMETERS=yes make ssm-parameters-bootstrap
```

운영 비밀번호가 정해져 있으면 AWS 콘솔 또는 AWS CLI로 직접 SecureString을 만듭니다. 이미 PVC가 존재하는 DB의 경우 SSM 값을 바꿔도 MySQL 내부 사용자 비밀번호가 자동으로 바뀌지는 않습니다.

### Argo CD Application이 `authentication required` 또는 `Repository not found`

infra repo가 private인데 Argo CD repository credential이 없거나 token 권한이 부족한 상태입니다.

확인:

```sh
make ssm-parameters-check
make argocd-repo-token-check
make argocd-repo-secret
kubectl -n argocd get secret woori-wallet-infra-repo
kubectl get applications -n argocd
```

`/woori-wallet/prod/argocd-infra-repo-token`에는 infra repo를 읽을 수 있는 GitHub token을 SecureString으로 넣습니다. 앱 repo CI가 infra repo에 push할 때 쓰는 `INFRA_REPO_TOKEN`은 read/write 권한이고, Argo CD token은 read 권한으로 분리하는 것을 권장합니다.

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
terraform -chdir=infra/edge-frontend validate
terraform -chdir=infra/edge-woori validate
terraform -chdir=infra/edge-wallet validate
terraform -chdir=infra/edge-monitoring validate
kubectl kustomize apps
kubectl kustomize addons/monitoring
git diff --check
```

실제 AWS apply/destroy는 비용과 리소스 영향이 있으므로 명시 요청이 있을 때만 실행합니다.

현재 로컬에서 Terraform provider plugin handshake 문제가 발생할 수 있습니다. 이 경우 `terraform validate`가 코드 문제가 아니라 provider schema 로딩 단계에서 실패할 수 있으므로, `terraform init -reconfigure` 후 다시 확인합니다.
