# Entra sign-in app hygiene (owner runbook)

Fixes the four findings of the 2026-10-18 audit (`scripts/entra-audit`) for the sign-in apps:

1. **Assignment required**: only people in the right groups can sign in (`appRoleAssignmentRequired = true`). OpsHub and KB only; Rova is excluded, see "Why Rova is not on assignment".
2. **Secret lifetime ≤ 180 days**: rotate each client secret with no downtime.
3. **Notes**: the repo link on every known app. **Lock** on "Claude for Outlook".

`hygiene.py` does the work. You run it in your own terminal. It makes Entra calls with your `az` login (an Entra admin)
and AWS calls with `--profile qnsc-admin`. It never prints a secret value, takes secrets only from memory or stdin, and
asks `y` before every write. Nothing here runs in CI.

This folder is in a **public repository**, so it holds no tenant, app or object IDs. Keep any output directory outside
the repo.

## Before you start (once)

1. Python 3.10 or newer: `python3 -V`. Install with `brew install python` if older.
2. Azure CLI and AWS CLI v2: `brew install azure-cli awscli`.
3. Check the AWS profile works: `aws sts get-caller-identity --profile qnsc-admin` must print account `608983206583`.
4. Sign in to Entra with an admin account that can write apps and groups (Application Administrator and Groups
   Administrator, or Global Administrator). Sign-in logs need Reports Reader or Global Reader too:
   ```bash
   az login --tenant <your-tenant>.onmicrosoft.com --allow-no-subscriptions
   ```
5. Run the tests once (no tenant needed):
   ```bash
   cd <your clone of infra>
   python3 -m unittest scripts/owner/entra-hygiene/test_hygiene.py -v
   ```
6. Check the license. Dynamic groups (`opshub-users`, `kb-users`) need **Microsoft Entra ID P1** or better.
   If the tenant does not have it, tell the architect before running `setup`; the fallback is an assigned group filled by
   hand (see the decisions list below).

Every command below takes `--product` and `--env`. The known products are `rova` (dev, prod), `opshub` (dev), `kb` (dev). For `rova`, only `rotate` and `notes` apply.

## Track 1: assignment required (OpsHub and KB, dev first)

Rova is not in this track. See "Why Rova is not on assignment" below. Each product gets two groups: `<product>-users` (dynamic: every licensed internal Member) and `<product>-guests` (assigned: filled by hand).

For each product, in this order. Prod (`--env prod`) is a separate decision, do it only after the owner's "go".

1. **Read the current state (read-only):**
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py status --product kb --env dev
   ```
2. **Create the groups and assign them to the app.** Asks `y` once. Re-running is safe.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py setup --product kb --env dev
   ```
   If it stops with "defines app roles", the app has its own roles. Stop and tell the architect; this helper assigns
   default access only.
3. **Add the people who need access but are outside the dynamic rule**, usually external guests. One command per
   person, into the assigned `<product>-guests` group:
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py add-member --product kb --env dev --group kb-guests --upn guest@example.com
   ```
   If there are none, skip this step.
4. **Check who would lose access (read-only).** It lists everyone who signed in to the app in the last 30 days and is in
   neither a group nor a direct assignment. Wait a few minutes after `setup` so dynamic groups fill in, then:
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py check --product kb --env dev
   ```
   Every `WOULD LOSE ACCESS` line must be either added (step 3) or an account that should go. The check reads 30 days of
   sign-ins. A user who has not signed in for longer is not listed: ask the product owner for the list of people who
   should keep access, and add them by hand.
5. **Require assignment.** It runs the check again and refuses if anyone is listed.
   ```bash
   python3 scripts/owner/entra-hygiene/hygiene.py enforce --product kb --env dev
   ```
6. **Test it:** sign in to the dev product as a staff member, and as a guest in `kb-guests`. Both must work. Sign in as a
   tenant user who is in no group; that user must be refused.

**Rollback (one line, takes effect at once):**
```bash
python3 scripts/owner/entra-hygiene/hygiene.py rollback --product kb --env dev
```

## Why Rova is not on assignment

Decision of the owner, 2026-10-18. `appRoleAssignmentRequired` stays **false** on Rova Dev and Rova Prod, and the audit
finding "any tenant user can sign in" is accepted for those two apps.

- Rova admits its own users. Staff come in through the staff email domain. External users come in only through a live
  invitation or a held home-workspace seat (identity v8), and the app checks that on every sign-in. Entra assignment would
  be a second gate that adds nothing the app does not already enforce.
- Turning assignment on would need the worker to add each invited guest to a group automatically (rova#732). That needs
  `GroupMember.ReadWrite.All` or `AppRoleAssignment.ReadWrite.All`. Both reach every group or every app in the tenant:
  far more reach than the gain. Rejected.
- Rova is therefore excluded here: `setup`, `add-member`, `check`, `enforce` and `rollback` refuse for `rova`.
  `status`, `rotate` and `notes` still apply to Rova Dev and Rova Prod.
- rova#732 is closed with this rationale.

## Track 2: secret rotation (dev first)

Each sign-in app holds one client secret, read by the product's API and worker from the bundle key
`entra-client-secret`. The rotation adds a second secret, writes it to the bundle, restarts the services, verifies
sign-in, and only then removes the old secret. The old secret stays valid until the last step, so there is no downtime.

Run it once per app (`Rova Dev`, `OpsHub Dev`, `KB Dev`, then `Rova Prod` after the go). You need the ECS cluster and the
service names that read the bundle. Ask the architect if you do not have them, and check them first:
```bash
aws ecs list-services --cluster <cluster> --profile qnsc-admin --region ap-southeast-1
```

```bash
python3 scripts/owner/entra-hygiene/hygiene.py rotate --product rova --env dev \
  --cluster <cluster> --services <api-service>,<worker-service> \
  --out-dir ~/entra-hygiene-out
```

The command asks, in order:

1. Add the new secret (180 days) and write it to the bundle. The new value goes straight from Entra to the bundle
   through stdin. It is never shown.
2. Restart the services (rolling). Old tasks keep the old secret until replaced.
3. Sign in to the dev product **now** in a browser. Then answer `y` to "Did sign-in work?". The command looks for a
   successful sign-in in the log for up to 5 minutes.
4. Remove the old secret. Only after step 3 passes.

If the sign-in does not show up, the command **rolls back**: it restores the previous bundle value, restarts the
services, and removes the new secret. The old secret is untouched.

It writes a calendar file `rotate-<app>.ics` into `--out-dir`. The event is on the day the next rotation is due: 30 days
before the new expiry. Open the file to add it to your calendar. Do the same for each app.

## Track 3: Notes and the Claude for Outlook lock

Notes (repo link on every known app; existing text is kept unless `--force`):
```bash
python3 scripts/owner/entra-hygiene/hygiene.py notes
```

The instance property lock on "Claude for Outlook" (it reads the app back to confirm):
```bash
python3 scripts/owner/entra-hygiene/hygiene.py lock-app --name "Claude for Outlook"
```
If the app is registered in another tenant, this fails with "no application named". That is expected: the lock can only
be set in the tenant that owns the registration. Tell the architect in that case.

## Decisions the owner must confirm

- **Who keeps access.** `opshub-users` and `kb-users` default to every licensed internal Member. Confirm
  this for KB: the KB user population was not known when this was written.
- **Guests of OpsHub and KB**: who goes into `<product>-guests`, before enforcing.
- **Claude for Outlook**: its repo for the Notes field, and whether it is in this tenant.
- **Prod.** Track 1 and Track 2 for `--env prod` only after the owner's "go" and a green dev run.

## What was not verified

- Nothing here has run against the real tenant. The tests use a fake Graph and a fake AWS, so the Graph paths and
  payloads (for example the instance-lock body, `servicePrincipalLockConfiguration`) are from Microsoft's documented
  schema and must be checked by reading the result of `status` and `lock-app`.
- Sign-in logs keep 30 days on P1/P2 and 7 days on the free tier. Check can miss a user who signed in longer ago.
- The ECS names and the KB user population are not in this repo; the owner supplies them.
