variable "aws_region" {
  description = "AWS region for wallet service resources."
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
  default     = "wallet"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prd"
}

variable "name_prefix" {
  description = "Common name prefix for wallet service resources."
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

variable "namespace" {
  description = "Kubernetes namespace for the service."
  type        = string
  default     = "wallet"
}

variable "app_name" {
  description = "Kubernetes app name."
  type        = string
  default     = "wallet-api"
}

variable "route_path" {
  description = "Deprecated. Services now use dedicated API Gateways with a root $default route."
  type        = string
  default     = "wallet"
}

variable "load_balancer_name" {
  description = "Internal NLB name created for the Kubernetes service."
  type        = string
  default     = "wallet-api-prd"
}

variable "load_balancer_target_type" {
  description = "NLB target type for the Kubernetes LoadBalancer. Use ip only after installing/configuring AWS Load Balancer Controller support."
  type        = string
  default     = "instance"

  validation {
    condition     = contains(["instance", "ip"], var.load_balancer_target_type)
    error_message = "load_balancer_target_type must be either instance or ip."
  }
}

variable "custom_domain_name" {
  description = "Optional custom domain name for this service API Gateway, for example wallet-api.example.com."
  type        = string
  default     = null
}

variable "route53_zone_name" {
  description = "Optional public Route53 hosted zone name used to validate and point the custom domain, for example example.com."
  type        = string
  default     = null
}

variable "image_repository" {
  description = "ECR image repository URI."
  type        = string
  default     = "655700895912.dkr.ecr.ap-northeast-2.amazonaws.com/our-ai-has-changed/woori-wallet-trial"
}

variable "image_tag" {
  description = "Container image tag."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Container HTTP port."
  type        = number
  default     = 8000
}

variable "service_port" {
  description = "Kubernetes Service port."
  type        = number
  default     = 80
}

variable "api_throttling_burst_limit" {
  description = "Default API Gateway throttling burst limit for this service."
  type        = number
  default     = 100
}

variable "api_throttling_rate_limit" {
  description = "Default API Gateway throttling steady-state request rate per second for this service."
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

variable "replicas" {
  description = "Deployment replica count."
  type        = number
  default     = 1
}

variable "health_check_path" {
  description = "HTTP health check path for readiness and liveness probes."
  type        = string
  default     = "/docs"
}

variable "environment_variables" {
  description = "Additional non-secret environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "service_annotations" {
  description = "Additional annotations for the Kubernetes LoadBalancer Service."
  type        = map(string)
  default     = {}
}

variable "cpu_request" {
  description = "Container CPU request."
  type        = string
  default     = "100m"
}

variable "memory_request" {
  description = "Container memory request."
  type        = string
  default     = "128Mi"
}

variable "cpu_limit" {
  description = "Container CPU limit."
  type        = string
  default     = "500m"
}

variable "memory_limit" {
  description = "Container memory limit."
  type        = string
  default     = "512Mi"
}
