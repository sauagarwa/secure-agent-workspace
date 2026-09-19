#!/bin/bash
# Runs only in a fresh Fedora cloud disk, offline through virt-customize.
set -euo pipefail
tar --extract --gzip --file=/opt/guest.tar.gz --directory=/ --no-same-owner
install -m 0755 /opt/payload/openshell /usr/local/bin/openshell
install -m 0755 /opt/payload/openshell-gateway /usr/local/bin/openshell-gateway
install -m 0755 /opt/payload/openshell-supervisor /usr/local/bin/openshell-supervisor
if ! id cloud-user >/dev/null 2>&1; then
    useradd --create-home --uid 1000 --user-group cloud-user
fi
usermod --groups '' --lock cloud-user
install -d -m 0755 /var/lib/saw /etc/saw
install -d -m 0700 /var/lib/saw/reconciler
install -d -m 0755 /var/lib/systemd/linger
touch /var/lib/systemd/linger/cloud-user
# Only the enrolled guest starts the gateway; no rootful Podman socket at boot.
systemctl disable podman.socket podman.service || true
systemctl enable qemu-guest-agent.service saw-guest.service
python3 - <<'PY'
import sys
import hashlib
import json
from pathlib import Path
import yaml
sys.path[:0] = ['/opt/saw/guest', '/opt/saw/installer']
from apply_bom import GUEST_VENDOR_DROPIN, load_installer_bom, trusted_guest_path, verify_installed_software
verify_installed_software(load_installer_bom('/opt/saw/installer/installer-bom.yaml'))
# Attest the one reviewed Fedora service-wide default, not arbitrary overrides.
manifest_path = Path('/opt/saw/installer/build.json')
manifest = json.loads(manifest_path.read_text())
manifest['gatewayDropIns'] = {}
if GUEST_VENDOR_DROPIN.exists():
    trusted_guest_path(GUEST_VENDOR_DROPIN)
    lines = [line.strip() for line in GUEST_VENDOR_DROPIN.read_text().splitlines()
             if line.strip() and not line.lstrip().startswith(('#', ';'))]
    assert lines == ['[Service]', 'TimeoutStopFailureMode=abort'], 'Unreviewed vendor drop-in'
    manifest['gatewayDropIns'][str(GUEST_VENDOR_DROPIN)] = hashlib.sha256(GUEST_VENDOR_DROPIN.read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
# Cloud-init must not turn the gateway runtime identity into a sudo administrator.
config = {'system_info': {'default_user': {'name': 'cloud-user', 'lock_passwd': True,
                                         'groups': [], 'sudo': [], 'shell': '/bin/bash'}}}
Path('/etc/cloud/cloud.cfg.d/99-saw-runtime-user.cfg').write_text(yaml.safe_dump(config))
for source in ('/etc/subuid', '/etc/subgid'):
    entries = [r.split(':') for r in Path(source).read_text().splitlines()]
    assert any(len(r) == 3 and r[0] == 'cloud-user' and int(r[2]) >= 65536 for r in entries)
assert not Path('/etc/saw/guest.json').exists()
assert not Path('/var/lib/saw/gateway').exists()
assert not Path('/var/lib/saw/openshell-client').exists()
PY
cloud-init clean --logs --seed --machine-id
# virt-customize is not booted under systemd. cloud-init may therefore remove
# machine-id instead of leaving a systemd first-boot sentinel. Keep an empty
# mount point: systemd must be able to bind its fresh ID before / is remounted RW.
install -m 0444 /dev/null /etc/machine-id
# Remove only fresh-image build inputs and generated SSH host identities.
rm -f /opt/guest.tar.gz /opt/payload/openshell /opt/payload/openshell-gateway /opt/payload/openshell-supervisor
rmdir /opt/payload
find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*' -delete
find /var/log -type f -exec truncate -s 0 {} +
