# Owner scripts: product PROD Graph mail — Exchange Online side

Per the SA-approved #187 redesign: **the Entra side lives in
[`live/identity`](../../../live/identity/)** (the mail service apps are adopted
there by import or created by `prod_apps.tf`, certificates attached by their
public half, client ids as `tofu output mail_service_client_ids` /
`opshub_prod_client_ids`). This directory keeps ONLY what Terraform does not
model — the **Exchange Online** side. One file: `exchange-prod-mail.ps1`
(PowerShell 7, ExchangeOnlineManagement).

Scope: **prod, per `-Product`** (`rova`, `opshub`, `kb`). The dev service apps'
Exchange side is live since 2026-10-18. Nothing tenant-specific is hardcoded
(public repo) — `-TenantId` and `-ServiceAppId` are mandatory; `-SignInAppId`
is required only by `-Step RemoveSignInRole` (the rova sign-in app's legacy
grant; opshub/kb prod never held one). The `kb` entry is ready and runs when
kb prod launches (decision 5: after TEI).

## Which app is which

| Product | Service app (holds `Application Mail.Send`) | Mailbox / scope | Entra side |
| --- | --- | --- | --- |
| rova | `Rova Prod Service` | `noreply-rova` | adopted, `mail.tf` |
| opshub | `OpsHub Prod Service` | `noreply-opshub` | created, `prod_apps.tf` |
| kb | `KB Prod Service` | `noreply-kb` | draft, when kb prod launches |

`-ServiceAppId` is the service app's client/app id; `-ServiceObjectId` is its
service-principal OBJECT id (`az ad sp show --id <appId> --query id`). The old
parameter names `-RovaProdServiceAppId` / `-RovaProdServiceObjectId` remain as
aliases, so previously recorded rova commands keep working.

## Sequence — Stage D preconditions (CUTOVER-2026-11), NOT a separate window

There is no standalone Graph-prod release window: the Exchange-side setup below
is **pre-window prep for the rova prod on-prem cutover (Stage D)**. Stage D
opens only when its preconditions hold — among them **Graph prod live via the
certificate path (rova #758/#763)** and **SES/SQS removed (rova #730)**; the
manual RDS snapshot is Stage D's own D1 step. The SES-removal order is plan
§7.3: **rova #730 → opshub #413 → KB #216 → infra #188** (infra #188, the SES
identity + DNS removal, lands last in the AWS-exit teardown; #413/#216 cover
opshub's and KB's prod SES paths).

1. **Entra side (owner, from `live/identity`):** the "Rova Prod Service"
   registration already exists (hand-made 2026-11-01, certificate attached,
   secret `kv-qnsc-prod/rova-prod-graph-cert` already written). Export the ids
   and the public certificate, check the certificate thumbprint by hand (README
   "Mail service apps" step 3), `tofu plan` go/no-go (8 app/SP imports + 4 cert
   imports, no cert create, nothing else), `tofu apply`. Record
   `mail_service_client_ids`.
2. **Exchange side (this directory):**

   ```powershell
   # rova (Stage D)
   ./exchange-prod-mail.ps1 `
     -TenantId <tenant-guid> -Product rova `
     -ServiceAppId <app id from mail_service_client_ids> `
     -ServiceObjectId <SP object id from az ad sp show> `
     -ControlMailbox noreply-rova-dev@qnsc.vn

   # opshub prod (live/identity "Prod identity: OpsHub" step 3 gives both ids)
   ./exchange-prod-mail.ps1 `
     -TenantId <tenant-guid> -Product opshub `
     -ServiceAppId <opshub_prod_client_ids.service> `
     -ServiceObjectId <opshub_prod_object_ids.service_sp> `
     -ControlMailbox noreply-opshub-dev@qnsc.vn
   ```

   Creates what is missing and prints the proof table (explicit
   `Application Mail.Send` + `InScope` filter, plus a `-ControlMailbox`
   assertion that must be OUT of scope). SP lookups are identity-scoped
   (`Get-ServicePrincipal -Identity`, never a bare tenant-wide call). The run fails if any row differs from
   the expected values: the own prod mailbox is `True`, everything else `False`.
   First-hour propagation is normal — re-run before debugging.

3. **Graph prod goes live BEFORE the Stage D window** via the certificate path
   (rova #758/#763; `mail_graph_client_id` = the recorded rova_prod client id,
   cert mounted from `rova-prod-graph-cert`), and **rova #730 removes
   SES/SQS**. §7.3: rova prod cannot leave AWS until Graph prod works and #730
   has removed SES/SQS. The real-invitation smoke (login, attachment,
   Graph 202, guest invite) is the Stage D D6 step.
4. **After a real invitation arrived (rova only):** remove the legacy grant on
   the "Rova Prod" sign-in app. Dry run by default; the UNDO command is printed
   before anything is removed:

   ```powershell
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole -TenantId <tenant-guid> `
     -SignInAppId <sign-in-app-guid> -ServiceAppId <app id>                          # dry run
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole ... -ConfirmRemoveSignInAppRole
   ```

   (`-ServiceObjectId` and `-ControlMailbox` are Setup-only; the examples above
   carry exactly the parameters each step uses.)

   The match is found by role `Application Mail.Send`, the product's scope
   (`noreply-rova`), and assignee resolving to the sign-in app's service
   principal — not by display name. It refuses unless the Service app is
   already in scope for its own mailbox, refuses if more than one assignment
   matches, and verifies the sign-in app is out of scope after the removal.
5. **infra #188** (SES identity + DNS removal) lands LAST, in the AWS-exit
   teardown, per the §7.3 order above.

## Smoke check per product (owner-run, from the product repos)

rova `pnpm exec platform-mail-check` (`docs/runbooks/mail-graph.md`), opshub
the same tool, KB `python3 scripts/graph_mail_check.py` — each must PASS the
send to its own mailbox and 403 on the others.

## What is NOT verified

- Nothing here has run against Exchange Online or the tenant; the script was
  parse-checked with the PowerShell parser (`Parser::ParseFile`: OK) and
  reviewed, not executed. Cmdlet behaviour
  (`Test-ServicePrincipalAuthorization` row shape incl. `RoleName`,
  `RoleAssignee` matching) is written from the product runbooks.
- The check tools were read from the product repos, not run.
- The live `tofu plan` for `live/identity` is the owner's go/no-go — see that
  README for the expected counts.
