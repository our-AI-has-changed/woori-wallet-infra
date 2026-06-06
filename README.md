# woori-wallet-infra

Terraform infrastructure for Woori Wallet.

## Requirements

- Terraform 1.15.5
- AWS credentials configured locally

## Layout

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

## Services

- `SERVICE_MODE=woori`: 우리 인증/사용자 서비스
- `SERVICE_MODE=wallet`: 지갑/소비재판 서비스

## Getting Started

```sh
make init SERVICE_MODE=woori
make fmt
make validate SERVICE_MODE=woori
make plan SERVICE_MODE=woori
```

Switch services by changing `SERVICE_MODE`.

```sh
make plan SERVICE_MODE=wallet
```

Create a local `terraform.tfvars` from the service example before planning with service-specific values.

```sh
cp services/woori/terraform.tfvars.example services/woori/terraform.tfvars
cp services/wallet/terraform.tfvars.example services/wallet/terraform.tfvars
```

`terraform.tfvars` files are intentionally ignored by git because they can contain local or secret values.

## State

Each service currently starts with its own local Terraform backend.
Before applying shared production infrastructure, migrate state to a remote backend such as S3 with DynamoDB locking.
