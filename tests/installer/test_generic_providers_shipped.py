"""Shipped profiles on the generic provider schema, and the credentials array.

- custom-inference takes its endpoint from `config: OPENAI_BASE_URL`
  (secretKey url); that base URL drives OpenClaw onboarding exactly like
  baseUrlSecretKey did.
- data-science's nvidia provider reads its model from the `inference`
  Secret (`modelSecretKey: model`), the literal being the default.
- A provider may carry a `credentials:` array: the first entry is the
  primary credential, the rest become extra `--credential ENV` flags.
"""
import importlib.util

import pytest

from conftest import ROOT, profile_files


def _secret(dirpath, name, **keys):
    base = dirpath / name
    base.mkdir(parents=True, exist_ok=True)
    for key, value in keys.items():
        (base / key).write_text(value)


def _provider(profiles, name):
    return next(p for prof in profiles for ws in prof.workspaces for p in ws.providers
                if p.name == name)


# --- custom-inference: base URL through config ----------------------------

def test_custom_inference_endpoint_comes_from_config(ab, tmp_path):
    profiles = ab.parse_profiles(profile_files("custom-inference"))
    ab.validate_profiles(profiles)
    custom = _provider(profiles, "custom")
    assert custom.base_url_secret_key == ""          # no dedicated field any more
    assert custom.config["OPENAI_BASE_URL"]["secretKey"] == "url"

    _secret(tmp_path, "inference", provider="openai", api_key="sk-test",
            url="https://vllm.models.svc:8443/v1", model="meta-llama/Llama-3.1-8B-Instruct")
    _secret(tmp_path, "web-search", api_key="brave-test")
    ab.resolve_credentials(profiles, tmp_path)
    # The config-supplied URL is the provider's endpoint (drives onboarding).
    assert custom.base_url == "https://vllm.models.svc:8443/v1"
    assert custom.model == "meta-llama/Llama-3.1-8B-Instruct"


def test_config_base_url_drives_custom_onboarding(ab, fake_env, config, tmp_path):
    provider = ab.Provider(name="inference", type="openai", model="llama3",
                           credential_secret="inference", credential_secret_key="api_key",
                           config={"OPENAI_BASE_URL": {"secretKey": "url"}})
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    profiles = [ab.Profile(name="test", workspaces=[workspace])]
    _secret(tmp_path, "inference", api_key="sk-test", url="http://ollama.models.svc:11434/v1")

    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)

    created = fake_env.openshell_state()["providers"]["default/inference"]
    # Passed once (base-URL mapping and config entry are the same key).
    assert created["config"] == ["OPENAI_BASE_URL=http://ollama.models.svc:11434/v1"]
    onboard = next(c[-1] for c in fake_env.openshell_calls()
                   if c[:2] == ["sandbox", "exec"] and "openclaw onboard " in c[-1])
    assert "--auth-choice custom-api-key " in onboard
    assert "--custom-base-url http://ollama.models.svc:11434/v1" in onboard
    assert "--custom-model-id llama3" in onboard


def test_a_bad_config_base_url_is_refused(ab, tmp_path):
    provider = ab.Provider(name="inference", type="openai",
                           credential_secret="inference", credential_secret_key="api_key",
                           config={"OPENAI_BASE_URL": {"secretKey": "url"}})
    workspace = ab.Workspace(name="default", providers=[provider])
    _secret(tmp_path, "inference", api_key="sk-test", url="http://localhost:8000/v1")
    with pytest.raises(ab.InstallerError, match="OPENAI_BASE_URL"):
        ab.resolve_credentials([ab.Profile(name="t", workspaces=[workspace])], tmp_path)


# --- nvidia: model from the Secret ------------------------------------------

def test_nvidia_model_comes_from_the_inference_secret(ab, tmp_path):
    profiles = ab.parse_profiles(profile_files("data-science"))
    ab.validate_profiles(profiles)
    _secret(tmp_path, "inference", provider="build", api_key="nvapi-test",
            model="nvidia/nemotron-3-super-120b-a12b")
    _secret(tmp_path, "web-search", api_key="brave-test")
    ab.resolve_credentials(profiles, tmp_path)
    nvidia = [p for prof in profiles for ws in prof.workspaces for p in ws.providers
              if p.type == "nvidia"]
    assert nvidia and all(p.model == "nvidia/nemotron-3-super-120b-a12b" for p in nvidia)


def test_nvidia_falls_back_to_the_profile_model(ab, tmp_path):
    profiles = ab.parse_profiles(profile_files("data-science"))
    _secret(tmp_path, "inference", provider="build", api_key="nvapi-test")   # no model key
    _secret(tmp_path, "web-search", api_key="brave-test")
    ab.resolve_credentials(profiles, tmp_path)
    assert _provider(profiles, "nvidia").model == "nvidia/nemotron-3.5-lightning-30b-a3b"


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


# --- RHDH form fields (catalog) ------------------------------------------------

def _catalog_module():
    spec = importlib.util.spec_from_file_location(
        "saw_profile_catalog", ROOT / "scripts" / "saw-profile-catalog.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_form_asks_for_config_and_extra_credentials():
    cat = _catalog_module()
    fields = cat.secret_fields({
        "credentialSecret": "x",
        "credentials": [{"secretKey": "api_key"}, {"secretKey": "app_secret", "title": "App secret"}],
        "config": {"OPENAI_BASE_URL": {"secretKey": "url", "title": "Endpoint"},
                   "OPENAI_ORG": {"value": "acme"},              # literal: not asked
                   "OPENAI_PROJECT": {"secretKey": "project"}},
    })
    by_key = {f["key"]: f for f in fields}
    assert by_key["api_key"]["kind"] == "secret" and by_key["app_secret"]["kind"] == "secret"
    assert by_key["app_secret"]["title"] == "App secret"
    assert by_key["url"]["kind"] == "url" and by_key["url"]["title"] == "Endpoint"
    assert by_key["project"]["kind"] == "text" and by_key["project"]["title"] == "OPENAI_PROJECT"
    assert "acme" not in str(fields)
