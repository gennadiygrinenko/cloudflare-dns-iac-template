output "zone_ids" {
  description = "Map of domain name → Cloudflare zone ID."
  value       = { for domain, zone in cloudflare_zone.this : domain => zone.id }
}

output "zone_name_servers" {
  description = "Map of domain name → list of Cloudflare nameservers."
  value       = { for domain, zone in cloudflare_zone.this : domain => zone.name_servers }
}

output "dns_record_ids" {
  description = "Map of record key → Cloudflare DNS record ID."
  value       = { for key, rec in cloudflare_dns_record.this : key => rec.id }
}
