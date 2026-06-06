variable "aws_region" {
  description = "AWS region for woori service resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "woori-wallet"
}

variable "service" {
  description = "Service name used for resource naming and tagging."
  type        = string
  default     = "woori"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prd"
}

variable "name_prefix" {
  description = "Common name prefix for woori service resources."
  type        = string
  default     = "woori-auth-prd"
}

variable "tags" {
  description = "Additional tags to apply to all supported AWS resources."
  type        = map(string)
  default     = {}
}
