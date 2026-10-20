# live/identity

Entra ID + Azure Key Vault for the whole platform. **Skeleton — applies
nothing yet**: the subscription does not exist (pre-work (e)). `tofu plan`
against this stack only works once `stqnsctfstate` is created by hand and CI
holds the two OIDC identities ("QNSC CI Infra" / "QNSC CI Infra Read").

## Owns

- `rg-qnsc-platform`, the four Key Vaults (`kv-qnsc-{prod,dev,platform,admin}`)
  with §7.1 properties (RBAC auth, 90-day soft delete, purge protection on
  prod/platform/admin), the $10 budget alert.
- Phase 1: the Entra groups, ESO/CI/Backup SP apps with federated credentials
  or certificate auth, product sign-in app redirect URIs, vault RBAC.
- Import target for `stqnsctfstate` (hand-created, never TF-created).

## Never does

- Holds no secret values. Certificates are attached by public half; tokens and
  keys are piped into the vaults through stdin by the operator, with expiry and
  `owner`/`rotate-by` tags (§7.5).
