output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded EKS cluster certificate authority data."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "api_gateway_vpc_link_id" {
  description = "API Gateway VPC Link ID."
  value       = aws_apigatewayv2_vpc_link.this.id
}

output "shared_alb_arn" {
  description = "ARN of the shared internal ALB."
  value       = aws_lb.shared_internal.arn
}

output "shared_alb_dns_name" {
  description = "DNS name of the shared internal ALB."
  value       = aws_lb.shared_internal.dns_name
}

output "shared_alb_zone_id" {
  description = "Hosted zone ID of the shared internal ALB."
  value       = aws_lb.shared_internal.zone_id
}

output "shared_alb_listener_arn" {
  description = "ARN of the shared internal ALB HTTP listener."
  value       = aws_lb_listener.shared_http.arn
}

output "node_group_autoscaling_group_names" {
  description = "Autoscaling group names backing the EKS managed node group."
  value       = [for group in aws_eks_node_group.this.resources[0].autoscaling_groups : group.name]
}

output "external_secrets_irsa_role_arn" {
  description = "IAM role ARN used by the External Secrets Operator service account."
  value       = try(aws_iam_role.external_secrets[0].arn, "")
}
