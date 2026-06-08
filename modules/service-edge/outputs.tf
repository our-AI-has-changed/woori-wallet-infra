output "api_gateway_id" {
  description = "HTTP API Gateway ID."
  value       = aws_apigatewayv2_api.this.id
}

output "api_gateway_endpoint" {
  description = "HTTP API Gateway endpoint."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "docs_url" {
  description = "Swagger UI URL for the service."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/docs"
}

output "target_group_arn" {
  description = "ALB target group ARN for the service."
  value       = aws_lb_target_group.this.arn
}

output "custom_domain_name" {
  description = "Custom domain name for the service, when enabled."
  value       = try(aws_apigatewayv2_domain_name.this[0].domain_name, null)
}

output "custom_domain_docs_url" {
  description = "Swagger UI URL on the service custom domain, when enabled."
  value       = try("https://${aws_apigatewayv2_domain_name.this[0].domain_name}/docs", null)
}

output "api_route" {
  description = "API Gateway route path for the service."
  value       = "$default"
}

output "waf_web_acl_arn" {
  description = "AWS WAF web ACL ARN associated with the HTTP API stage, when enabled."
  value       = try(aws_wafv2_web_acl.this[0].arn, null)
}
