#!/usr/bin/env bash
# Terraform state operations: import-domain, remove-domain, move-domain.
# Called by the state-ops GitHub Actions workflow.
#
# Usage: state-ops.sh <operation> <zone> <domain> [from_zone]
set -euo pipefail

OPERATION="${1:?operation required}"
ZONE="${2:?zone required}"
DOMAIN="${3:?domain required}"
FROM_ZONE="${4:-}"

ZONES_DIR="envs/cloudflare/zones"
ZONE_DIR="${ZONES_DIR}/${ZONE}"

log()    { echo "  $*"; }
ok()     { echo "✅ $*"; }
warn()   { echo "⚠️  $*"; }
die()    { echo "❌ $*" >&2; exit 1; }
section(){ echo ""; echo "── $* ──────────────────────────────────────"; }

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
  section "Import domain: ${DOMAIN} → zone: ${ZONE}"
  [ -d "$ZONE_DIR" ] || die "Zone directory not found: ${ZONE_DIR}"

  ZONE_ID=$(get_zone_id "$DOMAIN") || die "Could not fetch zone ID for ${DOMAIN}"
  [ -n "$ZONE_ID" ]                || die "Zone ID empty for ${DOMAIN} — is it in Cloudflare?"

  log "Zone ID: ${ZONE_ID}"
  tg_init "$ZONE_DIR"

  # Import the zone resource itself
  RESOURCE="module.dns_zone.cloudflare_zone.this[\"${DOMAIN}\"]"
  if terragrunt state list 2>/dev/null | grep -qF "$RESOURCE"; then
    warn "${DOMAIN} already in state — skipping zone import."
  else
    log "Importing zone ${DOMAIN}..."
    terragrunt import --terragrunt-non-interactive "$RESOURCE" "$ZONE_ID"
    ok "Zone imported."
  fi

  log "DNS records will sync on next apply."
}

remove_domain() {
  section "Remove domain: ${DOMAIN} from zone: ${ZONE}"
  [ -d "$ZONE_DIR" ] || die "Zone directory not found: ${ZONE_DIR}"

  tg_init "$ZONE_DIR"

  RESOURCES=$(terragrunt state list 2>/dev/null | grep "\"${DOMAIN}\"" || true)
  if [ -z "$RESOURCES" ]; then
    warn "${DOMAIN} not found in state — nothing to remove."
    exit 0
  fi

  log "Resources to remove:"
  echo "$RESOURCES" | sed 's/^/    /'

  echo "$RESOURCES" | while IFS= read -r resource; do
    [ -z "$resource" ] && continue
    log "Removing: ${resource}"
    terragrunt state rm "$resource"
  done

  ok "All resources for ${DOMAIN} removed from state."
}

move_domain() {
  section "Move domain: ${DOMAIN} from ${FROM_ZONE} → ${ZONE}"
  [ -n "$FROM_ZONE" ] || die "from_zone required for move-domain"

  FROM_DIR="${ZONES_DIR}/${FROM_ZONE}"
  [ -d "$FROM_DIR" ] || die "Source zone directory not found: ${FROM_DIR}"
  [ -d "$ZONE_DIR" ] || die "Target zone directory not found: ${ZONE_DIR}"

  # Remove from source
  log "Removing ${DOMAIN} from ${FROM_ZONE} state..."
  tg_init "$FROM_DIR"
  RESOURCES=$(terragrunt state list 2>/dev/null | grep "\"${DOMAIN}\"" || true)
  if [ -n "$RESOURCES" ]; then
    echo "$RESOURCES" | while IFS= read -r resource; do
      [ -z "$resource" ] && continue
      terragrunt state rm "$resource"
    done
    ok "Removed from ${FROM_ZONE}."
  else
    warn "${DOMAIN} not found in ${FROM_ZONE} state."
  fi

  # Import to target
  log "Importing ${DOMAIN} into ${ZONE}..."
  import_domain
  ok "${DOMAIN} moved from ${FROM_ZONE} to ${ZONE}."
}

case "$OPERATION" in
  import-domain) import_domain ;;
  remove-domain) remove_domain ;;
  move-domain)   move_domain ;;
  *) die "Unknown operation: ${OPERATION}. Use: import-domain | remove-domain | move-domain" ;;
esac
