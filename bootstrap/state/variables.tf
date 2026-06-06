variable "aws_region" {
  description = "AWS region for Terraform state resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "Project name used for tagging."
  type        = string
  default     = "woori-wallet"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prd"
}

variable "state_bucket_name" {
  description = "S3 bucket name used for Terraform remote state."
  type        = string
  default     = "woori-wallet-tfstate-655700895912-apne2"
}

variable "tags" {
  description = "Additional tags to apply to all supported AWS resources."
  type        = map(string)
  default     = {}
}

