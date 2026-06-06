# woori-wallet-infra

Woori Wallet 인프라를 관리하는 Terraform 저장소입니다.

## 요구사항

- Terraform 1.15.5
- 로컬 AWS credential 설정

## 구조

```text
.
├── Makefile
├── modules
│   └── README.md
├── services
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

- `SERVICE_MODE=woori`: 우리 인증/사용자 서비스
- `SERVICE_MODE=wallet`: 지갑/소비재판 서비스

## 시작하기

```sh
make init SERVICE_MODE=woori
make fmt
make validate SERVICE_MODE=woori
make plan SERVICE_MODE=woori
```

다른 서비스를 실행하려면 `SERVICE_MODE` 값을 바꿉니다.

```sh
make plan SERVICE_MODE=wallet
```

서비스별 값을 넣기 전에 예시 파일을 복사해서 로컬 `terraform.tfvars`를 만듭니다.

```sh
cp services/woori/terraform.tfvars.example services/woori/terraform.tfvars
cp services/wallet/terraform.tfvars.example services/wallet/terraform.tfvars
```

`terraform.tfvars` 파일은 로컬 값이나 비밀값을 포함할 수 있으므로 git에 커밋하지 않습니다.

## State

현재 각 서비스는 독립적인 local backend로 시작합니다.
운영 인프라를 실제로 적용하기 전에는 S3 backend와 DynamoDB locking 같은 remote state 구성으로 이전하는 것을 권장합니다.
