#!/usr/bin/env bash
# Exercise the tool refresh with mise stubbed.
#
# refresh-tools.sh rewrites mise.toml to the newest releases, and the workflow
# opens the pull request that proposes them. A rewrite that hits
# the wrong line, drops a prefix or skips the pins check would ship a broken
# pin to main through a pull request nobody runs -- so the rewrite is tested,
# not the download.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  ROOT="${WORK}/repo"
  OUT="${WORK}/output.log"
  GHOUT="${WORK}/github_output"
  : >"$GHOUT"
  mkdir -p "${ROOT}/.github/workflows" "${ROOT}/.github/actions/setup-iac" "${WORK}/bin"
  printf '[tools]\nterraform  = "1.16.0"\nterragrunt = "1.1.4"\ntflint     = "0.64.0"\ntrivy      = "0.74.0"\n' >"${ROOT}/mise.toml"
  printf 'name: security\non: push\njobs: {}\n' >"${ROOT}/.github/workflows/security.yml"
  printf 'name: validate\non: push\njobs: {}\n' >"${ROOT}/.github/workflows/validate.yml"
  printf 'name: x\ninputs:\n  cache-key-files:\n    default: "**/versions.tf"\nruns: {using: composite, steps: []}\n' >"${ROOT}/.github/actions/setup-iac/action.yml"

  # `mise latest <tool>` answers from a table.
  cat >"${WORK}/bin/mise" <<STUB
#!/usr/bin/env bash
[ "\$1" = "latest" ] || exit 1
awk -v t="\$2" '\$1 == t { print \$2 }' "${WORK}/latest.txt"
STUB
  chmod +x "${WORK}/bin/mise"
  latest terraform 1.16.0; latest terragrunt 1.1.4; latest tflint 0.64.0; latest trivy 0.74.0
}
teardown() { rm -rf "$WORK"; }

latest() { echo "$1 $2" >>"${WORK}/latest.txt"; }

run_refresh() { (PATH="${WORK}/bin:${PATH}" PINS_ROOT="$ROOT" GITHUB_OUTPUT="$GHOUT" bash "${SCRIPTS}/refresh-tools.sh" >"$OUT" 2>&1); }
pin() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "${ROOT}/mise.toml"; }
changed() { sed -n 's/^changed=//p' "$GHOUT"; }
summary_has() { grep -qF "$1" "$GHOUT" && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

echo "refresh-tools.sh"

setup; before="$(cat "${ROOT}/mise.toml")"; run_refresh
check "everything current succeeds"                                 "0"     "$?"
check "and reports no change"                                       "false" "$(changed)"
check "and leaves mise.toml byte-identical"                          "yes"   "$([ "$before" = "$(cat "${ROOT}/mise.toml")" ] && echo yes || echo no)"
teardown

setup; : >"${WORK}/latest.txt"; latest terraform 1.16.1; latest terragrunt 1.1.4; latest tflint 0.64.0; latest trivy 0.74.0; run_refresh
check "a newer terraform rewrites its line in mise.toml"            "1.16.1" "$(pin terraform)"
check "and only its line"                                           "1.1.4"  "$(pin terragrunt)"
check "and reports a change"                                        "true"   "$(changed)"
check "with a release-notes link for the right repository"          "yes"    "$(summary_has 'hashicorp/terraform/releases/tag/v1.16.1')"
teardown

setup; wf_before="$(cat "${ROOT}"/.github/workflows/*.yml)"; : >"${WORK}/latest.txt"; latest terraform 1.16.0; latest terragrunt 1.1.4; latest tflint 0.64.0; latest trivy 0.75.0; run_refresh
check "a newer Trivy rewrites its line in mise.toml"                "0.75.0" "$(pin trivy)"
check "and the summary links Trivy's release notes"                 "yes"    "$(summary_has 'aquasecurity/trivy/releases/tag/v0.75.0')"
# GITHUB_TOKEN may not push edits to .github/workflows/; a refresh that writes
# there fails at push time, after every check in the run has passed.
check "and no workflow file is touched"                             "yes"    "$([ "$wf_before" = "$(cat "${ROOT}"/.github/workflows/*.yml)" ] && echo yes || echo no)"
teardown

setup; printf 'gitleaks   = "8.30.1"\n' >>"${ROOT}/mise.toml"; latest gitleaks 8.31.0; run_refresh
check "gitleaks is refreshed like the rest"                         "8.31.0" "$(pin gitleaks)"
teardown

setup; printf 'newtool    = "1.0.0"\n' >>"${ROOT}/mise.toml"; run_refresh
check "a pin the refresh does not know fails the run"               "1"   "$?"
check "naming the tool"                                             "yes" "$(grep -qF 'pins newtool' "$OUT" && echo yes || echo no)"
teardown

setup; : >"${WORK}/latest.txt"; latest terragrunt 1.1.4; latest tflint 0.64.0; run_refresh
check "mise failing to resolve a tool is an error, not a skip"      "1"   "$?"
teardown

setup; printf 'name: deploy\non: push\nenv:\n  TERRAFORM_VERSION: "1.16.0"\njobs: {}\n' >"${ROOT}/.github/workflows/deploy.yml"; run_refresh
check "a tree the pins check rejects fails the refresh"             "1"   "$?"
check "so a stray second pin cannot ride along in the pull request" "yes" "$(grep -qF 'pins check rejects' "$OUT" && echo yes || echo no)"
teardown

echo
if [ "$fail" -gt 0 ]; then printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
