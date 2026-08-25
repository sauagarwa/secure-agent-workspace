#!/usr/bin/env bash
# Shared functions for the SAW BOM installer.

INSTALLER_VERSION="0.1.0"

_REPORT_ENTRIES=()

log() {
  echo "[saw-installer] $(date '+%H:%M:%S') $*"
}

log_phase() {
  echo ""
  log "===== Phase: $1 ====="
}

die() {
  log "FATAL: $*"
  write_report "FAILED"
  exit 1
}

warn() {
  log "WARN: $*"
}

report_add() {
  _REPORT_ENTRIES+=("$1")
}

write_report() {
  local status="${1:-OK}"
  local report_json="${BOM_REPORT_JSON:-/var/log/saw-bom-install-report.json}"
  local report_text="${BOM_REPORT_TEXT:-/var/log/saw-bom-install-report.txt}"

  sudo mkdir -p "$(dirname "${report_json}")" "$(dirname "${report_text}")" 2>/dev/null || true

  {
    echo "SAW BOM Install Report"
    echo "======================"
    echo "Status:   ${status}"
    echo "Version:  ${BOM_VERSION:-unknown}"
    echo "Role:     ${BOM_ROLE:-unknown}"
    echo "Date:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    for entry in "${_REPORT_ENTRIES[@]}"; do
      echo "  ${entry}"
    done
  } | sudo tee "${report_text}" >/dev/null 2>/dev/null || true

  local entries_json="[]"
  for entry in "${_REPORT_ENTRIES[@]}"; do
    entries_json=$(echo "${entries_json}" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
arr.append('${entry}')
print(json.dumps(arr))
" 2>/dev/null || echo "[]")
  done

  python3 -c "
import json, sys
report = {
    'status': '${status}',
    'version': '${BOM_VERSION:-unknown}',
    'role': '${BOM_ROLE:-unknown}',
    'installerVersion': '${INSTALLER_VERSION}',
    'entries': ${entries_json}
}
json.dump(report, sys.stdout, indent=2)
" 2>/dev/null | sudo tee "${report_json}" >/dev/null 2>/dev/null || true
}

run_as_user() {
  local user="${BOM_USER:-openshell}"
  if [[ "$(whoami)" == "${user}" ]]; then
    eval "$@"
  else
    sudo -u "${user}" bash -lc "$*"
  fi
}
