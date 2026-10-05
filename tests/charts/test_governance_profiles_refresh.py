"""Slack and Gmail governance profiles: read-only, refreshable, reachable by node."""
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ROOT / "charts" / "governance-policy" / "profiles"


@pytest.mark.parametrize("name, token_url, env", [
    ("slack", "https://slack.com/api/oauth.v2.access", "SLACK_BOT_TOKEN"),
    ("gmail", "https://oauth2.googleapis.com/token", "GMAIL_ACCESS_TOKEN")])
def test_the_gateway_can_refresh_the_token(name, token_url, env):
    doc = yaml.safe_load((PROFILES / f"{name}.yaml").read_text())
    [cred] = doc["credentials"]
    assert env in cred["env_vars"] and cred["auth_style"] == "bearer"
    refresh = cred["refresh"]
    assert refresh["strategy"] == "oauth2_refresh_token" and refresh["token_url"] == token_url
    material = {m["name"]: m for m in refresh["material"]}
    assert set(material) == {"client_id", "client_secret", "refresh_token"}
    assert material["client_secret"]["secret"] and material["refresh_token"]["secret"]
    assert 0 < refresh["refresh_before_seconds"] < refresh["max_lifetime_seconds"]


@pytest.mark.parametrize("name", ["slack", "gmail"])
def test_read_only_and_reachable_from_node(name):
    doc = yaml.safe_load((PROFILES / f"{name}.yaml").read_text())
    methods = {r["allow"]["method"] for e in doc["endpoints"] for r in e["rules"]}
    assert methods == {"GET"}
    assert {"/usr/bin/node-*", "/usr/local/bin/node"} <= set(doc["binaries"])
