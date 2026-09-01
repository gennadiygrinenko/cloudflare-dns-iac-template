#!/usr/bin/env bash
# Move the tool version pins to the newest release each project has published.
#
# These are plain env strings, not manifest entries, so no Dependabot ecosystem
# reaches them: Terragrunt 1.1.4 sat unnoticed for two weeks and Terraform
# 1.16.0 was found only because somebody went and looked. The Version pins
# check keeps the four workflows agreeing with each other; it has no idea a
# newer release exists. This is the half that does.
#
# Outputs (via GITHUB_OUTPUT when set):
#   changed    - "true" | "false"
#   summary    - one markdown line per tool that moved
#   terraform  - the resulting TERRAFORM_VERSION, so the caller can install it
#   terragrunt - the resulting TERRAGRUNT_VERSION

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

WORKFLOWS="$(cd "${SCRIPT_DIR}/../workflows" && pwd)"
SETUP_ACTION="$(cd "${SCRIPT_DIR}/../actions/setup-iac" && pwd)/action.yml"

# key : GitHub repository
# Terraform and Terragrunt live as input defaults on the setup action, the rest
# as env in the one workflow that uses them. Two homes, so two rewrites.
TOOLS=(
  "TERRAFORM_VERSION:hashicorp/terraform"
  "TERRAGRUNT_VERSION:gruntwork-io/terragrunt"
  "TFLINT_VERSION:terraform-linters/tflint"
  "TRIVY_VERSION:aquasecurity/trivy"
  "PRE_COMMIT_VERSION:pre-commit/pre-commit"
)

# Empty unless the key is one the setup action owns.
action_input_for() {
  case "$1" in
    TERRAFORM_VERSION) echo "terraform-version" ;;
    TERRAGRUNT_VERSION) echo "terragrunt-version" ;;
    *) echo "" ;;
  esac
}

current_pin() {
  local input; input="$(action_input_for "$1")"
  if [ -n "$input" ]; then
    awk -v k="  ${input}:" '$0 == k {found=1; next} found && /^  [a-z-]+:/ {exit} found' "$SETUP_ACTION" |
      sed -nE 's/^    default: "(.*)"$/\1/p' | head -1
  else
    grep -hE "^  ${1}:" "${WORKFLOWS}"/*.yml | head -1 |
      sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
  fi
}

# Releases come back newest-first by date, which is not newest by version: a
# patch on an older line can be published after a new minor. Sort instead.
latest_release() {
  gh api "repos/${1}/releases" --paginate --jq \
    '.[] | select(.prerelease == false and .draft == false) | .tag_name' 2>/dev/null |
    sed 's/^v//' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
}

summary=""

for entry in "${TOOLS[@]}"; do
  key="${entry%%:*}"
  repo="${entry#*:}"

  current="$(current_pin "$key")"
  [ -n "$current" ] || error_exit 1 "${key} is not pinned in any workflow"

  latest="$(latest_release "$repo")"
  [ -n "$latest" ] || error_exit 1 "Could not read a release version for ${repo}"

  # Each pin keeps whatever prefix it already uses -- tflint writes v0.64.0,
  # Trivy writes 0.74.0, and rewriting one into the other's style breaks the
  # installer that consumes it.
  prefix=""
  [ "${current#v}" != "$current" ] && prefix="v"
  target="${prefix}${latest}"

  if [ "${current#v}" = "$latest" ]; then
    log_info "${key}: ${current} is current"
    continue
  fi

  log_warning "${key}: ${current} → ${target}"
  summary="${summary}- \`${key}\`: ${current} → ${target} ([release notes](https://github.com/${repo}/releases/tag/v${latest}))"$'\n'

  input="$(action_input_for "$key")"
  if [ -n "$input" ]; then
    # One default line, inside that input's block.
    awk -v k="  ${input}:" -v cur="    default: \"${current}\"" -v new="    default: \"${target}\"" '
      $0 == k { inblock = 1 }
      inblock && $0 == cur { print new; inblock = 0; next }
      inblock && /^  [a-z-]+:/ && $0 != k { inblock = 0 }
      { print }
    ' "$SETUP_ACTION" >"${SETUP_ACTION}.tmp"
    mv "${SETUP_ACTION}.tmp" "$SETUP_ACTION"
  else
    for f in "${WORKFLOWS}"/*.yml; do
      grep -qE "^  ${key}: \"${current}\"$" "$f" || continue
      sed -i.bak -E "s|^(  ${key}: )\"${current}\"$|\1\"${target}\"|" "$f"
      rm -f "${f}.bak"
    done
  fi
done

# A rewrite that missed a file would leave the pins disagreeing, which is the
# exact failure this repo already has a check for. Use it.
bash "${SCRIPT_DIR}/check-version-pins.sh" >/dev/null ||
  error_exit 1 "Rewrite left the pins disagreeing between workflows"

if [ -z "$summary" ]; then
  log_success "Every tool pin is already on the newest release."
  changed=false
else
  changed=true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed=${changed}"
    echo "terraform=$(current_pin TERRAFORM_VERSION)"
    echo "terragrunt=$(current_pin TERRAGRUNT_VERSION)"
    echo "summary<<EOF"
    printf '%s' "$summary"
    echo "EOF"
  } >>"$GITHUB_OUTPUT"
fi
