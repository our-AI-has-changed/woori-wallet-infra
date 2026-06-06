terraform {
  backend "s3" {
    bucket       = "woori-wallet-tfstate-655700895912-apne2"
    key          = "prd/platform/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

