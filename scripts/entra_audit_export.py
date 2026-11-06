#!/usr/bin/env python3
"""Export Microsoft Entra directory AUDIT logs to the audit storage account.

Why this instead of diagnostic settings: the tenant has no Entra ID P1, and the
sign-in log API is refused on a non-premium tenant (403
Authentication_RequestFromNonPremiumTenantOrB2CTenant). Directory audit logs
ARE readable on Free, so this pulls them over Microsoft Graph with an app-only
token (permission AuditLog.Read.All, granted in live/identity/entra_audit_export.tf)
and appends one gzip JSONL file per run.

Sign-in logs are NOT here; the gap and its weekly manual review are documented in
docs/runbooks/entra-activity-logs.md.

Records contain personal data (UPNs, IP addresses). This script prints COUNTS
only: nothing from a record reaches the log, the step summary or an error
message. The destination is the private, WORM `entra-audit` container on
stqnsckvaudit.

Usage:
    python3 scripts/entra_audit_export.py                 # last 72 h, upload
    python3 scripts/entra_audit_export.py --dry-run       # write locally, no upload
    python3 scripts/entra_audit_export.py --hours 168     # first backfill (API keeps 7 d)
"""

from __future__ import annotations

import argparse
import gzip
import json
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

GRAPH = "https://graph.microsoft.com/v1.0"
GRAPH_HOST = "graph.microsoft.com"
PAGE_SIZE = 1000  # directoryAudits caps $top at 1000


class ExportError(RuntimeError):
    """A step that could not run. Never contains record contents."""


def graph_token() -> str:
    """App-only Graph token from the signed-in Azure identity (OIDC in CI)."""
    proc = subprocess.run(
        [
            "az", "account", "get-access-token",
            "--resource", "https://graph.microsoft.com",
            "--query", "accessToken", "-o", "tsv",
        ],
        capture_output=True, text=True, check=False,
    )
    token = proc.stdout.strip()
    if proc.returncode != 0 or not token:
        raise ExportError("could not get a Microsoft Graph token (az account get-access-token failed)")
    return token


def require_graph_url(url: str) -> None:
    """The bearer token goes to graph.microsoft.com and nowhere else.

    `@odata.nextLink` is server-controlled; a compromised or misconfigured
    response must not be able to redirect the token to another host (the
    classic `https://graph.microsoft.com@evil.example/` shape included:
    urlsplit reads the host as evil.example).
    """
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname != GRAPH_HOST:
        raise ExportError(f"refusing to send the token to {parts.scheme}://{parts.hostname or '?'}")


def fetch_json(url: str, token: str) -> dict:
    require_graph_url(url)
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 - fixed https URL
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # The URL carries only the filter (a timestamp); the body may carry tenant data, so it is dropped.
        raise ExportError(f"Graph directoryAudits returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ExportError("Graph directoryAudits request failed (network)") from exc


def collect(since_iso: str, token: str, fetch=fetch_json) -> list[dict]:
    """Every audit record with activityDateTime >= since_iso, de-duplicated by id."""
    query = urllib.parse.urlencode({"$filter": f"activityDateTime ge {since_iso}", "$top": PAGE_SIZE})
    url: str | None = f"{GRAPH}/auditLogs/directoryAudits?{query}"
    seen: set[str] = set()
    records: list[dict] = []
    while url:
        page = fetch(url, token)
        for record in page.get("value", []):
            record_id = record.get("id")
            if not record_id or record_id in seen:
                continue
            seen.add(record_id)
            records.append(record)
        url = page.get("@odata.nextLink")
        if url:
            # fetch_json checks too; this keeps the contract testable with a fake.
            require_graph_url(url)
    return records


def blob_name(now: datetime) -> str:
    return f"audit-{now:%Y%m%dT%H%M%SZ}.jsonl.gz"


def blob_path(now: datetime) -> str:
    return f"{now:%Y}/{now:%m}/{now:%d}/{blob_name(now)}"


def write_gzip_jsonl(records: list[dict], path: Path) -> None:
    with gzip.open(path, "wt", encoding="utf-8", compresslevel=9) as handle:
        for record in records:
            handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
            handle.write("\n")


def upload(path: Path, name: str, account: str, container: str) -> None:
    proc = subprocess.run(
        [
            "az", "storage", "blob", "upload",
            "--account-name", account,
            "--container-name", container,
            "--name", name,
            "--file", str(path),
            "--auth-mode", "login",      # OIDC identity; no account key, no SAS
            "--overwrite", "false",      # WORM: never replace an existing audit file
            "--only-show-errors", "--output", "none",
        ],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise ExportError(f"az storage blob upload failed (exit {proc.returncode}); stderr: {proc.stderr.strip()[:300]}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export Entra directory audit logs to blob storage.")
    parser.add_argument("--hours", type=int, default=72, help="window ending now; the API keeps 7 days (default: 72)")
    parser.add_argument("--since", help="explicit RFC3339 UTC start instead of --hours")
    parser.add_argument("--account", default="stqnsckvaudit")
    parser.add_argument("--container", default="entra-audit")
    parser.add_argument("--out-dir", help="where to write the gzip file (default: a temp dir)")
    parser.add_argument("--dry-run", action="store_true", help="write locally, do not upload")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    now = datetime.now(timezone.utc)
    if args.since:
        since = args.since
    else:
        if args.hours < 1 or args.hours > 168:
            print("entra-audit-export: --hours must be 1..168 (the API retains 7 days)", file=sys.stderr)
            return 2
        since_dt = now - timedelta(hours=args.hours)
        since = f"{since_dt:%Y-%m-%dT%H:%M:%SZ}"

    try:
        token = graph_token()
        records = collect(since, token)
    except ExportError as exc:
        print(f"entra-audit-export: {exc}", file=sys.stderr)
        return 1

    name = blob_path(now)
    if not records:
        # An empty window is legitimate on a quiet tenant; say so and stop. The
        # next run re-queries 72 h, so nothing is lost by this.
        print(f"entra-audit-export: no audit records since {since}; nothing uploaded")
        return 0

    out_dir = Path(args.out_dir) if args.out_dir else Path(tempfile.mkdtemp(prefix="entra-audit-"))
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / blob_name(now)
    write_gzip_jsonl(records, path)

    if args.dry_run:
        print(f"entra-audit-export: {len(records)} records since {since} -> {path} (dry run, not uploaded)")
        return 0

    try:
        upload(path, name, args.account, args.container)
    except ExportError as exc:
        print(f"entra-audit-export: {exc}", file=sys.stderr)
        return 1

    print(f"entra-audit-export: {len(records)} records since {since} -> {args.container}/{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
