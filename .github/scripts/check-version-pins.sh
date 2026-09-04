#!/usr/bin/env bash
# Fail when a tool version is pinned anywhere but mise.toml, or when mise.toml
# does not pin what CI needs.
#
# Terragrunt 1.1.4 once sat unnoticed for two weeks and then had to be edited
# in four places by hand. The pins then moved to one action, and now to one
# file that a laptop reads too. A second declaration anywhere would win for
# whatever reads it and drift away silently, so reintroducing one is itself
# the failure. Workflow-level *_VERSION pins that remain (Trivy, installed by
# its own action) must still agree with each other.
#
# Testing hook: PINS_ROOT=<dir> points at a repository root other than this one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ROOT="${PINS_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
MISE="${ROOT}/mise.toml"
WORKFLOWS="${ROOT}/.github/workflows"
SETUP_ACTION="${ROOT}/.github/actions/setup-iac/action.yml"

# Tools CI cannot run without. pre-commit and the rest may be pinned too, but
# these three are required.
REQUIRED_TOOLS=(terraform terragrunt tflint)

# Env keys that used to carry these pins. Any of them in a workflow is a second
# source of truth.
MISE_OWNED_KEYS=(TERRAFORM_VERSION TERRAGRUNT_VERSION TFLINT_VERSION PRE_COMMIT_VERSION SHELLCHECK_VERSION JQ_VERSION)

[ -f "$MISE" ] || error_exit 1 "mise.toml not found at ${ROOT} — tool versions have no home."

mise_pin() {
  sed -nE "s/^${1}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$MISE" | head -1
}

failed=0

for tool in "${REQUIRED_TOOLS[@]}"; do
  pin="$(mise_pin "$tool")"
  if [ -z "$pin" ]; then
    log_error "mise.toml does not pin ${tool}."
    failed=1
  elif ! [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "mise.toml pins ${tool} = \"${pin}\"; an exact X.Y.Z version is required, or CI and laptops drift apart."
    failed=1
  else
    log_info "${tool} = ${pin} (mise.toml)"
  fi
done

for key in "${MISE_OWNED_KEYS[@]}"; do
  if grep -qE "^  ${key}:" "${WORKFLOWS}"/*.yml 2>/dev/null; then
    log_error "${key} is pinned in a workflow; that tool belongs to mise.toml alone:"
    grep -nE "^  ${key}:" "${WORKFLOWS}"/*.yml | sed 's|.*/workflows/|    |' >&2
    failed=1
  fi
done

if [ -f "$SETUP_ACTION" ] && grep -qE '^    default: "v?[0-9]+\.[0-9]+' "$SETUP_ACTION"; then
  log_error "setup-iac declares a version default; it must install from mise.toml:"
  grep -nE '^    default: "v?[0-9]+\.[0-9]+' "$SETUP_ACTION" | sed 's|^|    |' >&2
  failed=1
fi

# Whatever *_VERSION pins remain at workflow level must agree with each other.
keys="$(grep -hoE '^  [A-Z][A-Z0-9_]*_VERSION:' "${WORKFLOWS}"/*.yml 2>/dev/null | tr -d ' :' | sort -u || true)"
for key in $keys; do
  values="$(grep -hE "^  ${key}:" "${WORKFLOWS}"/*.yml |
    sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | sort -u)"
  if [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" -gt 1 ]; then
    log_error "${key} disagrees between workflows:"
    grep -nE "^  ${key}:" "${WORKFLOWS}"/*.yml | sed 's|.*/workflows/|    |' >&2
    failed=1
  else
    log_info "${key} = ${values} (workflow env)"
  fi
done

if [ "$failed" -ne 0 ]; then
  error_exit 1 "Tool versions are declared in more than one place, or mise.toml is incomplete."
fi

log_success "Tool versions are declared once, in mise.toml, and the remaining workflow pins agree."
