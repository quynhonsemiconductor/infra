# kubectl through Entra (kubelogin)

Admins and developers sign `kubectl` in with their Entra account. The long-lived admin kubeconfig is
**break-glass only**: it stays offline in 1Password and never on a laptop.

```
laptop: kubectl  --exec-->  kubelogin  -->  Entra (browser, MFA)  -->  ID token
   |                                                                      |
   +----------------------- API 6443 (over WARP) <------------------------+
                        k3s API server verifies the token (OIDC), reads the
                        `groups` claim, RBAC decides what you may do
```

## What has to be true before this page applies

| Piece | Where | State |
|---|---|---|
| "QNSC k3s" app (public client, groups claim) | `infra/live/identity/k3s_oidc.tf` | applied by the owner |
| API-server OIDC flags + RBAC bindings | `infra/ansible`, role `k3s_server`, `k3s_server_entra_auth_enabled=true` | applied in the owner window (k3s restart) |
| You are in `grp-qnsc-platform-admins` or `grp-qnsc-developers` | Entra | by role |

The **workload-identity issuer is a different thing** and this page does not touch it: `service-account-issuer`
(`https://oidc.qnsc.vn/k3s-onprem`) is what k3s *signs* service-account tokens with for ESO. The OIDC flags here
make the API server *verify* Entra **user** tokens. Two separate mechanisms, no overlap.

Reachability: the API is on the office VLAN, so **WARP on** (Cloudflare One Client) is required from anywhere
outside the office — same door as every other admin endpoint.

## Owner (cluster-admin) — one-time laptop setup

1. Install kubelogin (the standalone binary also works if Homebrew is not around):

   ```sh
   brew install int128/kubelogin/kubelogin
   kubelogin --version
   ```

2. Get the two ids from the owner kit (not from this repo):

   ```sh
   # client id from the identity apply; tenant id from Entra
   K3S_CLIENT_ID=<k3s_oidc_client_id>
   K3S_TENANT_ID=<tenant id>
   ```

3. Write `~/.kube/qnsc-onprem-entra.yaml` (chmod 600). The server address is the site value from the
   local inventory:

   ```yaml
   apiVersion: v1
   kind: Config
   clusters:
     - name: qnsc-onprem
       cluster:
         server: https://<k3s-01 address>:6443
         certificate-authority-data: <the cluster CA, base64>   # from the break-glass kubeconfig, once
   users:
     - name: entkubectl
       user:
         exec:
           apiVersion: client.authentication.k8s.io/v1beta1
           command: kubelogin
           args:
             - get-token
             - --oidc-issuer-url=https://login.microsoftonline.com/<tenant>/v2.0
             - --oidc-client-id=<k3s client id>
             - --oidc-extra-scope=email,profile,offline_access
           interactiveMode: IfAvailable
   contexts:
     - name: qnsc-onprem
       context: { cluster: qnsc-onprem, user: entkubectl }
   current-context: qnsc-onprem
   ```

4. First call opens a browser, MFA completes, and the token is cached (kubelogin renews it until the
   refresh token expires):

   ```sh
   KUBECONFIG=~/.kube/qnsc-onprem-entra.yaml kubectl auth whoami
   # Username: oidc:<you>@<company>  Groups: [<grp-qnsc-platform-admins object id> system:authenticated]
   ```

   The group in `Groups:` must be the **object id** of `grp-qnsc-platform-admins` — that is what the binding
   matches. If it is missing: the app's `groups` claim is not being emitted (check SecurityGroup claims on the
   app) or you are not in the group.

5. Make it the default: `export KUBECONFIG=~/.kube/qnsc-onprem-entra.yaml` in the shell profile, and delete
   any old admin kubeconfig from the laptop.

**No browser on the machine** (a jump box): add `--grant-type=device-code` to the args and complete the sign-in
on a phone.

## Developer (read-only) — same steps, different outcome

Same app, same kubeconfig, same command. RBAC gives `grp-qnsc-developers` the ClusterRole
`qnsc-k8s-developer-readonly`: get/list/watch on pods (and `pods/log`), services, endpoints, events,
namespaces, nodes, PVCs, workloads (apps/batch), ingresses/networkpolicies, HPAs, metrics, Argo CD objects.

What a developer **cannot** do, by design:

- read `secrets` **or `configmaps`** — both hold credentials here, so neither is in the cluster-wide role.
  A team that needs a configmap gets a namespaced RoleBinding, decided on its own;
- change anything (`apply`, `delete`, `scale`, `exec`). Those are admin actions; ask an admin or change the
  deployment through GitOps.

If a developer needs more than that, the fix is a role change discussed with the owner, not a kubeconfig.

## Day-to-day

- `kubectl get/describe/logs` — works until the refresh token expires; when it does, kubelogin opens the
  browser again. `kubelogin remove-tokens` forces it early.
- `kubectl exec` and `kubectl port-forward` need cluster-admin; engineers do not get them by default.
- **Audit lines show the object id**, not the UPN: the API server names the user `oidc:<object id>` because
  that is the only immutable identifier (a UPN is renamed, and Entra can reissue a freed one). Map an id
  when reading a log: `az ad user show --id <oid> --query userPrincipalName`.
- ArgoCD, Grafana etc. keep their own sign-in; this page is only the API server.

## Break-glass: the admin kubeconfig

- The `/etc/rancher/k3s/k3s.yaml` copy (server `https://127.0.0.1:6443`, `system:admin`) is the **offline**
  break-glass. It lives in **1Password**, is fetched only when Entra or WARP is the thing that is broken, and
  is deleted from the machine after use.
- It is **unaffected by the OIDC flags or by the restart**: it authenticates with the API server's client
  certificate (`CN=system:admin`), a path that does not go through OIDC. That is exactly why it stays as the
  last door.
- Rule: a laptop that carries it does not also have it in shell history, `KUBECONFIG` exports or a synced
  folder.
- It is not revoked by any day-to-day change; rotating it is its own owner action (`k3s` rewrites it on
  restart with the same token).

## Troubleshooting

| Symptom | Cause |
|---|---|
| browser opens, then `Unauthorized` | the API server has no/incorrect `oidc-client-id` or a different tenant: check `/etc/rancher/k3s/config.yaml` on k3s-01 and that the restart happened |
| `error: You must be logged in to the server (Unauthorized)` before the browser | the token's audience/issuer does not match the flags: compare `--oidc-issuer-url` (v2.0 endpoint) with the app's `signInAudience` |
| signed in, `forbidden` on everything | the `Groups:` line in `auth whoami` does not carry the expected group object id — see the setup step 4 |
| `dial tcp … i/o timeout` | WARP is off, or you are not on the office VLAN |
| `forbidden` for everyone at once, `auth whoami` shows no groups | the token carried no `groups` claim: Entra switches to an overage (`_claim_names`/`_claim_sources`) when a user is in **more than ~200 groups**, and the API server then sees no group. Reduce membership or use the object id allow-list pattern instead |
| works, then asks for the browser again after about an hour | no refresh token: the app must request `offline_access` (it does) and kubelogin must ask for it (`--oidc-extra-scope=…,offline_access`). The Entra tenant's sign-in frequency policy can still force a new sign-in |
