#!/usr/bin/env bash
# Generate local secrets for provisioning.
# Idempotent — only creates secrets that don't exist yet.
set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.secrets}"

install -d -m 0700 "${SECRETS_DIR}"

for name in inter-vm-bearer gmail-write-frontdoor m365-write-frontdoor slack-write-frontdoor; do
  if [ ! -f "${SECRETS_DIR}/${name}" ]; then
    openssl rand -hex 32 > "${SECRETS_DIR}/${name}"
    chmod 600 "${SECRETS_DIR}/${name}"
    echo "Generated: ${name}"
  else
    echo "Exists:    ${name}"
  fi
done

echo "Secrets stored in ${SECRETS_DIR}/"
