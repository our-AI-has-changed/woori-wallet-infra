locals {
  common_tags = merge(
    {
      Project     = var.project
      Service     = "dns"
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

resource "aws_route53_zone" "this" {
  name    = var.zone_name
  comment = "Public hosted zone for ${var.project} ${var.environment} endpoints."

  tags = local.common_tags
}
