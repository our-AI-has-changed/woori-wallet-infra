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
