#!/usr/bin/env python3
"""Preview the ECR lifecycle policy on EVERY repository in the estate, as a DRY RUN, and
write an artefact a human attaches to the task 0.7 PR before the policy is applied.

2026-10-18: `keep_build_count` goes from 20 to 10 (tf-modules `ecr`, owner decision), so this preview now answers
three questions per repository BEFORE anyone applies it, and exits 2 if ANY answer is "yes, it would expire":

  1. does it expire an image carrying a release (`v*`) tag?
  2. does it expire an image a running ECS task, a service deployment or the newest ACTIVE task-definition revision of a
     family (develop AND prod) references, by tag or by digest, or a per-architecture child of such a manifest list?
  3. does it expire a per-architecture CHILD image of a manifest list the policy keeps? (AWS documents that ECR will not;
     this measures it on the real repositories instead of trusting the documentation.)

WHY THIS EXISTS (§13; the open step is tracked in infra issue #175, carried over from the former implementation-plan.md task 0.7). `tf-modules/modules/ecr` moved the
RELEASE keep rule from a COUNT (`keep_release_count`) to a TIME window
(`release_retention_days = 180`) in ecr-v2.1.0. A time rule can delete images a count rule
was keeping, and the DIRECTION depends on the current promotion rate — at a low promotion
rate thirty releases may span more than 180 days, so the time rule deletes MORE; at a high
rate it deletes fewer. Which way it goes for THESE repositories cannot be reasoned out; it
has to be measured against the real image set. `aws ecr start-lifecycle-policy-preview` is
that measurement: it evaluates a policy against a repository's actual images and reports
what WOULD expire, deleting nothing.

The acceptance test for 0.7 is "the preview output is attached to a PR; it expires no
release anyone would want to roll back to." This script produces exactly that output for
every repository at once, so a human with credentials runs ONE thing and gets the
attachable artefact — rather than hand-running two AWS calls per repository and pasting
them together.

FAIL LOUD — the whole point, and the reason this is a script and not a one-liner.
This estate has twice shipped scanners that reported a clean state on data they never read
(infra commits 0d28db7 and 3b53296): a script that treats "the AWS call failed" the same as
"the call succeeded and found nothing" prints a FALSE GREEN, and a preview is the worst
possible place for one — it is the gate that decides whether a destructive lifecycle rule is
safe to apply. So this script:

  * raises on ANY AWS CLI failure, per repository, and names the repository (PreviewFailed);
  * distinguishes "repository has no images" (nothing to preview — reported, not silent)
    from "preview returned results";
  * treats a preview that never reaches a terminal status (COMPLETE/FAILED) as a failure,
    never as an empty clean result;
  * exits NON-ZERO if it could not fully preview every repository it was asked about, and
    prints WHICH ones it could not read;
  * never writes an artefact that claims success unless every repository reached COMPLETE.

A partial run is not a clean bill of health. If three repositories previewed and one could
not be read, the correct output is "1 repository COULD NOT BE PREVIEWED", exit 1 — not a
summary of the three that happened to work.

THE POLICY TEXT MUST MATCH THE MODULE. The preview evaluates the policy TEXT you give it,
so a preview of a policy that differs from what OpenTofu will apply proves nothing. This
script builds the policy from the SAME rules and defaults as tf-modules/modules/ecr/main.tf
(ecr-v2.1.0 with keep_build_count = 10, released as ecr-v2.2.0), with the per-caller overrides the live callers pass
(see REPOSITORIES). If the module's rules change, change them here too, or the preview lies.

USAGE
  # READ-ONLY. Requires AWS credentials with ecr:StartLifecyclePolicyPreview, ecr:GetLifecyclePolicyPreview,
  # ecr:DescribeRepositories, ecr:DescribeImages, ecr:BatchGetImage, and ecs:ListClusters, ecs:ListServices,
  # ecs:DescribeServices, ecs:ListTasks, ecs:DescribeTasks, ecs:ListTaskDefinitionFamilies, ecs:DescribeTaskDefinition.
  # (start-lifecycle-policy-preview writes nothing to the repository: it evaluates the policy text you pass.)
  python3 scripts/ecr_lifecycle_preview.py                 # preview known estate repos
  python3 scripts/ecr_lifecycle_preview.py --discover      # ALSO preview any repo the
                                                           # account has that we don't know
  python3 scripts/ecr_lifecycle_preview.py -o preview.md   # write artefact to preview.md
  python3 scripts/ecr_lifecycle_preview.py --inventory inv.json          # also dump every image as JSON
  python3 scripts/ecr_lifecycle_preview.py --referrer-tag-days 210       # preview a CANDIDATE rule 4 for sha256-* tags

  Default artefact path is ecr-lifecycle-preview-<date>.md in the CWD.

NO CREDENTIALS
  With no credentials every StartLifecyclePolicyPreview call fails, so the script raises
  PreviewFailed for every repository, prints each one as COULD NOT PREVIEW, and exits 1
  without writing a success artefact. That is the correct behaviour, and running it this way
  is how you prove the fail-loud path works (see --self-test-no-creds, which asserts it).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import time

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

# ── Policy parameters, mirrored from tf-modules/modules/ecr (ecr-v2.1.0 + keep_build_count 10) ──
# Keep these in lockstep with modules/ecr/main.tf and variables.tf. The preview is only
# meaningful if the text below is the text OpenTofu will apply.
DEFAULT_RELEASE_TAG_PREFIX = "v"
DEFAULT_BUILD_TAG_PREFIX = "sha-"
DEFAULT_RELEASE_RETENTION_DAYS = 180
DEFAULT_KEEP_BUILD_COUNT = 10  # was 20 before ecr-v2.2.0
DEFAULT_UNTAGGED_EXPIRE_DAYS = 1

# ── The estate's repositories and any per-caller overrides ───────────────────────────────
# Sourced from the four ECR module callers:
#   rova/infra/live/_shared/main.tf            (module defaults)
#   opshub/infra/live/_shared/main.tf          (module defaults)
#   qnsc-kb-backend/infra/live/_shared/main.tf (keep_build_count = 5; release_retention_days = 180)
#   infra-template/live/_shared/main.tf        (template — __PRODUCT__, not a live repo)
# infra-template is intentionally absent: __PRODUCT__-* is a placeholder, not a real repo.
REPOSITORIES: dict[str, dict] = {
    "rova-api": {},
    "rova-worker": {},
    "rova-migrator": {},
    "opshub-api": {},
    "opshub-worker": {},
    "opshub-migrator": {},
    "qnsc-kb-api": {"keep_build_count": 5},
    "qnsc-kb-worker": {"keep_build_count": 5},
    "qnsc-kb-migrator": {"keep_build_count": 5},
}

# How long to wait for a preview to reach a terminal status before treating it as unread.
PREVIEW_POLL_SECONDS = 3
PREVIEW_TIMEOUT_SECONDS = 120


class PreviewFailed(Exception):
    """A repository could not be fully previewed, as distinct from being previewed and found
    to expire nothing. This distinction is the whole reason the script exists: see 0d28db7
    and 3b53296. An unreadable repository must be LOUDER than an empty one, never quieter."""


def _aws(*args: str) -> object:
    """Run an AWS CLI command and parse its JSON. Dependency-free (the CLI is preinstalled
    on GitHub runners), matching scripts/unmanaged_resources.py. Raises PreviewFailed on a
    non-zero exit rather than returning None — the entire point."""
    cmd = ["aws", *args, "--region", REGION, "--output", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise PreviewFailed(f"`{' '.join(cmd[:3])} …` failed: {result.stderr.strip()[:300]}")
    return json.loads(result.stdout or "null")


def build_policy(overrides: dict) -> dict:
    """Build the lifecycle policy for one repository, identical in structure and priority to
    tf-modules/modules/ecr/main.tf. Rule priorities matter: a promoted image carries both a
    `v` and a `sha-` tag and matches both the release rule and the build rule, and ECR
    applies the LOWEST rulePriority — so the release (keep-longer) rule MUST be priority 2,
    ahead of the build rule at 3."""
    release_days = overrides.get("release_retention_days", DEFAULT_RELEASE_RETENTION_DAYS)
    build_count = overrides.get("keep_build_count", DEFAULT_KEEP_BUILD_COUNT)
    untagged_days = overrides.get("untagged_expire_days", DEFAULT_UNTAGGED_EXPIRE_DAYS)
    release_prefix = overrides.get("release_tag_prefix", DEFAULT_RELEASE_TAG_PREFIX)
    build_prefix = overrides.get("build_tag_prefix", DEFAULT_BUILD_TAG_PREFIX)
    policy = {
        "rules": [
            {
                "rulePriority": 1,
                "description": f"Remove untagged images after {untagged_days} day(s)",
                "selection": {
                    "tagStatus": "untagged",
                    "countType": "sinceImagePushed",
                    "countUnit": "days",
                    "countNumber": untagged_days,
                },
                "action": {"type": "expire"},
            },
            {
                "rulePriority": 2,
                "description": f"Expire release ({release_prefix}*) images older than {release_days} days",
                "selection": {
                    "tagStatus": "tagged",
                    "tagPrefixList": [release_prefix],
                    "countType": "sinceImagePushed",
                    "countUnit": "days",
                    "countNumber": release_days,
                },
                "action": {"type": "expire"},
            },
            {
                "rulePriority": 3,
                "description": f"Keep the last {build_count} build ({build_prefix}*) images",
                "selection": {
                    "tagStatus": "tagged",
                    "tagPrefixList": [build_prefix],
                    "countType": "imageCountMoreThan",
                    "countNumber": build_count,
                },
                "action": {"type": "expire"},
            },
        ]
    }
    referrer_days = overrides.get("referrer_tag_days")
    if referrer_days:
        # CANDIDATE rule, only when asked for (--referrer-tag-days): tag-schema referrers/signatures (`sha256-<digest>[.sig]`)
        # are ordinary tagged images that no other rule selects and that carry no `subject` ECR could follow.
        policy["rules"].append({
            "rulePriority": 4,
            "description": f"Expire sha256-* referrer tags older than {referrer_days} days",
            "selection": {"tagStatus": "tagged", "tagPatternList": ["sha256-*"], "countType": "sinceImagePushed",
                          "countUnit": "days", "countNumber": referrer_days},
            "action": {"type": "expire"},
        })
    return policy


INDEX_MEDIA_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
ECR_IMAGE = re.compile(
    r"^(?P<host>\d+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com)/(?P<repo>[^:@]+)(?::(?P<tag>[^@]+))?(?:@(?P<digest>sha256:[0-9a-f]+))?$"
)


def chunks(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i : i + size]


def parse_image_ref(image: str) -> dict | None:
    """`<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` (and/or `@sha256:...`) -> {repo, tag, digest}; None for any
    other registry. The account id is parsed away on purpose and never printed."""
    match = ECR_IMAGE.match(image or "")
    if not match:
        return None
    return {"repo": match["repo"], "tag": match["tag"], "digest": match["digest"]}


def describe_images(repo: str) -> list[dict]:
    """Every image in the repository: digest, tags, manifest media type, push time."""
    details = (_aws("ecr", "describe-images", "--repository-name", repo) or {}).get("imageDetails", [])
    return [
        {
            "digest": d.get("imageDigest"),
            "tags": d.get("imageTags") or [],
            "media_type": d.get("imageManifestMediaType") or "",
            "pushed_at": d.get("imagePushedAt"),
            "size": int(d.get("imageSizeInBytes") or 0),
            "artifact_media_type": d.get("artifactMediaType") or "",
            "subject": d.get("subjectManifestDigest") or "",
        }
        for d in details
    ]


def child_kind(entry: dict) -> str:
    """What an index entry is: buildx marks its provenance/SBOM manifests with this annotation and an `unknown/unknown` platform."""
    annotations = entry.get("annotations") or {}
    platform = entry.get("platform") or {}
    if annotations.get("vnd.docker.reference.type") == "attestation-manifest" or platform.get("architecture") == "unknown":
        return "attestation"
    return f"{platform.get('os', '?')}/{platform.get('architecture', '?')}"


def manifest_children(repo: str, images: list[dict]) -> tuple[dict[str, list[str]], dict[str, str]]:
    """For every manifest LIST / OCI index in the repository: the digests of the images it references (per-architecture
    children and buildx attestations), and what each child is. Read from the manifests themselves, not inferred."""
    lists = [i["digest"] for i in images if i["media_type"] in INDEX_MEDIA_TYPES]
    children: dict[str, list[str]] = {}
    kinds: dict[str, str] = {}
    for group in chunks(lists, 20):
        args = ["ecr", "batch-get-image", "--repository-name", repo, "--accepted-media-types", *INDEX_MEDIA_TYPES, "--image-ids"]
        args += [f"imageDigest={d}" for d in group]
        out = _aws(*args) or {}
        if out.get("failures"):
            raise PreviewFailed(f"{repo}: batch-get-image could not read manifest(s): {out['failures'][:3]}")
        for item in out.get("images", []):
            digest = (item.get("imageId") or {}).get("imageDigest")
            try:
                manifest = json.loads(item.get("imageManifest") or "{}")
            except json.JSONDecodeError as exc:
                raise PreviewFailed(f"{repo}: manifest of {digest} is not JSON: {exc}") from exc
            children[digest] = [m.get("digest") for m in manifest.get("manifests", []) if m.get("digest")]
            for entry in manifest.get("manifests", []):
                if entry.get("digest"):
                    kinds.setdefault(entry["digest"], child_kind(entry))
        missing = [d for d in group if d not in children]
        if missing:
            raise PreviewFailed(f"{repo}: no manifest returned for {len(missing)} index image(s), e.g. {missing[0]}")
    return children, kinds


def collect_in_use() -> list[dict]:
    """Every ECR image reference the ECS estate depends on, develop and prod alike (all clusters of the account/region):

      * the task definition of EVERY deployment of EVERY service (PRIMARY and the ACTIVE one a rollback would return to),
      * the task definition and the resolved image digest of every RUNNING task,
      * the newest ACTIVE revision of every task-definition family (one-shot tasks such as the migrator run from these).

    Raises PreviewFailed on any ECS failure: an estate that could not be read must not read as an estate with nothing in use."""
    refs: list[dict] = []
    task_defs: dict[str, str] = {}  # arn -> why

    clusters = (_aws("ecs", "list-clusters") or {}).get("clusterArns", [])
    for cluster in clusters:
        name = cluster.split("/")[-1]
        services = (_aws("ecs", "list-services", "--cluster", cluster) or {}).get("serviceArns", [])
        for group in chunks(services, 10):
            described = _aws("ecs", "describe-services", "--cluster", cluster, "--services", *group) or {}
            if described.get("failures"):
                raise PreviewFailed(f"ecs describe-services failed in {name}: {described['failures'][:2]}")
            for svc in described.get("services", []):
                for dep in svc.get("deployments", []):
                    arn = dep.get("taskDefinition")
                    if arn:
                        task_defs.setdefault(arn, f"{name}/{svc.get('serviceName')} {dep.get('status', '?')} deployment")
        tasks = (_aws("ecs", "list-tasks", "--cluster", cluster, "--desired-status", "RUNNING") or {}).get("taskArns", [])
        for group in chunks(tasks, 100):
            described = _aws("ecs", "describe-tasks", "--cluster", cluster, "--tasks", *group) or {}
            if described.get("failures"):
                raise PreviewFailed(f"ecs describe-tasks failed in {name}: {described['failures'][:2]}")
            for task in described.get("tasks", []):
                arn = task.get("taskDefinitionArn")
                if arn:
                    task_defs.setdefault(arn, f"{name} running task")
                for container in task.get("containers", []):
                    parsed = parse_image_ref(container.get("image", ""))
                    if parsed:
                        refs.append({**parsed, "digest": container.get("imageDigest") or parsed["digest"], "source": f"{name} running task ({container.get('name')})"})

    families = (_aws("ecs", "list-task-definition-families", "--status", "ACTIVE") or {}).get("families", [])
    for family in families:
        latest = (_aws("ecs", "describe-task-definition", "--task-definition", family) or {}).get("taskDefinition", {})
        if latest.get("taskDefinitionArn"):
            task_defs.setdefault(latest["taskDefinitionArn"], f"newest ACTIVE revision of {family}")

    for arn, why in task_defs.items():
        definition = (_aws("ecs", "describe-task-definition", "--task-definition", arn) or {}).get("taskDefinition", {})
        label = f"{why}: {arn.split('/')[-1]}"
        for container in definition.get("containerDefinitions", []):
            parsed = parse_image_ref(container.get("image", ""))
            if parsed:
                refs.append({**parsed, "source": f"{label} ({container.get('name')})"})
    return refs


def classify_expiring(repo: str, images: list[dict], expiring: list[dict], children: dict[str, list[str]], in_use: list[dict]) -> dict:
    """Pure: which of the images the preview would expire are (a) release-tagged, (b) in use, (c) a child of a manifest
    list that is KEPT. `expiring` items are {digest, tags}; `children` maps a list digest to its children's digests."""
    expiring_digests = {e["digest"] for e in expiring}
    by_tag = {t: i["digest"] for i in images for t in i["tags"]}

    in_use_digests: dict[str, str] = {}  # digest -> why
    for ref in in_use:
        if ref["repo"] != repo:
            continue
        if ref.get("digest"):
            in_use_digests.setdefault(ref["digest"], ref["source"])
        if ref.get("tag") and ref["tag"] in by_tag:
            in_use_digests.setdefault(by_tag[ref["tag"]], f"{ref['source']} (tag {ref['tag']})")
    for parent, why in list(in_use_digests.items()):  # a running list keeps its children too
        for child in children.get(parent, []):
            in_use_digests.setdefault(child, f"child of {why}")
    for parent, kids in children.items():  # and a running child (a task reports the digest it pulled) keeps its list
        running = next((in_use_digests[k] for k in kids if k in in_use_digests), None)
        if running:
            in_use_digests.setdefault(parent, f"manifest list of {running}")

    kept_children: dict[str, str] = {}
    for parent, kids in children.items():
        if parent in expiring_digests:
            continue
        label = next((",".join(i["tags"]) for i in images if i["digest"] == parent), parent) or parent
        for kid in kids:
            kept_children.setdefault(kid, label)

    release, used, orphaned = [], [], []
    for e in expiring:
        entry = {"digest": e["digest"], "tags": e["tags"]}
        if any(t.startswith(DEFAULT_RELEASE_TAG_PREFIX) and t != "latest" for t in e["tags"]):
            release.append(entry)
        if e["digest"] in in_use_digests:
            used.append({**entry, "why": in_use_digests[e["digest"]]})
        if e["digest"] in kept_children:
            orphaned.append({**entry, "parent": kept_children[e["digest"]]})
    return {"release": release, "in_use": used, "children_of_kept_lists": orphaned}



def repository_exists(repo: str) -> bool:
    """True if the repository exists. A repository that does not exist yet (the products are
    not yet created) cannot be
    previewed, and that is reported honestly, not silently skipped."""
    try:
        _aws("ecr", "describe-repositories", "--repository-names", repo)
        return True
    except PreviewFailed as exc:
        # A genuine "does not exist" is RepositoryNotFoundException. Anything else (denied,
        # throttled, no credentials) is a real failure and must propagate — do NOT swallow
        # it as "absent", or an unreadable account reads as an empty one.
        if "RepositoryNotFoundException" in str(exc):
            return False
        raise


def preview_repository(repo: str, overrides: dict) -> dict:
    """Start and poll a lifecycle-policy preview for one repository. Returns the terminal
    preview result. Raises PreviewFailed if the repository is unreadable, or if the preview
    never reaches a terminal status, or if it comes back FAILED. Never returns a partial or
    ambiguous result dressed as success."""
    policy_text = json.dumps(build_policy(overrides))

    # Starting a preview when one is already running returns
    # LifecyclePolicyPreviewInProgressException; the running one is fine to read, so treat
    # that specific case as "already started" rather than a failure.
    try:
        _aws(
            "ecr", "start-lifecycle-policy-preview",
            "--repository-name", repo,
            "--lifecycle-policy-text", policy_text,
        )
    except PreviewFailed as exc:
        if "LifecyclePolicyPreviewInProgressException" not in str(exc):
            raise

    deadline = time.time() + PREVIEW_TIMEOUT_SECONDS
    while True:
        result = _aws("ecr", "get-lifecycle-policy-preview", "--repository-name", repo)
        if not isinstance(result, dict):
            raise PreviewFailed(f"{repo}: get-lifecycle-policy-preview returned no object")
        status = result.get("status")
        if status == "COMPLETE":
            return result
        if status == "FAILED":
            raise PreviewFailed(f"{repo}: preview status FAILED — {result.get('summary')}")
        if status not in ("IN_PROGRESS", "EXPIRED", None):
            raise PreviewFailed(f"{repo}: unexpected preview status {status!r}")
        if time.time() > deadline:
            raise PreviewFailed(
                f"{repo}: preview did not reach COMPLETE within {PREVIEW_TIMEOUT_SECONDS}s "
                f"(last status {status!r}) — treating as UNREAD, not as clean"
            )
        time.sleep(PREVIEW_POLL_SECONDS)


def summarise(repo: str, result: dict, images: list[dict], children: dict[str, list[str]], in_use: list[dict],
              kinds: dict[str, str] | None = None, keep_build: int = DEFAULT_KEEP_BUILD_COUNT) -> dict:
    """Reduce a COMPLETE preview to the facts the reviewer needs: how many images the policy would expire, and the
    acceptance tests: none carries a release (`v*`) tag, none is referenced by the ECS estate, none is a child of a
    manifest list the policy keeps. Also a breakdown of the whole repository by class, with the rule that hit each image."""
    expiring = []
    for pr in result.get("previewResults") or []:
        # The API spells the action in capitals ("EXPIRE"). Comparing against lower-case silently matched NOTHING, so every
        # check below ran on an empty list and passed while the AWS summary said 26 images would expire.
        if str((pr.get("action") or {}).get("type", "")).lower() == "expire":
            expiring.append({"digest": pr.get("imageDigest"), "tags": pr.get("imageTags") or [], "priority": pr.get("appliedRulePriority")})
    summary = result.get("summary") or {}
    reported = summary.get("expiringImageTotalCount")
    if reported is not None and reported != len(expiring):
        raise PreviewFailed(
            f"{repo}: AWS says {reported} image(s) would expire but {len(expiring)} were read from the preview results; "
            f"every check built on this list would be wrong, so this is an error and not a pass"
        )
    checks = classify_expiring(repo, images, expiring, children, in_use)
    build_prefix = DEFAULT_BUILD_TAG_PREFIX
    builds_now = sum(1 for i in images if any(t.startswith(build_prefix) for t in i["tags"]))
    builds_expiring = sum(1 for e in expiring if any(t.startswith(build_prefix) for t in e["tags"]))
    return {
        "repository": repo,
        "status": result.get("status"),
        "images_total": len(images),
        "build_images_now": builds_now,
        "build_images_after": builds_now - builds_expiring,
        "expiring_image_count": len(expiring),
        "expiring_with_release_tag": checks["release"],
        "expiring_in_use": checks["in_use"],
        "expiring_children_of_kept_lists": checks["children_of_kept_lists"],
        "index_images": len(children),
        "expiring_sample": expiring[:25],
        "breakdown": breakdown(images, expiring, children, kinds or {}, keep_build),
    }


RELEASE_RE = re.compile(r"^v\d")
REFERRER_TAG = re.compile(r"^sha256-[0-9a-f]{64}(\..+)?$")


def tag_pattern(tag: str) -> str:
    """`sha-3f9a2c1` -> `sha-<hex>`, `v1.2.3` -> `vN.N.N`, `pr-123` -> `pr-N`: the shape of a tag, to count distinct kinds."""
    tag = re.sub(r"[0-9a-f]{40,64}", "<sha>", tag)
    tag = re.sub(r"(?<![0-9a-zA-Z])[0-9a-f]{7,39}(?![0-9a-zA-Z])|(?<=-)[0-9a-f]{7,39}(?![0-9a-zA-Z])", "<hex>", tag)
    return re.sub(r"\d+", "N", tag)


def image_class(image: dict, parents_kept: set[str], parents_expiring: set[str], child_of: dict[str, str]) -> str:
    """One class per image, in the order that explains why a rule does or does not select it."""
    tags = image["tags"]
    is_index = image["media_type"] in INDEX_MEDIA_TYPES
    if image.get("subject") or (image.get("artifact_media_type") and not image["artifact_media_type"].startswith(
            ("application/vnd.docker.container.image", "application/vnd.oci.image.config", "application/vnd.oci.empty"))):
        return "referrer artifact (OCI subject)"
    if tags:
        if any(RELEASE_RE.match(t) for t in tags):
            return "release v* (index)" if is_index else "release v* (single image)"
        if any(t.startswith(DEFAULT_BUILD_TAG_PREFIX) for t in tags):
            return "build sha-* (index)" if is_index else "build sha-* (single image)"
        if any(REFERRER_TAG.match(t) for t in tags):
            return "referrer-by-tag sha256-<digest>[.sig/.att/.sbom]"
        return "other tagged"
    if image["digest"] in child_of:
        return f"untagged child of a {'kept' if child_of[image['digest']] in parents_kept else 'EXPIRING'} list"
    return "untagged orphan (no list references it)"


def breakdown(images: list[dict], expiring: list[dict], children: dict[str, list[str]], kinds: dict[str, str], keep_build: int) -> dict:
    """Counts and sizes per class, which rule hit the expiring ones, the tag shapes, and why rule 3 does or does not select
    the build images. Sizes are the sum of each image's reported size: layers shared between images are counted once PER
    image, so the total overstates the bytes stored and the split between classes is the useful part."""
    hit = {e["digest"]: e["priority"] for e in expiring}
    expiring_digests = set(hit)
    child_of = {kid: parent for parent, kids in children.items() for kid in kids}
    parents_kept = {p for p in children if p not in expiring_digests}
    parents_expiring = set(children) - parents_kept
    classes: dict[str, dict] = {}
    other_patterns: dict[str, int] = {}
    artifact_types: dict[str, int] = {}
    child_kinds: dict[str, int] = {}
    for image in images:
        cls = image_class(image, parents_kept, parents_expiring, child_of)
        row = classes.setdefault(cls, {"images": 0, "bytes": 0, "expire_by_rule": {}, "kept": 0})
        row["images"] += 1
        row["bytes"] += image["size"]
        if image["digest"] in hit:
            rule = str(hit[image["digest"]])
            row["expire_by_rule"][rule] = row["expire_by_rule"].get(rule, 0) + 1
        else:
            row["kept"] += 1
        if cls == "other tagged":
            for t in image["tags"]:
                other_patterns[tag_pattern(t)] = other_patterns.get(tag_pattern(t), 0) + 1
        if image.get("artifact_media_type"):
            artifact_types[image["artifact_media_type"]] = artifact_types.get(image["artifact_media_type"], 0) + 1
        if image["digest"] in child_of:
            child_kinds[kinds.get(image["digest"], "?")] = child_kinds.get(kinds.get(image["digest"], "?"), 0) + 1

    # Why rule 3 does or does not select the build images: rank them as ECR does (newest first, by push time).
    builds = sorted((i for i in images if any(t.startswith(DEFAULT_BUILD_TAG_PREFIX) for t in i["tags"])),
                    key=lambda i: str(i["pushed_at"]), reverse=True)
    beyond = builds[keep_build:]
    diagnosis = []
    for image in beyond:
        tags = ",".join(image["tags"])
        priority = hit.get(image["digest"])
        if priority is not None:
            diagnosis.append({"tags": tags, "digest": image["digest"], "result": f"expires by rule {priority}"})
        elif any(RELEASE_RE.match(t) for t in image["tags"]):
            diagnosis.append({"tags": tags, "digest": image["digest"],
                              "result": "KEPT: also tagged v*, so rule 2 (priority 2, 180 days) governs it and rule 3 (priority 3) may not expire it"})
        else:
            diagnosis.append({"tags": tags, "digest": image["digest"], "result": "NOT SELECTED and unexplained: beyond the newest N, no release tag, not in the preview"})
    return {
        "classes": classes,
        "other_tag_patterns": dict(sorted(other_patterns.items(), key=lambda kv: -kv[1])),
        "artifact_media_types": artifact_types,
        "child_kinds": child_kinds,
        "build_images": len(builds),
        "keep_build": keep_build,
        "builds_beyond_keep": len(beyond),
        "builds_beyond_keep_diagnosis": diagnosis,
        "expiring_by_rule": {str(r): sum(1 for p in hit.values() if p == r) for r in sorted({p for p in hit.values() if p is not None})},
    }


def render_artefact(previewed: list[dict], empty: list[str], failed: dict[str, str], in_use_count: int | None) -> str:
    now = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")
    lines = [
        "# ECR lifecycle-policy preview (keep_build_count 10; release rule unchanged)",
        "",
        f"Generated: {now}  ·  region: {REGION}",
        "",
        f"Dry run of `aws ecr start-lifecycle-policy-preview` with the ecr-v2.1.0 policy and keep_build_count = "
        f"{DEFAULT_KEEP_BUILD_COUNT} (qnsc-kb passes its own 5). Nothing was deleted. "
        + (f"{in_use_count} image reference(s) in use by the ECS estate were cross-checked." if in_use_count is not None else "ECS was NOT read."),
        "",
    ]
    total_release = sum(len(p["expiring_with_release_tag"]) for p in previewed)
    total_used = sum(len(p["expiring_in_use"]) for p in previewed)
    total_children = sum(len(p["expiring_children_of_kept_lists"]) for p in previewed)
    if failed:
        lines += [
            "## ⚠ INCOMPLETE — do NOT treat this as a clean preview",
            "",
            f"{len(failed)} repository/repositories COULD NOT BE PREVIEWED. A partial preview "
            "is not a clean bill of health (see infra 0d28db7 / 3b53296). Resolve these and "
            "re-run before applying:",
            "",
        ]
        for repo, why in failed.items():
            lines.append(f"- **{repo}** — {why}")
        lines.append("")
    lines += ["## Verdict", ""]
    if not previewed:
        lines += [
            "**No repository was successfully previewed, so there is NO verdict.** This run "
            "says nothing about what the policy would delete. Resolve the failures above and "
            "re-run before applying.",
            "",
        ]
    else:
        bad = total_release + total_used + total_children
        lines += [
            f"- images carrying a release (`v*`) tag that would expire: **{total_release}**",
            f"- images referenced by an ECS service deployment, running task or newest ACTIVE task definition that would expire: **{total_used}**",
            f"- per-architecture children of a KEPT manifest list that would expire: **{total_children}**",
            "",
            ("**FAIL — do not apply.** Raise the retention (or fix what holds the reference) until all three are zero."
             if bad else
             f"**PASS — all three are zero on the {len(previewed)} repository/repositories that previewed.**"),
            "",
        ]
        if failed:
            lines += [f"The verdict covers only the repositories that previewed; the {len(failed)} above were not read.", ""]
    lines += [
        "## Per repository",
        "",
        "| repository | images now | `sha-` now → after | expiring | release-tagged | in use | children of kept lists |",
        "| :--------- | ---------: | -----------------: | -------: | -------------: | -----: | ---------------------: |",
    ]
    for p in previewed:
        lines.append(
            f"| {p['repository']} | {p['images_total']} | {p['build_images_now']} → {p['build_images_after']} | {p['expiring_image_count']} "
            f"| {len(p['expiring_with_release_tag'])} | {len(p['expiring_in_use'])} | {len(p['expiring_children_of_kept_lists'])} |"
        )
    for repo in empty:
        lines.append(f"| {repo} | 0 | – | 0 | 0 | 0 | 0 |")
    for repo in failed:
        lines.append(f"| {repo} | **COULD NOT PREVIEW** | ? | ? | ? | ? | ? |")
    lines.append("")
    for p in previewed:
        for key, title in (("expiring_with_release_tag", "release images that would expire"),
                           ("expiring_in_use", "images in use that would expire"),
                           ("expiring_children_of_kept_lists", "children of kept manifest lists that would expire")):
            if p[key]:
                lines += [f"### {p['repository']}: {title}", ""]
                for img in p[key]:
                    extra = img.get("why") or img.get("parent") or ""
                    lines.append(f"- `{', '.join(img['tags']) or '(untagged)'}` ({img['digest']}) {extra}")
                lines.append("")
    for p in previewed:
        lines += render_breakdown(p)
    return "\n".join(lines)


def human(n: int) -> str:
    size = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return str(n)


def render_breakdown(p: dict) -> list[str]:
    b = p["breakdown"]
    lines = [f"## Breakdown: {p['repository']}", "",
             f"{p['images_total']} images; the policy would expire {p['expiring_image_count']} "
             f"(by rule: {', '.join(f'rule {r}: {n}' for r, n in b['expiring_by_rule'].items()) or 'none'}). "
             "Sizes add up each image's reported size, so layers shared between images are counted once per image.", "",
             "| class | images | size | kept | expire by rule 1 | rule 2 | rule 3 | rule 4 |",
             "| :---- | -----: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for cls, row in sorted(b["classes"].items(), key=lambda kv: -kv[1]["images"]):
        by = row["expire_by_rule"]
        lines.append(f"| {cls} | {row['images']} | {human(row['bytes'])} | {row['kept']} | {by.get('1', 0)} | {by.get('2', 0)} | {by.get('3', 0)} | {by.get('4', 0)} |")
    lines.append("")
    if b["child_kinds"]:
        lines.append("Untagged children by kind (read from the index manifests): " + ", ".join(f"{k}: {n}" for k, n in sorted(b["child_kinds"].items())))
        lines.append("")
    if b["other_tag_patterns"]:
        lines.append("Other tagged: distinct tag shapes: " + ", ".join(f"`{k}` x{n}" for k, n in b["other_tag_patterns"].items()))
        lines.append("")
    if b["artifact_media_types"]:
        lines.append("Artifact media types present: " + ", ".join(f"`{k}` x{n}" for k, n in b["artifact_media_types"].items()))
        lines.append("")
    lines.append(f"**Rule 3 (keep the newest {b['keep_build']} `sha-*` images):** {b['build_images']} build images; "
                 f"{b['builds_beyond_keep']} rank beyond the newest {b['keep_build']}.")
    unexplained = [d for d in b["builds_beyond_keep_diagnosis"] if d["result"].startswith("NOT SELECTED")]
    if not b["builds_beyond_keep_diagnosis"]:
        lines.append("Nothing to expire: the repository holds no more than the number to keep.")
    else:
        lines.append(("All of them are accounted for:" if not unexplained else f"**{len(unexplained)} of them are NOT expiring for no reason this script can find:**"))
        for d in b["builds_beyond_keep_diagnosis"][:30]:
            lines.append(f"- `{d['tags']}` ({d['digest']}): {d['result']}")
    lines.append("")
    return lines


def run(discover: bool, out_path: str, inventory_path: str | None = None, referrer_tag_days: int | None = None) -> int:
    repos = {name: dict(o) for name, o in REPOSITORIES.items()}
    if referrer_tag_days:
        for o in repos.values():
            o["referrer_tag_days"] = referrer_tag_days
    inventory: dict[str, dict] = {}
    if discover:
        # Enumerate every repository the account has, so a repo created outside the four
        # known callers is previewed too rather than silently missed. describe-repositories
        # failing here is a hard failure — an unreadable account is not an empty one.
        described = _aws("ecr", "describe-repositories")
        for r in (described or {}).get("repositories", []):
            name = r.get("repositoryName")
            if name and name not in repos:
                repos[name] = {}

    previewed: list[dict] = []
    empty: list[str] = []
    failed: dict[str, str] = {}

    # What the ECS estate references is read ONCE. If it cannot be read, nothing can be called safe: every repository is
    # then reported as not verifiable, never as clean.
    in_use: list[dict] | None
    try:
        in_use = collect_in_use()
        print(f"  ECS: {len(in_use)} image reference(s) in use across all clusters")
    except PreviewFailed as exc:
        in_use = None
        for repo in repos:
            failed[repo] = f"in-use check impossible, ECS could not be read: {exc}"
        print(f"  ECS COULD NOT BE READ — {exc}", file=sys.stderr)

    for repo, overrides in repos.items():
        if in_use is None:
            break
        try:
            if not repository_exists(repo):
                # Written-but-not-applied is the norm today; report it, do not fail on it,
                # and do not count it as previewed.
                empty.append(repo)
                print(f"  {repo}: repository does not exist yet — nothing to preview")
                continue
            images = describe_images(repo)
            if not images:
                empty.append(repo)
                print(f"  {repo}: no images")
                continue
            result = preview_repository(repo, overrides)
            children, kinds = manifest_children(repo, images)
            summary = summarise(repo, result, images, children, in_use, kinds, overrides.get("keep_build_count", DEFAULT_KEEP_BUILD_COUNT))
            previewed.append(summary)
            inventory[repo] = {"summary": {k: v for k, v in summary.items() if k != "expiring_sample"}, "images": images, "children": children, "child_kinds": kinds}
            print(
                f"  {repo}: {summary['expiring_image_count']} of {summary['images_total']} expiring "
                f"(sha-: {summary['build_images_now']} -> {summary['build_images_after']}); "
                f"release-tagged {len(summary['expiring_with_release_tag'])}, in use {len(summary['expiring_in_use'])}, "
                f"children of kept lists {len(summary['expiring_children_of_kept_lists'])}"
            )
        except PreviewFailed as exc:
            failed[repo] = str(exc)
            print(f"  {repo}: COULD NOT PREVIEW — {exc}", file=sys.stderr)

    artefact = render_artefact(previewed, empty, failed, len(in_use) if in_use is not None else None)

    if failed:
        # Never write a success artefact on a partial run. Write the incomplete report so the
        # failure is visible, then exit non-zero.
        with open(out_path, "w") as fh:
            fh.write(artefact)
        print(
            f"\nINCOMPLETE: {len(failed)} repository/repositories could not be previewed: "
            f"{', '.join(failed)}. A partial preview is not a clean bill of health. "
            f"Report written to {out_path}; exit 1.",
            file=sys.stderr,
        )
        return 1

    if not previewed and not empty:
        # Read literally nothing. This is the false-green case the script exists to refuse.
        print(
            "\nNOTHING WAS PREVIEWED — no repositories were read at all. This run says nothing "
            "about what the policy would delete.",
            file=sys.stderr,
        )
        return 1

    with open(out_path, "w") as fh:
        fh.write(artefact)
    if inventory_path:
        with open(inventory_path, "w") as fh:
            json.dump(inventory, fh, indent=1, default=str)
        print(f"Inventory (digests, tags, sizes, classes) written to {inventory_path}")
    release = sum(len(p["expiring_with_release_tag"]) for p in previewed)
    used = sum(len(p["expiring_in_use"]) for p in previewed)
    kids = sum(len(p["expiring_children_of_kept_lists"]) for p in previewed)
    print(f"\nPreview complete. Artefact written to {out_path}.")
    if release or used or kids:
        print(
            f"FAIL: would expire {release} release-tagged, {used} in-use and {kids} manifest-list-child image(s). "
            f"Do not apply; raise the retention or fix the reference first.",
            file=sys.stderr,
        )
        return 2
    print("PASS: no release-tagged, in-use or kept-list-child image would expire on any previewed repository.")
    return 0


def self_test_no_creds() -> int:
    """Prove the fail-loud path: force every AWS call to fail and assert the script exits
    non-zero and writes no success artefact. Run in CI (or locally) with no credentials to
    demonstrate the script cannot report a clean preview on data it never read."""
    global _aws
    original = _aws

    def _always_fail(*args: str) -> object:
        raise PreviewFailed("forced failure (self-test): no credentials")

    _aws = _always_fail  # type: ignore[assignment]
    try:
        out = os.path.join(
            os.environ.get("TMPDIR", "/tmp"), "ecr-preview-selftest.md"
        )
        if os.path.exists(out):
            os.remove(out)
        rc = run(discover=False, out_path=out)
        assert rc == 1, f"expected exit 1 on a wholly failed run, got {rc}"
        # An INCOMPLETE artefact is written (so the failure is visible) but it must be marked
        # incomplete, never a clean verdict.
        assert os.path.exists(out), "expected an INCOMPLETE report to be written"
        body = open(out).read()
        assert "INCOMPLETE" in body, "artefact must be marked INCOMPLETE"
        assert "COULD NOT BE PREVIEWED" in body, "artefact must name the failure"
        print("self-test PASSED: no-credentials run exits 1 and refuses a clean verdict.")
        return 0
    finally:
        _aws = original  # type: ignore[assignment]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--discover", action="store_true", help="also preview repos found via describe-repositories")
    default_out = f"ecr-lifecycle-preview-{_dt.date.today().isoformat()}.md"
    ap.add_argument("-o", "--out", default=default_out, help=f"artefact path (default {default_out})")
    ap.add_argument("--self-test-no-creds", action="store_true",
                    help="assert the fail-loud path: exit 1, no clean artefact, on a wholly failed run")
    ap.add_argument("--inventory", metavar="FILE", help="also write every image (digest, tags, size, media type, children) as JSON")
    ap.add_argument("--referrer-tag-days", type=int, metavar="N",
                    help="evaluate a CANDIDATE rule 4 that expires sha256-* tags older than N days (not part of the module today)")
    args = ap.parse_args()

    if args.self_test_no_creds:
        return self_test_no_creds()
    return run(discover=args.discover, out_path=args.out, inventory_path=args.inventory, referrer_tag_days=args.referrer_tag_days)


if __name__ == "__main__":
    sys.exit(main())
