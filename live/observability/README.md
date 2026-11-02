# live/observability: Grafana Cloud org stack

The Grafana Cloud stack, the OTLP push access policy and the alerting service account
(`grafana_cloud_stack_service_account.alerting` + its token). Instance-level objects (folders,
dashboards, alert rules) live in `live/observability-alerting`, which reads this stack's outputs.

## How it is planned and applied

| Where | Refresh | Credential |
|---|---|---|
| PR plan (`infra-plan.yml`) | **off** (`-refresh=false`) | repo secret `GRAFANA_CLOUD_API_KEY_READONLY` (read-only) |
| Apply on merge (`infra-apply.yml`, `apply-observability`) | on | `production` environment secret `GRAFANA_CLOUD_API_KEY` (write) |
| Drift detection | not run | n/a |

**Why the PR plan does not refresh.** Grafana Cloud has no `stack-service-accounts:read` scope, only
`:write`. A read-only token therefore gets `403 Forbidden` refreshing the stack service account, and the
write key must never reach a PR plan (the PR's own HCL runs there). `-refresh=false` gives a
configuration-versus-state diff, which is what review needs. The real refresh happens in the apply job,
behind the `production` environment. For the same reason this stack is not in `drift-detection.yml`:
that job would be red every night.

The apply job fails early, with the cause, if `GRAFANA_CLOUD_API_KEY` is empty or unset (an empty value
otherwise reaches the provider as "no token": "the Cloud API client is required for this resource").

## Temporary: forgotten orphans

The state still lists ten Grafana-instance objects from before the stack split, and a dead push token.
`removed` blocks plus a read-only `grafana.stack` provider alias (configured from this stack's own
outputs) forget them without destroying anything; see the comments in `main.tf`. Delete the alias, the
`data.terraform_remote_state.self` source and the `removed` blocks in one PR after the first apply that
forgets them.
