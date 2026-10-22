"""Generic provider `config:` map — arbitrary `provider create --config KEY=VALUE`
passthrough so a new provider knob needs no installer change.

A literal value is used as given; a `secretKey` is read from the provider's
Secret at /run/saw/secrets/<credentialSecret>/<key>. Secret material still
belongs on the credential (env-var) path, not here: config values go into argv.
"""
import pytest


def _single_provider(ab, **provider_kwargs):
    provider = ab.Provider(name="inference", type="openai", model="m",
                           credential_secret="inference", credential_secret_key="api_key",
                           **provider_kwargs)
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    return provider, [ab.Profile(name="test", workspaces=[workspace])]


def test_generic_config_reaches_provider_create(ab, fake_env, config, tmp_path):
    provider, profiles = _single_provider(ab, config={
        "OPENAI_ORG": {"value": "acme"},            # literal
        "OPENAI_PROJECT": {"secretKey": "project"},  # from the Secret
    })
    base = tmp_path / "inference"
    base.mkdir()
    (base / "api_key").write_text("sk-test")
    (base / "project").write_text("proj-123")

    creds = ab.resolve_credentials(profiles, tmp_path)
    # Resolved to KEY->value, literal and secret-backed alike.
    assert provider.config_values == {"OPENAI_ORG": "acme", "OPENAI_PROJECT": "proj-123"}

    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    emitted = fake_env.openshell_state()["providers"]["default/inference"]["config"]
    assert "OPENAI_ORG=acme" in emitted
    assert "OPENAI_PROJECT=proj-123" in emitted


def test_generic_config_coexists_with_base_url(ab, fake_env, config, tmp_path):
    provider, profiles = _single_provider(
        ab, base_url="https://api.openai.com/v1",
        config={"OPENAI_ORG": {"value": "acme"}})
    base = tmp_path / "inference"
    base.mkdir()
    (base / "api_key").write_text("sk-test")

    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    emitted = fake_env.openshell_state()["providers"]["default/inference"]["config"]
    # The hardcoded base-URL mapping and the generic entry both make it through.
    assert "OPENAI_BASE_URL=https://api.openai.com/v1" in emitted
    assert "OPENAI_ORG=acme" in emitted


def test_bad_config_shape_is_rejected(ab):
    _, profiles = _single_provider(ab, config={"OPENAI_ORG": {"value": "a", "secretKey": "b"}})
    with pytest.raises(ab.InstallerError, match="exactly one of value or secretKey"):
        ab.validate_profiles(profiles)


def test_secret_key_config_needs_a_credential_secret(ab):
    provider = ab.Provider(name="p", type="openai", credential_free=True,
                           config={"X": {"secretKey": "y"}})
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    with pytest.raises(ab.InstallerError, match="no credentialSecret"):
        ab.validate_profiles([ab.Profile(name="test", workspaces=[workspace])])


def test_shell_unsafe_config_value_is_rejected(ab):
    _, profiles = _single_provider(ab, config={"OPENAI_ORG": {"value": "a;rm -rf /"}})
    with pytest.raises(ab.InstallerError, match="shell-unsafe"):
        ab.validate_profiles(profiles)
