#!/usr/bin/env python3
"""Create one of the two org-owned GitHub Apps of live/github from its manifest, and put the
private key straight into 1Password. OWNER ONLY (needs org-owner rights in the browser).

    python3 scripts/owner/create_github_app.py read      # qnsc-iac-read  (plans + drift)
    python3 scripts/owner/create_github_app.py apply     # qnsc-iac-apply (apply job)

What happens (GitHub App MANIFEST flow, https://docs.github.com/apps/sharing-github-apps/registering-a-github-app-from-a-manifest):
 1. a tiny web server on 127.0.0.1 serves a page that POSTs live/github/apps/<app>.json to
    https://github.com/organizations/<org>/settings/apps/new (your browser opens it);
 2. you click "Create GitHub App" on GitHub's confirmation page (one click);
 3. GitHub redirects to http://127.0.0.1:<port>/callback?code=...; this script exchanges the
    one-time code for the app credentials (POST /app-manifests/<code>/conversions, valid 1 hour)
    and stores the PRIVATE KEY in 1Password (vault QNSC, Document, via stdin). No .pem file is
    ever written to disk; the key, the client secret and the webhook secret are never printed.
 4. it prints the app id, the install URL and the exact `gh` lines to wire the repository.

Terraform cannot create GitHub Apps, which is why this is a script. The webhook secret and the
client secret returned by GitHub are discarded: the apps have no webhook and no OAuth use.
"""
import argparse
import hmac
import html
import http.server
import json
import pathlib
import secrets
import subprocess
import sys
import threading
import urllib.error
import urllib.request
import webbrowser

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
APPS = {"read": "qnsc-iac-read", "apply": "qnsc-iac-apply"}


def item_title(slug: str) -> str:
    return f"GitHub App - {slug} - private key"


def op_item_exists(title: str, vault: str) -> bool:
    r = subprocess.run(["op", "document", "get", title, "--vault", vault], capture_output=True)
    return r.returncode == 0


def op_store_key(title: str, vault: str, file_name: str, pem: str) -> None:
    # The key travels on stdin only: never argv (visible in `ps`), never a file.
    r = subprocess.run(
        ["op", "document", "create", "-", "--title", title, "--vault", vault, "--file-name", file_name],
        input=pem.encode(), capture_output=True,
    )
    if r.returncode != 0:
        # op's stderr never contains the key (it is only on stdin), so it is safe to show.
        sys.exit(f"1Password refused the document: {r.stderr.decode().strip()}")


def convert(api: str, code: str) -> dict:
    req = urllib.request.Request(
        f"{api}/app-manifests/{code}/conversions", method="POST", data=b"",
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                 "User-Agent": "qnsc-create-github-app"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"GitHub rejected the manifest code (HTTP {e.code}); the code is single use and lasts 1 hour. Run the script again.")


def form_page(org: str, manifest: dict, state: str, github: str) -> str:
    action = f"{github}/organizations/{org}/settings/apps/new?state={state}"
    return (
        "<!doctype html><meta charset=utf-8><title>Create GitHub App</title>"
        f"<form id=f method=post action=\"{html.escape(action)}\">"
        f"<input type=hidden name=manifest value=\"{html.escape(json.dumps(manifest))}\">"
        f"<p>Creating <b>{html.escape(manifest['name'])}</b> in <b>{html.escape(org)}</b>.</p>"
        "<button>Continue to GitHub</button></form><script>document.getElementById('f').submit()</script>"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("which", choices=sorted(APPS))
    ap.add_argument("--org", default="quynhonsemiconductor")
    ap.add_argument("--vault", default="QNSC")
    ap.add_argument("--port", type=int, default=8765, help="must match redirect_url in the manifest")
    ap.add_argument("--no-open", action="store_true", help="print the URL instead of opening a browser")
    ap.add_argument("--github", default="https://github.com", help=argparse.SUPPRESS)
    ap.add_argument("--api", default="https://api.github.com", help=argparse.SUPPRESS)
    a = ap.parse_args()

    slug = APPS[a.which]
    manifest = json.loads((REPO_ROOT / "live/github/apps" / f"{slug}.json").read_text())
    if f":{a.port}/" not in manifest["redirect_url"]:
        sys.exit(f"--port {a.port} does not match redirect_url {manifest['redirect_url']} in the manifest")
    title = item_title(slug)
    if op_item_exists(title, a.vault):
        sys.exit(f'1Password already has "{title}" in vault {a.vault}: the app exists. Refusing to create a second one.')

    state = secrets.token_urlsafe(24)
    done = threading.Event()
    result: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):  # the callback URL carries the one-time code: keep it out of logs
            pass

        def _send(self, status: int, body: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            path, _, query = self.path.partition("?")
            if path == "/":
                return self._send(200, form_page(a.org, manifest, state, a.github))
            if path == "/callback":
                q = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
                if not hmac.compare_digest(q.get("state", ""), state) or not q.get("code"):
                    return self._send(400, "state mismatch or missing code; nothing was done")
                result["code"] = q["code"]
                self._send(200, "<p>Got it. Return to the terminal; you can close this tab.</p>")
                done.set()
                return None
            return self._send(404, "not found")

    server = http.server.HTTPServer(("127.0.0.1", a.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{a.port}/"
    print(f"Open {url} (opening it now). On GitHub, click 'Create GitHub App' once.")
    if not a.no_open:
        webbrowser.open(url)
    if not done.wait(timeout=600):
        server.shutdown()
        sys.exit("timed out after 10 minutes without the GitHub redirect; nothing was created here")
    server.shutdown()

    app = convert(a.api, result["code"])
    pem = app.pop("pem")
    app_id, app_slug = app["id"], app["slug"]
    app.clear()  # client secret and webhook secret: discarded
    op_store_key(title, a.vault, f"{app_slug}.pem", pem)
    del pem

    print(f"\nCreated app {app_slug} (id {app_id}). Private key stored in 1Password: vault {a.vault}, \"{title}\".")
    print(f"\nNext: install it. {a.github}/organizations/{a.org}/settings/apps/{app_slug}/installations")
    print("  -> Install -> 'All repositories'. (Nothing else is needed; the app has no webhook.)\n")
    print("Then wire the repository (these lines read the key from 1Password into gh, never to disk):")
    if a.which == "read":
        print(f'  gh variable set IAC_READ_APP_ID --repo {a.org}/infra --body {app_id}')
        print(f'  op document get "{title}" --vault {a.vault} | gh secret set IAC_READ_APP_KEY --repo {a.org}/infra')
    else:
        print(f'  gh variable set IAC_APPLY_APP_ID --env production --repo {a.org}/infra --body {app_id}')
        print(f'  op document get "{title}" --vault {a.vault} | gh secret set IAC_APPLY_APP_KEY --env production --repo {a.org}/infra')


if __name__ == "__main__":
    main()
