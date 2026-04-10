# -------------------------------------------------------------------
# Google Workspace standard records injected when google_workspace = true
# -------------------------------------------------------------------
locals {
  # ------------------------------------------------------------------
  # Plan-based defaults: merged with user-provided settings.
  # User values always win; plan defaults fill in the rest.
  # ------------------------------------------------------------------
  plan_defaults = {
    free = {
      polish        = "off"
      mirage        = false
      rocket_loader = false
      waf_managed   = false
    }
    pro = {
      polish        = "lossless"
      mirage        = true
      rocket_loader = false # can break some JS — opt-in explicitly
      waf_managed   = true
    }
    business = {
      polish        = "lossless"
      mirage        = true
      rocket_loader = false
      waf_managed   = true
    }
    enterprise = {
      polish        = "lossless"
      mirage        = true
      rocket_loader = false
      waf_managed   = true
    }
  }

  # Resolved settings per domain: plan defaults ← overridden by user settings
  resolved = {
    for domain, cfg in var.domains : domain => {
      polish        = coalesce(cfg.settings.polish, local.plan_defaults[cfg.plan].polish)
      mirage        = coalesce(cfg.settings.mirage, local.plan_defaults[cfg.plan].mirage)
      rocket_loader = coalesce(cfg.settings.rocket_loader, local.plan_defaults[cfg.plan].rocket_loader)
      waf_managed   = coalesce(cfg.waf_managed_enabled, local.plan_defaults[cfg.plan].waf_managed)
    }
  }

  gws_mx_records = [
    { name = "@", value = "aspmx.l.google.com", priority = 1 },
    { name = "@", value = "alt1.aspmx.l.google.com", priority = 5 },
    { name = "@", value = "alt2.aspmx.l.google.com", priority = 5 },
    { name = "@", value = "alt3.aspmx.l.google.com", priority = 10 },
    { name = "@", value = "alt4.aspmx.l.google.com", priority = 10 },
  ]

  gws_cname_records = [
    { name = "mail", value = "ghs.googlehosted.com" },
    { name = "calendar", value = "ghs.googlehosted.com" },
  ]

  # Build all records per domain (user-defined + GWS auto-records)
  all_records = merge(flatten([
    for domain, cfg in var.domains : [
      # User-defined records
      {
        for r in cfg.records :
        "${domain}__${lower(r.type)}__${replace(r.name, ".", "_")}__${replace(r.value, ".", "_")}__${coalesce(r.priority, 0)}" => merge(r, { domain = domain })
      },

      # GWS: MX records
      cfg.google_workspace ? {
        for mx in local.gws_mx_records :
        "${domain}__mx__${replace(mx.name, ".", "_")}__${replace(mx.value, ".", "_")}__${mx.priority}" => {
          domain   = domain
          type     = "MX"
          name     = mx.name
          value    = mx.value
          ttl      = 1
          proxied  = false
          priority = mx.priority
          comment  = "Google Workspace MX (auto)"
        }
      } : {},

      # GWS: CNAME records
      cfg.google_workspace ? {
        for cn in local.gws_cname_records :
        "${domain}__cname__${cn.name}__${replace(cn.value, ".", "_")}__0" => {
          domain   = domain
          type     = "CNAME"
          name     = cn.name
          value    = cn.value
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "Google Workspace CNAME (auto)"
        }
      } : {},

      # GWS: SPF TXT
      cfg.google_workspace ? {
        "${domain}__txt__@__spf__0" = {
          domain   = domain
          type     = "TXT"
          name     = "@"
          value    = "v=spf1 include:_spf.google.com ${join(" ", [for inc in cfg.spf_includes : "include:${inc}"])} ~all"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "SPF (auto)"
        }
      } : {},

      # GWS: DMARC TXT
      cfg.google_workspace ? {
        "${domain}__txt___dmarc__dmarc__0" = {
          domain   = domain
          type     = "TXT"
          name     = "_dmarc"
          value    = "v=DMARC1; p=none; rua=mailto:dmarc@${domain}"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "DMARC (auto)"
        }
      } : {},
    ]
  ])...)
}

# -------------------------------------------------------------------
# Zones
# -------------------------------------------------------------------
resource "cloudflare_zone" "this" {
  for_each = var.domains

  account = { id = var.account_id }
  name    = each.key
  type    = "full"
  plan    = each.value.plan
}

# -------------------------------------------------------------------
# Zone settings (Cloudflare provider v5: individual resources per setting)
# -------------------------------------------------------------------
resource "cloudflare_zone_setting" "ssl" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "ssl"
  value      = coalesce(each.value.settings.ssl, "strict")
}

resource "cloudflare_zone_setting" "always_use_https" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "always_use_https"
  value      = coalesce(each.value.settings.always_use_https, true) ? "on" : "off"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "min_tls_version"
  value      = coalesce(each.value.settings.min_tls_version, "1.2")
}

resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "automatic_https_rewrites"
  value      = coalesce(each.value.settings.automatic_https_rewrites, true) ? "on" : "off"
}

resource "cloudflare_zone_setting" "ipv6" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "ipv6"
  value      = coalesce(each.value.settings.ipv6, true) ? "on" : "off"
}

resource "cloudflare_zone_setting" "brotli" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "brotli"
  value      = coalesce(each.value.settings.brotli, true) ? "on" : "off"
}

resource "cloudflare_zone_setting" "early_hints" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "early_hints"
  value      = coalesce(each.value.settings.early_hints, true) ? "on" : "off"
}

resource "cloudflare_zone_setting" "always_online" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "always_online"
  value      = coalesce(each.value.settings.always_online, false) ? "on" : "off"
}

resource "cloudflare_zone_setting" "cache_level" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "cache_level"
  value      = coalesce(each.value.settings.cache_level, "aggressive")
}

resource "cloudflare_zone_setting" "security_level" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "security_level"
  value      = coalesce(each.value.settings.security_level, "medium")
}

resource "cloudflare_zone_setting" "max_upload" {
  for_each = var.domains

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "max_upload"
  value      = coalesce(each.value.settings.max_upload, 100)
}

# -------------------------------------------------------------------
# Pro+ zone settings (polish, mirage, rocket_loader)
# Only created for zones with plan = pro | business | enterprise
# -------------------------------------------------------------------
resource "cloudflare_zone_setting" "polish" {
  for_each = { for domain, cfg in var.domains : domain => cfg if contains(["pro", "business", "enterprise"], cfg.plan) }

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "polish"
  value      = local.resolved[each.key].polish
}

resource "cloudflare_zone_setting" "mirage" {
  for_each = { for domain, cfg in var.domains : domain => cfg if contains(["pro", "business", "enterprise"], cfg.plan) }

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "mirage"
  value      = local.resolved[each.key].mirage ? "on" : "off"
}

resource "cloudflare_zone_setting" "rocket_loader" {
  for_each = { for domain, cfg in var.domains : domain => cfg if contains(["pro", "business", "enterprise"], cfg.plan) }

  zone_id    = cloudflare_zone.this[each.key].id
  setting_id = "rocket_loader"
  value      = local.resolved[each.key].rocket_loader ? "on" : "off"
}

# -------------------------------------------------------------------
# DNS Records
# -------------------------------------------------------------------
resource "cloudflare_dns_record" "this" {
  for_each = local.all_records

  zone_id  = cloudflare_zone.this[each.value.domain].id
  type     = each.value.type
  name     = each.value.name
  content  = each.value.value
  ttl      = each.value.proxied ? 1 : coalesce(each.value.ttl, 1)
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment

  lifecycle {
    # Avoid perpetual drift on TXT records that Cloudflare auto-formats
    ignore_changes = [content]
  }
}

# -------------------------------------------------------------------
# 301 Redirect ruleset (optional, when redirect_to is set)
# -------------------------------------------------------------------
resource "cloudflare_ruleset" "redirect" {
  for_each = { for domain, cfg in var.domains : domain => cfg if cfg.redirect_to != null }

  zone_id     = cloudflare_zone.this[each.key].id
  name        = "Redirect ${each.key} → ${each.value.redirect_to}"
  description = "Managed by Terraform. Redirects all traffic to ${each.value.redirect_to}."
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules {
    action      = "redirect"
    description = "301 redirect to ${each.value.redirect_to}"
    enabled     = true
    expression  = "true"

    action_parameters {
      from_value {
        status_code = 301
        target_url {
          value = each.value.redirect_to
        }
        preserve_query_string = true
      }
    }
  }
}

# -------------------------------------------------------------------
# WAF: Cloudflare Managed Ruleset (Pro+ only)
# Activates the Cloudflare-managed WAF on the zone.
# -------------------------------------------------------------------
resource "cloudflare_ruleset" "waf_managed" {
  for_each = {
    for domain, cfg in var.domains : domain => cfg
    if local.resolved[domain].waf_managed && contains(["pro", "business", "enterprise"], cfg.plan)
  }

  zone_id     = cloudflare_zone.this[each.key].id
  name        = "default"
  description = "Managed by Terraform. Cloudflare Managed WAF ruleset."
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action      = "execute"
    description = "Cloudflare Managed Ruleset"
    enabled     = true
    expression  = "true"

    action_parameters {
      id = "efb7b8c949ac4650a09736fc376e9aee" # Cloudflare Managed Ruleset ID (global constant)
    }
  }
}

# -------------------------------------------------------------------
# WAF: Custom firewall rules (Pro+ only)
# -------------------------------------------------------------------
resource "cloudflare_ruleset" "firewall_custom" {
  for_each = {
    for domain, cfg in var.domains : domain => cfg
    if length(cfg.firewall_rules) > 0 && contains(["pro", "business", "enterprise"], cfg.plan)
  }

  zone_id     = cloudflare_zone.this[each.key].id
  name        = "default"
  description = "Managed by Terraform. Custom firewall rules."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  dynamic "rules" {
    for_each = each.value.firewall_rules
    content {
      action      = rules.value.action
      description = rules.value.description
      enabled     = rules.value.enabled
      expression  = rules.value.expression
    }
  }
}
