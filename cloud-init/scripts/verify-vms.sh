#!/usr/bin/env bash
# Verify all three VMs are running.
# Usage: verify-vms.sh [namespace]
set -euo pipefail

NS="${1:-${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}}"

echo "============================================================"
echo "Verifying SAW VMs in ${NS}"
echo "============================================================"

PASS=0
FAIL=0

for vm in saw-infrastructure saw-agent saw-integration; do
  phase="$(kubectl get vmi "${vm}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")"
  if [ "${phase}" = "Running" ]; then
    echo "  PASS  ${vm} is Running"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  ${vm} is ${phase}"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
test "${FAIL}" -eq 0
