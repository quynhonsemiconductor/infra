"""Tests for ecr_lifecycle_preview.py: `python3 -m unittest scripts/test_ecr_lifecycle_preview.py`.

The AWS CLI is replaced by a fake `_aws()` that serves a small multi-architecture repository and an ECS estate, so the three
acceptance checks (release-tagged, in use, child of a kept manifest list) are exercised on data with known answers.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ecr_lifecycle_preview as ep  # noqa: E402

ACCOUNT = "111111111111"
REGISTRY = f"{ACCOUNT}.dkr.ecr.ap-southeast-1.amazonaws.com"
INDEX = "application/vnd.oci.image.index.v1+json"
IMAGE = "application/vnd.oci.image.manifest.v1+json"


def d(name: str) -> str:
    """A well-formed digest (64 hex characters) derived from a readable name."""
    return "sha256:" + hashlib.sha256(name.encode()).hexdigest()


ATTESTATIONS: set[str] = set()


def build_repo(n_builds: int = 12, release_on: int = 1):
    """n_builds multi-arch commits oldest first: list sha-i with two per-architecture children and two buildx attestation
    manifests (all untagged); the oldest `release_on` build also carries v1.0.0. Returns (describe-images details, children)."""
    details, children = [], {}
    ATTESTATIONS.clear()
    for i in range(1, n_builds + 1):
        tags = [f"sha-{i}"] + (["v1.0.0"] if i == release_on else [])
        pushed = f"2026-10-{i:02d}T00:00:00"
        details.append({"imageDigest": d(f"list{i}"), "imageTags": tags, "imageManifestMediaType": INDEX, "imagePushedAt": pushed, "imageSizeInBytes": 856})
        kids = []
        for arch in ("amd", "arm"):
            details.append({"imageDigest": d(f"c{i}{arch}"), "imageManifestMediaType": IMAGE, "imagePushedAt": pushed, "imageSizeInBytes": 100_000_000})
            details.append({"imageDigest": d(f"a{i}{arch}"), "imageManifestMediaType": IMAGE, "imagePushedAt": pushed, "imageSizeInBytes": 40_000})
            ATTESTATIONS.add(d(f"a{i}{arch}"))
            kids += [d(f"c{i}{arch}"), d(f"a{i}{arch}")]
        children[d(f"list{i}")] = kids
    return details, children


class FakeAws:
    def __init__(self, details, children, expiring, tasks=None, services=None, families=None, fail=None, missing_manifest=False, reported_count=None):
        self.reported_count = reported_count
        self.details, self.children, self.expiring = details, children, expiring
        self.tasks, self.services, self.families = tasks or [], services or [], families or {}
        self.fail, self.missing_manifest = fail or set(), missing_manifest
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        key = " ".join(args[:2])
        if key in self.fail:
            raise ep.PreviewFailed(f"forced failure of {key}")
        if key == "ecr describe-repositories":
            return {"repositories": [{"repositoryName": "rova-api"}]}
        if key == "ecr describe-images":
            return {"imageDetails": self.details if args[args.index("--repository-name") + 1] == "rova-api" else []}
        if key == "ecr start-lifecycle-policy-preview":
            return {}
        if key == "ecr get-lifecycle-policy-preview":
            if args[args.index("--repository-name") + 1] != "rova-api":
                return {"status": "COMPLETE", "previewResults": [], "summary": {"expiringImageTotalCount": 0}}
            # The real API spells the action in CAPITALS and says which rule hit each image.
            results = [{"imageDigest": x, "imageTags": tags, "action": {"type": "EXPIRE"}, "appliedRulePriority": 3 if tags else 1} for x, tags in self.expiring]
            count = len(results) if self.reported_count is None else self.reported_count
            return {"status": "COMPLETE", "previewResults": results, "summary": {"expiringImageTotalCount": count}}
        if key == "ecr batch-get-image":
            ids = [a.split("=", 1)[1] for a in args if a.startswith("imageDigest=")]
            images = [] if self.missing_manifest else [
                {"imageId": {"imageDigest": x}, "imageManifest": json.dumps({"manifests": [
                    ({"digest": c, "platform": {"architecture": "unknown", "os": "unknown"}, "annotations": {"vnd.docker.reference.type": "attestation-manifest"}}
                     if c in ATTESTATIONS else {"digest": c, "platform": {"architecture": "arm64", "os": "linux"}}) for c in self.children[x]]})} for x in ids]
            return {"images": images, "failures": []}
        if key == "ecs list-clusters":
            return {"clusterArns": [f"arn:aws:ecs:ap-southeast-1:{ACCOUNT}:cluster/rova-develop", f"arn:aws:ecs:ap-southeast-1:{ACCOUNT}:cluster/rova-prod"]}
        if key == "ecs list-services":
            cluster = args[args.index("--cluster") + 1]
            return {"serviceArns": [s["arn"] for s in self.services if s["cluster"] in cluster]}
        if key == "ecs describe-services":
            cluster = args[args.index("--cluster") + 1]
            return {"services": [{"serviceName": s["name"], "deployments": [{"status": "PRIMARY", "taskDefinition": s["taskdef"]}]}
                                 for s in self.services if s["cluster"] in cluster], "failures": []}
        if key == "ecs list-tasks":
            cluster = args[args.index("--cluster") + 1]
            return {"taskArns": [f"t-{i}" for i, t in enumerate(self.tasks) if t["cluster"] in cluster]}
        if key == "ecs describe-tasks":
            cluster = args[args.index("--cluster") + 1]
            return {"tasks": [{"taskDefinitionArn": t["taskdef"], "containers": [{"name": "app", "image": t["image"], "imageDigest": t.get("digest")}]}
                              for t in self.tasks if t["cluster"] in cluster], "failures": []}
        if key == "ecs list-task-definition-families":
            return {"families": list(self.families)}
        if key == "ecs describe-task-definition":
            ref = args[args.index("--task-definition") + 1]
            family = ref.split("/")[-1].split(":")[0]
            image = self.families.get(family) or next((s["image"] for s in self.services if s["taskdef"] == ref), None) or \
                next((t["image"] for t in self.tasks if t["taskdef"] == ref), None)
            arn = ref if ref.startswith("arn:") else f"arn:aws:ecs:ap-southeast-1:{ACCOUNT}:task-definition/{ref}:1"
            return {"taskDefinition": {"taskDefinitionArn": arn, "containerDefinitions": [{"name": "app", "image": image}] if image else []}}
        raise AssertionError(f"unexpected call {args}")


def tdarn(name):
    return f"arn:aws:ecs:ap-southeast-1:{ACCOUNT}:task-definition/{name}:7"


class Harness(unittest.TestCase):
    def run_script(self, fake):
        original = ep._aws
        ep._aws = fake
        ep.REPOSITORIES = {"rova-api": {}}
        ep.PREVIEW_POLL_SECONDS = 0
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = os.path.join(tmp, "preview.md")
                rc = ep.run(discover=False, out_path=out)
                return rc, pathlib.Path(out).read_text()
        finally:
            ep._aws = original


class Parsing(unittest.TestCase):
    def test_ecr_references(self):
        self.assertEqual(ep.parse_image_ref(f"{REGISTRY}/rova-api:sha-2"), {"repo": "rova-api", "tag": "sha-2", "digest": None})
        self.assertEqual(ep.parse_image_ref(f"{REGISTRY}/rova-api@{d('abc')}")["digest"], d("abc"))
        self.assertEqual(ep.parse_image_ref(f"{REGISTRY}/rova-api:v1.0.0@{d('abc')}"), {"repo": "rova-api", "tag": "v1.0.0", "digest": d("abc")})
        self.assertIsNone(ep.parse_image_ref("public.ecr.aws/x/y:1"))
        self.assertIsNone(ep.parse_image_ref("clamav/clamav:1.4"))

    def test_the_default_is_ten_and_the_policy_says_so(self):
        self.assertEqual(ep.DEFAULT_KEEP_BUILD_COUNT, 10)
        rules = ep.build_policy({})["rules"]
        self.assertEqual(rules[2]["selection"]["countNumber"], 10)
        self.assertEqual(rules[1]["selection"]["countNumber"], 180)  # release rule unchanged
        self.assertEqual(ep.build_policy({"keep_build_count": 5})["rules"][2]["selection"]["countNumber"], 5)  # kb's own value


class Scenarios(Harness):
    def setUp(self):
        self.details, self.children = build_repo()
        # builds 2 and 3 (oldest without a release tag) expire; build 1 carries v1.0.0 and is held by the release rule
        self.clean = [(d("list2"), ["sha-2"]), (d("list3"), ["sha-3"])]

    def test_clean_preview_passes(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean))
        self.assertEqual(rc, 0, md)
        self.assertIn("**PASS", md)
        self.assertIn("| rova-api | 60 | 12 → 10 | 2 | 0 | 0 | 0 |", md)  # 36 images (12 lists + 24 children); sha- 12 -> 10

    def test_nothing_expiring_is_a_preview_not_an_empty_repository(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, []))
        self.assertEqual(rc, 0)
        self.assertIn("| rova-api | 60 | 12 → 12 | 0 | 0 | 0 | 0 |", md)

    def test_a_release_tagged_image_that_would_expire_fails(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean + [(d("list1"), ["sha-1", "v1.0.0"])]))
        self.assertEqual(rc, 2)
        self.assertIn("release images that would expire", md)
        self.assertIn("**FAIL", md)

    def test_an_image_a_running_task_uses_by_tag_fails(self):
        task = {"cluster": "rova-develop", "taskdef": tdarn("rova-develop-api"), "image": f"{REGISTRY}/rova-api:sha-2", "digest": d("c2arm")}
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, tasks=[task]))
        self.assertEqual(rc, 2, md)
        self.assertIn("images in use that would expire", md)
        self.assertIn("rova-develop running task", md)

    def test_an_image_a_service_deployment_pins_by_digest_fails_even_in_prod(self):
        service = {"cluster": "rova-prod", "name": "rova-prod-api", "arn": "svc1", "taskdef": tdarn("rova-prod-api"), "image": f"{REGISTRY}/rova-api@{d('list3')}"}
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, services=[service]))
        self.assertEqual(rc, 2, md)
        self.assertIn("rova-prod/rova-prod-api PRIMARY deployment", md)

    def test_the_newest_active_revision_of_a_family_counts(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, families={"rova-develop-migrator": f"{REGISTRY}/rova-api:sha-3"}))
        self.assertEqual(rc, 2, md)
        self.assertIn("newest ACTIVE revision of rova-develop-migrator", md)

    def test_a_running_child_digest_protects_its_manifest_list(self):
        # the task's task definition names another image; it merely REPORTS the per-architecture digest it pulled for sha-3
        task = {"cluster": "rova-develop", "taskdef": tdarn("other"), "image": f"{REGISTRY}/rova-worker:sha-9", "digest": d("c3arm")}
        fake = FakeAws(self.details, self.children, self.clean, tasks=[{**task, "image": f"{REGISTRY}/rova-api@{d('c3arm')}"}])
        rc, md = self.run_script(fake)
        self.assertEqual(rc, 2, md)
        self.assertIn("manifest list of", md)

    def test_an_image_used_in_another_repository_is_not_blamed(self):
        task = {"cluster": "rova-develop", "taskdef": tdarn("w"), "image": f"{REGISTRY}/rova-worker:sha-2", "digest": d("c2arm")}
        rc, _ = self.run_script(FakeAws(self.details, self.children, self.clean, tasks=[task]))
        self.assertEqual(rc, 0)

    def test_a_child_of_a_kept_manifest_list_that_would_expire_fails(self):
        """What the AWS documentation says cannot happen; if the preview ever lists it, this check must catch it."""
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean + [(d("c5amd"), [])]))
        self.assertEqual(rc, 2, md)
        self.assertIn("children of kept manifest lists that would expire", md)
        self.assertIn("sha-5", md)  # names the kept list

    def test_children_of_an_expiring_list_are_not_flagged_as_orphaned_by_a_kept_one(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean + [(d("c2amd"), []), (d("c2arm"), [])]))
        self.assertEqual(rc, 0, md)  # their own list (sha-2) expires too: the children go with it

    def test_an_unreadable_ecs_estate_is_incomplete_not_clean(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, fail={"ecs list-clusters"}))
        self.assertEqual(rc, 1)
        self.assertIn("INCOMPLETE", md)
        self.assertNotIn("**PASS", md)

    def test_an_ecs_failure_in_one_call_aborts_the_whole_in_use_check(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, fail={"ecs describe-task-definition"}, families={"f": "x"}))
        self.assertEqual(rc, 1)
        self.assertNotIn("**PASS", md)

    def test_an_unreadable_manifest_fails_the_repository(self):
        rc, md = self.run_script(FakeAws(self.details, self.children, self.clean, missing_manifest=True))
        self.assertEqual(rc, 1)
        self.assertIn("COULD NOT PREVIEW", md)

    def test_a_repository_without_images_is_reported_not_failed(self):
        rc, md = self.run_script(FakeAws([], {}, []))
        self.assertEqual(rc, 0)
        self.assertIn("| rova-api | 0 |", md)

    def test_the_artefact_contains_no_account_id(self):
        task = {"cluster": "rova-develop", "taskdef": tdarn("rova-develop-api"), "image": f"{REGISTRY}/rova-api:sha-2", "digest": d("c2arm")}
        _, md = self.run_script(FakeAws(self.details, self.children, self.clean, tasks=[task]))
        self.assertNotIn(ACCOUNT, md)

    def test_nothing_is_ever_written_to_aws(self):
        fake = FakeAws(self.details, self.children, self.clean)
        self.run_script(fake)
        verbs = {c[1] for c in fake.calls}
        self.assertTrue(all(v.startswith(("describe-", "list-", "get-", "batch-get-")) or v == "start-lifecycle-policy-preview" for v in verbs), verbs)


class Breakdown(Harness):
    def extra_images(self):
        sig = "sha256-" + "ab" * 32 + ".sig"
        return [
            {"imageDigest": d("sig1"), "imageTags": [sig], "imageManifestMediaType": IMAGE, "imagePushedAt": "2026-10-05T00:00:00", "imageSizeInBytes": 2000},
            {"imageDigest": d("cache"), "imageTags": ["buildcache"], "imageManifestMediaType": INDEX, "imagePushedAt": "2026-10-12T00:00:00", "imageSizeInBytes": 900},
            {"imageDigest": d("pr"), "imageTags": ["pr-123"], "imageManifestMediaType": IMAGE, "imagePushedAt": "2026-10-12T00:00:00", "imageSizeInBytes": 5000},
            {"imageDigest": d("att"), "imageManifestMediaType": IMAGE, "imagePushedAt": "2026-10-06T00:00:00", "imageSizeInBytes": 3000,
             "artifactMediaType": "application/vnd.dev.sigstore.bundle.v0.3+json", "subjectManifestDigest": d("list2")},
            {"imageDigest": d("orphan"), "imageManifestMediaType": IMAGE, "imagePushedAt": "2026-09-01T00:00:00", "imageSizeInBytes": 77},
        ]

    def summary_of(self, fake):
        original = ep._aws
        ep._aws = fake
        ep.PREVIEW_POLL_SECONDS = 0
        try:
            images = ep.describe_images("rova-api")
            children, kinds = ep.manifest_children("rova-api", images)
            result = ep._aws("ecr", "get-lifecycle-policy-preview", "--repository-name", "rova-api")
            return ep.summarise("rova-api", result, images, children, [], kinds, 10)
        finally:
            ep._aws = original

    def test_every_image_lands_in_a_class_with_counts_and_sizes(self):
        details, children = build_repo()
        children[d("cache")] = []
        fake = FakeAws(details + self.extra_images(), children, [(d("list2"), ["sha-2"]), (d("orphan"), [])])
        b = self.summary_of(fake)["breakdown"]
        c = b["classes"]
        self.assertEqual(c["build sha-* (index)"]["images"], 11)  # 12 builds, one of which also carries v1.0.0
        self.assertEqual(c["release v* (index)"]["images"], 1)
        self.assertEqual(c["untagged child of a kept list"]["images"], 44)  # 11 kept lists x 4 children
        self.assertEqual(c["untagged child of a EXPIRING list"]["images"], 4)  # only list2 expires; list1 is kept by its v tag
        self.assertEqual(c["referrer-by-tag sha256-<digest>[.sig/.att/.sbom]"]["images"], 1)
        self.assertEqual(c["referrer artifact (OCI subject)"]["images"], 1)
        self.assertEqual(c["other tagged"]["images"], 2)
        self.assertEqual(c["untagged orphan (no list references it)"]["images"], 1)
        self.assertEqual(c["untagged orphan (no list references it)"]["expire_by_rule"], {"1": 1})
        self.assertEqual(b["other_tag_patterns"], {"buildcache": 1, "pr-N": 1})
        self.assertEqual(b["child_kinds"]["attestation"], 24)
        self.assertEqual(b["child_kinds"]["linux/arm64"], 24)
        self.assertEqual(c["untagged orphan (no list references it)"]["bytes"], 77)
        self.assertEqual(b["artifact_media_types"], {"application/vnd.dev.sigstore.bundle.v0.3+json": 1})

    def test_rule_3_diagnosis_accounts_for_every_build_beyond_the_newest_n(self):
        details, children = build_repo()
        b = self.summary_of(FakeAws(details, children, [(d("list2"), ["sha-2"])]))["breakdown"]
        self.assertEqual(b["builds_beyond_keep"], 2)
        results = {x["tags"]: x["result"] for x in b["builds_beyond_keep_diagnosis"]}
        self.assertEqual(results["sha-2"], "expires by rule 3")
        self.assertIn("also tagged v*", results["sha-1,v1.0.0"])
        self.assertEqual(b["expiring_by_rule"], {"3": 1})

    def test_a_rule_3_that_selects_nothing_is_reported_as_unexplained(self):
        details, children = build_repo(release_on=0)  # no build carries a release tag
        b = self.summary_of(FakeAws(details, children, []))["breakdown"]
        self.assertEqual([x["result"].split(":")[0] for x in b["builds_beyond_keep_diagnosis"]], ["NOT SELECTED and unexplained"] * 2)
        details, children = build_repo(release_on=0)
        rc, md = self.run_script(FakeAws(details, children, []))
        self.assertIn("are NOT expiring for no reason this script can find", md)
        self.assertIn("## Breakdown: rova-api", md)

    def test_the_markdown_table_has_sizes_and_rule_columns(self):
        details, children = build_repo()
        children[d("cache")] = []
        rc, md = self.run_script(FakeAws(details + self.extra_images(), children, [(d("list2"), ["sha-2"])]))
        self.assertIn("| class | images | size | kept | expire by rule 1 | rule 2 | rule 3 | rule 4 |", md)
        self.assertIn("| build sha-* (index) | 11 |", md)
        self.assertIn("Other tagged: distinct tag shapes: `buildcache` x1, `pr-N` x1", md)
        self.assertIn("Untagged children by kind", md)

    def test_tag_shapes(self):
        self.assertEqual(ep.tag_pattern("sha-3f9a2c1"), "sha-<hex>")
        self.assertEqual(ep.tag_pattern("v1.2.3"), "vN.N.N")
        self.assertEqual(ep.tag_pattern("pr-123"), "pr-N")
        self.assertEqual(ep.tag_pattern("buildcache"), "buildcache")
        self.assertEqual(ep.tag_pattern("sha256-" + "ab" * 32 + ".sig"), "sha256-<sha>.sig".replace("sha256", "shaN"))

    def test_the_candidate_referrer_rule_is_only_added_when_asked(self):
        self.assertEqual([r["rulePriority"] for r in ep.build_policy({})["rules"]], [1, 2, 3])
        rules = ep.build_policy({"referrer_tag_days": 210})["rules"]
        self.assertEqual(rules[3]["selection"]["tagPatternList"], ["sha256-*"])
        self.assertEqual(rules[3]["selection"]["countNumber"], 210)

    def test_the_inventory_json_is_written_on_request(self):
        details, children = build_repo()
        original = ep._aws
        ep._aws = FakeAws(details, children, [(d("list2"), ["sha-2"])])
        ep.REPOSITORIES = {"rova-api": {}}
        ep.PREVIEW_POLL_SECONDS = 0
        try:
            with tempfile.TemporaryDirectory() as tmp:
                rc = ep.run(False, os.path.join(tmp, "p.md"), inventory_path=os.path.join(tmp, "inv.json"))
                inv = json.loads(pathlib.Path(tmp, "inv.json").read_text())
                self.assertEqual(rc, 0)
                self.assertEqual(len(inv["rova-api"]["images"]), 60)
                self.assertIn("breakdown", inv["rova-api"]["summary"])
        finally:
            ep._aws = original


class ActionSpelling(Harness):
    """The bug that made the first real run a false PASS: the API says EXPIRE, the script looked for expire."""

    def test_capitalised_expire_is_read_and_the_checks_run_on_it(self):
        details, children = build_repo()
        rc, md = self.run_script(FakeAws(details, children, [(d("list1"), ["sha-1", "v1.0.0"])]))
        self.assertEqual(rc, 2)  # the release-tagged image IS seen
        self.assertIn("| rova-api | 60 | 12 → 11 | 1 | 1 |", md)

    def test_a_summary_that_disagrees_with_the_parsed_list_is_an_error_not_a_pass(self):
        details, children = build_repo()
        rc, md = self.run_script(FakeAws(details, children, [(d("list2"), ["sha-2"])], reported_count=26))
        self.assertEqual(rc, 1)
        self.assertIn("AWS says 26 image(s) would expire but 1 were read", md)
        self.assertNotIn("**PASS", md)

    def test_lower_case_is_still_accepted(self):
        result = {"status": "COMPLETE", "previewResults": [{"imageDigest": d("list2"), "imageTags": ["sha-2"], "action": {"type": "expire"}, "appliedRulePriority": 3}],
                  "summary": {"expiringImageTotalCount": 1}}
        details, children = build_repo()
        images = [{"digest": x["imageDigest"], "tags": x.get("imageTags") or [], "media_type": x["imageManifestMediaType"], "pushed_at": x["imagePushedAt"],
                   "size": x["imageSizeInBytes"], "artifact_media_type": "", "subject": ""} for x in details]
        self.assertEqual(ep.summarise("rova-api", result, images, children, [])["expiring_image_count"], 1)


class NoCredentials(unittest.TestCase):
    def test_the_fail_loud_self_test_still_passes(self):
        self.assertEqual(ep.self_test_no_creds(), 0)


if __name__ == "__main__":
    unittest.main()
