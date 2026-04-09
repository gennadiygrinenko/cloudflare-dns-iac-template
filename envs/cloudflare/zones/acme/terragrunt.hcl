include "root" {
  path = find_in_parent_folders("backend.hcl")
}

include "zone" {
  path = find_in_parent_folders("zones.hcl")
}

# Workspace name in Terraform Cloud: cloudflare-dns-acme
terraform {
  extra_arguments "workspace" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = {
      TF_WORKSPACE = "cloudflare-dns-acme"
    }
  }
}
