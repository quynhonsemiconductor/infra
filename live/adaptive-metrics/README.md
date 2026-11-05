# adaptive-metrics

The Grafana Adaptive Metrics aggregation rules for the on-prem app metrics
(`main.tf`). Applied by its own stack because the provider calls the AM API at
configure time.

## Querying a family this stack aggregates

Adaptive Metrics keeps only the labels named in each rule's `keep_labels` and
drops every other label and every non-aggregated series. Two consequences that
have each produced a false "the metric does not exist" conclusion:

1. **A bare `{__name__=~"http_server_.*"}` query returns nothing or a 422.**
   The metric is aggregated into a smaller series set; query it by the kept
   labels, e.g.

   ```promql
   sum by (job, status_class, deployment_environment_name) (
     increase(http_server_duration_milliseconds_count[1d])
   )
   ```

2. **`http_status_code` / `http_response_status_code` do not exist** for a
   family covered by the `http_server_` / `http_client_` rules: they are not in
   `keep_labels`. Every HTTP rule must use `status_class` (`2xx`…`5xx`), which
   the app SDKs and Beyla both emit (Beyla's `http_response_status_code` is
   renamed to `status_class` at the collector before Mimir sees it).

The `http.server.duration` family exists for kb too (qnsc-kb-backend#369), not
only rova/opshub. A rule over it is valid; an empty result means no traffic in
the window, not a missing instrument.
