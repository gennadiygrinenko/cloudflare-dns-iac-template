# Zone: acme
# Domains managed in this zone. Add/remove domains by editing this file.

domains = {
  "acme-corp.io" = {
    plan             = "free"
    google_workspace = true
    spf_includes     = ["sendgrid.net"]
    dmarc_policy     = "reject" # none → quarantine → reject (tighten after DKIM is set up)

    records = [
      # Main site — proxied through Cloudflare
      { type = "A", name = "@", value = "76.76.21.21", proxied = true },
      { type = "A", name = "www", value = "76.76.21.21", proxied = true },

      # Staging subdomain — not proxied
      { type = "A", name = "staging", value = "203.0.113.10", proxied = false, ttl = 300 },

      # Email tracking (SendGrid)
      { type = "CNAME", name = "em1234", value = "u1234.wl.sendgrid.net", proxied = false },
      { type = "CNAME", name = "s1._domainkey", value = "s1.domainkey.u1234.wl.sendgrid.net", proxied = false },

      # Google site verification
      { type = "TXT", name = "@", value = "google-site-verification=REPLACE_WITH_REAL_VALUE", comment = "Google Search Console" },

      # DKIM (Google Workspace)
      { type = "TXT", name = "google._domainkey", value = "v=DKIM1; k=rsa; p=REPLACE_WITH_REAL_KEY", comment = "Google DKIM" },
    ]
  }

  "acme-blog.net" = {
    plan             = "free"
    google_workspace = false

    # Redirect entire domain to main site
    redirect_to = "https://acme-corp.io"

    records = [
      { type = "A", name = "@", value = "192.0.2.1", proxied = true },
      { type = "A", name = "www", value = "192.0.2.1", proxied = true },
    ]
  }

  # Pro plan example:
  # - polish=lossless, mirage, WAF managed ruleset enabled automatically
  # - custom firewall rule added on top
  # - individual settings can be overridden via the settings block
  "acme-shop.com" = {
    plan             = "pro"
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
      { type = "A", name = "@", value = "76.76.21.21", proxied = true },
      { type = "A", name = "www", value = "76.76.21.21", proxied = true },
      { type = "A", name = "api", value = "76.76.21.21", proxied = true },
    ]
  }
}
