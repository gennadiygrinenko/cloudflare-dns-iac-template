# DMARC aggregate reporting to a mailbox outside the publishing domain.
#
# RFC 7489 §7.1 requires the receiving zone to authorize the sender. Getting
# this wrong is silent — reports are simply never delivered — so each branch is
# pinned here rather than left to a reviewer's memory.
#
# Plan-only: no Cloudflare credentials, no API calls.

variables {
  account_id = "0123456789abcdef0123456789abcdef"
}

run "default_rua_needs_no_authorization" {
  command = plan

  variables {
    domains = {
      "shop.com" = { google_workspace = true }
    }
  }

  assert {
    condition     = length(output.dmarc_external_authorizations_required) == 0
    error_message = "dmarc@<domain> is the same organizational domain and must not be reported as external."
  }

  assert {
    condition     = length([for r in values(output.dns_records) : r if strcontains(r.name, "_report._dmarc")]) == 0
    error_message = "No authorization record should be created for a mailbox in the publishing domain."
  }
}

run "subdomain_mailbox_is_internal" {
  command = plan

  variables {
    domains = {
      "shop.com"      = { google_workspace = true }
      "mail.shop.com" = { google_workspace = true, dmarc_rua = "dmarc@shop.com" }
    }
  }

  assert {
    condition     = length(output.dmarc_external_authorizations_required) == 0
    error_message = "mail.shop.com -> dmarc@shop.com shares an organizational domain; no authorization is required."
  }
}

run "vendor_mailbox_is_reported_not_created" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        google_workspace = true
        dmarc_rua        = "MAILTO:Agg@vendor.example"
      }
    }
  }

  assert {
    condition     = keys(output.dmarc_external_authorizations_required) == ["shop.com"]
    error_message = "A mailbox in an unmanaged zone must appear in the checklist."
  }

  assert {
    condition     = output.dmarc_external_authorizations_required["shop.com"].fqdn == "shop.com._report._dmarc.vendor.example"
    error_message = "Checklist FQDN must be <publisher>._report._dmarc.<rua-domain>; the mailto: prefix and case must be normalized away."
  }

  assert {
    condition     = length([for r in values(output.dns_records) : r if strcontains(r.name, "_report._dmarc")]) == 0
    error_message = "Nothing may be created for a zone this module does not manage."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.name == "_dmarc" && r.value == "v=DMARC1; p=none; rua=mailto:agg@vendor.example"
    ])
    error_message = "The DMARC record must carry the normalized rua address."
  }
}

run "public_suffix_parent_is_not_internal" {
  command = plan

  variables {
    domains = {
      # endswith("shop.co.uk", ".co.uk") is true, but co.uk is a public suffix
      # and a different organizational domain. Treating it as internal would
      # skip an authorization that is actually required.
      "shop.co.uk" = {
        google_workspace = true
        dmarc_rua        = "dmarc@co.uk"
      }
    }
  }

  assert {
    condition     = keys(output.dmarc_external_authorizations_required) == ["shop.co.uk"]
    error_message = "A parent that is not a managed zone must never be treated as the same organizational domain."
  }
}

run "mailbox_in_a_sibling_managed_zone_is_created_there" {
  command = plan

  variables {
    domains = {
      "publisher.io" = {
        google_workspace = true
        dmarc_rua        = "dmarc@acme.com"
      }
      "acme.com" = {}
    }
  }

  assert {
    condition     = length(output.dmarc_external_authorizations_required) == 0
    error_message = "When the receiving zone is managed here, the record is created rather than reported."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.domain == "acme.com" && r.name == "publisher.io._report._dmarc" && r.value == "v=DMARC1"
    ])
    error_message = "The authorization record belongs to the zone that owns the mailbox, not to the publisher."
  }

  assert {
    condition = length([
      for r in values(output.dns_records) :
      r if r.domain == "publisher.io" && strcontains(r.name, "_report._dmarc")
    ]) == 0
    error_message = "Publishing the authorization on the sending zone authorizes nobody."
  }
}

run "longest_managed_suffix_wins_and_keeps_labels" {
  command = plan

  variables {
    domains = {
      "delegated.io" = {
        google_workspace = true
        dmarc_rua        = "dmarc@reports.acme.com"
      }
      "labels.io" = {
        google_workspace = true
        dmarc_rua        = "dmarc@a.reports.acme.com"
      }
      "acme.com" = {
        records = [
          { type = "NS", name = "reports", value = "ns1.cloudflare.com" },
        ]
      }
      "reports.acme.com" = {}
    }
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.domain == "reports.acme.com" && r.name == "delegated.io._report._dmarc"
    ])
    error_message = "A delegated child zone is authoritative over its parent, so the record belongs to the child."
  }

  assert {
    condition = anytrue([
      for r in values(output.dns_records) :
      r.domain == "reports.acme.com" && r.name == "labels.io._report._dmarc.a"
    ])
    error_message = "Labels between the mailbox and the managed zone must be preserved in the record name."
  }

  assert {
    condition     = length(output.dmarc_report_delegation_warnings) == 0
    error_message = "acme.com delegates reports via NS, so no delegation warning is expected."
  }
}

run "child_zone_without_ns_delegation_warns" {
  command = plan

  variables {
    domains = {
      "orphan.io" = {
        google_workspace = true
        dmarc_rua        = "dmarc@nodeleg.acme.com"
      }
      # No NS record for "nodeleg": the parent stays authoritative and the
      # record in the child zone would never be served.
      "acme.com"         = {}
      "nodeleg.acme.com" = {}
    }
  }

  assert {
    condition     = keys(output.dmarc_report_delegation_warnings) == ["orphan.io"]
    error_message = "A managed child zone with no NS delegation from its managed parent must be reported."
  }
}
