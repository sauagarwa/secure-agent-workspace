#!/usr/bin/env bash
# Push local secrets to K8s Secrets in the target namespace.
# Requires: oc logged in, local secrets generated.
set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.secrets}"
NS="${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}"

for name in inter-vm-bearer gmail-write-frontdoor m365-write-frontdoor slack-write-frontdoor; do
  if [ ! -f "${SECRETS_DIR}/${name}" ]; then
    echo "Error: ${SECRETS_DIR}/${name} not found. Run generate-secrets.sh first." >&2
    exit 1
  fi
done

echo "Pushing secrets to namespace ${NS}..."

# Inter-VM bearer (includes SHA256)
BEARER="$(cat "${SECRETS_DIR}/inter-vm-bearer")"
BEARER_SHA="$(echo -n "${BEARER}" | sha256sum | cut -d ' ' -f 1)"
oc create secret generic inter-vm-bearer -n "${NS}" \
  --from-literal=bearer="${BEARER}" \
  --from-literal=sha256="${BEARER_SHA}" \
  --dry-run=client -o yaml | oc apply -f -
echo "  inter-vm-bearer"

# Front-door bearer secrets
for name in gmail-write-frontdoor m365-write-frontdoor slack-write-frontdoor; do
  oc create secret generic "${name}" -n "${NS}" \
    --from-file=bearer="${SECRETS_DIR}/${name}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ${name}"
done

echo "K8s Secrets created in ${NS}"
