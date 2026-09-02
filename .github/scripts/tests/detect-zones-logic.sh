#!/usr/bin/env bash
# Exercise zone detection against a throwaway git repository.
#
# detect-zones.sh decides which zones enter the Validate and Deploy matrices.
# A zone it leaves out is not validated and not deployed, and nothing reports
# that: an empty matrix skips the job, and the aggregator is written to accept
# that when nothing relevant changed. So the decision itself is what is tested
# here -- both modes, the shared-path rule, and the shape of the output that
# GITHUB_OUTPUT will accept.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# A repository with three zones -- two with domains, one with an empty map --
# plus one file in each place SHARED_PATHS is meant to cover. Cases change
# files on top of this base and commit, so the script sees a real diff.
setup() {
  WORK="$(mktemp -d)"
  REPO="${WORK}/repo"
  OUT="${WORK}/github_output"
  : >"$OUT"

  mkdir -p "${REPO}/.github/scripts" "${REPO}/.github/workflows" "${REPO}/.github/actions/setup-iac" \
    "${REPO}/terraform/modules/dns-zone" "${REPO}/envs/cloudflare/zones"/{acme,legacy,empty}
  cp "${SCRIPTS}/detect-zones.sh" "${SCRIPTS}/common.sh" "${REPO}/.github/scripts/"

  cat >"${REPO}/envs/cloudflare/zones/acme/variables.auto.tfvars" <<'TFVARS'
domains = {
  "acme-corp.io" = {
    apex_ip = "203.0.113.10"
  }
}
TFVARS
  cat >"${REPO}/envs/cloudflare/zones/legacy/variables.auto.tfvars" <<'TFVARS'
domains = {
  # "retired.example" = {}
  "legacy.example" = { plan = "free" }
}
TFVARS
  echo 'domains = {}' >"${REPO}/envs/cloudflare/zones/empty/variables.auto.tfvars"

  echo '# module' >"${REPO}/terraform/modules/dns-zone/main.tf"
  echo '# shared' >"${REPO}/envs/cloudflare/zones.hcl"
  echo '# workflow' >"${REPO}/.github/workflows/validate.yml"
  echo '# action' >"${REPO}/.github/actions/setup-iac/action.yml"
  echo '# readme' >"${REPO}/README.md"

  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  BASE="$(git -C "$REPO" rev-parse HEAD)"
}
teardown() { rm -rf "$WORK"; }

# Stage a change on top of the base, then commit it as the pull request head.
change() { mkdir -p "$(dirname "${REPO}/$1")"; echo "# changed" >>"${REPO}/$1"; git -C "$REPO" add "$1"; }
remove() { git -C "$REPO" rm -rq "$1"; }
head_commit() { git -C "$REPO" commit -q -m head; HEAD="$(git -C "$REPO" rev-parse HEAD)"; }

run_pr() { head_commit; (cd "$REPO" && GITHUB_OUTPUT="$OUT" bash .github/scripts/detect-zones.sh "$BASE" "$HEAD" >/dev/null 2>&1); }
run_push() { (cd "$REPO" && GITHUB_OUTPUT="$OUT" bash .github/scripts/detect-zones.sh "$@" >/dev/null 2>&1); }

# The zones output is a GITHUB_OUTPUT heredoc; this is the value between the
# markers, exactly as the workflow would receive it.
zones() { sed -n '/^zones<<EOF$/,/^EOF$/p' "$OUT" | sed '1d;$d'; }
any_changes() { sed -n 's/^any_changes=//p' "$OUT"; }

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

echo "detect-zones.sh"

# ── push to main: every zone that has something to deploy ────────────────

setup
run_push
check "push mode lists the zones with domains, sorted"        '["acme","legacy"]' "$(zones)"
check "a zone whose domains map is empty is left out"          "no"  "$(zones | grep -q empty && echo yes || echo no)"
check "push mode writes no any_changes"                        ""    "$(any_changes)"
check "the JSON array is a single line"                        "1"   "$(zones | wc -l | tr -d ' ')"
teardown

setup
mkdir -p "${REPO}/envs/cloudflare/zones/scratch"
run_push
check "a directory without variables.auto.tfvars is not a zone" "no" "$(zones | grep -q scratch && echo yes || echo no)"
teardown

setup
run_push "$BASE"
check "one SHA is not PR mode: all zones are listed"           '["acme","legacy"]' "$(zones)"
teardown

# ── pull request: only what changed ──────────────────────────────────────

setup
change envs/cloudflare/zones/legacy/variables.auto.tfvars
run_pr
check "a change inside one zone selects that zone only"        '["legacy"]' "$(zones)"
check "and reports that there is something to validate"        "true" "$(any_changes)"
teardown

setup
change envs/cloudflare/zones/legacy/variables.auto.tfvars
change envs/cloudflare/zones/legacy/.terraform.lock.hcl
run_pr
check "two files in one zone give one matrix entry"            '["legacy"]' "$(zones)"
teardown

setup
change envs/cloudflare/zones/legacy/variables.auto.tfvars
change envs/cloudflare/zones/acme/variables.auto.tfvars
run_pr
check "several zones come out sorted"                          '["acme","legacy"]' "$(zones)"
teardown

setup
change envs/cloudflare/zones/empty/variables.auto.tfvars
run_pr
check "a touched zone is validated even with no domains yet"   '["empty"]' "$(zones)"
teardown

setup
mkdir -p "${REPO}/envs/cloudflare/zones/fresh"
echo 'domains = { "fresh.example" = {} }' >"${REPO}/envs/cloudflare/zones/fresh/variables.auto.tfvars"
git -C "$REPO" add envs/cloudflare/zones/fresh
run_pr
check "a zone added in the pull request is validated"          '["fresh"]' "$(zones)"
teardown

setup
change README.md
run_pr
check "an unrelated file selects nothing"                      "[]"    "$(zones)"
check "and says so, so the aggregator can accept an empty matrix" "false" "$(any_changes)"
teardown

# ── a deleted zone has nothing to validate ───────────────────────────────

setup
remove envs/cloudflare/zones/legacy
run_pr
check "a deleted zone directory is not put in the matrix"      "[]"    "$(zones)"
check "and counts as no change to validate"                    "false" "$(any_changes)"
teardown

setup
remove envs/cloudflare/zones/legacy
change envs/cloudflare/zones/acme/variables.auto.tfvars
run_pr
check "a deleted zone does not hide the changed one"           '["acme"]' "$(zones)"
teardown

# ── shared paths: a change that touches every zone validates every zone ──

for shared in \
  terraform/modules/dns-zone/main.tf \
  envs/cloudflare/zones.hcl \
  .github/workflows/validate.yml \
  .github/scripts/plan-zone.sh \
  .github/actions/setup-iac/action.yml
do
  setup
  change "$shared"
  run_pr
  check "a change to ${shared} validates all zones"            '["acme","legacy"]' "$(zones)"
  teardown
done

setup
change terraform/modules/dns-zone/main.tf
run_pr
check "a shared change reports something to validate"          "true" "$(any_changes)"
check "but still leaves out the zone with no domains"          "no"   "$(zones | grep -q empty && echo yes || echo no)"
teardown

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
