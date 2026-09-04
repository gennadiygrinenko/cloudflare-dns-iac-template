#!/usr/bin/env bash
# Exercise the version-pin rules against a throwaway repository root.
#
# check-version-pins.sh is what keeps tool versions declared in one place.
# A rule it fails to enforce lets a second pin creep in and win for whatever
# reads it -- exactly the drift the file exists to stop. PINS_ROOT points the
# script at a fixture tree, so every rule can be exercised on its own.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  ROOT="${WORK}/repo"
  OUT="${WORK}/output.log"
  mkdir -p "${ROOT}/.github/workflows" "${ROOT}/.github/actions/setup-iac"
  mise_toml 'terraform  = "1.16.0"' 'terragrunt = "1.1.4"' 'tflint     = "0.64.0"' 'pre-commit = "4.6.2"'
  workflow validate.yml
  workflow security.yml 'TRIVY_VERSION: "0.74.0"'
  action
}
teardown() { rm -rf "$WORK"; }

# mise_toml <tool = "version" lines...>
mise_toml() { { echo "[tools]"; printf '%s\n' "$@"; } >"${ROOT}/mise.toml"; }
# workflow <name> [env lines...]  -- env keys at the workflow level, two spaces in
workflow() {
  local name="$1"; shift
  { echo "name: ${name%.yml}"; echo "on: push"; if [ "$#" -gt 0 ]; then echo "env:"; printf '  %s\n' "$@"; fi; echo "jobs: {}"; } >"${ROOT}/.github/workflows/${name}"
}
# action [input default lines...]
action() {
  { echo "name: Set up IaC tooling"; echo "inputs:"; echo "  cache-key-files:"; echo '    default: "**/versions.tf"'; printf '%s\n' "$@"; echo "runs: {using: composite, steps: []}"; } >"${ROOT}/.github/actions/setup-iac/action.yml"
}

run_check() { PINS_ROOT="$ROOT" bash "${SCRIPTS}/check-version-pins.sh" >"$OUT" 2>&1; }
output_has() { grep -qF "$1" "$OUT" && echo yes || echo no; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

echo "check-version-pins.sh"

setup; run_check
check "a repository with every pin in mise.toml passes"            "0"   "$?"
check "and lists the pins it found"                                 "yes" "$(output_has 'terraform = 1.16.0 (mise.toml)')"
check "and the one workflow-level pin that remains"                 "yes" "$(output_has 'TRIVY_VERSION = 0.74.0')"
teardown

setup; rm "${ROOT}/mise.toml"; run_check
check "no mise.toml fails"                                          "1"   "$?"
check "and says so"                                                 "yes" "$(output_has 'mise.toml not found')"
teardown

setup; mise_toml 'terraform  = "1.16.0"' 'terragrunt = "1.1.4"'; run_check
check "a required tool missing from mise.toml fails"                "1"   "$?"
check "naming the tool"                                             "yes" "$(output_has 'does not pin tflint')"
teardown

setup; mise_toml 'terraform  = "latest"' 'terragrunt = "1.1.4"' 'tflint     = "0.64.0"'; run_check
check "a floating version fails"                                    "1"   "$?"
check "because CI and laptops would drift"                          "yes" "$(output_has 'exact X.Y.Z')"
teardown

setup; mise_toml 'terraform  = "v1.16.0"' 'terragrunt = "1.1.4"' 'tflint     = "0.64.0"'; run_check
check "a v-prefixed version fails the exact-version rule"           "1"   "$?"
teardown

setup; workflow deploy.yml 'TERRAFORM_VERSION: "1.16.0"'; run_check
check "TERRAFORM_VERSION reintroduced in a workflow fails"          "1"   "$?"
check "and the message names the workflow"                          "yes" "$(output_has 'deploy.yml')"
check "even when it agrees with mise.toml"                          "yes" "$(output_has 'belongs to mise.toml alone')"
teardown

setup; workflow validate.yml 'PRE_COMMIT_VERSION: "4.6.2"'; run_check
check "PRE_COMMIT_VERSION reintroduced fails too"                   "1"   "$?"
teardown

setup; action '  terraform-version:' '    default: "1.16.0"'; run_check
check "a version default on setup-iac fails"                        "1"   "$?"
check "since the action must install from mise.toml"                "yes" "$(output_has 'declares a version default')"
teardown

setup; workflow other.yml 'TRIVY_VERSION: "0.75.0"'; run_check
check "a remaining workflow pin that disagrees fails"               "1"   "$?"
check "naming the key"                                              "yes" "$(output_has 'TRIVY_VERSION disagrees')"
teardown

setup; workflow security.yml; run_check
check "no workflow-level pins at all is fine"                       "0"   "$?"
teardown

echo
if [ "$fail" -gt 0 ]; then printf '\033[0;31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
