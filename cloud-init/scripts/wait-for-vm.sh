#!/usr/bin/env bash
# Wait for a KubeVirt VMI to reach Running phase and SSH to become available.
# Usage: wait-for-vm.sh <vm-name> <namespace> [ssh-user] [ssh-key]
set -euo pipefail

VM="${1:?Usage: wait-for-vm.sh <vm-name> <namespace>}"
NS="${2:?Usage: wait-for-vm.sh <vm-name> <namespace>}"
SSH_USER="${3:-openshell}"
SSH_KEY="${4:-${HOME}/.ssh/id_ed25519}"

# Phase 1: wait for VMI Running
echo "Waiting for VM ${VM} to be running in namespace ${NS}..."
while true; do
  phase=$(kubectl get vmi -n "${NS}" "${VM}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "${phase}" == "Running" ]] && break
  echo "  ${VM}: ${phase}"
  sleep 5
done
echo "  ${VM}: Running"

# Phase 2: wait for SSH
echo "Waiting for SSH on ${VM}..."
while true; do
  if virtctl -n "${NS}" ssh "${SSH_USER}@vm/${VM}" \
      --identity-file="${SSH_KEY}" \
      --local-ssh-opts="-oStrictHostKeyChecking=no" \
      --local-ssh-opts="-oUserKnownHostsFile=/dev/null" \
      --local-ssh-opts="-oConnectTimeout=5" \
      --command="true" 2>/dev/null; then
    break
  fi
  echo "  ${VM}: SSH not ready yet..."
  sleep 10
done
echo "  ${VM}: SSH ready"
