# Runbook: preview before `keep_build_count` 20 -> 10

Owner decision 2026-10-18: keep fewer build images, org-wide. `tf-modules` `ecr` changes the default
`keep_build_count` from 20 to 10 (the `v*` release rule is unchanged: production rollback images are kept by it).
**Nobody applies this to a live repository until the preview below is clean.** qnsc-kb-backend sets `keep_build_count = 5`
itself and is unaffected by the default, but is previewed too.

Everything here is **read-only**: `start-lifecycle-policy-preview` evaluates a policy text and deletes nothing.

> **Correction, 2026-10-18 evening.** The first run of the v2 script PASSED on all three checks **vacuously**: the API spells the
> action `EXPIRE` and the script compared against `expire`, so it read zero expiring images (the table said `sha- 28 -> 28`
> while AWS's own summary said 26 images would expire). The checks, and the "rule 3 does nothing" reading, were built on that
> empty list. Fixed: case-insensitive, and the script now refuses to continue (INCOMPLETE) whenever the images it parsed do not
> match AWS's own expiring count. The same slip was in the original script; its earlier release-tag assertion was vacuous too.
> **Discard the earlier artefact and re-run.**

## 1. Run the preview (one command)

Needs credentials (any role that can read ECR and ECS: `ecr:DescribeRepositories/DescribeImages/BatchGetImage/
StartLifecyclePolicyPreview/GetLifecyclePolicyPreview`, `ecs:List*/Describe*`), region `ap-southeast-1`:

```bash
export AWS_REGION=ap-southeast-1
python3 scripts/ecr_lifecycle_preview.py -o ecr-preview-$(date +%F).md --inventory ecr-inventory-$(date +%F).json; echo "exit=$?"
```

(Use your MFA-backed profile, `AWS_PROFILE=<profile>`. `--inventory` also writes every image as JSON: digest, tags, size,
media type, children. Keep it; send it only if asked.)

It previews every product repository (rova, opshub, qnsc-kb x api/worker/migrator) with the policy the module will apply,
reads **every ECS cluster in the account** (develop and prod alike) and checks, per repository, that the policy would
expire **zero** images that:

1. carry a release (`v*`) tag;
2. are referenced by an ECS service deployment (PRIMARY or the ACTIVE one a rollback returns to), a running task (the tag
   or the digest it actually pulled), or the newest ACTIVE revision of any task-definition family (the migrators run
   from those), or are the per-architecture children of such a manifest list;
3. are per-architecture children (or attestations) of a manifest list the policy **keeps**.

Exit status: `0` PASS (all three are zero on every repository), `2` FAIL (the artefact names the images), `1` INCOMPLETE
(something could not be read; the artefact says what; a partial run is never a pass).

**Paste back:** the whole `ecr-preview-<date>.md` (it now ends with a **Breakdown** section per repository) and the `exit=` line. The artefact has repository names, tags and image
digests, no account id and no secret. The table has, per repository: images now, `sha-` images now -> after, images that
would expire, and the three zero-checks.

Run it again immediately before the apply: new pushes between the preview and the apply change the answer.

## 2. The same checks by hand (to cross-check the script)

```bash
R=rova-api   # repeat per repository
POLICY='{"rules":[
 {"rulePriority":1,"description":"untagged","selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":1},"action":{"type":"expire"}},
 {"rulePriority":2,"description":"release","selection":{"tagStatus":"tagged","tagPrefixList":["v"],"countType":"sinceImagePushed","countUnit":"days","countNumber":180},"action":{"type":"expire"}},
 {"rulePriority":3,"description":"builds","selection":{"tagStatus":"tagged","tagPrefixList":["sha-"],"countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}'
aws ecr start-lifecycle-policy-preview --repository-name "$R" --lifecycle-policy-text "$POLICY"
aws ecr get-lifecycle-policy-preview --repository-name "$R" \
  --query 'previewResults[].{digest:imageDigest,tags:imageTags,rule:appliedRulePriority}' --output json
```

(`qnsc-kb-*`: use `"countNumber":5` in rule 3.) What ECS references, develop and prod:

```bash
for c in $(aws ecs list-clusters --query 'clusterArns[]' --output text); do
  for s in $(aws ecs list-services --cluster "$c" --query 'serviceArns[]' --output text); do
    aws ecs describe-services --cluster "$c" --services "$s" --query 'services[].deployments[].taskDefinition' --output text
  done
  aws ecs list-tasks --cluster "$c" --desired-status RUNNING --query 'taskArns[]' --output text | xargs -n100 -r \
    aws ecs describe-tasks --cluster "$c" --query 'tasks[].containers[].[image,imageDigest]' --output text --tasks
done | sort -u
# then for each task-definition ARN printed above, and for the newest revision of each family:
aws ecs describe-task-definition --task-definition <arn-or-family> --query 'taskDefinition.containerDefinitions[].image' --output text
```

Compare: no `previewResults` entry may have a `v*` tag, a tag or digest that appears in the ECS output, or be a
per-architecture child (below).

## 3. Multi-architecture images

The `sha-<commit>` tag sits on a manifest list (OCI index); the per-architecture images and the buildx attestations are
**untagged**, so rule 1 (untagged after 1 day) selects them. AWS documents that an image referenced by a manifest list
cannot be expired while the list exists ("If an image is referenced by a manifest list, it cannot be expired or archived
without the manifest list being deleted or archived first", ECR lifecycle policy evaluation rules), and the module already
relies on this for attestations (`untagged_expire_days` description). The count in rule 3 is of **tagged** images, so one
per commit (the list); children are not counted. When a list is expired by rule 3, its children become unreferenced and
rule 1 removes them a day later: that is the intended cleanup.

The script measures this instead of trusting the documentation: it reads the manifest of every index image
(`batch-get-image`) and fails if the preview would expire any child of a list it keeps. To look at one by hand:

```bash
aws ecr batch-get-image --repository-name rova-api --image-ids imageTag=sha-<commit> \
  --accepted-media-types application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json \
  --query 'images[0].imageManifest' --output text | jq '.manifests[] | {digest, platform}'
```

## 4. Rollout order

1. tf-modules `feat(ecr)` PR merged, release-please releases `ecr-v2.2.0`.
2. Renovate (grouped "tf-modules" PR, Monday) or a one-line PR bumps `ref=ecr-v2.1.0` -> `ecr-v2.2.0` in
   `infra/live/_shared` of rova, opshub, qnsc-kb-backend.
3. Re-run step 1 on the day; PASS; the `_shared` plan shows only the lifecycle policy changing; apply.

## 5. Reading the breakdown: where the images are and why a rule does or does not select them

The artefact's per-repository **Breakdown** has one row per class, with count, size, how many are kept and how many each rule
would expire (rule 1 untagged, 2 release, 3 builds, 4 candidate):

| class | what it is | which rule can touch it |
| :--- | :--- | :--- |
| build sha-* (index) | the multi-arch manifest list tagged `sha-<commit>` | rule 3 (newest N kept) |
| build sha-* (single image) | a single-arch push | rule 3 |
| release v* | promoted image; also carries its `sha-` tag | rule 2 only (priority 2 beats 3: a `v*` image is never trimmed as a build) |
| untagged child of a kept list | per-architecture images and buildx provenance/SBOM manifests of a list the policy keeps | none, by design: ECR does not expire an image a list references |
| untagged child of an EXPIRING list | the same, once the list goes | rule 1, a day after the list goes |
| untagged orphan | no list references it | rule 1 after 1 day |
| referrer artifact (OCI subject) | a signature/attestation pushed with a `subject` (GitHub's `push-to-registry`) | ECR itself: expired within 24 h of its subject's deletion |
| referrer-by-tag `sha256-<digest>[.sig/.att/.sbom]` | tag-schema signatures/attestations: ordinary tagged images | **no rule today** |
| other tagged | everything else (`buildcache`, `pr-N`, ...); the distinct tag shapes are listed | none |

Expected shape, to compare with: a multi-arch build with provenance and SBOM is **5 images** (the list, two architectures, two
attestation manifests; `build-push-ecr` sets `provenance: mode=max` and `sbom: true`). 28 builds is therefore 140 of rova-api's
184 images before any release is counted, which is the "85% is not `sha-` tagged" seen: the children of kept lists, which leave
with their list and are not an accumulation.

The line **Rule 3 (keep the newest N)** ranks the `sha-*` images newest first as ECR does and accounts for each one beyond N:
`expires by rule 3`, or `KEPT: also tagged v*` (governed by rule 2), or **`NOT SELECTED and unexplained`**. If you ever see the
last one, paste the section back: that would be a real rule problem and the next step is a policy change, not a theory.

By hand, per repository, with no script (read-only):

```bash
R=rova-api
# classes: tagged?, manifest type, artifact type -> count
aws ecr describe-images --repository-name "$R" --output json | jq -r '.imageDetails
  | group_by([(.imageTags // [] | length > 0), .imageManifestMediaType, (.artifactMediaType // "-")])[]
  | [length, (.[0].imageTags // [] | length > 0), .[0].imageManifestMediaType, (.[0].artifactMediaType // "-")] | @tsv'
# distinct tag shapes
aws ecr describe-images --repository-name "$R" --query 'imageDetails[].imageTags[]' --output text | tr '\t' '\n' \
  | sed -E 's/[0-9a-f]{40,64}/<sha>/g; s/[0-9a-f]{7,39}/<hex>/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn
# which rule the preview applied (run start-lifecycle-policy-preview first, section 2)
aws ecr get-lifecycle-policy-preview --repository-name "$R" --output json | jq -r '.previewResults[] | [.appliedRulePriority, .action.type] | @tsv' | sort | uniq -c
```

## 6. Proposed module rule set (decide after the corrected run)

How ECR treats what is not a plain image (from the lifecycle evaluation rules): referrer artifacts (an OCI `subject`) are expired
automatically within 24 h of their subject's deletion; an image referenced by a manifest list is not expired while the list exists.
So **no module change is needed for rule 3, for children, or for subject-linked attestations**: the current three rules already
keep N builds, never touch children of kept lists, and leave `v*` to rule 2. In-use images are protected by the preview gate (they
are not something a lifecycle policy can know about), which is why the preview refuses to pass when one would expire.

The only thing no rule covers is tag-schema referrers (`sha256-<digest>[.sig/.att/.sbom]`), if the breakdown shows any: they are
tagged images with no `subject` ECR can follow. If they exist and accumulate, add an age-based rule at the end, with the age
longer than anything they can be attached to:

```hcl
# optional, off by default (null renders the current policy unchanged)
variable "referrer_tag_retention_days" {
  type    = number
  default = null # suggest release_retention_days + 30 = 210
}
# in the policy rules:
{
  rulePriority = 4
  description  = "Expire tag-schema referrers (sha256-*) older than ${var.referrer_tag_retention_days} days"
  selection = {
    tagStatus = "tagged", tagPatternList = ["sha256-*"],
    countType = "sinceImagePushed", countUnit = "days", countNumber = var.referrer_tag_retention_days
  }
  action = { type = "expire" }
}
```

Trade-off to accept explicitly: an attestation is pushed with its image, so a release (kept 180 days) always has one younger than
210 days; a *build* kept longer than that on a quiet repository would lose its registry copy of the attestation (GitHub keeps the
signed original; `gh attestation verify` still works). Evaluate it before adopting: `python3 scripts/ecr_lifecycle_preview.py
--referrer-tag-days 210` previews the policy with this rule 4 added. Do not add it if the breakdown shows no such tags.
