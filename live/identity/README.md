# live/identity

Entra ID + Azure Key Vault for the whole platform, plus the two CI workload
identities (§7.4). **This stack is applied ONLY by the owner, locally, with
their own `az login` — every plan and every apply, not just the first.** CI
neither plans nor applies it. The repository is public, and plan output (PR
comments, Actions logs) would publish the break-glass UPNs and the Entra role
layout, so the owner runs `tofu plan` and `tofu apply` locally. An identity
able to apply this stack could grant itself any role in the tenant, so no CI
identity is given that ability.

## Owns

- `rg-qnsc-platform`, the four Key Vaults (`kv-qnsc-{prod,dev,platform,admin}`)
  with §7.1 properties (RBAC auth, 90-day soft delete, purge protection on
  prod/platform/admin), the `qnsc-platform-monthly` $10 budget alert.
- The state backend `stqnsctfstate` + `tfstate` container (imported; shared
  keys OFF, so the backend authenticates with Entra — `use_azuread_auth`,
  versions.tf).
- The CI identities, GitHub OIDC only, client IDs as outputs — no secrets:
  - "QNSC CI Infra" (apply of the OTHER stacks, environment `production`):
    Contributor (subscription) + Storage Blob Data Contributor
    (`stqnsctfstate`). NO Entra directory role, NO User Access Administrator.
  - "QNSC CI Infra Read" (plan/drift): Directory Readers (Entra), Reader
    (subscription), Storage Blob Data Reader (`stqnsctfstate`), Key Vault
    Reader (metadata only).
    TODO: the Directory Readers role is kept for drift tooling run privately
    or in future; if nothing uses it, remove it.
- Phase 1: the Entra groups, ESO/CI/Backup SP apps with certificate auth,
  product sign-in app redirect URIs, vault RBAC.

## Auth (no client secrets anywhere)

- **CI: none for this stack.**
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

   Azure leaves `publicNetworkAccess` unset on the hand-created account, while
   azurerm 5.x plans `"" -> "Enabled"` for it. The script prints the fix if it
   sees that; run it once (idempotent, no behaviour change) so the first plan
   is clean:

   ```sh
   az storage account update -g rg-qnsc-platform -n stqnsctfstate --public-network-access Enabled
   ```

3. Export the variables the stack needs (values stay in your shell):

   ```sh
   export TF_VAR_subscription_id=<subscription-id>
   export ARM_SUBSCRIPTION_ID=$TF_VAR_subscription_id   # tofu init (backend) reads this one
   export TF_VAR_budget_period_start=2026-10-01T00:00:00Z  # RFC3339, copy from the live budget (bootstrap script prints it)
   export TF_VAR_budget_period_end=2028-09-30T00:00:00Z    # RFC3339, the hand-created budget's end (must match Azure exactly)
   export TF_VAR_break_glass_upn_domain=<tenant-primary-domain>
   ```

4. Init, plan, apply. The plan performs the four `import` blocks in `imports.tf`
   (resource group, storage account, `tfstate` container, budget) and creates
   the four vaults, the break-glass users/group, the two CI identities and
   their role assignments:

   ```sh
   tofu init
   tofu plan     # go/no-go below
   tofu apply
   ```

   **Go/no-go — the first owner plan must read exactly: 4 to import (each
   "no changes"), 23 to add, 0 to change, 0 to destroy, 0 to replace.**
   (These 23 cover the vaults, break-glass and CI identities ONLY. The Phase-1
   PRs — ESO SPs, vault RBAC, sign-in apps — are SEPARATE applies with their
   own expected counts, stated in their sections below; never mix them into
   this first apply.)
   Anything else on an imported resource (an update or a replace on the
   resource group, storage account, container or budget) is NO-GO: STOP and
   reconcile the code to the live value in a reviewed PR instead of applying —
   the resource being changed is the thing holding every state file.

5. Record the two client IDs from the outputs, then set the GitHub repo
   variables CI needs for the later OIDC wiring (repo **variables**, values are
   public identifiers):

   - `AZURE_CLIENT_ID` = `ci_infra_apply_client_id`
   - `AZURE_CLIENT_ID_READ` = `ci_infra_read_client_id`
   - `AZURE_TENANT_ID` = `<tenant-id>`

   The variables still serve other stacks and later OIDC use. `identity` stays
   NOT_PLANNABLE in `infra-plan.yml` on purpose (public repo, see the top of
   this file), so CI never plans this stack. Every change is `tofu plan` and
   `tofu apply` by the owner, locally.

## Residual risk

"QNSC CI Infra" (Contributor + Storage Blob Data Contributor on `stqnsctfstate`)
can WRITE the blob `infra/identity/terraform.tfstate`, i.e. tamper with this
stack's state even though it cannot apply the stack. Follow-up: replace the
account-wide Blob Data Contributor with an ABAC condition that excludes
`infra/identity/*` (and give the Read identity the same view it has today).

## Never does

- Holds no secret values. Certificates are attached by public half; tokens and
  keys are piped into the vaults through stdin by the operator, with expiry and
  `owner`/`rotate-by` tags (§7.5).

## Phase 1: ESO SP certificates + vault data-plane RBAC (§7.1)

`vault_rbac.tf` + `eso.tf` add, per store in gitops `platform/eso/stores-onprem.yaml`
(dev, prod, platform — none for `kv-qnsc-admin`):

- one Entra app + service principal `QNSC ESO <Env>`, **certificate-only** (no
  password credential exists — `tests/static.sh` fails the tree if one appears);
- `Key Vault Secrets User` for that SP, scoped to **its own vault only**;
- `Key Vault Secrets Officer` for `grp-qnsc-platform-admins` on **all four**
  vaults (the operator writes every secret through stdin).

Owner steps, per SP (`dev` shown; repeat with `prod`, `platform`):

1. Generate the keypair and a self-signed certificate (RSA 2048, ≤ 12 months)
   **locally, outside the repo**, in a directory only you can read:

   ```sh
   mkdir -p ~/keys && cd ~/keys && umask 077
   openssl req -x509 -newkey rsa:2048 -nodes \
     -keyout eso-dev-key.pem -out eso-dev-cert.pem \
     -days 365 -subj '/CN=QNSC ESO Dev'
   # the COMBINED PEM (certificate + private key concatenated) is what ESO's
   # tls.pem reads (stores-onprem.yaml) — store it in 1Password, then shred
   # the private half:
   cat eso-dev-cert.pem eso-dev-key.pem > eso-dev-combined.pem
   # (file eso-dev-combined.pem into 1Password first, then:)
   rm eso-dev-key.pem
   ```

2. Run the static guard (plan-free; asserts certificate-only auth and
   vault-scope-only RBAC). CI runs the same script on every PR as a step of
   the `tofu fmt check` job in `infra-plan.yml`:

   ```sh
   sh live/identity/tests/static.sh
   ```

3. Pass the PUBLIC certs and the group id as environment (`*.tfvars` and state
   are git-ignored for values; the private keys never touch the repo or state):

   ```sh
   export TF_VAR_platform_admins_object_id=$(
     az ad group show --group grp-qnsc-platform-admins --query id -o tsv)
   export TF_VAR_eso_certificates=$(jq -n \
     --rawfile dev ~/keys/eso-dev-cert.pem \
     --rawfile prod ~/keys/eso-prod-cert.pem \
     --rawfile platform ~/keys/eso-platform-cert.pem \
     '{dev:$dev, prod:$prod, platform:$platform}')
   ```

4. Plan and apply as above (owner-local only). The plan adds 3 applications,
   3 certificates, 3 service principals, 4 Secrets Officer + 3 Secrets User
   assignments — nothing wider.

5. Record `eso_client_ids` from the outputs. At bootstrap (§14 step 2, after
   the cluster exists) hand-apply each store's Secret — one COMBINED PEM per
   SP, the shape `stores-onprem.yaml` reads:

   ```sh
   kubectl -n external-secrets create secret generic qnsc-eso-dev-cert \
     --from-file=tls.pem=$HOME/keys/eso-dev-combined.pem \
     --from-literal=client-id=<eso_client_ids.dev>
   # same shape for qnsc-eso-prod-cert / qnsc-eso-platform-cert
   rm ~/keys/eso-*-combined.pem   # after 1Password holds it and the Secret is applied
   ```

Rotation (≤ 12 months): issue a NEW keypair, `tofu apply` the new public cert
(`create_before_destroy` — the new credential exists before the old one is
removed), THEN re-apply the cluster Secret from the new combined PEM. Between
apply and the Secret swap ESO authentication fails for that store — downtime is
acceptable; dev secrets are re-issuable. The old credential is removed by the
same apply, immediately after the new one is created, so the swap is the very
next step.
