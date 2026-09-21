# ─────────────────────────────────────────────────────────────────────────────
# Cost allocation tags — §12
#
# "Add this before migrating, not after. History cannot be reconstructed
#  retroactively, and the day the bill becomes QNSC's is the day two years of it
#  becomes valuable."
#
# In OpenTofu rather than the Billing console, because a console click nobody
# recorded is exactly what §12b cannot afford to depend on: §12b's entire
# contingency plan rests on per-product numbers existing when TrueIDC stops
# paying, and "someone clicked this once" is not a record.
#
# Activation is NOT retroactive. AWS begins recording a tag the day it is
# activated and says nothing about the days before. That is the whole reason this
# is the first thing applied and not the last.
#
# The tags themselves are set by product-profile's `locals.tags` and by each
# cluster and data stack. This only makes AWS record them.
#
# ── ⚠ OFF BY DEFAULT, AND NOT BECAUSE IT IS OPTIONAL ────────────────────────
#
# THIS ACCOUNT CANNOT ACTIVATE COST ALLOCATION TAGS. AWS refuses, structurally:
#
#   Error: updating Cost Explorer Cost Allocation Tag (size): ...
#   AccessDeniedException: Failed to update Cost Allocation Tag:
#   Linked account doesn't have access to cost allocation tags.
#
# Cost allocation tags are a PAYER-ACCOUNT facility. `608983206583` is a member
# account in TrueIDC's organisation — TrueIDC pays the bill under consolidated
# billing (see docs/data-residency-question.md) — so the activation has to happen
# in THEIR management account. No IAM policy in this account can grant it; widening
# the apply role would change nothing.
#
# ⚠ IT WAS BLOCKING EVERY APPLY. `bootstrap` is the first stack in
# `.github/workflows/infra-apply.yml`, so these three resources failed every run
# and the seven stacks behind them were skipped — three of the four most recent
# `Infrastructure · Apply` runs before 2026-09-20 were red for this reason and
# nothing else. Found 2026-09-20 when merging #141 auto-applied the pipeline and it
# failed after creating the chart registry.
#
# ── WHAT THIS MEANS FOR TASK 0.2 ────────────────────────────────────────────
#
# 0.2 is marked done in the implementation plan and is NOT. It reads "OWNER HUMAN —
# requires Billing console access", which was right about the owner and wrong about
# whose console: it is TrueIDC's, not ours. The ask is external, and §12's point
# stands undiminished — activation is NOT retroactive, AWS records a tag from the
# day it is switched on and says nothing about the days before, so every day this
# waits is a day of per-product history that cannot be reconstructed. §12b's
# contingency plan depends on those numbers existing when the bill transfers.
#
# Set this true only if QNSC becomes its own payer, or if AWS changes the API to
# accept a delegated administrator. Leaving the resources in code rather than
# deleting them is deliberate: the requirement is real and the code is the record
# of it.
variable "activate_cost_allocation_tags" {
  type        = bool
  default     = false
  description = <<-EOT
    Activate `product`, `env` and `size` as cost allocation tags. §12.

    FALSE because this is a member account and AWS rejects the call from one —
    "Linked account doesn't have access to cost allocation tags". See the comment
    above. TrueIDC must do it in the management account.
  EOT
}

resource "aws_ce_cost_allocation_tag" "this" {
  for_each = var.activate_cost_allocation_tags ? toset([
    "product", # rova · opshub · kb · lms · solodesk · ai-dev-kit · shared
    "env",     # dev | prod — §7c
    "size",    # the criticality tier, so cost can be read against §5's presets
  ]) : toset([])

  tag_key = each.value
  status  = "Active"
}
