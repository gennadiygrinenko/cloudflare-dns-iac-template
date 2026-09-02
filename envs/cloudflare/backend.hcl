# Root Terragrunt backend config.
#
# State lives in a Cloudflare R2 bucket through Terraform's S3 backend. GitHub
# has no built-in Terraform state store (GitLab does), so state needs a home
# outside the runner; R2 keeps it with the vendor the repository already talks
# to, S3-compatible, on a free tier. Credentials are an R2 API token (access
# key + secret), read by the S3 backend from AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY -- see docs/DESIGN_DECISIONS.md.
#
# One state object per zone directory: zones/<zone>/terraform.tfstate.
# CI validate sets TG_BACKEND=local so pull requests need no bucket at all.

locals {
  backend    = get_env("TG_BACKEND", "r2")
  bucket     = get_env("R2_BUCKET", "")
  account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")

  backend_local = <<-EOF
    terraform {
      backend "local" {}
    }
  EOF

  # Locking uses the S3 backend's native lock file, which relies on
  # conditional writes; R2 supports them. skip_* flags are what R2 needs from
  # an S3 client that is not talking to AWS.
  backend_r2 = <<-EOF
    terraform {
      backend "s3" {
        bucket = "${local.bucket}"
        key    = "${path_relative_to_include()}/terraform.tfstate"
        region = "auto"

        endpoints = {
          s3 = "https://${local.account_id}.r2.cloudflarestorage.com"
        }

        use_lockfile                = true
        use_path_style              = true
        skip_credentials_validation = true
        skip_region_validation      = true
        skip_requesting_account_id  = true
        skip_metadata_api_check     = true
        skip_s3_checksum            = true
      }
    }
  EOF
}

generate "backend" {
  path      = "backend.generated.tf"
  if_exists = "overwrite_terragrunt"

  contents = local.backend == "local" ? local.backend_local : local.backend_r2
}
