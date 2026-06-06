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

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.platform.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.platform.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
