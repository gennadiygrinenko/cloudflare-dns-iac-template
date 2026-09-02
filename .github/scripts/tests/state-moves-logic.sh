#!/usr/bin/env bash
# Exercise the moved-block generator without a cloud account.
#
# plan-state-moves.sh matches every record in state to its new address by what
# the record is -- zone, type, FQDN, content, priority -- and writes moved.tf.
# A wrong match does not fail: it writes a valid file that moves a record onto
# another record's address, which then passes plan, review and apply as a
# normal change. The script has STATE_JSON_FILE / PLAN_JSON_FILE hooks that
# skip Terragrunt and take fixtures instead; this is the first thing to use
# them.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

ZONE_ID="0123456789abcdef0123456789abcdef"
DOMAIN="acme-corp.io"

# A throwaway repository with one zone directory. State and plan are built up
# per case with the helpers below and handed to the script as files.
setup() {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/repo/.github/scripts" "${WORK}/repo/envs/cloudflare/zones/acme"
  cp "${SCRIPTS}/plan-state-moves.sh" "${SCRIPTS}/common.sh" "${WORK}/repo/.github/scripts/"

  MOVED="${WORK}/repo/envs/cloudflare/zones/acme/moved.tf"
  OUTPUT="${WORK}/output.log"
  STATE_RESOURCES="${WORK}/state-resources.jsonl"
  DESIRED="${WORK}/desired.jsonl"
  : >"$STATE_RESOURCES"
  : >"$DESIRED"

  # The zone itself is always in state: the script maps zone_id to the domain
  # through it.
  jq -nc --arg id "$ZONE_ID" --arg name "$DOMAIN" '{
    address: "module.dns_zone.cloudflare_zone.this[\"\($name)\"]",
    type: "cloudflare_zone",
    values: { id: $id, name: $name }
  }' >>"$STATE_RESOURCES"
}
teardown() { rm -rf "$WORK"; }

# A record as `terraform show -json` reports it: the name is an FQDN and the
# address carries whatever key scheme was current when it was applied.
#   in_state <address> <type> <fqdn> <content> [priority] [zone_id]
in_state() {
  jq -nc --arg address "$1" --arg type "$2" --arg name "$3" --arg content "$4" \
    --argjson priority "${5:-null}" --arg zone_id "${6:-$ZONE_ID}" '{
    address: $address,
    type: "cloudflare_dns_record",
    values: { zone_id: $zone_id, type: $type, name: $name, content: $content, priority: $priority }
  }' >>"$STATE_RESOURCES"
}

# A record as the module's dns_records output describes it: relative name,
# current key, and which of the two record resources it belongs to.
#   desired <key> <type> <name> <value> [priority]
desired() {
  local resource="cloudflare_dns_record.this"
  [ "$2" = "TXT" ] && resource="cloudflare_dns_record.txt"
  jq -nc --arg key "$1" --arg type "$2" --arg name "$3" --arg value "$4" \
    --argjson priority "${5:-null}" --arg domain "$DOMAIN" --arg resource "$resource" '{
    key: $key,
    value: { domain: $domain, resource: $resource, type: $type, name: $name, value: $value, priority: $priority }
  }' >>"$DESIRED"
}

run_moves() {
  jq -sc '{ format_version: "1.0", values: { root_module: { child_modules: [ { address: "module.dns_zone", resources: . } ] } } }' \
    "$STATE_RESOURCES" >"${WORK}/state.json"
  jq -sc '{ format_version: "1.2", planned_values: { outputs: { dns_records: { sensitive: false, value: (map({ (.key): .value }) | add // {}) } } } }' \
    "$DESIRED" >"${WORK}/plan.json"
  (cd "${WORK}/repo" && STATE_JSON_FILE="${WORK}/state.json" PLAN_JSON_FILE="${WORK}/plan.json" \
    bash .github/scripts/plan-state-moves.sh "${1:-acme}" >"$OUTPUT" 2>&1)
}

moved_blocks() { [ -f "$MOVED" ] && grep -c '^moved {' "$MOVED" || echo 0; }
moves_to() { grep -qF "to   = module.dns_zone.$1" "$MOVED" 2>/dev/null && echo yes || echo no; }
# common.sh sends warnings to stdout and errors to stderr; both are kept.
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

echo "plan-state-moves.sh"

# ── matching ─────────────────────────────────────────────────────────────

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__api__old"]' A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_moves
check "a record whose key changed gets a moved block"        "0"   "$?"
check "exactly one block is written"                         "1"   "$(moved_blocks)"
check "it moves onto the address the plan gives the record" "yes" "$(moves_to 'cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]')"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__txt__@__spf"]' TXT "$DOMAIN" "v=spf1 include:_spf.google.com ~all"
desired "acme-corp.io__txt__@__9b8c7d6e5f4a" TXT "@" "v=spf1 include:_spf.google.com ~all"
run_moves
check "a TXT record moves onto the txt resource"            "yes" "$(moves_to 'cloudflare_dns_record.txt["acme-corp.io__txt__@__9b8c7d6e5f4a"]')"
check "and not onto the regular one"                        "no"  "$(moves_to 'cloudflare_dns_record.this[')"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-apex"]' A "$DOMAIN" 203.0.113.10
desired "acme-corp.io__a__@__1a2b3c4d5e6f" A "@" 203.0.113.10
run_moves
check "an apex record in state matches the @ in the plan"   "1"   "$(moved_blocks)"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-mx"]' MX "$DOMAIN" smtp.google.com 1
desired "acme-corp.io__mx__@__aaaaaaaaaaaa" MX "@" smtp.google.com 1
run_moves
check "an MX record matches on priority too"                "1"   "$(moved_blocks)"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-mx"]' MX "$DOMAIN" smtp.google.com 10
desired "acme-corp.io__mx__@__aaaaaaaaaaaa" MX "@" smtp.google.com 1
run_moves
check "a different priority is a different record"         "0"   "$(moved_blocks)"
check "and is reported as one that will be destroyed"      "yes" "$(output_has 'no counterpart')"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-api"]' A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.11
run_moves
check "a different content is a different record"          "0"   "$(moved_blocks)"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-cname"]' CNAME "mail.${DOMAIN}" ghs.googlehosted.com
desired "acme-corp.io__cname__mail__bbbbbbbbbbbb" CNAME mail ghs.googlehosted.com
desired "acme-corp.io__cname__calendar__cccccccccccc" CNAME calendar ghs.googlehosted.com
run_moves
check "same type and content but another name is not it"   "yes" "$(moves_to 'cloudflare_dns_record.this["acme-corp.io__cname__mail__bbbbbbbbbbbb"]')"
check "only the matching name moves"                        "1"   "$(moved_blocks)"
teardown

# ── nothing to do ────────────────────────────────────────────────────────

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]' A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_moves
check "a record already at its address is left alone"       "0"   "$?"
check "and no moved.tf is written"                          "no"  "$([ -f "$MOVED" ] && echo yes || echo no)"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__api__3f2a9c1b0e7d"]' A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
echo 'moved { from = a to = b }' >"$MOVED"
run_moves
check "a stale moved.tf from an earlier run is removed"    "no"  "$([ -f "$MOVED" ] && echo yes || echo no)"
teardown

# ── the cases that must not be guessed ──────────────────────────────────

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["old-api"]' A "api.${DOMAIN}" 203.0.113.10
in_state 'module.dns_zone.cloudflare_dns_record.this["old-legacy"]' A "legacy.${DOMAIN}" 203.0.113.99
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_moves
check "an orphan does not stop the moves that are safe"     "0"   "$?"
check "the safe move is still written"                      "1"   "$(moved_blocks)"
check "the orphan is named as going to be destroyed"       "yes" "$(output_has 'legacy.acme-corp.io')"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["drifted-1"]' A "api.${DOMAIN}" 203.0.113.10
in_state 'module.dns_zone.cloudflare_dns_record.this["drifted-2"]' A "api.${DOMAIN}" 203.0.113.10
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_moves
check "two state records onto one address is refused"       "1"   "$?"
check "and nothing is written that would lose one"          "no"  "$([ -f "$MOVED" ] && echo yes || echo no)"
teardown

setup
in_state 'module.dns_zone.cloudflare_dns_record.this["foreign"]' A "api.${DOMAIN}" 203.0.113.10 null "ffffffffffffffffffffffffffffffff"
desired "acme-corp.io__a__api__3f2a9c1b0e7d" A api 203.0.113.10
run_moves
check "a record of a zone not in state is not matched"      "0"   "$(moved_blocks)"
check "and is reported without a domain"                    "yes" "$(output_has '?: A api.acme-corp.io')"
teardown

setup
run_moves nosuchzone
check "a missing zone directory fails"                      "1"   "$?"
teardown

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
