# Owner scripts: PROD Graph mail tenant setup

Owner-run scripts for the **production** tenant (`dc0f2078-ac28-4ff2-b21a-d4b28df32361`, AWS account `608983206583`, region `ap-southeast-1`). They set up the Microsoft Graph mail path for Rova, OpsHub and KB: one shared mailbox per product, one Exchange RBAC-scoped Service app per product, one certificate per Service app.

These scripts are written, not run. Nothing here has executed against a tenant or an AWS account.

## Files

| File | Runs on | Does |
| --- | --- | --- |
| `exchange-prod-mail.ps1` | PowerShell 7, ExchangeOnlineManagement | Mailboxes, management scopes, service principals, `Application Mail.Send` assignments, the authorization proof table. Step `RemoveSignInRole` removes the old sign-in-app grant (dry run by default). |
| `entra-aws-prod-mail.sh` | bash, `az`, `aws` (profile `qnsc-admin`), `openssl`, `python3` | Certificates, certificate credentials on the Service apps, opshub's five Graph permissions, the standalone secrets, and each product's check tool. |

## Placeholders (fill before running)

The owner creates three Entra app registrations by hand (single tenant, no redirect URI, no client secret, notes = repo link) and an enterprise-application object for each. The scripts take their GUIDs as inputs and refuse placeholder values such as `<ROVA_PROD_SERVICE_APP_ID>`. Nothing in these files is a real GUID.

| Placeholder | Where it comes from | Used by |
| --- | --- | --- |
| `<ROVA_PROD_SERVICE_APP_ID>` | Application (client) ID of "Rova Prod Service" | PowerShell `-RovaProdServiceAppId`, bash env `ROVA_PROD_SERVICE_APP_ID` |
| `<ROVA_PROD_SERVICE_OBJECT_ID>` | Object ID of the **enterprise application** "Rova Prod Service" (not the App registrations object ID) | PowerShell `-RovaProdServiceObjectId` |
| `<OPSHUB_PROD_SERVICE_APP_ID>` | Application (client) ID of "OpsHub Prod Service" | PowerShell `-OpshubProdServiceAppId`, bash env `OPSHUB_PROD_SERVICE_APP_ID` |
| `<OPSHUB_PROD_SERVICE_OBJECT_ID>` | Enterprise application object ID of "OpsHub Prod Service" | PowerShell `-OpshubProdServiceObjectId` |
| `<KB_PROD_SERVICE_APP_ID>` | Application (client) ID of "KB Prod Service" | PowerShell `-KbProdServiceAppId`, bash env `KB_PROD_SERVICE_APP_ID` |
| `<KB_PROD_SERVICE_OBJECT_ID>` | Enterprise application object ID of "KB Prod Service" | PowerShell `-KbProdServiceObjectId` |
| `<MAIL_SMOKE_TO>` | A mailbox you can read, receives the test message | bash env `MAIL_SMOKE_TO` |
| `<ROVA_REPO>`, `<OPSHUB_REPO>`, `<KB_REPO>` | Local checkouts of `rova`, `opshub`, `qnsc-kb-backend` with dependencies installed (`pnpm install`; the KB Python env) | bash env, `check` step |

The sign-in app `503133fe-58c0-4158-86ca-0cecb2f6f376` ("Rova Prod") is a known value from the rova runbook, not a placeholder.

## Standards these scripts follow

- Secrets: one standalone secret per product certificate, readable only by the worker's execution role. Names: `rova/production/mail-graph-certificate`, `opshub/production/graph-client-certificate`, `qnsc-kb/prod/mail-graph-certificate`. Values go in on stdin (`file:///dev/stdin`), never in argv. Output shows lengths and PEM markers only.
- Entra: certificate only, no client secret, no `Mail.*` permission anywhere. Only the `.crt` is uploaded. Keys stay in `~/.qnsc-secrets/mail-certs` (mode 700, files 600). The scripts refuse paths under `~/Desktop`, `~/Documents` and iCloud Drive.
- Graph permissions: `opshub` prod gets exactly the five application roles (`SecurityEvents.Read.All`, `DeviceManagementManagedDevices.Read.All`, `User.Read.All`, `User.EnableDisableAccount.All`, `User.RevokeSessions.All`). Rova and KB Service apps get none, as their runbooks require. Role IDs are resolved from Microsoft Graph by name, not hard-coded.
- Every AWS command names `--profile qnsc-admin --region ap-southeast-1`. Preflight verifies the account is `608983206583`.

## Run order

Run in this order. Step 3 (the check tools) needs steps 1 and 2 finished, and the Exchange role can take up to about an hour to reach Graph.

1. **Owner, by hand (Entra admin center):** create the three apps listed above and record their IDs. Remove the default `User.Read` delegated entry from each Service app. Do not add `Mail.Send` or grant any mail consent.

2. **Exchange (PowerShell 7):**

   ```powershell
   ./exchange-prod-mail.ps1 `
     -RovaProdServiceAppId '<ROVA_PROD_SERVICE_APP_ID>' -RovaProdServiceObjectId '<ROVA_PROD_SERVICE_OBJECT_ID>' `
     -OpshubProdServiceAppId '<OPSHUB_PROD_SERVICE_APP_ID>' -OpshubProdServiceObjectId '<OPSHUB_PROD_SERVICE_OBJECT_ID>' `
     -KbProdServiceAppId '<KB_PROD_SERVICE_APP_ID>' -KbProdServiceObjectId '<KB_PROD_SERVICE_OBJECT_ID>'
   ```

   Creates what is missing and prints the proof table. The run fails if any row differs from the expected values: the own prod mailbox is `True`, the dev mailboxes and the other products' mailboxes are `False`. The existing scope `noreply-rova` and the sign-in app's assignment are left alone.

3. **AWS and Entra (bash):**

   ```bash
   export ROVA_PROD_SERVICE_APP_ID='<ROVA_PROD_SERVICE_APP_ID>' \
          OPSHUB_PROD_SERVICE_APP_ID='<OPSHUB_PROD_SERVICE_APP_ID>' \
          KB_PROD_SERVICE_APP_ID='<KB_PROD_SERVICE_APP_ID>'
   S=entra-aws-prod-mail.sh
   bash "$S" preflight     # az on prod tenant, AWS account 608983206583 via qnsc-admin
   bash "$S" certs         # RSA 2048 per app, 730 days, never overwrites
   bash "$S" entra         # upload .crt (--append), opshub Graph roles + admin consent, role count asserts
   bash "$S" secrets       # key+cert PEM to the three standalone secrets (stdin)
   export MAIL_SMOKE_TO='<MAIL_SMOKE_TO>' ROVA_REPO='<ROVA_REPO>' OPSHUB_REPO='<OPSHUB_REPO>' KB_REPO='<KB_REPO>'
   bash "$S" check rova opshub kb   # each product's own check tool against prod, with --denied-mailbox
   ```

   The `check` step sends one test message per product. Each tool must report `PASS` for the SEND to the prod mailbox and `PASS` (403) for each denied mailbox. If an allowed send is refused in the first hour, wait and retry: that is Exchange propagation.

   After `check` passes, the product switch-on PRs (`email_provider = "graph"`, the client ID, the certificate flag) are separate changes. They are not part of this directory.

4. **Rova production only, after a real invitation has arrived from `noreply-rova@qnsc.vn`:** remove the old grant on the sign-in app. This is a dry run unless the flag is passed:

   ```powershell
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole -RovaProdServiceAppId '<ROVA_PROD_SERVICE_APP_ID>'                       # dry run: prints the match
   ./exchange-prod-mail.ps1 -Step RemoveSignInRole -RovaProdServiceAppId '<ROVA_PROD_SERVICE_APP_ID>' -ConfirmRemoveSignInAppRole
   ```

   The match is found by role `Application Mail.Send`, scope `noreply-rova`, and assignee resolving to the sign-in app's service principal. It is not matched by display name. The step refuses to run unless the Rova Service app is in scope for `noreply-rova@qnsc.vn`, and it refuses if more than one assignment matches.

## What is NOT verified

- Nothing ran against Entra, Exchange Online or AWS. The scripts were only syntax-checked.
- Exchange and Entra cmdlet behaviour (`Test-ServicePrincipalAuthorization` output shape, `RoleAssignee` matching, `az ad app credential reset --append` with `--cert`) is written from the runbooks in the product repos and has not been exercised.
- The check tools were read from the product repos (`rova` `docs/runbooks/mail-graph.md`, `opshub` `docs/runbooks/mail-graph.md`, `qnsc-kb-backend` `scripts/graph_mail_check.py`) and not run.
- The opshub spec (`docs/graph-worker-app.md`) shows RSA 3072 for the Graph worker certificate. These scripts use RSA 2048, as the task specifies. Whether each product's check tool accepts RSA 2048 has not been tested.
- Admin consent on the opshub Service app also covers the default delegated `User.Read` entry, if it is still listed. Remove that entry in Entra (step 1).
