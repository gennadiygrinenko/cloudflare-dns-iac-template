#!/usr/bin/env bash
# Terraform state operations: import-domain, remove-domain, move-domain.
# Called by the state-ops GitHub Actions workflow.
#
# Usage: state-ops.sh <operation> <zone> <domain> [from_zone]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

OPERATION="${1:?operation required}"
ZONE="${2:?zone required}"
DOMAIN="${3:?domain required}"
FROM_ZONE="${4:-}"

ZONES_DIR="envs/cloudflare/zones"
ZONE_DIR="${ZONES_DIR}/${ZONE}"

get_zone_id() {
  local domain="$1"
  curl -sSf -X GET "https://api.cloudflare.com/client/v4/zones?name=${domain}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    | jq -r '.result[0].id // empty'
}

tg_init() {
  local dir="$1"
  cd "$dir"
  terragrunt init --terragrunt-non-interactive -reconfigure 2>&1 | tail -5
}

import_domain() {
  log_section "Import domain: ${DOMAIN} → zone: ${ZONE}"
  [ -d "$ZONE_DIR" ] || error_exit 1 "Zone directory not found: ${ZONE_DIR}"

  ZONE_ID=$(get_zone_id "$DOMAIN") || error_exit 1 "Could not fetch zone ID for ${DOMAIN}"
  [ -n "$ZONE_ID" ]                || error_exit 1 "Zone ID empty for ${DOMAIN} — is it in Cloudflare?"

  log_info "Zone ID: ${ZONE_ID}"
  tg_init "$ZONE_DIR"

  RESOURCE="module.dns_zone.cloudflare_zone.this[\"${DOMAIN}\"]"
  if terragrunt state list 2>/dev/null | grep -qF "$RESOURCE"; then
    log_warning "${DOMAIN} already in state — skipping zone import."
  else
    log_info "Importing zone ${DOMAIN}..."
    terragrunt import --terragrunt-non-interactive "$RESOURCE" "$ZONE_ID"
    log_success "Zone imported."
  fi

  log_info "DNS records will sync on next apply."
}

remove_domain() {
  log_section "Remove domain: ${DOMAIN} from zone: ${ZONE}"
  [ -d "$ZONE_DIR" ] || error_exit 1 "Zone directory not found: ${ZONE_DIR}"

  tg_init "$ZONE_DIR"

  RESOURCES=$(terragrunt state list 2>/dev/null | grep "\"${DOMAIN}\"" || true)
  if [ -z "$RESOURCES" ]; then
    log_warning "${DOMAIN} not found in state — nothing to remove."
    exit 0
  fi

  log_info "Resources to remove:"
  echo "$RESOURCES" | sed 's/^/    /'

  echo "$RESOURCES" | while IFS= read -r resource; do
    [ -z "$resource" ] && continue
    log_info "Removing: ${resource}"
    terragrunt state rm "$resource"
  done

  log_success "All resources for ${DOMAIN} removed from state."
}

move_domain() {
  log_section "Move domain: ${DOMAIN} from ${FROM_ZONE} → ${ZONE}"
  [ -n "$FROM_ZONE" ] || error_exit 1 "from_zone required for move-domain"

  FROM_DIR="${ZONES_DIR}/${FROM_ZONE}"
  [ -d "$FROM_DIR" ] || error_exit 1 "Source zone directory not found: ${FROM_DIR}"
  [ -d "$ZONE_DIR" ] || error_exit 1 "Target zone directory not found: ${ZONE_DIR}"

  log_info "Removing ${DOMAIN} from ${FROM_ZONE} state..."
  tg_init "$FROM_DIR"
  RESOURCES=$(terragrunt state list 2>/dev/null | grep "\"${DOMAIN}\"" || true)
  if [ -n "$RESOURCES" ]; then
    echo "$RESOURCES" | while IFS= read -r resource; do
      [ -z "$resource" ] && continue
      terragrunt state rm "$resource"
    done
    log_success "Removed from ${FROM_ZONE}."
  else
    log_warning "${DOMAIN} not found in ${FROM_ZONE} state."
  fi

  log_info "Importing ${DOMAIN} into ${ZONE}..."
  import_domain
  log_success "${DOMAIN} moved from ${FROM_ZONE} to ${ZONE}."
}

case "$OPERATION" in
  import-domain) import_domain ;;
  remove-domain) remove_domain ;;
  move-domain)   move_domain ;;
  *) error_exit 1 "Unknown operation: ${OPERATION}. Use: import-domain | remove-domain | move-domain" ;;
esac
