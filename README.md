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

## API 진입 구조

모바일 앱은 서비스별 public API Gateway로 접근하고, EKS 서비스는 internal NLB 뒤에 둡니다.

```text
Mobile App
  -> Service API Gateway
  -> VPC Link
  -> Internal NLB
  -> EKS Service
  -> Pod
```

서비스별 진입점:

```text
wallet API Gateway -> wallet-api
woori API Gateway  -> woori-api
```

각 Gateway는 `$default` route로 자기 backend에 연결됩니다. 예를 들어 wallet Gateway의 `/docs` 요청은 backend pod의 `/docs`로 그대로 전달되고, `/openapi.json`도 같은 Gateway 루트에서 처리됩니다.

Route53 hosted zone이 있으면 서비스별 custom domain을 붙일 수 있습니다.

```hcl
# services/wallet/terraform.tfvars
custom_domain_name = "wallet-api.example.com"
route53_zone_name  = "example.com"

# services/woori/terraform.tfvars
custom_domain_name = "woori-api.example.com"
route53_zone_name  = "example.com"
```

이 설정을 넣으면 ACM DNS 검증, API Gateway custom domain, Route53 alias record를 서비스 스택에서 함께 관리합니다.

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
