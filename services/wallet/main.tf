locals {
  name_prefix = var.name_prefix
  app_labels = {
    app     = var.service
    project = var.project
  }

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
        "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internal"
        "service.beta.kubernetes.io/aws-load-balancer-name"   = var.load_balancer_name
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

data "aws_lb" "this" {
  name = var.load_balancer_name

  depends_on = [kubernetes_service_v1.this]
}

data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.this.arn
  port              = var.service_port
}

resource "aws_apigatewayv2_integration" "this" {
  api_id                 = data.terraform_remote_state.platform.outputs.api_gateway_id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = data.aws_lb_listener.http.arn
  connection_type        = "VPC_LINK"
  connection_id          = data.terraform_remote_state.platform.outputs.api_gateway_vpc_link_id
  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:path" = "/$request.path.proxy"
  }
}

resource "aws_apigatewayv2_route" "this" {
  api_id    = data.terraform_remote_state.platform.outputs.api_gateway_id
  route_key = "ANY /${var.route_path}/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}
