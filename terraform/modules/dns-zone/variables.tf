variable "account_id" {
  description = "Cloudflare account ID (32-character hex string)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id must be a 32-character lowercase hex string."
  }
}

variable "domains" {
  description = "Map of domain name → domain configuration."
  type = map(object({
    plan = optional(string, "free")

    # DNS records
    records = optional(list(object({
      type     = string
      name     = string
      value    = string
      ttl      = optional(number, 1)
      proxied  = optional(bool, false)
      priority = optional(number, null)
      comment  = optional(string, null)
    })), [])

    # Zone-level settings to override defaults
    settings = optional(object({
      # Available on all plans
      ssl                      = optional(string, "strict")
      min_tls_version          = optional(string, "1.2")
      always_use_https         = optional(bool, true)
      automatic_https_rewrites = optional(bool, true)
      always_online            = optional(bool, false)
      ipv6                     = optional(bool, true)
      brotli                   = optional(bool, true)
      early_hints              = optional(bool, true)
      cache_level              = optional(string, "aggressive") # aggressive | basic | simplified
      security_level           = optional(string, "medium")     # off | essentially_off | low | medium | high | under_attack
      max_upload               = optional(number, 100)          # MB; 100 on free, up to 500 on Pro+

      # Pro+ only (ignored on free plan)
      polish        = optional(string, "off") # off | lossless | lossy
      mirage        = optional(bool, false)   # mobile image optimization
      rocket_loader = optional(bool, false)   # async JS loading
    }), {})

    # Shortcut: auto-creates proxied A records for @ and www pointing to the same IP
    apex_ip = optional(string, null)

    # Convenience: auto-add Google Workspace MX + SPF + DMARC
    google_workspace = optional(bool, false)

    # Extra SPF includes (appended when google_workspace = true)
    spf_includes = optional(list(string), [])

    # DMARC policy: none (monitor) → quarantine → reject
    # Recommended: start with "none", move to "reject" once DKIM is set up
    dmarc_policy = optional(string, "none")

    # Google Search Console domain verification token (the part after "google-site-verification=")
    google_site_verification = optional(string, null)

    # Google Workspace DKIM public key (from GWS Admin > Apps > Gmail > Authenticate email)
    # Paste only the key value (p=...), the full record is built automatically
    google_dkim_key = optional(string, null)

    # 301 redirect entire zone to another domain
    redirect_to = optional(string, null)

    # WAF: Cloudflare Managed Ruleset (Pro+ only)
    # When enabled, activates the Cloudflare Managed Ruleset on the zone.
    waf_managed_enabled = optional(bool, false)

    # WAF: custom firewall rules (Pro+ only)
    # Each rule: { expression, description, action, enabled }
    # action: block | challenge | js_challenge | managed_challenge | log | skip
    firewall_rules = optional(list(object({
      expression  = string
      description = optional(string, "")
      action      = optional(string, "block")
      enabled     = optional(bool, true)
    })), [])
  }))

  validation {
    condition = alltrue([
      for name, cfg in var.domains :
      contains(["free", "pro", "business", "enterprise"], cfg.plan)
    ])
    error_message = "plan must be one of: free, pro, business, enterprise."
  }

  validation {
    condition = alltrue(flatten([
      for name, cfg in var.domains : [
        for r in cfg.records :
        contains(["A", "AAAA", "CNAME", "MX", "TXT", "NS", "SRV", "CAA", "PTR"], r.type)
      ]
    ]))
    error_message = "record type must be one of: A, AAAA, CNAME, MX, TXT, NS, SRV, CAA, PTR."
  }

  validation {
    condition = alltrue([
      for name, cfg in var.domains :
      contains(["none", "quarantine", "reject"], cfg.dmarc_policy)
    ])
    error_message = "dmarc_policy must be one of: none, quarantine, reject."
  }
}
