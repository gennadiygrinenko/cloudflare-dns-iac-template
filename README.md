# cloudflare-dns-iac-template

> Production-ready IaC template for managing Cloudflare DNS across multiple zones using Terraform + Terragrunt + GitHub Actions.

## Features

- **Multi-zone structure** — each logical group of domains is an isolated Terraform workspace
- **DRY config** — Terragrunt code generation; zone dirs contain only `variables.auto.tfvars`
- **GitHub Actions CI/CD** — validate on PR, plan + apply on merge to `main` with required approvals
- **Terraform Cloud backend** — remote state, no static cloud credentials needed
- **Google Workspace auto-records** — set `google_workspace = true` to auto-generate MX, SPF, DMARC, DKIM, CNAME records
- **Apex shortcut** — set `apex_ip` to auto-create proxied `@` and `www` A records in one line
- **Domain redirect** — set `redirect_to` for a 301 redirect ruleset
- **Plan-based defaults** — set `plan = "pro"` to automatically enable polish, mirage, and WAF managed ruleset; override anything via `settings`
- **WAF & firewall rules** — Pro+ domains get Cloudflare Managed WAF and support custom `firewall_rules`
- **Cloudflare provider v5** — uses the latest provider with `cloudflare_dns_record` and `cloudflare_zone_setting`

## Stack

| Tool | Version |
|---|---|
| Terraform | >= 1.9 |
| Terragrunt | >= 0.67 |
| Cloudflare provider | ~> 5.0 |
| GitHub Actions | — |
| Terraform Cloud (HCP) | free tier |

## Repository structure

```
.
├── .github/
│   ├── scripts/
│   │   ├── common.sh             # Shared logging utilities (log_info, log_success, etc.)
│   │   ├── detect-zones.sh       # Detect changed/all zones for CI matrix
│   │   ├── install-terragrunt.sh # Install Terragrunt in CI
│   │   └── state-ops.sh          # Import / remove / move domain state ops
│   └── workflows/
│       ├── validate.yml          # PR: validate changed zones in parallel
│       ├── deploy.yml            # main: plan → apply (with approval gate)
│       └── state-ops.yml         # Manual: import/remove/move domain
├── envs/cloudflare/
│   ├── backend.hcl               # Terraform Cloud backend (shared)
│   ├── zones.hcl                 # Provider + module wiring (shared)
│   └── zones/
│       ├── acme/                 # Example zone
│       │   ├── terragrunt.hcl
│       │   └── variables.auto.tfvars
│       └── example/              # Minimal zone example
└── terraform/modules/dns-zone/   # Reusable Terraform module
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
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
| TXT | `@` | `v=spf1 include:_spf.google.com [spf_includes] ~all` |
| TXT | `_dmarc` | `v=DMARC1; p=<dmarc_policy>; rua=mailto:dmarc@<domain>` |

Optional parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `spf_includes` | `list(string)` | Extra SPF includes, e.g. `["sendgrid.net", "mailchimp.com"]` |
| `dmarc_policy` | `string` | `none` (default) → `quarantine` → `reject` |
| `google_site_verification` | `string` | Token from Google Search Console (the part after `google-site-verification=`) |
| `google_dkim_key` | `string` | DKIM public key from GWS Admin → Apps → Gmail → Authenticate email |

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

## State operations (manual)

Use the **State Operations** workflow in the GitHub Actions UI:

| Operation | Description |
|---|---|
| `import-domain` | Import an existing Cloudflare zone into Terraform state |
| `remove-domain` | Remove a domain from state (does not delete from Cloudflare) |
| `move-domain` | Move a domain from one zone to another |

## Local development

```bash
# Install dependencies
brew install terraform terragrunt pre-commit tflint

# Set environment variables
export CLOUDFLARE_API_TOKEN=your-token
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export TF_CLOUD_ORGANIZATION=your-org

# Install pre-commit hooks
pre-commit install

# Work on a zone
cd envs/cloudflare/zones/acme
terragrunt init
terragrunt plan
```

## License

MIT
