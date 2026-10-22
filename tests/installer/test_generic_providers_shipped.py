"""Shipped profiles on the provider/sandbox split, and the credentials array.

- A provider holds only credentials. The workload's settings (endpoint,
  model, ...) are the sandbox's `env:`, passed as `sandbox create --env`,
  as OpenShell 0.1.2 documents.
- data-science's sandboxes read MODEL from the `inference` Secret, the
  profile's model being the default.
- A provider may carry a `credentials:` array: the first entry is the
  primary credential, the rest become extra `--credential ENV` flags.
"""
import importlib.util
import json

import pytest

from conftest import ROOT, profile_files


def _secret(dirpath, name, **keys):
    base = dirpath / name
    base.mkdir(parents=True, exist_ok=True)
    for key, value in keys.items():
        (base / key).write_text(value)


def _sandboxes(profiles):
    return [sb for prof in profiles for ws in prof.workspaces for sb in ws.sandboxes
            if sb.enabled]


# --- data-science: the model from the Secret, through the sandbox env --------

def test_data_science_sandboxes_read_model_from_the_inference_secret(ab, tmp_path):
    profiles = ab.parse_profiles(profile_files("data-science"))
    ab.validate_profiles(profiles)
    _secret(tmp_path, "inference", provider="build", api_key="nvapi-test",
            model="nvidia/nemotron-3-super-120b-a12b")
    _secret(tmp_path, "web-search", api_key="brave-test")
    ab.resolve_credentials(profiles, tmp_path)
    agents = [sb for sb in _sandboxes(profiles) if sb.type in ("openclaw", "nemoclaw")]
    assert agents and all(sb.env_values == {"MODEL": "nvidia/nemotron-3-super-120b-a12b"}
                          for sb in agents)
    # The providers are credentials only, as on main.
    nvidia = [p for prof in profiles for ws in prof.workspaces for p in ws.providers
              if p.type == "nvidia"]
    assert nvidia and all(p.model_secret_key == "" for p in nvidia)


def test_data_science_falls_back_to_the_profile_model(ab, tmp_path):
    profiles = ab.parse_profiles(profile_files("data-science"))
    _secret(tmp_path, "inference", provider="build", api_key="nvapi-test")   # no model key
    _secret(tmp_path, "web-search", api_key="brave-test")
    ab.resolve_credentials(profiles, tmp_path)
    assert {sb.env_values["MODEL"] for sb in _sandboxes(profiles) if sb.env_values} == {
        "nvidia/nemotron-3.5-lightning-30b-a3b"}


# --- credentials array --------------------------------------------------------

TWO_CRED_PROFILE = (
    "id: twokey\n"
    "credentials:\n"
    "  - name: api_key\n"
    "    env_vars: [TWOKEY_API_KEY]\n"
    "  - name: app_secret\n"
    "    env_vars: [TWOKEY_APP_SECRET]\n")


def _two_cred_profiles(ab, credentials):
    provider = ab.Provider(name="tk", type="twokey", credential_secret="tk",
                           credential_secret_key=credentials[0]["secretKey"],
                           credentials_spec=credentials)
    sandbox = ab.Sandbox(name="tools", type="generic", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    return [ab.Profile(name="test", workspaces=[workspace])]


def test_a_credentials_array_passes_every_credential(ab, fake_env, config, tmp_path):
    profiles = _two_cred_profiles(ab, [{"secretKey": "key"}, {"secretKey": "secret"}])
    ab.validate_profiles(profiles, known_profiles={"twokey"})
    _secret(tmp_path, "tk", key="k-123", secret="s-456")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds,
                      provider_profile_docs={"twokey": TWO_CRED_PROFILE}).apply(profiles)
    created = fake_env.openshell_state()["providers"]["default/tk"]
    # Primary first, extra from the profile's second credential's env var.
    assert created["credentials"] == ["TWOKEY_API_KEY=k-123", "TWOKEY_APP_SECRET=s-456"]
    # Values travel in the environment only.
    assert not any("s-456" in " ".join(c) for c in fake_env.openshell_calls())


def test_an_explicit_env_overrides_the_profile(ab, fake_env, config, tmp_path):
    profiles = _two_cred_profiles(ab, [{"secretKey": "key"},
                                       {"secretKey": "secret", "env": "CUSTOM_SECRET"}])
    _secret(tmp_path, "tk", key="k-1", secret="s-2")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds,
                      provider_profile_docs={"twokey": TWO_CRED_PROFILE}).apply(profiles)
    assert fake_env.openshell_state()["providers"]["default/tk"]["credentials"] == [
        "TWOKEY_API_KEY=k-1", "CUSTOM_SECRET=s-2"]


def test_a_missing_extra_credential_is_an_error(ab, tmp_path):
    profiles = _two_cred_profiles(ab, [{"secretKey": "key"}, {"secretKey": "secret"}])
    _secret(tmp_path, "tk", key="k-1")                           # no `secret`
    with pytest.raises(ab.InstallerError, match="credential #2"):
        ab.resolve_credentials(profiles, tmp_path)


def test_credentials_and_credential_secret_key_are_exclusive(ab):
    files = profile_files("custom-inference")
    key = next(k for k in files if k.endswith("providers.yaml"))
    files[key] = files[key].replace("credentialSecretKey: api_key",
                                    "credentialSecretKey: api_key\n      credentials:\n"
                                    "        - secretKey: api_key", 1)
    with pytest.raises(ab.InstallerError, match="both credentials and credentialSecretKey"):
        ab.parse_profiles(files)


def test_bad_credentials_entries_are_rejected(ab):
    profiles = _two_cred_profiles(ab, [{"secretKey": "key"}, {"env": "NO_KEY"}])
    with pytest.raises(ab.InstallerError, match=r"credentials\[1\] needs a valid secretKey"):
        ab.validate_profiles(profiles, known_profiles={"twokey"})


# --- the plan the installer re-executes itself with keeps all of it -----------

def test_the_plan_keeps_sandbox_env_and_extra_credentials(ab, tmp_path):
    profiles = _two_cred_profiles(ab, [{"secretKey": "key"}, {"secretKey": "secret"}])
    profiles[0].workspaces[0].sandboxes[0].env = {"MODEL": {"value": "m"}}
    _secret(tmp_path, "tk", key="k-1", secret="s-2")
    creds = ab.resolve_credentials(profiles, tmp_path)
    plan = json.loads(json.dumps(ab.plan_for_user({}, profiles, creds, "dash.sh")))
    back = ab.profiles_from_plan(plan)
    ws = back[0].workspaces[0]
    assert ws.sandboxes[0].env_values == {"MODEL": "m"}
    assert [value for _, value in ws.providers[0].extra_credential_values] == ["s-2"]


# --- RHDH form fields (catalog) ------------------------------------------------

def _catalog_module():
    spec = importlib.util.spec_from_file_location(
        "saw_profile_catalog", ROOT / "scripts" / "saw-profile-catalog.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_form_asks_for_sandbox_env_and_extra_credentials():
    cat = _catalog_module()
    fields = list(cat.sandbox_env_fields({"env": {
        "OPENAI_BASE_URL": {"secret": "inference", "secretKey": "url", "title": "Endpoint"},
        "MODEL": {"secret": "inference", "secretKey": "model", "default": "m1"},
        "HF_HUB_OFFLINE": {"value": "1"},                  # literal: not asked
    }}))
    by_key = {f["key"]: (secret, f) for secret, f in fields}
    assert set(by_key) == {"url", "model"}
    assert by_key["url"][1]["kind"] == "url" and by_key["url"][1]["title"] == "Endpoint"
    assert by_key["model"][1] == {"key": "model", "kind": "text", "required": True,
                                  "title": "MODEL", "default": "m1"}
    assert {secret for secret, _ in fields} == {"inference"}

    creds = cat.secret_fields({"credentials": [{"secretKey": "api_key"},
                                               {"secretKey": "app_secret", "title": "App secret"}]})
    assert [(f["key"], f["kind"], f["title"]) for f in creds] == [
        ("api_key", "secret", "API key"), ("app_secret", "secret", "App secret")]


def test_the_shipped_form_asks_for_the_custom_endpoint_and_model():
    cat = json.loads((ROOT / "charts" / "openshell-rhdh" / "files" /
                      "profile-catalog.json").read_text())["profiles"]
    custom = {f["key"]: f for f in cat["custom-inference"]["secrets"]["inference"]["fields"]}
    assert list(custom) == ["api_key", "url", "model"]
    assert custom["url"]["kind"] == "url"
    ds = {f["key"]: f for f in cat["data-science"]["secrets"]["inference"]["fields"]}
    assert ds["model"]["default"] == "nvidia/nemotron-3.5-lightning-30b-a3b"
