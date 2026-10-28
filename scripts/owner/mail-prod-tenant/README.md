# Owner scripts: rova PROD Graph mail — Exchange Online side

Per the SA-approved #187 redesign: **the Entra side lives in
[`live/identity/mail.tf`](../../../live/identity/)** (the mail service apps are
adopted there by import, certificates attached by their public half, client ids
as `tofu output mail_service_client_ids`). This directory keeps ONLY what
Terraform does not model — the **Exchange Online** side, rova prod only. One
file: `exchange-prod-mail.ps1` (PowerShell 7, ExchangeOnlineManagement).

Scope: **rova prod only.** The dev service apps' Exchange side is live since
2026-10-18. opshub/KB prod are not live; their Exchange steps come with their
own prod service-app PRs. Nothing tenant-specific is hardcoded (public repo) —
`-TenantId` and `-SignInAppId` are mandatory parameters.

## Sequence — Stage D preconditions (CUTOVER-2026-11), NOT a separate window

There is no standalone Graph-prod release window: the Exchange-side setup below
is **pre-window prep for the rova prod on-prem cutover (Stage D)**. Stage D
opens only when its preconditions hold — among them **Graph prod live via the
certificate path (rova #758/#763)** and **SES/SQS removed (rova #730)**; the
manual RDS snapshot is Stage D's own D1 step. The SES-removal order is plan
§7.3: **rova #730 → opshub #413 → KB #216 → infra #188** (infra #188, the SES
identity + DNS removal, lands last in the AWS-exit teardown; #413/#216 cover
opshub's and KB's prod SES paths).

1. **Entra side (owner, from `live/identity`):** hand-create the missing
   "Rova Prod Service" registration (README "Mail service apps" step 1),
   export the ids/certs, `tofu plan` go/no-go (8 app/SP imports + 3 dev cert
   imports + 1 cert create, nothing else), `tofu apply`, then the vault
   one-liners — `kv-qnsc-prod/rova-prod-graph-cert` and the three dev
   `<product>-<env>-graph-cert` secrets. Record `mail_service_client_ids`.
2. **Exchange side (this directory, rova prod):**

   ```powershell
   ./exchange-prod-mail.ps1 `
     -TenantId <tenant-guid> -SignInAppId <rova-prod-sign-in-app-guid> `
     -RovaProdServiceAppId <app id from mail_service_client_ids> `
     -RovaProdServiceObjectId <SP object id from the az ad sp show export> `
     -ControlMailbox noreply-rova-dev@qnsc.vn
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
4. **After a real invitation arrived:** remove the legacy grant on the
   "Rova Prod" sign-in app. Dry run by default; the UNDO command is printed
   before anything is removed:

   ```powershell
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole -TenantId <tenant-guid> `
     -SignInAppId <sign-in-app-guid> -RovaProdServiceAppId <app id>                              # dry run
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole ... -ConfirmRemoveSignInAppRole
   ```

   (`-RovaProdServiceObjectId` and `-ControlMailbox` are Setup-only; the
   examples above carry exactly the parameters each step uses.)

   The match is found by role `Application Mail.Send`, scope `noreply-rova`,
   and assignee resolving to the sign-in app's service principal — not by
   display name. It refuses unless the Service app is already in scope for
   `noreply-rova@qnsc.vn`, refuses if more than one assignment matches, and
   verifies the sign-in app is out of scope after the removal.
5. **infra #188** (SES identity + DNS removal) lands LAST, in the AWS-exit
   teardown, per the §7.3 order above.

## Smoke check per product (owner-run, from the product repos)

rova `pnpm exec platform-mail-check` (`docs/runbooks/mail-graph.md`), opshub
the same tool, KB `python3 scripts/graph_mail_check.py` — each must PASS the
send to its own mailbox and 403 on the others.

## What is NOT verified

- Nothing here has run against Exchange Online or the tenant; the script was
  reviewed, not executed. Cmdlet behaviour
  (`Test-ServicePrincipalAuthorization` row shape incl. `RoleName`,
  `RoleAssignee` matching) is written from the product runbooks.
- The check tools were read from the product repos, not run.
- The live `tofu plan` for `live/identity/mail.tf` is the owner's go/no-go —
  see that README for the expected counts.
