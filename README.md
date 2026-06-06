# woori-wallet-infra

Woori Wallet 인프라를 관리하는 Terraform 저장소입니다.

## 요구사항

- Terraform 1.15.5
- 로컬 AWS credential 설정

## 구조

```text
.
├── Makefile
├── bootstrap
│   └── state
│       ├── main.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       └── versions.tf
├── modules
│   └── README.md
├── services
│   ├── platform
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── terraform.tfvars.example
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── wallet
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── terraform.tfvars.example
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── woori
│       ├── backend.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       └── versions.tf
```

## 서비스

- `STACK_MODE=state`: Terraform state S3 bucket bootstrap
- `SERVICE_MODE=platform`: 공통 VPC/EKS 플랫폼
- `SERVICE_MODE=woori`: 우리 인증/사용자 서비스
- `SERVICE_MODE=wallet`: 지갑/소비재판 서비스

## 시작하기

먼저 Terraform state를 저장할 S3 bucket을 만듭니다.

```sh
make init STACK_MODE=state
make plan STACK_MODE=state
make apply STACK_MODE=state
```

그 다음 공통 EKS 플랫폼을 만듭니다.

```sh
make init SERVICE_MODE=platform
make plan SERVICE_MODE=platform
make apply SERVICE_MODE=platform
```

마지막으로 서비스별 Kubernetes 리소스를 배포합니다.

```sh
make init SERVICE_MODE=woori
make validate SERVICE_MODE=woori
make plan SERVICE_MODE=woori
make apply SERVICE_MODE=woori
```

다른 서비스를 실행하려면 `SERVICE_MODE` 값을 바꿉니다.

```sh
make init SERVICE_MODE=wallet
make plan SERVICE_MODE=wallet
make apply SERVICE_MODE=wallet
```

전체 포맷은 루트에서 실행합니다.

```sh
make fmt
```

서비스별 값을 바꾸려면 예시 파일을 복사해서 로컬 `terraform.tfvars`를 만듭니다.

```sh
cp bootstrap/state/terraform.tfvars.example bootstrap/state/terraform.tfvars
cp services/platform/terraform.tfvars.example services/platform/terraform.tfvars
cp services/woori/terraform.tfvars.example services/woori/terraform.tfvars
cp services/wallet/terraform.tfvars.example services/wallet/terraform.tfvars
```

`terraform.tfvars` 파일은 로컬 값이나 비밀값을 포함할 수 있으므로 git에 커밋하지 않습니다.

## State

`bootstrap/state`만 local backend로 시작하고, 나머지 스택은 S3 backend를 사용합니다.

기본 state bucket:

```text
woori-wallet-tfstate-655700895912-apne2
```

state key:

```text
prd/platform/terraform.tfstate
prd/woori/terraform.tfstate
prd/wallet/terraform.tfstate
```
