#!/usr/bin/env bash
# Plan one zone and leave behind exactly one artifact: a plan file when there
# are changes, or a NO_CHANGES marker when there are none.
#
# The marker is the point. An apply that finds neither file has to be able to
# tell "nothing to do" from "the upload broke" -- inferring the first from an
# absent file is how this pipeline once reported success while planning had
# failed outright.
#
# Usage: plan-zone.sh <zone-dir>
# Outputs (via GITHUB_OUTPUT when set):
#   no_changes - "true" | "false"
# Exits non-zero when the plan itself failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ZONE_DIR="${1:?Usage: plan-zone.sh <zone-dir>}"
[ -d "$ZONE_DIR" ] || error_exit 1 "Zone directory not found: ${ZONE_DIR}"

ZONE="$(basename "$ZONE_DIR")"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
LOG="$(mktemp)"

log_section "Plan: ${ZONE}"
cd "$ZONE_DIR" || error_exit 1 "Cannot enter ${ZONE_DIR}"

# -detailed-exitcode: 0 = no changes, 2 = changes, anything else is a real
# failure. Grepping the log for "No changes." cannot tell an empty plan from a
# broken one, and the pipe to tee hides the exit code unless PIPESTATUS is read.
# -out must be absolute: Terragrunt runs OpenTofu/Terraform inside
# .terragrunt-cache, so a relative path saves the plan there.
terragrunt plan -out="${PWD}/tfplan" -detailed-exitcode --non-interactive 2>&1 | tee "$LOG"
EXIT_CODE=${PIPESTATUS[0]}

echo "### Plan: ${ZONE}" >>"$SUMMARY"

case "$EXIT_CODE" in
  0)
    log_info "No changes detected."
    rm -f tfplan && touch NO_CHANGES
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "no_changes=true" >>"$GITHUB_OUTPUT"
    echo "⬛ No changes." >>"$SUMMARY"
    ;;
  2)
    log_success "Changes detected — plan saved."
    rm -f NO_CHANGES
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "no_changes=false" >>"$GITHUB_OUTPUT"
    {
      echo '```hcl'
      grep -A 999 "Terraform will perform" "$LOG" | head -60 || true
      echo '```'
    } >>"$SUMMARY"
    ;;
  *)
    log_error "Plan failed for ${ZONE} (exit ${EXIT_CODE})."
    {
      echo "❌ Plan failed."
      echo '```'
      tail -40 "$LOG"
      echo '```'
    } >>"$SUMMARY"
    exit "$EXIT_CODE"
    ;;
esac
