#!/usr/bin/env bash
# Phase: Verify — run verification commands from manifest, write report.

log_phase "Verify"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would run verification commands"
  report_add "verify: dry-run skipped"
  return 0
fi

VERIFY_PASS=0
VERIFY_FAIL=0

commands="$(echo "${BOM_VERIFY_COMMANDS}" | python3 -c 'import sys, json; [print(c) for c in json.load(sys.stdin)]' 2>/dev/null || true)"

while IFS= read -r cmd; do
  [[ -z "${cmd}" ]] && continue
  log "  Check: ${cmd}"
  if run_as_user "${cmd}" &>/dev/null; then
    log "    PASS"
    report_add "verify: PASS — ${cmd}"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    warn "    FAIL"
    report_add "verify: FAIL — ${cmd}"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
done <<< "${commands}"

log "Verification: ${VERIFY_PASS} passed, ${VERIFY_FAIL} failed"

if [[ "${VERIFY_FAIL}" -gt 0 ]]; then
  warn "Some verification checks failed — review report"
fi

write_report "$([ "${VERIFY_FAIL}" -eq 0 ] && echo 'OK' || echo 'PARTIAL')"
