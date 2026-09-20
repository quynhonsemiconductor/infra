#!/usr/bin/env python3
"""Preview the ECR lifecycle policy on EVERY repository in the estate, as a DRY RUN, and
write an artefact a human attaches to the task 0.7 PR before the policy is applied.

WHY THIS EXISTS (§13, implementation-plan.md task 0.7). `tf-modules/modules/ecr` moved the
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
(ecr-v2.1.0), with the per-caller overrides the live callers pass (see REPOSITORIES). If the
module's rules change, change them here too, or the preview lies.

USAGE
  # Requires AWS credentials with ecr:StartLifecyclePolicyPreview,
  # ecr:GetLifecyclePolicyPreview, ecr:DescribeRepositories, ecr:DescribeImages.
  python3 scripts/ecr_lifecycle_preview.py                 # preview known estate repos
  python3 scripts/ecr_lifecycle_preview.py --discover      # ALSO preview any repo the
                                                           # account has that we don't know
  python3 scripts/ecr_lifecycle_preview.py -o preview.md   # write artefact to preview.md

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
import subprocess
import sys
import time

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

# ── Policy parameters, mirrored from tf-modules/modules/ecr (ecr-v2.1.0) ─────────────────
# Keep these in lockstep with modules/ecr/main.tf and variables.tf. The preview is only
# meaningful if the text below is the text OpenTofu will apply.
DEFAULT_RELEASE_TAG_PREFIX = "v"
DEFAULT_BUILD_TAG_PREFIX = "sha-"
DEFAULT_RELEASE_RETENTION_DAYS = 180
DEFAULT_KEEP_BUILD_COUNT = 20
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
    return {
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


def repository_exists(repo: str) -> bool:
    """True if the repository exists. A repository that does not exist yet (the products are
    written but not applied — implementation-plan.md: NOTHING HAS BEEN APPLIED) cannot be
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


def summarise(repo: str, result: dict) -> dict:
    """Reduce a COMPLETE preview to the facts the reviewer needs: how many images the policy
    would expire, and — the actual acceptance test — whether ANY of them carry a release tag
    (a `v*` tag), which is the thing 0.7 forbids expiring."""
    preview_results = result.get("previewResults") or []
    expiring = []
    release_expiring = []
    for pr in preview_results:
        tags = pr.get("imageTags") or []
        applied = (pr.get("action") or {}).get("type")
        if applied == "expire":
            expiring.append({"digest": pr.get("imageDigest"), "tags": tags})
            if any(t.startswith(DEFAULT_RELEASE_TAG_PREFIX) and t != "latest" for t in tags):
                release_expiring.append({"digest": pr.get("imageDigest"), "tags": tags})
    summary = result.get("summary") or {}
    return {
        "repository": repo,
        "status": result.get("status"),
        "expiring_image_count": summary.get("expiringImageTotalCount", len(expiring)),
        "expiring_with_release_tag": release_expiring,
        "expiring_sample": expiring[:25],
    }


def render_artefact(previewed: list[dict], empty: list[str], failed: dict[str, str]) -> str:
    now = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")
    lines = [
        "# ECR lifecycle-policy preview (task 0.7, §13)",
        "",
        f"Generated: {now}  ·  region: {REGION}",
        "",
        "Dry run of `aws ecr start-lifecycle-policy-preview` with the ecr-v2.1.0 policy "
        "(time-based release retention). Nothing was deleted. Attach this to the retention PR.",
        "",
    ]
    total_release = sum(len(p["expiring_with_release_tag"]) for p in previewed)
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
        # Nothing reached COMPLETE. Say nothing reassuring — there is no verdict to give.
        lines += [
            "**No repository was successfully previewed, so there is NO verdict.** This run "
            "says nothing about what the policy would delete. Resolve the failures above and "
            "re-run before applying.",
            "",
        ]
    else:
        lines += [
            (
                f"**{total_release} image(s) carrying a release (`v*`) tag would expire "
                f"across the {len(previewed)} repository/repositories that previewed.** "
                + (
                    "This FAILS the 0.7 acceptance test — raise `release_retention_days` until "
                    "it reaches zero. Do NOT lower it to match a count rule."
                    if total_release > 0
                    else "No release image is expired on any previewed repository."
                )
            ),
            "",
        ]
        if failed:
            lines += [
                "Note the verdict covers only the repositories that previewed; the "
                f"{len(failed)} above were not read and are not included.",
                "",
            ]
    lines += [
        "## Per repository",
        "",
        "| repository | status | images expiring | of which release-tagged |",
        "| :--------- | :----- | --------------: | ----------------------: |",
    ]
    for p in previewed:
        lines.append(
            f"| {p['repository']} | {p['status']} | {p['expiring_image_count']} "
            f"| {len(p['expiring_with_release_tag'])} |"
        )
    for repo in empty:
        lines.append(f"| {repo} | NO IMAGES | 0 | 0 |")
    for repo in failed:
        lines.append(f"| {repo} | **COULD NOT PREVIEW** | ? | ? |")
    lines.append("")
    for p in previewed:
        if p["expiring_with_release_tag"]:
            lines += [f"### {p['repository']}: release images that would expire", ""]
            for img in p["expiring_with_release_tag"]:
                lines.append(f"- `{', '.join(img['tags'])}` ({img['digest']})")
            lines.append("")
    return "\n".join(lines)


def run(discover: bool, out_path: str) -> int:
    repos = dict(REPOSITORIES)
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

    for repo, overrides in repos.items():
        try:
            if not repository_exists(repo):
                # Written-but-not-applied is the norm today; report it, do not fail on it,
                # and do not count it as previewed.
                empty.append(repo)
                print(f"  {repo}: repository does not exist yet — nothing to preview")
                continue
            result = preview_repository(repo, overrides)
            summary = summarise(repo, result)
            if summary["expiring_image_count"] == 0 and not (result.get("previewResults")):
                empty.append(repo)
                print(f"  {repo}: no images / nothing expires")
            else:
                previewed.append(summary)
                print(
                    f"  {repo}: {summary['expiring_image_count']} expiring, "
                    f"{len(summary['expiring_with_release_tag'])} release-tagged"
                )
        except PreviewFailed as exc:
            failed[repo] = str(exc)
            print(f"  {repo}: COULD NOT PREVIEW — {exc}", file=sys.stderr)

    artefact = render_artefact(previewed, empty, failed)

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
    total_release = sum(len(p["expiring_with_release_tag"]) for p in previewed)
    print(f"\nPreview complete. Artefact written to {out_path}.")
    if total_release:
        print(
            f"FAIL: {total_release} release-tagged image(s) would expire. Raise "
            f"release_retention_days before applying (0.7).",
            file=sys.stderr,
        )
        return 2
    print("PASS: no release-tagged image would expire on any previewed repository (0.7).")
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
    args = ap.parse_args()

    if args.self_test_no_creds:
        return self_test_no_creds()
    return run(discover=args.discover, out_path=args.out)


if __name__ == "__main__":
    sys.exit(main())
