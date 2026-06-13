variable "aws_region" {
  description = "AWS region for monitoring edge resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "woori-wallet"
}

variable "service" {
  description = "Service name used for naming and tagging."
  type        = string
  default     = "monitoring"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prd"
}

variable "name_prefix" {
  description = "Common name prefix for monitoring edge resources."
  type        = string
  default     = "woori-wallet-prd"
}

variable "tags" {
  description = "Additional tags to apply to all supported AWS resources."
  type        = map(string)
  default     = {}
}

variable "state_bucket_name" {
  description = "S3 bucket name used for Terraform remote state."
  type        = string
  default     = "woori-wallet-tfstate-655700895912-apne2"
}

variable "node_port" {
  description = "Fixed Grafana Kubernetes NodePort reached by the shared internal ALB."
  type        = number
  default     = 30082
}

variable "target_group_name" {
  description = "ALB target group name for Grafana."
  type        = string
  default     = "grafana-prd-tg"
}

variable "alb_host_header" {
  description = "Internal Host header used by API Gateway and the shared ALB listener rule to route to Grafana."
  type        = string
  default     = "grafana.internal"
}

variable "alb_listener_rule_priority" {
  description = "Priority for Grafana rule on the shared ALB listener."
  type        = number
  default     = 120
}

variable "blocked_paths" {
  description = "External Grafana paths blocked at the shared ALB before forwarding."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "HTTP health check path for Grafana."
  type        = string
  default     = "/api/health"
}

variable "health_check_matcher" {
  description = "HTTP status matcher for the Grafana target group health check."
  type        = string
  default     = "200-399"
}

variable "api_throttling_burst_limit" {
  description = "Default API Gateway throttling burst limit for Grafana."
  type        = number
  default     = 20
}

variable "api_throttling_rate_limit" {
  description = "Default API Gateway throttling steady-state request rate per second for Grafana."
  type        = number
  default     = 5
}

variable "api_stage_name" {
  description = "API Gateway stage name for Grafana."
  type        = string
  default     = "prod"
}

variable "admin_allowed_cidrs" {
  description = "IPv4 CIDR allowlist for public Grafana access. Replace the documentation-only default with an administrator or VPN public IP CIDR before use."
  type        = list(string)
  default     = ["203.0.113.10/32"]
}

variable "jwt_issuer" {
  description = "Optional JWT issuer URL for API Gateway authorization. Leave null to disable gateway-level JWT auth."
  type        = string
  default     = null
}

variable "jwt_audience" {
  description = "Optional JWT audiences for API Gateway authorization. Set with jwt_issuer to enable gateway-level JWT auth."
  type        = list(string)
  default     = []
}

variable "custom_domain_name" {
  description = "Custom domain name for Grafana."
  type        = string
  default     = "grafana.dannis.cloud"
}

variable "route53_zone_name" {
  description = "Public Route53 hosted zone name used to validate and point the custom domain."
  type        = string
  default     = "dannis.cloud"
}
