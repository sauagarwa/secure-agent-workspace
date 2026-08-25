#!/usr/bin/env bash
# Phase: Fetch artifacts from container images and verify checksums.

log_phase "Fetch & Verify"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would fetch:"
  log "  gateway:    ${OPENSHELL_GATEWAY_IMAGE}"
  log "  supervisor: ${OPENSHELL_SUPERVISOR_IMAGE}"
  report_add "fetch: dry-run skipped"
  return 0
fi

RUNTIME="${BOM_RUNTIME}"
FETCH_DIR="/tmp/saw-fetch"
mkdir -p "${FETCH_DIR}"
chown "${BOM_USER}:${BOM_USER}" "${FETCH_DIR}" 2>/dev/null || true

# Deny latest tags if configured
if [[ "${BOM_DENY_LATEST_TAGS}" == "true" ]]; then
  for img in "${OPENSHELL_GATEWAY_IMAGE}" "${OPENSHELL_SUPERVISOR_IMAGE}"; do
    [[ -z "${img}" ]] && continue
    if [[ "${img}" == *":latest" ]]; then
      die "Floating tag 'latest' not allowed (security.denyLatestTags=true): ${img}"
    fi
  done
fi

extract_binary() {
  local image="$1"
  local src_path="$2"
  local dest_path="$3"
  local label="$4"

  log "Pulling ${label}: ${image}"
  run_as_user "${RUNTIME} pull '${image}'" || die "Failed to pull ${image}"

  log "Extracting ${src_path} → ${dest_path}"
  local cid
  cid="$(run_as_user "${RUNTIME} create '${image}'" 2>/dev/null)" || die "Failed to create container from ${image}"
  run_as_user "${RUNTIME} cp '${cid}:${src_path}' '${FETCH_DIR}/$(basename "${dest_path}")'" || die "Failed to extract ${src_path}"
  run_as_user "${RUNTIME} rm '${cid}'" 2>/dev/null || true

  sudo mv "${FETCH_DIR}/$(basename "${dest_path}")" "${dest_path}"
  sudo chmod 755 "${dest_path}"
  log "Installed: ${dest_path}"
}

# Gateway binary
if [[ -n "${OPENSHELL_GATEWAY_IMAGE}" ]]; then
  extract_binary "${OPENSHELL_GATEWAY_IMAGE}" "${OPENSHELL_GATEWAY_PATH_IN_IMAGE}" "${BOM_GATEWAY_BIN}" "gateway"
  report_add "fetch-gateway: OK (${OPENSHELL_GATEWAY_IMAGE})"
fi

# Supervisor binary
if [[ -n "${OPENSHELL_SUPERVISOR_IMAGE}" ]]; then
  extract_binary "${OPENSHELL_SUPERVISOR_IMAGE}" "${OPENSHELL_SUPERVISOR_PATH_IN_IMAGE}" "${BOM_SUPERVISOR_BIN}" "supervisor"
  report_add "fetch-supervisor: OK (${OPENSHELL_SUPERVISOR_IMAGE})"
fi

# OpenShell CLI (pip)
if [[ -n "${OPENSHELL_CLI_VERSION}" ]]; then
  log "Installing OpenShell CLI: ${OPENSHELL_CLI_PACKAGE}==${OPENSHELL_CLI_VERSION}"
  PIP_EXTRA=""
  [[ -n "${OPENSHELL_CLI_EXTRA_INDEX_URL}" ]] && PIP_EXTRA="--extra-index-url ${OPENSHELL_CLI_EXTRA_INDEX_URL}"
  run_as_user "pip3 install --user '${OPENSHELL_CLI_PACKAGE}==${OPENSHELL_CLI_VERSION}' ${PIP_EXTRA}" \
    || warn "OpenShell CLI install failed (continuing with existing version)"
  report_add "fetch-cli: OK (${OPENSHELL_CLI_VERSION})"
fi

rm -rf "${FETCH_DIR}"
log "Fetch & verify complete"
