# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

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
