#!/usr/bin/env bash
# Import base VM image as a golden DataVolume for cloning.
# Usage: import-base-image.sh [namespace]
set -euo pipefail

NS="${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2}"
GOLDEN_DV_NAME="${GOLDEN_DV_NAME:-saw-base-golden}"
GOLDEN_DISK_SIZE="${GOLDEN_DISK_SIZE:-10Gi}"

if oc get datavolume "${GOLDEN_DV_NAME}" -n "${NS}" >/dev/null 2>&1; then
  phase="$(oc get datavolume "${GOLDEN_DV_NAME}" -n "${NS}" -o jsonpath='{.status.phase}')"
  echo "Golden DataVolume '${GOLDEN_DV_NAME}' already exists (phase: ${phase})"
  exit 0
fi

echo "Importing base image into golden DataVolume '${GOLDEN_DV_NAME}'..."
echo "  URL: ${BASE_IMAGE_URL}"
echo "  Namespace: ${NS}"

oc apply -n "${NS}" -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${GOLDEN_DV_NAME}
  labels:
    app.kubernetes.io/name: secure-agent-workspace
    app.kubernetes.io/component: base-image
spec:
  source:
    http:
      url: "${BASE_IMAGE_URL}"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${GOLDEN_DISK_SIZE}
EOF

echo "Waiting for import to complete..."
oc wait datavolume "${GOLDEN_DV_NAME}" -n "${NS}" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m

echo "Golden image '${GOLDEN_DV_NAME}' ready."
