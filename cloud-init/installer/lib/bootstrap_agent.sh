#!/usr/bin/env bash
# Phase: Bootstrap Agent — apply BOM profiles to create workspaces, providers, sandboxes.
# This phase is agent-role specific.

log_phase "Bootstrap Agent"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would apply BOM profiles from ${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
  report_add "bootstrap-agent: dry-run skipped"
  return 0
fi

PROFILES_DIR="${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
APPLY_BOM="${INSTALLER_DIR}/lib/apply_bom.py"

if [[ ! -d "${PROFILES_DIR}" ]]; then
  die "Profiles directory not found: ${PROFILES_DIR}"
fi

if [[ ! -f "${APPLY_BOM}" ]]; then
  die "apply_bom.py not found: ${APPLY_BOM}"
fi

# Credentials already loaded by install-bom.sh from /etc/saw/credentials.env
# Map secret disk keys to the env vars apply_bom.py expects
[[ -n "${INTER_VM_BEARER:-}" ]] && export PROV_GMAIL_READ_PROXY_KEY="${INTER_VM_BEARER}"

# Transfer profiles to user home for apply_bom.py
USER_HOME="$(eval echo ~"${BOM_USER}")"
BOM_DIR="${USER_HOME}/bom-profiles"
run_as_user "rm -rf '${BOM_DIR}' && mkdir -p '${BOM_DIR}'"

# Copy only the profile matching BOM_PROFILES_ROLE (not all profiles)
ROLE_DIR="${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
if [[ ! -d "${ROLE_DIR}" ]]; then
  die "Profile role directory not found: ${ROLE_DIR}"
fi
for ws_dir in "${ROLE_DIR}"/*/; do
  [[ ! -d "${ws_dir}" ]] && continue
  ws_name="$(basename "${ws_dir}")"
  run_as_user "mkdir -p '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}'"
  for file in "${ws_dir}"*; do
    [[ ! -f "${file}" ]] && continue
    fname="$(basename "${file}")"
    cp "${file}" "/tmp/bom-${fname}"
    run_as_user "cp '/tmp/bom-${fname}' '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}/${fname}'"
    rm -f "/tmp/bom-${fname}"
    [[ "${fname}" == *.sh ]] && run_as_user "chmod +x '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}/${fname}'"
  done
done

# Copy apply_bom.py
cp "${APPLY_BOM}" "/tmp/apply_bom.py"
run_as_user "cp /tmp/apply_bom.py '${USER_HOME}/apply_bom.py'"
rm -f /tmp/apply_bom.py

# Copy governance profiles if present
GOV_DIR="${INSTALLER_DIR}/governance-profiles"
GOV_VM_DIR="${USER_HOME}/governance-profiles"
if [[ -d "${GOV_DIR}" ]]; then
  run_as_user "mkdir -p '${GOV_VM_DIR}'"
  for file in "${GOV_DIR}"/*.yaml; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "/tmp/gov-$(basename "${file}")"
    run_as_user "cp '/tmp/gov-$(basename "${file}")' '${GOV_VM_DIR}/$(basename "${file}")'"
    rm -f "/tmp/gov-$(basename "${file}")"
  done
fi

# Build bom.env with resolved credentials
BOM_ENV="/tmp/bom.env"
: > "${BOM_ENV}"

# Forward credential env vars (PROV_*_KEY, INFERENCE_*, etc.)
env | grep -E '^(PROV_|INFERENCE_|NAMESPACE)' >> "${BOM_ENV}" 2>/dev/null || true

run_as_user "cp '${BOM_ENV}' '${USER_HOME}/bom.env'"
rm -f "${BOM_ENV}"

log "Running apply_bom.py..."
run_as_user "
  set -a; source '${USER_HOME}/bom.env' 2>/dev/null; set +a
  python3 '${USER_HOME}/apply_bom.py' \
    --profiles-dir '${BOM_DIR}' \
    --mtls-gateway '${BOM_GATEWAY_NAME}' \
    --governance-profiles-dir '${GOV_VM_DIR}'
" 2>&1

report_add "bootstrap-agent: OK (profiles=${BOM_PROFILES_SOURCE})"
log "Agent bootstrap complete"
