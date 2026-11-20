"""Provider helpers for configuring the agent.

OpenShell owns provider security: profiles decide which endpoints a credential
may reach, and the supervisor substitutes the real value only for those. This
module only tells the agent which environment variable holds its inference key
and checks the site's custom inference URL.
"""
import re
import ipaddress
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit

import yaml

from .core import shared

PROFILES = Path(shared.__file__).resolve().parents[1] / "provider-profiles"
INFERENCE = {"openai", "anthropic", "nvidia"}


@lru_cache(maxsize=4)
def _shipped(kind):
    return yaml.safe_load((PROFILES / (kind + ".yaml")).read_text())


def custom_host(url):
    """Custom inference must be an HTTPS v1 endpoint on port 443 with a DNS name."""
    if not isinstance(url, str) or shared.check_base_url(url) != url:
        raise ValueError("invalid custom inference base URL")
    parsed = urlsplit(url)
    hostname = parsed.hostname or ""
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        raise ValueError("custom inference requires a DNS hostname")
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if (parsed.scheme != "https" or parsed.port not in (None, 443)
            or len(hostname) > 253 or not re.fullmatch(rf"{label}(?:\.{label})+", hostname)
            or not re.fullmatch(r"(?:/[A-Za-z0-9_-]+)*/v1", parsed.path)):
        raise ValueError("custom inference requires an approved HTTPS v1 endpoint on port 443")
    return parsed.hostname


def inference_key_env(kind):
    """The env var the agent reads its inference key from (an OpenShell placeholder)."""
    if kind == "custom-inference":
        return "CUSTOM_INFERENCE_API_KEY"
    if kind not in INFERENCE:
        raise ValueError("not an inference provider")
    slot, = _shipped(kind)["credentials"]
    return slot["env_vars"][0]
