# Cloudflare DNS IaC — convenience commands
# Usage: make <target> [zone=<zone>] [domain=<domain>] [from_zone=<zone>]
#
# Examples:
#   make plan zone=acme
#   make apply zone=acme
#   make import zone=acme domain=acme-corp.io
#   make move zone=acme domain=acme-corp.io from_zone=legacy

ZONES_DIR := envs/cloudflare/zones

# Lock hashes are per platform: CI is linux_amd64, laptops are darwin_*.
# A lock without the CI platform fails init on the runner.
LOCK_PLATFORMS := -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64

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
	terragrunt hcl fmt

.PHONY: lint
lint: ## Run tflint on the module
	tflint --init
	tflint --recursive --format compact

.PHONY: test
test: ## Run module logic tests (plan-only, no credentials)
	terraform -chdir=terraform/modules/dns-zone init -backend=false -input=false
	terraform -chdir=terraform/modules/dns-zone test

.PHONY: mutants
mutants: ## Break the module on purpose, one edit at a time, and check the tests notice
	terraform -chdir=terraform/modules/dns-zone init -backend=false -input=false
	python3 terraform/modules/dns-zone/tests/mutants.py

.PHONY: hooks
hooks: ## Install pre-commit hooks
	pre-commit install

.PHONY: hooks-run
hooks-run: ## Run all pre-commit hooks on all files
	pre-commit run --all-files

# ── Zone operations ──────────────────────────────────────────────────────────

.PHONY: init
init: .check-zone ## terragrunt init for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt init --non-interactive

.PHONY: plan
plan: .check-zone ## terragrunt plan for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt plan --non-interactive

.PHONY: apply
apply: .check-zone ## terragrunt apply for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt apply --non-interactive

.PHONY: validate
validate: .check-zone ## terragrunt validate for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt validate --non-interactive

.PHONY: moves
moves: .check-zone ## Generate moved.tf for records whose address changed
	bash .github/scripts/plan-state-moves.sh $(zone)

.PHONY: state-list
state-list: .check-zone ## List all resources in state for a zone
	cd $(ZONES_DIR)/$(zone) && terragrunt state list

.PHONY: lock
lock: .check-zone ## Refresh .terraform.lock.hcl for a zone (all platforms)
	cd $(ZONES_DIR)/$(zone) && terragrunt init -backend=false --non-interactive \
		&& terragrunt run -- providers lock $(LOCK_PLATFORMS)

.PHONY: lock-upgrade
lock-upgrade: .check-zone ## Move a zone to the newest provider allowed by versions.tf
	cd $(ZONES_DIR)/$(zone) && terragrunt init -backend=false -upgrade --non-interactive \
		&& terragrunt run -- providers lock $(LOCK_PLATFORMS)

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
