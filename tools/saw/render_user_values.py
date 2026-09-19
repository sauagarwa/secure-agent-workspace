#!/usr/bin/env python3
"""Combine one user enrollment with the platform's approved SAW defaults."""
import argparse
from pathlib import Path

import yaml


def load(path, parser):
    try:
        return yaml.safe_load(path.read_text()) or {}
    except OSError as exc:
        parser.error(f"cannot read {path}: {exc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-values", required=True, type=Path,
                        help="admin-owned sawPlatform values")
    parser.add_argument("--user-values", required=True, type=Path,
                        help="one user-owned sawUser enrollment")
    args = parser.parse_args()
    platform = load(args.platform_values, parser).get("sawPlatform", {})
    user = load(args.user_values, parser).get("sawUser", {})

    required_platform = (platform.get("platform"), platform.get("image"),
                         platform.get("installerRelease"))
    required_user = (user.get("name"), user.get("subject"))
    if not all(required_platform):
        parser.error(
            f"{args.platform_values} is an unconfigured sawPlatform template; "
            "set sawPlatform.platform (issuer and Vault connection), image "
            "(namespace, imported CDI DataSource, diskSizeGi), and installerRelease "
            "(the approved immutable InstallerBOM release) once before installing users"
        )
    if not all(required_user):
        parser.error("user values must define sawUser.name and immutable sawUser.subject")

    image = platform["image"]
    if not all(image.get(key) for key in ("namespace", "dataSource", "diskSizeGi")):
        parser.error("sawPlatform.image must define namespace, dataSource, and diskSizeGi")

    tenant = dict(user)
    tenant.setdefault("username", tenant["name"])
    tenant.setdefault("credentials", [])
    instance = tenant.pop("instance", {"workspaces": []})
    profile_config_maps = tenant.pop("profileConfigMaps", [])
    guest = tenant.pop("guest", {"enabled": True, "cores": 4, "memoryGi": 8, "runStrategy": "Halted"})
    print(yaml.safe_dump({"openshellSaw": {
        "platform": platform["platform"],
        "tenant": tenant,
        "image": image,
        "instance": instance,
        "profileConfigMaps": profile_config_maps,
        "installerRelease": platform["installerRelease"],
        "guest": guest,
    }}, sort_keys=False))


if __name__ == "__main__":
    main()
