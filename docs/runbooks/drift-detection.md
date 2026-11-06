# Nightly drift detection: how to read a red run

`.github/workflows/drift-detection.yml` runs at 07:30 ICT. Per stack it runs TWO passes:

1. **external drift** (`tofu plan -refresh-only`) — reality moved away from state;
2. **unapplied config** (`tofu plan`) — main moved away from reality (an apply that never ran).

Exit 2 on either pass fails the stack; the alert job opens/updates the `drift-detection` issue
and posts to the platform Teams channel. `identity` is in the matrix too (see below).

## The read-only Cloudflare token

Every Cloudflare stack (edge, storage-dev, storage-prod, onprem) plans with
**`CLOUDFLARE_API_TOKEN_READONLY`** — a repository secret. It must be a READ-ONLY token; the
write token the apply job uses must never reach a scheduled PR-less run. Required scopes:

- Zone:Read
- DNS:Read
- Zone WAF:Read (rulesets)
- Account: Cloudflare Pages:Read
- Workers R2 Storage:Read
- Turnstile:Read

If the secret is missing or resolves empty, the run fails at "Require the read-only Cloudflare
token" with that message; it never falls back to the write token. To check the secret exists
without reading it: `gh secret list -R quynhonsemiconductor/infra | grep CLOUDFLARE_API_TOKEN_READONLY`.

## 2026-11-03 → 11-05: the three red nights

The audit line "missing token" did NOT match the run. In run 41985292188 (2026-11-05) the token
step reported `HAVE_TOKEN: true` and every Cloudflare resource refreshed, so the token was
present; the red came from **plan exit 2** on two stacks:

| Stack | Pending change | Fix |
|---|---|---|
| edge | `cloudflare_pages_project.landing` — `build_config` / `build_image_auto_upgrade` re-planned `(known after apply)` | Fixed by infra#403 (codified `build_config`, merged 2026-11-05T10:28Z, i.e. AFTER that morning's 00:30Z run). The next edge apply clears it. |
| onprem | `cloudflare_r2_bucket_lock.qnsc_backups` — the `lock-pg-kb-14d` rule (infra#208) was never applied | Apply onprem. The rule locks nothing until the kb CNPG cluster exists. |

Both are "unapplied config" (pass 2), not external drift: nothing was changed by hand.
After the applies, the next scheduled run should be green. If it is still red, read the run
summary: it prints which pass failed and tails the plan (except identity, below).

## 2026-11-06: still two red stacks, two different causes

Run 42179043406 (main `275f1f7`):

| Stack | Pass | Cause |
|---|---|---|
| edge | unapplied config (exit 2) | `cloudflare_pages_project.landing` → `build_image_auto_upgrade = (known after apply)`: a provider-computed attribute, still pending because the edge apply of #427 was **cancelled** (2026-11-06T08:45Z). The last green edge apply is `c529c85` (#413, 2026-11-05T16:24Z). Run the edge apply; if the attribute keeps re-planning after it, it is a provider artifact and belongs in `ignore_changes`, not in a nightly red. |
| identity | both passes (exit 1) | all six `IDENTITY_*` inputs were empty (the run's env block lists them blank); the kit stopped. Nothing about the tenant was wrong. |

The edge Cloudflare token was **present** in that run (`HAVE_TOKEN: true`, and the
plan refreshed every Cloudflare resource). The "Drift cannot see Cloudflare" text in
the log is the step's *script*, printed before the step body runs — not an error.
Reading it as an error sent the 2026-11-06 audit down the wrong path once; the
authoritative signals are `HAVE_TOKEN:` in the step env and plan exit codes.

Tagging a secret as "missing" from a run: compare the run's step env block (it
prints `HAVE_TOKEN: true|false` and blank env values) with `gh secret list -R …`.
Never conclude from a line that appears without `##[error]` on it.

## identity

`live/identity` is never planned in `infra-plan.yml` (owner-only: the plan names break-glass
accounts and the Entra role layout). The nightly job DOES run both passes for it, with the same
read identity (`Directory Readers` can read app/group metadata and credential DATES, never
values), through the owner apply kit:

- the kit builds every required `TF_VAR_*` from read-only `az` lookups, so no id lives in Git;
- both passes write to `live/identity/refresh.txt` / `plan.txt` and **never to the log or the step
  summary**;
- the destructive-guard classifier is **skipped for identity**: its `drift_report.py` prints drifted
  resource addresses, and the identity `for_each` keys are user/app object ids. A red identity stack
  (exit 2) shows one "details withheld" line and nothing else; run
  `scripts/owner/identity-env/identity-env.sh -- tofu plan` locally to see it.

Required inputs (owner, add once). Everything below is a **repository-level
secret or variable**; the identity job declares no `environment:`, so
`gh secret list --env production` will never show them — that is not a missing
secret.

| Name | Kind | Why the identity plan needs it |
|---|---|---|
| `AZURE_CLIENT_ID_READ` | repo **variable** | OIDC app the job logs in as (already set; the same read identity as the other stacks) |
| `ENTRA_TENANT_ID` | repo **variable** | its tenant (already set) |
| `IDENTITY_OWNER_OPERATOR_UPN` | secret | the owner operator behind `TF_VAR_owner_operator_object_id`. A CI run has no signed-in user, so the kit cannot fall back to `az`'s account |
| `IDENTITY_SECOND_OWNER_UPN` | secret | the second company owner (`TF_VAR_second_owner_object_id`); no default, the kit stops without it |
| `IDENTITY_PROXMOX_HOST` | secret | PVE admin door hostname → the Proxmox app's `https://<host>/` redirect URI |
| `IDENTITY_PBS_HOST` | secret | PBS admin door hostname → the second redirect URI (must differ from PVE's) |
| `IDENTITY_DEV_APP_EXTRA_OWNERS` | secret | the hand-added owners of the DEV sign-in apps (`app=upn,...`). `live/identity` owns those owner sets now; unset, the plan proposes **removing** live owners → exit 2 |
| `IDENTITY_DEV_APP_EXTRA_ADMINS` | secret | the hand-added holders of the OpsHub Dev `admin` app role (the 2026-08-31 testers, adopted by infra#426). Unset, the plan proposes **removing** those live assignments → exit 2 |

The last two are "optional" to the kit and **required for a green nightly run**.
If the intent is to drop those owners/admins, run the plan locally, apply the
removal deliberately, and only then leave the secrets unset.

Set them without leaking a value — no `--body`, no value in the shell history or
in `ps` (argv is visible to every process on the machine):

```bash
# 1) type it at the prompt (gh reads stdin, never echoes with a TTY)
gh secret set IDENTITY_SECOND_OWNER_UPN -R quynhonsemiconductor/infra

# 2) or pipe it from the password manager's clipboard — nothing lands in history
pbpaste | gh secret set IDENTITY_PROXMOX_HOST -R quynhonsemiconductor/infra

# repeat for OWNER_OPERATOR_UPN, PBS_HOST, DEV_APP_EXTRA_OWNERS, DEV_APP_EXTRA_ADMINS
```

These are **repo** secrets on purpose: do not create them at the organisation
level (the org secret would be readable by every repo the job runs in, and this
one is only needed here).

Verify without reading values:

```bash
gh secret list -R quynhonsemiconductor/infra | grep IDENTITY_
```

A name in that list means "a secret exists", **not** "it has a value" — a secret
created with empty input lists the same way. The workflow's
"Identity drift inputs present" step is the real test: it fails with the exact
list of empty names before the kit runs.

The kit stops (it never guesses) if one is missing, an app name is ambiguous, a
credential is unpinned, or a mail certificate differs from the one on the app. A kit stop exits non-zero and
leaves no plan file, which the workflow reports as `class=1` — not as a clean run.

## Triage order

1. Read the run summary: it names the stack and which pass failed.
2. External drift → decide adopt / revert / ignore, then reconcile the code.
3. Unapplied config → find the merged PR that added it and run the stack's apply.
4. An errored pass (exit 1) is never a pass: a detector that cannot run is a detector that knows
   nothing.
