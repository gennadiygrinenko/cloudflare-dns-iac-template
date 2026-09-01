#!/usr/bin/env bash
# Exercise the state operation routing without a cloud account.
#
# These operations touch state and are the ones with no undo, yet none of them
# has ever run: State Operations is a manual dispatch and nobody has dispatched
# it. terragrunt and curl are replaced by stubs, so what is checked here is the
# routing and the composition -- which is where move-domain was leaving state
# torn in half.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

# A throwaway repository with two zone directories and stubbed tools. The
# stubs record every terragrunt call so a test can assert what was attempted.
setup() {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/repo/.github/scripts" "${WORK}/bin"
  mkdir -p "${WORK}/repo/envs/cloudflare/zones/acme" "${WORK}/repo/envs/cloudflare/zones/legacy"
  cp "${SCRIPTS}/state-ops.sh" "${SCRIPTS}/common.sh" "${WORK}/repo/.github/scripts/"

  DOMAIN_UNDER_TEST="acme-corp.io"
  CALLS="${WORK}/calls.log"
  : >"$CALLS"

  # State is per zone directory and `state rm` really removes, so a move has
  # to actually empty the source before the import sees an empty target --
  # a stub that returned one shared list would let a broken move look fine.
  cat >"${WORK}/bin/terragrunt" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${CALLS}"
zone="\$(basename "\$(pwd)")"
state="${WORK}/state-\${zone}.txt"
case "\$*" in
  *"state list"*)
    cat "\$state" 2>/dev/null || true
    ;;
  "state rm "*)
    target="\${*#state rm }"
    if [ -f "\$state" ]; then
      grep -vxF "\$target" "\$state" >"\${state}.tmp" || true
      mv "\${state}.tmp" "\$state"
    fi
    ;;
  import*)
    printf '%s\\n' "module.dns_zone.cloudflare_zone.this[\\"${DOMAIN_UNDER_TEST}\\"]" >>"\$state"
    ;;
esac
exit 0
STUB

  cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"result":[{"id":"deadbeefdeadbeefdeadbeefdeadbeef"}]}'
STUB

  chmod +x "${WORK}/bin/terragrunt" "${WORK}/bin/curl"
  export PATH="${WORK}/bin:${PATH}"
  export CLOUDFLARE_API_TOKEN=stub
}

# Seed the state of one zone directory.
#   in_state <zone> [address...]
in_state() {
  local zone="$1"; shift
  if [ "$#" -eq 0 ]; then : >"${WORK}/state-${zone}.txt"; else printf '%s\n' "$@" >"${WORK}/state-${zone}.txt"; fi
}
teardown() { rm -rf "$WORK"; }

run_op() { (cd "${WORK}/repo" && bash .github/scripts/state-ops.sh "$@" >/dev/null 2>&1); }

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

echo "state-ops.sh"

# ── routing and input validation ─────────────────────────────────────────

setup
run_op nonsense-op acme acme-corp.io
check "an unknown operation fails"                  "1"   "$?"
teardown

setup
run_op move-domain acme acme-corp.io
check "move without from_zone fails"                "1"   "$?"
teardown

setup
run_op import-domain nosuchzone acme-corp.io
check "a missing zone directory fails"              "1"   "$?"
teardown

# ── import ───────────────────────────────────────────────────────────────

setup
in_state acme
run_op import-domain acme acme-corp.io
check "import succeeds"                             "0"   "$?"
check "import calls terragrunt import"              "yes" "$(grep -q '^import ' "$CALLS" && echo yes || echo no)"
teardown

setup
in_state acme 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]'
run_op import-domain acme acme-corp.io
check "an already-imported domain is skipped"       "no"  "$(grep -q '^import ' "$CALLS" && echo yes || echo no)"
teardown

# ── remove ───────────────────────────────────────────────────────────────

setup
in_state acme 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]' 'module.dns_zone.cloudflare_dns_record.this["acme-corp.io__a__@__abc"]'
run_op remove-domain acme acme-corp.io
check "remove takes out every matching resource"    "2"   "$(grep -c '^state rm ' "$CALLS")"
teardown

setup
in_state acme
run_op remove-domain acme acme-corp.io
check "removing an absent domain is not an error"   "0"   "$?"
teardown

# ── move: the composition ────────────────────────────────────────────────

setup
in_state legacy 'module.dns_zone.cloudflare_zone.this["acme-corp.io"]'
in_state acme
run_op move-domain acme acme-corp.io legacy
check "move succeeds end to end"                    "0"   "$?"
check "move removes from the source"                "yes" "$(grep -q '^state rm ' "$CALLS" && echo yes || echo no)"
check "move imports into the target"                "yes" "$(grep -q '^import ' "$CALLS" && echo yes || echo no)"
teardown

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
