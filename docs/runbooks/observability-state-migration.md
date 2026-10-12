<!-- Extracted unchanged from docs/runbook-first-deploy.md (section 3.4b) on 2026-10-13, when that runbook (the EKS bring-up) was removed with the
spike. This is the ONLY write-up of this migration, and it is still open: `observability` cannot be planned until it is done
(infra-plan.yml NOT_PLANNABLE, drift-detection.yml matrix). The script it describes is scripts/migrate_observability_state.sh. -->

# Migrate observability's state: the split is not finished

```
DO       move every grafana_* object out of live/observability's state and into
         live/observability-alerting's.
WHY      THE SPLIT WAS CODE-ONLY AND THIS STACK IS APPLIED. Its state holds
         grafana_folder.{company,alerts,dashboards,slos,rally_dashboards,
         opshub_dashboards}, grafana_dashboard.system_overview,
         grafana_contact_point.teams, grafana_notification_policy.root and
         grafana_rule_group.series_near_cap — all created through the
         `grafana.stack` provider alias the split removed. So the plan now fails:

           Error: Provider configuration not present
           To work with grafana_folder.alerts (orphan) its original provider
           configuration at provider["...grafana/grafana"].stack is required,
           but it has been removed.

         `moved` blocks cannot fix this. They do not cross state files.
KNOW IT  `tofu plan` is clean in BOTH live/observability and
         live/observability-alerting, and `observability` can leave NOT_PLANNABLE
         in .github/workflows/infra-plan.yml.
SAFE?    Yes, and this is worth knowing before starting: nothing in Grafana is
         touched. The folders, dashboards and alert rules keep existing and keep
         working throughout. Only which state file OWNS them changes, so the
         failure mode is a duplicate or an unmanaged object, never a deleted one.
```

Order matters: remove from the old state only after the import into the new one
has succeeded, so an interrupted migration leaves the object managed twice rather
than not at all.

**`infra/scripts/migrate_observability_state.sh` does all of it**, and prefer it to
the commands below — it reads each import ID out of the old state instead of having
you transcribe ten UIDs, and Grafana's import IDs are not uniform (a folder is a
UID, a dashboard is `<folder-uid>:<dashboard-uid>`, the notification policy is the
literal string `policy`), which is where a hand-made migration goes wrong.

```bash
./scripts/migrate_observability_state.sh              # dry run — prints every import
APPLY=true ./scripts/migrate_observability_state.sh   # performs it
```

It refuses to `state rm` anything until the sibling's plan is **empty**, so a
configuration that disagrees with what is live in Grafana stops the migration
instead of being applied past. The commands below are the same steps by hand, kept
because a script you cannot read is not a runbook.

```bash
cd live/observability-alerting
tofu init
# IDs, not names. grafana_folder imports by UID; read them off the old state:
#   cd ../observability && tofu state show grafana_folder.alerts | grep -E '^\s+(id|uid)'
tofu import grafana_folder.company            <uid>
tofu import grafana_folder.alerts             <uid>
tofu import grafana_folder.dashboards         <uid>
tofu import grafana_folder.slos               <uid>
tofu import grafana_folder.rally_dashboards   <uid>
tofu import grafana_folder.opshub_dashboards  <uid>
tofu import grafana_dashboard.system_overview       <folder-uid>:<dashboard-uid>
tofu import grafana_contact_point.teams             <name>
tofu import grafana_notification_policy.root        policy
tofu import grafana_rule_group.series_near_cap      <folder-uid>:<group-name>

tofu plan          # MUST be empty. A diff here means an argument drifted from
                   # what is live, and that is worth resolving before proceeding.

cd ../observability
tofu state rm grafana_folder.company grafana_folder.alerts \
  grafana_folder.dashboards grafana_folder.slos \
  grafana_folder.rally_dashboards grafana_folder.opshub_dashboards \
  grafana_dashboard.system_overview grafana_contact_point.teams \
  grafana_notification_policy.root grafana_rule_group.series_near_cap
tofu plan          # MUST be clean, and MUST NOT propose destroying anything
```

**If `tofu plan` in the sibling is not empty, stop.** An unexpected diff means the
committed configuration disagrees with what is live in Grafana — which is exactly
the drift the split makes visible for the first time, and exactly the thing to
resolve deliberately rather than apply past.

---
