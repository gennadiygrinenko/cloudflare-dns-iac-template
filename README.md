# cloudflare-dns-iac-template

> Production-ready IaC template for managing Cloudflare DNS across multiple zones using Terraform + Terragrunt + GitHub Actions.

## Features

- **Multi-zone structure** — each logical group of domains is an isolated Terraform workspace
- **DRY config** — Terragrunt code generation; zone dirs contain only `variables.auto.tfvars`
- **GitHub Actions CI/CD** — validate on PR, plan + apply on merge to `main` with required approvals
- **Terraform Cloud backend** — remote state, no static cloud credentials needed
- **Google Workspace auto-records** — set `google_workspace = true` to auto-generate MX, SPF, DMARC, CNAME records
- **Domain redirect** — set `redirect_to` for a 301 redirect ruleset
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

```hcl
domains = {
  "example.com" = {
    plan             = "free"              # free | pro | business | enterprise
    google_workspace = true                # auto-adds MX, SPF, DMARC, CNAME

    records = [
      { type = "A",     name = "@",   value = "1.2.3.4",          proxied = true  },
      { type = "CNAME", name = "www", value = "example.com",       proxied = true  },
      { type = "TXT",   name = "@",   value = "some-verification", proxied = false },
    ]

    settings = {
      ssl             = "strict"   # off | flexible | full | strict
      min_tls_version = "1.2"
    }
  }

  "old-brand.com" = {
    plan        = "free"
    redirect_to = "https://example.com"  # 301 redirect entire domain
    records = [
      { type = "A", name = "@",   value = "1.2.3.4", proxied = true },
      { type = "A", name = "www", value = "1.2.3.4", proxied = true },
    ]
  }
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
