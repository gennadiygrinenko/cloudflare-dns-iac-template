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
      ssl                       = optional(string, "strict")
      min_tls_version           = optional(string, "1.2")
      always_use_https          = optional(bool, true)
      automatic_https_rewrites  = optional(bool, true)
      ipv6                      = optional(bool, true)
      brotli                    = optional(bool, true)
      early_hints               = optional(bool, true)
    }), {})

    # Convenience: auto-add Google Workspace MX + SPF + DMARC
    google_workspace = optional(bool, false)

    # Extra SPF includes (appended when google_workspace = true)
    spf_includes = optional(list(string), [])

    # 301 redirect entire zone to another domain
    redirect_to = optional(string, null)
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
}
