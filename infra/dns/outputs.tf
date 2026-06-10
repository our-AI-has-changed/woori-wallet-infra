output "zone_id" {
  description = "Route53 public hosted zone ID."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Route53 public hosted zone name."
  value       = aws_route53_zone.this.name
}

output "name_servers" {
  description = "Name servers to configure at the domain registrar."
  value       = aws_route53_zone.this.name_servers
}
