# Entra app-registration audit

A **read-only** check of every Entra app registration against the QNSC app-registration standard
(HYBRID-INFRA-PLAN section 7.4, decided 2026-10-18). The owner runs it in their own terminal; nothing here
touches a tenant from CI. This repository is public: the scripts contain no tenant or app IDs, and the output
(which has them) is written **outside** the repo.

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
| `redirect-uris` | all | a redirect URI (web, SPA, public client) is not an exact `https://` URI; `http://localhost` is allowed only on Dev apps |
| `credential-expiry` | all | a secret or certificate is expired or expires within 30 days |
| `signin-delegated-only` | sign-in | a delegated permission other than openid, profile, email, offline_access, User.Read |
| `signin-secret-lifetime` | sign-in | a client secret valid for more than 6 months (183 days) |
| `signin-assignment-required` | sign-in | the enterprise app's `appRoleAssignmentRequired` is false (or there is no enterprise app) |
| `signin-no-mail-rbac` | sign-in | the app holds an Exchange `Application Mail.*` role (belongs on the Service app) |
| `service-no-secret` | service | any client secret |
| `service-mail-rbac-scoped` | service | an `Application Mail.*` role without a custom resource scope that has a recipient filter |

Results are PASS, FAIL, N/A (rule does not apply) or SKIP (data not collected: the two `*-mail-rbac` rules need
the Exchange step). Every FAIL has a concrete fix line. Also reported: expected apps that are missing (a Service
app with no sign-in app and vice versa), Exchange mail role assignments that match no app, and collection notes.

## Prerequisites

- **Azure CLI** (`az`), `jq`, `python3` (3.10+). `az login` with an account that has the **Global Reader** role.
  No write role is needed or used.
- **Exchange step (optional but needed for the two mail-RBAC rules):** PowerShell 7 (`pwsh`) and the module:
  `Install-Module ExchangeOnlineManagement -Scope CurrentUser`. Global Reader can read Exchange configuration; if
  `Get-ManagementRoleAssignment` is refused, the Exchange role group *View-Only Organization Management* is the
  read-only alternative. (Not verified against this tenant: the script's role assumption comes from Microsoft's docs.)

Why `az rest` and not the Microsoft Graph PowerShell SDK for the Graph part: no module to install or pin, the call is
a plain GET that reads exactly like the Graph documentation, and "only GET" can be enforced with a grep
(`check-readonly.sh`). The Exchange part has no Graph equivalent, so it is PowerShell. The report generator is
Python (standard library) so the same code runs on the recorded fixtures in CI.

## Run it

```bash
az login
scripts/entra-audit/entra-audit.sh                 # collects Graph data, writes the report; default dir ~/entra-audit-<date>/
pwsh scripts/entra-audit/exchange-rbac-audit.ps1   # collects Exchange RBAC into the same directory
scripts/entra-audit/entra-audit.sh --report-only ~/entra-audit-$(date +%F)   # report again, now with the mail-RBAC rules
```

All three take the output directory as an argument (`entra-audit.sh [OUTDIR]`, `exchange-rbac-audit.ps1 [OUTDIR]`).
The directory must be outside any git repository (`entra-audit.sh` refuses otherwise). It will contain
`graph.json`, `exchange.json`, `entra-audit-report.md`, `entra-audit-report.json`.

Exit status: `entra-audit.sh` 0 = no FAIL, 1 = at least one FAIL, 2 = could not run. The Exchange script exits 1 when it
sees an unscoped mail role (a finding, not an error).

**Send back** `entra-audit-report.md`. App and tenant IDs are in it and are not secrets; no secret value is ever
read (credential metadata is reduced to keyId, display name and dates; the `hint` and `key` fields are dropped).
Delete the directory afterwards: it names your apps, mailboxes and owners.

## Limits

- Exchange role assignments are matched to apps by service principal object id, app id or display name
  (`RoleAssigneeName` as Exchange prints it). Assignments that match no app are listed rather than dropped.
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
