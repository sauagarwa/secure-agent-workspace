#!/usr/bin/env bash
# Phase: Install — version-wrap openshell CLI so all components report matching versions.

log_phase "Install Components"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would install version wrapper for openshell CLI"
  report_add "install: dry-run skipped"
  return 0
fi

# The gateway binary's --version is the source of truth. Wrap the pip-installed
# openshell CLI so its --version output matches (PEP 440 '+' vs semver '-').
NATIVE_VERSION="$(${BOM_GATEWAY_BIN} --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\S*' | head -1 || true)"
if [[ -z "${NATIVE_VERSION}" ]]; then
  NATIVE_VERSION="$(echo "${OPENSHELL_CLI_VERSION}" | sed 's/+/-/')"
fi

OS_BIN="$(run_as_user "command -v openshell" 2>/dev/null || echo "/home/${BOM_USER}/.local/bin/openshell")"
OS_DIR="$(dirname "${OS_BIN}")"

if [[ -f "${OS_BIN}" && ! -f "${OS_DIR}/openshell-real" ]]; then
  log "Wrapping openshell CLI for version alignment (${NATIVE_VERSION})"
  run_as_user "mv '${OS_BIN}' '${OS_DIR}/openshell-real'"

  cat > /tmp/openshell-wrapper <<WEOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "openshell ${NATIVE_VERSION}"
  exit 0
fi
SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\${SELF_DIR}/openshell-real" "\$@"
WEOF
  chmod 755 /tmp/openshell-wrapper
  run_as_user "cp /tmp/openshell-wrapper '${OS_BIN}' && chmod 755 '${OS_BIN}'"
  rm -f /tmp/openshell-wrapper
fi

# Install lsof (needed by nemoclaw for gateway listener detection)
sudo dnf install -y lsof 2>&1 | tail -3 || warn "lsof install failed (non-fatal)"

# Log versions
log "Installed versions:"
run_as_user "openshell --version" 2>/dev/null || true
run_as_user "${BOM_GATEWAY_BIN} --version" 2>/dev/null || true
run_as_user "${BOM_SUPERVISOR_BIN} --version" 2>/dev/null || true

report_add "install: OK (versions aligned to ${NATIVE_VERSION})"
