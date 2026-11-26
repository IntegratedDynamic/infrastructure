"""The CI side of headscale-sts: .github/actions/debug-tailscale/get-authkey.sh,
run against a stand-in for headscale and for GitHub's token endpoint. The server
side of the same exchange is tested in the gitops repo
(services/platform/headscale/tests)."""

import http.server
import json
import os
import pathlib
import subprocess
import threading

import pytest
import yaml

ACTION = pathlib.Path(__file__).resolve().parents[1] / ".github/actions/debug-tailscale"
SCRIPT = ACTION / "get-authkey.sh"
JOB_TOKEN = "header.payload.signature"
KEY = "hskey-auth-test-0123456789"


class Server:
    def __init__(self):
        self.requests = []
        self.health = 200
        self.token = (200, json.dumps({"value": JOB_TOKEN}))
        self.authkey = (200, KEY)
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                server.requests.append(("GET", self.path, self.headers.get("Authorization")))
                if self.path == "/sts/healthz":
                    self.reply(server.health, "ok\n")
                elif self.path.startswith("/token?"):
                    self.reply(*server.token)
                else:
                    self.reply(404, "not found")

            def do_POST(self):
                server.requests.append(("POST", self.path, self.headers.get("Authorization")))
                self.reply(*(server.authkey if self.path == "/sts/authkey" else (404, "not found")))

            def reply(self, status, body):
                self.send_response(status)
                self.send_header("Content-Length", str(len(body.encode())))
                self.end_headers()
                self.wfile.write(body.encode())

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def posts(self):
        return [r for r in self.requests if r[0] == "POST"]


@pytest.fixture
def server():
    s = Server()
    yield s
    s.httpd.shutdown()


@pytest.fixture
def step(tmp_path, server):
    """Runs the script the way the composite action does."""

    def run(login_server=None, id_token=True):
        output = tmp_path / "github_output"
        output.write_text("")
        env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(output),
               "LOGIN_SERVER": login_server or server.url}
        if id_token:
            env.update(ACTIONS_ID_TOKEN_REQUEST_URL=f"{server.url}/token?api-version=2.0",
                       ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token")
        result = subprocess.run(["bash", SCRIPT], env=env, capture_output=True, text=True, timeout=120)
        result.outputs = dict(l.split("=", 1) for l in output.read_text().splitlines())
        return result

    return run


def test_returns_the_key_for_the_job_token(server, step):
    result = step()
    assert result.returncode == 0, result.stderr
    assert result.outputs == {"key": KEY}
    token_request = next(r for r in server.requests if r[1].startswith("/token?"))
    assert token_request[1].endswith(f"&audience={server.url}/sts")
    assert token_request[2] == "bearer request-token"
    assert server.posts() == [("POST", "/sts/authkey", f"Bearer {JOB_TOKEN}")]


def test_masks_the_token_and_the_key_before_anything_else(step):
    lines = step().stdout.splitlines()
    assert lines == [f"::add-mask::{JOB_TOKEN}", f"::add-mask::{KEY}"]


def test_only_warns_when_headscale_is_unreachable(step):
    result = step(login_server="http://127.0.0.1:1")
    assert result.returncode == 0
    assert "::warning::headscale is unreachable" in result.stdout
    assert result.outputs == {}


def test_only_warns_when_sts_is_not_serving(server, step):
    server.health = 503
    result = step()
    assert result.returncode == 0 and "::warning::" in result.stdout
    assert result.outputs == {} and server.posts() == []


@pytest.mark.parametrize("status,reason", [(401, "token rejected"), (403, "no rule matched"), (502, "minting key failed")])
def test_fails_when_refused_and_does_not_retry(server, step, status, reason):
    server.authkey = (status, reason)
    result = step()
    assert result.returncode == 1
    assert f"::error::headscale-sts refused to mint a key: {reason}" in result.stdout
    assert result.outputs == {}
    assert len(server.posts()) == 1, "a token mints one key: never post it twice"


@pytest.mark.parametrize("token", [(500, "boom"), (200, "{}")], ids=["error", "no-value"])
def test_fails_when_github_gives_no_token(server, step, token):
    server.token = token
    result = step()
    assert result.returncode != 0
    assert result.outputs == {} and server.posts() == []


def test_explains_the_missing_permission(step):
    result = step(id_token=False)
    assert result.returncode == 1 and "id-token: write" in result.stdout


def test_action_joins_with_the_key_it_got():
    steps = yaml.safe_load((ACTION / "action.yml").read_text())["runs"]["steps"]
    get, join = steps
    assert "get-authkey.sh" in get["run"] and get["env"]["LOGIN_SERVER"] == "${{ inputs.login-server }}"
    assert join["if"] == f"steps.{get['id']}.outputs.key != ''"
    assert join["with"]["authkey"] == "${{ steps.%s.outputs.key }}" % get["id"]
    assert join["with"]["args"].split(" --") == ["--ssh", "login-server=${{ inputs.login-server }}"]
    # The key carries the tag: asking for tags again is refused by headscale.
    assert "tags" not in join["with"]


@pytest.mark.parametrize("workflow", sorted((ACTION.parents[1] / "workflows").glob("*.yml")), ids=lambda p: p.name)
def test_callers_grant_the_oidc_token(workflow):
    content = yaml.safe_load(workflow.read_text())
    for job in content["jobs"].values():
        if any(s.get("uses") == "./.github/actions/debug-tailscale" for s in job.get("steps", [])):
            permissions = job.get("permissions", content.get("permissions", {}))
            assert permissions.get("id-token") == "write"
