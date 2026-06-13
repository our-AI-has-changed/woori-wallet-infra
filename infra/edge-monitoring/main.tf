locals {
  name_prefix           = var.name_prefix
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

module "edge" {
  source = "../../modules/service-edge"

  name_prefix                        = local.name_prefix
  service                            = var.service
  common_tags                        = local.common_tags
  vpc_id                             = data.terraform_remote_state.platform.outputs.vpc_id
  api_gateway_vpc_link_id            = data.terraform_remote_state.platform.outputs.api_gateway_vpc_link_id
  shared_alb_listener_arn            = data.terraform_remote_state.platform.outputs.shared_alb_listener_arn
  node_group_autoscaling_group_names = data.terraform_remote_state.platform.outputs.node_group_autoscaling_group_names
  node_port                          = var.node_port
  target_group_name                  = var.target_group_name
  alb_host_header                    = var.alb_host_header
  alb_listener_rule_priority         = var.alb_listener_rule_priority
  blocked_paths                      = var.blocked_paths
  health_check_path                  = var.health_check_path
  health_check_matcher               = var.health_check_matcher
  api_throttling_burst_limit         = var.api_throttling_burst_limit
  api_throttling_rate_limit          = var.api_throttling_rate_limit
  api_stage_name                     = var.api_stage_name
  jwt_issuer                         = var.jwt_issuer
  jwt_audience                       = var.jwt_audience
  custom_domain_name                 = var.custom_domain_name
  route53_zone_name                  = var.route53_zone_name
  route53_zone_id                    = local.custom_domain_enabled ? data.terraform_remote_state.dns[0].outputs.zone_id : null
  allowed_source_cidrs               = var.admin_allowed_cidrs
}
