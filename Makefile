# Cloudflare DNS IaC — convenience commands
# Usage: make <target> [zone=<zone>] [domain=<domain>] [from_zone=<zone>]
#
# Examples:
#   make plan zone=acme
#   make apply zone=acme
#   make import zone=acme domain=acme-corp.io
#   make move zone=acme domain=acme-corp.io from_zone=legacy

ZONES_DIR := envs/cloudflare/zones

# Require zone variable for zone-scoped targets
.check-zone:
	@[ -n "$(zone)" ] || (echo "❌ Usage: make $(MAKECMDGOALS) zone=<zone>"; exit 1)

# Require domain variable
.check-domain:
	@[ -n "$(domain)" ] || (echo "❌ Usage: make $(MAKECMDGOALS) zone=<zone> domain=<domain>"; exit 1)

# ── Local dev ────────────────────────────────────────────────────────────────

.PHONY: fmt
fmt: ## Format all Terraform and Terragrunt files
	terraform fmt -recursive terraform/
	terragrunt hclfmt

.PHONY: lint
lint: ## Run tflint on the module
	tflint --init
	tflint --recursive --format compact

.PHONY: hooks
hooks: ## Install pre-commit hooks
	pre-commit install

.PHONY: hooks-run
hooks-run: ## Run all pre-commit hooks on all files
	pre-commit run --all-files

# ── Zone operations ──────────────────────────────────────────────────────────

.PHONY: init
init: .check-zone ## terragrunt init for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt init --terragrunt-non-interactive

.PHONY: plan
plan: .check-zone ## terragrunt plan for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt plan --terragrunt-non-interactive

.PHONY: apply
apply: .check-zone ## terragrunt apply for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt apply --terragrunt-non-interactive

.PHONY: validate
validate: .check-zone ## terragrunt validate for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt validate --terragrunt-non-interactive

.PHONY: state-list
state-list: .check-zone ## List all resources in state for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt state list

# ── State operations ─────────────────────────────────────────────────────────

.PHONY: import
import: .check-zone .check-domain ## Import a domain into state
	bash .github/scripts/state-ops.sh import-domain $(zone) $(domain)

.PHONY: remove
remove: .check-zone .check-domain ## Remove a domain from state
	bash .github/scripts/state-ops.sh remove-domain $(zone) $(domain)

.PHONY: move
move: .check-zone .check-domain ## Move a domain between zones (requires from_zone=<zone>)
	@[ -n "$(from_zone)" ] || (echo "❌ Usage: make move zone=<zone> domain=<domain> from_zone=<zone>"; exit 1)
	bash .github/scripts/state-ops.sh move-domain $(zone) $(domain) $(from_zone)

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "Usage: make <target> [zone=<zone>] [domain=<domain>] [from_zone=<zone>]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

.DEFAULT_GOAL := help
