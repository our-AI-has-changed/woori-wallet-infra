variable "name_prefix" {
  description = "Common name prefix for service edge resources."
  type        = string
}

variable "service" {
  description = "Service name used for naming and tagging."
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
}

variable "vpc_id" {
  description = "VPC ID containing the shared ALB and EKS nodes."
  type        = string
}

variable "api_gateway_vpc_link_id" {
  description = "API Gateway VPC Link ID used for private integration."
  type        = string
}

variable "shared_alb_listener_arn" {
  description = "Shared internal ALB HTTP listener ARN."
  type        = string
}

variable "node_group_autoscaling_group_names" {
  description = "Autoscaling group names backing the EKS managed node group."
  type        = list(string)
}

variable "node_port" {
  description = "Fixed Kubernetes NodePort reached by the shared internal ALB."
  type        = number
}

variable "target_group_name" {
  description = "ALB target group name for this service."
  type        = string
}

variable "alb_host_header" {
  description = "Internal Host header used by API Gateway and the shared ALB listener rule to route to this service."
  type        = string
}

variable "alb_listener_rule_priority" {
  description = "Priority for this service rule on the shared ALB listener."
  type        = number
}

variable "blocked_paths" {
  description = "Optional external paths blocked at the shared ALB for this service host header before forwarding to the target group."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.blocked_paths) == 0 || var.alb_listener_rule_priority > length(var.blocked_paths)
    error_message = "alb_listener_rule_priority must be greater than the number of blocked_paths so higher-priority block rules can be created."
  }
}

variable "health_check_path" {
  description = "HTTP health check path for the ALB target group."
  type        = string
}

variable "health_check_matcher" {
  description = "HTTP status matcher for the ALB target group health check."
  type        = string
}

variable "api_throttling_burst_limit" {
  description = "Default API Gateway throttling burst limit for this service."
  type        = number
}

variable "api_throttling_rate_limit" {
  description = "Default API Gateway throttling steady-state request rate per second for this service."
  type        = number
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
  description = "Optional custom domain name for this service API Gateway."
  type        = string
  default     = null
}

variable "route53_zone_name" {
  description = "Optional public Route53 hosted zone name used to validate and point the custom domain."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Optional public Route53 hosted zone ID used to validate and point the custom domain. Prefer this over route53_zone_name when the zone is managed by Terraform."
  type        = string
  default     = null
}

variable "allowed_source_cidrs" {
  description = "Optional IPv4 CIDR allowlist enforced by AWS WAF on the HTTP API Gateway stage. Leave empty to skip WAF."
  type        = list(string)
  default     = []
}
