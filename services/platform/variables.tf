variable "aws_region" {
  description = "AWS region for platform resources."
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

variable "name_prefix" {
  description = "Common name prefix for platform resources."
  type        = string
  default     = "woori-wallet-prd"
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Leave null to use the AWS default version."
  type        = string
  default     = null
}

variable "cluster_endpoint_private_access" {
  description = "Whether the EKS API server endpoint is reachable from inside the VPC."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable from the public internet."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to access the public EKS API server endpoint. Restrict this to admin/VPN IPs for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_disk_size" {
  description = "Disk size in GiB for managed node group instances."
  type        = number
  default     = 20
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Additional tags to apply to all supported AWS resources."
  type        = map(string)
  default     = {}
}
