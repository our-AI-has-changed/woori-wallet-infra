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

output "api_route" {
  description = "API Gateway route path for the woori service."
  value       = "/${var.route_path}/{proxy+}"
}
