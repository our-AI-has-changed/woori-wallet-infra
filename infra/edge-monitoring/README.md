# Legacy stack

This Terraform stack exposes Grafana through API Gateway.
The default monitoring entrypoint is now `addons/monitoring/ingress.yaml`,
managed by AWS Load Balancer Controller.

Do not use this stack for new deployments.
