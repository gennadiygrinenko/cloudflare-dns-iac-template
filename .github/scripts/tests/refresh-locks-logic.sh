#!/usr/bin/env bash
# Exercise the provider lock refresh with Terragrunt stubbed.
#
# refresh-locks.sh decides whether a lock change is worth a pull request and
# whether the lock it wrote is usable on every platform. A lock that covers
# only the runner's platform looks exactly like success and fails `init` on a
# laptop; a refresh that reports "unchanged" while a version moved never opens
# the pull request at all. So those decisions are tested, not the download.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# lock <version> <h1 count> -- a lock file body, one provider.
lock() {
  echo 'provider "registry.terraform.io/cloudflare/cloudflare" {'
  echo "  version     = \"$1\""
  echo '  constraints = "~> 5.0"'
  echo '  hashes = ['
  local i
  for ((i = 1; i <= $2; i++)); do echo "    \"h1:hash${i}-$1=\","; done
  echo '    "zh:abc",'
  echo '  ]'
  echo '}'
}

# Two zones with domains (acme locked at 5.23.0, beta at 5.23.0) and one with
# an empty map, which the refresh must skip. Committed, so the "nothing moved"
# path has something to restore.
setup() {
  WORK="$(mktemp -d)"
  REPO="${WORK}/repo"
  OUT="${WORK}/output.log"
  GHOUT="${WORK}/github_output"
  : >"$GHOUT"
  mkdir -p "${REPO}/.github/scripts" "${REPO}/envs/cloudflare/zones"/{acme,beta,empty} "${WORK}/bin" "${WORK}/tg"
  cp "${SCRIPTS}/refresh-locks.sh" "${SCRIPTS}/common.sh" "${REPO}/.github/scripts/"
  for z in acme beta; do
    printf 'domains = {\n  "%s.example" = {}\n}\n' "$z" >"${REPO}/envs/cloudflare/zones/${z}/variables.auto.tfvars"
    lock 5.23.0 3 >"${REPO}/envs/cloudflare/zones/${z}/.terraform.lock.hcl"
  done
  echo 'domains = {}' >"${REPO}/envs/cloudflare/zones/empty/variables.auto.tfvars"
  git -C "$REPO" init -q && git -C "$REPO" add -A && git -C "$REPO" commit -q -m base

  # `terragrunt init` does nothing; `terragrunt run -- providers lock` writes
  # the lock the case asked for: tg/<zone>.version and tg/<zone>.hashes
  # (default 5.23.0, one hash per -platform flag), or fails with tg/<zone>.fail.
  # Every call is logged, so a skipped zone can be proven untouched.
  cat >"${WORK}/bin/terragrunt" <<STUB
#!/usr/bin/env bash
zone="\$(basename "\$PWD")"
echo "\$zone \$*" >>"${WORK}/tg/calls.log"
[ -f "${WORK}/tg/\${zone}.fail" ] && { echo "boom" >&2; exit 1; }
[ "\$1" = "run" ] || exit 0
[ -f "${WORK}/tg/\${zone}.nolock" ] && { rm -f .terraform.lock.hcl; exit 0; }
platforms=\$(printf '%s\n' "\$@" | grep -c '^-platform=')
version=\$(cat "${WORK}/tg/\${zone}.version" 2>/dev/null || echo 5.23.0)
hashes=\$(cat "${WORK}/tg/\${zone}.hashes" 2>/dev/null || echo "\$platforms")
source "${WORK}/lock.sh"
lock "\$version" "\$hashes" >.terraform.lock.hcl
STUB
  declare -f lock >"${WORK}/lock.sh"
  chmod +x "${WORK}/bin/terragrunt"
}
teardown() { rm -rf "$WORK"; }

run_refresh() { (PATH="${WORK}/bin:${PATH}" GITHUB_OUTPUT="$GHOUT" bash "${REPO}/.github/scripts/refresh-locks.sh" >"$OUT" 2>&1); }
locked() { sed -nE 's/^ *version *= *"(.*)"/\1/p' "${REPO}/envs/cloudflare/zones/$1/.terraform.lock.hcl"; }
changed() { sed -n 's/^changed=//p' "$GHOUT"; }
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

echo "refresh-locks.sh"

setup; run_refresh
check "nothing newer succeeds"                                      "0"     "$?"
check "and reports no change"                                       "false" "$(changed)"
check "and leaves the tree clean"                                   ""      "$(git -C "$REPO" status --porcelain)"
check "the zone with no domains is never touched"                   "no"    "$(has "${WORK}/tg/calls.log" 'empty ')"
check "every lock is written for all three platforms"               "yes"   "$(has "${WORK}/tg/calls.log" '-platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64')"
teardown

# Hash churn alone -- same version, different hashes -- is not worth a pull
# request, and must not ride along with the next one either.
setup; echo 3 >"${WORK}/tg/acme.hashes"; sed -i.bak 's/h1:hash1-5.23.0/h1:other/' "${REPO}/envs/cloudflare/zones/acme/.terraform.lock.hcl"; rm -f "${REPO}/envs/cloudflare/zones/acme/.terraform.lock.hcl.bak"; git -C "$REPO" commit -qam churn; run_refresh
check "hash-only churn reports no change"                           "false" "$(changed)"
check "and is reverted"                                             ""      "$(git -C "$REPO" status --porcelain)"
teardown

setup; echo 5.24.0 >"${WORK}/tg/acme.version"; run_refresh
check "a newer provider succeeds"                                   "0"      "$?"
check "and reports a change"                                        "true"   "$(changed)"
check "with the zone and both versions in the summary"              "yes"    "$(has "$GHOUT" '- `acme`: 5.23.0 → 5.24.0')"
check "and only that zone"                                          "no"     "$(has "$GHOUT" '`beta`')"
check "and the new lock is kept"                                    "5.24.0" "$(locked acme)"
teardown

setup; rm "${REPO}/envs/cloudflare/zones/beta/.terraform.lock.hcl"; git -C "$REPO" commit -qam "no lock"; run_refresh
check "a zone with no lock yet gets one"                            "5.23.0" "$(locked beta)"
check "and counts as a change"                                      "true"   "$(changed)"
check "shown as new in the summary"                                 "yes"    "$(has "$GHOUT" '- `beta`: — → 5.23.0')"
teardown

# The failure this script exists to prevent: a lock for one platform only.
setup; echo 1 >"${WORK}/tg/acme.hashes"; run_refresh
check "a lock missing platforms fails the run"                      "1"   "$?"
check "and says how many hashes it found"                           "yes" "$(has "$OUT" 'acme: lock has 1 h1 hashes, expected 3')"
teardown

setup; touch "${WORK}/tg/acme.nolock"; run_refresh
check "no lock written at all fails the run"                        "1"   "$?"
check "with a message that says so, not a stray sed error"          "yes" "$(has "$OUT" 'acme: no lock file after providers lock')"
teardown

setup; touch "${WORK}/tg/beta.fail"; run_refresh
check "a Terragrunt failure fails the run"                          "1"   "$?"
check "rather than reporting no change"                             ""    "$(changed)"
teardown

echo
if [ "$fail" -gt 0 ]; then printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
