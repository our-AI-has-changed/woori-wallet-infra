locals {
  name_prefix = var.name_prefix
  app_labels = {
    app     = var.service
    project = var.project
  }
  custom_domain_enabled = var.custom_domain_name != null && var.route53_zone_name != null

  common_tags = merge(
    {
      Project     = var.project
      Service     = var.service
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      app     = var.service
      project = var.project
    }
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.app_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.app_labels
    }

    template {
      metadata {
        labels = local.app_labels
      }

      spec {
        container {
          name  = var.app_name
          image = "${var.image_repository}:${var.image_tag}"

          port {
            name           = "http"
            container_port = var.container_port
          }

          env {
            name  = "SERVICE_MODE"
            value = var.service
          }

          dynamic "env" {
            for_each = var.environment_variables

            content {
              name  = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }

            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          readiness_probe {
            http_get {
              path = var.health_check_path
              port = var.container_port
            }

            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = var.health_check_path
              port = var.container_port
            }

            initial_delay_seconds = 30
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.app_labels
    annotations = merge(
      {
        "service.beta.kubernetes.io/aws-load-balancer-type"     = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"   = "internal"
        "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
        "service.beta.kubernetes.io/aws-load-balancer-name"     = var.load_balancer_name
        "service.beta.kubernetes.io/aws-load-balancer-subnets"  = join(",", data.terraform_remote_state.platform.outputs.private_subnet_ids)
      },
      var.service_annotations
    )
  }

  spec {
    type     = "LoadBalancer"
    selector = local.app_labels

    port {
      name        = "http"
      port        = var.service_port
      target_port = var.container_port
      protocol    = "TCP"
    }
  }
}

data "aws_lbs" "this" {
  tags = {
    "kubernetes.io/service-name" = "${var.namespace}/${var.app_name}"
  }

  depends_on = [kubernetes_service_v1.this]
}

data "aws_lb" "this" {
  arn = one(data.aws_lbs.this.arns)
}

data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.this.arn
  port              = var.service_port
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name_prefix}-${var.service}-api"
  protocol_type = "HTTP"

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}

data "aws_route53_zone" "custom_domain" {
  count = local.custom_domain_enabled ? 1 : 0

  name         = trimsuffix(var.route53_zone_name, ".")
  private_zone = false
}

resource "aws_acm_certificate" "custom_domain" {
  count = local.custom_domain_enabled ? 1 : 0

  domain_name       = var.custom_domain_name
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "custom_domain_validation" {
  for_each = local.custom_domain_enabled ? {
    for option in aws_acm_certificate.custom_domain[0].domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.custom_domain[0].zone_id
}

resource "aws_acm_certificate_validation" "custom_domain" {
  count = local.custom_domain_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.custom_domain[0].arn
  validation_record_fqdns = [for record in aws_route53_record.custom_domain_validation : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "this" {
  count = local.custom_domain_enabled ? 1 : 0

  domain_name = var.custom_domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.custom_domain[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count = local.custom_domain_enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this[0].domain_name
  stage       = aws_apigatewayv2_stage.default.name
}

resource "aws_route53_record" "custom_domain" {
  count = local.custom_domain_enabled ? 1 : 0

  name    = var.custom_domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.custom_domain[0].zone_id

  alias {
    evaluate_target_health = false
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
  }
}

resource "aws_apigatewayv2_integration" "this" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = data.aws_lb_listener.http.arn
  connection_type        = "VPC_LINK"
  connection_id          = data.terraform_remote_state.platform.outputs.api_gateway_vpc_link_id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "this" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}
