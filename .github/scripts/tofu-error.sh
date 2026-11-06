#!/usr/bin/env bash
# tofu-error.sh — print WHAT FAILED, and nothing of the plan/apply body.
#
#   bash .github/scripts/tofu-error.sh live/edge/plan.txt >&2
#
# live/edge carries private data in state (SSH target addresses and logins), so its plan and
# apply text are written to a file and never printed. The cost showed up on 2026-11-06: an
# apply failed and the log only said "apply text withheld", with the actual error hidden inside
# the file. This script prints the diagnostics and nothing else:
#
#   * the `╷ … ╵` error boxes, when OpenTofu wrote them (a TTY-less run may not);
#   * otherwise every `Error:`/`Warning:` block WHOLE — summary, the source lines AND the
#     un-indented detail that follows the blank line (that is where the provider puts the HTTP
#     status and the API body; the first version cut there and hid the cause of the 2026-11-06
#     failure). A failed run prints its diagnostics at the END of the stream, so everything from
#     the first diagnostic on is failure output; nothing printed before it is.
#   * otherwise one line saying no diagnostics were found — never the body, and never silence.
#
# Values inside the text are already masked by the step's `::add-mask::` (the guard masks every
# SSH-target string and every node name before anything runs), so the printed text is safe.
set -euo pipefail

file=${1:?usage: tofu-error.sh <output-file>}
if [ ! -s "$file" ]; then
  echo "tofu-error: '$file' is missing or empty; the command produced no output at all." >&2
  exit 0
fi

if grep -q '╷' "$file"; then
  sed -n '/^╷/,/^╵/p' "$file"
  exit 0
fi

if grep -qE '^(│ )?(Error|Warning): ' "$file"; then
  # Print EACH diagnostic block WHOLE: from `Error:`/`Warning:` to the next one or EOF, including the
  # un-indented detail text that follows the blank line (the provider puts the HTTP status and the API
  # body there — cutting at the first column-0 line hid the cause of the 2026-11-06 apply failure).
  # Plan/apply body text sits between diagnostics, never inside one, and this file is only produced by
  # a run that failed.
  awk '
    /^(│ )?(Error|Warning): / {
      if (p) print ""
      p = 1
      print
      next
    }
    p { print }' "$file"
  exit 0
fi

echo "tofu-error: no Error: diagnostics found in '$file' (the command still failed — read the step above)." >&2
exit 0
