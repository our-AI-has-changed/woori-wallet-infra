# Legacy stack

This Terraform stack is kept only for compatibility with older deployments.
The default wallet backend public entrypoint is now
`apps/wallet-backend/ingress.yaml`, managed by AWS Load Balancer Controller.

Do not use this stack for new deployments.
