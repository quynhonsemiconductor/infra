#!/usr/bin/env bash
# CI guard: the audit scripts must stay read-only. Fails when entra-audit.sh or exchange-rbac-audit.ps1 contain anything
# that could change the tenant: an HTTP verb other than GET, a second `az rest` call site, an `az` sub-command other than
# `rest` / `account`, or a PowerShell cmdlet whose verb is not read-only.
#
#   ./check-readonly.sh                      # checks the two scripts next to this file
#   ./check-readonly.sh FILE...              # .sh and .ps1 files by extension (used by the tests)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -eq 0 ]]; then set -- "$HERE/entra-audit.sh" "$HERE/exchange-rbac-audit.ps1"; fi

bad=0
fail() { echo "READ-ONLY GUARD: $1: $2" >&2; bad=1; }

# Comments and (for PowerShell) <# ... #> blocks are documentation, not code.
strip_sh() { sed -E 's/^[[:space:]]*#.*$//' "$1"; }
strip_ps() { awk 'BEGIN{b=0} { line=$0; if (b) { if (index(line,"#>")) { b=0; sub(/.*#>/,"",line) } else next } while (match(line,/<#/)) { pre=substr(line,1,RSTART-1); rest=substr(line,RSTART+2); if (index(rest,"#>")) { sub(/.*#>/,"",rest); line=pre rest } else { line=pre; b=1; break } } sub(/^[[:space:]]*#.*/,"",line); print line }' "$1"; }

for file in "$@"; do
  [[ -f "$file" ]] || { fail "$file" "not found"; continue; }
  case "$file" in
    *.sh)
      code="$(strip_sh "$file")"
      if grep -nEi -e '--method[ =]+(post|put|patch|delete|head|options)' <<<"$code" >/dev/null; then fail "$file" "an az rest call with a method other than get"; fi
      if grep -nE -e '(^|[^[:alnum:]_-])(curl|wget)([^[:alnum:]_-]|$)' <<<"$code" >/dev/null; then fail "$file" "curl/wget; use graph_get"; fi
      if grep -nEi -e '-X[ ]*(POST|PUT|PATCH|DELETE)|--request' <<<"$code" >/dev/null; then fail "$file" "an explicit HTTP verb"; fi
      if grep -nE -e '--body|--headers|--data' <<<"$code" >/dev/null; then fail "$file" "a request body or header option"; fi
      # short flags of az rest: -m (method) and -b (body), on any line that calls az rest
      if grep -E -e '(^|[^[:alnum:]_-])az[[:space:]]+rest' <<<"$code" | grep -E -e '(^|[[:space:]])-[mb]([[:space:]=]|$)' >/dev/null; then fail "$file" "az rest with a short -m/-b flag"; fi
      rest_lines="$(grep -cE -e '(^|[^[:alnum:]_-])az[[:space:]]+rest' <<<"$code" || true)"
      if [[ "$rest_lines" -gt 1 ]]; then fail "$file" "az rest appears $rest_lines times; the only call site must be graph_get()"; fi
      if [[ "$rest_lines" -eq 1 ]] && ! grep -E -e 'az[[:space:]]+rest[[:space:]]+--method[[:space:]]+get([[:space:]]|$)' <<<"$code" >/dev/null; then
        fail "$file" "az rest must be called as: az rest --method get ..."
      fi
      # any other az sub-command (az ad, az role, az account set, az login ...) is not part of the collection. Quoted text is
      # removed first so a hint such as "run 'az login'" in a message is not mistaken for a command.
      unquoted="$(sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g" <<<"$code")"
      if grep -E -e '(^|[;&|(`]|\$\()[[:space:]]*az[[:space:]]+[a-z]' <<<"$unquoted" | grep -vE 'az[[:space:]]+(rest|account[[:space:]]+show)([[:space:]]|$)' | grep -E 'az' >/dev/null; then
        fail "$file" "an az sub-command other than 'rest' / 'account show'"
      fi
      ;;
    *.ps1)
      code="$(strip_ps "$file")"
      # Verbs that change something. Write-* (console output), Set-StrictMode and Import-Module are the only exceptions.
      hits="$(grep -noE -e '\b(New|Set|Remove|Add|Enable|Disable|Update|Invoke|Start|Stop|Grant|Revoke|Install|Uninstall|Clear|Reset|Move|Rename|Restore|Resume|Suspend|Publish|Register|Unregister|Send|Copy|Out|Save|Sync|Mount|Dismount|Initialize)-[A-Za-z]+' <<<"$code" | grep -vE ':(Set-StrictMode|Out-File|Out-Null|Out-String)$' || true)"
      if [[ -n "$hits" ]]; then fail "$file" "cmdlet(s) that are not read-only: $(tr '\n' ' ' <<<"$hits")"; fi
      if grep -nEi -e 'Invoke-(Rest|Web)|\[System\.Net|curl|wget' <<<"$code" >/dev/null; then fail "$file" "a direct web call"; fi
      if grep -nEi -e '::(Delete|Move|Copy|Replace|WriteAll|AppendAll)|\.Delete\(|\bcmd(\.exe)?\b|\bbash\b' <<<"$code" >/dev/null; then fail "$file" "a .NET file operation or a shell-out"; fi
      ;;
    *) fail "$file" "unknown file type" ;;
  esac
done
[[ "$bad" -eq 0 ]] && echo "read-only guard: ok ($*)" | sed "s#$HERE/##g"
exit "$bad"
