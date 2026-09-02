#!/usr/bin/env bash
# Generate `import` blocks for a zone whose Cloudflare records predate this
# module — a live domain being brought under management.
#
# import-domain brings in the zone only. The records already exist in
# Cloudflare, so an apply that tries to create them is rejected as duplicates
# (error 81058), and there is no way to import them one by one without knowing
# the module's key for each. This reads the live records, matches each to the
# address the current configuration gives it — by what the record is: zone,
# type, name, content, priority — and writes the blocks.
#
# Output is an `imports.tf` in the zone directory: the imports show up in a
# normal plan as "will be imported", get reviewed, and apply through the usual
# pipeline. Delete the file once applied; importing a managed resource errors.
#
# The match is exact, so a plan after the import should show no change to
# these records. Anything else is a difference between the configuration and
# the live zone, and on a domain that serves mail that plan must be read before
# it is applied.
#
# Usage:
#   plan-record-imports.sh <zone>
#
# Testing hooks (skip Terragrunt and the API, feed fixtures instead):
#   STATE_JSON_FILE=… PLAN_JSON_FILE=… LIVE_JSON_FILE=… plan-record-imports.sh <zone>
#   LIVE_JSON_FILE holds { "<domain>": { "zone_id": "…", "records": [ … ] } }.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ZONE="${1:?Usage: plan-record-imports.sh <zone>}"
ZONE_DIR="${REPO_ROOT}/envs/cloudflare/zones/${ZONE}"
IMPORTS_FILE="${ZONE_DIR}/imports.tf"
CF_API="https://api.cloudflare.com/client/v4"

[ -d "$ZONE_DIR" ] || error_exit 1 "Zone directory not found: ${ZONE_DIR}"

cf_get() {
  curl -sSf -X GET "${CF_API}$1" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json"
}

if [ -n "${STATE_JSON_FILE:-}" ] && [ -n "${PLAN_JSON_FILE:-}" ] && [ -n "${LIVE_JSON_FILE:-}" ]; then
  state_json="$(cat "$STATE_JSON_FILE")"
  plan_json="$(cat "$PLAN_JSON_FILE")"
  live_json="$(cat "$LIVE_JSON_FILE")"
else
  : "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required to read the live zone}"

  log_info "Reading current state for ${ZONE}..."
  state_json="$(cd "$ZONE_DIR" && terragrunt run --log-disable -- show -json)"

  log_info "Planning ${ZONE} to resolve the record addresses..."
  plan_file="${ZONE_DIR}/tfplan.imports"
  (cd "$ZONE_DIR" && terragrunt plan -out="$plan_file" --non-interactive >/dev/null)
  plan_json="$(cd "$ZONE_DIR" && terragrunt run --log-disable -- show -json "$plan_file")"
  rm -f "$plan_file"

  # One lookup per domain the configuration declares for this zone.
  live_json="{}"
  for domain in $(jq -r '(.planned_values.outputs.dns_records.value // {}) | [.[].domain] | unique[]' <<<"$plan_json"); do
    log_info "Reading live records for ${domain}..."
    zone_id="$(cf_get "/zones?name=${domain}" | jq -r '.result[0].id // empty')"
    [ -n "$zone_id" ] || error_exit 1 "Zone ${domain} not found in Cloudflare — is the token scoped to it?"
    records="$(cf_get "/zones/${zone_id}/dns_records?per_page=5000")"
    if [ "$(jq '.result_info.total_count > (.result | length)' <<<"$records")" = "true" ]; then
      error_exit 1 "${domain} has more records than one page returned; refusing to import a partial list."
    fi
    live_json="$(jq --arg d "$domain" --arg z "$zone_id" --argjson r "$(jq '.result' <<<"$records")" \
      '. + { ($d): { zone_id: $z, records: $r } }' <<<"$live_json")"
  done
fi

report="$(
  jq -n \
    --argjson state "$state_json" \
    --argjson plan "$plan_json" \
    --argjson live "$live_json" '
    def resources($doc):
      [$doc.values?.root_module? | .. | objects | select(has("address") and has("type") and has("values"))];

    (resources($state) | map(.address)) as $managed
    |
    (($plan.planned_values?.outputs?.dns_records?.value) // {}
      | to_entries
      | map({
          key: .key,
          address: "module.dns_zone.\(.value.resource)[\"\(.key)\"]",
          domain: .value.domain,
          type: .value.type,
          # Cloudflare reports names as FQDNs; configuration uses relative names.
          fqdn: (if .value.name == "@" then .value.domain else "\(.value.name).\(.value.domain)" end),
          value: .value.value,
          priority: (.value.priority // 0),
        })) as $desired
    |
    ($live | to_entries | map(
        .key as $domain | .value.zone_id as $zone_id
        | .value.records[]
        | { domain: $domain, zone_id: $zone_id, id: .id, type: .type, name: .name,
            content: .content, priority: (.priority // 0) }
      )) as $records
    |
    ($records | map(
        . as $r
        | ($desired | map(select(
            .domain == $r.domain
            and .type == $r.type
            and .fqdn == $r.name
            and .value == $r.content
            and .priority == $r.priority
          ))) as $exact
        | { record: $r,
            match: (if ($exact | length) == 1 then $exact[0] else null end),
            ambiguous: (($exact | length) > 1) }
      )) as $matched
    |
    {
      # The zone itself, unless import-domain already brought it in.
      zones: [ $live | to_entries[]
        | { domain: .key, id: .value.zone_id, to: "module.dns_zone.cloudflare_zone.this[\"\(.key)\"]" }
        | select(.to as $a | $managed | index($a) | not) ],

      records: [ $matched[] | select(.match != null) | select(.match.address as $a | $managed | index($a) | not)
        | { to: .match.address, id: "\(.record.zone_id)/\(.record.id)", domain: .record.domain,
            record: "\(.record.type) \(.record.name)" } ],

      already_managed: [ $matched[] | select(.match != null) | select(.match.address as $a | $managed | index($a))
        | "\(.record.domain): \(.record.type) \(.record.name)" ],

      # Live but not described: Terraform never sees these, so they stay as they
      # are. On a domain being mirrored that means the configuration is incomplete.
      unmatched: [ $matched[] | select(.match == null and (.ambiguous | not))
        | "\(.record.domain): \(.record.type) \(.record.name)" ],

      ambiguous: [ $matched[] | select(.ambiguous)
        | "\(.record.domain): \(.record.type) \(.record.name)" ],

      # Described but not live: the next apply creates these.
      missing: [ $desired[] | select(.address as $a | [$matched[] | select(.match != null) | .match.address] | index($a) | not)
        | select(.address as $a | $managed | index($a) | not)
        | "\(.domain): \(.type) \(.fqdn)" ],
    }
    | .collisions = (.records | group_by(.to) | map(select(length > 1)))
  '
)"

count_of() { jq ".$1 | length" <<<"$report"; }

if [ "$(count_of unmatched)" -gt 0 ]; then
  log_warning "$(count_of unmatched) live record(s) have no counterpart in the configuration and stay unmanaged:"
  jq -r '.unmatched[] | "    \(.)"' <<<"$report" >&2
fi

if [ "$(count_of ambiguous)" -gt 0 ]; then
  log_warning "$(count_of ambiguous) live record(s) match more than one configured record and are not imported:"
  jq -r '.ambiguous[] | "    \(.)"' <<<"$report" >&2
fi

if [ "$(count_of missing)" -gt 0 ]; then
  log_warning "$(count_of missing) configured record(s) do not exist in Cloudflare yet and will be created on apply:"
  jq -r '.missing[] | "    \(.)"' <<<"$report" >&2
fi

if [ "$(count_of already_managed)" -gt 0 ]; then
  log_info "$(count_of already_managed) record(s) are already in state and are skipped."
fi

if [ "$(count_of collisions)" -gt 0 ]; then
  log_error "Several live records resolve to the same address; refusing to write ${IMPORTS_FILE#"${REPO_ROOT}/"}."
  jq -r '.collisions[] | "    → \(.[0].to)\n" + (map("        \(.id)") | join("\n"))' <<<"$report" >&2
  error_exit 1 "Cloudflare holds duplicates of a record — reconcile them there first."
fi

total=$(( $(count_of zones) + $(count_of records) ))
if [ "$total" -eq 0 ]; then
  log_success "Nothing to import for ${ZONE}: every live record is already in state."
  rm -f "$IMPORTS_FILE"
  exit 0
fi

{
  echo "# Generated by .github/scripts/plan-record-imports.sh — review, apply, then delete."
  echo "#"
  echo "# Each block adopts a record that already exists in Cloudflare under the"
  echo "# address the current configuration gives it. Without these, the next apply"
  echo "# tries to create the record again and Cloudflare rejects the duplicate."
  echo
  jq -r '.zones[] | "# \(.domain): zone\nimport {\n  to = \(.to)\n  id = \"\(.id)\"\n}\n"' <<<"$report"
  jq -r '.records[] | "# \(.domain): \(.record)\nimport {\n  to = \(.to)\n  id = \"\(.id)\"\n}\n"' <<<"$report"
} >"$IMPORTS_FILE"

terraform fmt "$IMPORTS_FILE" >/dev/null 2>&1 || true

log_warning "$(count_of zones) zone(s) and $(count_of records) record(s) to import — wrote ${IMPORTS_FILE#"${REPO_ROOT}/"}"
log_info "Review it, run a plan (the imports appear as \"will be imported\"), apply, then delete the file."
