# live/onprem-oidc

The on-prem cluster's **public OIDC issuer**: a Cloudflare Worker serving
`/.well-known/openid-configuration` and `openid/v1/jwks` under
`https://oidc.qnsc.vn/k3s-onprem`, plus the custom domain that fronts it.

This is the half of ESO workload identity that lives outside Azure. The other
half — the federated identity credential that trusts this issuer — is in
[live/identity/eso.tf](../identity/eso.tf); the issuer that k3s actually mints
tokens with is the `k3s_server_oidc_issuer` variable of the `k3s_server` Ansible
role (a site value in the git-ignored inventory). The static guard in
`live/identity/tests/static.sh` fails when this stack and `eso.tf` drift; the
k3s side is checked at rollout (the `iss` of a fresh token, identity README step 4).

## Trust chain (this Worker is a trust root for Key Vault)

Whoever can change what `<issuer>/openid/v1/jwks` serves can mint tokens that
Entra accepts for the ESO apps, hence read Key Vault secrets. The chain is:
Cloudflare account admins, the Workers API token used here, the owner who
applies this stack, and the cluster signing key. Keep the token scoped to
Workers Scripts:Edit on this one account (plus Zone:Workers Routes:Edit on the
one zone the custom domain needs), stored in 1Password only, and keep the
Cloudflare account admin list minimal with MFA. Detection: the `Drift
onprem-oidc-served` job of `drift-detection.yml` fetches the served documents
and fails when the `kid` set or the key hash differs from
`jwks-expected.txt` (the non-secret outputs `jwks_kids` / `jwks_sha256`; update
that file in the same PR as every rotation).

## Owns

- Worker `qnsc-k3s-oidc` (script content = the two documents, generated from
  `var.k3s_jwks` and the issuer variables).
- `oidc.qnsc.vn` custom domain — DNS record and certificate are created by
  `cloudflare_workers_custom_domain`, nothing is added by hand.

## Not in CI

`live/onprem-oidc` is owner-applied and listed in `NOT_PLANNABLE`
(`.github/workflows/infra-plan.yml`): its only input that CI does not have is
the JWKS, which can only be read from the running cluster. There is no cheap
plan to run on a merge, so there is none.

## Apply

Prerequisites: `az login` (the azurerm backend), and a Cloudflare token with
**Workers Scripts:Edit** and **Zone:Workers Routes:Edit** on the account.

```sh
cd live/onprem-oidc
export ARM_SUBSCRIPTION_ID=<subscription-id>
export TF_VAR_cloudflare_account_id=<account-id>
export TF_VAR_cloudflare_zone_id=<zone-id>
# the token comes from 1Password, never typed/pasted into the shell history:
export TF_VAR_cloudflare_api_token="$(op read 'op://QNSC/<item-id>/<field>')"
tofu init
kubectl get --raw /openid/v1/jwks > /tmp/jwks.json  # public keys only

TF_VAR_k3s_jwks="$(cat /tmp/jwks.json)" tofu plan    # expect 2 to add on the first run
TF_VAR_k3s_jwks="$(cat /tmp/jwks.json)" tofu apply
```

Check what Entra will fetch (the Worker is live as soon as the custom domain
provisions — usually within a minute):

```sh
curl -fsS https://oidc.qnsc.vn/k3s-onprem/.well-known/openid-configuration | jq .
curl -fsS https://oidc.qnsc.vn/k3s-onprem/openid/v1/jwks | jq '.keys[].kid'
```

The `issuer` in the discovery document, `var.eso_oidc_issuer` in
`live/identity` and `service-account-issuer` in the k3s config must all be
`https://oidc.qnsc.vn/k3s-onprem`.

## Rotation

k3s never rotates its service-account signing key on its own; only
`k3s certificate rotate-ca` rewrites `service.key`, and nothing watches that
file. When a rotation is done deliberately, publish **both** keys before
retiring the old one — a JWKS carrying only the new key rejects every token
minted before the rotation. Full sequence:
[live/identity/README.md](../identity/README.md), "Rotation of the
service-account signing key".
