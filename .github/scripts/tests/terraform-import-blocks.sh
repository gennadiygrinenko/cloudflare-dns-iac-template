#!/usr/bin/env bash
# Check that the Terraform on PATH honours every import block.
#
# Terraform 1.16.0 does not: when several import blocks target instances of
# one for_each resource, it imports the first and silently plans the rest as
# create. Found on the first real adoption of a live zone, where 6 of 8 records
# would have been created over their existing selves. The pin in mise.toml
# stays below 1.16 until a release passes this; the Tool versions workflow runs
# it against every proposed version, so a bump to a broken release goes red.
#
# Plan-only, one module with three random_id instances, no cloud account.

set -uo pipefail

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[0;32mok\033[0m   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

# The work dir is outside the repository, so a mise shim there has no
# mise.toml to read a version from. Resolve the real binary first.
TF="$(mise which terraform 2>/dev/null || command -v terraform)"
[ -n "$TF" ] || { echo "terraform not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/mod"

cat >"${WORK}/mod/main.tf" <<'TF'
variable "keys" { type = set(string) }

resource "random_id" "this" {
  for_each    = var.keys
  byte_length = 3
}
TF

cat >"${WORK}/main.tf" <<'TF'
terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

module "m" {
  source = "./mod"
  keys   = ["a", "b", "c"]
}
TF

cat >"${WORK}/imports.tf" <<'TF'
import {
  to = module.m.random_id.this["a"]
  id = "AQID"
}

import {
  to = module.m.random_id.this["b"]
  id = "BAUG"
}

import {
  to = module.m.random_id.this["c"]
  id = "BwgJ"
}
TF

echo "terraform $("$TF" version -json | jq -r .terraform_version): import blocks"

cd "$WORK" || exit 1
"$TF" init -input=false >init.log 2>&1 || { cat init.log; echo "init failed"; exit 1; }
"$TF" plan -out=tfplan -input=false >plan.log 2>&1 || { cat plan.log; echo "plan failed"; exit 1; }
"$TF" show -json tfplan >plan.json

imports="$(jq '[.resource_changes[] | select(.change.importing != null)] | length' plan.json)"
creates="$(jq '[.resource_changes[] | select(.change.actions == ["create"])] | length' plan.json)"

check "three import blocks import three instances"   "3" "$imports"
check "and none of them is planned as a create"       "0" "$creates"

echo
if [ "$fail" -gt 0 ]; then
  printf '\033[0;31m%d failed\033[0m, %d passed — this Terraform drops import blocks; do not pin it\n' "$fail" "$pass"
  exit 1
fi
printf '\033[0;32mall %d passed\033[0m\n' "$pass"
