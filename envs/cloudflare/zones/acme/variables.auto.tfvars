# Zone: acme
# Domains managed in this zone. Add/remove domains by editing this file.

domains = {
  "acme-corp.io" = {
    plan                     = "free"
    apex_ip                  = "76.76.21.21"        # auto-creates @ and www A records (proxied)
    google_workspace         = true
    google_site_verification = "REPLACE_WITH_REAL_VALUE"
    google_dkim_key          = "REPLACE_WITH_REAL_KEY" # from GWS Admin > Apps > Gmail > Authenticate email
    spf_includes             = ["sendgrid.net"]
    dmarc_policy             = "reject"

    records = [
      # Staging subdomain — not proxied
      { type = "A", name = "staging", value = "203.0.113.10", proxied = false, ttl = 300 },

      # Email tracking (SendGrid) — unique per account, add manually
      { type = "CNAME", name = "em1234",        value = "u1234.wl.sendgrid.net",              proxied = false },
      { type = "CNAME", name = "s1._domainkey", value = "s1.domainkey.u1234.wl.sendgrid.net", proxied = false },
    ]
  }

  "acme-blog.net" = {
    plan        = "free"
    apex_ip     = "192.0.2.1"    # auto-creates @ and www A records (proxied)
    redirect_to = "https://acme-corp.io"
  }

  # Pro plan example:
  # - polish=lossless, mirage, WAF managed ruleset enabled automatically
  # - custom firewall rule added on top
  # - individual settings can be overridden via the settings block
  "acme-shop.com" = {
    plan             = "pro"
    apex_ip          = "76.76.21.21"
    google_workspace = true
    dmarc_policy     = "quarantine"

    # Optional: override specific Pro defaults
    # settings = {
    #   polish         = "lossy"   # more aggressive image compression
    #   rocket_loader  = true      # enable async JS loading
    #   security_level = "high"
    # }

    # Optional: disable WAF if not needed
    # waf_managed_enabled = false

    # Optional: add custom firewall rules
    firewall_rules = [
      {
        expression  = "(ip.geoip.country eq \"CN\" or ip.geoip.country eq \"RU\")"
        description = "Challenge high-risk countries"
        action      = "managed_challenge"
      },
    ]

    records = [
      { type = "A", name = "api", value = "76.76.21.21", proxied = true },
    ]
  }
}
