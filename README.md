# cloudflare-dns-iac-template

[![Validate](https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/actions/workflows/validate.yml/badge.svg)](https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/actions/workflows/validate.yml)
[![Deploy](https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/actions/workflows/deploy.yml/badge.svg)](https://github.com/gennadiygrinenko/cloudflare-dns-iac-template/actions/workflows/deploy.yml)
[![Terraform](https://img.shields.io/badge/terraform-%3E%3D1.9-blueviolet?logo=terraform)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> Terraform + Terragrunt + GitHub Actions template for managing Cloudflare DNS across multiple zones: isolated state per zone group, module logic covered by `terraform test`, and safety rails around the changes that DNS cannot undo.

## Why this exists

DNS is the infrastructure with the worst ratio of change size to blast radius. One wrong record takes down mail or the site, propagation makes the mistake outlive the fix, and there is no undo. It is also the layer most often edited by hand in a dashboard, because each individual change looks too small to deserve a pull request.

This template is the smallest setup that makes DNS reviewable without making it tedious. Domains are declared as data in `variables.auto.tfvars`; the module turns that into zones, records, settings, redirects, and WAF rules. Google Workspace mail is one flag rather than a dozen hand-copied records, and the parts that are easy to get subtly wrong — SPF syntax, DMARC report authorization on the receiving zone, DKIM drift — are handled or surfaced explicitly rather than left to the reader.

It is aimed at whoever owns a handful to a few dozen domains: an in-house platform or ops engineer, a consultancy managing client estates, a team that inherited domains across several accounts. The difference from dropping `cloudflare_dns_record` resources into one file is mostly what happens after the happy path — isolated state per zone group so one change plans in seconds and one mistake cannot reach every domain, `prevent_destroy` because DNS has no undo, keys that cannot silently collide, and drift suppression scoped to the one record type that actually drifts. The reasoning behind each of those is in [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md).

## Features

- **Multi-zone structure** — each logical group of domains is an isolated Terraform workspace
- **DRY config** — Terragrunt code generation; zone dirs contain only `variables.auto.tfvars`
- **GitHub Actions CI/CD** — validate on PR, plan + apply on merge to `main` with required approvals
- **Terraform Cloud backend** — remote state, so no state file or credential lives in the repo (Cloudflare and TFC are reached with scoped API tokens from GitHub Secrets)
- **Google Workspace auto-records** — set `google_workspace = true` to auto-generate MX, SPF, DMARC, DKIM, CNAME records
- **Apex shortcut** — set `apex_ip` to auto-create proxied `@` and `www` A records in one line
- **Domain redirect** — set `redirect_to` for a 301 redirect ruleset
- **Plan-based defaults** — set `plan = "pro"` to automatically enable polish, mirage, and WAF managed ruleset; override anything via `settings`
- **WAF & firewall rules** — Pro+ domains get Cloudflare Managed WAF and support custom `firewall_rules`
- **Cloudflare provider v5** — uses the latest provider with `cloudflare_dns_record` and `cloudflare_zone_setting`

## Stack

| Tool | Version |
|---|---|
| Terraform | >= 1.9 (CI pins an exact version in the workflows) |
| Terragrunt | >= 1.0 (CI pins an exact version in the workflows) |
| Cloudflare provider | ~> 5.0 (exact build pinned in each zone's `.terraform.lock.hcl`) |
| GitHub Actions | — |
| Terraform Cloud (HCP) | free tier |

## Repository structure

```
.
├── .github/
│   ├── scripts/
│   │   ├── check-version-pins.sh # Fail when workflows disagree on a tool version
│   │   ├── common.sh             # Shared logging utilities (log_info, log_success, etc.)
│   │   ├── detect-zones.sh       # Detect changed/all zones for CI matrix
│   │   ├── dmarc-checklist.sh    # DMARC authorizations we cannot publish ourselves
│   │   ├── install-terragrunt.sh # Install Terragrunt in CI
│   │   ├── plan-state-moves.sh   # Generate moved.tf for records whose address changed
│   │   ├── refresh-locks.sh      # Move zone locks to the newest allowed provider
│   │   ├── refresh-tools.sh      # Move tool pins to the newest releases
│   │   └── state-ops.sh          # Import / remove / move domain state ops
│   ├── dependabot.yml            # Action, provider and pre-commit updates
│   └── workflows/
│       ├── validate.yml          # PR: validate changed zones in parallel
│       ├── deploy.yml            # main: plan → apply (with approval gate)
│       ├── provider-lock.yml     # Monthly: refresh provider lock, open a PR
│       ├── security.yml          # Trivy config scan → code scanning alerts
│       ├── tool-versions.yml     # Monthly: refresh tool pins, open a PR
│       └── state-ops.yml         # Manual: import/remove/move domain
├── docs/
│   └── DESIGN_DECISIONS.md       # Why the module is shaped this way
├── envs/cloudflare/
│   ├── backend.hcl               # Terraform Cloud backend (shared)
│   ├── zones.hcl                 # Provider + module wiring (shared)
│   └── zones/
│       ├── acme/                 # Example zone
│       │   ├── .terraform.lock.hcl
│       │   ├── terragrunt.hcl
│       │   └── variables.auto.tfvars
│       └── example/              # Minimal zone example
└── terraform/modules/dns-zone/   # Reusable Terraform module
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    └── tests/                    # terraform test — plan-only, no credentials
```

## Quick start

### 1. Fork / clone

```bash
git clone https://github.com/your-username/cloudflare-dns-iac-template.git
cd cloudflare-dns-iac-template
```

### 2. Set up Terraform Cloud

1. Create a free account at [app.terraform.io](https://app.terraform.io)
2. Create an organization
3. Generate an API token: **User Settings → Tokens → Create API token**

### 3. Configure GitHub secrets and variables

In your GitHub repository → **Settings → Secrets and variables → Actions**:

| Name | Type | Description |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | Secret | Cloudflare API token with Zone:Edit + DNS:Edit |
| `TF_API_TOKEN` | Secret | Terraform Cloud API token |
| `CLOUDFLARE_ACCOUNT_ID` | Variable | Your Cloudflare account ID (32-char hex) |
| `TF_CLOUD_ORGANIZATION` | Variable | Your Terraform Cloud organization name |

Until all four exist, the Deploy workflow stops at its preflight job and says so in the run summary: plan and apply are skipped rather than run against nothing. Validate does not need any of them — pull requests work in a fresh fork.

### 4. Set up the production environment

In **Settings → Environments → New environment** → name it `production`:
- Add required reviewers
- Enable "Required reviewers" protection rule

### 5. Add your domains

Copy an existing zone directory and edit `variables.auto.tfvars`:

```bash
cp -r envs/cloudflare/zones/example envs/cloudflare/zones/my-company
# Edit envs/cloudflare/zones/my-company/terragrunt.hcl  (set TF_WORKSPACE)
# Edit envs/cloudflare/zones/my-company/variables.auto.tfvars (add your domains)
```

### 6. Create a pull request

Push to a feature branch. The `validate` workflow will run automatically. On merge to `main`, the `deploy` workflow runs plan → waits for approval → applies.

## Domain configuration reference

### Free plan (minimal)

```hcl
domains = {
  "example.com" = {
    plan    = "free"   # free | pro | business | enterprise
    apex_ip = "1.2.3.4"  # auto-creates proxied A records for @ and www

    # Google Workspace: auto-adds MX (smtp.google.com), SPF, DMARC, mail/calendar CNAMEs
    google_workspace         = true
    google_site_verification = "abc123xyz"          # Google Search Console token
    google_dkim_key          = "MIIBIjANBgkq..."    # from GWS Admin > Gmail > Authenticate email
    spf_includes             = ["sendgrid.net"]      # extra SPF includes
    dmarc_policy             = "reject"              # none | quarantine | reject

    records = [
      # Only records that aren't covered by shortcuts above
      { type = "A",     name = "staging", value = "1.2.3.4", proxied = false, ttl = 300 },
      { type = "TXT",   name = "@",       value = "some-other-verification" },
    ]
  }

  "old-brand.com" = {
    plan        = "free"
    apex_ip     = "1.2.3.4"             # auto-creates @ and www
    redirect_to = "https://example.com" # 301 redirect entire domain
  }
}
```

### Pro plan (automatic defaults)

Setting `plan = "pro"` automatically enables:
- `polish = "lossless"` — image compression
- `mirage = true` — mobile image optimization
- `waf_managed = true` — Cloudflare Managed WAF ruleset

```hcl
domains = {
  "shop.com" = {
    plan             = "pro"
    apex_ip          = "1.2.3.4"    # auto-creates @ and www
    google_workspace = true
    dmarc_policy     = "quarantine"

    # All Pro defaults apply automatically — no extra config needed.
    # Override specific settings if required:
    # settings = {
    #   polish         = "lossy"    # off | lossless | lossy
    #   mirage         = false
    #   rocket_loader  = true       # async JS loading (off by default — can break JS)
    #   security_level = "high"     # off | essentially_off | low | medium | high | under_attack
    #   cache_level    = "aggressive" # aggressive | basic | simplified
    #   max_upload     = 200        # MB; up to 500 on Pro+
    # }

    # Disable WAF if not needed:
    # waf_managed_enabled = false

    # Custom firewall rules (Pro+ only):
    firewall_rules = [
      {
        expression  = "(ip.geoip.country eq \"CN\" or ip.geoip.country eq \"RU\")"
        description = "Challenge high-risk countries"
        action      = "managed_challenge"  # block | challenge | js_challenge | managed_challenge | log | skip
      },
    ]

    records = [
      { type = "A", name = "api", value = "1.2.3.4", proxied = true },
    ]
  }
}
```

### Google Workspace auto-records

When `google_workspace = true`, the following DNS records are created automatically:

| Type | Name | Value |
|------|------|-------|
| MX | `@` | `smtp.google.com` (priority 1) |
| CNAME | `mail` | `ghs.googlehosted.com` |
| CNAME | `calendar` | `ghs.googlehosted.com` |
| TXT | `@` | `v=spf1 include:_spf.google.com [spf_includes] <spf_policy>` |
| TXT | `_dmarc` | `v=DMARC1; p=<dmarc_policy>; rua=mailto:<dmarc_rua>` |

Optional parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `spf_includes` | `list(string)` | Extra SPF includes, e.g. `["sendgrid.net", "mailchimp.com"]` |
| `spf_policy` | `string` | `~all` (default, softfail) \| `-all` (fail) \| `?all` (neutral) |
| `dmarc_policy` | `string` | `none` (default) → `quarantine` → `reject` |
| `dmarc_rua` | `string` | Aggregate report mailbox. Defaults to `dmarc@<domain>`; `mailto:` and case are normalized |
| `google_site_verification` | `string` | Token from Google Search Console (the part after `google-site-verification=`) |
| `google_dkim_key` | `string` | DKIM public key from GWS Admin → Apps → Gmail → Authenticate email |

### DMARC reports to another domain

Per RFC 7489 §7.1, sending reports to a mailbox outside the publishing domain requires the **receiving** zone to authorize it. For `shop.com` with `rua=mailto:dmarc@acme.com`, receivers look up `shop.com._report._dmarc.acme.com TXT "v=DMARC1"` — a record in `acme.com`, not in `shop.com`. Publishing it on the sender does nothing.

The module handles the three cases:

1. **Mailbox in the same domain tree** (the default `dmarc@<domain>`, or `dmarc@reports.<domain>`) — nothing to authorize.
2. **Mailbox in another zone in this same `domains` map** — the authorization record is created for you, in the zone that owns the mailbox. The longest managed suffix wins, since a delegated child zone is authoritative over its parent, and intermediate labels are kept: with `reports.acme.com` managed, `shop.com` → `dmarc@a.reports.acme.com` creates `shop.com._report._dmarc.a` in `reports.acme.com`.
3. **Mailbox anywhere else** — nothing is created and nothing fails. The entry appears in the `dmarc_external_authorizations_required` output instead. Report vendors (EasyDMARC, dmarcian, Valimail) publish a wildcard on their side, so this is a checklist to verify, not an error.

Do **not** copy the receiving domain into a second zone group to get case 2. Two Terragrunt stacks with the same domain means two states fighting over one Cloudflare zone. If publisher and mailbox live in different groups, take the output and add a plain TXT record in the group that actually owns the receiving zone.

Two limits worth knowing, both deliberate:

- Org-domain comparison needs the Public Suffix List, which Terraform cannot read, so nesting is used as an approximation. `a.shop.com` → `dmarc@b.shop.com` is one org-domain but neither is a suffix of the other, so it lands in the checklist even though no record is needed. A harmless extra line. The reverse (a parent that is a public suffix, like `shop.co.uk` → `dmarc@co.uk`) would be the dangerous direction, so the parent case additionally requires the parent to be a zone in this `domains` map.
- The mirror case — a `domains` key that is itself a public suffix, making its subdomains look internal — is a known non-goal. It requires owning a PSL entry.

A managed child zone only answers if its parent delegates to it. If the parent is in the same `domains` map and has no `NS` record for the child, the case-2 record would be written into a zone nobody queries; that shows up in the `dmarc_report_delegation_warnings` output. Delegation configured outside this module is invisible here and is not reported.

### DNS record keys

Each record is keyed as `{domain}__{type}__{name}__{hash12}`, where `hash12` is the first 12 hex characters of `sha256(value:priority)`. Domain, type, and name stay readable in plans; the hash is there so two payloads that only differ by `.` vs `_` cannot collide and silently drop a record.

The key includes the value, so changing a record's content or priority is a replace, not an in-place update. That is how SPF, DMARC, DKIM, and Google site verification updates apply: those four auto-TXT records used to have stable keys with `ignore_changes = [content]` on every record, so Terraform ignored the new value. `ignore_changes` is now only on TXT, and it does not apply across a replace.

Existing state from before this key scheme will destroy and recreate every DNS record on first apply (TXT also move to `cloudflare_dns_record.txt`). On a live estate that is an outage for MX and the mail TXT records, so generate `moved` blocks first — see [Migrating state after a key change](#migrating-state-after-a-key-change).

### All available settings

```hcl
settings = {
  # Available on all plans
  ssl                      = "strict"      # off | flexible | full | strict
  min_tls_version          = "1.2"         # 1.0 | 1.1 | 1.2 | 1.3
  always_use_https         = true
  automatic_https_rewrites = true
  always_online            = false         # serve cached page when origin is down
  ipv6                     = true
  brotli                   = true
  early_hints              = true
  cache_level              = "aggressive"  # aggressive | basic | simplified
  security_level           = "medium"      # off | essentially_off | low | medium | high | under_attack
  max_upload               = 100           # MB; 100 on free, up to 500 on Pro+

  # Pro+ only (ignored on free plan)
  polish        = "lossless"  # off | lossless | lossy
  mirage        = true        # mobile image optimization
  rocket_loader = false       # async JS loading (opt-in — can break some JS)
}
```

## Migrating state after a key change

Record addresses contain a hash of the value, and TXT records live in their own resource. If an upgrade changes either, a plan reads as destroy-and-create for every record. That is harmless for an A record and an outage for MX and the SPF/DKIM/DMARC TXT records.

`make moves zone=<zone>` closes that gap. It reads the current state, matches each record to its new address by what the record *is* — zone, type, name, content, priority — and writes `moved.tf` into the zone directory:

```hcl
moved {
  from = module.dns_zone.cloudflare_dns_record.this["example.com__txt__@__spf__0"]
  to   = module.dns_zone.cloudflare_dns_record.txt["example.com__txt__@__3d1c0d3023a0"]
}
```

Commit that file, and the moves appear in the normal plan as `has moved to` with no destroys. Apply through the usual pipeline, then delete the file in a follow-up change — `moved` blocks are only needed once.

Matching never reconstructs old key formats, because there have been several. A record in state with no counterpart in the configuration is reported separately: it is not moved, and it will be destroyed on apply. If two records in state resolve to the same target address, nothing is written at all — merging them would lose one.

## State operations (manual)

This module does not delete a Cloudflare zone: `cloudflare_zone` has `prevent_destroy`, so removing a domain from `domains` or running `terraform destroy` will fail on apply. DNS has no undo. To drop a domain from state without touching Cloudflare, use `remove-domain` below (or `make remove`).

Use the **State Operations** workflow in the GitHub Actions UI:

| Operation | Description |
|---|---|
| `import-domain` | Import an existing Cloudflare zone into Terraform state |
| `remove-domain` | Remove a domain from state (does not delete from Cloudflare) |
| `move-domain` | Move a domain from one zone to another |

## Local development

```bash
# Install dependencies (Terragrunt 1.0+ — the CLI renamed its flags in 1.0)
brew install terraform terragrunt pre-commit tflint

# Set environment variables
export CLOUDFLARE_API_TOKEN=your-token
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export TF_CLOUD_ORGANIZATION=your-org

# Install pre-commit hooks
make hooks

# Format all files
make fmt

# Run module logic tests (no Cloudflare account needed)
make test

# Work on a zone
make init  zone=acme
make plan  zone=acme
make apply zone=acme

# Provider version
make lock         zone=acme   # refresh lock hashes (all platforms)
make lock-upgrade zone=acme   # move to the newest provider allowed by versions.tf

# State operations
make import zone=acme domain=acme-corp.io
make remove zone=acme domain=acme-corp.io
make move   zone=acme domain=acme-corp.io from_zone=legacy

# Show all available commands
make help
```

## License

MIT
