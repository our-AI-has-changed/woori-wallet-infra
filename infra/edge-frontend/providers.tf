provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket  = var.state_bucket_name
    key     = "prd/platform/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
  }
}

data "terraform_remote_state" "dns" {
  count = local.custom_domain_enabled ? 1 : 0

  backend = "s3"

  config = {
    bucket  = var.state_bucket_name
    key     = "prd/dns/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
  }
}
