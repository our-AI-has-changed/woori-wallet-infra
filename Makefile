SERVICE_MODE ?= edge-woori
STACK_MODE ?= $(SERVICE_MODE)
AWS_REGION ?= ap-northeast-2
ECR_REGISTRY ?= 655700895912.dkr.ecr.ap-northeast-2.amazonaws.com
ARGOCD_CHART_VERSION ?= 7.8.27
GIT_BRANCH ?= main
METRICS_TOKEN_PARAMETER ?= /woori-wallet/prod/metrics-token
ARGOCD_INFRA_REPO_URL ?= https://github.com/our-AI-has-changed/woori-wallet-infra.git
ARGOCD_INFRA_REPO_TOKEN_PARAMETER ?= /woori-wallet/prod/argocd-infra-repo-token
WOORI_DB_PASSWORD_PARAMETER ?= /woori-wallet/prod/woori-db-password
WOORI_DB_ROOT_PASSWORD_PARAMETER ?= /woori-wallet/prod/woori-db-root-password
WALLET_DB_PASSWORD_PARAMETER ?= /woori-wallet/prod/wallet-db-password
WALLET_DB_ROOT_PASSWORD_PARAMETER ?= /woori-wallet/prod/wallet-db-root-password
FORCE_GRAFANA_ADMIN_PASSWORD ?= no
ENABLE_GRAFANA_EDGE ?= no
CREATE_MISSING_SSM_PARAMETERS ?= no
CANONICAL_STACK := $(if $(filter wallet,$(STACK_MODE)),edge-wallet,$(if $(filter woori,$(STACK_MODE)),edge-woori,$(STACK_MODE)))
TF_DIR := $(if $(filter state,$(CANONICAL_STACK)),bootstrap/state,infra/$(CANONICAL_STACK))

.PHONY: init fmt validate plan apply apply-all gitops-guard update-kubeconfig images-verify ssm-parameters-check ssm-parameters-bootstrap ssm-parameters-ensure argocd-install argocd-repo-secret argocd-apply metrics-secret db-secret monitoring-secret secrets-apply monitoring-apply monitoring-wait app-secrets-wait monitoring-secrets-wait secrets-wait addons-apply apps-wait deploy-apps apps-dry-run apps-apply argocd-apps-apply workloads-delete data-delete confirm-data-delete destroy stop-all destroy-all output

init:
	terraform -chdir=$(TF_DIR) init -reconfigure

fmt:
	terraform fmt -recursive

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) plan

apply:
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
	for manifest in apps/wallet-backend/deployment.yaml apps/woori-backend/deployment.yaml apps/wallet-ai/deployment.yaml apps/mock-mydata/deployment.yaml; do \
		image=$$(awk '/ image: / { print $$2; exit }' "$$manifest"); \
		repository=$${image%:*}; \
		tag=$${image##*:}; \
		repository_name=$${repository#$(ECR_REGISTRY)/}; \
		echo "Checking ECR image $$repository_name:$$tag"; \
		aws ecr describe-images --region $(AWS_REGION) --repository-name "$$repository_name" --image-ids imageTag="$$tag" --output json >/dev/null; \
	done

ssm-parameters-check:
	@set -e; \
	missing=""; \
	for name in \
		"$(METRICS_TOKEN_PARAMETER)" \
		"$(ARGOCD_INFRA_REPO_TOKEN_PARAMETER)" \
		"$(WOORI_DB_PASSWORD_PARAMETER)" \
		"$(WOORI_DB_ROOT_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_ROOT_PASSWORD_PARAMETER)"; do \
		if aws ssm get-parameter --region $(AWS_REGION) --name "$$name" --with-decryption --output json >/dev/null 2>&1; then \
			echo "SSM parameter exists: $$name"; \
		else \
			missing="$$missing $$name"; \
		fi; \
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
	for name in \
		"$(METRICS_TOKEN_PARAMETER)" \
		"$(WOORI_DB_PASSWORD_PARAMETER)" \
		"$(WOORI_DB_ROOT_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_PASSWORD_PARAMETER)" \
		"$(WALLET_DB_ROOT_PASSWORD_PARAMETER)"; do \
		if aws ssm get-parameter --region $(AWS_REGION) --name "$$name" --with-decryption --output json >/dev/null 2>&1; then \
			echo "SSM parameter already exists: $$name"; \
		else \
			value="$$(openssl rand -base64 32)"; \
			aws ssm put-parameter --region $(AWS_REGION) --name "$$name" --type SecureString --value "$$value" --output json >/dev/null; \
			echo "Created SSM SecureString: $$name"; \
		fi; \
	done

ssm-parameters-ensure:
	@if [ "$(CREATE_MISSING_SSM_PARAMETERS)" = "yes" ]; then \
		$(MAKE) ssm-parameters-bootstrap CREATE_MISSING_SSM_PARAMETERS=yes; \
	fi
	@$(MAKE) ssm-parameters-check

argocd-install:
	kubectl apply -f addons/argocd/namespace.yaml
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update
	helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --version $(ARGOCD_CHART_VERSION) --values addons/argocd/values.yaml --wait --timeout 300s
	kubectl wait --for condition=Established crd/applications.argoproj.io --timeout=120s

argocd-repo-secret:
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

argocd-apply: argocd-repo-secret metrics-secret db-secret
	kubectl apply -f argocd/applications/apps.yaml

metrics-secret:
	kubectl apply -f apps/namespaces/wallet.yaml
	kubectl apply -f apps/namespaces/woori.yaml
	kubectl apply -f addons/monitoring/namespace.yaml
	@set -e; \
	token="$$(aws ssm get-parameter --region $(AWS_REGION) --name "$(METRICS_TOKEN_PARAMETER)" --with-decryption --query Parameter.Value --output text)"; \
	secret_file="$$(mktemp)"; \
	trap 'rm -f "$$secret_file"' EXIT; \
	printf 'METRICS_TOKEN=%s\n' "$$token" > "$$secret_file"; \
	for namespace in wallet woori monitoring; do \
		kubectl -n "$$namespace" create secret generic metrics-token --from-env-file="$$secret_file" --dry-run=client -o yaml | kubectl apply -f -; \
	done

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

secrets-apply: metrics-secret db-secret monitoring-secret

monitoring-apply: argocd-repo-secret metrics-secret monitoring-secret
	kubectl apply -f argocd/applications/monitoring.yaml

monitoring-wait: metrics-secret monitoring-secret monitoring-secrets-wait
	@set -e; deadline=$$(( $$(date +%s) + 600 )); \
	for resource in \
		"namespace/monitoring" \
		"service/kube-prometheus-stack-grafana -n monitoring" \
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
		"wallet metrics-token METRICS_TOKEN" \
		"wallet wallet-db-credentials MYSQL_PASSWORD" \
		"wallet wallet-db-credentials MYSQL_ROOT_PASSWORD" \
		"wallet wallet-db-credentials WALLET_DATABASE_URL" \
		"wallet woori-db-credentials WOORI_DATABASE_URL" \
		"woori metrics-token METRICS_TOKEN" \
		"woori woori-db-credentials MYSQL_PASSWORD" \
		"woori woori-db-credentials MYSQL_ROOT_PASSWORD" \
		"woori woori-db-credentials WOORI_DATABASE_URL"; do \
		set -- $$secret_key; namespace=$$1; secret=$$2; key=$$3; \
		echo "Waiting for secret $$namespace/$$secret key $$key"; \
		until [ -n "$$(kubectl -n "$$namespace" get secret "$$secret" -o jsonpath="{.data.$$key}" 2>/dev/null)" ]; do \
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
		until [ -n "$$(kubectl -n "$$namespace" get secret "$$secret" -o jsonpath="{.data.$$key}" 2>/dev/null)" ]; do \
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
		"service/wallet-db -n wallet" \
		"service/woori-db -n woori" \
		"statefulset/wallet-db -n wallet" \
		"statefulset/woori-db -n woori" \
		"service/wallet-backend -n wallet" \
		"service/woori-backend -n woori" \
		"deployment/wallet-backend -n wallet" \
		"deployment/woori-backend -n woori" \
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
	kubectl -n wallet wait --for=condition=Available deployment/wallet-ai --timeout=300s
	kubectl -n wallet wait --for=condition=Available deployment/mock-mydata --timeout=300s

apps-dry-run:
	kubectl apply -k apps --dry-run=client

apps-apply: metrics-secret db-secret
	kubectl apply -k apps

argocd-apps-apply:
	$(MAKE) argocd-apply

deploy-apps:
	$(MAKE) argocd-apply

workloads-delete:
	@set -e; \
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
	fi
	kubectl -n wallet delete deployment wallet-backend wallet-ai mock-mydata --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n woori delete deployment woori-backend --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n wallet delete statefulset wallet-db --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n woori delete statefulset woori-db --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n wallet delete service wallet-backend wallet-ai mock-mydata wallet-db --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n woori delete service woori-backend woori-db --ignore-not-found=true --wait=true --timeout=300s
	kubectl delete namespace monitoring argocd --ignore-not-found=true --wait=true --timeout=300s

data-delete: confirm-data-delete
	kubectl -n wallet delete pvc data-wallet-db-0 --ignore-not-found=true --wait=true --timeout=300s
	kubectl -n woori delete pvc data-woori-db-0 --ignore-not-found=true --wait=true --timeout=300s
	kubectl delete namespace wallet woori --ignore-not-found=true --wait=true --timeout=300s
	kubectl delete storageclass woori-wallet-gp3 --ignore-not-found=true --wait=true --timeout=300s

confirm-data-delete:
	@test "$(CONFIRM_DATA_DELETE)" = "yes" || { echo "DB PVC deletion is required before platform destroy. Re-run with CONFIRM_DATA_DELETE=yes only after backup/data loss is accepted."; exit 1; }

destroy:
	terraform -chdir=$(TF_DIR) destroy

stop-all:
	$(MAKE) destroy SERVICE_MODE=edge-monitoring
	$(MAKE) destroy SERVICE_MODE=edge-wallet
	$(MAKE) destroy SERVICE_MODE=edge-woori
	$(MAKE) workloads-delete
	@echo "Stopped public edges and Kubernetes workloads. Platform resources and DB PVCs are retained."

destroy-all:
	$(MAKE) confirm-data-delete
	$(MAKE) destroy SERVICE_MODE=edge-monitoring
	$(MAKE) destroy SERVICE_MODE=edge-wallet
	$(MAKE) destroy SERVICE_MODE=edge-woori
	$(MAKE) workloads-delete
	$(MAKE) data-delete CONFIRM_DATA_DELETE=yes
	$(MAKE) destroy SERVICE_MODE=platform

apply-all:
	$(MAKE) gitops-guard
	$(MAKE) images-verify
	$(MAKE) ssm-parameters-ensure
	$(MAKE) apply SERVICE_MODE=platform
	$(MAKE) update-kubeconfig
	$(MAKE) argocd-install
	$(MAKE) addons-apply
	$(MAKE) monitoring-wait
	$(MAKE) apps-wait
	$(MAKE) apply SERVICE_MODE=edge-woori
	$(MAKE) apply SERVICE_MODE=edge-wallet
	@if [ "$(ENABLE_GRAFANA_EDGE)" = "yes" ]; then \
		$(MAKE) apply SERVICE_MODE=edge-monitoring; \
	else \
		echo "Skipping edge-monitoring apply. Use ENABLE_GRAFANA_EDGE=yes make apply-all or make apply SERVICE_MODE=edge-monitoring when public Grafana is needed."; \
	fi

output:
	terraform -chdir=$(TF_DIR) output
