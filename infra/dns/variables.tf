variable "aws_region" {
  description = "AWS region used by Terraform."
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "Project tag value."
  type        = string
  default     = "woori-wallet"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "prd"
}

variable "zone_name" {
  description = "Public DNS zone name for stable service domains."
  type        = string
  default     = "dannis.cloud"
}

variable "tags" {
  description = "Additional tags to apply to DNS resources."
  type        = map(string)
  default     = {}
}
