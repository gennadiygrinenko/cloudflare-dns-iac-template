#!/usr/bin/env bash
# Exercise the adoption-plan guard against hand-written plan JSON.
#
# check-adoption-plan.sh is the one gate between "the mirror configuration is
# wrong" and an apply on a zone that serves mail. A rule it fails to enforce
# lets a replace of the MX records through as if it were an import. Each case
# is a terraform show -json document with only the fields the guard reads.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  PLAN="${WORK}/plan.json"
  OUT="${WORK}/output.log"
  SUMMARY="${WORK}/summary.md"
  CHANGES="${WORK}/changes.jsonl"
  : >"$CHANGES"
  : >"$SUMMARY"
}
teardown() { rm -rf "$WORK"; }

# change <address> <type> <actions-json> [importing-id]
change() {
  jq -nc --arg a "$1" --arg t "$2" --argjson actions "$3" --arg imp "${4:-}" \
    '{ address: $a, type: $t, change: ({ actions: $actions } + (if $imp == "" then {} else { importing: { id: $imp } } end)) }' >>"$CHANGES"
}
imported()  { change "$1" "$2" '["no-op"]' "zid/$3"; }

run_guard() {
  jq -sc '{ format_version: "1.2", resource_changes: . }' "$CHANGES" >"$PLAN"
  (GITHUB_STEP_SUMMARY="$SUMMARY" bash "${SCRIPTS}/check-adoption-plan.sh" "$PLAN" >"$OUT" 2>&1)
}
output_has() { grep -qF "$1" "$OUT" && echo yes || echo no; }
summary_has() { grep -qF "$1" "$SUMMARY" && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

echo "check-adoption-plan.sh"

# ── what an adoption looks like ──────────────────────────────────────────

setup
imported 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]' cloudflare_zone z1
imported 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__mx__@__aaaa"]' cloudflare_dns_record r1
imported 'module.dns_zone.cloudflare_dns_record.txt["acme-corp.io__txt__@__bbbb"]' cloudflare_dns_record r2
run_guard
check "a plan of imports only is accepted"                              "0"   "$?"
check "and counted"                                                     "yes" "$(summary_has '| Records and zones imported | 3 |')"
check "with no rejections"                                              "yes" "$(summary_has '| Changes that are not an adoption | 0 |')"
teardown

setup
imported 'module.dns_zone.cloudflare_dns_record.this["k"]' cloudflare_dns_record r1
change 'module.dns_zone.cloudflare_zone_setting.ssl["acme-corp.io"]' cloudflare_zone_setting '["create"]'
change 'module.dns_zone.cloudflare_zone_setting.min_tls_version["acme-corp.io"]' cloudflare_zone_setting '["create"]'
run_guard
check "zone settings written alongside the imports are accepted"        "0"   "$?"
check "and reported separately"                                         "yes" "$(summary_has '| Zone settings written with their current value | 2 |')"
check "and not counted as imports"                                      "yes" "$(summary_has '| Records and zones imported | 1 |')"
teardown

setup
imported 'module.dns_zone.cloudflare_dns_record.this["k"]' cloudflare_dns_record r1
change 'module.dns_zone.cloudflare_dns_record.this["unchanged"]' cloudflare_dns_record '["no-op"]'
change 'data.cloudflare_zone.lookup' cloudflare_zone '["read"]'
run_guard
check "plain no-ops and data reads are not changes"                     "0"   "$?"
teardown

setup
run_guard
check "an empty plan is accepted"                                       "0"   "$?"
check "and says there is nothing to adopt"                              "yes" "$(output_has 'Nothing to adopt')"
teardown

# ── what must never pass ─────────────────────────────────────────────────

setup
imported 'module.dns_zone.cloudflare_dns_record.this["k"]' cloudflare_dns_record r1
change 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__mx__@__cccc"]' cloudflare_dns_record '["create"]'
run_guard
check "a record to be created is refused"                               "1"   "$?"
check "by address"                                                      "yes" "$(output_has 'cloudflare_dns_record.this["acme-corp.io__mx__@__cccc"]: create')"
check "and the summary says so"                                         "yes" "$(summary_has 'Refused.')"
teardown

setup
imported 'module.dns_zone.cloudflare_dns_record.this["k"]' cloudflare_dns_record r1
change 'module.dns_zone.cloudflare_dns_record.this["mx"]' cloudflare_dns_record '["update"]'
run_guard
check "an in-place update is refused"                                   "1"   "$?"
teardown

setup
change 'module.dns_zone.cloudflare_dns_record.txt["spf"]' cloudflare_dns_record '["delete","create"]'
run_guard
check "a replace is refused"                                            "1"   "$?"
check "and shown as delete,create"                                      "yes" "$(output_has 'delete,create')"
teardown

setup
change 'module.dns_zone.cloudflare_dns_record.this["orphan"]' cloudflare_dns_record '["delete"]'
run_guard
check "a delete is refused"                                             "1"   "$?"
teardown

setup
change 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]' cloudflare_zone '["create"]'
run_guard
check "creating the zone itself is refused — it must be imported"       "1"   "$?"
teardown

setup
change 'module.dns_zone.cloudflare_zone_setting.ssl["acme-corp.io"]' cloudflare_zone_setting '["update"]'
run_guard
check "a zone setting changing value is refused, only create is allowed" "1"  "$?"
teardown

setup
imported 'module.dns_zone.cloudflare_dns_record.this["k"]' cloudflare_dns_record r1
change 'module.dns_zone.cloudflare_dns_record.this["k2"]' cloudflare_dns_record '["update"]' 'zid/r2'
run_guard
check "an import that also updates the record is refused"              "1"   "$?"
teardown

setup
echo '{"format_version":"1.2"}' >"$PLAN"
(bash "${SCRIPTS}/check-adoption-plan.sh" "$PLAN" >"$OUT" 2>&1)
check "a document without resource_changes fails rather than passing"   "1"   "$?"
teardown

setup
(bash "${SCRIPTS}/check-adoption-plan.sh" "${WORK}/missing.json" >"$OUT" 2>&1)
check "a missing plan file fails"                                       "1"   "$?"
teardown

echo
if [ "$fail" -gt 0 ]; then printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
