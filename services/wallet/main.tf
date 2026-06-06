locals {
  name_prefix = var.name_prefix

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
