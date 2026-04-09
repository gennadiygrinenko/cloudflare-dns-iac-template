# Zone: example
# Minimal example zone — copy this to create a new zone.

domains = {
  "my-startup.dev" = {
    plan             = "free"
    google_workspace = true

    records = [
      { type = "A", name = "@", value = "76.76.21.21", proxied = true },
      { type = "A", name = "www", value = "76.76.21.21", proxied = true },
      { type = "CNAME", name = "api", value = "api-gateway.example.com", proxied = true },
    ]
  }
}
