# Legacy stack

This Terraform stack is kept only for compatibility with older deployments.
The default frontend public entrypoint is now `apps/frontend/ingress.yaml`,
managed by AWS Load Balancer Controller.

Do not use this stack for new deployments.
