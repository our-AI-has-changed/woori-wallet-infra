output "name_prefix" {
  description = "Common name prefix for woori prd resources."
  value       = local.name_prefix
}

output "common_tags" {
  description = "Common tags applied to woori prd resources."
  value       = local.common_tags
}

output "namespace" {
  description = "Kubernetes namespace for the woori service."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "service_name" {
  description = "Kubernetes Service name for the woori service."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "load_balancer_hostname" {
  description = "Load balancer hostname for the woori service."
  value       = try(kubernetes_service_v1.this.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "api_gateway_id" {
  description = "HTTP API Gateway ID for the woori service."
  value       = aws_apigatewayv2_api.this.id
}

output "api_gateway_endpoint" {
  description = "HTTP API Gateway endpoint for the woori service."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "docs_url" {
  description = "Swagger UI URL for the woori service."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/docs"
}

output "custom_domain_name" {
  description = "Custom domain name for the woori service, when enabled."
  value       = try(aws_apigatewayv2_domain_name.this[0].domain_name, null)
}

output "custom_domain_docs_url" {
  description = "Swagger UI URL on the woori custom domain, when enabled."
  value       = try("https://${aws_apigatewayv2_domain_name.this[0].domain_name}/docs", null)
}

output "api_route" {
  description = "API Gateway route path for the woori service."
  value       = "$default"
}
