# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Changed
- **Breaking for local use:** Terragrunt 0.67 → 1.1.3 and Terraform 1.9.8 → 1.15.8. Terragrunt 1.0 removed the `--terragrunt-` flag prefix and renamed `hclfmt` to `hcl fmt`, so every workflow, script, and Makefile target was migrated. Terragrunt < 1.0 no longer works with this repo
- Zone `.terraform.lock.hcl` files are committed and pin `cloudflare/cloudflare` 5.23.0 with hashes for linux and macOS. Previously they were gitignored, so every run resolved to whatever the newest 5.x was that day
- `make lock` / `make lock-upgrade` to refresh or raise the pinned provider

### CI
- **Fixed:** Deploy reported success when `terragrunt plan` failed. The pipe to `tee` discarded the exit code, "no changes" was inferred by grepping the log, and Apply treated a missing artifact as an empty plan. Plan now uses `-detailed-exitcode` with `PIPESTATUS`, and always uploads either a plan or a `NO_CHANGES` marker, so a missing artifact is a failure
- Deploy preflight job: without `TF_CLOUD_ORGANIZATION`, `CLOUDFLARE_ACCOUNT_ID`, `TF_API_TOKEN`, and `CLOUDFLARE_API_TOKEN`, plan and apply are skipped with a summary explaining why
- Dependabot for GitHub Actions and the Terraform provider constraint, with action updates grouped into a single pull request
- Changes to the shared Terragrunt HCL or to CI now validate every zone, not zero of them — an action bump used to pass checks that never ran the job using it
- `tflint` version pinned instead of tracking `latest`
- Trivy misconfiguration scan in a separate `Security` workflow, reporting to code scanning rather than blocking pull requests

### Documentation
- `docs/DESIGN_DECISIONS.md` — rationale for state isolation, TXT-scoped `ignore_changes`, hashed record keys, `prevent_destroy`, `coalesce` defaults, DMARC report authorization, and the credential model
- README: `## Why this exists`, and an accurate description of the credential model (scoped API tokens, not OIDC)

### Added
- `dmarc_rua` — aggregate report mailbox, defaulting to `dmarc@<domain>`; `mailto:` prefix and case are normalized
- `spf_policy` (`~all` | `-all` | `?all`) with validation
- Automatic `_report._dmarc` authorization records when the rua mailbox lives in another zone managed by the same module (RFC 7489 §7.1), placed in the receiving zone with intermediate labels preserved
- `dmarc_external_authorizations_required` output — records that must be published in zones this module does not manage, surfaced as a PR comment on same-repo pull requests
- `dmarc_report_delegation_warnings` output — managed child zone with no NS delegation from its managed parent

### Fixed
- Scope `ignore_changes` to TXT records. Auto-generated GSC, DKIM, SPF, and DMARC records previously kept a stable key, so content updates were silently ignored.
- Derive `for_each` keys from a hash of value + priority so `replace(".", "_")` cannot collide two records into one map entry.

### Changed
- DNS records are split into `cloudflare_dns_record.this` (non-TXT) and `cloudflare_dns_record.txt`.
- Record keys are `{domain}__{type}__{name}__{hash12}`. **Breaking:** existing state will recreate every DNS record unless addresses are `state mv`'d.

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
