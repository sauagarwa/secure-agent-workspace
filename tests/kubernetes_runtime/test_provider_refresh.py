"""OpenShell refreshes OAuth access tokens; the runtime only hands it the material."""
import copy
import json

from saw_kubernetes import Reconciler
from saw_kubernetes.compiler import MANAGED, OWNER
from .test_runtime import FakeGateway

OWNER_ID = "b032b2e4-2cd5-47a7-8ef8-ac73e15700b1"
PLAN = {"ownerID": OWNER_ID}
WS = {"name": "default"}
GMAIL = {"metadata": {"name": "gmail", "labels": {OWNER: OWNER_ID, MANAGED: "kubernetes-runtime"}},
         "type": "gmail", "credentialRef": {"secret": "gmail", "key": "access_token"},
         "refresh": {"strategy": "oauth2_refresh_token",
                     "material": ["client_id", "client_secret", "refresh_token"]}}


class RefreshGateway(FakeGateway):
    def __init__(self):
        super().__init__()
        self.refresh_ok = True

    def call(self, method, request):
        if method in ("ConfigureProviderRefresh", "RotateProviderCredential"):
            self.calls.append((method, copy.deepcopy(request)))
            return {"status": {}}
        if method == "GetProviderRefreshStatus":
            status = {"credential_key": request["credential_key"]}
            if not self.refresh_ok:
                status["last_error"] = "invalid_grant"
            return {"credentials": [status]}
        response = super().call(method, request)
        if method == "CreateProvider":
            obj = response["provider"]
            obj["metadata"]["resource_version"] = "1"
            obj["credentials"] = {k: "REDACTED" for k in obj.get("credentials", {})}
        return response


def setup(tmp_path):
    gateway = RefreshGateway()
    secret = {"revision": "1"}
    def read_credential(name, key):
        return f"{key}-{secret['revision']}", secret["revision"]
    core = Reconciler(gateway, tmp_path / "ledger", lambda _: None, read_credential=read_credential)
    core.credential_env["gmail"] = "GMAIL_ACCESS_TOKEN"
    return core, gateway, secret


def run(core, state):
    pending = []
    return core._apply_provider(WS, GMAIL, PLAN, state, 1, pending), pending


def methods(gateway, name):
    return [r for m, r in gateway.calls if m == name]


def test_refresh_is_configured_once_per_secret_revision(tmp_path):
    core, gateway, secret = setup(tmp_path)
    state = {}
    assert run(core, state) == (False, ["provider/default/gmail"])   # created
    assert run(core, state) == (False, ["provider/default/gmail"])   # refresh configured
    configure, = methods(gateway, "ConfigureProviderRefresh")
    assert configure["credential_key"] == "GMAIL_ACCESS_TOKEN"
    assert configure["strategy"] == "PROVIDER_CREDENTIAL_REFRESH_STRATEGY_OAUTH2_REFRESH_TOKEN"
    assert configure["material"] == {"client_id": "client_id-1", "client_secret": "client_secret-1",
                                     "refresh_token": "refresh_token-1"}
    assert set(configure["secret_material_keys"]) == {"client_id", "client_secret", "refresh_token"}
    assert len(methods(gateway, "RotateProviderCredential")) == 1
    assert run(core, state) == (True, [])
    assert len(methods(gateway, "ConfigureProviderRefresh")) == 1   # unchanged Secret: not re-sent

    secret["revision"] = "2"
    assert run(core, state)[0] is False
    assert len(methods(gateway, "ConfigureProviderRefresh")) == 2
    assert not methods(gateway, "UpdateProvider")   # OpenShell owns the refreshed token
    assert run(core, state) == (True, [])

    stored = json.dumps(core.store.load()) + json.dumps(state)
    ids = json.dumps([r.get("request_id") for _, r in gateway.calls])
    assert "refresh_token-" not in stored + ids and "client_secret-" not in stored + ids


def test_failing_refresh_is_reported(tmp_path):
    core, gateway, _ = setup(tmp_path)
    state = {}
    run(core, state); run(core, state)
    gateway.refresh_ok = False
    import pytest
    from saw_kubernetes import ContractError
    with pytest.raises(ContractError, match="refresh is failing"):
        run(core, state)
