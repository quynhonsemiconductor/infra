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

Required repository secrets (owner, add once):

- `IDENTITY_OWNER_OPERATOR_UPN`
- `IDENTITY_SECOND_OWNER_UPN`
- `IDENTITY_PROXMOX_HOST`
- `IDENTITY_PBS_HOST`

The kit stops (it never guesses) if one is missing, an app name is ambiguous, a credential is
unpinned, or a mail certificate differs from the one on the app. A kit stop exits non-zero and
leaves no plan file, which the workflow reports as `class=1` — not as a clean run.

## Triage order

1. Read the run summary: it names the stack and which pass failed.
2. External drift → decide adopt / revert / ignore, then reconcile the code.
3. Unapplied config → find the merged PR that added it and run the stack's apply.
4. An errored pass (exit 1) is never a pass: a detector that cannot run is a detector that knows
   nothing.
