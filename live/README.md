# `live/` — one directory per stack

**One directory per stack, directly under `live/`, named `<name>-<env>`. Never
nested.**

```
live/
  bootstrap           organization        security-baseline
  observability       edge                          ← account-wide, no env
  cluster-dev         cluster-prod
  data-dev            data-prod
  runtime-dev         runtime-prod
  storage-dev         storage-prod                  ← platform, per env
  kb-dev              kb-prod
  opshub-dev          opshub-prod
  rova-dev            rova-prod       …             ← products, per env
```

## Why the depth is fixed

Nothing here maintains a list of stacks. Every tool in the pipeline **finds** them
by globbing a fixed depth:

| where | how it enumerates |
|---|---|
| `iac-lint` (fmt · validate · tflint) | `dirs: 'live/*/'` |
| `infra-plan.yml` detect step | `find live -name '*.tf' -exec dirname` |
| `infra-apply.yml` unmanaged report | the same `find` |
| `ci/scripts/platform_conformance.py` | `live / f"{product}-{env}"` |

A second depth means all four have to agree about it, forever. On 2026-09-16 they
did not. `kb` was the one nested stack — `live/kb/dev` — and `live/*/` never
reached it, so **no CI job had ever linted, validated or planned it**. Two bugs
went to `main` through that gap:

1. `source = "../../../../tf-modules/modules/product-profile"` — a path out of the
   repository. It resolves only on a machine with the repos side by side, so a
   local `tofu validate` passed while CI could not have read the module at all.
2. `?ref=product-profile-v1.0.0` — a tag nothing produced, because the module was
   missing from `release-please-config.json`. That fails at `tofu init`: at apply
   time, on the machine of whoever is mid-migration.

Three separate workarounds were written to accommodate one nested directory — a
`compgen` skip in `iac-lint`, a `live/*/ live/*/*/` glob here, and a nested path
join in the conformance tool — before it was cheaper to just flatten it.

## Platform or product is the STATE KEY, not the directory

```
platform/<stack>/terraform.tfstate     bootstrap, cluster-prod, data-dev, …
products/<stack>/terraform.tfstate     kb-dev, and every product after it
```

That distinction belongs in the key because `tofu` can read a key and cannot read
a directory tree. A `live/platform/` and `live/products/` split would express the
same thing one level deeper, and buy back the problem above.

Sorting does the grouping for free: `cluster-dev` sits beside `cluster-prod`, and
`kb-dev` beside `kb-prod`.

## Adding a stack

Create `live/<name>-<env>/` with a `*.tf`. That is the whole registration — the
plan job discovers it on the next run. If it cannot plan yet (its
`terraform_remote_state` dependencies are not applied), add it to `NOT_PLANNABLE`
in `.github/workflows/infra-plan.yml` **with the reason**, because a stack is
either planned or explicitly excluded, and there is no third state.

`infra-apply.yml` is deliberately NOT derived: adding a stack there starts
applying it on merge to `main`, which for an EKS cluster is a decision with a bill
attached. It reports what it does not manage on every run instead.
