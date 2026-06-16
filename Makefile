SERVICE_MODE ?= platform
STACK_MODE ?= $(SERVICE_MODE)
AWS_REGION ?= ap-northeast-2
ECR_REGISTRY ?= 655700895912.dkr.ecr.ap-northeast-2.amazonaws.com
ARGOCD_CHART_VERSION ?= 7.8.27
EXTERNAL_SECRETS_CHART_VERSION ?= 0.14.4
AWS_LOAD_BALANCER_CONTROLLER_CHART_VERSION ?= 1.13.0
GIT_BRANCH ?= main
METRICS_TOKEN_PARAMETER ?= /woori-wallet/prod/metrics-token
TRIAL_WOORI_BACKEND_ENV_PARAMETER ?= /woori-wallet/prod/trial/woori-backend-env
TRIAL_WALLET_BACKEND_ENV_PARAMETER ?= /woori-wallet/prod/trial/wallet-backend-env
TRIAL_AI_ENV_PARAMETER ?= /woori-wallet/prod/trial/ai-env
TRIAL_APP_ENV_PARAMETER ?= /woori-wallet/prod/trial/app-env
ARGOCD_INFRA_REPO_OWNER ?= our-AI-has-changed
ARGOCD_INFRA_REPO_NAME ?= woori-wallet-infra
ARGOCD_INFRA_REPO_URL ?= https://github.com/$(ARGOCD_INFRA_REPO_OWNER)/$(ARGOCD_INFRA_REPO_NAME).git
ARGOCD_GITHUB_API_URL ?= https://api.github.com
ARGOCD_INFRA_REPO_TOKEN_PARAMETER ?= /woori-wallet/prod/argocd-infra-repo-token
WOORI_DB_PASSWORD_PARAMETER ?= /woori-wallet/prod/woori-db-password
WOORI_DB_ROOT_PASSWORD_PARAMETER ?= /woori-wallet/prod/woori-db-root-password
WALLET_DB_PASSWORD_PARAMETER ?= /woori-wallet/prod/wallet-db-password
WALLET_DB_ROOT_PASSWORD_PARAMETER ?= /woori-wallet/prod/wallet-db-root-password
FORCE_GRAFANA_ADMIN_PASSWORD ?= no
CREATE_MISSING_SSM_PARAMETERS ?= no
ROUTE53_ZONE_NAME ?= dannis.cloud
EDGE_CUSTOM_DOMAIN_ENABLED ?= yes
CANONICAL_STACK := $(STACK_MODE)
TF_DIR := $(if $(filter state,$(CANONICAL_STACK)),bootstrap/state,infra/$(CANONICAL_STACK))

.PHONY: init fmt validate plan apply apply-all gitops-guard update-kubeconfig images-verify route53-zone-check route53-delegation-check ssm-parameters-check ssm-parameters-bootstrap ssm-parameters-ensure external-secrets-install aws-load-balancer-controller-install argocd-install argocd-repo-token-check argocd-repo-secret argocd-apply db-secret monitoring-secret secrets-apply monitoring-apply monitoring-wait app-secrets-wait monitoring-secrets-wait secrets-wait addons-apply apps-wait deploy-apps apps-render apps-dry-run apps-apply argocd-apps-apply workloads-delete data-delete confirm-data-delete destroy stop-all destroy-all destroy-dns legacy-edges-destroy output

init:
	terraform -chdir=$(TF_DIR) init -reconfigure

fmt:
	terraform fmt -recursive

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) plan

apply:
	@if { [ "$(CANONICAL_STACK)" = "edge-woori" ] || [ "$(CANONICAL_STACK)" = "edge-wallet" ] || [ "$(CANONICAL_STACK)" = "edge-monitoring" ]; } && [ "$(EDGE_CUSTOM_DOMAIN_ENABLED)" = "yes" ]; then \
		$(MAKE) route53-zone-check; \
		$(MAKE) route53-delegation-check; \
	fi
	terraform -chdir=$(TF_DIR) apply

gitops-guard:
	@test "$$(git rev-parse --abbrev-ref HEAD)" = "$(GIT_BRANCH)" || { echo "Expected git branch $(GIT_BRANCH)"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "Working tree has local changes, including untracked files. Commit and push before GitOps apply."; exit 1; }
	@git fetch origin $(GIT_BRANCH)
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/$(GIT_BRANCH))" || { echo "Local HEAD differs from origin/$(GIT_BRANCH). Push or pull before GitOps apply."; exit 1; }

update-kubeconfig:
	aws eks update-kubeconfig --region $(AWS_REGION) --name "$$(terraform -chdir=infra/platform output -raw cluster_name)"

images-verify:
	@set -e; \
	for manifest in apps/frontend/deployment.yaml apps/wallet-backend/deployment.yaml apps/woori-backend/deployment.yaml apps/wallet-ai/deployment.yaml apps/mock-mydata/deployment.yaml; do \
		image=$$(awk '/ image: / { print $$2; exit }' "$$manifest"); \
		repository=$${image%:*}; \
		tag=$${image##*:}; \
		repository_name=$${repository#$(ECR_REGISTRY)/}; \
		echo "Checking ECR image $$repository_name:$$tag"; \
		aws ecr describe-images --region $(AWS_REGION) --repository-name "$$repository_name" --image-ids imageTag="$$tag" --output json >/dev/null; \
	done

route53-zone-check:
	@set -e; \
	zone_id="$$(terraform -chdir=infra/dns output -raw zone_id 2>/dev/null || true)"; \
	zone_name="$$(terraform -chdir=infra/dns output -raw zone_name 2>/dev/null || true)"; \
	if [ -z "$$zone_id" ] || [ "$$zone_id" = "None" ]; then \
		echo "Missing Route53 DNS Terraform state. Run make apply SERVICE_MODE=dns before applying edge resources."; \
		exit 1; \
	fi; \
	if [ "$$zone_name" != "$(ROUTE53_ZONE_NAME)" ]; then \
		echo "DNS Terraform state zone_name is $$zone_name, expected $(ROUTE53_ZONE_NAME)."; \
		exit 1; \
	fi; \
	echo "Route53 hosted zone exists: $$zone_name ($$zone_id)"; \
	echo "Route53 name servers:"; \
	aws route53 get-hosted-zone --id "$$zone_id" --query 'DelegationSet.NameServers' --output text

route53-delegation-check:
	@set -e; \
	if ! command -v dig >/dev/null 2>&1; then \
		echo "dig is required for Route53 public NS delegation check."; \
		echo "Install bind tools or run this check from an environment with dig before applying edge resources."; \
		exit 1; \
	fi; \
	zone_id="$$(terraform -chdir=infra/dns output -raw zone_id 2>/dev/null || true)"; \
	zone_name="$$(terraform -chdir=infra/dns output -raw zone_name 2>/dev/null || true)"; \
	if [ -z "$$zone_id" ] || [ "$$zone_id" = "None" ]; then \
		echo "Missing Route53 DNS Terraform state. Run make apply SERVICE_MODE=dns before applying edge resources."; \
		exit 1; \
	fi; \
	if [ "$$zone_name" != "$(ROUTE53_ZONE_NAME)" ]; then \
		echo "DNS Terraform state zone_name is $$zone_name, expected $(ROUTE53_ZONE_NAME)."; \
		exit 1; \
	fi; \
	route53_ns="$$(aws route53 get-hosted-zone --id "$$zone_id" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sed 's/\.$$//' | sort | tr '\n' ' ' | sed 's/ $$//')"; \
	public_ns="$$(dig +short NS "$$zone_name" | sed 's/\.$$//' | sort | tr '\n' ' ' | sed 's/ $$//')"; \
	if [ -z "$$public_ns" ]; then \
		echo "No public NS records found for $$zone_name."; \
		echo "Delegate the domain to these Route53 name servers before apply-all continues:"; \
		echo "$$route53_ns"; \
		exit 1; \
	fi; \
	if [ "$$route53_ns" != "$$public_ns" ]; then \
		echo "Public NS records for $$zone_name do not match the Route53 hosted zone."; \
		echo "Route53 name servers: $$route53_ns"; \
		echo "Public DNS name servers: $$public_ns"; \
		echo "Update the domain registrar NS records before applying platform/edge resources."; \
		exit 1; \
	fi; \
	echo "Route53 public NS delegation is configured for $$zone_name."

ssm-parameters-check:
	@set -e; \
	missing=""; \
	err_file="$$(mktemp)"; \
	trap 'rm -f "$$err_file"' EXIT; \
	for name in \
		"$(METRICS_TOKEN_PARAMETER)" \
		"$(TRIAL_APP_ENV_PARAMETER)" \
		"$(TRIAL_WOORI_BACKEND_ENV_PARAMETER)" \
		"$(TRIAL_WALLET_BACKEND_ENV_PARAMETER)" \
		"$(TRIAL_AI_ENV_PARAMETER)" \
		"$(ARGOCD_INFRA_REPO_TOKEN_PARAMETER)" \
		"$(WOORI_DB_PASSWORD_PARAMETER)" \
		"$(WOORI_DB_ROOT_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_ROOT_PASSWORD_PARAMETER)"; do \
		if aws ssm get-parameter --region $(AWS_REGION) --name "$$name" --with-decryption --output json >/dev/null 2>"$$err_file"; then \
			echo "SSM parameter exists: $$name"; \
		elif grep -q "ParameterNotFound" "$$err_file"; then \
			missing="$$missing $$name"; \
		else \
			echo "Failed to check SSM parameter: $$name"; \
			cat "$$err_file"; \
			exit 1; \
		fi; \
		: > "$$err_file"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "Missing required SSM parameters:"; \
		for name in $$missing; do echo "  - $$name"; done; \
		echo "Create secrets manually as SecureString. Non-GitHub random test values can be bootstrapped with:"; \
		echo "  CREATE_MISSING_SSM_PARAMETERS=yes make ssm-parameters-bootstrap"; \
		echo "The Argo CD infra repo token must be a real GitHub token with read access to the infra repo."; \
		exit 1; \
	fi

ssm-parameters-bootstrap:
	@test "$(CREATE_MISSING_SSM_PARAMETERS)" = "yes" || { echo "This creates missing SecureString parameters. Re-run with CREATE_MISSING_SSM_PARAMETERS=yes."; exit 1; }
	@set -e; \
	err_file="$$(mktemp)"; \
	trap 'rm -f "$$err_file"' EXIT; \
	for name in \
		"$(METRICS_TOKEN_PARAMETER)" \
		"$(WOORI_DB_PASSWORD_PARAMETER)" \
		"$(WOORI_DB_ROOT_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_ROOT_PASSWORD_PARAMETER)"; do \
		if aws ssm get-parameter --region $(AWS_REGION) --name "$$name" --with-decryption --output json >/dev/null 2>"$$err_file"; then \
			echo "SSM parameter already exists: $$name"; \
		elif grep -q "ParameterNotFound" "$$err_file"; then \
			value="$$(openssl rand -base64 32)"; \
			aws ssm put-parameter --region $(AWS_REGION) --name "$$name" --type SecureString --value "$$value" --output json >/dev/null; \
			echo "Created SSM SecureString: $$name"; \
		else \
			echo "Failed to check SSM parameter: $$name"; \
			cat "$$err_file"; \
			exit 1; \
		fi; \
		: > "$$err_file"; \
	done

ssm-parameters-ensure:
	@if [ "$(CREATE_MISSING_SSM_PARAMETERS)" = "yes" ]; then \
		$(MAKE) ssm-parameters-bootstrap CREATE_MISSING_SSM_PARAMETERS=yes; \
	fi
	@$(MAKE) ssm-parameters-check

external-secrets-install:
	kubectl apply -f addons/external-secrets/namespace.yaml
	helm repo add external-secrets https://charts.external-secrets.io --force-update
	helm repo update
	@set -e; \
	role_arn="$$(terraform -chdir=infra/platform output -raw external_secrets_irsa_role_arn)"; \
	if [ -z "$$role_arn" ]; then \
		echo "external_secrets_irsa_role_arn is empty. Ensure infra/platform has been applied."; \
		exit 1; \
	fi; \
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace external-secrets \
		--create-namespace \
		--version $(EXTERNAL_SECRETS_CHART_VERSION) \
		--values addons/external-secrets/values.yaml \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$$role_arn" \
		--wait \
		--timeout 300s
	kubectl wait --for condition=Established crd/externalsecrets.external-secrets.io --timeout=120s
	kubectl wait --for condition=Established crd/clustersecretstores.external-secrets.io --timeout=120s
	kubectl apply -f addons/external-secrets/cluster-secret-store.yaml

aws-load-balancer-controller-install:
	helm repo add eks https://aws.github.io/eks-charts --force-update
	helm repo update
	@set -e; \
	cluster_name="$$(terraform -chdir=infra/platform output -raw cluster_name)"; \
	vpc_id="$$(terraform -chdir=infra/platform output -raw vpc_id)"; \
	role_arn="$$(terraform -chdir=infra/platform output -raw aws_load_balancer_controller_irsa_role_arn)"; \
	if [ -z "$$role_arn" ]; then \
		echo "aws_load_balancer_controller_irsa_role_arn is empty. Ensure infra/platform has been applied."; \
		exit 1; \
	fi; \
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		--namespace kube-system \
		--version $(AWS_LOAD_BALANCER_CONTROLLER_CHART_VERSION) \
		--values addons/aws-load-balancer-controller/values.yaml \
		--set clusterName="$$cluster_name" \
		--set region="$(AWS_REGION)" \
		--set vpcId="$$vpc_id" \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$$role_arn" \
		--wait \
		--timeout 300s

argocd-install:
	kubectl apply -f addons/argocd/namespace.yaml
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update
	helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --version $(ARGOCD_CHART_VERSION) --values addons/argocd/values.yaml --wait --timeout 300s
	kubectl wait --for condition=Established crd/applications.argoproj.io --timeout=120s

argocd-repo-token-check:
	@set -e; \
	repo_path="$(ARGOCD_INFRA_REPO_OWNER)/$(ARGOCD_INFRA_REPO_NAME)"; \
	repo_url="$(ARGOCD_INFRA_REPO_URL)"; \
	case "$$repo_url" in \
		https://*/*) ;; \
		*) \
			echo "ARGOCD_INFRA_REPO_URL must be an HTTPS Git URL because argocd-repo-secret uses token/password authentication."; \
			echo "SSH repo URLs require a different Argo CD Secret with sshPrivateKey and are not supported by this Makefile."; \
			exit 1; \
			;; \
	esac; \
	repo_host="$$(printf '%s\n' "$$repo_url" | sed -E 's#^https://([^/]+)/.*#\1#')"; \
	url_repo_path="$$(printf '%s\n' "$$repo_url" | sed -E 's#^https://[^/]+/##; s#\.git$$##; s#/*$$##')"; \
	if [ "$$url_repo_path" != "$$repo_path" ]; then \
		echo "ARGOCD_INFRA_REPO_URL points to $$url_repo_path, but token preflight checks $$repo_path."; \
		echo "Set ARGOCD_INFRA_REPO_OWNER, ARGOCD_INFRA_REPO_NAME, and ARGOCD_INFRA_REPO_URL to the same repo."; \
		exit 1; \
	fi; \
	api_url="$(ARGOCD_GITHUB_API_URL)"; \
	case "$$api_url" in \
		https://*) ;; \
		*) echo "ARGOCD_GITHUB_API_URL must be an HTTPS URL."; exit 1 ;; \
	esac; \
	api_host="$$(printf '%s\n' "$$api_url" | sed -E 's#^https://([^/]+).*#\1#')"; \
	if [ "$$repo_host" = "github.com" ] && [ "$$api_host" != "api.github.com" ]; then \
		echo "github.com repos must use ARGOCD_GITHUB_API_URL=https://api.github.com."; \
		exit 1; \
	fi; \
	if [ "$$repo_host" != "github.com" ] && [ "$$api_url" = "https://api.github.com" ]; then \
		echo "GitHub Enterprise repo host $$repo_host requires ARGOCD_GITHUB_API_URL, for example https://$$repo_host/api/v3."; \
		exit 1; \
	fi; \
	if [ "$$repo_host" != "github.com" ] && [ "$$api_host" != "$$repo_host" ]; then \
		echo "GitHub Enterprise API host $$api_host must match repo host $$repo_host."; \
		exit 1; \
	fi; \
	token="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(ARGOCD_INFRA_REPO_TOKEN_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	err_file="$$(mktemp)"; \
	trap 'rm -f "$$err_file"' EXIT; \
	status="$$(curl -sS -o /dev/null -w '%{http_code}' \
		-H "Authorization: Bearer $$token" \
		-H "Accept: application/vnd.github+json" \
		"$${api_url%/}/repos/$$repo_path" 2>"$$err_file" || true)"; \
	if [ "$$status" = "000" ]; then \
		echo "GitHub API unreachable while checking $$repo_path."; \
		cat "$$err_file"; \
		exit 1; \
	fi; \
	if [ "$$status" != "200" ]; then \
		echo "Argo CD infra repo token cannot read $$repo_path. GitHub API status: $$status"; \
		echo "Update $(ARGOCD_INFRA_REPO_TOKEN_PARAMETER) with a token that has contents:read access."; \
		exit 1; \
	fi; \
	echo "Argo CD infra repo token can read $$repo_path"

argocd-repo-secret: argocd-repo-token-check
	kubectl apply -f addons/argocd/namespace.yaml
	@set -e; \
	token="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(ARGOCD_INFRA_REPO_TOKEN_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	kubectl -n argocd create secret generic woori-wallet-infra-repo \
		--from-literal=type=git \
		--from-literal=url="$(ARGOCD_INFRA_REPO_URL)" \
		--from-literal=username=x-access-token \
		--from-literal=password="$$token" \
		--dry-run=client -o yaml | \
		kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | \
		kubectl apply -f -

argocd-apply: argocd-repo-secret db-secret
	@set -e; \
	rendered="$$(mktemp)"; \
	trap 'rm -f "$$rendered"' EXIT; \
	ARGOCD_RENDER_REPO_URL="$(ARGOCD_INFRA_REPO_URL)" perl -pe 's#__ARGOCD_INFRA_REPO_URL__#$$ENV{ARGOCD_RENDER_REPO_URL}#g' argocd/applications/apps.yaml > "$$rendered"; \
	repo_count="$$(grep -F "repoURL: $(ARGOCD_INFRA_REPO_URL)" "$$rendered" | wc -l | tr -d ' ')"; \
	if grep -q "__ARGOCD_INFRA_REPO_URL__" "$$rendered" || [ "$$repo_count" -ne 1 ]; then \
		echo "Failed to render argocd/applications/apps.yaml with ARGOCD_INFRA_REPO_URL=$(ARGOCD_INFRA_REPO_URL)."; \
		exit 1; \
	fi; \
	kubectl apply -f "$$rendered"

db-secret:
	kubectl apply -f apps/namespaces/wallet.yaml
	kubectl apply -f apps/namespaces/woori.yaml
	@set -e; \
	secret_dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$secret_dir"' EXIT; \
	woori_password="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(WOORI_DB_PASSWORD_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	woori_root_password="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(WOORI_DB_ROOT_PASSWORD_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	wallet_password="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(WALLET_DB_PASSWORD_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	wallet_root_password="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(WALLET_DB_ROOT_PASSWORD_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	woori_password_url="$$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$$woori_password")"; \
	wallet_password_url="$$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$$wallet_password")"; \
	woori_url="mysql+pymysql://woori:$${woori_password_url}@woori-db.woori.svc.cluster.local:3306/woori_auth"; \
	wallet_url="mysql+pymysql://woori:$${wallet_password_url}@wallet-db.wallet.svc.cluster.local:3306/wallet_trial"; \
	printf 'MYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\nWOORI_DATABASE_URL=%s\n' "$$woori_password" "$$woori_root_password" "$$woori_url" > "$$secret_dir/woori-db.env"; \
	printf 'WOORI_DATABASE_URL=%s\n' "$$woori_url" > "$$secret_dir/wallet-woori-db.env"; \
	printf 'MYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\nWALLET_DATABASE_URL=%s\n' "$$wallet_password" "$$wallet_root_password" "$$wallet_url" > "$$secret_dir/wallet-db.env"; \
	kubectl -n woori create secret generic woori-db-credentials \
		--from-env-file="$$secret_dir/woori-db.env" \
		--dry-run=client -o yaml | kubectl apply -f -; \
	kubectl -n wallet create secret generic woori-db-credentials \
		--from-env-file="$$secret_dir/wallet-woori-db.env" \
		--dry-run=client -o yaml | kubectl apply -f -; \
	kubectl -n wallet create secret generic wallet-db-credentials \
		--from-env-file="$$secret_dir/wallet-db.env" \
		--dry-run=client -o yaml | kubectl apply -f -

monitoring-secret:
	kubectl apply -f addons/monitoring/namespace.yaml
	@set -e; \
	if [ "$(FORCE_GRAFANA_ADMIN_PASSWORD)" != "yes" ] && \
		[ -n "$$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null)" ] && \
		[ -n "$$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null)" ]; then \
		echo "grafana-admin secret already has required keys"; \
	else \
		secret_file="$$(mktemp)"; \
		trap 'rm -f "$$secret_file"' EXIT; \
		printf 'admin-user=admin\nadmin-password=%s\n' "$${GRAFANA_ADMIN_PASSWORD:-$$(openssl rand -base64 24)}" > "$$secret_file"; \
		kubectl -n monitoring create secret generic grafana-admin --from-env-file="$$secret_file" --dry-run=client -o yaml | kubectl apply -f -; \
	fi

secrets-apply: db-secret monitoring-secret

monitoring-apply: argocd-repo-secret monitoring-secret
	@set -e; \
	rendered="$$(mktemp)"; \
	trap 'rm -f "$$rendered"' EXIT; \
	ARGOCD_RENDER_REPO_URL="$(ARGOCD_INFRA_REPO_URL)" perl -pe 's#__ARGOCD_INFRA_REPO_URL__#$$ENV{ARGOCD_RENDER_REPO_URL}#g' argocd/applications/monitoring.yaml > "$$rendered"; \
	repo_count="$$(grep -F "repoURL: $(ARGOCD_INFRA_REPO_URL)" "$$rendered" | wc -l | tr -d ' ')"; \
	if grep -q "__ARGOCD_INFRA_REPO_URL__" "$$rendered" || [ "$$repo_count" -ne 2 ]; then \
		echo "Failed to render argocd/applications/monitoring.yaml with ARGOCD_INFRA_REPO_URL=$(ARGOCD_INFRA_REPO_URL)."; \
		exit 1; \
	fi; \
	kubectl apply -f "$$rendered"

monitoring-wait: monitoring-secret monitoring-secrets-wait
	@set -e; deadline=$$(( $$(date +%s) + 600 )); \
	for resource in \
		"namespace/monitoring" \
		"service/kube-prometheus-stack-grafana -n monitoring" \
		"ingress/grafana -n monitoring" \
		"deployment/kube-prometheus-stack-grafana -n monitoring"; do \
		echo "Waiting for $$resource"; \
		until kubectl get $$resource >/dev/null 2>&1; do \
			if [ $$(date +%s) -ge $$deadline ]; then echo "Timed out waiting for $$resource"; exit 1; fi; \
			sleep 5; \
		done; \
	done
	kubectl -n monitoring wait --for=condition=Available deployment/kube-prometheus-stack-grafana --timeout=300s

app-secrets-wait:
	@set -e; deadline=$$(( $$(date +%s) + 600 )); \
	for secret_key in \
		"wallet backend-env .env" \
		"wallet ai-env .env" \
		"wallet metrics-token METRICS_TOKEN" \
		"wallet wallet-db-credentials MYSQL_PASSWORD" \
		"wallet wallet-db-credentials MYSQL_ROOT_PASSWORD" \
		"wallet wallet-db-credentials WALLET_DATABASE_URL" \
		"wallet woori-db-credentials WOORI_DATABASE_URL" \
		"woori backend-env .env" \
		"woori metrics-token METRICS_TOKEN" \
		"woori woori-db-credentials MYSQL_PASSWORD" \
		"woori woori-db-credentials MYSQL_ROOT_PASSWORD" \
		"woori woori-db-credentials WOORI_DATABASE_URL"; do \
		set -- $$secret_key; namespace=$$1; secret=$$2; key=$$3; \
		echo "Waiting for secret $$namespace/$$secret key $$key"; \
		until [ -n "$$(kubectl -n "$$namespace" get secret "$$secret" -o go-template="{{ index .data \"$$key\" }}" 2>/dev/null)" ]; do \
			if [ $$(date +%s) -ge $$deadline ]; then echo "Timed out waiting for secret $$namespace/$$secret key $$key"; exit 1; fi; \
			sleep 5; \
		done; \
	done

monitoring-secrets-wait:
	@set -e; deadline=$$(( $$(date +%s) + 600 )); \
	for secret_key in \
		"monitoring metrics-token METRICS_TOKEN" \
		"monitoring grafana-admin admin-user" \
		"monitoring grafana-admin admin-password"; do \
		set -- $$secret_key; namespace=$$1; secret=$$2; key=$$3; \
		echo "Waiting for secret $$namespace/$$secret key $$key"; \
		until [ -n "$$(kubectl -n "$$namespace" get secret "$$secret" -o go-template="{{ index .data \"$$key\" }}" 2>/dev/null)" ]; do \
			if [ $$(date +%s) -ge $$deadline ]; then echo "Timed out waiting for secret $$namespace/$$secret key $$key"; exit 1; fi; \
			sleep 5; \
		done; \
	done

secrets-wait: app-secrets-wait monitoring-secrets-wait

addons-apply: argocd-apply monitoring-apply

apps-wait: app-secrets-wait
	@set -e; deadline=$$(( $$(date +%s) + 600 )); \
	for resource in \
		"namespace/wallet" \
		"namespace/woori" \
		"namespace/frontend" \
		"service/wallet-db -n wallet" \
		"service/woori-db -n woori" \
		"statefulset/wallet-db -n wallet" \
		"statefulset/woori-db -n woori" \
		"service/wallet-backend -n wallet" \
		"service/woori-backend -n woori" \
		"service/frontend -n frontend" \
		"ingress/frontend -n frontend" \
		"ingress/wallet-backend -n wallet" \
		"ingress/woori-backend -n woori" \
		"deployment/wallet-backend -n wallet" \
		"deployment/woori-backend -n woori" \
		"deployment/frontend -n frontend" \
		"deployment/wallet-ai -n wallet" \
		"deployment/mock-mydata -n wallet"; do \
		echo "Waiting for $$resource"; \
		until kubectl get $$resource >/dev/null 2>&1; do \
			if [ $$(date +%s) -ge $$deadline ]; then echo "Timed out waiting for $$resource"; exit 1; fi; \
			sleep 5; \
		done; \
	done
	kubectl -n wallet rollout status statefulset/wallet-db --timeout=300s
	kubectl -n woori rollout status statefulset/woori-db --timeout=300s
	kubectl -n wallet wait --for=condition=Available deployment/wallet-backend --timeout=300s
	kubectl -n woori wait --for=condition=Available deployment/woori-backend --timeout=300s
	kubectl -n frontend wait --for=condition=Available deployment/frontend --timeout=300s
	kubectl -n wallet wait --for=condition=Available deployment/wallet-ai --timeout=300s
	kubectl -n wallet wait --for=condition=Available deployment/mock-mydata --timeout=300s

apps-render:
	kubectl kustomize apps

apps-dry-run:
	kubectl apply -k apps --dry-run=client

apps-apply: db-secret
	kubectl apply -k apps

argocd-apps-apply:
	$(MAKE) argocd-apply

deploy-apps:
	$(MAKE) argocd-apply

workloads-delete:
	@set -e; \
	if ! kubectl get --raw=/readyz >/dev/null 2>&1; then \
		cluster_name="$$(terraform -chdir=infra/platform output -raw cluster_name 2>/dev/null || true)"; \
		if [ -z "$$cluster_name" ]; then \
			echo "No platform cluster in Terraform state; skipping workload cleanup."; \
			exit 0; \
		fi; \
		err_file="$$(mktemp)"; \
		trap 'rm -f "$$err_file"' EXIT; \
		if cluster_status="$$(aws eks describe-cluster --region $(AWS_REGION) --name "$$cluster_name" --query cluster.status --output text 2>"$$err_file")"; then \
			if [ "$$cluster_status" = "DELETING" ]; then \
				echo "EKS cluster $$cluster_name is deleting; skipping workload cleanup."; \
				exit 0; \
			fi; \
			echo "Kubernetes API unavailable while EKS cluster $$cluster_name is $$cluster_status."; \
			echo "Run make update-kubeconfig or fix kubectl access before workload cleanup."; \
			exit 1; \
		elif grep -q "ResourceNotFoundException" "$$err_file"; then \
			echo "EKS cluster $$cluster_name no longer exists; skipping workload cleanup."; \
			exit 0; \
		else \
			echo "Failed to check EKS cluster $$cluster_name before workload cleanup."; \
			cat "$$err_file"; \
			exit 1; \
		fi; \
	fi; \
	if kubectl api-resources --api-group=argoproj.io --no-headers 2>/dev/null | awk '{print $$1}' | grep -qx applications; then \
		for application in woori-wallet-monitoring woori-wallet-apps; do \
			application_name="$$(kubectl -n argocd get application "$$application" --ignore-not-found -o name)"; \
			if [ -n "$$application_name" ]; then \
				kubectl -n argocd patch "$$application_name" --type=merge -p '{"metadata":{"finalizers":[]}}'; \
			fi; \
			kubectl -n argocd delete application "$$application" --ignore-not-found=true --wait=true --timeout=300s; \
		done; \
	else \
		echo "Argo CD Application CRD is not installed; skipping Application delete."; \
	fi; \
	kubectl -n wallet delete deployment wallet-backend wallet-ai mock-mydata --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n woori delete deployment woori-backend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n frontend delete deployment frontend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n frontend delete ingress frontend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n wallet delete ingress wallet-backend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n woori delete ingress woori-backend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n wallet delete statefulset wallet-db --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n woori delete statefulset woori-db --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n wallet delete service wallet-backend wallet-ai mock-mydata wallet-db --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n woori delete service woori-backend woori-db --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n frontend delete service frontend --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl delete namespace monitoring argocd frontend --ignore-not-found=true --wait=true --timeout=300s

data-delete: confirm-data-delete
	@set -e; \
	if ! kubectl get --raw=/readyz >/dev/null 2>&1; then \
		cluster_name="$$(terraform -chdir=infra/platform output -raw cluster_name 2>/dev/null || true)"; \
		if [ -z "$$cluster_name" ]; then \
			echo "No platform cluster in Terraform state; skipping PVC and namespace cleanup."; \
			exit 0; \
		fi; \
		err_file="$$(mktemp)"; \
		trap 'rm -f "$$err_file"' EXIT; \
		if cluster_status="$$(aws eks describe-cluster --region $(AWS_REGION) --name "$$cluster_name" --query cluster.status --output text 2>"$$err_file")"; then \
			if [ "$$cluster_status" = "DELETING" ]; then \
				echo "EKS cluster $$cluster_name is deleting, so PVC cleanup cannot be verified."; \
				echo "Check for leftover EBS volumes before considering destroy complete."; \
				exit 1; \
			fi; \
			echo "Kubernetes API unavailable while EKS cluster $$cluster_name is $$cluster_status."; \
			echo "Run make update-kubeconfig or fix kubectl access before PVC cleanup."; \
			exit 1; \
		elif grep -q "ResourceNotFoundException" "$$err_file"; then \
			echo "EKS cluster $$cluster_name no longer exists; skipping PVC and namespace cleanup."; \
			exit 0; \
		else \
			echo "Failed to check EKS cluster $$cluster_name before PVC cleanup."; \
			cat "$$err_file"; \
			exit 1; \
		fi; \
	fi; \
	kubectl -n wallet delete pvc data-wallet-db-0 --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl -n woori delete pvc data-woori-db-0 --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl delete namespace wallet woori --ignore-not-found=true --wait=true --timeout=300s; \
	kubectl delete storageclass woori-wallet-gp3 --ignore-not-found=true --wait=true --timeout=300s

confirm-data-delete:
	@test "$(CONFIRM_DATA_DELETE)" = "yes" || { echo "DB PVC deletion is required before platform destroy. Re-run with CONFIRM_DATA_DELETE=yes only after backup/data loss is accepted."; exit 1; }

destroy:
	@if [ "$(CANONICAL_STACK)" = "dns" ] && [ "$(CONFIRM_DNS_DELETE)" != "yes" ]; then \
		echo "Route53 DNS hosted zone is a long-lived base resource. Use CONFIRM_DNS_DELETE=yes make destroy-dns if NS changes are accepted."; \
		exit 1; \
	fi
	terraform -chdir=$(TF_DIR) destroy

stop-all:
	$(MAKE) workloads-delete
	@echo "Stopped Kubernetes workloads and Ingress ALBs. Platform resources and DB PVCs are retained."

destroy-all:
	$(MAKE) confirm-data-delete
	$(MAKE) workloads-delete
	$(MAKE) data-delete CONFIRM_DATA_DELETE=yes
	$(MAKE) destroy SERVICE_MODE=platform
	@echo "Keeping Route53 DNS stack. Use CONFIRM_DNS_DELETE=yes make destroy-dns only when the hosted zone must be deleted."

destroy-dns:
	@test "$(CONFIRM_DNS_DELETE)" = "yes" || { echo "Route53 DNS hosted zone is a long-lived base resource. Re-run with CONFIRM_DNS_DELETE=yes only if NS changes are accepted."; exit 1; }
	$(MAKE) destroy SERVICE_MODE=dns CONFIRM_DNS_DELETE=yes

legacy-edges-destroy:
	$(MAKE) destroy SERVICE_MODE=edge-monitoring
	$(MAKE) destroy SERVICE_MODE=edge-wallet
	$(MAKE) destroy SERVICE_MODE=edge-woori

apply-all:
	$(MAKE) gitops-guard
	$(MAKE) images-verify
	$(MAKE) apply SERVICE_MODE=dns
	$(MAKE) route53-zone-check
	$(MAKE) route53-delegation-check
	$(MAKE) ssm-parameters-ensure
	$(MAKE) argocd-repo-token-check
	$(MAKE) apply SERVICE_MODE=platform
	$(MAKE) update-kubeconfig
	$(MAKE) external-secrets-install
	$(MAKE) aws-load-balancer-controller-install
	$(MAKE) argocd-install
	$(MAKE) addons-apply
	$(MAKE) monitoring-wait
	$(MAKE) apps-wait

output:
	terraform -chdir=$(TF_DIR) output
