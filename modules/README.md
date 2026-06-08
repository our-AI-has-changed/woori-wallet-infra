# modules

Woori Wallet 인프라에서 재사용할 Terraform 모듈을 두는 디렉터리입니다.

스택별 값은 `infra/*`에 두고, 여러 스택에서 반복되는 리소스 패턴만 이곳에 모듈로 분리합니다.

- `service-edge`: 서비스별 public API Gateway, shared ALB listener rule, target group, optional custom domain, optional AWS WAF IP allowlist를 관리합니다.
