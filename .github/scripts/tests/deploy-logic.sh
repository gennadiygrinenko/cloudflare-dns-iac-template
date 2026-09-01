#!/usr/bin/env bash
# Exercise the plan/apply decision logic without a cloud account.
#
# The faults this pipeline actually shipped were all shell logic: a discarded
# exit code, an inferred "no changes", an absent artifact read as an empty
# plan. None of them need Cloudflare to reproduce, and none of them were
# reachable by a test while the logic lived inside the workflow YAML.
#
# terragrunt is replaced by a stub whose exit code and side effects each case
# chooses. Everything else is the real script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

# Build a throwaway zone directory plus a terragrunt stub on PATH.
#   $1 exit code the stub returns
#   $2 "write-plan" to have it create the -out file, anything else to skip
setup() {
  WORK="$(mktemp -d)"
  ZONE="${WORK}/acme"
  mkdir -p "$ZONE"

  mkdir -p "${WORK}/bin"
  cat >"${WORK}/bin/terragrunt" <<STUB
#!/usr/bin/env bash
echo "stub terragrunt: \$*"
if [ "${2:-}" = "write-plan" ]; then
  for arg in "\$@"; do
    case "\$arg" in -out=*) : >"\${arg#-out=}" ;; esac
  done
fi
echo "Terraform will perform the following actions"
exit ${1}
STUB
  chmod +x "${WORK}/bin/terragrunt"
  export PATH="${WORK}/bin:${PATH}"
}

teardown() { rm -rf "$WORK"; }

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

# ── plan ──────────────────────────────────────────────────────────────────

echo "plan-zone.sh"

setup 0 write-plan
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1
check "exit 0 leaves a NO_CHANGES marker"      "yes" "$([ -f "${ZONE}/NO_CHANGES" ] && echo yes || echo no)"
check "exit 0 removes the plan file"           "yes" "$([ ! -f "${ZONE}/tfplan" ] && echo yes || echo no)"
teardown

setup 2 write-plan
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1
check "exit 2 keeps the plan file"             "yes" "$([ -f "${ZONE}/tfplan" ] && echo yes || echo no)"
check "exit 2 writes no marker"                "yes" "$([ ! -f "${ZONE}/NO_CHANGES" ] && echo yes || echo no)"
teardown

setup 1 no-plan
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1
check "a failed plan fails the step"           "1"   "$?"
teardown

# A marker left by an earlier run must not survive into one that has changes:
# apply trusts it and skips, so a stale marker silently drops a real change.
setup 2 write-plan
touch "${ZONE}/NO_CHANGES"
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1
check "exit 2 clears a stale marker"           "yes" "$([ ! -f "${ZONE}/NO_CHANGES" ] && echo yes || echo no)"
teardown

# The mirror: a plan file left by an earlier run must not survive a plan that
# found nothing, or apply would re-apply stale changes.
setup 0 no-plan
touch "${ZONE}/tfplan"
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1
check "exit 0 clears a stale plan file"        "yes" "$([ ! -f "${ZONE}/tfplan" ] && echo yes || echo no)"
teardown

setup 1 no-plan
bash "${SCRIPTS}/plan-zone.sh" "$ZONE" >/dev/null 2>&1 || true
check "a failed plan leaves no false marker"   "yes" "$([ ! -f "${ZONE}/NO_CHANGES" ] && echo yes || echo no)"
teardown

# ── apply ─────────────────────────────────────────────────────────────────

echo "apply-zone.sh"

setup 0 no-plan
touch "${ZONE}/NO_CHANGES"
bash "${SCRIPTS}/apply-zone.sh" "$ZONE" >/dev/null 2>&1
check "a marker means skip, and succeed"       "0"   "$?"
teardown

setup 0 no-plan
touch "${ZONE}/tfplan"
bash "${SCRIPTS}/apply-zone.sh" "$ZONE" >/dev/null 2>&1
check "a plan file is applied"                 "0"   "$?"
teardown

# The one that shipped: neither file present, and the job reported success.
setup 0 no-plan
bash "${SCRIPTS}/apply-zone.sh" "$ZONE" >/dev/null 2>&1
check "neither file is a failure, not a skip"  "1"   "$?"
teardown

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
