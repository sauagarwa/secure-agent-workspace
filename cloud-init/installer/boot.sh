#!/bin/bash
# SAW cloud-init boot script — runs as root via runcmd.
# Mounts credentials, pulls installer image, starts BOM installer service.
# Logs to /var/log/saw-cloud-init.log
set -euo pipefail
LOG=/var/log/saw-cloud-init.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[saw-init] $(date '+%H:%M:%S') $*"; }

INSTALLER_IMAGE="${1:?Usage: boot.sh <installer-image>}"

log "=== SAW cloud-init starting ==="
log "Installer image: ${INSTALLER_IMAGE}"

# --- Step 1: Mount credentials secret disk ---
log "Step 1: Mounting credentials secret disk..."
mkdir -p /etc/saw/secrets
TRIES=0
while [ ! -b /dev/disk/by-id/virtio-SAWCREDS ] && [ $TRIES -lt 30 ]; do
  TRIES=$((TRIES + 1))
  log "  waiting for virtio-SAWCREDS device... ($TRIES/30)"
  sleep 1
done
if [ -b /dev/disk/by-id/virtio-SAWCREDS ]; then
  mount -o ro /dev/disk/by-id/virtio-SAWCREDS /etc/saw/secrets
  log "  mounted at /etc/saw/secrets ($(ls /etc/saw/secrets/ | tr '\n' ' '))"
else
  log "  ERROR: virtio-SAWCREDS device not found after 30s"
  exit 1
fi

# --- Step 2: Pull and extract installer image (if not already done by runcmd) ---
if [ ! -f /opt/saw-installer/install-bom.sh ]; then
  log "Step 2: Pulling installer image..."
  podman pull "${INSTALLER_IMAGE}"
  log "  pull complete"
  log "Step 3: Extracting installer to /opt/saw-installer/"
  CID=$(podman create "${INSTALLER_IMAGE}")
  podman cp "${CID}:/opt/saw-installer" /opt/saw-installer
  podman rm "${CID}"
  chmod +x /opt/saw-installer/install-bom.sh /opt/saw-installer/lib/*.sh
  log "  extracted $(find /opt/saw-installer -type f | wc -l) files"
else
  log "Step 2-3: Installer already extracted ($(find /opt/saw-installer -type f | wc -l) files)"
fi

# --- Step 4: Build credentials.env from mounted secret files ---
log "Step 4: Building /etc/saw/credentials.env"
: > /etc/saw/credentials.env
for f in /etc/saw/secrets/*; do
  [ -f "$f" ] || continue
  key=$(basename "$f" | tr '[:lower:]-' '[:upper:]_')
  echo "${key}=$(cat "$f")" >> /etc/saw/credentials.env
  log "  loaded: ${key}"
done
chmod 600 /etc/saw/credentials.env

# --- Step 5: Install and start BOM installer service ---
log "Step 5: Enabling saw-bom-install.service"
cp /opt/saw-installer/saw-bom-install.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now saw-bom-install.service
log "  service started"

log "=== SAW cloud-init complete ==="
log "Installer logs: sudo journalctl -u saw-bom-install.service"
log "This log: cat /var/log/saw-cloud-init.log"
