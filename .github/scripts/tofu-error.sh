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
#   * otherwise the plain `Error: …` blocks (summary + indented detail, up to the blank line);
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

if grep -qE '^(│ )?Error: ' "$file"; then
  # The Error block: the summary, its indented detail and the blank lines inside it. It ends at the
  # next line that starts at column 0 (the plain form puts nothing else at the left margin except
  # another Error), so text after the block — plan body, progress lines — is never printed.
  awk '
    /^(│ )?Error: / { p = 1 }
    p {
      if ($0 !~ /^[[:space:]]/ && $0 !~ /^(│ )?Error: / && $0 != "") { p = 0; next }
      print
    }' "$file"
  exit 0
fi

echo "tofu-error: no Error: diagnostics found in '$file' (the command still failed — read the step above)." >&2
exit 0
