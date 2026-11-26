"""Contracts between this repo and the gitops repo it points ArgoCD at: a wrong
path or a drifted name only shows on a live cluster otherwise.

Needs a gitops checkout: GITOPS_DIR (default: ../gitops next to this repo)."""

import os
import pathlib
import subprocess

import hcl2
import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
GITOPS = pathlib.Path(os.environ.get("GITOPS_DIR", ROOT.parent / "gitops")).resolve()
PLATFORM_APPS = ROOT / "10-cluster/platform-apps"
HEADSCALE = GITOPS / "services/platform/headscale"
VALUE_FILES = sorted(PLATFORM_APPS.glob("values-*.yaml"))
CLUSTER_TFVARS = sorted(ROOT.glob("10-cluster/*/env/*.tfvars"))


def load_yaml(path):
    return yaml.safe_load(path.read_text())


def tfvars(path):
    """A .tfvars file as plain data (python-hcl2 keeps string quotes and adds
    comment entries)."""

    def clean(value):
        if isinstance(value, dict):
            return {clean(k): clean(v) for k, v in value.items() if not k.startswith("__")}
        if isinstance(value, list):
            return [clean(v) for v in value]
        if isinstance(value, str) and len(value) > 1 and value[0] == value[-1] == '"':
            return value[1:-1]
        return value

    with path.open() as handle:
        return clean(hcl2.load(handle))


@pytest.fixture(scope="module", autouse=True)
def gitops_checkout():
    if not (GITOPS / "services").is_dir():
        pytest.fail(f"no gitops checkout at {GITOPS}: set GITOPS_DIR")


APPS = [(f.name, app) for f in VALUE_FILES for app in load_yaml(f).get("apps", [])]


@pytest.mark.parametrize("source,app", APPS, ids=[f"{s}:{a['name']}" for s, a in APPS])
def test_every_application_points_at_a_chart_that_exists(source, app):
    chart = GITOPS / app["chartPath"]
    assert (chart / "Chart.yaml").is_file(), app["chartPath"]
    for key in ("valueFile", "extraValueFileParam"):
        if app.get(key):
            assert (chart / app[key]).is_file(), f"{app['chartPath']}/{app[key]}"


@pytest.mark.parametrize("path", VALUE_FILES, ids=lambda p: p.name)
def test_platform_apps_renders(path):
    subprocess.run(["helm", "template", "platform-apps", PLATFORM_APPS, "-f", path], check=True, capture_output=True)


@pytest.mark.parametrize("path", CLUSTER_TFVARS, ids=lambda p: p.name)
def test_every_domain_uses_values_files_that_exist(path):
    for name, domain in tfvars(path).get("domains", {}).items():
        for values_file in domain.get("value_files", []):
            assert (PLATFORM_APPS / values_file).is_file(), f"{name}: {values_file}"


@pytest.fixture(scope="module")
def headscale():
    chart = load_yaml(HEADSCALE / "chart/values.yaml")
    chart["url"] = f"https://{chart['hostPrefix']}.{chart['domain']}"
    return chart


def test_authentik_client_matches_headscale(headscale):
    sso = tfvars(ROOT / "14-sso/managed/env/14-sso-managed-dev.tfvars")
    slug = headscale["oidc"]["applicationSlug"]
    client = sso["oidc_clients"][slug]
    assert client["client_id"] == headscale["oidc"]["clientID"]
    # The chart ships a placeholder secret: only a public client accepts it.
    assert client["client_type"] == "public"
    assert client["redirect_uris"] == [f"{headscale['url']}/oidc/callback"]
    assert client["groups"], "who may log a device in must be restricted"
    assert sso["domain"] == headscale["domain"]


def test_ci_action_targets_the_deployed_server(headscale):
    action = load_yaml(ROOT / ".github/actions/debug-tailscale/action.yml")
    assert action["inputs"]["login-server"]["default"] == headscale["url"]


def test_this_repository_may_get_ci_keys(headscale):
    assert headscale["sts"]["enabled"]
    assert headscale["sts"]["github"]["repository"] == "IntegratedDynamic/infrastructure"
    repository_id = os.environ.get("GITHUB_REPOSITORY_ID")
    if repository_id and os.environ.get("GITHUB_REPOSITORY") == headscale["sts"]["github"]["repository"]:
        assert headscale["sts"]["github"]["repositoryID"] == repository_id


def test_headscale_is_deployed_restore_first():
    apps = {a["name"]: a for _, a in APPS}
    assert int(apps["headscale-restore"]["wave"]) < int(apps["headscale"]["wave"])
    domains = tfvars(ROOT / "10-cluster/scaleway/env/10-cluster-scaleway-staging.tfvars")["domains"]
    assert domains["headscale-apps"]["needs_backups"] is True
