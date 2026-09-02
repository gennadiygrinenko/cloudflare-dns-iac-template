# What only an apply can show: the references between resources, and the
# outputs built from IDs. At plan time every zone_id is "known after apply",
# so a record attached to the wrong zone, or an output that drops half its
# keys, plans cleanly. The Cloudflare provider is mocked — no account, no API —
# and each zone gets a fixed ID, so this proves the module's own wiring and
# nothing about what Cloudflare accepts. That gap is stated in docs/DESIGN_DECISIONS.md.

mock_provider "cloudflare" {}

variables {
  account_id = "0123456789abcdef0123456789abcdef"
}

run "records_attach_to_the_zone_named_in_their_key" {
  command = apply

  # cloudflare_ruleset validates zone_id as 32 hex characters, which the
  # mock's generated IDs are not. Fixed, distinct IDs per zone keep the
  # wiring checks meaningful.
  override_resource {
    target = cloudflare_zone.this["shop.com"]
    values = { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  override_resource {
    target = cloudflare_zone.this["blog.net"]
    values = { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }

  variables {
    domains = {
      "shop.com" = {
        apex_ip          = "203.0.113.10"
        google_workspace = true
        records          = [{ type = "CNAME", name = "docs", value = "hosting.example.com" }]
      }
      "blog.net" = {
        apex_ip          = "203.0.113.20"
        google_workspace = true
        google_dkim_key  = "MIIBIjANBgkq"
      }
    }
  }

  # Without this the two assertions below could pass with every record on one
  # zone: the check only means something when the zones have different IDs.
  assert {
    condition     = length(distinct(values(output.zone_ids))) == 2
    error_message = "Two zones must have two distinct IDs, or the wiring checks prove nothing."
  }

  assert {
    condition = alltrue([
      for key, r in cloudflare_dns_record.this :
      r.zone_id == cloudflare_zone.this[split("__", key)[0]].id
    ])
    error_message = "Every regular record must carry the ID of the zone its key names."
  }

  assert {
    condition = alltrue([
      for key, r in cloudflare_dns_record.txt :
      r.zone_id == cloudflare_zone.this[split("__", key)[0]].id
    ])
    error_message = "Every TXT record must carry the ID of the zone its key names."
  }
}

run "zone_settings_and_rulesets_attach_to_their_own_zone" {
  command = apply

  # cloudflare_ruleset validates zone_id as 32 hex characters, which the
  # mock's generated IDs are not. Fixed, distinct IDs per zone keep the
  # wiring checks meaningful.
  override_resource {
    target = cloudflare_zone.this["shop.com"]
    values = { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  override_resource {
    target = cloudflare_zone.this["blog.net"]
    values = { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }

  variables {
    domains = {
      "shop.com" = {
        plan           = "pro"
        redirect_to    = "https://new-shop.com"
        firewall_rules = [{ expression = "ip.src eq 203.0.113.99" }]
      }
      "blog.net" = {}
    }
  }

  assert {
    condition     = length(distinct(values(output.zone_ids))) == 2
    error_message = "Two zones must have two distinct IDs, or the wiring checks prove nothing."
  }

  # Fourteen settings resources, each for_each over var.domains: the key is
  # the domain, so the zone_id must be that domain's zone.
  assert {
    condition = alltrue(concat(
      [for d, s in cloudflare_zone_setting.ssl : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.always_use_https : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.min_tls_version : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.automatic_https_rewrites : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.ipv6 : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.brotli : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.early_hints : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.always_online : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.cache_level : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.security_level : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.max_upload : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.polish : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.mirage : s.zone_id == cloudflare_zone.this[d].id],
      [for d, s in cloudflare_zone_setting.rocket_loader : s.zone_id == cloudflare_zone.this[d].id],
    ))
    error_message = "Every zone setting must carry the ID of the zone it is keyed by."
  }

  assert {
    condition = alltrue(concat(
      [for d, r in cloudflare_ruleset.redirect : r.zone_id == cloudflare_zone.this[d].id],
      [for d, r in cloudflare_ruleset.waf_managed : r.zone_id == cloudflare_zone.this[d].id],
      [for d, r in cloudflare_ruleset.firewall_custom : r.zone_id == cloudflare_zone.this[d].id],
    ))
    error_message = "Every ruleset must carry the ID of the zone it is keyed by."
  }

  assert {
    condition = (
      length(cloudflare_ruleset.redirect) == 1 &&
      length(cloudflare_ruleset.waf_managed) == 1 &&
      length(cloudflare_ruleset.firewall_custom) == 1
    )
    error_message = "The Pro zone gets all three rulesets and the free zone none, so the check above covers each once."
  }
}

run "dmarc_authorization_lands_in_the_receiving_zone" {
  command = apply

  # cloudflare_ruleset validates zone_id as 32 hex characters, which the
  # mock's generated IDs are not. Fixed, distinct IDs per zone keep the
  # wiring checks meaningful.
  override_resource {
    target = cloudflare_zone.this["shop.com"]
    values = { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  override_resource {
    target = cloudflare_zone.this["blog.net"]
    values = { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }

  # Runs in one file share state, and cloudflare_zone has prevent_destroy: a
  # run that swapped a zone for another would have to destroy one and fail.
  # Every run therefore uses the same two zones.
  variables {
    domains = {
      "shop.com" = {
        google_workspace = true
        dmarc_rua        = "dmarc@blog.net"
      }
      "blog.net" = {}
    }
  }

  # The one record the module places in a zone other than its own domain's.
  # Its key starts with the receiving zone, so the generic check above would
  # pass even if the logic chose the wrong zone; this pins the zone by name.
  assert {
    condition = alltrue([
      for key, r in cloudflare_dns_record.txt :
      r.zone_id == cloudflare_zone.this["blog.net"].id
      if r.name == "shop.com._report._dmarc"
    ])
    error_message = "The report authorization record must be created in blog.net's zone, not shop.com's."
  }

  assert {
    condition     = length([for r in values(cloudflare_dns_record.txt) : r if r.name == "shop.com._report._dmarc"]) == 1
    error_message = "Exactly one authorization record is created for the external mailbox."
  }
}

run "outputs_are_complete_after_apply" {
  command = apply

  # cloudflare_ruleset validates zone_id as 32 hex characters, which the
  # mock's generated IDs are not. Fixed, distinct IDs per zone keep the
  # wiring checks meaningful.
  override_resource {
    target = cloudflare_zone.this["shop.com"]
    values = { id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  override_resource {
    target = cloudflare_zone.this["blog.net"]
    values = { id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }

  variables {
    domains = {
      "shop.com" = {
        apex_ip          = "203.0.113.10"
        google_workspace = true
        google_dkim_key  = "MIIBIjANBgkq"
      }
      "blog.net" = {
        records = [{ type = "TXT", name = "@", value = "hello" }]
      }
    }
  }

  assert {
    condition     = toset(keys(output.zone_ids)) == toset(["blog.net", "shop.com"])
    error_message = "zone_ids has one entry per domain."
  }

  assert {
    condition     = toset(keys(output.zone_name_servers)) == toset(["blog.net", "shop.com"])
    error_message = "zone_name_servers has one entry per domain."
  }

  # dns_record_ids merges the two record resources; a merge that missed one
  # would leave `state mv` planning against half the records.
  assert {
    condition     = toset(keys(output.dns_record_ids)) == toset(keys(output.dns_records))
    error_message = "dns_record_ids must cover exactly the keys dns_records resolved, TXT included."
  }

  assert {
    condition     = alltrue([for id in values(output.dns_record_ids) : id != null && id != ""])
    error_message = "Every record has an ID after apply."
  }
}
