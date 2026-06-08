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
  default     = "1.33"
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
  default     = 2
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 2
}

variable "enable_ebs_csi_driver" {
  description = "Whether to install the AWS EBS CSI driver add-on for Kubernetes PVC-backed workloads such as in-cluster MySQL."
  type        = bool
  default     = true
}

variable "ebs_csi_driver_addon_version" {
  description = "Pinned EKS add-on version for the AWS EBS CSI driver. Must be compatible with cluster_version."
  type        = string
  default     = "v1.61.1-eksbuild.1"
}

variable "shared_alb_name" {
  description = "Name of the shared internal ALB used by service API Gateways."
  type        = string
  default     = "woori-wallet-prd-api-alb"
}

variable "shared_alb_deletion_protection" {
  description = "Whether deletion protection is enabled for the shared internal ALB."
  type        = bool
  default     = false
}

variable "shared_alb_node_port_min" {
  description = "Lowest Kubernetes NodePort that the shared ALB may reach."
  type        = number
  default     = 30080
}

variable "shared_alb_node_port_max" {
  description = "Highest Kubernetes NodePort that the shared ALB may reach."
  type        = number
  default     = 30089
}

variable "tags" {
  description = "Additional tags to apply to all supported AWS resources."
  type        = map(string)
  default     = {}
}
