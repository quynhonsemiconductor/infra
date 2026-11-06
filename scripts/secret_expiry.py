#!/usr/bin/env python3
"""Watch Key Vault secret and Entra app credential expiry.

The estate used to cite a weekly expiry check in three places and have none. This is the check:
one read-only pass over the four Key Vaults (metadata only, never a value) and over every Entra
app registration's credentials, then a report that fails when a prod/platform secret has no expiry,
when any credential has expired, or when any credential expires within 7 days, and warns when one
expires within 30 days.

WHY KEY VAULT READER IS ENOUGH. The CI read identity has Key Vault Reader, which can read secret
metadata (name, attributes.exp) but not a value. Entra app credentials are metadata too: keyId,
display name and dates, never the secret value.

EXIT CODE. 0 = no FAIL (WARN is allowed, the workflow still posts it), 1 = at least one FAIL,
2 = a collection error (a vault or Graph could not be read). A check that could not run never
reads as a check that passed.

    python3 scripts/secret_expiry.py --markdown expiry.md --json expiry.json
    python3 scripts/secret_expiry.py --now 2026-11-04T00:00:00Z   # deterministic tests
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import math
import re
import subprocess
import sys
from typing import Any, Optional

DEFAULT_VAULTS = ("kv-qnsc-prod", "kv-qnsc-platform", "kv-qnsc-dev")
# The two vaults whose secrets must carry an expiry. Dev's missing expiries are a WARN: dev values
# are re-issuable, and the backlog is being backfilled.
STRICT_VAULTS = {"kv-qnsc-prod", "kv-qnsc-platform"}
# Two thresholds, two alerts. Within 30 days is a WARN (green run, Teams card); within 7 days is a
# FAIL (red run, Teams card) because a weekly cadence leaves one run before it expires — the
# rotation needs to happen now, not "soon".
WARN_DAYS = 30
URGENT_DAYS = 7

# Identifiers that rotate never, so an expiry would only create noise. A credential is not on this
# list: graph-cert follows the certificate, R2 key ids follow their token.
NO_EXPIRY_OK = (
    (re.compile(r"-mcp-access-aud$"), "Cloudflare Access AUD tag: an identifier, not a credential"),
    (re.compile(r"-client-id$"), "Entra client id: an identifier, not a credential"),
    (re.compile(r"-platform-admin-emails$"), "staff email roster: not a credential"),
)

FAIL, WARN, OK = "FAIL", "WARN", "OK"
STATUS_ORDER = {FAIL: 0, WARN: 1, OK: 2}


class CollectionError(RuntimeError):
    """A check could not run: a vault or Graph was not readable."""


@dataclasses.dataclass
class Finding:
    source: str
    name: str
    kind: str
    expires: Optional[dt.datetime]
    status: str
    detail: str
    days: Optional[int] = None
    fix: str = ""


def parse_timestamp(value: Any) -> Optional[dt.datetime]:
    """Parse an ISO-8601 date/time, an epoch number, or a digit string. None when absent/invalid."""
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if value <= 0:
            return None
        return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
    text = str(value).strip()
    if text.isdigit():
        number = int(text)
        # Key Vault uses epoch seconds; a year string is not a timestamp.
        if number < 10**9:
            return None
        return dt.datetime.fromtimestamp(number, tz=dt.timezone.utc)
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    parsed = parsed.astimezone(dt.timezone.utc)
    # Graph writes 0001-01-01 for "no expiry"; that is missing, not 2000 years expired.
    return None if parsed.year < 1970 else parsed


def no_expiry_reason(name: str) -> Optional[str]:
    for pattern, reason in NO_EXPIRY_OK:
        if pattern.search(name):
            return reason
    return None


def classify(
    *,
    source: str,
    name: str,
    kind: str,
    expires: Optional[dt.datetime],
    now: dt.datetime,
    required: bool,
) -> Finding:
    """Turn an expiry date into OK/WARN/FAIL. `required` means a missing expiry is a FAIL."""
    reason = no_expiry_reason(name)
    if expires is None:
        if reason:
            return Finding(source, name, kind, None, OK, f"no expiry by design ({reason})")
        if required:
            return Finding(
                source,
                name,
                kind,
                None,
                FAIL,
                "no expiry set",
                fix="set an expiry (scripts/owner/backfill-kv-expiry.sh --apply) and rotate on schedule",
            )
        return Finding(
            source,
            name,
            kind,
            None,
            WARN,
            "no expiry set (dev vault: backfill in progress)",
            fix="set an expiry (scripts/owner/backfill-kv-expiry.sh --apply) and rotate on schedule",
        )

    days = math.floor((expires - now).total_seconds() / 86400)
    if days < 0:
        return Finding(
            source,
            name,
            kind,
            expires,
            FAIL,
            f"expired {abs(days)} days ago",
            days=days,
            fix="replace the credential now; ESO/apps fail when it is gone",
        )
    if days <= URGENT_DAYS:
        return Finding(
            source,
            name,
            kind,
            expires,
            FAIL,
            f"expires in {days} days (7-day threshold)",
            days=days,
            fix="rotate now: the next weekly run is after this expires",
        )
    if days <= WARN_DAYS:
        return Finding(
            source,
            name,
            kind,
            expires,
            WARN,
            f"expires in {days} days",
            days=days,
            fix="rotate and update the vault before the expiry date",
        )
    return Finding(source, name, kind, expires, OK, "ok", days=days)


def evaluate_key_vault(secrets: list[dict[str, Any]], vault: str, now: dt.datetime) -> list[Finding]:
    findings = []
    for secret in secrets:
        attributes = secret.get("attributes") or {}
        expires = parse_timestamp(attributes.get("exp", attributes.get("expires")))
        findings.append(
            classify(
                source=vault,
                name=secret.get("name", "<unnamed>"),
                kind="Key Vault secret",
                expires=expires,
                now=now,
                required=vault in STRICT_VAULTS,
            )
        )
    return findings


def evaluate_entra(apps: list[dict[str, Any]], now: dt.datetime) -> list[Finding]:
    findings = []
    for app in apps:
        app_name = app.get("displayName") or app.get("appId") or "<unnamed app>"
        credentials = []
        for credential in app.get("passwordCredentials") or []:
            credentials.append(("client secret", credential))
        for credential in app.get("keyCredentials") or []:
            credentials.append(("certificate", credential))
        for kind, credential in credentials:
            label = credential.get("displayName") or credential.get("keyId") or "<unnamed>"
            name = f"{app_name} / {label}"
            expires = parse_timestamp(credential.get("endDateTime"))
            finding = classify(
                source="Entra app",
                name=name,
                kind=kind,
                expires=expires,
                now=now,
                required=True,
            )
            if expires is None and finding.status == FAIL:
                finding.detail = "credential has no readable end date"
            findings.append(finding)
    return findings


def validate_entra_apps(apps: list[dict[str, Any]]) -> int:
    """Return the credential count, or raise when the Graph answer is empty/unreadable.

    An empty application list is not a clean tenant: it means Graph returned nothing to a
    Directory Readers identity that should see every app. Treat it as a collection error so a
    broken check never reads as "nothing expires".
    """
    if not apps:
        raise CollectionError("Graph returned no applications; Directory Readers may be missing")
    count = sum(
        len(app.get("passwordCredentials") or []) + len(app.get("keyCredentials") or [])
        for app in apps
    )
    if count == 0:
        raise CollectionError("no Entra app credentials were readable; refusing to report a clean pass")
    return count


def counts(findings: list[Finding]) -> dict[str, int]:
    result = {FAIL: 0, WARN: 0, OK: 0}
    for finding in findings:
        result[finding.status] += 1
    return result


def urgent_count(findings: list[Finding]) -> int:
    """Credentials inside the 7-day window, including already expired ones.

    A FAIL with no days (no expiry, or an unreadable end date) is NOT urgent:
    it has no deadline to race. Expired credentials have negative days and are
    the most urgent of all.
    """
    return sum(1 for finding in findings if finding.days is not None and finding.days <= URGENT_DAYS)


def _cell(value: str) -> str:
    return value.replace("|", r"\|")


def render_markdown(
    findings: list[Finding], now: dt.datetime, vaults: list[str], app_count: int
) -> str:
    summary = counts(findings)
    lines = [
        "## Secret and credential expiry",
        "",
        f"Checked {len(vaults)} Key Vault(s) and {app_count} Entra app credential(s) at "
        f"{now.strftime('%Y-%m-%d %H:%M UTC')}.",
        "",
        f"**{summary[FAIL]} FAIL, {summary[WARN]} WARN, {summary[OK]} OK** "
        f"({urgent_count(findings)} urgent: expires within 7 days or already expired). "
        "FAIL means a prod/platform secret has no expiry, or a credential is expired or expires "
        "within 7 days; WARN means it expires within 30 days.",
        "",
    ]
    notable = [f for f in findings if f.status != OK]
    if not notable:
        lines.append("No credential expires within 30 days and every prod/platform vault secret has an expiry.")
        return "\n".join(lines) + "\n"

    lines.extend(
        [
            "| Status | Source | Name | Kind | Expires | Days | Detail |",
            "|---|---|---|---|---|---|---|",
        ]
    )
    for finding in sorted(notable, key=lambda f: (STATUS_ORDER[f.status], f.name)):
        expires = finding.expires.strftime("%Y-%m-%d") if finding.expires else "none"
        days = "" if finding.days is None else str(finding.days)
        lines.append(
            f"| {finding.status} | {_cell(finding.source)} | {_cell(finding.name)} | "
            f"{finding.kind} | {expires} | {days} | {_cell(finding.detail)} |"
        )
    fixes = sorted({f.fix for f in notable if f.fix})
    if fixes:
        lines.extend(["", "### What to do"])
        lines.extend(f"- {fix}" for fix in fixes)
    return "\n".join(lines) + "\n"


def _az_json(args: list[str]) -> Any:
    process = subprocess.run(
        ["az", *args, "--only-show-errors", "--output", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        raise CollectionError(process.stderr.strip() or f"az {' '.join(args)} failed")
    try:
        return json.loads(process.stdout or "[]")
    except json.JSONDecodeError as error:
        raise CollectionError(f"az returned invalid JSON: {error}") from error


def collect_key_vault(vault: str) -> list[dict[str, Any]]:
    return _az_json(["keyvault", "secret", "list", "--vault-name", vault])


def collect_entra() -> list[dict[str, Any]]:
    url = (
        "https://graph.microsoft.com/v1.0/applications"
        "?$select=displayName,appId,passwordCredentials,keyCredentials&$top=999"
    )
    apps: list[dict[str, Any]] = []
    while url:
        page = _az_json(["rest", "--method", "get", "--url", url])
        apps.extend(page.get("value") or [])
        url = page.get("@odata.nextLink") or ""
    return apps


def write_json(path: str, findings: list[Finding], now: dt.datetime, vaults: list[str]) -> None:
    payload = {
        "checked_at": now.isoformat().replace("+00:00", "Z"),
        "vaults": vaults,
        "counts": counts(findings),
        "urgent": urgent_count(findings),
        "findings": [
            {
                **dataclasses.asdict(finding),
                "expires": finding.expires.isoformat().replace("+00:00", "Z") if finding.expires else None,
            }
            for finding in findings
        ],
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vaults", nargs="+", default=list(DEFAULT_VAULTS))
    parser.add_argument("--now", help="ISO timestamp for tests (default: now)")
    parser.add_argument("--markdown", help="write the Markdown report here (default: stdout)")
    parser.add_argument("--json", help="write the machine-readable report here")
    parser.add_argument("--skip-entra", action="store_true")
    args = parser.parse_args(argv)

    now = parse_timestamp(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    if now is None:
        parser.error("--now is not a valid ISO timestamp")

    try:
        findings: list[Finding] = []
        for vault in args.vaults:
            findings.extend(evaluate_key_vault(collect_key_vault(vault), vault, now))
        app_count = 0
        if not args.skip_entra:
            apps = collect_entra()
            app_count = validate_entra_apps(apps)
            findings.extend(evaluate_entra(apps, now))
    except CollectionError as error:
        message = f"expiry watch could not run: {error}\n"
        if args.markdown:
            with open(args.markdown, "w", encoding="utf-8") as handle:
                handle.write("## Secret and credential expiry\n\n**COULD NOT RUN**\n\n")
                handle.write(f"```\n{error}\n```\n")
        sys.stderr.write(message)
        return 2

    report = render_markdown(findings, now, args.vaults, app_count)
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8") as handle:
            handle.write(report)
    else:
        sys.stdout.write(report)
    if args.json:
        write_json(args.json, findings, now, args.vaults)

    return 1 if counts(findings)[FAIL] else 0


if __name__ == "__main__":
    sys.exit(main())
