#!/usr/bin/env bash
# Delete a VM.
# Usage: delete-vm.sh <role> [namespace]
set -euo pipefail

ROLE="${1:?Usage: delete-vm.sh <role> [namespace]}"
NS="${2:-${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}}"

echo "Deleting saw-${ROLE} from ${NS}..."
kubectl delete vm "saw-${ROLE}" -n "${NS}" --ignore-not-found 2>/dev/null || true
kubectl delete server "saw-${ROLE}" -n "${NS}" --ignore-not-found 2>/dev/null || true
echo "saw-${ROLE} deleted"
