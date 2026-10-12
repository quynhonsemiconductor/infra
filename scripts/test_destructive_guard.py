"""Tests for destructive_guard.py:  python3 scripts/test_destructive_guard.py   (stdlib only)"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "destructive_guard.py")


def rc(address, rtype, actions, mode="managed"):
    return {"address": address, "mode": mode, "type": rtype, "change": {"actions": actions}}


def plan(*changes):
    return {"format_version": "1.2", "terraform_version": "1.9.1", "resource_changes": list(changes)}


def run(doc, *flags, raw=None):
    text = raw if raw is not None else json.dumps(doc)
    with tempfile.NamedTemporaryFile("r", suffix=".md") as summary:
        env = dict(os.environ, GITHUB_STEP_SUMMARY=summary.name)
        r = subprocess.run([sys.executable, GUARD, *flags], input=text, capture_output=True, text=True, env=env)
        return r.returncode, r.stdout + r.stderr, summary.read()


class DestructiveGuard(unittest.TestCase):
    def test_the_2026_10_09_plan_is_refused(self):
        # nine records replaced because zone_id went to null: the exact shape of infra#149's apply
        records = [rc(f'cloudflare_record.landing["h{i}"]', "cloudflare_record", ["delete", "create"]) for i in range(9)]
        code, out, summary = run(plan(*records))
        self.assertEqual(code, 1)
        self.assertIn("REFUSED", out)
        self.assertIn("REPLACE", out)
        self.assertIn('cloudflare_record.landing["h8"]', out)
        self.assertIn("REFUSED", summary)

    def test_a_plain_destroy_is_refused(self):
        code, out, _ = run(plan(rc("cloudflare_record.x", "cloudflare_record", ["delete"])))
        self.assertEqual(code, 1)
        self.assertIn("DESTROY", out)

    def test_create_and_in_place_update_are_fine(self):
        code, out, _ = run(plan(rc("cloudflare_record.a", "cloudflare_record", ["create"]),
                                rc("cloudflare_record.b", "cloudflare_record", ["update"]),
                                rc("cloudflare_record.c", "cloudflare_record", ["no-op"])))
        self.assertEqual(code, 0, out)

    def test_other_destroys_are_not_this_guards_business(self):
        code, _, _ = run(plan(rc("aws_security_group.x", "aws_security_group", ["delete"]),
                              rc("aws_ecs_service.x", "aws_ecs_service", ["delete", "create"])))
        self.assertEqual(code, 0)

    def test_every_protected_family(self):
        # Built from a prefix and a name, not written out in full: a literal list of `cloudflare_...` strings with
        # separators between them is exactly what the secret scanner's cloudflare-api-key rule reads as a key.
        cf = ["dns_record", "pages_domain", "pages_project", "r2_custom_domain", "r2_bucket", "r2_bucket_cors",
              "ruleset", "turnstile_widget", "zone", "zone_dnssec", "worker_script", "tunnel", "custom_hostname",
              "certificate_pack", "origin_ca_certificate", "email_routing_rule", "zero_trust_access_application",
              "access_policy", "zero_trust_tunnel_cloudflared"]
        aws = ["route53_record", "sesv2_email_identity", "sesv2_email_identity_mail_from_attributes", "ses_domain_dkim",
               "acm_certificate", "acm_certificate_validation", "iam_openid_connect_provider", "kms_key", "kms_alias"]
        for rtype in ["cloudflare_" + n for n in cf] + ["aws_" + n for n in aws] + ["cloudflare_record"]:
            with self.subTest(rtype=rtype):
                code, _, _ = run(plan(rc("module.m." + rtype + ".this", rtype, ["delete", "create"])))
                self.assertEqual(code, 1)

    def test_a_type_that_does_not_exist_yet_is_covered_by_prefix(self):
        for rtype in ("cloudflare_r2_bucket_sippy", "aws_sesv2_brand_new_thing", "aws_acm_something_new", "cloudflare_zone_hold"):
            with self.subTest(rtype=rtype):
                code, _, _ = run(plan(rc("x.y", rtype, ["delete"])))
                self.assertEqual(code, 1)

    def test_ci_oidc_roles_are_guarded_by_address_other_iam_is_not(self):
        for address in ("module.iam_oidc.aws_iam_role.infra_apply", "module.iam_oidc.aws_iam_role_policy_attachment.infra_apply_admin",
                        "aws_iam_role.chart_publish", "aws_iam_role_policy.chart_publish", "module.x.aws_iam_role.ecr_push"):
            with self.subTest(address=address):
                rtype = address.split(".")[-2]
                code, _, _ = run(plan(rc(address, rtype, ["delete", "create"])))
                self.assertEqual(code, 1)
        code, _, _ = run(plan(rc("aws_iam_role.task_execution", "aws_iam_role", ["delete", "create"]),
                              rc("module.app.aws_iam_role.chart_publisher_unrelated", "aws_iam_role", ["delete", "create"])))
        self.assertEqual(code, 0)

    def test_module_nested_and_indexed_addresses(self):
        code, out, _ = run(plan(rc("module.edge.cloudflare_ruleset.ratelimit[0]", "cloudflare_ruleset", ["delete", "create"])))
        self.assertEqual(code, 1)
        self.assertIn("module.edge.cloudflare_ruleset.ratelimit[0]", out)

    def test_data_sources_are_ignored(self):
        code, _, _ = run(plan(rc("data.cloudflare_record.x", "cloudflare_record", ["delete"], mode="data")))
        self.assertEqual(code, 0)

    def test_the_label_allows_and_records_the_addresses(self):
        code, out, summary = run(plan(rc("cloudflare_record.x", "cloudflare_record", ["delete", "create"])), "--allow")
        self.assertEqual(code, 0)
        self.assertIn("ALLOWED", out)
        self.assertIn("cloudflare_record.x", summary)          # the record outlives the label

    def test_allow_with_nothing_destructive_is_quiet(self):
        code, out, _ = run(plan(rc("cloudflare_record.x", "cloudflare_record", ["create"])), "--allow")
        self.assertEqual(code, 0)
        self.assertNotIn("ALLOWED", out)

    def test_input_that_is_not_a_plan_fails_closed(self):
        for label, raw in (("empty", ""), ("null", "null"), ("{}", "{}"), ("[]", "[]"), ("not json", "oops"),
                           ("truncated", '{"format_version": "1.2", "resource_ch')):
            with self.subTest(label=label):
                code, out, _ = run(None, raw=raw)
                self.assertNotEqual(code, 0, out)
                code, out, _ = run(None, "--allow", raw=raw)
                self.assertNotEqual(code, 0, "--allow must not turn garbage into a pass: " + out)

    def test_a_plan_with_no_changes_passes(self):
        code, _, _ = run({"format_version": "1.2"})
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
