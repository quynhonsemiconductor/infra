# Docker Hub pull credential on every k3s node

Why: Docker Hub limits anonymous pulls to 10 per hour per IP. Every node sits behind the office NAT,
and the cluster pulls 12 `docker.io` images plus k3s's `rancher/*` images; a rebuild or an image-GC
sweep would spend the hour in `ImagePullBackOff`, adding directly to RTO.

The Ansible role `k3s_registries` writes `/etc/rancher/k3s/registries.yaml` (mode 0600) on **all
three nodes** with a READ-ONLY Docker Hub personal access token. Reading it needs a k3s restart;
the role reports when one is needed and only restarts with `-e k3s_registries_allow_restart=true`.

## Owner setup (once)

1. Docker Hub account: a free personal or organisation account for the platform (not a personal
   developer login). Create **Account settings → Security → New access token**, access
   **Read-only**. Do not use the account password.
2. Store it in 1Password: item `Docker Hub - k3s read-only pull token`, fields `username` and
   `credential`. The token value never goes into Git, Ansible vars or this runbook.
3. Put the account name in the **git-ignored** local inventory (`ansible/inventory/local/hosts.yml`):

   ```yaml
   all:
     vars:
       k3s_registries_docker_hub_username: <dockerhub-account>
   ```

4. A local `op run` env template outside the repo maps the token:

   ```
   QNSC_DOCKER_HUB_TOKEN=op://QNSC/<item-id>/credential
   ```

## Apply (maintenance window; one node at a time)

```sh
cd ansible
op run --env-file=<local template> -- \
  ansible-playbook k3s-server.yml --tags k3s_registries --check --diff
op run --env-file=<local template> -- \
  ansible-playbook k3s-server.yml --tags k3s_registries -e k3s_registries_allow_restart=true
# then the agents, one playbook each:
op run --env-file=<local template> -- \
  ansible-playbook k3s-agent-gpu.yml --tags k3s_registries -e k3s_registries_allow_restart=true
op run --env-file=<local template> -- \
  ansible-playbook k3s-agent.yml --tags k3s_registries -e k3s_registries_allow_restart=true
```

`--diff` does not print the token: the template task is `no_log`.

## Verify

The proof is the **authenticated rate limit**, not a successful anonymous pull: Docker Hub returns
`ratelimit-limit: 100;w=21600` to an anonymous client and a higher bucket to an authenticated one.
Run this under the same `op run`, so the token stays out of argv (`curl -K -` reads the credential
from stdin):

```sh
U=<dockerhub-account>   # same value as k3s_registries_docker_hub_username
printf 'user = "%s:%s"\n' "$U" "$QNSC_DOCKER_HUB_TOKEN" \
  | curl -sSI -K - https://index.docker.io/v2/ | grep -i '^ratelimit-limit'
```

Expect HTTP 200 and a `ratelimit-limit` larger than the anonymous 100. Also confirm the file and its
permissions on each node:

```sh
ssh <node> 'sudo test -f /etc/rancher/k3s/registries.yaml && sudo stat -c "%a %U" /etc/rancher/k3s/registries.yaml'
```

Check k3s-01, ai-01 and vlsi-01: each node's containerd must read its own registries.yaml, which a
`kubectl run` (scheduled on any node) would not prove. A pull alone can still succeed anonymously, so
it is not the verification.

## Rotating the token

Docker Hub tokens can be revoked on their own. Create a new read-only token, replace the 1Password
field, re-run the playbooks above with `k3s_registries_allow_restart=true`, then revoke the old
token. No image has to be rebuilt.
