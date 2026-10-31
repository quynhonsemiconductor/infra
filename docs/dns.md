# qnsc.vn DNS: what is in code, what is not, and what to delete

Cloudflare is the DNS for `qnsc.vn`. `live/edge` manages the records below in OpenTofu (zone id from the validated variable
`cloudflare_zone_id`; every record has `prevent_destroy`, and the plan/apply workflows refuse a plan that deletes or replaces a DNS
record unless the PR carries the `allow-dns-destroy` label; see `docs/incidents/2026-10-09-edge-dns.md`).

## Mail records (owner: `live/edge`)

| Name | Type | Purpose | In code |
|---|---|---|---|
| `qnsc.vn` | TXT | SPF for the apex: Microsoft 365, `-all` (the `include:amazonses.com` term is removed by hand once SES is gone) | not in code (set by hand) |
| `_dmarc.qnsc.vn` | TXT | DMARC, report-only | `dmarc` (imported, see below) |

**The SES records are removed from code and from the zone** by `chore(email): remove SES identity and mail-from DNS for qnsc.vn`
(infra#188): the shared `qnsc.vn` identity, its three `*._domainkey` DKIM CNAMEs, and the `mail.qnsc.vn` MX + SPF pair. That PR is
gated on every product being off SES.

## DMARC policy and its plan

`v=DMARC1; p=none; rua=mailto:devops@qnsc.vn`. `p=none` only **collects** aggregate reports; it rejects and quarantines nothing, so a legitimate
sender we forgot (Microsoft 365 for staff mailboxes, SES for the products) cannot have its mail dropped while the reports are unread.

1. Read the aggregate reports for **2 to 4 weeks**.
2. When every legitimate source passes (Microsoft 365 via `spf.protection.outlook.com`, SES via `amazonses.com`, DKIM aligned) and only noise fails,
   move to `p=quarantine` in its own PR, with the reports that justify it.
3. After another clean period, `p=reject`.

The record was set by hand and **imported** (record id `dbd8907e1e797ff142ef0b5ac6e50a60`). The first apply shows `1 to import, 1 to change`; the
"change" only backfills `content` and `allow_overwrite` into state (the v4 provider does not read them on import). The DNS values (name, type, ttl, content)
are unchanged. After that apply, delete the `import` block, then quote the content and add a comment in a follow-up update, as was done for the SPF record.

## Resend leftovers: delete by hand (owner)

Resend is not used. rova and opshub send through SES (`EMAIL_PROVIDER=ses`; opshub's module default is `dev`), no repository or GitHub secret is
named for Resend, and **solodesk, the one product whose code still defaulted to Resend, is retired and archived** (owner, 2026-10-13). These records
are not in code and serve nothing; delete them in the Cloudflare dashboard (they cannot be removed by a PR here):

| Record | Value (as of 2026-10-13) |
|---|---|
| `send.qnsc.vn` MX | `10 feedback-smtp.ap-northeast-1.amazonses.com` |
| `send.qnsc.vn` TXT | `"v=spf1 include:amazonses.com ~all"` (same string as the SES one, but under `send.`, the Resend sending subdomain) |
| `resend._domainkey.qnsc.vn` TXT | Resend's DKIM public key |

Also remove the Resend domain in the Resend account if it still exists (not visible from here). The dead Resend provider code in rova and opshub
(`libs/platform/src/email/providers/resend.provider.ts`, `RESEND_API_KEY`, `EMAIL_PROVIDER=resend`) goes in the WP-15 mail work.
