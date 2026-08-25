# Cirrus Cloud-Init Deployment

Provision the two-VM split architecture on IBM Cirrus (or any cloud with cloud-init support) without OpenShift/KubeVirt. Uses Ansible playbooks run via cloud-init to configure pre-existing VMs as agent + integrations nodes.

## Architecture

```
Infra VM (provisioner)               saw-{owner}-agent-vm              saw-{owner}-integration-vm
┌──────────────────┐                 ┌──────────────────┐              ┌──────────────────────┐
│  Ansible + SSH   │──── SSH ──────>│  OpenShell gw     │              │  OpenShell gw        │
│  Secret store    │                │  OpenClaw sandbox │              │  gmail-read :18080   │
│  OAuth creds     │──── SSH ──────────────────────────>│  gmail-write :18081  │
│  BOM profiles    │                │  gog + forwarder  │              │  m365-read :18082    │
│                  │                │  No real keys     │              │  inference :18083    │
└──────────────────┘                └──────────────────┘              │  slack-read :18084   │
                                                                      │  slack-write :18085  │
                                                                      │  m365-write :18086   │
                                                                      └──────────────────────┘
```

## Directory Structure

```
cloud-init/
├── README.md                          # This file
├── ansible/
│   ├── site.yml                       # Main playbook (dispatches by role)
│   ├── agent.yml                      # Agent VM provisioning
│   ├── integ.yml                      # Integrations VM provisioning
│   ├── vars/
│   │   ├── agent-vars.example.yml     # Agent VM variables template
│   │   └── integ-vars.example.yml     # Integrations VM variables template
│   ├── files/
│   │   ├── inference-proxy.py         # Inference reverse proxy
│   │   └── openclaw-policy.yml        # Sandbox policy
│   └── roles/                         # Ansible roles (future)
├── images/
│   ├── saw-agent-golden/
│   │   └── Containerfile              # Pre-baked agent VM golden image
│   └── saw-integ-golden/
│   │   └── Containerfile              # Pre-baked integ VM golden image
└── kubernetes/                        # Cirrus Server manifests (optional)
```

## VM Naming Convention

| VM | Name Pattern | Example |
|----|-------------|---------|
| Infra (provisioner) | `saw-{infra}-vm` | `saw-infra-vm` |
| Agent | `saw-{owner}-agent-vm` | `saw-alice-agent-vm` |
| Integrations | `saw-{owner}-integration-vm` | `saw-alice-integration-vm` |

## Deployment Options

### Option 1: Golden Images (pre-baked, air-gap ready)

Build golden images that embed all container images + binaries. VMs boot ready — the infra VM just drops credentials.

```bash
# Build golden images
cd cloud-init/images/saw-agent-golden
podman build -t quay.io/redhat-et/saw-agent-golden:latest .

cd cloud-init/images/saw-integ-golden
podman build -t quay.io/redhat-et/saw-integ-golden:latest .
```

### Option 2: Cloud-init + Ansible (runtime provisioning)

VMs boot from a base Fedora/RHEL image. Cloud-init runs the Ansible playbooks to install everything at first boot.

```bash
# Prepare variables
cp cloud-init/ansible/vars/agent-vars.example.yml cloud-init/.secrets/agent-vars.yml
cp cloud-init/ansible/vars/integ-vars.example.yml cloud-init/.secrets/integ-vars.yml
# Edit with real values...

# Run from infra VM (or locally with SSH access)
cd cloud-init/ansible
ansible-playbook site.yml -i inventory.ini
```

### Option 3: Hybrid (golden image + cloud-init for credentials)

Use golden images for the base + runtime cloud-init only for injecting credentials (API keys, OAuth tokens, bearers). Fastest boot, most secure.

## Secret Handling

Secrets are stored on the infra VM at `~/.config/saw-secrets/{owner}/`:

```
~/.config/saw-secrets/{owner}/
├── inter-vm-bearer           # Raw bearer (64 hex chars)
├── inter-vm-bearer-sha256    # SHA256 of bearer
├── inference-api-key         # NVIDIA/OpenAI API key
├── gmail-write-frontdoor     # Front-door bearer
├── m365-write-frontdoor      # Front-door bearer
├── slack-write-frontdoor     # Front-door bearer
└── oauth/
    ├── gmail-client.json     # OAuth client JSON
    └── gmail-token.json      # gog token export
```

Never commit secrets. Use `cloud-init/.secrets/` (gitignored).

## Prior Art

- **PR #3** (`feat: add Cirrus two-VM cloud-init deployment`) — original cloud-init + Ansible work for IBM Cirrus
- **openclaw-saw-demo** — reference two-VM deployment with all proxies
