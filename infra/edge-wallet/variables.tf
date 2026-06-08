variable "aws_region" {
  description = "AWS region for wallet edge resources."
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
  default     = "wallet"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prd"
}

variable "name_prefix" {
  description = "Common name prefix for wallet edge resources."
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
  description = "Fixed Kubernetes NodePort reached by the shared internal ALB."
  type        = number
  default     = 30080
}

variable "target_group_name" {
  description = "ALB target group name for the wallet backend."
  type        = string
  default     = "wallet-backend-prd-tg"
}

variable "alb_host_header" {
  description = "Internal Host header used by API Gateway and the shared ALB listener rule to route to wallet backend."
  type        = string
  default     = "wallet.internal"
}

variable "alb_listener_rule_priority" {
  description = "Priority for wallet rule on the shared ALB listener."
  type        = number
  default     = 100
}

variable "blocked_paths" {
  description = "External wallet paths blocked at the shared ALB before forwarding to the backend."
  type        = list(string)
  default     = ["/metrics", "/metrics/*"]
}

variable "health_check_path" {
  description = "HTTP health check path for the wallet backend target group."
  type        = string
  default     = "/api/health"
}

variable "health_check_matcher" {
  description = "HTTP status matcher for the wallet backend target group health check."
  type        = string
  default     = "200-399"
}

variable "api_throttling_burst_limit" {
  description = "Default API Gateway throttling burst limit for wallet."
  type        = number
  default     = 100
}

variable "api_throttling_rate_limit" {
  description = "Default API Gateway throttling steady-state request rate per second for wallet."
  type        = number
  default     = 50
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
  description = "Optional custom domain name for the wallet API Gateway, for example wallet-api.example.com."
  type        = string
  default     = null
}

variable "route53_zone_name" {
  description = "Optional public Route53 hosted zone name used to validate and point the custom domain, for example example.com."
  type        = string
  default     = null
}
