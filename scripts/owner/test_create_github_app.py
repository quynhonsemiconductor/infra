#!/usr/bin/env python3
"""Offline tests for create_github_app.py. A stub `op` on PATH logs every argv and keeps stdin; a local
fake plays api.github.com's /app-manifests/<code>/conversions. No GitHub, no 1Password, no browser.
Checks: the form page carries the manifest and a state; a wrong state is refused without touching
1Password or GitHub; the happy path stores the key once, through stdin only; the key, client secret and
webhook secret reach neither stdout, stderr nor any argv; an existing 1Password item refuses a second app;
a rejected code fails. A PASS here must fail on broken input (see the mutation note at the bottom).
"""
import http.server
import json
import os
import pathlib
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "create_github_app.py"
PEM = "-----BEGIN RSA PRIVATE KEY-----\nSTUBPRIVATEKEYBODY-9f3\n-----END RSA PRIVATE KEY-----\n"
SECRETS = ["STUBPRIVATEKEYBODY-9f3", "STUBCLIENTSECRET-77", "STUBWEBHOOKSECRET-88"]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Fake(http.server.BaseHTTPRequestHandler):
    calls: list = []
    ok = True

    def log_message(self, *_):
        pass

    def do_POST(self):
        Fake.calls.append(self.path)
        if not Fake.ok or "/app-manifests/good-code/conversions" not in self.path:
            self.send_response(404); self.end_headers(); return
        body = json.dumps({"id": 4242424, "slug": "qnsc-iac-read", "pem": PEM,
                           "client_secret": SECRETS[1], "webhook_secret": SECRETS[2]}).encode()
        self.send_response(201); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)


def run_case(name, *, existing=False, callback="good-code", state_ok=True, which="read", api_ok=True):
    tmp = pathlib.Path(tempfile.mkdtemp())
    bin_ = tmp / "bin"; bin_.mkdir()
    log = tmp / "op.log"; store = tmp / "stored.pem"
    stub = bin_ / "op"
    stub.write_text(f"""#!/bin/sh
echo "$@" >> {log}
if [ "$1 $2" = "document get" ]; then {'exit 0' if existing else 'exit 1'}; fi
if [ "$1 $2" = "document create" ]; then cat > {store}; exit 0; fi
exit 2
""")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    Fake.calls = []; Fake.ok = api_ok
    fake = http.server.HTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    port = 8765  # the manifest's redirect_url is fixed
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}")
    p = subprocess.Popen([sys.executable, str(SCRIPT), which, "--no-open", "--api", f"http://127.0.0.1:{fake.server_port}"],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    page = ""
    if not existing:
        for _ in range(50):
            try:
                page = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2).read().decode(); break
            except Exception:
                time.sleep(0.1)
        state = page.split("state=")[1].split('"')[0] if "state=" in page else "x"
        q = f"code={callback}&state={state if state_ok else 'WRONG'}"
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/callback?{q}", timeout=5)
            assert state_ok, "a callback with the wrong state was accepted"
        except urllib.error.HTTPError as e:
            if state_ok:
                raise
            assert e.code == 400, e.code
            # a refused callback must leave the script waiting: unblock it with a good one
            urllib.request.urlopen(f"http://127.0.0.1:{port}/callback?code={callback}&state={state}", timeout=5)
    out, err = p.communicate(timeout=30)
    fake.shutdown()
    return dict(page=page, out=out, err=err, rc=p.returncode, log=log.read_text() if log.exists() else "",
                stored=store.read_text() if store.exists() else "", api_calls=list(Fake.calls))


def no_secret_leak(r):
    blob = r["out"] + r["err"] + r["log"]
    for s in SECRETS:
        assert s not in blob, f"secret {s} leaked"


# 1. happy path
r = run_case("happy")
assert r["rc"] == 0, r
assert "organizations/quynhonsemiconductor/settings/apps/new?state=" in r["page"]
assert "qnsc-iac-read" in r["page"] and "&quot;administration&quot;: &quot;read&quot;" in r["page"]
assert r["stored"] == PEM, "key not stored through stdin"
assert r["log"].count("document create") == 1
assert "--vault QNSC" in r["log"] and "GitHub App - qnsc-iac-read - private key" in r["log"]
no_secret_leak(r)
assert "gh variable set IAC_READ_APP_ID" in r["out"] and "4242424" in r["out"]
assert "IAC_READ_APP_KEY" in r["out"] and "/installations" in r["out"]
assert r["api_calls"] == ["/app-manifests/good-code/conversions"]
print("PASS happy path")

# 2. wrong state is refused, then a good callback completes (one store only)
r = run_case("state", state_ok=False)
assert r["rc"] == 0 and r["log"].count("document create") == 1
assert r["api_calls"] == ["/app-manifests/good-code/conversions"], "conversion ran for the bad state"
no_secret_leak(r)
print("PASS wrong state refused")

# 3. an existing item refuses a second app
r = run_case("exists", existing=True)
assert r["rc"] != 0 and "already has" in r["err"] and "document create" not in r["log"] and not r["api_calls"]
print("PASS existing item refused")

# 4. rejected code
r = run_case("badcode", callback="bad-code")
assert r["rc"] != 0 and "rejected the manifest code" in r["err"] and "document create" not in r["log"]
print("PASS rejected code fails, nothing stored")

# 5. apply variant wires the environment secret
r = run_case("apply", which="apply")
assert "IAC_APPLY_APP_KEY --env production" in r["out"] and "IAC_APPLY_APP_ID --env production" in r["out"]
print("PASS apply variant")

# 6. manifests match the agreed permissions
apps = HERE.parent.parent / "live/github/apps"
read = json.loads((apps / "qnsc-iac-read.json").read_text()); apply_ = json.loads((apps / "qnsc-iac-apply.json").read_text())
assert read["default_permissions"] == {"administration": "read", "environments": "read", "metadata": "read"}
assert apply_["default_permissions"] == {"administration": "write", "environments": "write", "metadata": "read"}
for m in (read, apply_):
    assert m["public"] is False and m["default_events"] == [] and "hook_attributes" not in m
print("PASS manifests")
