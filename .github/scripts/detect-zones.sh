#!/usr/bin/env bash
# Detect which zones to process.
#
# When called with two SHAs (PR mode), returns only zones that changed.
# When called with no args (push to main mode), returns all zones with domains.
#
# Outputs (via GITHUB_OUTPUT):
#   zones       - JSON array of zone names
#   any_changes - "true" | "false" (PR mode only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BASE_SHA="${1:-}"
HEAD_SHA="${2:-}"
ZONES_DIR="envs/cloudflare/zones"

# Compact JSON array from newline-separated names. jq pretty-prints by default;
# multiline values break GITHUB_OUTPUT (Invalid format '  "acme",').
to_json_array() {
  jq -cRn '[inputs | select(length > 0)]'
}

list_all_zones_with_domains() {
  for dir in "${ZONES_DIR}"/*/; do
    zone=$(basename "$dir")
    if grep -qE '^\s*"[^"]+"\s*=' "${dir}variables.auto.tfvars" 2>/dev/null; then
      echo "$zone"
    fi
  done
}

# Paths that affect every zone: the module itself, the shared Terragrunt HCL,
# and the CI that runs them. A change here validated against zero zones tells
# you nothing, which is how an action bump can look tested without being run.
SHARED_PATHS='^(terraform/modules/|envs/cloudflare/[^/]+\.hcl|\.github/(workflows|scripts)/)'

if [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]; then
  # PR mode: shared change → validate all zones; otherwise only changed zones
  if git diff --name-only "$BASE_SHA" "$HEAD_SHA" | grep -qE "$SHARED_PATHS"; then
    log_info "Shared module, config, or CI changed — validating all zones."
    ZONES=$(list_all_zones_with_domains | to_json_array)
  else
    ZONES=$(
      git diff --name-only "$BASE_SHA" "$HEAD_SHA" \
        | { grep "^${ZONES_DIR}/" || true; } \
        | sed "s|^${ZONES_DIR}/\([^/]*\)/.*|\1|" \
        | sort -u \
        | to_json_array
    )
  fi

  if [ "$ZONES" = "[]" ]; then
    echo "any_changes=false" >> "$GITHUB_OUTPUT"
  else
    echo "any_changes=true" >> "$GITHUB_OUTPUT"
  fi
else
  # Push-to-main mode: all zones with domains
  ZONES=$(list_all_zones_with_domains | to_json_array)
fi

log_info "Zones detected: $ZONES"
{
  echo "zones<<EOF"
  echo "$ZONES"
  echo "EOF"
} >> "$GITHUB_OUTPUT"
