#!/usr/bin/env python3
"""Mutation-test the module's terraform test suite: `make mutants`.

Each entry below breaks the module on purpose, one edit at a time, and the
suite has to notice. A mutation that leaves the suite green is a hole in the
tests, not a fault in the module — that is the whole output of this script.

Run by hand, not in CI. The mutations are anchored to the text of main.tf and
variables.tf, so a rename breaks the anchor rather than the module, and a red
pipeline that means "someone renamed a variable" is worse than no pipeline. An
anchor that no longer matches is reported as a failure here for the same
reason: it means this file has fallen behind the module, and the mutation it
describes is no longer being tried.

Add a mutation whenever a test case is added, and pick the fault that case
exists to catch.
"""

from __future__ import annotations

import itertools
import pathlib
import re
import subprocess
import sys

MODULE = pathlib.Path(__file__).resolve().parent.parent
MAIN = MODULE / "main.tf"
VARIABLES = MODULE / "variables.tf"

# Booleans whose zone_setting blocks are near-identical, so a block reading its
# neighbour's field is the plausible copy-paste fault. Every ordered pair is
# tried: six settings over two on/off values cannot be separated by a single
# plan, and the first version of the suite did miss one of these.
BOOLEAN_SETTINGS = [
    "always_use_https",
    "automatic_https_rewrites",
    "ipv6",
    "brotli",
    "early_hints",
    "always_online",
]

MUTATIONS: list[tuple[str, pathlib.Path, str, str]] = [
    (
        "pro plan default polish becomes off",
        MAIN,
        'pro = {\n      polish        = "lossless"',
        'pro = {\n      polish        = "off"',
    ),
    (
        "pro plan default drops the managed WAF",
        MAIN,
        "rocket_loader = false # can break some JS — opt-in explicitly\n      waf_managed   = true",
        "rocket_loader = false # can break some JS — opt-in explicitly\n      waf_managed   = false",
    ),
    (
        "coalesce order: the plan default wins over the user's value",
        MAIN,
        "polish        = coalesce(cfg.settings.polish, local.plan_defaults[cfg.plan].polish)",
        "polish        = coalesce(local.plan_defaults[cfg.plan].polish, cfg.settings.polish)",
    ),
    (
        "a Pro+ setting is planned on every plan",
        MAIN,
        'resource "cloudflare_zone_setting" "polish" {\n  for_each = { for domain, cfg in var.domains : domain => cfg if contains(["pro", "business", "enterprise"], cfg.plan) }',
        'resource "cloudflare_zone_setting" "polish" {\n  for_each = var.domains',
    ),
    (
        "the managed WAF ignores the plan gate",
        MAIN,
        'if local.resolved[domain].waf_managed && contains(["pro", "business", "enterprise"], cfg.plan)',
        "if local.resolved[domain].waf_managed",
    ),
    (
        "always_online default flips to true",
        VARIABLES,
        "always_online            = optional(bool, false)",
        "always_online            = optional(bool, true)",
    ),
    (
        "the ssl default is weakened",
        VARIABLES,
        'ssl                      = optional(string, "strict")',
        'ssl                      = optional(string, "flexible")',
    ),
    (
        "the max_upload default changes",
        VARIABLES,
        "max_upload               = optional(number, 100)",
        "max_upload               = optional(number, 200)",
    ),
    (
        "Pro+ settings default to a value again, so coalesce never reaches plan_defaults",
        VARIABLES,
        'polish        = optional(string, null) # off | lossless | lossy; Pro+ default lossless\n      mirage        = optional(bool, null)   # mobile image optimization; Pro+ default true',
        'polish        = optional(string, "off")\n      mirage        = optional(bool, false)',
    ),
    (
        "an on/off mapping is inverted",
        MAIN,
        'setting_id = "ipv6"\n  value      = each.value.settings.ipv6 ? "on" : "off"',
        'setting_id = "ipv6"\n  value      = each.value.settings.ipv6 ? "off" : "on"',
    ),
    (
        "the zone redirect becomes a 302",
        MAIN,
        "status_code           = 301",
        "status_code           = 302",
    ),
    (
        "a firewall rule's enabled flag is hardcoded",
        MAIN,
        "enabled     = r.enabled",
        "enabled     = true",
    ),
    (
        "zones are created as partial rather than full",
        MAIN,
        'type    = "full"',
        'type    = "partial"',
    ),
    *[
        (
            f"the {victim} setting reads the {source} field",
            MAIN,
            f'setting_id = "{victim}"\n  value      = each.value.settings.{victim} ? "on" : "off"',
            f'setting_id = "{victim}"\n  value      = each.value.settings.{source} ? "on" : "off"',
        )
        for victim, source in itertools.permutations(BOOLEAN_SETTINGS, 2)
    ],
]


def failing_runs() -> int:
    """Number of failing test runs, or -1 if the suite did not report."""
    result = subprocess.run(
        ["terraform", f"-chdir={MODULE}", "test"],
        capture_output=True,
        text=True,
        check=False,
    )
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + result.stderr)
    reported = re.search(r"(\d+) passed, (\d+) failed", output)
    return int(reported.group(2)) if reported else -1


def main() -> int:
    if failing_runs() != 0:
        print("The suite is not green to begin with; fix that first.")
        return 1

    originals = {path: path.read_text() for path in (MAIN, VARIABLES)}
    survivors: list[str] = []

    try:
        for label, path, old, new in MUTATIONS:
            original = originals[path]
            if old not in original:
                print(f"STALE  anchor no longer in {path.name} :: {label}")
                survivors.append(label)
                continue

            path.write_text(original.replace(old, new, 1))
            try:
                failed = failing_runs()
            finally:
                path.write_text(original)

            if failed > 0:
                print(f"caught ({failed} run{'s' if failed != 1 else ''}) :: {label}")
            else:
                print(f"MISSED           :: {label}")
                survivors.append(label)
    finally:
        for path, text in originals.items():
            path.write_text(text)

    print()
    if survivors:
        print(f"{len(survivors)} of {len(MUTATIONS)} mutations went unnoticed:")
        for label in survivors:
            print(f"  - {label}")
        return 1

    print(f"All {len(MUTATIONS)} mutations turn the suite red.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
