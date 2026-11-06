# Separate Entra admin accounts (hardening decision 7)

Owner guide, 2026-11-06. Read-only status audit:
`sa-notes/reviews/hardening-status-2026-11-06.md`.

## Why

A Global Administrator must never be the account that reads mail, browses the
web and installs browser extensions. Today the tenant has four GA holders:

| Account | Kind | Today |
| --- | --- | --- |
| the owner's daily work account | **daily** | Global Administrator |
| the second admin's daily work account | **daily** | Global Administrator |
| `bg1` (initial `*.onmicrosoft.com` domain) | break-glass | Global Administrator |
| `bg2` (initial `*.onmicrosoft.com` domain) | break-glass | Global Administrator |

The decision: create cloud-only `<name>-admin` accounts on the tenant's verified domain, move Global
Administrator onto them, remove it from the daily accounts, keep `bg1`/`bg2`.
No Conditional Access is possible (it needs Entra ID P1, which the tenant does
not have), so **Security Defaults** is the only MFA enforcement — §5 verifies it
is actually on.

## 1. Prepare (5 minutes, no change yet)

1. Open 1Password → vault `QNSC` → create item `Entra admin – <name>` for each
   new account. Put nothing in it until §2 step 4.
2. Confirm you can sign in as **bg1** right now (it is the safety net for this
   whole procedure; its password and TOTP are in 1Password). If you cannot,
   stop and fix that first.
3. Do this outside a change window: nothing breaks mid-way, but a half-finished
   move leaves one daily account with GA.

## 2. Create the admin accounts

Portal: <https://entra.microsoft.com> → **Users → New user → Create new user**
(cloud-only; do **not** invite a guest, do **not** sync from on-prem).

For each of the two people:

1. **User principal name**: `<firstname>adm@<tenant-domain>` (for example
   `aaadm` and `bbadm` on the same verified domain). Keep it recognisable as an
   admin identity, and do not reuse the daily account's mailbox alias.
2. **Display name**: `<Full name> (admin)`.
3. **Password**: auto-generate; copy it straight into the 1Password item from
   §1. Tick "Require this user to change their password on first sign-in".
4. **Properties → Usage location**: set it (e.g. Vietnam). Not strictly needed
   without a licence, but it keeps the account valid for future licences.
5. **Licenses**: assign **none**. An admin account needs no Microsoft 365
   licence to administer the tenant, and a licence would give it a mailbox and
   an attack surface we do not want.
6. **Groups**: add to no group. Group memberships are for people, not for the
   admin identity.

Do not use these accounts for daily work — no Teams, no mail, no browsing.

## 3. Move Global Administrator

1. Sign in **as the new admin account** once, in a private window. Security
   Defaults forces MFA registration: register Microsoft Authenticator (the only
   method Security Defaults allows) and store the TOTP seed in the 1Password
   item.
2. Sign back in as your daily account (or bg1), then
   **Entra ID → Roles & admins → Global Administrator → Add assignments** →
   add the two new admin accounts.
3. **Verify before removing anything**: sign in as each new admin account and
   confirm the Entra portal loads with the Global Administrator role shown on
   the account.
4. Only then: **Global Administrator → Assignments** → select the owner's
   daily account → **Remove assignment**. Repeat for the second admin's daily
   account.
5. Leave `bg1` and `bg2` exactly as they are (break-glass, excluded from daily
   use).

## 4. Verify (read-only, 1 minute)

```bash
RID=$(az rest --method get --url 'https://graph.microsoft.com/v1.0/directoryRoles' \
  --query "value[?displayName=='Global Administrator'].id" -o tsv)
az rest --method get --url "https://graph.microsoft.com/v1.0/directoryRoles/$RID/members?\$select=userPrincipalName" \
  --query 'value[].userPrincipalName' -o tsv | sort
```

Expected: the two `<name>adm` accounts, `bg1`, `bg2` — and **no daily
account**. The Application Administrator role must stay empty (it had no members
at the 2026-11-06 audit; the same query with
`displayName=='Application Administrator'` should return nothing).

## 5. Verify Security Defaults is ON (this is the MFA control)

There is no Conditional Access without P1, so if Security Defaults is off, the
tenant has **no enforced MFA** and the only thing protecting these admin
accounts is their password. Do not skip this.

Portal path: **Entra ID → Overview → Properties → Manage security defaults**
(also reachable as <https://entra.microsoft.com> → Identity → Overview →
Properties). The toggle must read **Enabled**.

What "Enabled" gives us (and what it does not):

| Security Defaults enforces | Notes |
| --- | --- |
| MFA registration for all users, 14-day grace | Microsoft Authenticator only (no SMS/voice on Free) |
| MFA required for all admins at every sign-in | the rule this procedure depends on |
| MFA challenge for risky sign-ins / unfamiliar devices | risk detections available on Free are basic |
| Legacy authentication blocked | IMAP/POP/SMTP AUTH, older Office clients |
| MFA for Azure portal / CLI / PowerShell | — |
| **Not** included | Conditional Access, PIM, sign-in log export, custom MFA methods. Those need P1/P2. |

If the toggle is **Disabled**: re-enable it, then sign out and back in as each
admin account to confirm the MFA prompt appears. Record the date of the check in
the platform Teams channel; nobody else can see this setting.

This was one open item in the 2026-11-06 audit (the SA's read token lacks
`Policy.Read.All`, so it could not verify the setting). The portal check above is
the closing evidence.

## 6. Rollback

If an admin account cannot be used (lost authenticator before a second method
exists): sign in as `bg1`, add the Global Administrator role back to the daily
account, sign in with it, and repair the admin account. `bg1`/`bg2` are never
removed, which is what makes this recoverable.

## 7. Known limitations to accept

- **No mailbox on the admin accounts.** Password-reset notifications and
  security alerts go to the daily account (the account that owns the contact
  details). Keep the admin account's alternate email set to the person's daily
  address so account recovery works.
- **No PIM.** The role is standing, not eligible/time-bound. That is the P1
  boundary; revisit when the budget allows.
- **Personal owners of app registrations** are a separate item from the
  drift audit (`sa-notes/reviews/iac-drift-audit-2026-11-06.md` §1a); this guide
  does not change app ownership.
- Break-glass accounts stay on the initial `*.onmicrosoft.com` domain on
  purpose (never a custom domain the tenant could lose).
