# live/identity

Entra ID + Azure Key Vault for the whole platform, plus the two CI workload
identities (§7.4). The first apply happens AT THE OPERATOR'S LAPTOP — the
state backend and budget it imports were created by hand (pre-work (e)); CI
takes over from the second apply on.

## Owns

- `rg-qnsc-platform`, the four Key Vaults (`kv-qnsc-{prod,dev,platform,admin}`)
  with §7.1 properties (RBAC auth, 90-day soft delete, purge protection on
  prod/platform/admin), the `qnsc-platform-monthly` $10 budget alert.
- The state backend `stqnsctfstate` + `tfstate` container (imported; shared
  keys OFF, so the backend authenticates with Entra — `use_azuread_auth`,
  versions.tf).
- The CI identities "QNSC CI Infra" (apply) / "QNSC CI Infra Read" (plan):
  GitHub OIDC only, client IDs as outputs — no secrets.
- Phase 1: the Entra groups, ESO/CI/Backup SP apps with certificate auth,
  product sign-in app redirect URIs, vault RBAC.

## Auth (no client secrets anywhere)

- **CI**: the workflow exports `ARM_USE_OIDC=true` (GitHub OIDC federation via
  the two identities above) and the subscription ID. The backend is configured
  from the `backend` block plus those env vars; nothing OIDC-specific is
  hardcoded in the stack.
- **Operators**: `az login` first — both providers and the backend pick up the
  Azure CLI session.

## First apply, at the operator's laptop

Public repository: every `<placeholder>` below is filled in at the terminal,
never committed.

1. Sign in against the tenant and select the platform subscription:

   ```sh
   az login --tenant <tenant-domain>
   az account set --subscription <subscription-id>
   ```

2. Verify the hand-created backend and grant yourself the one backend role
   (idempotent — safe to re-run):

   ```sh
   ../../scripts/owner/bootstrap-state.sh <operator-upn>
   ```

3. Export the variables the stack needs (values stay in your shell):

   ```sh
   export TF_VAR_subscription_id=<subscription-id>
   export ARM_SUBSCRIPTION_ID=$TF_VAR_subscription_id   # tofu init (backend) reads this one
   export TF_VAR_budget_period_start=2026-10-01         # first day of the month the subscription was created
   export TF_VAR_break_glass_upn_domain=<tenant-primary-domain>
   ```

4. Init, plan, apply. The plan performs the four `import` blocks in `imports.tf`
   (resource group, storage account, `tfstate` container, budget) and creates
   the four vaults + two CI identities and their role assignments:

   ```sh
   tofu init
   tofu plan     # MUST show the imports and new resources — and NO change on any imported resource
   tofu apply
   ```

   **If the plan proposes a change (update/replace) on an imported resource,
   STOP.** Reconcile the code to the imported value in a reviewed PR instead of
   applying — the resource being changed is the thing holding every state file.

5. Record the two client IDs from the outputs, then set the GitHub repo
   variables CI needs for the later OIDC wiring (repo **variables**, values are
   public identifiers):

   - `AZURE_CLIENT_ID` = `ci_infra_apply_client_id`
   - `AZURE_CLIENT_ID_READ` = `ci_infra_read_client_id`
   - `AZURE_TENANT_ID` = `<tenant-id>`

   The workflows still list `identity` as NOT_PLANNABLE until a follow-up PR
   exports `ARM_USE_OIDC=true` and removes it from that list — CI does not plan
   or apply this stack yet.

## Never does

- Holds no secret values. Certificates are attached by public half; tokens and
  keys are piped into the vaults through stdin by the operator, with expiry and
  `owner`/`rotate-by` tags (§7.5).
