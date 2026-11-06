"""Guard: every identity-kit step in drift-detection.yml gets every IDENTITY_* input.

The kit builds TF_VAR_* from read-only lookups plus six IDENTITY_* inputs. A step
that forgets one still runs: the kit silently drops that input (the plan then
proposes removing the live DEV owners / OpsHub Dev admins) or stops with a
one-line message. Both shapes were observed on 2026-11-06 (#440 review).

Standard library only: `python3 -m unittest scripts/test_drift_identity_inputs.py`.
Text parsing on purpose: no PyYAML dependency in the guard that guards the guard.
"""

from __future__ import annotations

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows" / "drift-detection.yml"

REQUIRED = (
    "IDENTITY_OWNER_OPERATOR_UPN",
    "IDENTITY_SECOND_OWNER_UPN",
    "IDENTITY_PROXMOX_HOST",
    "IDENTITY_PBS_HOST",
    "IDENTITY_DEV_APP_EXTRA_OWNERS",
    "IDENTITY_DEV_APP_EXTRA_ADMINS",
)

STEP = re.compile(r"^      - name: (?P<name>.*)$")
JOB = re.compile(r"^  [A-Za-z0-9_-]+:$")
ENV = re.compile(r"^\s{10}(?P<key>[A-Z][A-Z0-9_]*):\s*(?P<value>.*)$")


def steps(text: str) -> list[tuple[str, str]]:
    """(name, block) for every step of every job, by indentation."""
    lines = text.splitlines()
    out: list[tuple[str, str]] = []
    index = 0
    while index < len(lines):
        match = STEP.match(lines[index])
        if not match:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and not STEP.match(lines[end]) and not JOB.match(lines[end]):
            end += 1
        out.append((match.group("name").strip(), "\n".join(lines[index:end])))
        index = end
    return out


def env_map(block: str) -> dict[str, str]:
    return {m.group("key"): m.group("value").strip() for m in map(ENV.match, block.splitlines()) if m}


class IdentityKitSteps(unittest.TestCase):
    def setUp(self):
        self.steps = steps(WORKFLOW.read_text(encoding="utf-8"))

    def kit_steps(self):
        # A real invocation is a command line, not the mention in the Report
        # step's comment (`# run scripts/owner/identity-env/identity-env.sh ...`).
        invocation = re.compile(r"^\s+scripts/owner/identity-env/identity-env\.sh --", re.MULTILINE)
        return [(name, block) for name, block in self.steps if invocation.search(block)]

    def test_there_are_kit_steps(self):
        # Two passes (refresh-only and plan). A parser drift that finds none must
        # fail here instead of passing every later assertion vacuously.
        self.assertGreaterEqual(len(self.kit_steps()), 2, [name for name, _ in self.steps])

    def test_every_kit_step_passes_every_input(self):
        for name, block in self.kit_steps():
            values = env_map(block)
            for key in REQUIRED:
                with self.subTest(step=name, key=key):
                    self.assertIn(key, values, f"{name}: missing env {key}")
                    self.assertEqual(
                        values[key], f"${{{{ secrets.{key} }}}}",
                        f"{name}: {key} must come from the same-named repository secret",
                    )

    def test_preflight_names_every_input(self):
        preflight = [block for name, block in self.steps if name == "Identity drift inputs present"]
        self.assertEqual(len(preflight), 1, "the preflight step is missing")
        values = env_map(preflight[0])
        self.assertEqual(set(values), {f"IN_{key}" for key in
                                       ("OWNER_UPN", "SECOND_UPN", "PVE_HOST", "PBS_HOST",
                                        "EXTRA_OWNERS", "EXTRA_ADMINS")})
        for key in REQUIRED:
            self.assertIn(key, preflight[0], f"preflight does not name {key}")


if __name__ == "__main__":
    unittest.main()
