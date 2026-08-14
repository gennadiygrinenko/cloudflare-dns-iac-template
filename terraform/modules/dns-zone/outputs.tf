output "zone_ids" {
  description = "Map of domain name → Cloudflare zone ID."
  value       = { for domain, zone in cloudflare_zone.this : domain => zone.id }
}

output "zone_name_servers" {
  description = "Map of domain name → list of Cloudflare nameservers."
  value       = { for domain, zone in cloudflare_zone.this : domain => zone.name_servers }
}

output "dmarc_external_authorizations_required" {
  description = "Domains whose DMARC rua mailbox lives in a zone this module does not manage. Each entry must be published by whoever owns that zone, or aggregate reports are silently dropped (RFC 7489 §7.1). Vendors such as EasyDMARC or dmarcian publish a wildcard themselves — the list is a checklist, not an error."
  value = {
    for domain, rua in local.dmarc_rua_domain :
    domain => {
      fqdn    = "${domain}._report._dmarc.${rua}"
      type    = "TXT"
      content = "v=DMARC1"
      note    = "Publish in the zone that owns ${rua}, not in ${domain}."
    }
    if !local.dmarc_rua_internal[domain] && local.dmarc_rua_zone[domain] == null
  }
}

output "dmarc_report_delegation_warnings" {
  description = "Authorization records placed in a managed child zone whose managed parent has no NS delegation for it. Without delegation the parent stays authoritative and the record is never served."
  value = {
    for domain, zone in local.dmarc_rua_zone :
    domain => "Zone ${zone} has no NS delegation from ${local.dmarc_report_parent[domain]} in this config; ${domain}._report._dmarc would not resolve."
    if zone != null && !local.dmarc_rua_internal[domain] && !local.dmarc_report_delegated[domain]
  }
}

output "dns_record_ids" {
  description = "Map of record key → Cloudflare DNS record ID."
  value = merge(
    { for key, rec in cloudflare_dns_record.this : key => rec.id },
    { for key, rec in cloudflare_dns_record.txt : key => rec.id },
  )
}
