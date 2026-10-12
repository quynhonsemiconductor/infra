# EKS/k8s spike teardown, 2026-10-13

Record of the teardown of the six spike stacks (`rova-dev`, `cluster-dev`, `cluster-prod`, `data-dev`, `platform-dev`, `platform-prod`). All times +07.

The owner ran a purpose-built teardown kit (see "Archive"), one step at a time, with a fresh MFA session before each. Nothing outside the
six spike stacks was touched; every plan went through `plan_guard.py` (fail-closed) and every destroy was confirmed by typing the stack name.

| Step | Stack | Started | Ended | Destroyed |
|---|---|---|---|---|
| baseline (`FORCE_BASELINE=1`) | - | 00:10:30 | 00:12 | - |
| `--dry-run all` | all six | 00:12:22 | ~00:14 | 0 (the `s2.3` gate printed `gate OK` at 00:13:11) |
| s2.1 | rova-dev | 00:18:14 | 00:20:15 | **21** |
| s2.2 | cluster-dev (EKS qnsc-dev, tunnel, CNAME) | 00:22:13 | 00:27:15 | **30** |
| s2.3 | cluster-prod (EKS qnsc-prod) | 00:27:40 | 00:32:33 | **26** (gate OK at 00:27:51) |
| s2.4 | data-dev (RDS qnsc-shared-dev + qnsc-preview, cache; no final snapshot) | 00:37:41 | 00:45:05 | **12** |
| s2.5 | platform-dev (VPC 10.92, NAT instance) | 00:45:29 | 00:46:43 | **58** |
| s2.6 | platform-prod (VPC 10.93, NAT gateway + EIP) | 00:46:53 | 00:48:50 | **51** |
| s5.1 | re-inventory and diff | 00:49:11 | 00:50 | - |

**198 resources destroyed** (the counts are OpenTofu's `Apply complete! ... N destroyed`). Both prerequisites were met first: the denied-`AssumeRole`
alert reached `devops@` (2026-10-12T16:56:52Z) and the `devops@qnsc.vn` subscription is confirmed.

### s5.1, first run (00:49): everything PASS except one FALSE FAIL
```
  FAIL sqs: ap-southeast-1.sqs.json is MISSING/UNREADABLE in the AFTER inventory: cannot prove anything about it
1 FAIL, 0 WARN
```
Every other line was PASS: EKS, both VPC CIDRs, both spike RDS instances, the cache, 14 spike secrets and 2 `rds!` secrets, 16 spike IAM roles
and 2 EKS OIDC providers, log groups, the EIP, the old break-glass rule gone, and all shared items intact (5 databases, 2 caches, 5 ECS clusters,
9 ECR repositories, 3 S3 buckets, 2 KMS aliases, the SNS topic, 18 shared tfstate keys, the lock table ACTIVE, KMS key Enabled).

**Why the FAIL was false.** `inventory.sh` listed SQS with `--queue-name-prefix qnsc-`, i.e. only the spike's queues. After the teardown there are none,
`aws` prints nothing for an empty list, the file was 0 bytes, and `post_check.py` read a 0-byte file as unreadable. The five product queues
(`opshub-{develop,prod}-ses-bounce-feedback`, `rova-{develop,prod}-ses-bounce-feedback`, `rova-ses-bounce-feedback`) were intact (`list-queues`).
A second, expected error: `events-break-glass-targets` failed in `ap-southeast-1` because the old rule was deleted on purpose.

**Fixed in the archived kit** (not in this repository):
- `inventory.sh`: `save` writes `[]` when a call SUCCEEDED with no output; only a failed call leaves an `.err`. New `save_if_exists` treats
  `ResourceNotFoundException` as `[]` (used for the deleted rule). SQS now lists ALL queues (URLs only), like secrets.
- `post_check.py`: JSON `null` and `[]` are readable and empty; a 0-byte, non-JSON or missing file is unreadable. The five product queues are in `KEEP`,
  so their survival is proven, not assumed (an empty listing now fails as "EMPTY", for the right reason).
- Tests: `inventory_selftest.py` (12 checks incl. the regression, four hand-made mutants killed, one equivalent). `guard_selftest.py` (169) and
  `mutation_check.py` (78/78) pass again after their fixtures stopped depending on the old baseline shape.

**s5.1, re-run with the fixed tools (01:32): `0 FAIL, 1 WARN`.** `PASS sqs: spike gone (2 item(s) removed)`, `PASS sqs: shared items intact (5 checked)`, and one
WARN that the five product queues are "new since the baseline" (the baseline only listed `qnsc-` queues; expected once).

### Manual Cloudflare checklist (ticked by the owner, 2026-10-13)
The kit cannot see Cloudflare, so the owner checked it by hand on 2026-10-13: the tunnel `qnsc-dev` is gone (`qnsc-prod` never existed: cluster-prod's state held no
tunnel), the CNAME `rova-api-eks-dev.qnsc.vn` is gone, and the ECS estate's tunnels and records are intact. The tunnels that remain are exactly
`opshub-develop`, `qnsc-kb-develop`, `rova-develop` and `rova-prod`. (Owner's report; not re-verified from here.)

### Evidence that the six states are empty
The kit ran `tofu state list` after every apply and logged `state is empty` for all six stacks (00:20-00:48). The S3 objects agree: the state
keys shrank from 22-87 KB to 243-759 bytes (`rova-dev` 86,781 -> 759, `cluster-dev` 56,329 -> 446, `cluster-prod` 53,558 -> 445, `data-dev` 22,277 -> 243,
`platform-dev` 68,339 -> 468, `platform-prod` 59,040 -> 468). `data-prod` and `kb-dev` were never applied and have no state key. The old state objects are kept in
`qnsc-tofu-state` (versioned) as undo history.

### Archive
The kit itself is not in this repository, on purpose: it is single-use and targets resources that no longer exist, its redaction tests contain
credential-shaped canaries and its `raw*/` directories hold an account inventory, and the org's `gitleaks --all` scan would flag both in history forever.
It is kept by the owner as a local archive (`aws-eks-teardown-2026-10-13.tar.gz`). The lessons that are worth keeping are the design points: the guard read the plan, was
fail-closed, required the delete set to equal the whole prior state, allowlisted by pinned attribute, and had a global deny layer for shared infrastructure;
and an inventory that fails must never read as "all good" (and an empty answer must not read as a failure).
