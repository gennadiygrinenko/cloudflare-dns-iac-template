#!/usr/bin/env bash
# Apply the plan that plan-zone.sh left for this zone.
#
# Exactly one of two files must be present. A NO_CHANGES marker means the plan
# was empty and there is nothing to do; a tfplan means apply it. Neither means
# the artifact never arrived, which is a failure -- treating it as "no changes"
# is what let a broken plan report success.
#
# Usage: apply-zone.sh <zone-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ZONE_DIR="${1:?Usage: apply-zone.sh <zone-dir>}"
[ -d "$ZONE_DIR" ] || error_exit 1 "Zone directory not found: ${ZONE_DIR}"

ZONE="$(basename "$ZONE_DIR")"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log_section "Apply: ${ZONE}"

if [ -f "${ZONE_DIR}/NO_CHANGES" ]; then
  log_info "Plan reported no changes for ${ZONE} — nothing to apply."
  echo "### ${ZONE}: no changes ⬛" >>"$SUMMARY"
  exit 0
fi

if [ ! -f "${ZONE_DIR}/tfplan" ]; then
  error_exit 1 "Artifact for ${ZONE} has neither a plan nor a no-changes marker."
fi

cd "$ZONE_DIR"
terragrunt apply "${PWD}/tfplan" --non-interactive
log_success "Applied: ${ZONE}"
echo "### Applied: ${ZONE} ✅" >>"$SUMMARY"
