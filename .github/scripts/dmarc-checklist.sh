#!/usr/bin/env bash
# Collect DMARC report authorizations that this repo cannot publish itself.
#
# The module knows a rua mailbox sits in an unmanaged zone but cannot create
# the record there, so it reports the gap through two outputs. Both are pure
# functions of var.domains, so a plan is enough — no state, no credentials.
#
# Inputs (env):
#   ZONES - JSON array of zone names, from detect-zones.sh
# Outputs:
#   /tmp/dmarc-checklist.md  - PR comment body (only when findings exist)
#   has_findings             - "true" | "false" (via GITHUB_OUTPUT)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BODY="/tmp/dmarc-checklist.md"
ROWS="$(mktemp)"
WARNINGS="$(mktemp)"

for zone in $(echo "${ZONES:-[]}" | jq -r '.[]'); do
  zone_dir="${REPO_ROOT}/envs/cloudflare/zones/${zone}"
  [ -d "$zone_dir" ] || continue

  log_info "Planning ${zone} for DMARC outputs..."
  if ! (cd "$zone_dir" && terragrunt plan -out=tfplan.dmarc >/dev/null 2>&1); then
    log_warning "Plan failed for ${zone} — skipping its checklist."
    continue
  fi

  plan_json="$(cd "$zone_dir" && terraform show -json tfplan.dmarc)"
  rm -f "${zone_dir}/tfplan.dmarc"

  jq -r --arg zone "$zone" '
    (.planned_values.outputs.dmarc_external_authorizations_required.value // {})
    | to_entries[]
    | "| \($zone) | \(.key) | `\(.value.fqdn)` | `\(.value.content)` | \(.value.note) |"
  ' <<<"$plan_json" >>"$ROWS"

  jq -r --arg zone "$zone" '
    (.planned_values.outputs.dmarc_report_delegation_warnings.value // {})
    | to_entries[]
    | "- **\($zone) / \(.key)**: \(.value)"
  ' <<<"$plan_json" >>"$WARNINGS"
done

if [ ! -s "$ROWS" ] && [ ! -s "$WARNINGS" ]; then
  log_success "No external DMARC authorizations required."
  echo "has_findings=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

{
  echo "## DMARC report authorizations to verify"
  echo
  if [ -s "$ROWS" ]; then
    echo "These domains send aggregate reports to a mailbox in a zone this repo does not manage. Per RFC 7489 §7.1 the record below must exist **in the receiving zone**, or reports are silently dropped. Report vendors publish a wildcard themselves — verify rather than assume."
    echo
    echo "| Zone | Domain | Record | Value | Where |"
    echo "|---|---|---|---|---|"
    cat "$ROWS"
    echo
  fi
  if [ -s "$WARNINGS" ]; then
    echo "### Missing NS delegation"
    echo
    echo "An authorization record is planned in a managed child zone that its managed parent does not delegate to, so nothing would answer the query."
    echo
    cat "$WARNINGS"
    echo
  fi
  echo "_Advisory only — this check never fails the PR._"
} >"$BODY"

log_warning "DMARC checklist has findings — see the PR comment."
echo "has_findings=true" >>"$GITHUB_OUTPUT"
