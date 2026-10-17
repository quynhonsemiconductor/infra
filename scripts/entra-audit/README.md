# Entra app-registration audit

A **read-only** check of every Entra app registration (and of the service principals that have none here) against the
QNSC app-registration standard (HYBRID-INFRA-PLAN section 7.4, decided 2026-10-18). The owner runs it in their own
terminal; nothing here touches a tenant from CI. **This repository is public**: the scripts contain no tenant or app IDs,
and the output (which has them) is written **outside** the repo.

## What it checks

Apps are mapped to product and environment by display name: sign-in `<Product> <Env>`, service
`<Product> <Env> Service` (products Rova, OpsHub, KB, LMS; `--products` changes the list). An app that does not
follow the naming is reported as UNKNOWN and gets only the rules that hold for every app.

| Rule | Applies to | Fails when |
| :--- | :--- | :--- |
| `audience` | all | `signInAudience` is not `AzureADMyOrg` |
| `mail-app-permission` | all | any `Mail.*` or `full_access_as_app` **application** permission is consented **or declared** |
| `sites-scope` | all | `Sites.Read.All`, `ReadWrite.All`, `FullControl.All` or `Manage.All` (use `Sites.Selected`) |
| `unscoped-app-permission-only-on-service` | sign-in and UNKNOWN apps | any application permission at all |
| `owners` | all | fewer than 2 owners |
| `lock` | all | `servicePrincipalLockConfiguration.isEnabled` is not true |
| `notes` | all | Notes is empty |
| `implicit-grant` | all | ID-token or access-token implicit grant is on |
| `redirect-uris` | all | a redirect URI (web, SPA, public client) is a wildcard or not `https://`; `localhost`, `127.0.0.1` and `[::1]` fail in **any** scheme on a non-Dev app, and on a Dev app only `https` or `http` loopback pass |
| `credential-expiry` | all | a secret or certificate is expired, expires within 30 days, or has an unreadable end date |
| `signin-delegated-only` | sign-in | a delegated permission other than openid, profile, email, offline_access, User.Read |
| `signin-secret-lifetime` | sign-in | a client secret valid for more than 6 calendar months (184 days) |
| `signin-assignment-required` | sign-in | the enterprise app's `appRoleAssignmentRequired` is false (or there is no enterprise app) |
| `signin-no-mail-rbac` | sign-in | the app holds an Exchange `Application Mail.*` role (belongs on the Service app) |
| `service-no-secret` | service | any client secret |
| `service-no-delegated` | service | any delegated permission (new registrations get `User.Read` by default; remove it) |
| `service-mail-rbac-scoped` | service | an `Application Mail.*` role without a custom resource scope that has a recipient filter |

**Service principals without an app registration in this tenant** (third-party and multi-tenant apps, managed
identities) are found through `appRoleAssignedTo` on the Microsoft Graph and Exchange Online resources and get
`mail-app-permission` and `sites-scope`. Microsoft first-party apps (owner tenant `f8cdef31-...`, a public constant) are
listed, not graded. Application permissions on other resources (SharePoint's own API, Dynamics ...) are not scanned.

Results are PASS, FAIL, N/A (rule does not apply) or SKIP (data not collected: the two `*-mail-rbac` rules need the Exchange
step). Every FAIL has a concrete fix line. Also reported: expected apps that are missing (a Service app with no sign-in app
and vice versa), Exchange mail role assignments that match no app, and collection notes.

## Prerequisites

- **Global Reader** in the tenant; no write role is needed or used. Azure CLI (`az`), `jq`, and **Python 3.10 or newer**
  for the report (macOS ships 3.9: install a newer one). The scripts say so and stop if it is older.
- **Exchange step** (needed for the two mail-RBAC rules): PowerShell 7 and the `ExchangeOnlineManagement` module. Global
  Reader can read Exchange configuration; if `Get-ManagementRoleAssignment` is refused, the Exchange role group
  *View-Only Organization Management* is the read-only alternative. (Not verified against this tenant; from Microsoft's docs.)

macOS:

```bash
brew install azure-cli jq python
brew install --cask powershell
pwsh -c 'Install-Module ExchangeOnlineManagement -Scope CurrentUser'
```

Why `az rest` and not the Microsoft Graph PowerShell SDK for the Graph part: no module to install or pin, the call is a
plain GET that reads exactly like the Graph documentation, and "only GET" can be enforced with a grep
(`check-readonly.sh`). The Exchange part has no Graph equivalent, so it is PowerShell. The report generator is Python
(standard library) so the same code runs on the recorded fixtures in CI.

## Run it

Pick **one output directory outside any git repository** and use it for all three commands (the scripts refuse a
directory inside a repo, and the Exchange step refuses a directory without the `graph.json` of step 2):

```bash
OUT=~/entra-audit-$(date +%F)

az login --tenant <tenant>.onmicrosoft.com --allow-no-subscriptions   # --allow-no-subscriptions: this account may have none
scripts/entra-audit/entra-audit.sh "$OUT"                    # 1. Graph data + first report (prints the user and tenant it reads as)
pwsh scripts/entra-audit/exchange-rbac-audit.ps1 "$OUT"      # 2. Exchange RBAC (signs in to Exchange Online interactively)
scripts/entra-audit/entra-audit.sh --report-only "$OUT"      # 3. final report, now with the mail-RBAC rules
```

The directory then holds `graph.json`, `exchange.json`, `entra-audit-report.md`, `entra-audit-report.json`, all owner-only
(mode 600/700). A transient Graph error is retried after 10, 30 and 60 seconds; any other failure **aborts the run**, so a
permission error can never read as "nothing consented".

Exit status: `entra-audit.sh` 0 = no FAIL, 1 = at least one FAIL, 2 = could not run. The Exchange script exits 1 when it
sees an unscoped mail role (a finding, not an error).

**Send `entra-audit-report.md` privately** (chat or mail to the architect). **Never paste it into a pull request or
issue: this repository is public.** App and tenant IDs in it are not secrets, but the app names, owners and mailboxes are
not for the public either. No secret value is ever read (credential metadata is reduced to keyId, display name and dates;
the `hint` and `key` fields are dropped). Delete the directory afterwards.

## Limits

- Exchange role assignments are matched to apps by service principal object id, app id or display name
  (`RoleAssigneeName` as Exchange prints it); blank fields never match. Assignments that match no app are listed.
  `Get-ManagementRoleAssignment -RoleAssigneeType ServicePrincipal` is tried first; if Exchange rejects the value the
  script filters client-side and says so.
- If no app returns `servicePrincipalLockConfiguration` the report says so: the `lock` rule would then be failing
  because the field could not be read, not because the lock is off.
- The standard's "Service app is worker only", "Entra groups assigned" and "federated credential on k3s" are not
  machine-checkable from app metadata and are not checked. Federated credentials are collected (name and issuer only).
- Declared-but-not-consented forbidden permissions are FAIL too (one click away from consented).

## Tests (CI: `.github/workflows/entra-audit.yml`)

```bash
python3 -m unittest scripts/entra-audit/test_entra_audit.py -v
bash scripts/entra-audit/check-readonly.sh
shellcheck -x scripts/entra-audit/entra-audit.sh scripts/entra-audit/check-readonly.sh
```

Fixtures in `fixtures/` use fabricated IDs and `example.invalid` addresses only.
