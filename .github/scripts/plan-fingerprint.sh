#!/usr/bin/env bash
# Plan-first apply helpers. Runs inside live/<stack> after `tofu plan -out=tfplan`.
#
#   plan-fingerprint.sh plan  <stack> <exitcode>   plan stage (read-only credentials): summary, outputs, fp.json
#   plan-fingerprint.sh check <stack>              apply stage (write credentials): same fingerprint or fail
#
# THE FINGERPRINT is sha256 over the sorted lines "<resource address> <action>" of every managed resource that
# changes (from `tofu show -json`). Addresses and actions only: no attribute values, so it is safe in a public
# log. The JSON plan is only ever piped into jq; it is never written to disk or uploaded.
#
# HIDE_ADDRESSES=true prints TYPES only (module path + resource type, no for_each keys, no names). A stack
# whose resource addresses carry private data (live/edge: the SSH target map keys) sets it. The fingerprint is
# computed from the FULL addresses either way, so the plan stage and the apply stage still compare like for like.
#
# Env: PLAN_FILE (default tfplan), PLAN_TITLE (step-summary heading), SUMMARY_FILE (also write the summary
# here, for the PR comment), HIDE_ADDRESSES, EXPECTED_FP (check mode), FP_JSON, GITHUB_STEP_SUMMARY/GITHUB_OUTPUT.

mode=${1:?mode}
stack=${2:?stack}
plan_file=${PLAN_FILE:-tfplan}
hide_addresses=${HIDE_ADDRESSES:-false}

lines() {
  tofu show -json "$plan_file" | jq -r '
    [ .resource_changes[]?
      | select(.mode == "managed")
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | "\(.address) \(.change.actions | join("+"))" ]
    | sort | .[]'
}

# fingerprint <lines> — sha256 of the sorted "<address> <action>" lines, or HMAC-SHA256 when
# FP_HMAC_KEY is set. Keying it stops an outsider from testing guesses against the published value:
# without the key the digest is an oracle over a small space of node names (the address lines carry
# them). The key is the stack's own private input (live/edge: SSH_INFRA_TARGETS) and both stages use
# the same value, so plan-vs-apply parity is unchanged.
fingerprint() {
  if [ -n "${FP_HMAC_KEY:-}" ]; then
    printf '%s\n' "$1" | sed '/^$/d' | python3 -c '
import hashlib, hmac, os, sys
print(hmac.new(os.environ["FP_HMAC_KEY"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())'
  else
    printf '%s\n' "$1" | sed '/^$/d' | sha256sum | cut -d' ' -f1
  fi
}

# emit <file> — append a finished block to the step summary, plus SUMMARY_FILE when one is named (the PR
# comment reads that file). Takes a FILE, not a string: macOS's bash 3.2 cannot parse `case` inside `$( )`.
emit() {
  cat "$1" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  if [ -n "${SUMMARY_FILE:-}" ]; then cat "$1" >>"$SUMMARY_FILE"; fi
}

# emit_line <text> — one already-formatted string to the step summary and SUMMARY_FILE.
emit_line() {
  printf '%s' "$1" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  if [ -n "${SUMMARY_FILE:-}" ]; then printf '%s' "$1" >>"$SUMMARY_FILE"; fi
}

# hide_type <address> — "module.edge.cloudflare_dns_record.app_hosts[\"rova-dev.qnsc.vn\"]" becomes
# "module.edge.cloudflare_dns_record": every for_each key dropped, then the resource's local name.
hide_type() {
  local base
  base=$(printf '%s' "$1" | sed -E 's/\[[^]]*\]//g')
  printf '%s' "${base%.*}"
}

summary() { # summary <lines> <title>
  local body=$1 title=$2 add=0 chg=0 del=0 fgt=0 destructive=no
  while read -r addr act; do
    [ -n "${addr:-}" ] || continue
    case $act in
      create) add=$((add + 1)) ;;
      update) chg=$((chg + 1)) ;;
      delete) del=$((del + 1)); destructive=yes ;;
      delete+create | create+delete) add=$((add + 1)); del=$((del + 1)); destructive=yes ;;
      forget) fgt=$((fgt + 1)) ;;
    esac
  done <<<"$body"
  # Built in a FILE, then emitted: macOS bash 3.2 cannot parse `case` inside a command substitution.
  local block
  block=$(mktemp)
  {
    echo "### ${title}"
    echo
    echo "**+${add} add, ~${chg} change, -${del} destroy** (forgotten from state, not destroyed: ${fgt})"
    if [ "$destructive" = yes ]; then
      echo
      echo "> Contains a delete or replace: the apply needs the \`allow_destructive\` dispatch input or the \`allow-dns-destroy\` label."
    fi
    echo
    if [ -n "$body" ]; then
      echo '```'
      if [ "$hide_addresses" = true ]; then
        # TYPES only, each once: a for_each key is private data on this stack.
        while read -r addr act; do
          [ -n "${addr:-}" ] || continue
          case $act in
            create) sym='+' ;;
            update) sym='~' ;;
            delete) sym='-' ;;
            delete+create | create+delete) sym='-/+' ;;
            forget) sym='forget' ;;
            *) sym="$act" ;;
          esac
          printf '%-6s %s\n' "$sym" "$(hide_type "$addr")"
        done <<<"$body" | sort -u
      else
        while read -r addr act; do
          [ -n "${addr:-}" ] || continue
          case $act in
            create) sym='+' ;;
            update) sym='~' ;;
            delete) sym='-' ;;
            delete+create | create+delete) sym='-/+' ;;
            forget) sym='forget' ;;
            *) sym="$act" ;;
          esac
          printf '%-6s %s\n' "$sym" "$addr"
        done <<<"$body"
      fi
      echo '```'
    else
      echo "No resource changes."
    fi
    echo
  } >"$block"
  emit "$block"
  rm -f "$block"
}

case $mode in
  plan)
    ec=${3:?exit code of tofu plan}
    if [ "$ec" = 0 ]; then body=""; else body=$(lines); fi
    fp=$(fingerprint "$body")
    has=false; [ "$ec" = 2 ] && has=true
    summary "$body" "${PLAN_TITLE:-Plan: ${stack}}"
    # shellcheck disable=SC2016  # literal markdown backticks
    emit_line "$(printf 'fingerprint: `%s`\n\n' "$fp")"
    out=${GITHUB_OUTPUT:-/dev/null}
    { echo "has_changes=${has}"; echo "fingerprint=${fp}"; } >>"$out"
    jq -n --arg s "$stack" --argjson h "$has" --arg f "$fp" '{stack:$s, has_changes:$h, fingerprint:$f}' >"${FP_JSON:-fp.json}"
    ;;
  check)
    body=$(lines)
    fp=$(fingerprint "$body")
    summary "$body" "${PLAN_TITLE:-Applying: ${stack}}"
    expected=${EXPECTED_FP:-}
    if [ -z "$expected" ]; then
      echo "::notice::${stack}: no approved fingerprint (read-only plan not comparable for this stack): applying the plan made just now, as before."
    elif [ "$fp" != "$expected" ]; then
      echo "::error title=plan changed since approval::${stack}: the plan with write credentials differs from the plan that was shown for approval (approved ${expected}, now ${fp}). Nothing was applied. Re-run the workflow to review the new plan."
      # shellcheck disable=SC2016  # literal markdown backticks
      emit_line "$(printf '> **Not applied: the plan changed since approval** (approved `%s`, now `%s`). Re-run to review the new plan.\n\n' "$expected" "$fp")"
      exit 1
    else
      echo "${stack}: plan matches the approved fingerprint ${fp}"
    fi
    ;;
  *)
    echo "unknown mode ${mode}" >&2
    exit 2
    ;;
esac
