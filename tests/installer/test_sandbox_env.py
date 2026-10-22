"""A sandbox's `env:`: the workload's settings, passed as `sandbox create
--env` and on every `sandbox exec` the installer runs (OpenShell 0.1.2).

Literals are fixed by the profile; `{secret, secretKey}` entries come from a
mounted Secret (else their `default`). Credentials never go here: the agent
can read sandbox env, so those stay on providers.
"""
import pytest

GH_PROFILE = ("id: github\ncredentials:\n  - name: api_token\n"
              "    env_vars: [GITHUB_TOKEN, GH_TOKEN]\n")


def _secret(dirpath, name, **keys):
    base = dirpath / name
    base.mkdir(parents=True, exist_ok=True)
    for key, value in keys.items():
        (base / key).write_text(value)


def _one(ab, env, provider=None, sandbox_type="openclaw", model=""):
    provider = provider or ab.Provider(name="inference", type="openai", model="provider-model",
                                       credential_secret="inference",
                                       credential_secret_key="api_key")
    sandbox = ab.Sandbox(name="chat", type=sandbox_type, providers=[provider.name],
                         env=env, model=model)
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    return provider, sandbox, [ab.Profile(name="test", workspaces=[workspace])]


# --- validation ------------------------------------------------------------------

@pytest.mark.parametrize("name,src,problem", [
    ("OPENSHELL_X", {"value": "1"}, "reserved by OpenShell"),
    ("NVIDIA_API_KEY", {"value": "1"}, "provider credential variable"),
    ("1BAD", {"value": "1"}, "not a valid variable name"),
    ("X", {"value": "a\nb"}, "single line"),
    ("X", {"value": True}, "must be a string"),
    ("X", {"value": "1", "secretKey": "k"}, "exactly one of value or secretKey"),
    ("X", {"secretKey": "k"}, "needs a valid secret"),
    ("X", {"value": "1", "titel": "typo"}, "unknown keys titel"),
])
def test_bad_env_entries_are_rejected(ab, name, src, problem):
    _, _, profiles = _one(ab, {name: src})
    with pytest.raises(ab.InstallerError, match=problem):
        ab.validate_profiles(profiles)


def test_env_must_be_a_mapping(ab):
    _, _, profiles = _one(ab, ["MODEL=x"])
    with pytest.raises(ab.InstallerError, match="env must be a mapping"):
        ab.validate_profiles(profiles)


# --- resolution ------------------------------------------------------------------

def test_literals_secrets_and_defaults_resolve(ab, tmp_path):
    _, sb, profiles = _one(ab, {
        "HF_HUB_OFFLINE": {"value": "1"},
        "MODEL": {"secret": "inference", "secretKey": "model"},
        "PROJECT": {"secret": "inference", "secretKey": "project", "default": "demo"},
    })
    ab.validate_profiles(profiles)
    _secret(tmp_path, "inference", api_key="k", model="llama3\n")
    ab.resolve_credentials(profiles, tmp_path)
    assert sb.env_values == {"HF_HUB_OFFLINE": "1", "MODEL": "llama3", "PROJECT": "demo"}


def test_a_missing_value_without_default_names_the_secret_not_a_value(ab, tmp_path):
    _, _, profiles = _one(ab, {"MODEL": {"secret": "inference", "secretKey": "model"}})
    _secret(tmp_path, "inference", api_key="k")
    with pytest.raises(ab.InstallerError, match="Secret 'inference' key 'model'"):
        ab.resolve_credentials(profiles, tmp_path)


def test_a_base_url_in_env_is_checked_without_echoing_it(ab, tmp_path):
    _, _, profiles = _one(ab, {"OPENAI_BASE_URL": {"secret": "inference", "secretKey": "url"}})
    _secret(tmp_path, "inference", api_key="k", url="http://localhost:8000/v1")
    with pytest.raises(ab.InstallerError) as err:
        ab.resolve_credentials(profiles, tmp_path)
    assert "base URL" in str(err.value) and "localhost:8000" not in str(err.value)


# --- create and exec -------------------------------------------------------------

def test_the_env_reaches_create_and_every_exec(ab, fake_env, config, tmp_path):
    _, _, profiles = _one(ab, {"MODEL": {"value": "llama3"}, "HF_HUB_OFFLINE": {"value": "1"}})
    _secret(tmp_path, "inference", api_key="k")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    assert fake_env.openshell_state()["sandboxes"]["default/chat"]["env"] == [
        "HF_HUB_OFFLINE=1", "MODEL=llama3"]
    execs = [c for c in fake_env.openshell_calls() if c[:2] == ["sandbox", "exec"]]
    assert execs
    for call in execs:
        head = call[:call.index("--")]            # the flags, not the command
        assert [head[i + 1] for i, part in enumerate(head) if part == "--env"] == [
            "HF_HUB_OFFLINE=1", "MODEL=llama3"]
    # No provider --config any more.
    assert "config" not in fake_env.openshell_state()["providers"]["default/inference"]


def test_a_sandbox_without_env_gets_no_env_flags(ab, fake_env, config, tmp_path):
    _, _, profiles = _one(ab, {})
    _secret(tmp_path, "inference", api_key="k")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    assert not any("--env" in c for c in fake_env.openshell_calls())
    assert "env" not in fake_env.openshell_state()["sandboxes"]["default/chat"]


def test_env_may_not_shadow_an_attached_providers_credential(ab, fake_env, config, tmp_path):
    github = ab.Provider(name="gh", type="github", credential_secret="gh",
                         credential_secret_key="token")
    _, sb, profiles = _one(ab, {"GH_TOKEN": {"value": "plain"}}, provider=github,
                           sandbox_type="generic")
    _secret(tmp_path, "gh", token="ghp-x")
    creds = ab.resolve_credentials(profiles, tmp_path)
    applier = ab.ProfileApplier(ab.Shell(), config, creds,
                                provider_profile_docs={"github": GH_PROFILE})
    with pytest.raises(ab.InstallerError, match="credential variable of provider 'gh'"):
        applier.apply(profiles)
    assert "default/chat" not in fake_env.openshell_state()["sandboxes"]


# --- model and endpoint ------------------------------------------------------------

@pytest.mark.parametrize("sandbox_type,env,model,expected", [
    ("openclaw", {"OPENCLAW_MODEL": "a", "MODEL": "b"}, "c", "a"),
    ("openclaw", {"NEMOCLAW_MODEL": "x", "MODEL": "b"}, "c", "b"),   # not this agent's
    ("nemoclaw", {"NEMOCLAW_MODEL": "n", "MODEL": "b"}, "c", "n"),
    ("openclaw", {}, "c", "c"),
    ("openclaw", {}, "", "provider-model"),
])
def test_model_precedence(ab, sandbox_type, env, model, expected):
    provider, sb, _ = _one(ab, {}, sandbox_type=sandbox_type, model=model)
    sb.env_values = env
    assert ab.sandbox_model(sb, provider, "builtin") == expected


def test_the_model_reaches_nemoclaw(ab, fake_env, config, tmp_path):
    nvidia = ab.Provider(name="nvidia", type="nvidia", nemoclaw_provider="build",
                         credential_secret="inference", credential_secret_key="api_key")
    _, _, profiles = _one(ab, {"MODEL": {"value": "nvidia/m"}}, provider=nvidia,
                          sandbox_type="nemoclaw")
    _secret(tmp_path, "inference", api_key="nvapi-x")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    calls = fake_env.other_calls("nemoclaw")
    assert calls and calls[0]["model"] == "nvidia/m"


def test_an_env_base_url_onboards_on_that_endpoint(ab, fake_env, config, tmp_path):
    _, _, profiles = _one(ab, {"OPENAI_BASE_URL": {"value": "http://ollama.models.svc:11434/v1"},
                               "MODEL": {"value": "llama3"}})
    _secret(tmp_path, "inference", api_key="k")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    onboard = next(c[-1] for c in fake_env.openshell_calls()
                   if c[:2] == ["sandbox", "exec"] and "openclaw onboard " in c[-1])
    assert "--auth-choice custom-api-key " in onboard
    assert "--custom-base-url http://ollama.models.svc:11434/v1 " in onboard
    assert "--custom-model-id llama3 " in onboard


def test_without_an_env_base_url_official_apis_onboard_natively(ab, fake_env, config, tmp_path):
    _, _, profiles = _one(ab, {"MODEL": {"value": "gpt-4o"}})
    _secret(tmp_path, "inference", api_key="k")
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    onboard = next(c[-1] for c in fake_env.openshell_calls()
                   if c[:2] == ["sandbox", "exec"] and "openclaw onboard " in c[-1])
    assert "--auth-choice openai-api-key" in onboard


# --- the agent gateway restarts when the env changes --------------------------------

def test_the_env_is_part_of_the_gateway_fingerprint(ab, config):
    def script(env):
        return ab.openclaw_gateway_script(config, "default", "chat", "",
                                          env_digest=ab.env_digest(env))
    base, one, two = script({}), script({"MODEL": "llama-a"}), script({"MODEL": "llama-b"})
    assert "# sandbox env" not in base and "# sandbox env" in one
    assert len({base, one, two}) == 3              # a changed env restarts the gateway
    assert "llama-a" not in one                    # a digest, not the values
