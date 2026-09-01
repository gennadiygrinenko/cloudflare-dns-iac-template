# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [2.5.0] - 2026-09-02

The deploy path, examined. Its decision logic moved somewhere a test can reach it and got eleven cases; what those cases cannot reach is now written down rather than implied to work.

### Added

- The plan and apply decision logic is now testable, and tested. It moved out of `deploy.yml` into `plan-zone.sh` and `apply-zone.sh`, and 11 cases exercise it with a stubbed Terragrunt: exit codes 0, 2 and 1, the `NO_CHANGES` marker, stale artifacts from an earlier run, and an apply that finds neither file. That last case is the fault this pipeline actually shipped — a missing artifact read as "no changes", reporting success while the plan had failed outright. The faults were all shell logic, so none of them need a Cloudflare account to reproduce; none were reachable by a test while the logic lived inside the workflow
- `docs/DESIGN_DECISIONS.md` now states what is verified and what is not. `terragrunt apply` has never run in this repository: every Deploy run so far had no credentials, so `plan` failed and the apply step exited zero on the absent artifact. The decision logic is covered now; the provider interaction is not, and the document says so and says what would close it

## [2.4.0] - 2026-09-02

The last gap in version coverage. Every pinned version in this repository now has something that will tell you when it moves — no exceptions left.

### Added

- `Tool versions` workflow — monthly, it moves `TERRAFORM_VERSION`, `TERRAGRUNT_VERSION`, `TFLINT_VERSION`, `TRIVY_VERSION` and `PRE_COMMIT_VERSION` to the newest release each project has published, and opens a pull request when anything moved. These are plain env strings, so no Dependabot ecosystem reaches them; the `Version pins` check keeps the workflows agreeing with each other but cannot know a newer release exists. Each pin keeps its own prefix style, the module tests and every zone are run against the new versions inside the workflow, and the run fails rather than committing if the rewrite left the pins disagreeing

## [2.3.0] - 2026-09-01

Enforcement, not new rules. The pre-commit hooks had been configured since 1.0 and run by nobody but whoever remembered `make hooks`; now they run where they cannot be skipped, and Validate can actually see the files they guard.

### Added

- `File hygiene` job in Validate — the pre-commit hooks were local-only, so anyone who never ran `make hooks` bypassed every one of them, and nothing checked for private keys, oversized files or trailing whitespace at all. The job runs the hooks that CI did not already cover; the Terraform and Terragrunt ones stay skipped, since `fmt`, `tflint` and `validate` already run as their own steps

### Changed

- Validate no longer filters by path. The filter listed the Terraform directories, so a pull request touching only a template, the README or `dependabot.yml` ran no checks whatsoever — which is exactly the set of files the new hygiene job exists to guard. Zone validation is still skipped internally for zones that did not change

## [2.2.0] - 2026-09-01

Housekeeping, all of it in CI. The theme is versions that nothing was watching: after this, every pinned version in the repository is either updated by a robot or checked for agreement by a job.

### Added

- Dependabot now watches `.pre-commit-config.yaml`. The `github-actions` and `terraform` ecosystems did not cover it, which left the three pinned hook revisions as the only versions in the repository with nothing watching them — a stale hook stops enforcing a rule without ever failing. Grouped into one pull request, since no CI job runs pre-commit
- `Version pins` check in Validate — `TERRAFORM_VERSION` and `TERRAGRUNT_VERSION` are plain env strings repeated across four workflows, which Dependabot cannot see and no job noticed disagreeing. The check compares every `*_VERSION` pin across the workflows and fails when one of them is out of step, naming the file and line

### Changed

- Terraform 1.15.8 → 1.16.0 in CI
- Pre-commit hooks: `pre-commit-terraform` v1.96.1 → v1.109.0, `pre-commit-hooks` v5.0.0 → v6.0.0, `shellcheck-py` v0.10.0.1 → v0.11.0.1 — the first pull request the new Dependabot coverage produced
- The README stack table no longer restates the exact versions CI pins; it names where they live. Restating a version that another file owns is what left the table claiming a provider build that had not been locked for a month

## [2.1.0] - 2026-09-01

Nothing about the configuration changes: `variables.auto.tfvars` and the module interface are the same as 2.0.0. What is new is a supported way through the 2.0.0 state migration, and a provider lock refresh that actually works — it had been failing on every run since the first one, in three separate ways, without anyone being told.

### Added

- `make moves zone=<zone>` — generates a `moved.tf` for records whose address changed, matching state to configuration by zone, type, name, content, and priority rather than by reconstructing an old key format. The 2.0.0 key change becomes a reviewable set of `moved` blocks instead of a destroy-and-create of every record, which for MX and the SPF/DKIM/DMARC TXT records was a gap in mail delivery
- Records present in state but absent from the configuration are reported separately, since they are destroyed rather than moved
- `make moves` refuses to write anything when two records in state resolve to the same target address, rather than emitting a `moved.tf` that would merge them and lose one
- `dns_records` is now exposed through the Terragrunt-generated root outputs, not just the module

### Changed

- Cloudflare provider 5.23.0 → 5.24.0 in the zone locks; the `~> 5.0` constraint is unchanged
- Terragrunt 1.1.3 → 1.1.4 in CI

### Fixed

- **README facts that had drifted from the repository.** The stack table named the locked provider build, which the monthly lock refresh moves without touching the README, so it now points at the lock files instead of restating them; `plan-state-moves.sh` and `refresh-locks.sh` were missing from the structure listing; and the key-change section told the reader to run `terraform state mv` by hand without mentioning that `make moves` writes those blocks for them
- **The `Provider lock` workflow could never open its pull request twice.** The refreshed lock branch was pushed with a bare `--force-with-lease`, which resolves the lease base through the configured refspec — and `actions/checkout` configures `main` only. The first run passed because pushing a branch the remote does not have satisfies the lease trivially; from the second run on, git found no base for the existing branch and rejected the push with `stale info`, before the pull request step was ever reached. The base is now named explicitly, so a create still works, a re-push forces, and a concurrent push to the branch is still refused
- **Provider locks were being written for one platform only.** `make lock`, `make lock-upgrade`, and the `Provider lock` workflow all ran `terraform providers lock -platform=...` inside the zone directory. Terragrunt 1.x copies the unit into `.terragrunt-cache` and generates the `.tf` files there, so that directory holds no configuration, the command locked nothing, and the committed lock kept only the `h1:` hash that `init` had recorded for the machine that ran it — three platform hashes became one, with no error anywhere. They now go through `terragrunt run --`, and the refresh script fails when a lock ends up with fewer `h1:` hashes than platforms rather than committing it
- **`gh pr create` failures were reported as a missing pull request.** Its stderr was discarded and any failure fell through to `gh pr edit`, which then said `no pull requests found for branch` whatever the real cause was — masking, in the first monthly run, that Actions lacked permission to create pull requests in the repository. The step now asks whether the pull request exists and lets errors surface

## [2.0.0] - 2026-08-14

Configuration syntax is unchanged — existing `variables.auto.tfvars` files keep working. What breaks is where records live in state, and which Terragrunt runs them.

### Breaking

- **Record addresses changed.** Keys are now `{domain}__{type}__{name}__{hash12}`, where the hash covers the value and priority. The first apply on existing state destroys and recreates every DNS record. Either `terraform state mv` each address onto its new key (the new `dns_records` output lists them), or accept the recreate on a zone that can afford brief churn.
- **TXT records moved to their own resource.** They are planned under `cloudflare_dns_record.txt` instead of `cloudflare_dns_record.this`, so their addresses change even before the key scheme is considered.
- **Terragrunt 1.0 or newer is required.** Terragrunt 1.0 removed the `--terragrunt-` flag prefix and renamed `hclfmt` to `hcl fmt`. Every workflow, script, and Makefile target was migrated; 0.x no longer works with this repo.
- **Zones can no longer be destroyed by Terraform.** `cloudflare_zone` carries `prevent_destroy`, so removing a domain from `domains` — or a `terraform destroy` — now fails on apply. Use the `remove-domain` state operation to stop managing a domain without deleting it in Cloudflare.

### Added

- `dmarc_rua` — aggregate report mailbox, defaulting to `dmarc@<domain>`; the `mailto:` prefix and case are normalized, and the address is validated
- `spf_policy` (`~all` | `-all` | `?all`) with validation
- Automatic `_report._dmarc` authorization records when the report mailbox lives in another zone managed by the same module (RFC 7489 §7.1). The record is created in the receiving zone, choosing the longest managed suffix and preserving intermediate labels
- `dmarc_external_authorizations_required` output — records that must be published in zones this module does not manage, surfaced as a pull request comment on same-repository pull requests
- `dmarc_report_delegation_warnings` output — a managed child zone holding an authorization record without NS delegation from its managed parent
- `dns_records` output — the record inventory as the module resolved it, known at plan time
- `terraform test` suite: 15 plan-only cases covering record keying and collisions, the TXT split, `apex_ip` and Google Workspace expansion, SPF assembly, variable validation, and every branch of DMARC report authorization
- `make test`, `make lock`, `make lock-upgrade`
- `LICENSE` (MIT), which the README badge had been pointing at all along
- `docs/DESIGN_DECISIONS.md`, and a `## Why this exists` section in the README

### Changed

- Zone `.terraform.lock.hcl` files are committed and pin `cloudflare/cloudflare` 5.23.0 with hashes for linux and macOS. They were previously gitignored, so every run resolved to whatever the newest 5.x was that day
- Terraform 1.9.8 → 1.15.8 in CI
- Deploy now stops at a preflight job when `TF_CLOUD_ORGANIZATION`, `CLOUDFLARE_ACCOUNT_ID`, `TF_API_TOKEN`, or `CLOUDFLARE_API_TOKEN` are missing, listing what is absent instead of running against nothing
- Changes to the module, the shared Terragrunt HCL, or CI now validate every zone; previously only zone directories triggered zone validation
- Dependabot (weekly, actions grouped into one pull request), a monthly `Provider lock` workflow that moves the locks within the constraint, and a monthly Trivy scan reporting to code scanning rather than blocking pull requests
- `tflint` pinned instead of tracking `latest`
- README states the credential model accurately: scoped API tokens in GitHub Secrets, not OIDC

### Fixed

- **`ignore_changes` scoped to TXT.** It previously applied to every record type. Combined with keys that omitted the value, updates to the auto-generated Google site verification, DKIM, SPF, and DMARC records were silently ignored — the plan was empty and the zone kept serving the old value
- **Key collisions.** Keys were built with `replace(value, ".", "_")`, so `1.2.3.4` and `1_2_3_4` produced the same key and one record vanished without an error
- **Deploy reported success when `terragrunt plan` failed.** The pipe to `tee` discarded the exit code, "no changes" was inferred by grepping the log, and Apply read a missing artifact as an empty plan. Plan now uses `-detailed-exitcode` with `PIPESTATUS` and always uploads either a plan or a `NO_CHANGES` marker
- **Plan files were written into `.terragrunt-cache`** under Terragrunt 1.x, leaving nothing to upload or read; `-out` is now absolute
- **`detect-zones.sh` wrote multiline JSON to `$GITHUB_OUTPUT`**, which failed with `Invalid format` on every Validate and Deploy run
- **`.tflint.hcl` referenced a plugin that does not exist** (`tflint-ruleset-cloudflare`), so `tflint --init` returned 404 and failed the job
- **An empty `TF_CLOUD_ORGANIZATION` broke `terragrunt validate`** on pull requests; validation now runs against a local backend, which needs no organization

## [1.2.0] - 2026-04-13

### Added
- `apex_ip` shortcut — auto-creates proxied A records for `@` and `www` in one line
- `google_site_verification` shortcut — auto-creates Google Search Console TXT record
- `google_dkim_key` shortcut — auto-creates `google._domainkey` TXT record
- `dmarc_policy` parameter (`none` | `quarantine` | `reject`) with validation
- `common.sh` — shared structured logging for all CI scripts (`log_info`, `log_success`, `log_warning`, `log_error`, `log_section`)
- Makefile with convenience commands for local development

### Changed
- Google Workspace MX simplified from 5 records to single `smtp.google.com` (per current Google recommendation)
- All CI scripts and workflow inline steps now use structured logging with emoji, ANSI colors, and timestamps
- README updated with badges, Google Workspace parameter table, and simplified examples

## [1.1.0] - 2026-04-09

### Added
- Pro+ plan support with automatic plan-based defaults (polish, mirage, WAF managed ruleset)
- `waf_managed_enabled` flag to opt out of WAF on Pro+ plans
- `firewall_rules` — custom Cloudflare firewall rules (Pro+ only)
- `spf_includes` — extra SPF includes appended to the auto-generated SPF record
- `cloudflare_ruleset` for WAF managed ruleset and custom firewall rules

### Changed
- Updated `cloudflare_ruleset` to provider v5 attribute syntax
- Removed read-only `plan` field from zone resource

## [1.0.0] - 2026-04-09

### Added
- Initial release
- Multi-zone Terraform + Terragrunt structure
- `dns-zone` reusable module with `cloudflare_zone`, `cloudflare_dns_record`, `cloudflare_zone_setting`
- `google_workspace = true` auto-generates MX, SPF, DMARC, mail/calendar CNAME records
- `redirect_to` — 301 redirect ruleset for entire zone
- GitHub Actions workflows: `validate` (PR), `deploy` (plan + apply), `state-ops` (manual)
- Terraform Cloud backend with remote state
- Pre-commit hooks: `terraform_fmt`, `terraform_validate`, `terraform_tflint`, `terragrunt_fmt`, shellcheck
- `CODEOWNERS` for required reviews on infrastructure changes

[Unreleased]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.5.0...HEAD
[2.5.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.3.0...v2.4.0
[2.3.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/releases/tag/v1.0.0
