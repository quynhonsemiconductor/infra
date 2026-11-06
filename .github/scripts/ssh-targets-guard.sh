#!/usr/bin/env bash
# ssh-targets-guard.sh — run inside an initialized live/edge directory BEFORE any
# edge plan, apply or drift pass.
#
# TF_VAR_ssh_infra_targets defaults to {}, so a run where the secret
# SSH_INFRA_TARGETS is missing (a fork PR, a repo where it was never created, a
# value set to {}) makes the plan see an EMPTY map and propose to DESTROY every
# live Access-for-Infrastructure target. This refuses that, and masks the values
# as a second layer for anything else that prints.
#
#   SSH_INFRA_TARGETS='{...}' .github/scripts/ssh-targets-guard.sh
#
# Prints counts only, never a value: "configured: N" or "none in the secret,
# none in state". A missing state read is a STOP, not a pass.
set -euo pipefail

target_type='cloudflare_zero_trust_access_infrastructure_target\.'
json=${SSH_INFRA_TARGETS:-}

configured=0
if [ -n "${json//[[:space:]]/}" ]; then
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::SSH_INFRA_TARGETS is not a JSON object (shape only, value withheld)"
    exit 1
  fi
  configured=$(printf '%s' "$json" | jq 'length')
  # Layer 2: every string in the object AND every top-level key (the node names).
  # The keys matter on their own: each target becomes Access app `ssh-<key>`, and a
  # failed apply prints that resource address in its error box.
  while IFS= read -r value; do
    if [ -n "$value" ]; then echo "::add-mask::$value"; fi
  done < <(printf '%s\n' "$(printf '%s' "$json" | jq -r '.. | strings')" \
             "$(printf '%s' "$json" | jq -r 'keys[]')")
fi

if [ "$configured" -gt 0 ]; then
  echo "ssh targets: ${configured} configured (values withheld)"
  exit 0
fi

# Nothing configured: the state decides whether that is safe to plan.
if ! state=$(tofu state list 2>&1); then
  echo "STOP: 'tofu state list' failed, so the guard cannot tell whether targets exist. Not planning blind." >&2
  printf '%s\n' "$state" >&2
  exit 1
fi

in_state=$(printf '%s\n' "$state" | grep -c "^${target_type}" || true)
if [ "${in_state:-0}" -gt 0 ]; then
  echo "::error::SSH_INFRA_TARGETS is empty or unset but the state holds ${in_state} Access-for-Infrastructure target(s). A plan would DESTROY them. Set the secret with the JSON that was applied, or remove the targets deliberately."
  exit 1
fi
echo "ssh targets: none configured, none in state — safe to plan"
