#!/usr/bin/env bash
# Exercise the DMARC checklist with Terragrunt stubbed.
#
# dmarc-checklist.sh turns two module outputs into a pull request comment. A
# zone it fails to read and then reports as clean is a DMARC record nobody is
# told to publish -- and reports are dropped silently on the receiving side,
# so nothing else would ever say so. The plan itself is not tested here; what
# the script does with the plan, and with a plan that failed, is.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  REPO="${WORK}/repo"
  OUT="${WORK}/output.log"
  GHOUT="${WORK}/github_output"
  BODY="${WORK}/body.md"
  : >"$GHOUT"
  mkdir -p "${REPO}/.github/scripts" "${REPO}/envs/cloudflare/zones"/{acme,beta} "${WORK}/bin" "${WORK}/tg"
  cp "${SCRIPTS}/dmarc-checklist.sh" "${SCRIPTS}/common.sh" "${REPO}/.github/scripts/"

  # `plan -out=<file>` creates the file, or fails with tg/<zone>.fail, or
  # "succeeds" without writing it with tg/<zone>.noplan. `show -json` prints
  # tg/<zone>.json, defaulting to a plan whose two outputs are empty.
  cat >"${WORK}/bin/terragrunt" <<STUB
#!/usr/bin/env bash
zone="\$(basename "\$PWD")"
case "\$1" in
  plan)
    [ -f "${WORK}/tg/\${zone}.fail" ] && { echo "Error: plan exploded" >&2; exit 1; }
    [ -f "${WORK}/tg/\${zone}.noplan" ] && exit 0
    out="\$(printf '%s\n' "\$@" | sed -n 's/^-out=//p')"
    : >"\$out" ;;
  run)
    cat "${WORK}/tg/\${zone}.json" 2>/dev/null ||
      echo '{"planned_values":{"outputs":{"dmarc_external_authorizations_required":{"value":{}},"dmarc_report_delegation_warnings":{"value":{}}}}}' ;;
esac
STUB
  chmod +x "${WORK}/bin/terragrunt"
}
teardown() { rm -rf "$WORK"; }

external() {
  cat >"${WORK}/tg/$1.json" <<'JSON'
{"planned_values":{"outputs":{
  "dmarc_external_authorizations_required":{"value":{"acme.example":{"fqdn":"acme.example._report._dmarc.vendor.example","content":"v=DMARC1","note":"in vendor.example"}}},
  "dmarc_report_delegation_warnings":{"value":{}}}}}
JSON
}
delegation() {
  cat >"${WORK}/tg/$1.json" <<'JSON'
{"planned_values":{"outputs":{
  "dmarc_external_authorizations_required":{"value":{}},
  "dmarc_report_delegation_warnings":{"value":{"child.example":"parent.example has no NS for child.example"}}}}}
JSON
}

run_checklist() { (PATH="${WORK}/bin:${PATH}" GITHUB_OUTPUT="$GHOUT" DMARC_BODY="$BODY" ZONES="$1" bash "${REPO}/.github/scripts/dmarc-checklist.sh" >"$OUT" 2>&1); }
findings() { sed -n 's/^has_findings=//p' "$GHOUT"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

echo "dmarc-checklist.sh"

setup; run_checklist '["acme","beta"]'
check "clean plans succeed"                                         "0"     "$?"
check "and report no findings"                                      "false" "$(findings)"
check "and write no comment"                                        "no"    "$([ -e "$BODY" ] && echo yes || echo no)"
teardown

setup; external beta; run_checklist '["acme","beta"]'
check "an external authorization is a finding"                      "true"  "$(findings)"
check "listed as a table row with its zone, record and value"       "yes"   "$(has "$BODY" '| beta | acme.example | `acme.example._report._dmarc.vendor.example` | `v=DMARC1` | in vendor.example |')"
check "and no delegation section when there is nothing for it"      "no"    "$(has "$BODY" 'Missing NS delegation')"
teardown

setup; delegation acme; run_checklist '["acme"]'
check "a delegation warning is a finding"                           "true"  "$(findings)"
check "under its own heading"                                       "yes"   "$(has "$BODY" '### Missing NS delegation')"
check "naming zone and domain"                                      "yes"   "$(has "$BODY" '**acme / child.example**: parent.example has no NS')"
check "and no table when there are no rows"                         "no"    "$(has "$BODY" '| Zone | Domain |')"
teardown

setup; run_checklist '["acme","gone"]'
check "a zone with no directory is skipped, not an error"           "0"     "$?"
check "and does not count as unchecked"                             "false" "$(findings)"
teardown

setup; run_checklist '[]'
check "no zones at all is clean"                                    "false" "$(findings)"
teardown

# A zone whose plan failed was not checked. Saying "no authorizations
# required" about it is the silent failure this comment exists to prevent.
setup; touch "${WORK}/tg/beta.fail"; run_checklist '["acme","beta"]'
check "a failed plan does not fail the check (advisory)"            "0"     "$?"
check "but is not reported as clean"                                "true"  "$(findings)"
check "the comment names the zone that was not checked"             "yes"   "$(has "$BODY" '`beta`')"
check "and the log does not claim nothing is required"              "no"    "$(has "$OUT" 'No external DMARC authorizations required')"
teardown

setup; touch "${WORK}/tg/acme.noplan"; run_checklist '["acme"]'
check "a plan that wrote no file counts as not checked too"         "true"  "$(findings)"
check "named in the comment"                                        "yes"   "$(has "$BODY" '`acme`')"
teardown

setup; touch "${WORK}/tg/acme.fail"; external beta; run_checklist '["acme","beta"]'
check "findings and an unchecked zone appear together"              "yes"   "$(has "$BODY" '| beta | acme.example |')"
check "neither hiding the other"                                    "yes"   "$(has "$BODY" '`acme`')"
teardown

echo
if [ "$fail" -gt 0 ]; then printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
