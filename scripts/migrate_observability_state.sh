#!/usr/bin/env bash
# Move observability's Grafana objects into observability-alerting's state.
#
# Runbook step 3.4b. Needs credentials, so it is a script a human runs rather than
# something CI does.
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# The observability split was code-only, and this stack HAS BEEN APPLIED. Its state
# holds grafana_folder.*, the dashboard, contact point, notification policy and rule
# group — all created through the `grafana.stack` provider alias the split removed.
# So its plan fails with:
#
#   Error: Provider configuration not present
#   To work with grafana_folder.alerts (orphan) its original provider configuration
#   at provider["...grafana/grafana"].stack is required, but it has been removed.
#
# `moved` blocks cannot fix it — they do not cross state files. The objects must be
# imported into the sibling and removed from here.
#
# ── WHY A SCRIPT AND NOT THE COMMANDS IN THE RUNBOOK ────────────────────────
#
# The runbook version has you read each UID out of `tofu state show` and paste it
# into a `tofu import`. Ten objects, ten transcriptions, at least one of which will
# be a folder UID pasted into a dashboard import. This reads them from the state
# instead.
#
# ── WHAT IT WILL NOT DO ─────────────────────────────────────────────────────
#
# It never calls `tofu state rm` until the sibling's plan is EMPTY. A non-empty plan
# there means the committed configuration disagrees with what is live in Grafana —
# which is real drift the split has just made visible for the first time, and is
# exactly the thing to resolve deliberately rather than apply past.
#
# Nothing in Grafana is touched either way. The folders, dashboards and alert rules
# keep existing and keep working throughout; only which state file OWNS them
# changes. So the failure mode is a duplicate or an unmanaged object, never a
# deleted one — and that is the property that makes this safe to attempt.
set -euo pipefail

FROM_DIR="${FROM_DIR:-live/observability}"
TO_DIR="${TO_DIR:-live/observability-alerting}"
APPLY="${APPLY:-false}"   # APPLY=true performs the change; default is a dry run

# address -> the import ID's shape. Grafana's provider is not uniform here, which
# is the single most likely source of a hand-made mistake:
#   folders               the folder UID
#   dashboards            <folder-uid>:<dashboard-uid>
#   contact points        the name
#   notification policy   the literal string `policy` — there is only ever one
#   rule groups           <folder-uid>:<group-name>
RESOURCES=(
  grafana_folder.company
  grafana_folder.alerts
  grafana_folder.dashboards
  grafana_folder.slos
  grafana_folder.rally_dashboards
  grafana_folder.opshub_dashboards
  grafana_dashboard.system_overview
  grafana_contact_point.teams
  grafana_notification_policy.root
  grafana_rule_group.series_near_cap
)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n  ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$FROM_DIR" ] || die "$FROM_DIR does not exist — run this from the infra repository root"
[ -d "$TO_DIR" ]   || die "$TO_DIR does not exist"

say "1. Reading import IDs out of $FROM_DIR's state"
( cd "$FROM_DIR" && tofu init -input=false >/dev/null )

declare -a PRESENT=() IMPORT_IDS=()
for addr in "${RESOURCES[@]}"; do
  if ! ( cd "$FROM_DIR" && tofu state list 2>/dev/null | grep -qxF "$addr" ); then
    printf '  skip     %-38s not in state\n' "$addr"
    continue
  fi
  # `tofu state show` renders the id attribute; for every one of these resources the
  # provider's import ID is either `id` itself or derivable from it, and the provider
  # already stores the composite form for dashboards and rule groups.
  id=$( cd "$FROM_DIR" && tofu state show -no-color "$addr" 2>/dev/null \
        | awk -F'= ' '/^[[:space:]]+id[[:space:]]+=/ {gsub(/"/,"",$2); print $2; exit}' )
  [ -n "$id" ] || die "could not read an id for $addr — inspect it by hand: (cd $FROM_DIR && tofu state show $addr)"
  PRESENT+=("$addr"); IMPORT_IDS+=("$id")
  printf '  found    %-38s id=%s\n' "$addr" "$id"
done

[ ${#PRESENT[@]} -gt 0 ] || die "nothing to migrate — $FROM_DIR's state holds none of these addresses.
  If the migration has already run, remove 'observability' from NOT_PLANNABLE in
  .github/workflows/infra-plan.yml and confirm both stacks plan clean."

say "2. Importing ${#PRESENT[@]} object(s) into $TO_DIR"
( cd "$TO_DIR" && tofu init -input=false >/dev/null )
for i in "${!PRESENT[@]}"; do
  addr="${PRESENT[$i]}"; id="${IMPORT_IDS[$i]}"
  if ( cd "$TO_DIR" && tofu state list 2>/dev/null | grep -qxF "$addr" ); then
    printf '  already  %s\n' "$addr"; continue
  fi
  if [ "$APPLY" = "true" ]; then
    printf '  import   %s\n' "$addr"
    ( cd "$TO_DIR" && tofu import -input=false "$addr" "$id" >/dev/null ) \
      || die "import failed for $addr (id=$id). Nothing has been removed from $FROM_DIR, so the estate is unchanged."
  else
    printf '  WOULD    tofu -chdir=%s import %s %s\n' "$TO_DIR" "$addr" "$id"
  fi
done

say "3. The gate — $TO_DIR's plan must be EMPTY"
if [ "$APPLY" != "true" ]; then
  echo "  dry run: re-run with APPLY=true to import, then this check becomes real."
  exit 0
fi
set +e
( cd "$TO_DIR" && tofu plan -input=false -lock=false -detailed-exitcode -no-color >/tmp/obs-plan.txt 2>&1 )
rc=$?
set -e
case $rc in
  0) echo "  empty plan — the imported objects match the committed configuration" ;;
  2) tail -40 /tmp/obs-plan.txt
     die "the plan is NOT empty. STOPPING BEFORE ANY state rm, so nothing is lost.
  A diff here means the committed configuration disagrees with what is live in
  Grafana — drift this split has just made visible. Resolve it deliberately: either
  correct the configuration to match, or decide the live object is wrong and let the
  plan change it. Then re-run." ;;
  *) tail -40 /tmp/obs-plan.txt; die "the plan errored (exit $rc). Nothing removed." ;;
esac

say "4. Removing them from $FROM_DIR's state"
( cd "$FROM_DIR" && tofu state rm "${PRESENT[@]}" )

say "5. Confirming $FROM_DIR plans clean and proposes no destruction"
set +e
( cd "$FROM_DIR" && tofu plan -input=false -lock=false -detailed-exitcode -no-color >/tmp/obs-old-plan.txt 2>&1 )
rc=$?
set -e
grep -qiE '^\s*#.*will be destroyed|to destroy' /tmp/obs-old-plan.txt && {
  tail -40 /tmp/obs-old-plan.txt
  die "the old stack now proposes a DESTROY. Do not apply. Investigate before proceeding."
}
[ $rc -ne 1 ] || { tail -40 /tmp/obs-old-plan.txt; die "the old stack's plan errored"; }

say "Done."
cat <<'EOF'
  Both stacks now own what they declare. Two follow-ups, both in this repository:

    1. remove `observability` from NOT_PLANNABLE in
       .github/workflows/infra-plan.yml — it can plan again
    2. `observability-alerting` stays excluded only until `observability` has been
       applied, which is the ordinary dependency, not this migration

  Nothing in Grafana changed. If anything here surprised you, the objects are
  intact and both states are recoverable from S3 versioning.
EOF
