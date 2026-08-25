#!/usr/bin/env bash
# Create a VM from the platform-specific CRD.
# Usage: create-vm.sh <platform> <role> [namespace]
#   platform: cirrus | openshift-cnv
#   role: agent | integration | infrastructure
set -euo pipefail

PLATFORM="${1:?Usage: create-vm.sh <platform> <role> [namespace]}"
ROLE="${2:?Usage: create-vm.sh <platform> <role> [namespace]}"
NS="${3:-${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}}"
BRANCH="${BRANCH:-main}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
CONTAINER_DISK_IMAGE="${CONTAINER_DISK_IMAGE:-registry.cirrus.ibm.com/mici-golden-images/cirrus-rhel-9-golden-image:latest}"
GOLDEN_IMAGE_PVC="${GOLDEN_IMAGE_PVC:-openshell-gateway-podman-golden}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBE_DIR="${SCRIPT_DIR}/../kubernetes/${PLATFORM}"

case "${ROLE}" in
  agent)          FILE="${KUBE_DIR}/agent-server.yml" ;;
  integration)    FILE="${KUBE_DIR}/integration-server.yml" ;;
  infrastructure) FILE="${KUBE_DIR}/infrastructure-server.yml" ;;
  *) echo "Error: role must be agent, integration, or infrastructure" >&2; exit 1 ;;
esac

# OpenShift CNV uses different file names
if [ "${PLATFORM}" = "openshift-cnv" ]; then
  case "${ROLE}" in
    agent)          FILE="${KUBE_DIR}/agent-vm.yml" ;;
    integration)    FILE="${KUBE_DIR}/integration-vm.yml" ;;
    infrastructure) FILE="${KUBE_DIR}/infrastructure-vm.yml" ;;
  esac
fi

if [ ! -f "${FILE}" ]; then
  echo "Error: ${FILE} not found. Check platform '${PLATFORM}'." >&2
  exit 1
fi

echo "Creating saw-${ROLE} in ${NS} (${PLATFORM})..."
sed -e "s|\${NS}|${NS}|g" \
    -e "s|\${BRANCH}|${BRANCH}|g" \
    -e "s|\${CONTAINER_DISK_IMAGE}|${CONTAINER_DISK_IMAGE}|g" \
    -e "s|\${SSH_PUBKEY}|${SSH_PUBKEY}|g" \
    -e "s|\${GOLDEN_IMAGE_PVC}|${GOLDEN_IMAGE_PVC}|g" \
  "${FILE}" | oc apply -n "${NS}" -f -

echo "saw-${ROLE} created in ${NS}"
