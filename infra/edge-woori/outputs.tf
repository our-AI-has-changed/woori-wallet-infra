output "name_prefix" {
  description = "Common name prefix for woori edge resources."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Common tags applied to woori edge resources."
  value       = local.common_tags
}

output "service_name" {
  description = "Logical backend service name for woori traffic."
  value       = "woori-backend"
}

output "load_balancer_hostname" {
  description = "Shared internal ALB hostname used by woori edge routing."
  value       = data.terraform_remote_state.platform.outputs.shared_alb_dns_name
}

output "target_group_arn" {
  description = "ALB target group ARN for woori backend."
  value       = module.edge.target_group_arn
}

output "node_port" {
  description = "Kubernetes NodePort reached by the shared internal ALB."
  value       = var.node_port
}

output "alb_host_header" {
  description = "Internal Host header used by API Gateway and ALB routing."
  value       = var.alb_host_header
}

output "api_gateway_id" {
  description = "HTTP API Gateway ID for woori."
  value       = module.edge.api_gateway_id
}

output "api_gateway_endpoint" {
  description = "HTTP API Gateway endpoint for woori."
  value       = module.edge.api_gateway_endpoint
}

output "docs_url" {
  description = "Swagger UI URL for woori."
  value       = module.edge.docs_url
}

output "custom_domain_name" {
  description = "Custom domain name for woori, when enabled."
  value       = module.edge.custom_domain_name
}

output "custom_domain_docs_url" {
  description = "Swagger UI URL on the woori custom domain, when enabled."
  value       = module.edge.custom_domain_docs_url
}

output "api_route" {
  description = "API Gateway route path for woori."
  value       = module.edge.api_route
}
