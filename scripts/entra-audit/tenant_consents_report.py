#!/usr/bin/env python3
"""Render the tenant-wide consent report from the JSON collected by tenant-consents.sh.

The input is metadata only (app display names, scope names, role names); it holds no secret value. The
script makes no network call and needs nothing but Python 3.10+.

    python3 tenant_consents_report.py tenant-consents.json

Writes markdown to stdout. Exit status: 0 rendered, 2 unusable input.
"""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


def _cell(text: Any) -> str:
    """One markdown table cell: keep names literal, break the table only on a pipe."""
    return str(text).replace("|", "\\|")


def render(data: dict[str, Any]) -> str:
    delegated = data.get("delegated") or []
    application = data.get("application") or []
    lines = [
        "# Tenant-wide consents (QNSC)",
        "",
        f"Collected {data.get('collectedAt', '(unknown time)')} by {data.get('collectedBy', '(unknown user)')} "
        f"in tenant {data.get('tenantId', '(unknown tenant)')}.",
        "",
        "Tenant-wide delegated grants are consentType `AllPrincipals`: every user is an actor for the listed",
        "scopes. Application permissions are consented once for the app (client credentials), so they are not",
        "per user by nature. Decide per app: keep only a sanctioned tool, and prefer per-user grants for the",
        "people who use it; revoke the rest by deleting the grant (delegated) or the assignment (application).",
        "",
        f"## Delegated grants (AllPrincipals) — {len(delegated)}",
        "",
    ]
    if delegated:
        lines += ["| Client app | Resource | Scopes |", "| :--- | :--- | :--- |"]
        for row in delegated:
            scopes = ", ".join(f"`{_cell(s)}`" for s in row.get("scopes") or [])
            lines.append(f"| {_cell(row.get('client', '?'))} | {_cell(row.get('resource', '?'))} | {scopes} |")
    else:
        lines.append("None.")
    lines += [
        "",
        f"## Application permissions (Microsoft Graph, Exchange Online) — {len(application)}",
        "",
    ]
    if application:
        lines += ["| Client app | Resource | Permission |", "| :--- | :--- | :--- |"]
        for row in application:
            lines.append(
                f"| {_cell(row.get('client', '?'))} | {_cell(row.get('resource', '?'))} | `{_cell(row.get('role', '?'))}` |"
            )
    else:
        lines.append("None.")
    lines += [
        "",
        "Revoking a delegated grant: Entra admin center > Enterprise applications > <app> > Permissions >",
        "Admin consent, or `Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId <id>` (Graph). Revoking an",
        "application permission: delete the app role assignment, or remove the app from the enterprise app list.",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: tenant_consents_report.py tenant-consents.json", file=sys.stderr)
        return 2
    path = pathlib.Path(argv[1])
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"tenant_consents_report: cannot read {path}: {error}", file=sys.stderr)
        return 2
    if not isinstance(data, dict) or not isinstance(data.get("delegated"), list) or not isinstance(data.get("application"), list):
        print(f"tenant_consents_report: {path} is not a tenant-consents.json (missing delegated/application lists)", file=sys.stderr)
        return 2
    print(render(data), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
