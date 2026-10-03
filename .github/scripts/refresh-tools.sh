#!/usr/bin/env bash
# Move every tool pin to the newest release, then let the pins check confirm
# the result is still declared in one place.
#
# No Dependabot ecosystem reads mise.toml, so nothing tells anyone a newer
# release exists. This is the half that does, with `mise latest`. It only ever
# rewrites mise.toml: GITHUB_TOKEN may not push edits to .github/workflows/.
#
# Outputs (via GITHUB_OUTPUT when set):
#   changed - "true" | "false"
#   summary - one markdown line per tool that moved
#
# Testing hooks: PINS_ROOT=<dir> points at another repository root; `mise` and
# `gh` are found on PATH, so a test can stub them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ROOT="${PINS_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
MISE="${ROOT}/mise.toml"

# tool : GitHub repository, for the release-notes link in the summary.
MISE_TOOLS=(
  "terraform:hashicorp/terraform"
  "terragrunt:gruntwork-io/terragrunt"
  "tflint:terraform-linters/tflint"
  "pre-commit:pre-commit/pre-commit"
  "shellcheck:koalaman/shellcheck"
  "jq:jqlang/jq"
  "trivy:aquasecurity/trivy"
)

summary=""

mise_pin() {
  sed -nE "s/^${1}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$MISE" | head -1
}

for entry in "${MISE_TOOLS[@]}"; do
  tool="${entry%%:*}"; repo="${entry#*:}"
  current="$(mise_pin "$tool")"
  [ -n "$current" ] || continue # not pinned here; nothing to move
  latest="$(mise latest "$tool" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$latest" ] || error_exit 1 "mise could not resolve the latest ${tool}"
  if [ "$current" = "$latest" ]; then
    log_info "${tool}: ${current} is current"
    continue
  fi
  log_warning "${tool}: ${current} → ${latest}"
  summary="${summary}- \`${tool}\`: ${current} → ${latest} ([release notes](https://github.com/${repo}/releases/tag/v${latest}))"$'\n'
  sed -i.bak -E "s|^(${tool}[[:space:]]*=[[:space:]]*)\"${current}\"|\1\"${latest}\"|" "$MISE"
  rm -f "${MISE}.bak"
done

# A rewrite that left a second declaration behind, or broke a pin, is exactly
# what the pins check exists to catch. Use it.
PINS_ROOT="$ROOT" bash "${SCRIPT_DIR}/check-version-pins.sh" >/dev/null ||
  error_exit 1 "Rewrite left the tool pins in a state the pins check rejects"

if [ -z "$summary" ]; then
  log_success "Every tool pin is already on the newest release."
  changed=false
else
  changed=true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed=${changed}"
    echo "summary<<EOF"
    printf '%s' "$summary"
    echo "EOF"
  } >>"$GITHUB_OUTPUT"
fi
