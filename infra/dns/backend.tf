terraform {
  backend "s3" {
    bucket       = "woori-wallet-tfstate-655700895912-apne2"
    key          = "prd/dns/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
