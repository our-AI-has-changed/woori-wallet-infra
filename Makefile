SERVICE_MODE ?= woori
STACK_MODE ?= $(SERVICE_MODE)
TF_DIR := $(if $(filter state,$(STACK_MODE)),bootstrap/state,services/$(STACK_MODE))

.PHONY: init fmt validate plan apply destroy destroy-all output

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

destroy:
	terraform -chdir=$(TF_DIR) destroy

destroy-all:
	$(MAKE) destroy SERVICE_MODE=wallet
	$(MAKE) destroy SERVICE_MODE=woori
	$(MAKE) destroy SERVICE_MODE=platform

output:
	terraform -chdir=$(TF_DIR) output
