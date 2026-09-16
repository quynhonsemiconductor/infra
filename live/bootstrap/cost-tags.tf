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
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset([
    "product", # rova · opshub · kb · lms · solodesk · ai-dev-kit · shared
    "env",     # dev | prod — §7c
    "size",    # the criticality tier, so cost can be read against §5's presets
  ])

  tag_key = each.value
  status  = "Active"
}
