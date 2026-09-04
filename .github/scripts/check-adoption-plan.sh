#!/usr/bin/env bash
# Refuse to apply an adoption plan that does anything but adopt.
#
# Bringing a live zone under management ends in one apply, and that apply may
# only import: every record already exists, and the configuration was written
# to mirror it. A plan that also updates, replaces or deletes something means
# the mirror is wrong — on a zone that serves mail, MX and TXT are exactly what
# would be replaced — and the place to learn that is here, not in the apply.
#
# Allowed: imports (a no-op change carrying `importing`), plain no-ops, data
# reads, and `create` for cloudflare_zone_setting only: settings cannot be
# imported through `make imports`, and creating one with the value the zone
# already has is a PATCH to the same value. Anything else fails the run and is
# listed by address.
#
# Usage: check-adoption-plan.sh <plan.json>      (terraform show -json <plan>)
# Writes a table to GITHUB_STEP_SUMMARY when set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PLAN="${1:?Usage: check-adoption-plan.sh <plan.json>}"
[ -f "$PLAN" ] || error_exit 1 "Plan JSON not found: ${PLAN}"
jq -e '.resource_changes? | type == "array"' "$PLAN" >/dev/null 2>&1 ||
  error_exit 1 "${PLAN} is not a terraform show -json plan (no resource_changes array)."

report="$(jq '
  [.resource_changes[] | {
    address,
    type,
    actions: .change.actions,
    importing: ((.change.importing // null) != null),
  }]
  | {
      imports:  [ .[] | select(.importing and .actions == ["no-op"]) | .address ],
      settings: [ .[] | select((.importing | not) and .actions == ["create"] and .type == "cloudflare_zone_setting") | .address ],
      rejected: [ .[]
        | select(
            (.importing and .actions == ["no-op"]) or
            .actions == ["no-op"] or .actions == ["read"] or
            (.actions == ["create"] and .type == "cloudflare_zone_setting")
          | not)
        | "\(.address): \(.actions | join(","))" ],
    }
' "$PLAN")"

count() { jq ".$1 | length" <<<"$report"; }
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "### Adoption plan"
  echo
  echo "| What | Count |"
  echo "| --- | --- |"
  echo "| Records and zones imported | $(count imports) |"
  echo "| Zone settings written with their current value | $(count settings) |"
  echo "| Changes that are not an adoption | $(count rejected) |"
  if [ "$(count rejected)" -gt 0 ]; then
    echo
    echo "Refused. These would change the zone rather than adopt it:"
    echo
    jq -r '.rejected[] | "- `\(.)`"' <<<"$report"
  fi
} >>"$SUMMARY"

log_info "$(count imports) import(s), $(count settings) zone setting(s) to write with their current value."

if [ "$(count rejected)" -gt 0 ]; then
  log_error "The plan would change the zone, not only adopt it:"
  jq -r '.rejected[] | "    \(.)"' <<<"$report" >&2
  error_exit 1 "Fix the configuration until the plan shows imports only; do not apply this."
fi

if [ "$(count imports)" -eq 0 ] && [ "$(count settings)" -eq 0 ]; then
  log_success "Nothing to adopt: the plan is empty."
  exit 0
fi

log_success "Adoption plan accepted: imports and same-value settings only."
