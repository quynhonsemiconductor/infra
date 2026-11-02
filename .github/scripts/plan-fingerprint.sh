#!/usr/bin/env bash
# Plan-first apply helpers. Runs inside live/<stack> after `tofu plan -out=tfplan`.
#
#   plan-fingerprint.sh plan  <stack> <exitcode>   plan stage (read-only credentials): summary, outputs, fp.json
#   plan-fingerprint.sh check <stack>              apply stage (write credentials): same fingerprint or fail
#
# THE FINGERPRINT is sha256 over the sorted lines "<resource address> <action>" of every managed resource that
# changes (from `tofu show -json`). Addresses and actions only: no attribute values, so it and the summary are
# safe in a public log. The JSON plan is only ever piped into jq; it is never written to disk or uploaded.

mode=${1:?mode}
stack=${2:?stack}
plan_file=${PLAN_FILE:-tfplan}

lines() {
  tofu show -json "$plan_file" | jq -r '
    [ .resource_changes[]?
      | select(.mode == "managed")
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | "\(.address) \(.change.actions | join("+"))" ]
    | sort | .[]'
}

fingerprint() { printf '%s\n' "$1" | sed '/^$/d' | sha256sum | cut -d' ' -f1; }

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
      echo '```'
    else
      echo "No resource changes."
    fi
    echo
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

case $mode in
  plan)
    ec=${3:?exit code of tofu plan}
    if [ "$ec" = 0 ]; then body=""; else body=$(lines); fi
    fp=$(fingerprint "$body")
    has=false; [ "$ec" = 2 ] && has=true
    summary "$body" "Plan: ${stack}"
    # shellcheck disable=SC2016  # literal markdown backticks
    printf 'fingerprint: `%s`\n\n' "$fp" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
    out=${GITHUB_OUTPUT:-/dev/null}
    { echo "has_changes=${has}"; echo "fingerprint=${fp}"; } >>"$out"
    jq -n --arg s "$stack" --argjson h "$has" --arg f "$fp" '{stack:$s, has_changes:$h, fingerprint:$f}' >"${FP_JSON:-fp.json}"
    ;;
  check)
    body=$(lines)
    fp=$(fingerprint "$body")
    summary "$body" "Applying: ${stack}"
    expected=${EXPECTED_FP:-}
    if [ -z "$expected" ]; then
      echo "::notice::${stack}: no approved fingerprint (read-only plan not comparable for this stack): applying the plan made just now, as before."
    elif [ "$fp" != "$expected" ]; then
      echo "::error title=plan changed since approval::${stack}: the plan with write credentials differs from the plan that was shown for approval (approved ${expected}, now ${fp}). Nothing was applied. Re-run the workflow to review the new plan."
      # shellcheck disable=SC2016  # literal markdown backticks
      printf '> **Not applied: the plan changed since approval** (approved `%s`, now `%s`). Re-run to review the new plan.\n\n' "$expected" "$fp" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
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
