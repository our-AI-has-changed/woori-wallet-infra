output "name_prefix" {
  description = "Common name prefix for monitoring edge resources."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Common tags applied to monitoring edge resources."
  value       = local.common_tags
}

output "service_name" {
  description = "Logical service name for Grafana traffic."
  value       = "grafana"
}

output "load_balancer_hostname" {
  description = "Shared internal ALB hostname used by monitoring edge routing."
  value       = data.terraform_remote_state.platform.outputs.shared_alb_dns_name
}

output "target_group_arn" {
  description = "ALB target group ARN for Grafana."
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
  description = "HTTP API Gateway ID for Grafana."
  value       = module.edge.api_gateway_id
}

output "api_gateway_endpoint" {
  description = "HTTP API Gateway endpoint for Grafana."
  value       = module.edge.api_gateway_endpoint
}

output "grafana_url" {
  description = "Public Grafana URL through API Gateway."
  value       = module.edge.api_gateway_endpoint
}

output "custom_domain_name" {
  description = "Custom domain name for Grafana, when enabled."
  value       = module.edge.custom_domain_name
}

output "custom_domain_grafana_url" {
  description = "Grafana URL on the custom domain, when enabled."
  value       = var.custom_domain_name != null ? "https://${var.custom_domain_name}" : null
}

output "waf_web_acl_arn" {
  description = "Deprecated compatibility output. Grafana IP allowlisting is enforced by API Gateway Lambda authorizer."
  value       = module.edge.waf_web_acl_arn
}

output "ip_authorizer_function_name" {
  description = "Lambda authorizer function name enforcing Grafana IP allowlisting."
  value       = module.edge.ip_authorizer_function_name
}

output "api_route" {
  description = "API Gateway route path for Grafana."
  value       = module.edge.api_route
}
