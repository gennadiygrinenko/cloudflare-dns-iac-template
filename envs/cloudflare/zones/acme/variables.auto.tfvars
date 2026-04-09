# Zone: acme
# Domains managed in this zone. Add/remove domains by editing this file.

domains = {
  "acme-corp.io" = {
    plan             = "free"
    google_workspace = true
    spf_includes     = ["sendgrid.net"]

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
}
