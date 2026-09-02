#!/usr/bin/env bash
# Exercise the import-block generator without a cloud account.
#
# plan-record-imports.sh adopts records that already exist in Cloudflare by
# matching each live record to the address the configuration gives it. It is
# the step that makes a live domain — one that serves mail today — manageable
# without an apply that tries to recreate its records. A wrong match imports a
# record under another record's address, and the next plan then proposes to
# rewrite it. The script's fixture hooks skip Terragrunt and the API.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

DOMAIN="acme-corp.io"
ZONE_ID="0123456789abcdef0123456789abcdef"

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/repo/.github/scripts" "${WORK}/repo/envs/cloudflare/zones/acme"
  cp "${SCRIPTS}/plan-record-imports.sh" "${SCRIPTS}/common.sh" "${WORK}/repo/.github/scripts/"

  IMPORTS="${WORK}/repo/envs/cloudflare/zones/acme/imports.tf"
  OUTPUT="${WORK}/output.log"
  MANAGED="${WORK}/managed.jsonl"
  DESIRED="${WORK}/desired.jsonl"
  LIVE="${WORK}/live.json"
  : >"$MANAGED"
  : >"$DESIRED"
  echo '{}' >"$LIVE"
  live_zone "$DOMAIN" "$ZONE_ID"
}
teardown() { rm -rf "$WORK"; }

# A zone as Cloudflare reports it, with no records yet.
#   live_zone <domain> <zone_id>
live_zone() {
  jq -c --arg d "$1" --arg z "$2" '. + { ($d): { zone_id: $z, records: [] } }' "$LIVE" >"${LIVE}.tmp" && mv "${LIVE}.tmp" "$LIVE"
}

# A record as the Cloudflare API lists it: FQDN name, its own ID.
#   live_record <domain> <record_id> <type> <fqdn> <content> [priority]
live_record() {
  jq -c --arg d "$1" --arg id "$2" --arg type "$3" --arg name "$4" --arg content "$5" --argjson priority "${6:-null}" \
    '.[$d].records += [{ id: $id, type: $type, name: $name, content: $content, priority: $priority }]' \
    "$LIVE" >"${LIVE}.tmp" && mv "${LIVE}.tmp" "$LIVE"
}

# A record as the module's dns_records output describes it.
#   desired <key> <type> <name> <value> [priority] [domain]
desired() {
  local resource="cloudflare_dns_record.this"
  [ "$2" = "TXT" ] && resource="cloudflare_dns_record.txt"
  jq -nc --arg key "$1" --arg type "$2" --arg name "$3" --arg value "$4" --argjson priority "${5:-null}" \
    --arg domain "${6:-$DOMAIN}" --arg resource "$resource" \
    '{ key: $key, value: { domain: $domain, resource: $resource, type: $type, name: $name, value: $value, priority: $priority } }' \
    >>"$DESIRED"
}

# An address already in state.
managed() { for a in "$@"; do jq -nc --arg a "$a" '{ address: $a, type: "managed", values: {} }' >>"$MANAGED"; done; }

run_imports() {
  jq -sc '{ format_version: "1.0", values: { root_module: { child_modules: [ { address: "module.dns_zone", resources: . } ] } } }' \
    "$MANAGED" >"${WORK}/state.json"
  jq -sc '{ format_version: "1.2", planned_values: { outputs: { dns_records: { sensitive: false, value: (map({ (.key): .value }) | add // {}) } } } }' \
    "$DESIRED" >"${WORK}/plan.json"
  (cd "${WORK}/repo" && STATE_JSON_FILE="${WORK}/state.json" PLAN_JSON_FILE="${WORK}/plan.json" LIVE_JSON_FILE="$LIVE" \
    bash .github/scripts/plan-record-imports.sh "${1:-acme}" >"$OUTPUT" 2>&1)
}

import_blocks() { [ -f "$IMPORTS" ] && grep -c '^import {' "$IMPORTS" || echo 0; }
imports_to() { grep -qF "to = module.dns_zone.$1" "$IMPORTS" 2>/dev/null && echo yes || echo no; }
imports_id() { grep -qF "id = \"$1\"" "$IMPORTS" 2>/dev/null && echo yes || echo no; }
output_has() { grep -qF "$1" "$OUTPUT" && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

echo "plan-record-imports.sh"

# ── matching ─────────────────────────────────────────────────────────────

setup
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_imports
check "a live record gets an import block under its configured address" "0"   "$?"
check "the zone and the record are imported"                             "2"   "$(import_blocks)"
check "the record's address is the one the plan gives it"               "yes" "$(imports_to 'cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]')"
check "the import ID is zone_id/record_id"                               "yes" "$(imports_id "${ZONE_ID}/rec1")"
check "the zone is imported by its ID"                                   "yes" "$(imports_id "$ZONE_ID")"
teardown

setup
live_record "$DOMAIN" rec1 TXT "$DOMAIN" "v=spf1 include:icloud.com ~all"
desired "acme-corp.io__txt__@__9b8c7d6e5f4a" TXT "@" "v=spf1 include:icloud.com ~all"
run_imports
check "a TXT record is imported under the txt resource"                 "yes" "$(imports_to 'cloudflare_dns_record.txt["acme-corp.io__txt__@__9b8c7d6e5f4a"]')"
check "and the apex FQDN matches @, so nothing is left unmanaged"       "no"  "$(output_has 'stay unmanaged')"
teardown

setup
live_record "$DOMAIN" rec1 MX "$DOMAIN" mx01.mail.icloud.com 10
live_record "$DOMAIN" rec2 MX "$DOMAIN" mx02.mail.icloud.com 10
desired "acme-corp.io__mx__@__aaaaaaaaaaaa" MX "@" mx01.mail.icloud.com 10
desired "acme-corp.io__mx__@__bbbbbbbbbbbb" MX "@" mx02.mail.icloud.com 10
run_imports
check "two MX records at the same name import separately by content"   "3"   "$(import_blocks)"
check "each onto its own key"                                            "yes" "$(imports_id "${ZONE_ID}/rec2")"
teardown

setup
live_record "$DOMAIN" rec1 MX "$DOMAIN" mx01.mail.icloud.com 10
desired "acme-corp.io__mx__@__aaaaaaaaaaaa" MX "@" mx01.mail.icloud.com 20
run_imports
check "a different priority is not the same record"                     "1"   "$(import_blocks)"
check "and the live one is reported as unmanaged"                       "yes" "$(output_has 'stay unmanaged')"
check "and the configured one as about to be created"                   "yes" "$(output_has 'will be created')"
teardown

setup
live_record "$DOMAIN" rec1 CNAME "sig1._domainkey.${DOMAIN}" "sig1.dkim.acme-corp.io.at.icloudmailer.com"
desired "acme-corp.io__cname__sig1._domainkey__cccccccccccc" CNAME "sig1._domainkey" "sig1.dkim.acme-corp.io.at.icloudmailer.com"
desired "acme-corp.io__cname__mail__dddddddddddd" CNAME mail ghs.googlehosted.com
run_imports
check "a record matches by name, not by type alone"                     "yes" "$(imports_to 'cloudflare_dns_record.this["acme-corp.io__cname__sig1._domainkey__cccccccccccc"]')"
check "the configured record with no live counterpart is not imported"  "no"  "$(imports_to 'cloudflare_dns_record.this["acme-corp.io__cname__mail__dddddddddddd"]')"
teardown

setup
live_record "$DOMAIN" rec1 CNAME "mail.${DOMAIN}" ghs.googlehosted.com
desired "acme-corp.io__cname__mail__dddddddddddd" CNAME mail ghs.googlehosted.com
desired "acme-corp.io__cname__calendar__eeeeeeeeeeee" CNAME calendar ghs.googlehosted.com
run_imports
check "same type and content under two names: the name decides"          "yes" "$(imports_to 'cloudflare_dns_record.this["acme-corp.io__cname__mail__dddddddddddd"]')"
check "and the other name is left to be created"                        "yes" "$(output_has 'calendar.acme-corp.io')"
teardown

setup
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.11
run_imports
check "a different content is not the same record"                      "1"   "$(import_blocks)"
teardown

# ── what is already managed ──────────────────────────────────────────────

setup
managed 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]'
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_imports
check "a zone already in state is not imported again"                   "no"  "$(imports_id "$ZONE_ID")"
check "but its records still are"                                       "1"   "$(import_blocks)"
teardown

setup
managed 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]' 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]'
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_imports
check "nothing left to import succeeds"                                 "0"   "$?"
check "and writes no file"                                              "no"  "$([ -f "$IMPORTS" ] && echo yes || echo no)"
check "and says the record is already in state"                         "yes" "$(output_has 'already in state')"
teardown

setup
managed 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]' 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]'
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
echo 'import { to = a id = "b" }' >"$IMPORTS"
run_imports
check "a stale imports.tf from an earlier run is removed"               "no"  "$([ -f "$IMPORTS" ] && echo yes || echo no)"
teardown

# ── the cases that must not be guessed ──────────────────────────────────

setup
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
live_record "$DOMAIN" rec2 A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_imports
check "two live copies of one record are refused"                       "1"   "$?"
check "and nothing is written that would adopt only one"                "no"  "$([ -f "$IMPORTS" ] && echo yes || echo no)"
teardown

setup
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
live_record "$DOMAIN" rec9 TXT "_acme-challenge.${DOMAIN}" "leftover"
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_imports
check "a live record the configuration does not describe blocks nothing" "0"  "$?"
check "the described record is still imported"                          "yes" "$(imports_id "${ZONE_ID}/rec1")"
check "the undescribed one is named as staying unmanaged"               "yes" "$(output_has '_acme-challenge.acme-corp.io')"
teardown

# ── several domains in one zone group ────────────────────────────────────

setup
live_zone "blog.net" "ffffffffffffffffffffffffffffffff"
live_record "$DOMAIN" rec1 A "api.${DOMAIN}" 203.0.113.10
live_record "blog.net" rec7 A "blog.net" 203.0.113.20
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
desired "blog.net__a__@__eeeeeeeeeeee" A "@" 203.0.113.20 null blog.net
run_imports
check "each domain's record carries its own zone ID"                    "yes" "$(imports_id "ffffffffffffffffffffffffffffffff/rec7")"
check "both zones and both records are imported"                        "4"   "$(import_blocks)"
teardown

setup
run_imports nosuchzone
check "a missing zone directory fails"                                  "1"   "$?"
teardown

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
