# Root Terragrunt backend config.
# Terraform Cloud (HCP) remote backend — no static credentials needed.
#
# Set TF_CLOUD_ORGANIZATION and TF_WORKSPACE_* via environment variables,
# or override the locals below per environment.

locals {
  organization = get_env("TF_CLOUD_ORGANIZATION", "your-org")
}

generate "backend" {
  path      = "backend.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
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
