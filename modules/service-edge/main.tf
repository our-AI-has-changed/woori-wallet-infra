locals {
  custom_domain_enabled       = var.custom_domain_name != null && (var.route53_zone_id != null || var.route53_zone_name != null)
  custom_domain_zone_id       = local.custom_domain_enabled ? (var.route53_zone_id != null ? var.route53_zone_id : data.aws_route53_zone.custom_domain[0].zone_id) : null
  ip_authorizer_enabled       = length(var.allowed_source_cidrs) > 0
  jwt_authorizer_enabled      = !local.ip_authorizer_enabled && var.jwt_issuer != null && length(var.jwt_audience) > 0
  ip_authorizer_function_name = substr(replace("${var.name_prefix}-${var.service}-ip-authorizer", "/[^a-zA-Z0-9-_]/", "-"), 0, 64)
  blocked_paths               = distinct(var.blocked_paths)
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-${var.service}-api"
  protocol_type = "HTTP"

  tags = var.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.api_stage_name
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_throttling_burst_limit
    throttling_rate_limit  = var.api_throttling_rate_limit
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  count = local.jwt_authorizer_enabled ? 1 : 0

  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name_prefix}-${var.service}-jwt"

  jwt_configuration {
    audience = var.jwt_audience
    issuer   = var.jwt_issuer
  }
}

data "archive_file" "ip_authorizer" {
  count = local.ip_authorizer_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/ip_authorizer.py"
  output_path = "${path.root}/.terraform/${local.ip_authorizer_function_name}.zip"
}

resource "aws_iam_role" "ip_authorizer" {
  count = local.ip_authorizer_enabled ? 1 : 0

  name = local.ip_authorizer_function_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ip_authorizer_basic" {
  count = local.ip_authorizer_enabled ? 1 : 0

  role       = aws_iam_role.ip_authorizer[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "ip_authorizer" {
  count = local.ip_authorizer_enabled ? 1 : 0

  name              = "/aws/lambda/${local.ip_authorizer_function_name}"
  retention_in_days = 7

  tags = var.common_tags
}

resource "aws_lambda_function" "ip_authorizer" {
  count = local.ip_authorizer_enabled ? 1 : 0

  function_name    = local.ip_authorizer_function_name
  role             = aws_iam_role.ip_authorizer[0].arn
  handler          = "ip_authorizer.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.ip_authorizer[0].output_path
  source_code_hash = data.archive_file.ip_authorizer[0].output_base64sha256
  timeout          = 3
  memory_size      = 128

  environment {
    variables = {
      ALLOWED_CIDRS = join(",", var.allowed_source_cidrs)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ip_authorizer,
    aws_iam_role_policy_attachment.ip_authorizer_basic,
  ]

  tags = var.common_tags
}

resource "aws_lambda_permission" "ip_authorizer_api_gateway" {
  count = local.ip_authorizer_enabled ? 1 : 0

  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ip_authorizer[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_apigatewayv2_authorizer" "ip" {
  count = local.ip_authorizer_enabled ? 1 : 0

  api_id                            = aws_apigatewayv2_api.this.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.ip_authorizer[0].invoke_arn
  authorizer_payload_format_version = "2.0"
  authorizer_result_ttl_in_seconds  = 0
  enable_simple_responses           = true
  name                              = "${var.name_prefix}-${var.service}-ip-allowlist"
}

data "aws_route53_zone" "custom_domain" {
  count = local.custom_domain_enabled && var.route53_zone_id == null ? 1 : 0

  name         = trimsuffix(var.route53_zone_name, ".")
  private_zone = false
}

resource "aws_acm_certificate" "custom_domain" {
  count = local.custom_domain_enabled ? 1 : 0

  domain_name       = var.custom_domain_name
  validation_method = "DNS"

  tags = var.common_tags

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
  zone_id         = local.custom_domain_zone_id
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

  tags = var.common_tags
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
  zone_id = local.custom_domain_zone_id

  alias {
    evaluate_target_health = false
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
  }
}

resource "aws_lb_target_group" "this" {
  name        = var.target_group_name
  port        = var.node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = var.health_check_matcher
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = var.common_tags
}

resource "aws_autoscaling_attachment" "this" {
  for_each = toset(var.node_group_autoscaling_group_names)

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.this.arn
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.shared_alb_listener_arn
  priority     = var.alb_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = [var.alb_host_header]
    }
  }

  tags = var.common_tags
}

resource "aws_lb_listener_rule" "blocked_paths" {
  for_each = { for index, path in local.blocked_paths : path => index }

  listener_arn = var.shared_alb_listener_arn
  priority     = var.alb_listener_rule_priority - each.value - 1

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    host_header {
      values = [var.alb_host_header]
    }
  }

  condition {
    path_pattern {
      values = [each.key]
    }
  }

  tags = var.common_tags
}

resource "aws_apigatewayv2_integration" "this" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.shared_alb_listener_arn
  connection_type        = "VPC_LINK"
  connection_id          = var.api_gateway_vpc_link_id
  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:header.host" = var.alb_host_header
  }

  depends_on = [aws_lb_listener_rule.this]
}

resource "aws_apigatewayv2_route" "this" {
  api_id             = aws_apigatewayv2_api.this.id
  authorization_type = local.ip_authorizer_enabled ? "CUSTOM" : (local.jwt_authorizer_enabled ? "JWT" : "NONE")
  authorizer_id      = local.ip_authorizer_enabled ? aws_apigatewayv2_authorizer.ip[0].id : (local.jwt_authorizer_enabled ? aws_apigatewayv2_authorizer.jwt[0].id : null)
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.this.id}"
}
