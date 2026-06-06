SERVICE_MODE ?= woori
TF_DIR := services/$(SERVICE_MODE)

.PHONY: init fmt validate plan

init:
	terraform -chdir=$(TF_DIR) init

fmt:
	terraform fmt -recursive

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) plan
