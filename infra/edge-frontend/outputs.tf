output "name_prefix" {
  description = "Common name prefix for frontend edge resources."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Common tags applied to frontend edge resources."
  value       = local.common_tags
}

output "service_name" {
  description = "Logical service name for frontend traffic."
  value       = "frontend"
}

output "load_balancer_hostname" {
  description = "Shared internal ALB hostname used by frontend edge routing."
  value       = data.terraform_remote_state.platform.outputs.shared_alb_dns_name
}

output "target_group_arn" {
  description = "ALB target group ARN for frontend."
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
  description = "HTTP API Gateway ID for frontend."
  value       = module.edge.api_gateway_id
}

output "api_gateway_endpoint" {
  description = "HTTP API Gateway endpoint for frontend."
  value       = module.edge.api_gateway_endpoint
}

output "frontend_url" {
  description = "Public frontend URL through API Gateway."
  value       = module.edge.api_gateway_endpoint
}

output "custom_domain_name" {
  description = "Custom domain name for frontend, when enabled."
  value       = module.edge.custom_domain_name
}

output "custom_domain_frontend_url" {
  description = "Frontend URL on the custom domain, when enabled."
  value       = var.custom_domain_name != null ? "https://${var.custom_domain_name}" : null
}

output "api_route" {
  description = "API Gateway route path for frontend."
  value       = module.edge.api_route
}
