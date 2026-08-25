#!/usr/bin/env python3
"""Parse a SAW BOM manifest.yaml and output shell-sourceable env vars."""
import sys
import json
import yaml


def shell_escape(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v).replace("'", "'\\''")


def emit(key, value):
    print(f"{key}='{shell_escape(value)}'")


def emit_dict(prefix, d):
    for k, v in d.items():
        env_key = f"{prefix}_{k}".upper().replace("-", "_")
        emit(env_key, v)


def main():
    if len(sys.argv) < 2:
        print("Usage: parse_manifest.py <manifest.yaml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        manifest = yaml.safe_load(f)

    meta = manifest.get("metadata", {})
    spec = manifest.get("spec", {})

    emit("BOM_NAME", meta.get("name", ""))
    emit("BOM_VERSION", meta.get("version", ""))
    emit("BOM_ROLE", spec.get("role", "agent"))

    plat = spec.get("platform", {})
    emit("BOM_OS", plat.get("os", "fedora"))
    emit("BOM_ARCH", plat.get("arch", "amd64"))
    emit("BOM_RUNTIME", plat.get("runtime", "podman"))

    arts = spec.get("artifacts", {})

    os_art = arts.get("openshell", {})
    cli = os_art.get("cli", {}).get("source", {})
    emit("OPENSHELL_CLI_PACKAGE", cli.get("package", "openshell"))
    emit("OPENSHELL_CLI_VERSION", cli.get("version", ""))
    emit("OPENSHELL_CLI_EXTRA_INDEX_URL", cli.get("extraIndexUrl", ""))

    gw = os_art.get("gateway", {}).get("source", {})
    emit("OPENSHELL_GATEWAY_IMAGE", gw.get("image", ""))
    emit("OPENSHELL_GATEWAY_PATH_IN_IMAGE", gw.get("pathInImage", "/usr/local/bin/openshell-gateway"))

    sv = os_art.get("supervisor", {}).get("source", {})
    emit("OPENSHELL_SUPERVISOR_IMAGE", sv.get("image", ""))
    emit("OPENSHELL_SUPERVISOR_PATH_IN_IMAGE", sv.get("pathInImage", "/openshell-sandbox"))

    sys_conf = spec.get("system", {})
    emit("BOM_USER", sys_conf.get("user", ""))

    paths = sys_conf.get("installPaths", {})
    emit("BOM_GATEWAY_BIN", paths.get("gatewayBin", "/usr/local/bin/openshell-gateway"))
    emit("BOM_SUPERVISOR_BIN", paths.get("supervisorBin", "/usr/local/bin/openshell-supervisor"))

    pkgs = sys_conf.get("packages", {}).get("required", [])
    emit("BOM_PACKAGES", " ".join(pkgs))

    svcs_enable = sys_conf.get("services", {}).get("enable", [])
    emit("BOM_SERVICES_ENABLE", " ".join(svcs_enable))

    gw_env = sys_conf.get("gatewayEnv", {})
    emit_dict("BOM_GW_ENV", gw_env)

    boot = spec.get("bootstrap", {})
    gw_boot = boot.get("gateway", {})
    emit("BOM_GATEWAY_NAME", gw_boot.get("name", "openshell-local"))
    emit("BOM_GATEWAY_ENDPOINT", gw_boot.get("endpoint", "https://127.0.0.1:17670"))
    emit("BOM_GATEWAY_AUTH_MODE", gw_boot.get("authMode", "mtls"))
    emit("BOM_GATEWAY_EXTERNALLY_SUPERVISED", gw_boot.get("externallySupervised", True))

    profiles = boot.get("profiles", {})
    emit("BOM_PROFILES_SOURCE", profiles.get("source", ""))
    emit("BOM_PROFILES_ROLE", profiles.get("role", ""))

    inf_proxy = boot.get("inferenceProxy", {})
    emit("BOM_INFERENCE_PROXY_ENABLED", inf_proxy.get("enabled", False))
    emit("BOM_INFERENCE_PROXY_PORT", inf_proxy.get("port", 18083))

    sec = spec.get("security", {})
    emit("BOM_VERIFY_CHECKSUMS", sec.get("verifyChecksums", False))
    emit("BOM_DENY_LATEST_TAGS", sec.get("denyLatestTags", False))

    verify = spec.get("verify", {})
    emit("BOM_VERIFY_COMMANDS", json.dumps(verify.get("commands", [])))

    report = spec.get("report", {})
    emit("BOM_REPORT_JSON", report.get("writeJson", "/var/log/saw-bom-install-report.json"))
    emit("BOM_REPORT_TEXT", report.get("writeText", "/var/log/saw-bom-install-report.txt"))


if __name__ == "__main__":
    main()
