#!/usr/bin/env bash
# SAW BOM Installer — manifest-driven VM configuration.
#
# Usage:
#   install-bom.sh --manifest /opt/saw-installer/manifest.yaml
#   install-bom.sh --manifest /opt/saw-installer/manifest.yaml --dry-run
#   install-bom.sh --manifest /opt/saw-installer/manifest.yaml --state-dir /var/lib/saw-bom
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST=""
STATE_DIR="/var/lib/saw-bom"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --state-dir)  STATE_DIR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: install-bom.sh --manifest <path> [--state-dir <dir>] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${MANIFEST}" ]] && MANIFEST="${INSTALLER_DIR}/manifest.yaml"
[[ ! -f "${MANIFEST}" ]] && { echo "ERROR: manifest not found: ${MANIFEST}" >&2; exit 1; }

source "${INSTALLER_DIR}/lib/common.sh"

# Parse manifest → env vars
eval "$(python3 "${INSTALLER_DIR}/lib/parse_manifest.py" "${MANIFEST}")"

# Auto-detect the target user if not set in manifest
if [[ -z "${BOM_USER}" ]]; then
  BOM_USER="$(getent passwd | awk -F: '$3>=1000 && $3<65534{print $1;exit}')"
  log "Auto-detected user: ${BOM_USER}"
fi
export BOM_USER

# Load credentials from KubeVirt secret disk (mounted by cloud-init)
CREDS_ENV="/etc/saw/credentials.env"
if [[ -f "${CREDS_ENV}" ]]; then
  log "Loading credentials from ${CREDS_ENV}"
  set -a
  source "${CREDS_ENV}"
  set +a
fi

# Idempotency: skip if manifest hash unchanged
sudo mkdir -p "${STATE_DIR}" 2>/dev/null || mkdir -p "${STATE_DIR}"
MANIFEST_HASH="$(sha256sum "${MANIFEST}" | cut -d' ' -f1)"
if [[ -f "${STATE_DIR}/last-applied-sha" ]]; then
  LAST_HASH="$(cat "${STATE_DIR}/last-applied-sha")"
  if [[ "${MANIFEST_HASH}" == "${LAST_HASH}" && "${DRY_RUN}" != "true" ]]; then
    log "Manifest unchanged (${MANIFEST_HASH:0:12}...) — no-op"
    exit 0
  fi
fi

log "=== SAW BOM Installer v${INSTALLER_VERSION} ==="
log "Manifest: ${BOM_NAME} ${BOM_VERSION}"
log "Role:     ${BOM_ROLE}"
log "Platform: ${BOM_OS}/${BOM_ARCH}/${BOM_RUNTIME}"
log "Hash:     ${MANIFEST_HASH:0:12}..."
[[ "${DRY_RUN}" == "true" ]] && log "Mode:     DRY RUN"

# Run base phases
source "${INSTALLER_DIR}/lib/preflight.sh"
source "${INSTALLER_DIR}/lib/fetch_verify.sh"
source "${INSTALLER_DIR}/lib/install_components.sh"
source "${INSTALLER_DIR}/lib/configure_gateway.sh"

# Run role-specific bootstrap
BOOTSTRAP="${INSTALLER_DIR}/lib/bootstrap_${BOM_ROLE}.sh"
if [[ -f "${BOOTSTRAP}" ]]; then
  source "${BOOTSTRAP}"
else
  log "No role-specific bootstrap for '${BOM_ROLE}'"
fi

# Verify
source "${INSTALLER_DIR}/lib/verify.sh"

# Record applied hash
echo "${MANIFEST_HASH}" | sudo tee "${STATE_DIR}/last-applied-sha" >/dev/null 2>/dev/null || \
  echo "${MANIFEST_HASH}" > "${STATE_DIR}/last-applied-sha"

log "=== Installation complete (${BOM_NAME} ${BOM_VERSION}) ==="
