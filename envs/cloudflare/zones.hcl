# Shared Terragrunt config included by every zone.
# Generates provider + module wiring so zone dirs stay minimal (only tfvars).

locals {
  account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")
}

# ── Provider ────────────────────────────────────────────────────────────────
generate "provider" {
  path      = "provider.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "cloudflare" {
      # CLOUDFLARE_API_TOKEN env var is read automatically by the provider.
      # Never hardcode the token here.
    }
  EOF
}

# ── Versions ────────────────────────────────────────────────────────────────
generate "versions" {
  path      = "versions.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    terraform {
      required_version = ">= 1.9.0"

      required_providers {
        cloudflare = {
          source  = "cloudflare/cloudflare"
          version = "~> 5.0"
        }
      }
    }
  EOF
}

# ── Module wiring ────────────────────────────────────────────────────────────
generate "main" {
  path      = "main.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    variable "domains" {
      description = "Map of domain name → domain configuration. Defined in variables.auto.tfvars."
      type        = any
    }

    module "dns_zone" {
      source     = "${get_repo_root()}/terraform/modules/dns-zone"
      account_id = "${local.account_id}"
      domains    = var.domains
    }

    output "zone_ids" {
      value = module.dns_zone.zone_ids
    }

    output "zone_name_servers" {
      value = module.dns_zone.zone_name_servers
    }
  EOF
}
