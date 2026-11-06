# Entra activity logs: what is kept, what is not, and the weekly sign-in review

Status 2026-11-06. Implements hardening decision 8
(`sa-notes/PLAN-PLATFORM-HARDENING-2026-11-04.md`): the tenant has **no Microsoft
Entra ID P1/P2**, so Microsoft's native retention applies and we compensate for
what the free tier drops.

## 1. What Microsoft keeps for free

| Log | Free retention | Machine-readable? | Where it goes here |
| --- | --- | --- | --- |
| Directory **audit** logs | 7 days | Yes — Graph `auditLogs/directoryAudits` | Exported nightly to `stqnsckvaudit/entra-audit`, **365 days** |
| **Sign-in** logs | 7 days | **No** — Graph refuses without P1 | Not exported. **Weekly manual review** (§4) |

Verified on this tenant, not inferred:

```bash
az rest --method get --url 'https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$top=1'
# 200, one record

az rest --method get --url 'https://graph.microsoft.com/v1.0/auditLogs/signIns?$top=1'
# 403 {"error":{"code":"Authentication_RequestFromNonPremiumTenantOrB2CTenant",
#              "message":"Tenant is not a B2C tenant and doesn't have premium license"}}
```

Documentation: Microsoft Entra licensing, "Microsoft Entra monitoring and health"
— audit logs and sign-in logs are listed as available on Entra ID Free;
*export* of sign-ins still requires P1/P2 in practice, which the 403 above shows
for Graph and which the portal's diagnostic settings enforce.
Sources: <https://learn.microsoft.com/en-us/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health>,
<https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-access-activity-logs>,
<https://learn.microsoft.com/en-us/entra/identity/monitoring-health/reference-reports-data-retention>.

## 2. The audit export (IaC + nightly job)

- IaC: `live/identity/entra_audit_export.tf` — app `QNSC Entra Audit Export`
  (secret-less, GitHub OIDC `ref:refs/heads/main` only), Graph **application**
  permission `AuditLog.Read.All`, `Storage Blob Data Contributor` scoped to the
  **`entra-audit` container** (never the account, so it cannot write the Key
  Vault trail), container with a **locked 365-day WORM** policy, plus a 365-day
  lifecycle rule in `live/identity/audit_logs.tf`.
- Job: `.github/workflows/entra-audit-export.yml`, nightly 01:23 UTC, 72-hour
  window (`scripts/entra_audit_export.py`). The script sends the bearer token
  only to `https://graph.microsoft.com/` and re-checks the host on every
  `@odata.nextLink` before following it.
- Watchdog: `.github/workflows/entra-audit-gap.yml`, weekly Monday. Fails and
  opens an issue when the export workflow is **disabled**, the container is
  empty, or the newest blob is older than **72 h**. It is a separate workflow on
  purpose: disabling the export must not silence the check that notices. The
  issue emails the watchers; the next green run closes it.
- Layout: `entra-audit/YYYY/MM/DD/audit-YYYYMMDDTHHMMSSZ.jsonl.gz`, one line per
  record. Runs overlap by design; de-duplicate on the record `id` when reading.
- The job **skips green** until repo variable `AZURE_CLIENT_ID_ENTRA_AUDIT` is
  set (the client id printed by `tofu output entra_audit_export_client_id`).

Read one day:

```bash
az storage blob download --account-name stqnsckvaudit --container-name entra-audit \
  --name 2026/11/06/audit-20261106T012315Z.jsonl.gz --auth-mode login --file /tmp/a.jsonl.gz
gzip -dc /tmp/a.jsonl.gz | jq -c 'select(.activityDisplayName|test("role|consent|application";"i"))'
```

**IRREVERSIBLE — a gate, not a comment.** The container's WORM policy is created
with `locked = true`: it can never be weakened or removed, by OpenTofu, the
portal or a subscription owner, and its blobs cannot be changed or deleted for
365 days. Retention may only be increased. `prevent_destroy` also makes
destroying `live/identity` fail rather than take the trail with it.

The apply refuses to create the policy without an explicit confirmation:

```bash
# Only after reading the paragraph above and agreeing with the owner:
export TF_VAR_confirm_worm_irreversible=true
# then the usual plan + apply (the kit does NOT set this variable)
scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan
scripts/owner/identity-env/identity-env.sh -- tofu apply tfplan
```

Without it the plan stops at the policy's precondition. Later applies are not
blocked: the precondition is evaluated only when that resource is planned for a
change.

First enablement (owner, once — identity is owner-applied only):

```bash
cd infra
scripts/owner/identity-env/identity-env.sh -- tofu apply tfplan   # after the usual plan/review
tofu output entra_audit_export_client_id                           # public id
gh variable set AZURE_CLIENT_ID_ENTRA_AUDIT -R quynhonsemiconductor/infra --body '<id>'
gh workflow run entra-audit-export.yml -R quynhonsemiconductor/infra
```

## 3. The sign-in gap, in plain words

- We can see a sign-in **for 7 days** in the Entra portal, and not at all from
  automation without P1.
- So: an incident detected more than a week late has **no sign-in trail**. What
  still survives is the directory audit trail (who changed roles, apps, groups;
  365 days here), Cloudflare Access logs, and the per-app logs.
- Accepted risk 2026-11-04; revisit at the next budget cycle (one P1 licence per
  admin would additionally unlock Conditional Access).

## 4. The compensation: a 10-minute weekly sign-in review

**Who:** the on-call platform admin. **When:** Monday before 10:00 (put it in
the on-call checklist). **Window:** the last 7 days — this cannot be done later.

1. <https://entra.microsoft.com> → **Entra ID → Monitoring & health → Sign-in logs**.
2. Add these filters one at a time and read the list (top 20 is enough):
   - **Status: failure** — a burst of failures against one or many accounts is
     password spraying.
   - **Application: (your admin tools)** — PVE/PBS, ArgoCD webhook, the
     sign-in apps; anything from an unexpected country is worth a look.
   - **User: each Global Administrator** — the admin accounts are the ones
     whose compromise matters; check their interactive sign-ins and the source
     IPs (office, VPN/WARP, home).
   - **Authentication requirement: single-factor** — on Free this is mostly
     legacy protocol attempts; any success is an escalation.
3. Cross-check anything odd against **Audit logs** in the portal for the same
   time (that trail is also exported for 365 days).
4. Record the result as one line in the platform Teams channel:
   `signin review <date>: clean`, or the finding plus the issue link.
   Anything suspicious: open an issue labelled `security` and, for a suspected
   compromise, **revoke the user's sessions** (Entra → user → Revoke sessions),
   reset the password, and remove the session grant in Cloudflare Zero Trust.

The exported audit trail does not replace this review: it cannot see sign-ins.

## 5. What to do if P1 is bought later

1. Create the diagnostic setting (portal: Entra → Monitoring & health →
   Diagnostic settings → Archive to storage → `stqnsckvaudit`) or extend this
   export to pull `auditLogs/signIns` (the app already has the pattern; add
   `AuditLog.Read.All` stays the same permission — sign-in requires the licence,
   not another scope).
2. Keep the weekly review for one month as a cross-check, then retire §4.
