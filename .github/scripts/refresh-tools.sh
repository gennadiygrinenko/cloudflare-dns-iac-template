#!/usr/bin/env bash
# Move every tool pin to the newest release, then let the pins check confirm
# the result is still declared in one place.
#
# No Dependabot ecosystem reads mise.toml or a workflow env string, so nothing
# tells anyone a newer release exists. This is the half that does: `mise
# latest` for the tools mise.toml pins, the GitHub releases API for Trivy,
# which its own action installs from a workflow env.
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
WORKFLOWS="${ROOT}/.github/workflows"

# tool : GitHub repository, for the release-notes link in the summary.
MISE_TOOLS=(
  "terraform:hashicorp/terraform"
  "terragrunt:gruntwork-io/terragrunt"
  "tflint:terraform-linters/tflint"
  "pre-commit:pre-commit/pre-commit"
  "shellcheck:koalaman/shellcheck"
  "jq:jqlang/jq"
)
ENV_TOOLS=(
  "TRIVY_VERSION:aquasecurity/trivy"
)

summary=""

mise_pin() {
  sed -nE "s/^${1}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$MISE" | head -1
}

# Releases come back newest-first by date, which is not newest by version: a
# patch on an older line can be published after a new minor. Sort instead.
latest_release() {
  gh api "repos/${1}/releases" --paginate --jq \
    '.[] | select(.prerelease == false and .draft == false) | .tag_name' 2>/dev/null |
    sed 's/^v//' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
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

for entry in "${ENV_TOOLS[@]}"; do
  key="${entry%%:*}"; repo="${entry#*:}"
  current="$(grep -hE "^  ${key}:" "${WORKFLOWS}"/*.yml 2>/dev/null | head -1 |
    sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  [ -n "$current" ] || error_exit 1 "${key} is not pinned in any workflow"
  latest="$(latest_release "$repo")"
  [ -n "$latest" ] || error_exit 1 "Could not read a release version for ${repo}"
  # Keep whatever prefix the pin already uses; the installer that consumes it
  # expects that style.
  prefix=""; [ "${current#v}" != "$current" ] && prefix="v"
  target="${prefix}${latest}"
  if [ "${current#v}" = "$latest" ]; then
    log_info "${key}: ${current} is current"
    continue
  fi
  log_warning "${key}: ${current} → ${target}"
  summary="${summary}- \`${key}\`: ${current} → ${target} ([release notes](https://github.com/${repo}/releases/tag/v${latest}))"$'\n'
  for f in "${WORKFLOWS}"/*.yml; do
    grep -qE "^  ${key}: \"${current}\"$" "$f" || continue
    sed -i.bak -E "s|^(  ${key}: )\"${current}\"$|\1\"${target}\"|" "$f"
    rm -f "${f}.bak"
  done
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
