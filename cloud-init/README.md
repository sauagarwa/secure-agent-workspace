# SAW Cloud-Init Provisioning

Provisions the three-VM Secure Agent Workspace using cloud-init and a versioned BOM installer. Supports IBM Cirrus and OpenShift CNV (KubeVirt) platforms.

## Architecture

```
                          ┌─────────────────────────────────┐
                          │      Quay.io / Registry         │
                          │  saw-installer-base:v0.1.0      │
                          │  saw-installer-agent:v0.1.0     │
                          │  saw-installer-integration:v0.1.0│
                          └────────────┬────────────────────┘
                                       │ podman pull
          ┌────────────────────────────┼──────────────────────────┐
          ▼                            ▼                          ▼
┌──────────────────┐     ┌───────────────────────┐    ┌────────────────────────┐
│ saw-infrastructure│     │     saw-agent          │    │   saw-integration       │
│                  │     │                       │    │                        │
│  SSH key gen     │     │  OpenShell gateway    │    │  OpenShell gateway     │
│  Secret store    │     │  OpenClaw sandbox     │    │  gmail-read   :18080   │
│  Ansible coord   │     │  gog + forwarder      │    │  gmail-write  :18081   │
│                  │     │  Forge UI :18090      │    │  m365-read    :18082   │
│  No real keys    │     │  No real keys         │    │  inference    :18083   │
└──────────────────┘     └───────────────────────┘    │  slack-read   :18084   │
                                                      │  slack-write  :18085   │
                                                      │  m365-write   :18086   │
                                                      └────────────────────────┘
```

## How It Works

```
┌──────────────────────────────────────────────────────────────────────┐
│  make create-all PLATFORM=openshift-cnv INSTALLER_IMAGE=quay.io/…  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                        Ansible playbook
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
    K8s Secrets           VM CRDs             Wait for VMs
    ├ inter-vm-bearer     ├ agent-vm.yml
    ├ saw-agent-creds     ├ integration-vm.yml
    └ saw-integ-creds     └ infrastructure-vm.yml
                               │
                        ┌──────┴───────┐
                        ▼              ▼
                   Agent VM      Integration VM
                   ┌──────────────────────────────────┐
                   │  cloud-init runcmd:               │
                   │   1. Mount secret disk            │  ← K8s Secret as
                   │      /dev/disk/by-id/             │    virtio disk
                   │      virtio-SAWCREDS              │    (survives reboot)
                   │   2. podman pull                  │  ← versioned image
                   │      ${INSTALLER_IMAGE}           │    from quay.io
                   │   3. podman cp → /opt/            │  ← unpack to host
                   │   4. Build credentials.env        │  ← secret files
                   │      from mounted disk            │    → env vars
                   │   5. systemctl enable             │
                   │      saw-bom-install.service       │
                   │                                   │
                   │  install-bom.sh:                  │
                   │   ├ preflight (OS, arch, runtime) │
                   │   ├ fetch & verify (pull images,  │
                   │   │   extract gateway/supervisor) │
                   │   ├ install components             │
                   │   ├ configure gateway (systemd,   │
                   │   │   mTLS, register)             │
                   │   ├ bootstrap (role-specific:     │
                   │   │   apply_bom.py / proxy setup) │
                   │   └ verify + report               │
                   └──────────────────────────────────┘
```

## Directory Structure

```
cloud-init/
├── Makefile                      # Convenience wrapper for Ansible
├── ansible/
│   └── provision.yml             # Main playbook: secrets, CRDs, wait
├── installer/
│   ├── install-bom.sh            # Installer entrypoint
│   ├── manifest.yaml             # BOM manifest (pinned versions)
│   ├── saw-bom-install.service   # Systemd unit for cloud-init
│   ├── Dockerfile.base           # Base installer image
│   ├── Dockerfile.agent          # Agent installer (FROM base)
│   └── lib/
│       ├── common.sh             # Logging, report, run_as_user
│       ├── parse_manifest.py     # YAML manifest → shell env vars
│       ├── preflight.sh          # OS/arch/runtime checks, packages
│       ├── fetch_verify.sh       # Pull images, extract binaries
│       ├── install_components.sh # Version wrapper, lsof
│       ├── configure_gateway.sh  # Systemd, mTLS, gateway register
│       ├── bootstrap_agent.sh    # apply_bom.py with BOM profiles
│       └── verify.sh             # Run checks, write report
├── kubernetes/
│   ├── openshift-cnv/            # KubeVirt VirtualMachine CRDs
│   │   ├── agent-vm.yml
│   │   ├── integration-vm.yml
│   │   └── infrastructure-vm.yml
│   └── cirrus/                   # IBM Cirrus Server CRDs
│       ├── agent-server.yml
│       ├── integration-server.yml
│       └── infrastructure-server.yml
├── scripts/
│   ├── import-base-image.sh      # Golden DataVolume import
│   ├── generate-secrets.sh
│   ├── push-secrets-k8s.sh
│   └── verify-vms.sh
└── .secrets/                     # Local secrets (gitignored)
```

## Quick Start

### Prerequisites

- `oc` CLI logged into the cluster
- SSH public key at `~/.ssh/id_ed25519.pub`
- Installer image pushed to a registry accessible from the VMs

### Build the Installer Image

```bash
# From repo root — build base, then agent
cd cloud-init/installer
podman build -f Dockerfile.base -t saw-installer-base:v0.1.0 .

cd ../..  # back to repo root
podman build -f cloud-init/installer/Dockerfile.agent \
  --build-arg BASE_IMAGE=saw-installer-base:v0.1.0 \
  -t quay.io/yourns/saw-installer-agent:v0.1.0 .

podman push quay.io/yourns/saw-installer-agent:v0.1.0
```

Or use the Helm chart to build on OpenShift:

```bash
helm install build-installer image-builder-charts/helm/build-installer/ \
  --set git.ref=feat/cirrus-cloud-init
# Then: oc start-build saw-installer-base && oc start-build saw-installer-agent
```

### Provision VMs (OpenShift CNV)

```bash
cd cloud-init

make create-all \
  PLATFORM=openshift-cnv \
  NS=openshell-agents \
  INSTALLER_IMAGE=quay.io/yourns/saw-installer-agent:v0.1.0
```

### Provision VMs (IBM Cirrus)

```bash
cd cloud-init

make create-all \
  PLATFORM=cirrus \
  NS=rh-vm-test1 \
  INSTALLER_IMAGE=quay.io/yourns/saw-installer-agent:v0.1.0
```

### Delete VMs

```bash
make delete-all NS=openshell-agents
```

### Check Status

```bash
make status NS=openshell-agents
make verify
```

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PLATFORM` | `cirrus` | Target platform: `cirrus` or `openshift-cnv` |
| `NS` | current oc project | Kubernetes namespace |
| `INSTALLER_IMAGE` | `quay.io/sauagarw/saw-installer-agent:latest` | Versioned installer container image |
| `SSH_PUBKEY` | (empty) | SSH public key string (overrides file) |
| `SSH_PUBKEY_PATH` | `~/.ssh/id_ed25519.pub` | Path to SSH public key file |
| `BASE_IMAGE_URL` | Fedora Cloud 44 qcow2 | Base VM disk image (openshift-cnv) |
| `CONTAINER_DISK_IMAGE` | Cirrus RHEL 9 golden | Base containerDisk (cirrus) |
| `CACHE` | `false` | Cache base image as golden DataVolume (openshift-cnv only) |
| `BRANCH` | `main` | Git branch (only used by infrastructure VM) |

## Secret Handling

Secrets are injected into VMs via **KubeVirt secret disk mounts** — K8s Secrets mounted as virtio disks that persist across reboots.

### Secret Flow

```
Ansible playbook
  │
  ├─ generates bearer tokens → .secrets/
  │
  ├─ creates K8s Secrets:
  │    saw-agent-credentials        ← inter-vm-bearer
  │    saw-integration-credentials  ← bearer SHA256 + front-door secrets
  │
  └─ VM CRDs reference secrets as volumes:
       volumes:
         - name: credentials
           secret:
             secretName: saw-agent-credentials
       devices:
         disks:
           - name: credentials
             serial: SAWCREDS
             disk:
               bus: virtio
```

Inside the VM, cloud-init mounts the secret disk and builds `/etc/saw/credentials.env`:

```bash
mount -o ro /dev/disk/by-id/virtio-SAWCREDS /etc/saw/secrets
# Files named after secret keys become env vars:
#   /etc/saw/secrets/inter-vm-bearer → INTER_VM_BEARER=<value>
```

The installer reads these credentials for provider creation and proxy authentication.

### Per-Role Secrets

| K8s Secret | Mounted on | Contains |
|------------|-----------|----------|
| `saw-agent-credentials` | Agent VM | `inter-vm-bearer` (for proxy auth to integration VM) |
| `saw-integration-credentials` | Integration VM | `inter-vm-bearer-sha256`, `gmail-write-frontdoor`, `m365-write-frontdoor`, `slack-write-frontdoor` |

Provider API keys (NVIDIA, OpenAI, etc.) can be added to the credential secrets before provisioning, or injected later by updating the secret and rebooting the VM.

### Secret Safety

- Never commit secrets to Git
- Local secrets stored in `cloud-init/.secrets/` (gitignored)
- Secrets are mounted read-only inside VMs
- Bearer tokens are 64 hex characters generated via `openssl rand -hex 32`

## BOM Manifest

The installer is driven by `manifest.yaml` — a versioned bill of materials that pins every artifact:

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: VmBom
metadata:
  name: saw-agent-bom
  version: v0.1.0
spec:
  role: agent
  platform:
    os: fedora
    arch: amd64
    runtime: podman
  artifacts:
    openshell:
      cli:
        version: "0.0.110"
      gateway:
        image: "ghcr.io/nvidia/openshell/gateway:0.0.110"
      supervisor:
        image: "ghcr.io/nvidia/openshell/supervisor:0.0.110"
```

The manifest controls:
- **Artifact versions** — OpenShell CLI, gateway, supervisor
- **System packages** — what gets `dnf install`'d
- **Gateway configuration** — systemd env vars, ports, auth mode
- **Bootstrap** — which BOM profiles to apply, gateway name
- **Verification** — post-install health checks

### Installer Behavior

1. **Idempotent** — skips if manifest hash unchanged (`/var/lib/saw-bom/last-applied-sha`)
2. **Dry-run** — `install-bom.sh --manifest manifest.yaml --dry-run`
3. **Phased** — preflight → fetch → install → configure → bootstrap → verify
4. **Reporting** — writes JSON + text report to `/var/log/saw-bom-install-report.*`

## Installer Image Layering

```
saw-installer-base:v0.1.0             ← common phases (preflight, fetch, install, configure, verify)
  ├─ saw-installer-agent:v0.1.0       ← + manifest.yaml + BOM profiles + apply_bom.py
  ├─ saw-installer-integration:v0.1.0 ← + integration profiles + proxy setup (future)
  └─ saw-installer-infrastructure:v0.1.0 ← + SSH keygen + Ansible coordination (future)
```

The base image contains the installer framework. Role-specific images add the manifest, profiles, and bootstrap scripts for each VM role.

Profiles come from `charts/saw-bom/profiles/` (single source of truth) and are COPYed into the image at build time.

## Build the Installer on OpenShift

The `build-installer` Helm chart creates BuildConfig + ImageStream resources:

```bash
helm install build-installer image-builder-charts/helm/build-installer/ \
  --set git.ref=main \
  --set git.uri=https://github.com/rh-forge/secure-agent-workspace.git

# Build base first, then agent (agent FROM base)
oc start-build saw-installer-base --follow
oc start-build saw-installer-agent --follow
```

## Upgrading

To upgrade the agent VM to a new BOM version:

1. Update `cloud-init/installer/manifest.yaml` with new artifact versions
2. Rebuild and push the installer image with a new tag
3. Update `INSTALLER_IMAGE` and re-provision:

```bash
make delete-all NS=openshell-agents
make create-all PLATFORM=openshift-cnv NS=openshell-agents \
  INSTALLER_IMAGE=quay.io/yourns/saw-installer-agent:v0.2.0
```

Or update the secret and reboot the VM — the installer detects the manifest hash change and re-runs.

## Troubleshooting

### Check installer logs

```bash
# SSH into agent VM
virtctl -n openshell-agents ssh openshell@vm/saw-agent

# Check installer service
journalctl -u saw-bom-install.service --no-pager

# Check install report
cat /var/log/saw-bom-install-report.txt

# Check gateway
systemctl --user status openshell-gateway.service
```

### Check secret disk mount

```bash
# Verify disk is visible
ls -la /dev/disk/by-id/virtio-SAWCREDS

# Check mount
mount | grep saw

# Check credentials
cat /etc/saw/credentials.env
```

### DataVolume stuck

If DataVolumes show `ImportInProgress` for too long, the Fedora Cloud qcow2 download may be slow. Use `CACHE=true` to import once and clone:

```bash
make create-all PLATFORM=openshift-cnv NS=openshell-agents CACHE=true \
  INSTALLER_IMAGE=quay.io/yourns/saw-installer-agent:v0.1.0
```

### VM not scheduling

Check cluster resources — the agent VM requests 4 cores / 8Gi:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```
