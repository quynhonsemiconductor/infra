# Entra sign-in app hygiene (owner runbook)

Fixes the audit findings (`scripts/entra-audit`, 2026-10-18) for the sign-in apps:

1. **Assignment required** for OpsHub and KB: only people in the right groups can sign in.
2. **Secret lifetime ≤ 180 days**: rotate each client secret with no downtime, for every sign-in app.
3. **Notes** (repo link) on the known apps, and the **instance lock** on "Claude for Outlook".

Rova is not on assignment: see "Why Rova is not on assignment". Rova gets rotation and Notes only.

`hygiene.py` does the work, in your own terminal. Entra calls use your `az` login (an Entra admin). AWS calls use
`--profile qnsc-admin`. Secret values stay in memory and on stdin: never printed, never on a command line, never on disk.
Every write prints its plan and asks `y`. Production writes also ask you to type the app name. Nothing runs in CI.

This folder is in a **public repository**: no tenant, app or object IDs here. Keep any output directory outside the repo.

## Before you start (once)

1. Python 3.10 or newer (`python3 -V`; `brew install python` if older), Azure CLI and AWS CLI v2
   (`brew install azure-cli awscli`).
2. Check AWS: `aws sts get-caller-identity --profile qnsc-admin` must print account `608983206583`.
3. Sign in to Entra with an admin account that can write apps and groups, and that can read the sign-in log
   (Reports Reader or Global Reader):
   ```bash
   az login --tenant <your-tenant>.onmicrosoft.com --allow-no-subscriptions
   ```
4. Run the tests (no tenant needed):
   ```bash
   python3 -m unittest scripts/owner/entra-hygiene/test_hygiene.py -v
   ```
5. **Entra ID P1** is needed for the dynamic groups (`opshub-users`, `kb-users`). `setup` checks for an assigned P1 plan
   and stops if it finds none. The check is a proxy: it looks for an assigned AAD_PREMIUM plan, not your exact license.

Commands take `--product` and `--env`. Environments are `develop` and `production` (the names in the bundles and the
infra stacks). Products: `rova` (develop, production), `opshub` (develop), `kb` (develop). For production add `--prod`.

## Track 1: assignment required (OpsHub and KB, develop first)

Each product gets:

- `<product>-users`: **dynamic**, every internal Member with an enabled account (`user.userType -eq "Member"` and
  `user.accountEnabled -eq true`). OpsHub and KB.
- `kb-guests` (KB only): **assigned**, filled by hand with external guests. OpsHub has no guests group: its sign-in refuses
  B2B guests (`allowGuests: false`), so nobody outside the rule can sign in to it.

### OpsHub only: the App Role `employee` (one-time owner step)

OpsHub's staff sign-in maps Entra App Roles to its own roles. The role `employee` is the ordinary staff role: it grants no
permission, and a user with no App Role gets exactly the same role. So the groups are assigned to the App Role
`employee`, and everyone else keeps any direct assignment they have.

```bash
python3 scripts/owner/entra-hygiene/hygiene.py add-role --product opshub --env develop
```
It adds the role if missing and reads it back. It keeps any App Roles already on the app.

### Steps

1. **Read the current state (read-only):**
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py status --product kb --env develop
   ```
2. **Create the groups and assign them.** Re-running is safe. A group that exists with other settings stops the run.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py setup --product kb --env develop
   ```
3. **KB only: add external guests** to `kb-guests`. If there are none, skip this. OpsHub: skip.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py add-member --product kb --env develop --group kb-guests --upn guest@example.com
   ```
   The lookup also finds guests by their mail address (their UPN is a `#EXT#` address).
4. **Check who would lose access (read-only).** It lists everyone who signed in to the app in the last 30 days and is in
   neither the allowed set. The allowed set is only the app's own assignments: direct user assignments, and members of
   the product groups that are assigned to the app. A group that exists but is not assigned allows nobody.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py check --product kb --env develop
   ```
   Every `WOULD LOSE ACCESS` line must be added (step 3) or be an account that should go. A user who has not signed in
   for 30 days is not listed: ask the product owner for the list of people who should keep access.
5. **Require assignment.** It runs the check again and refuses if anyone is listed.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py enforce --product kb --env develop
   ```
6. **Test:** sign in to the develop product as a staff member; for KB also as a guest in `kb-guests`. Both must work. A tenant
   user in no group must be refused.

**Rollback (one line, at once):**
```bash
python3 scripts/owner/entra-hygiene/hygiene.py rollback --product kb --env develop
```

Then OpsHub the same way (`--product opshub`), after `add-role`. OpsHub has no guests step.

## Why Rova is not on assignment

Decision of the owner, 2026-10-18. `appRoleAssignmentRequired` stays **false** on Rova Dev and Rova Prod, and the audit
finding "any tenant user can sign in" is accepted for those two apps.

- Rova admits its own users. Staff come in through the staff email domain. External users come in only through a live
  invitation or a held home-workspace seat (identity v8), and the app checks that on every sign-in. Entra assignment would
  be a second gate that adds nothing the app does not already enforce.
- Turning assignment on would need the worker to add each invited guest to a group automatically (rova#732). That needs
  `GroupMember.ReadWrite.All` or `AppRoleAssignment.ReadWrite.All`. Both reach every group or every app in the tenant:
  far more reach than the gain. Rejected.
- So `setup`, `add-role`, `add-member`, `check`, `enforce` and `rollback` refuse for `rova`. `status`, `rotate` and `notes`
  still apply. rova#732 is closed with this rationale.

## Track 2: secret rotation (every sign-in app, develop first)

Each sign-in app's client secret is read by its product from one key in the product's bundle:

| Product | Sign-in app | Bundle (Secrets Manager) | Key |
| :--- | :--- | :--- | :--- |
| rova | Rova Dev / Rova Prod | `rova/develop/app` / `rova/production/app` | `entra-client-secret` |
| opshub | OpsHub Dev | `opshub/develop/app` | `entra-client-secret` |
| kb | KB Dev | `qnsc-kb/develop/app` | `microsoft-client-secret` (KB reads it for sign-in and the SharePoint connector) |

Find the ECS services that read the bundle first. The command finds them too, and refuses if you miss one:
```bash
aws ecs list-services --cluster <cluster> --profile qnsc-admin --region ap-southeast-1
```

```bash
python3 scripts/owner/entra-hygiene/hygiene.py rotate --product rova --env develop \
  --cluster <cluster> --services <api-service>,<worker-service> --out-dir ~/entra-hygiene-out
```

Before anything is written, the command:

- reads the bundle and refuses if the key is missing or not a string;
- finds the one Entra secret whose hint matches the bundle's current value (refuses if there is not exactly one);
- scans every service in the cluster and refuses if one reads the bundle but is not in `--services`.

Then it runs, asking `y` at each step:

1. Adds a new secret (180 days) and writes it into the bundle key. It reads the bundle back and refuses unless only that key
   changed. A failed write puts the previous value back and removes the new secret.
2. Restarts the services (rolling). Old tasks keep the old secret until replaced.
3. Checks every consumer: exactly one PRIMARY deployment, created after the bundle write, with running equal to desired.
4. Asks: "Reached <app> signed in as you, in a private window?" Then it looks for your successful sign-in in the log
   (up to about 5 minutes).
5. Removes only the old secret (the one the bundle held). Other secrets are listed and not touched.

**Rollback:** if a consumer check fails, or you answer no at step 4, it restores the previous bundle value, restarts the
services, and removes the new secret. The old secret stays valid until step 5.

**Sign-in log miss:** if you answered yes at step 4 but the log shows no sign-in, nothing is rolled back and nothing is
removed. Both secrets are valid. Wait a few minutes, check the sign-in log for your sign-in, then finish with the command
the rotation prints:
```bash
python3 scripts/owner/entra-hygiene/hygiene.py remove-secret --product rova --env develop --key-id <old keyId>
```
It refuses the secret the bundle holds now. Run it only once your sign-in is in the log.

**Before rotating KB Dev, warn developers.** The KB Dev secret is also in developers' local `.env` files
(`docs/runbooks/entra-apps.md` in qnsc-kb-backend, "Local development", step 5). Local sign-in stops working once the old
secret is removed. Tell them when rotation happens, and have each set the new value from the bundle.

For production, add `--env production --prod`. It also asks you to type the app name (`Rova Prod`), before anything is
written.

It writes `rotate-<app>.ics` into `--out-dir`: an event on the day the next rotation is due, 30 days before the new expiry.
Add it to your calendar.

## Track 3: Notes and the Claude for Outlook lock

Notes (repo link on every known app; existing text is kept unless `--force`):
```bash
python3 scripts/owner/entra-hygiene/hygiene.py notes
```

Instance property lock on "Claude for Outlook" (reads the app back to confirm):
```bash
python3 scripts/owner/entra-hygiene/hygiene.py lock-app --name "Claude for Outlook"
```
If it fails with "no application named", the app is registered in another tenant, and the lock can only be set there.
Tell the architect.

## Decisions the owner must confirm

- **Who keeps access.** `opshub-users` and `kb-users` default to every enabled internal Member. Confirm for KB: the KB
  user population was not known when this was written.
- **Guests of KB:** who goes into `kb-guests`, before enforcing. OpsHub has none.
- **OpsHub:** the App Role `employee` (step above).
- **Claude for Outlook:** its repo for the Notes field, and whether it is in this tenant.
- **Production.** Track 1 and Track 2 for production only after the owner's "go" and a green develop run.

## What was not verified

- Nothing has run against the real tenant, AWS or ECS. The tests use fake Graph, AWS and ECS. Graph payloads, the lock
  body (`servicePrincipalLockConfiguration`), the sign-in log filters and the ECS output shapes follow the documented
  schemas. Check each by reading the output of `status`, `check`, `lock-app` and the rotation's own checks.
- **OpsHub `employee` mapping** was verified by reading the code only (`staff-sign-in.handler.ts`,
  `authz-admin.service.ts` `syncUserRolesByKeys`, `db/seed.ts`): `employee` is a system role with no permissions, and the
  sign-in falls back to it when no claim matches, so a token with `employee` and a token with no role give the same
  roles. The opshub test suite was not run for this.
- Sign-in logs keep 30 days on P1/P2 and 7 days on the free tier. Check can miss a user who signed in longer ago.
- Other consumers of the sign-in secret outside the ECS services are not scanned: KB developers' local `.env` (see above),
  a CI job, a Pages function. Confirm none before rotating.
- KB production is not configured here. Its bundle is `qnsc-kb/prod/app` (per the KB runbook), and it is not in this tool.
- ECS cluster and service names, and the KB user population, are owner inputs.
