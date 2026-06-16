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

resource "aws_acm_certificate" "public_alb" {
  domain_name               = "*.${var.zone_name}"
  subject_alternative_names = [var.zone_name]
  validation_method         = "DNS"

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project}-${var.environment}-public-alb"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "public_alb_certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.public_alb.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.this.zone_id
}

resource "aws_acm_certificate_validation" "public_alb" {
  certificate_arn         = aws_acm_certificate.public_alb.arn
  validation_record_fqdns = [for record in aws_route53_record.public_alb_certificate_validation : record.fqdn]
}
