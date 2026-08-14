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
    { name = "@", value = "smtp.google.com", priority = 1 },
  ]

  gws_cname_records = [
    { name = "mail", value = "ghs.googlehosted.com" },
    { name = "calendar", value = "ghs.googlehosted.com" },
  ]

  # Flattened record objects (no keys). Keyed once below so a collision
  # cannot silently drop a record in one of several map constructors.
  all_records_list = flatten([
    for domain, cfg in var.domains : concat(
      [for r in cfg.records : merge(r, { domain = domain })],
      cfg.apex_ip != null ? [
        {
          domain   = domain
          type     = "A"
          name     = "@"
          value    = cfg.apex_ip
          ttl      = 1
          proxied  = true
          priority = null
          comment  = "Apex (auto)"
        },
        {
          domain   = domain
          type     = "A"
          name     = "www"
          value    = cfg.apex_ip
          ttl      = 1
          proxied  = true
          priority = null
          comment  = "www (auto)"
        },
      ] : [],
      cfg.google_site_verification != null ? [
        {
          domain   = domain
          type     = "TXT"
          name     = "@"
          value    = "google-site-verification=${cfg.google_site_verification}"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "Google Search Console (auto)"
        },
      ] : [],
      cfg.google_dkim_key != null ? [
        {
          domain   = domain
          type     = "TXT"
          name     = "google._domainkey"
          value    = "v=DKIM1; k=rsa; p=${cfg.google_dkim_key}"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "Google DKIM (auto)"
        },
      ] : [],
      cfg.google_workspace ? [
        for mx in local.gws_mx_records : {
          domain   = domain
          type     = "MX"
          name     = mx.name
          value    = mx.value
          ttl      = 1
          proxied  = false
          priority = mx.priority
          comment  = "Google Workspace MX (auto)"
        }
      ] : [],
      cfg.google_workspace ? [
        for cn in local.gws_cname_records : {
          domain   = domain
          type     = "CNAME"
          name     = cn.name
          value    = cn.value
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "Google Workspace CNAME (auto)"
        }
      ] : [],
      cfg.google_workspace ? [
        {
          domain   = domain
          type     = "TXT"
          name     = "@"
          value    = "v=spf1 include:_spf.google.com ${join(" ", [for inc in cfg.spf_includes : "include:${inc}"])} ~all"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "SPF (auto)"
        },
      ] : [],
      cfg.google_workspace ? [
        {
          domain   = domain
          type     = "TXT"
          name     = "_dmarc"
          value    = "v=DMARC1; p=${cfg.dmarc_policy}; rua=mailto:dmarc@${domain}"
          ttl      = 1
          proxied  = false
          priority = null
          comment  = "DMARC (auto)"
        },
      ] : [],
    )
  ])

  # Prefix stays readable; payload is hashed so replace(".", "_") cannot
  # collide (e.g. 1.2.3.4 vs 1_2_3_4). Changing value or priority replaces
  # the record — ignore_changes on TXT content does not block that.
  all_records = {
    for r in local.all_records_list :
    "${r.domain}__${lower(r.type)}__${r.name}__${substr(sha256("${r.value}:${coalesce(r.priority, 0)}"), 0, 12)}" => r
  }

  # Cloudflare reformats long TXT (DKIM) into 255-char chunks — format drift
  # is inevitable only there. Other types must apply content updates in place.
  records_txt     = { for k, v in local.all_records : k => v if v.type == "TXT" }
  records_regular = { for k, v in local.all_records : k => v if v.type != "TXT" }
}

# -------------------------------------------------------------------
# Zones
# -------------------------------------------------------------------
resource "cloudflare_zone" "this" {
  for_each = var.domains

  account = { id = var.account_id }
  name    = each.key
  type    = "full"
  # plan is read-only in provider v5 — set it in the Cloudflare dashboard.
  # The plan variable is still used here to enable/disable Pro+ resources.

  lifecycle {
    prevent_destroy = true
  }
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
  for_each = local.records_regular

  zone_id  = cloudflare_zone.this[each.value.domain].id
  type     = each.value.type
  name     = each.value.name
  content  = each.value.value
  ttl      = each.value.proxied ? 1 : coalesce(each.value.ttl, 1)
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment
}

resource "cloudflare_dns_record" "txt" {
  for_each = local.records_txt

  zone_id  = cloudflare_zone.this[each.value.domain].id
  type     = each.value.type
  name     = each.value.name
  content  = each.value.value
  ttl      = coalesce(each.value.ttl, 1)
  proxied  = false
  priority = null
  comment  = each.value.comment

  lifecycle {
    ignore_changes = [content]
  }
}

# -------------------------------------------------------------------
# 301 Redirect ruleset (optional, when redirect_to is set)
# -------------------------------------------------------------------
resource "cloudflare_ruleset" "redirect" {
  for_each = { for domain, cfg in var.domains : domain => cfg if cfg.redirect_to != null }

  zone_id     = cloudflare_zone.this[each.key].id
  name        = "Redirect ${each.key} to ${each.value.redirect_to}"
  description = "Managed by Terraform. Redirects all traffic to ${each.value.redirect_to}."
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    {
      action      = "redirect"
      description = "301 redirect to ${each.value.redirect_to}"
      enabled     = true
      expression  = "true"
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true
          target_url            = { value = each.value.redirect_to }
        }
      }
    }
  ]
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

  rules = [
    {
      action      = "execute"
      description = "Cloudflare Managed Ruleset"
      enabled     = true
      expression  = "true"
      action_parameters = {
        id = "efb7b8c949ac4650a09736fc376e9aee" # Cloudflare Managed Ruleset ID (global constant)
      }
    }
  ]
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

  rules = [
    for r in each.value.firewall_rules : {
      action      = r.action
      description = r.description
      enabled     = r.enabled
      expression  = r.expression
    }
  ]
}
