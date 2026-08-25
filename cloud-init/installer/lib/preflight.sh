#!/usr/bin/env bash
# Phase: Preflight — validate OS, architecture, runtime, user.

log_phase "Preflight"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would check: OS=${BOM_OS}, arch=${BOM_ARCH}, runtime=${BOM_RUNTIME}, user=${BOM_USER}"
  report_add "preflight: dry-run skipped"
  return 0
fi

# Check OS
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  log "OS: ${NAME} ${VERSION_ID} (expected: ${BOM_OS})"
else
  warn "Cannot determine OS — /etc/os-release not found"
fi

# Check architecture
ACTUAL_ARCH="$(uname -m)"
case "${BOM_ARCH}" in
  amd64|x86_64) EXPECTED_ARCH="x86_64" ;;
  arm64|aarch64) EXPECTED_ARCH="aarch64" ;;
  *) EXPECTED_ARCH="${BOM_ARCH}" ;;
esac
if [[ "${ACTUAL_ARCH}" != "${EXPECTED_ARCH}" ]]; then
  die "Architecture mismatch: expected ${EXPECTED_ARCH}, got ${ACTUAL_ARCH}"
fi
log "Architecture: ${ACTUAL_ARCH}"

# Check user exists
if ! id "${BOM_USER}" &>/dev/null; then
  die "User '${BOM_USER}' does not exist"
fi
log "User: ${BOM_USER}"

# Install required packages
if [[ -n "${BOM_PACKAGES}" ]]; then
  log "Installing packages: ${BOM_PACKAGES}"
  sudo dnf install -y --setopt=install_weak_deps=False ${BOM_PACKAGES} 2>&1 | tail -5
fi

# Enable services
for svc in ${BOM_SERVICES_ENABLE}; do
  log "Enabling service: ${svc}"
  sudo systemctl enable --now "${svc}" 2>/dev/null || warn "Failed to enable ${svc}"
done

# Check runtime
if ! command -v "${BOM_RUNTIME}" &>/dev/null; then
  die "Runtime '${BOM_RUNTIME}' not found after package install"
fi
log "Runtime: ${BOM_RUNTIME} ($(${BOM_RUNTIME} --version 2>/dev/null | head -1))"

# Ensure subuid/subgid for podman rootless
if [[ "${BOM_RUNTIME}" == "podman" ]]; then
  if ! grep -q "^${BOM_USER}:" /etc/subuid 2>/dev/null; then
    log "Adding subuid/subgid for ${BOM_USER}"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${BOM_USER}" 2>/dev/null || true
  fi
fi

report_add "preflight: OK (${BOM_OS}/${ACTUAL_ARCH}/${BOM_RUNTIME})"
log "Preflight passed"
