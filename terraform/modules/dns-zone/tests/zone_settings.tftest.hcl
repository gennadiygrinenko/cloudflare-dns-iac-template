# Zone settings, plan-based defaults, and the rulesets gated on plan. These
# are the parts where a mistake is invisible in a diff: a default that never
# reaches the resource still plans and applies cleanly, it just applies the
# wrong value, and a paid-plan resource planned on a free zone only fails at
# the API.
#
# Plan-only: no Cloudflare credentials, no API calls.

variables {
  account_id = "0123456789abcdef0123456789abcdef"
}

run "plan_defaults_fill_settings_the_user_left_unset" {
  command = plan

  variables {
    domains = {
      "free.com"       = { plan = "free" }
      "pro.com"        = { plan = "pro" }
      "business.com"   = { plan = "business" }
      "enterprise.com" = { plan = "enterprise" }
    }
  }

  # README and docs/DESIGN_DECISIONS.md both state that plan = "pro" turns on
  # Polish, Mirage and the managed WAF with no further configuration.
  assert {
    condition = alltrue([
      for domain in ["pro.com", "business.com", "enterprise.com"] :
      tostring(cloudflare_zone_setting.polish[domain].value) == "lossless"
    ])
    error_message = "Pro and above default to polish = lossless."
  }

  assert {
    condition = alltrue([
      for domain in ["pro.com", "business.com", "enterprise.com"] :
      tostring(cloudflare_zone_setting.mirage[domain].value) == "on"
    ])
    error_message = "Pro and above default to mirage on."
  }

  assert {
    condition     = length(cloudflare_ruleset.waf_managed) == 3
    error_message = "Pro and above activate the managed WAF ruleset by default; free does not."
  }

  # A default that can break a site stays opt-in, on every plan.
  assert {
    condition = alltrue([
      for domain in ["pro.com", "business.com", "enterprise.com"] :
      tostring(cloudflare_zone_setting.rocket_loader[domain].value) == "off"
    ])
    error_message = "rocket_loader is off by default even on plans that support it."
  }
}

run "explicit_settings_are_never_second_guessed" {
  command = plan

  variables {
    domains = {
      "pro.com" = {
        plan = "pro"
        settings = {
          polish        = "off"
          mirage        = false
          rocket_loader = true
        }
        waf_managed_enabled = false
      }
    }
  }

  # The reason the module uses coalesce rather than branching on the plan.
  assert {
    condition     = tostring(cloudflare_zone_setting.polish["pro.com"].value) == "off"
    error_message = "polish = off on a Pro zone must survive the plan default."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.mirage["pro.com"].value) == "off"
    error_message = "mirage = false on a Pro zone must survive the plan default."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.rocket_loader["pro.com"].value) == "on"
    error_message = "rocket_loader = true must be honoured where the plan supports it."
  }

  assert {
    condition     = length(cloudflare_ruleset.waf_managed) == 0
    error_message = "waf_managed_enabled = false is the documented way to opt out on Pro+."
  }
}

run "paid_settings_are_not_planned_on_a_free_zone" {
  command = plan

  variables {
    domains = {
      "free.com" = {
        plan = "free"
        # Asking for paid features on a free zone: the module must not plan
        # them, or the apply fails at the API rather than in review.
        settings = {
          polish        = "lossless"
          mirage        = true
          rocket_loader = true
        }
        waf_managed_enabled = true
        firewall_rules      = [{ expression = "true", action = "block" }]
      }
    }
  }

  assert {
    condition     = length(cloudflare_zone_setting.polish) == 0
    error_message = "polish is a Pro+ setting and must not be planned for a free zone."
  }

  assert {
    condition     = length(cloudflare_zone_setting.mirage) == 0
    error_message = "mirage is a Pro+ setting and must not be planned for a free zone."
  }

  assert {
    condition     = length(cloudflare_zone_setting.rocket_loader) == 0
    error_message = "rocket_loader is a Pro+ setting and must not be planned for a free zone."
  }

  assert {
    condition     = length(cloudflare_ruleset.waf_managed) == 0
    error_message = "The managed WAF ruleset is Pro+ only, whatever waf_managed_enabled says."
  }

  assert {
    condition     = length(cloudflare_ruleset.firewall_custom) == 0
    error_message = "Custom firewall rules are Pro+ only, even when rules are configured."
  }
}

run "settings_available_on_every_plan_carry_their_documented_defaults" {
  command = plan

  variables {
    domains = {
      "shop.com" = {}
    }
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.ssl["shop.com"].value) == "strict"
    error_message = "ssl defaults to strict."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.min_tls_version["shop.com"].value) == "1.2"
    error_message = "min_tls_version defaults to 1.2."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.cache_level["shop.com"].value) == "aggressive"
    error_message = "cache_level defaults to aggressive."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.security_level["shop.com"].value) == "medium"
    error_message = "security_level defaults to medium."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.max_upload["shop.com"].value) == "100"
    error_message = "max_upload defaults to the 100 MB allowed on the free plan."
  }

  # Cloudflare takes on/off strings, the module takes booleans. The mapping is
  # per resource, so a copy-paste error inverts exactly one setting.
  assert {
    condition = alltrue([
      tostring(cloudflare_zone_setting.always_use_https["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.automatic_https_rewrites["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.ipv6["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.brotli["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.early_hints["shop.com"].value) == "on",
    ])
    error_message = "The booleans that default to true must map to \"on\"."
  }

  assert {
    condition     = tostring(cloudflare_zone_setting.always_online["shop.com"].value) == "off"
    error_message = "always_online defaults to false and must map to \"off\"."
  }
}

# Eleven near-identical resource blocks, one per setting, are written by copy
# and paste, so a block reading its neighbour's field is the likely mistake —
# and invisible whenever both settings happen to hold the same value. Two
# on/off values cannot separate six booleans in one plan, so the three runs
# below give each boolean a signature no other one shares:
#
#                            run A   run B   run C
#   always_use_https           off     off     off
#   automatic_https_rewrites   off     off     on
#   ipv6                       off     on      off
#   brotli                     off     on      on
#   early_hints                on      off     off
#   always_online              on      off     on
#
# The all-default case above covers the remaining combination, every one on
# except always_online.
run "overrides_reach_the_resources" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        settings = {
          ssl                      = "full"
          min_tls_version          = "1.3"
          cache_level              = "basic"
          security_level           = "under_attack"
          max_upload               = 200
          always_use_https         = false
          automatic_https_rewrites = false
          ipv6                     = false
          brotli                   = false
          early_hints              = true
          always_online            = true
        }
      }
    }
  }

  assert {
    condition = alltrue([
      tostring(cloudflare_zone_setting.ssl["shop.com"].value) == "full",
      tostring(cloudflare_zone_setting.min_tls_version["shop.com"].value) == "1.3",
      tostring(cloudflare_zone_setting.cache_level["shop.com"].value) == "basic",
      tostring(cloudflare_zone_setting.security_level["shop.com"].value) == "under_attack",
      tostring(cloudflare_zone_setting.max_upload["shop.com"].value) == "200",
    ])
    error_message = "String and number settings must pass through unchanged."
  }

  # false must not be read as "unset", which is what a coalesce over a bool
  # does: the value silently stays at the default.
  assert {
    condition = alltrue([
      tostring(cloudflare_zone_setting.always_use_https["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.automatic_https_rewrites["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.ipv6["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.brotli["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.early_hints["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.always_online["shop.com"].value) == "on",
    ])
    error_message = "Run A: every boolean setting must carry its own configured value."
  }
}

run "boolean_settings_stay_separated_second_pattern" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        settings = {
          always_use_https         = false
          automatic_https_rewrites = false
          ipv6                     = true
          brotli                   = true
          early_hints              = false
          always_online            = false
        }
      }
    }
  }

  assert {
    condition = alltrue([
      tostring(cloudflare_zone_setting.always_use_https["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.automatic_https_rewrites["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.ipv6["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.brotli["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.early_hints["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.always_online["shop.com"].value) == "off",
    ])
    error_message = "Run B: every boolean setting must carry its own configured value."
  }
}

run "boolean_settings_stay_separated_third_pattern" {
  command = plan

  variables {
    domains = {
      "shop.com" = {
        settings = {
          always_use_https         = false
          automatic_https_rewrites = true
          ipv6                     = false
          brotli                   = true
          early_hints              = false
          always_online            = true
        }
      }
    }
  }

  assert {
    condition = alltrue([
      tostring(cloudflare_zone_setting.always_use_https["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.automatic_https_rewrites["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.ipv6["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.brotli["shop.com"].value) == "on",
      tostring(cloudflare_zone_setting.early_hints["shop.com"].value) == "off",
      tostring(cloudflare_zone_setting.always_online["shop.com"].value) == "on",
    ])
    error_message = "Run C: every boolean setting must carry its own configured value."
  }
}

run "one_zone_per_domain_named_after_its_key" {
  command = plan

  variables {
    domains = {
      "shop.com"     = { plan = "pro" }
      "api.shop.com" = {}
    }
  }

  assert {
    condition     = length(cloudflare_zone.this) == 2
    error_message = "Each entry in domains is one zone."
  }

  assert {
    condition = alltrue([
      for domain, zone in cloudflare_zone.this : zone.name == domain
    ])
    error_message = "The map key is the zone name; a mismatch creates a zone nobody asked for."
  }

  assert {
    condition = alltrue([
      for zone in values(cloudflare_zone.this) :
      zone.type == "full" && zone.account.id == var.account_id
    ])
    error_message = "Zones are full-setup zones in the configured account."
  }

  # Every zone setting is created for_each over the same map, so a settings
  # resource that misses a zone leaves that zone on Cloudflare's own defaults.
  assert {
    condition     = length(cloudflare_zone_setting.ssl) == length(cloudflare_zone.this)
    error_message = "Zone settings cover every managed zone."
  }
}

run "the_redirect_ruleset_appears_only_where_redirect_to_is_set" {
  command = plan

  variables {
    domains = {
      "old.com" = { redirect_to = "https://new.com" }
      "new.com" = {}
    }
  }

  assert {
    condition     = length(cloudflare_ruleset.redirect) == 1
    error_message = "Only the zone with redirect_to gets a redirect ruleset."
  }

  assert {
    condition     = cloudflare_ruleset.redirect["old.com"].phase == "http_request_dynamic_redirect"
    error_message = "The redirect belongs in the dynamic redirect phase."
  }

  assert {
    condition     = cloudflare_ruleset.redirect["old.com"].rules[0].action_parameters.from_value.status_code == 301
    error_message = "A domain move is a 301, not a temporary redirect."
  }

  assert {
    condition = (
      cloudflare_ruleset.redirect["old.com"].rules[0].action_parameters.from_value.target_url.value == "https://new.com" &&
      cloudflare_ruleset.redirect["old.com"].rules[0].action_parameters.from_value.preserve_query_string == true
    )
    error_message = "The redirect points at redirect_to and keeps the query string."
  }
}

run "custom_firewall_rules_reach_the_ruleset_as_written" {
  command = plan

  variables {
    domains = {
      "pro.com" = {
        plan = "pro"
        firewall_rules = [
          { expression = "ip.src eq 203.0.113.10", description = "block a scanner", action = "block" },
          { expression = "http.request.uri.path contains \"/admin\"", action = "managed_challenge", enabled = false },
        ]
      }
    }
  }

  assert {
    condition     = length(cloudflare_ruleset.firewall_custom["pro.com"].rules) == 2
    error_message = "Every configured rule is planned, in order."
  }

  assert {
    condition = (
      cloudflare_ruleset.firewall_custom["pro.com"].rules[0].expression == "ip.src eq 203.0.113.10" &&
      cloudflare_ruleset.firewall_custom["pro.com"].rules[0].action == "block" &&
      cloudflare_ruleset.firewall_custom["pro.com"].rules[0].description == "block a scanner" &&
      cloudflare_ruleset.firewall_custom["pro.com"].rules[0].enabled == true
    )
    error_message = "A rule's expression, action and description pass through, and enabled defaults to true."
  }

  assert {
    condition = (
      cloudflare_ruleset.firewall_custom["pro.com"].rules[1].action == "managed_challenge" &&
      cloudflare_ruleset.firewall_custom["pro.com"].rules[1].enabled == false
    )
    error_message = "enabled = false must reach the rule rather than being read as unset."
  }

  assert {
    condition     = cloudflare_ruleset.firewall_custom["pro.com"].phase == "http_request_firewall_custom"
    error_message = "Custom rules belong in the custom firewall phase, not the managed one."
  }
}
