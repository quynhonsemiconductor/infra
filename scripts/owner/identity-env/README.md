# identity-env: owner apply kit for live/identity

Builds every `TF_VAR_*` of `live/identity` that has no default from read-only `az` / `op` lookups (no value typed,
none in Git, none printed). Owner's own terminal only: `az login` done, `op` signed in.

```sh
export IDENTITY_SECOND_OWNER_UPN=<second owner UPN>
export IDENTITY_PROXMOX_HOST=<proxmox realm hostname>
scripts/owner/identity-env/identity-env.sh                            # names + lengths only
scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan   # runs in live/identity, env only in the child
```

It stops (never guesses) on an empty lookup, a duplicate app name, a non-GUID id, an app-role set other than the
seven OpsHub roles, a mail certificate whose thumbprint differs from the one live on the app, or a private key
anywhere. `eso_certificates` is built from `$IDENTITY_ESO_CERT_DIR/eso-{dev,prod,platform}-cert.pem` only while the
stack still declares it. Test (offline, runs in the `Infrastructure · Plan` lint job):
`bash scripts/owner/identity-env/test_identity_env.sh`.
