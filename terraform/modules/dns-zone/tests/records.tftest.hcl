# Record keying, the TXT/non-TXT split, and the shortcuts that expand into
# several records. These are the parts where a mistake is silent: a map key
# collision drops a record without an error, and a stale key makes an update
# a no-op.
#
# Plan-only: no Cloudflare credentials, no API calls.

variables {
  account_id = "0123456789abcdef0123456789abcdef"
}

run "values_differing_only_by_punctuation_do_not_collide" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        records = [
          # The old key scheme ran replace(value, ".", "_") over both of these
          # and produced one key, so one record silently disappeared.
          { type = "TXT", name = "probe", value = "a.b" },
          { type = "TXT", name = "probe", value = "a_b" },
        ]
      }
    }
  }

  assert {
    condition     = length(output.dns_records) == 2
    error_message = "Two distinct values must produce two records, not one collided key."
  }

  assert {
    condition = length(distinct([
      for r in values(output.dns_records) : r.value
    ])) == 2
    error_message = "Both record values must survive keying."
  }
}

run "txt_records_are_split_from_the_rest" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        apex_ip          = "203.0.113.10"
        google_workspace = true
        google_dkim_key  = "MIIBIjANBgkq"
        records = [
          { type = "CNAME", name = "docs", value = "hosting.example.com" },
        ]
      }
    }
  }

  # Only TXT drifts: Cloudflare rechunks long values, so only that resource
  # carries ignore_changes. Everything else must apply content updates.
  assert {
    condition = alltrue([
      for r in values(output.dns_records) :
      r.resource == (r.type == "TXT" ? "cloudflare_dns_record.txt" : "cloudflare_dns_record.this")
    ])
    error_message = "TXT records belong to cloudflare_dns_record.txt and nothing else does."
  }

  assert {
    condition     = length(cloudflare_dns_record.txt) == length([for r in values(output.dns_records) : r if r.type == "TXT"])
    error_message = "Every TXT record must be planned under cloudflare_dns_record.txt."
  }

  assert {
    condition     = length(cloudflare_dns_record.this) == length([for r in values(output.dns_records) : r if r.type != "TXT"])
    error_message = "Every non-TXT record must be planned under cloudflare_dns_record.this."
  }

  assert {
    condition     = length(cloudflare_dns_record.this) + length(cloudflare_dns_record.txt) == length(output.dns_records)
    error_message = "The split must not drop or duplicate records."
  }
}

run "record_keys_carry_the_value" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        records = [
          { type = "A", name = "api", value = "203.0.113.10" },
        ]
      }
    }
  }

  # A key that ignores the value makes an update invisible: same key, and
  # ignore_changes on TXT would then suppress the change entirely.
  assert {
    condition     = length(regexall("^shop\\.com__a__api__[0-9a-f]{12}$", keys(output.dns_records)[0])) == 1
    error_message = "Keys must read {domain}__{type}__{name}__{hash} with a 12-character hash of the value."
  }
}

run "apex_ip_expands_to_proxied_root_and_www" {
  command = plan

  variables {
    domains = {
      "shop.com" = { apex_ip = "203.0.113.10" }
    }
  }

  assert {
    condition     = length(output.dns_records) == 2
    error_message = "apex_ip creates exactly the @ and www records."
  }

  assert {
    condition = alltrue([
      for r in values(output.dns_records) :
      r.type == "A" && r.value == "203.0.113.10"
    ])
    error_message = "Both apex records point at the configured address."
  }

  assert {
    condition     = sort([for r in values(output.dns_records) : r.name]) == tolist(["@", "www"])
    error_message = "apex_ip covers the root and www, nothing else."
  }
}

run "spf_is_assembled_without_empty_fields" {
  command = plan

  variables {
    domains = {
      "with-includes.com" = {
        google_workspace = true
        spf_includes     = ["sendgrid.net", "mailchimp.com"]
        spf_policy       = "-all"
      }
      "bare.com" = {
        google_workspace = true
      }
    }
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.value == "v=spf1 include:_spf.google.com include:sendgrid.net include:mailchimp.com -all"
    ])
    error_message = "Includes are appended in order and the policy is configurable."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.value == "v=spf1 include:_spf.google.com ~all"
    ])
    error_message = "An empty spf_includes must not leave a double space before the policy."
  }
}

run "google_workspace_expands_to_the_documented_set" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        google_workspace         = true
        google_site_verification = "abc123"
        google_dkim_key          = "MIIBIjANBgkq"
      }
    }
  }

  assert {
    condition     = length([for r in values(output.dns_records) : r if r.type == "MX" && r.value == "smtp.google.com" && r.priority == 1]) == 1
    error_message = "Google Workspace mail routes through a single MX at priority 1."
  }

  assert {
    condition     = sort([for r in values(output.dns_records) : r.name if r.type == "CNAME"]) == tolist(["calendar", "mail"])
    error_message = "Google Workspace adds the mail and calendar CNAMEs."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.name == "google._domainkey" && r.value == "v=DKIM1; k=rsa; p=MIIBIjANBgkq"
    ])
    error_message = "The DKIM record is built from the bare key."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.value == "google-site-verification=abc123"
    ])
    error_message = "Search Console verification is built from the bare token."
  }
}

run "rejects_an_unknown_spf_policy" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        google_workspace = true
        spf_policy       = "all"
      }
    }
  }

  expect_failures = [var.domains]
}

run "rejects_a_malformed_dmarc_mailbox" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        google_workspace = true
        dmarc_rua        = "not-an-address"
      }
    }
  }

  expect_failures = [var.domains]
}
