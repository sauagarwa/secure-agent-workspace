# Versioned BOM installer (Stage 1)

The gateway VM installs itself from a versioned Bill of Materials. The old
setup Job, which logged in to the VM over SSH and ran scripts, is gone.

## What runs where

```text
helm / Argo ──► openshell-saw chart
                 ├─ VirtualMachine (+ root disk clone)
                 ├─ <vm>-installer ConfigMap ─┐  installer-bom.yaml, config.json,
                 │                            │  apply_bom.py, setup-dashboard.sh
                 ├─ saw-bom-profiles ConfigMap ┤  (saw-bom chart: SAW-BOM profiles)
                 ├─ provider Secrets ─────────┤  inference, web-search, ...
                 ├─ <vm>-cloudinit Secret     │  attached as read-only disks
                 └─ <vm>-prepare Job          │  (cluster-side only, never touches the VM)
                                              ▼
VM boot ─► cloud-init ─► saw-install.service ─► saw-apply.service
                          apply_bom.py install    apply_bom.py apply
                          (root)                  (root → runs profiles as cloud-user)
```

- **saw-install** pulls each BOM component image by digest with podman,
  copies the binary out, checks `--version` against the BOM, installs it
  atomically into `/usr/local/bin`, re-syncs `gateway.env`, `gateway.toml`
  and the route-SAN drop-in from the installer disk, then starts the
  user-level `openshell-gateway.service` (restarting it if a binary or the
  config changed; an owed restart survives a failed attempt). Unchanged
  components are skipped, so reboots pull nothing.
- **saw-apply** runs only after `install` finished for the same BOM. It reads
  the profiles and mounted Secrets, then runs the profile step as
  `cloud-user` with the plan on stdin. Provider keys are passed to the CLI
  as `--credential NAME` with the value in the environment, never in argv;
  existing providers get the current key via `provider update`. It registers a local **mTLS**
  gateway entry, creates workspaces, providers, inference routes and
  sandboxes, optionally starts the dashboard, and verifies the result.
- The prepare Job only bootstraps the golden image DataSource and registers
  the dashboard redirect URI in Keycloak (admin API). It has no VM access.

cloud-init runs once per VM, so it only writes static files (mount script,
units) and first-boot copies of the gateway config. Everything that can
change after install (BOM, gateway config, Secret list, route host) is on
the installer disk and is re-read on every boot.

Both steps also run on every boot. Status is in `/var/lib/saw/status.json`
(one section per step), and `/var/lib/saw/ready` exists only when both
steps succeeded for the same BOM. Logs go to the serial console:

```bash
oc logs -f -l vm.kubevirt.io/name=<vm> -c guest-console-log --tail=-1
# or: make openshell-saw-logs OPENSHELL_SAW_NAME=<vm>
```

## Authentication

| Who | How | Role |
| --- | --- | --- |
| In-VM installer (`apply_bom.py`) | local mTLS client certificate, gateway entry `openshell` | must act as platform admin (`openshell-admin`) |
| Users (laptop CLI, dashboard) | their own OIDC token from Keycloak | from `realm_access.roles`: `openshell-admin` / `openshell-user` |

The installer never logs in to Keycloak and never configures the CLI for
OAuth. Set `accessControl.ownerSubject` (the owner's `openshell whoami`
subject) to make the owner admin of every workspace the installer creates.

To use the gateway from a laptop, register the gateway Route with OIDC in
your local OpenShell CLI and log in with your Keycloak account. You need the
gateway CA (`scripts/extract-gateway-ca.sh`); the Route hostname is added to
the gateway certificate by cloud-init.

> **Verify on a cluster:** OpenShell's docs don't state which role an mTLS
> caller gets when OIDC is also enabled. The installer checks this up front
> and fails with "check the mTLS identity has the openshell-admin role" if
> workspace creation is refused.

## Upgrading

1. Change `bom:` in the chart values (versions + digests; tags are refused
   at render time and by the installer).
2. Sync/upgrade the chart. The VM template changes, so KubeVirt marks the VM
   `RestartRequired`.
3. `virtctl restart <vm>` (or `make openshell-saw-restart`). On boot,
   `saw-install` installs only the changed components.

Profile or Secret changes are applied the same way (restart).

## Testing

```bash
make test-installer        # installer + chart tests; chart tests need helm
```

- `tests/installer`: the real `apply_bom.py` against fake `podman`,
  `openshell`, `nemoclaw` and `sudo` executables: BOM validation, component
  install/skip/upgrade/rollback-on-failure, profile apply and idempotency,
  mTLS-only access, credential masking, status/ready handling, dry-run.
- `tests/charts`: renders both charts, checks VM disks ↔ mount script ↔
  Secrets, systemd units, gateway TOML (parsed), render-time guards, and
  runs the shipped installer's `validate` against the rendered ConfigMaps.

## Not in Stage 1

- Signing of images or installer bundles (digest pinning only).
- Live updates without a VM restart (ConfigMap/Secret disks are read at boot).
- Removing workspaces/providers/sandboxes that were dropped from a profile.
- Reporting status to the cluster beyond the optional readiness probe
  (`vm.readinessProbe: true`, needs guest-agent exec).
- Docker as the VM container runtime.
- Migrating VMs created by the old SSH-based chart in place: cloud-init has
  already run on them, so the installer units are never written. Recreate
  the VM (delete the VM and its `-root` DataVolume) after upgrading the chart.
