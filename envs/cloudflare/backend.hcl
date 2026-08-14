# Root Terragrunt backend config.
# Terraform Cloud (HCP) remote backend for plan/apply: state stays out of the
# repo, but TFC itself is still reached with a static token (TF_API_TOKEN), and
# Cloudflare with CLOUDFLARE_API_TOKEN. Neither is OIDC — see
# docs/DESIGN_DECISIONS.md.
#
# Set TF_CLOUD_ORGANIZATION via environment variables, or override locals.
# CI validate sets TG_BACKEND=local so PRs do not need a TFC organization.

locals {
  raw_org      = get_env("TF_CLOUD_ORGANIZATION", "")
  organization = local.raw_org != "" ? local.raw_org : "your-org"
  backend      = get_env("TG_BACKEND", "cloud")

  backend_local = <<-EOF
    terraform {
      backend "local" {}
    }
  EOF

  backend_cloud = <<-EOF
    terraform {
      cloud {
        organization = "${local.organization}"

        workspaces {
          tags = ["cloudflare-dns"]
        }
      }
    }
  EOF
}

generate "backend" {
  path      = "backend.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = local.backend == "local" ? local.backend_local : local.backend_cloud
}
