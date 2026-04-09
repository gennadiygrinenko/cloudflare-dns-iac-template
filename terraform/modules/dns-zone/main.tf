# -------------------------------------------------------------------
# Google Workspace standard records injected when google_workspace = true
# -------------------------------------------------------------------
locals {
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
