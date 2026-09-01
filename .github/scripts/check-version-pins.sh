#!/usr/bin/env bash
# Fail when a *_VERSION pin that appears in more than one workflow disagrees
# between them.
#
# These pins are plain env strings, so Dependabot cannot see them and nothing
# fails when a bump misses a file. Terragrunt 1.1.4 sat unnoticed for two weeks
# and then had to be edited in four places by hand; a lock refresh had already
# left the README naming a provider build that was no longer locked. Drift here
# is silent by default, so it gets a check of its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

WORKFLOWS="$(cd "${SCRIPT_DIR}/../workflows" && pwd)"
SETUP_ACTION="$(cd "${SCRIPT_DIR}/../actions/setup-iac" && pwd)/action.yml"

# Terraform and Terragrunt are declared once, as input defaults on the setup
# action. A workflow that pins them again would win for its own jobs and drift
# away silently, so reintroducing the env key is itself the failure.
for key in TERRAFORM_VERSION TERRAGRUNT_VERSION; do
  if grep -qE "^  ${key}:" "${WORKFLOWS}"/*.yml; then
    log_error "${key} is pinned in a workflow; it belongs to ${SETUP_ACTION##*/.github/} alone:"
    grep -nE "^  ${key}:" "${WORKFLOWS}"/*.yml | sed 's|.*/workflows/|    |' >&2
    exit 1
  fi
done

# Workflow-level env only: keys are indented exactly two spaces.
keys="$(grep -hoE '^  [A-Z][A-Z0-9_]*_VERSION:' "${WORKFLOWS}"/*.yml | tr -d ' :' | sort -u)"

if [ -z "$keys" ]; then
  log_error "No *_VERSION pins found in ${WORKFLOWS} — has the env layout changed?"
  exit 1
fi

# The action's own pins, reported so the log shows every version in one place.
for input in terraform-version terragrunt-version; do
  value="$(awk -v k="  ${input}:" '$0 == k {found=1; next} found && /^  [a-z-]+:/ {exit} found' "$SETUP_ACTION" |
    sed -nE 's/^    default: "(.*)"$/\1/p' | head -1)"
  [ -n "$value" ] || { log_error "setup-iac declares no default for ${input}"; exit 1; }
  log_info "${input} = ${value} (setup-iac)"
done

drifted=0

for key in $keys; do
  values="$(grep -hE "^  ${key}:" "${WORKFLOWS}"/*.yml |
    sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | sort -u)"

  if [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" -gt 1 ]; then
    log_error "${key} disagrees between workflows:"
    grep -nE "^  ${key}:" "${WORKFLOWS}"/*.yml | sed 's|.*/workflows/|    |' >&2
    drifted=1
  else
    log_info "${key} = ${values}"
  fi
done

if [ "$drifted" -ne 0 ]; then
  log_error "Every workflow that pins a tool must pin the same version."
  exit 1
fi

log_success "All version pins agree across workflows."
