# Design decisions

Why this template is shaped the way it is. Each entry states the alternative that was rejected, because the constraint is usually more interesting than the choice.

## One zone group, one Terragrunt module, one state

Every directory under `envs/cloudflare/zones/` is an isolated Terraform workspace with its own state.

The obvious alternative is a single state for the whole estate. It reads better in a diagram and is worse in every operational way: a one-record change plans against every zone you own, so the feedback loop grows with the size of the estate rather than the size of the change. Worse, a mistake anywhere in the config puts every zone in the same apply. DNS mistakes are measured in propagation time, so blast radius matters more than convenience.

The cost is real and worth stating: cross-zone logic is impossible. The module can only reason about domains inside the same `domains` map. This shows up concretely in the DMARC report authorization below, where the receiving zone must be in the same group for the record to be created automatically.

## `ignore_changes` only on TXT

Cloudflare reformats long TXT values — DKIM keys in particular — into 255-character chunks. Terraform sees the reformatted value and reports drift forever. `ignore_changes = [content]` silences it.

Applying that to every record type, as this repo originally did, is a trap. The four auto-generated TXT records (Google site verification, DKIM, SPF, DMARC) had keys that did not include their value, so a new SPF policy or a rotated DKIM key produced no plan at all. The config said one thing, the zone served another, and nothing failed. A/CNAME/MX records happened to escape only because their value was part of the `for_each` key, so a change was a replace rather than an in-place update.

So the resource is split: `cloudflare_dns_record.this` applies content changes, `cloudflare_dns_record.txt` tolerates Cloudflare's formatting. Suppression is scoped to the one type that actually drifts. Note the interaction with the next decision: `ignore_changes` does not apply across a replace, so putting the value in the key is what makes TXT updates land at all.

## Record keys are `{domain}__{type}__{name}__{hash}`

`for_each` needs stable, unique keys. The original scheme built them by string concatenation with `replace(value, ".", "_")`, which makes `1.2.3.4` and `1_2_3_4` the same key. Two records collapse into one map entry, and Terraform does not warn: maps deduplicate silently. One of the records simply never exists.

The value and priority are hashed (`sha256`, first 12 characters) instead. Domain, type, and name stay in clear text so plans remain readable — full hashes would trade a silent bug for an unreadable one, which is a bad deal when the plan output is the last review step before touching production DNS.

Keys are also built in exactly one place. Previously eight separate map constructors each formatted their own key; a scheme that must be applied identically in eight places will eventually be applied differently in one of them.

## `prevent_destroy` on the zone

Deleting a Cloudflare zone deletes every record in it, and there is no undo. A typo in a `domains` key, or a `terraform destroy` aimed at the wrong workspace, is enough.

`prevent_destroy` makes those apply-time failures instead. The intended way to stop managing a domain is `remove-domain` in the state operations workflow, which drops it from state and leaves Cloudflare untouched. That asymmetry is deliberate: forgetting a domain should be easy, deleting one should require intent.

## Plan defaults via `coalesce`, never conditionals

Pro and Business zones get Polish, Mirage, and the managed WAF ruleset by default. The implementation is `coalesce(user_value, plan_default)` per setting, so a user value always wins and the default only fills a gap.

The alternative — branching on the plan and picking a whole settings block — makes "I set `polish = "off"` on a Pro zone" ambiguous. With `coalesce`, an explicitly configured value is never second-guessed. `rocket_loader` stays off even on plans that support it, because it breaks some JavaScript; a default that can break a site should be opt-in.

## DMARC report authorization lives in the receiving zone

When a domain sends aggregate reports to a mailbox in a different organizational domain, RFC 7489 §7.1 requires the *receiving* zone to authorize it: `shop.com` with `rua=mailto:dmarc@acme.com` needs `shop.com._report._dmarc.acme.com TXT "v=DMARC1"` published in `acme.com`. Publishing anything on `shop.com` authorizes nobody. This is the common way the feature looks configured and collects nothing.

The module creates that record when the receiving zone is in the same `domains` map, choosing the longest managed suffix — a delegated child zone is authoritative over its parent — and keeping intermediate labels. When the mailbox is somewhere else, it creates nothing and fails nothing; the requirement appears in the `dmarc_external_authorizations_required` output and as a PR comment. Report vendors publish a wildcard on their side, so failing there would be wrong, and staying silent would recreate the exact problem the feature exists to solve.

Two related judgments:

- **Do not duplicate the receiving zone into another group to make the automation trigger.** Two states managing one Cloudflare zone is a worse failure than a manual TXT record. The output exists precisely so the record can be added by hand in the group that owns the zone.
- **Organizational domains are approximated.** RFC 7489 compares org-domains, which requires the Public Suffix List; Terraform cannot read it. Nesting is used instead, and the error direction is chosen deliberately. Siblings (`a.shop.com` → `dmarc@b.shop.com`) produce a spurious checklist entry, which is harmless. The dangerous direction — a public-suffix parent like `shop.co.uk` → `dmarc@co.uk` looking internal — is blocked by requiring the parent to be a managed zone, since a public suffix can never be a zone in a Cloudflare account.

## Provider version: loose constraint, committed lock

`versions.tf` allows `~> 5.0`, and each zone commits a `.terraform.lock.hcl` pinning the exact build. The constraint says what the module is compatible with; the lock says what actually ran.

Without the lock — it was previously gitignored — the same commit resolved to whatever the newest 5.x happened to be that day. Two runs a month apart could plan differently with no diff to explain it, which turns a provider regression into a hunt through your own code. Lock files carry per-platform hashes, so `make lock` records linux (CI) and both macOS architectures; a lock missing the CI platform fails `init` on the runner.

The module directory deliberately has no lock. Lock files belong to root modules; a lock inside a reusable module is ignored by consumers and only rots.

Keeping the lock current is split between two mechanisms, because neither covers both halves. Dependabot owns the constraint in `versions.tf` and will propose `~> 6.0` when a major appears; it will not move the lock from 5.23.0 to 5.24.0, since it only rewrites a lock as a side effect of changing a manifest, and nothing in the manifest changes. The monthly `Provider lock` workflow owns that half: it runs `init -upgrade` plus `providers lock` per zone and opens a pull request when the resolved build moves. Monthly rather than weekly on purpose — a provider patch that lands seven days earlier changes nothing here, while action deprecations do have a deadline, which is why Dependabot stays weekly. It also validates the zones itself, because pull requests opened with `GITHUB_TOKEN` do not trigger workflows and an unchecked lock bump is exactly the change you want checked.

## Credentials: scoped secrets, not OIDC

State lives in Terraform Cloud, so no state file or cloud credential is stored in the repository, and `terraform.tfstate` never appears in a diff. Cloudflare is reached with a scoped API token (Zone:Edit + DNS:Edit) from GitHub Secrets; Terraform Cloud with `TF_API_TOKEN`.

This is deliberately not described as OIDC. The workflows request `id-token: write` in anticipation of Terraform Cloud's OIDC support, but the Cloudflare provider is authenticated with a static token today. Cloudflare does not accept GitHub OIDC for the Terraform provider, so claiming keyless authentication would be false — and anyone evaluating this repo will open the workflow and see the secret.

What is enforced instead: applies run only from `main`, behind a GitHub Environment with required reviewers; state operations run behind the same gate; and PRs from forks get validation without any secrets, which is why the checks that need credentials are scoped to same-repository pull requests.
