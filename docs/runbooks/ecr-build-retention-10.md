# Runbook: preview before `keep_build_count` 20 -> 10

Owner decision 2026-10-18: keep fewer build images, org-wide. `tf-modules` `ecr` changes the default
`keep_build_count` from 20 to 10 (the `v*` release rule is unchanged: production rollback images are kept by it).
**Nobody applies this to a live repository until the preview below is clean.** qnsc-kb-backend sets `keep_build_count = 5`
itself and is unaffected by the default, but is previewed too.

Everything here is **read-only**: `start-lifecycle-policy-preview` evaluates a policy text and deletes nothing.

## 1. Run the preview (one command)

Needs credentials (any role that can read ECR and ECS: `ecr:DescribeRepositories/DescribeImages/BatchGetImage/
StartLifecyclePolicyPreview/GetLifecyclePolicyPreview`, `ecs:List*/Describe*`), region `ap-southeast-1`:

```bash
export AWS_REGION=ap-southeast-1
python3 scripts/ecr_lifecycle_preview.py -o ecr-preview-$(date +%F).md; echo "exit=$?"
```

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

**Paste back:** the whole `ecr-preview-<date>.md` and the `exit=` line. The artefact has repository names, tags and image
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
