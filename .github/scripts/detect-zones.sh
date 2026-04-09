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

BASE_SHA="${1:-}"
HEAD_SHA="${2:-}"
ZONES_DIR="envs/cloudflare/zones"

list_all_zones_with_domains() {
  for dir in "${ZONES_DIR}"/*/; do
    zone=$(basename "$dir")
    if grep -qE '^\s*"[^"]+"\s*=' "${dir}variables.auto.tfvars" 2>/dev/null; then
      echo "$zone"
    fi
  done
}

if [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]; then
  # PR mode: check if modules changed → validate all; otherwise only changed zones
  if git diff --name-only "$BASE_SHA" "$HEAD_SHA" | grep -q '^terraform/modules/'; then
    echo "Terraform modules changed — validating all zones." >&2
    ZONES=$(list_all_zones_with_domains | jq -Rn '[inputs]')
  else
    ZONES=$(
      git diff --name-only "$BASE_SHA" "$HEAD_SHA" \
        | grep "^${ZONES_DIR}/" \
        | sed "s|^${ZONES_DIR}/\([^/]*\)/.*|\1|" \
        | sort -u \
        | jq -Rn '[inputs]'
    )
  fi

  if [ "$ZONES" = "[]" ]; then
    echo "any_changes=false" >> "$GITHUB_OUTPUT"
  else
    echo "any_changes=true" >> "$GITHUB_OUTPUT"
  fi
else
  # Push-to-main mode: all zones with domains
  ZONES=$(list_all_zones_with_domains | jq -Rn '[inputs]')
fi

echo "Zones detected: $ZONES" >&2
echo "zones=$ZONES" >> "$GITHUB_OUTPUT"
