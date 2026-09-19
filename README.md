# Secure Agent Workspace

Deploy isolated, per-user AI workspaces on OpenShift Virtualization with GitOps-managed tenant boundaries and credentials.

## Table of Contents

- [Secure Agent Workspace](#secure-agent-workspace)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Detailed description](#detailed-description)
    - [Architecture diagrams](#architecture-diagrams)
      - [Reference Architecture](#reference-architecture)
      - [GitOps Policy Model](#gitops-policy-model)
      - [Storage Layout](#storage-layout)
      - [Implementation Overview](#implementation-overview)
  - [Requirements](#requirements)
    - [Minimum hardware requirements](#minimum-hardware-requirements)
    - [Minimum software requirements](#minimum-software-requirements)
    - [Required user permissions](#required-user-permissions)
  - [Deploy](#deploy)
    - [Prerequisites](#prerequisites)
    - [Installation](#installation)
      - [Option A: Validated Pattern (GitOps multi-user)](#option-a-validated-pattern-gitops-multi-user)
      - [Option B: Standalone Helm (no Argo CD)](#option-b-standalone-helm-no-argo-cd)
    - [Global installer release](#global-installer-release)
    - [Per-user instances](#per-user-instances)
    - [Supported inference providers](#supported-inference-providers)
    - [Validate tenant provisioning](#validate-tenant-provisioning)
    - [Delete](#delete)
  - [Repository structure](#repository-structure)
  - [References](#references)
  - [Technical details](#technical-details)
    - [Security model](#security-model)
  - [Tags](#tags)

## Overview

Secure Agent Workspace provisions one isolated KubeVirt VM workspace per enrolled
user/SAW identity. Desired state is reviewed in Git and reconciled by Argo CD;
provider credentials flow from Vault through External Secrets Operator (ESO), never
through Git or Helm values.

## Detailed description

Organizations adopting AI coding and knowledge agents need strong isolation guarantees: each user's agent must run in its own boundary, with auditable access to enterprise systems, controlled network egress, and centralized identity management. Traditional container-based isolation is insufficient when agents can execute arbitrary code and tool calls.

This implementation uses the NVIDIA Secure Agent Workspace architecture on Red Hat
OpenShift. Each enrollment receives a dedicated Fedora VM. Its namespace, private
root disk, Vault authorization, ESO-managed provider Secrets, and optional VM are
all derived from reviewed Git configuration. The VM receives only explicitly
projected, read-only inputs; it does not receive Kubernetes API credentials.

The system supports multiple inference providers (Gemini, Anthropic, OpenAI, NVIDIA Build, OpenRouter, Ollama, or custom endpoints) and optional web search integration (Tavily, Brave). A bootc-based golden image pipeline pre-bakes all packages into a container image that CDI imports directly, enabling fast VM provisioning without cloud-init package installation.

### Architecture diagrams

The following diagrams are from the [NVIDIA Secure Agent Workspace OpenShift Virtualization Reference Implementation](https://docs.nvidia.com/enterprise-reference-architectures/secure-agent-workspace-reference-design/latest/openshift-virtualization-reference-implementation.html).

#### Reference Architecture

![OpenShift Virtualization Reference Implementation](docs/images/openshift-reference-shape.png)

#### GitOps Policy Model

![GitOps Policy Model — End-to-End Policy Flow](docs/images/gitops-policy-model.png)

#### Storage Layout

![NFS storage layout for policy bundles and workspace persistence](docs/images/nfs-storage-layout.png)

#### Implementation Overview

```
                     OpenShift Cluster
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  Operators (deployed by Validated Pattern or manually):  │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │ OpenShift        │  │ Red Hat Build    │              │
│  │ Virtualization   │  │ of Keycloak      │              │
│  └──────────────────┘  └──────────────────┘              │
│                                                          │
│  Infrastructure (ArgoCD-managed):                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────────────┐  │
│  │ Vault    │ │ ESO      │ │ Keycloak (OIDC provider) │  │
│  └──────────┘ └──────────┘ └──────────────────────────┘  │
│       │                              │                   │
│       │ secrets sync                 │ JWKS validation   │
│       ▼                              ▼                   │
│  ┌──────────────────────────────────────────┐            │
│  │ Golden Image (bootc)                     │            │
│  │ Fedora 44 + OpenShell + podman + nodejs  │            │
│  │ Built via BuildConfig → CDI DataSource   │            │
│  └─────────────────┬────────────────────────┘            │
│                    │ clone per user                      │
│       ┌────────────┼────────────┐                        │
│       ▼            ▼            ▼                        │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                     │
│  │ alice   │ │ bob     │ │ carol   │  Per-user VMs       │
│  │ sandbox │ │ sandbox │ │ sandbox │  with gateway +     │
│  │  VM     │ │  VM     │ │  VM     │  agent + routes     │
│  └─────────┘ └─────────┘ └─────────┘                     │
│       │            │            │                        │
│       └────────────┼────────────┘                        │
│                    │                                     │
│  Routes:  TLS passthrough (gRPC) + edge (dashboard)      │
└──────────────────────────────────────────────────────────┘
        │
        ▼
   User (openshell CLI / browser)
```

| Component | Technology | Purpose |
|---|---|---|
| VM isolation | OpenShift Virtualization (KubeVirt) | One VM per user with process and network isolation |
| Identity | Red Hat Build of Keycloak (RHBK) | OIDC authentication, user management, SSO |
| Guest runtime | NVIDIA OpenShell | Workspace and provider reconciliation from approved input |
| Golden image | Fedora 44 disk OCI artifact + CDI | Qualified, digest-pinned shared source cloned per tenant |
| Secrets | HashiCorp Vault + External Secrets Operator | Namespace-scoped provider credentials |
| GitOps | ArgoCD (Validated Patterns) | Declarative cluster configuration |
| Tenant boundary | Namespace, Vault role, private DataVolume | Prevents cross-tenant resource and credential access |

## Requirements

### Minimum hardware requirements

| Resource | Per sandbox VM | Cluster overhead |
|---|---|---|
| CPU | 4 cores | 8 cores (operators, Keycloak, Vault) |
| Memory | 8 GiB | 16 GiB |
| Storage | 40 GiB (VM disk) | 50 GiB (golden image, registry) |

### Minimum software requirements

| Software | Version |
|---|---|
| Red Hat OpenShift | 4.22+ |
| OpenShift Virtualization operator | stable channel |
| Red Hat Build of Keycloak operator | stable-v26 channel |
| Helm CLI | 3.x |
| oc CLI | matching cluster version |
| openshell CLI | [latest release](https://github.com/NVIDIA/OpenShell/releases) |

### Required user permissions

**Cluster admin** is required for platform installation and for the approved image/Vault
setup. Tenant provisioning itself is Git/Argo-driven. External end-user OIDC access
remains a qualification gate for the current guest implementation.

## Deploy

### Prerequisites

You need an OpenShift administrator account for the platform steps and a Vault
administrator account for the policy step. Nothing below asks you to put a Vault
administrator token, provider API key, or mutable image tag in Git.

Install the repository tools and log in first:

```bash
oc login <cluster-api>
oc whoami
make saw-platform-check
```

`saw-platform-check` is read-only. OpenShift Virtualization/CDI and External
Secrets Operator are required for both deployment modes. Argo CD/ApplicationSet
and the bundled Red Hat Build of Keycloak are optional. Configure an external
OIDC issuer in `config/saw-platform.yaml`, or require the bundled Keycloak
operator explicitly with `SAW_REQUIRE_KEYCLOAK=1`. Vault Kubernetes
authentication is verified by the Vault administrator in the Vault policy step
below.

If the check reports missing APIs, bootstrap the platform before creating a
user. For GitOps, use `./pattern.sh make install`. For standalone Helm, a
cluster administrator can apply the repository’s OperatorHub subscriptions and
wait for them to become ready:

```bash
make saw-platform-operators
make saw-platform-check
```

If you choose the bundled Keycloak provider, deploy it after the Red Hat Build
of Keycloak API is available and print its issuer:

```bash
make saw-keycloak-operator
# Wait for the CSV/API to become ready, then:
SAW_REQUIRE_KEYCLOAK=1 make saw-platform-check
make keycloak
make keycloak-issuer
make configure-keycloak
```

`configure-keycloak` creates or verifies the `saw` realm, creates the
confidential `saw` OIDC client, and stores its generated client secret as
`Secret/saw-oidc-client` in the Keycloak namespace. It requires Keycloak admin
credentials from the operator-generated Secret, or explicit
`KEYCLOAK_ADMIN_USER` and `KEYCLOAK_ADMIN_PASSWORD` values.

The bundled Keycloak default namespace is `keycloak`. If the RHBK operator is
or an existing `openshell-keycloak` instance is found in another namespace, the
command asks before using it; set
`KEYCLOAK_AUTO_NS=1` for a non-interactive deployment or pass
`KEYCLOAK_NS=<namespace>` explicitly. If multiple Keycloak resources exist,
select one with `KEYCLOAK_NS=<namespace> KEYCLOAK_NAME=<resource-name>`.

For an external OIDC provider, leave the Keycloak operator uninstalled and set
the provider’s issuer directly in `config/saw-platform.yaml`; discovery will
preserve an explicitly configured issuer. To make the preflight enforce the
bundled provider instead, run:

```bash
SAW_REQUIRE_KEYCLOAK=1 make saw-platform-check
```

Vault/ESO setup is owned by this repository. Run `make setup-vault` to install
the SAW OperatorHub dependencies and validate Vault/ESO connectivity, then use
`make configure-vault` with a reviewed user file to render the tenant policy and
role plan for the Vault administrator. If Vault already exists, discovery reads
the existing `vault-backend` ClusterSecretStore. These commands never place a
Vault administrator token or provider credential in Git.

### Installation

Two deployment flows are available:

1. **Flow 1 — Validated Pattern / GitOps (multi-user):** reviewed tenant
   records in Git are reconciled through Argo CD/ApplicationSet.
2. **Flow 2 — Standalone Helm (one user at a time):** an administrator sets
   the shared platform defaults once, then each user supplies one small
   `sawUser` YAML file and runs `make saw-user-install`.

#### **Flow 1 — Validated Pattern / GitOps (multi-user)**

This repository's deployment path is the tenant blueprint. Do **not** use
`make copy-images`, `values-secret.yaml`, or `make openshell-saw-create` for this
path: they belong to the legacy direct-provisioning flow and mirror legacy
0.0.103 images. Tenant workspaces instead use a qualified VM disk built from a
digest-pinned InstallerBOM.

> **Current release status:** the chart wiring and tenant isolation contracts are
> implemented, but the guest installer is not yet an end-to-end qualified production
> release. Keep the blueprint disabled and guest VMs `Halted` until image, Vault/ESO,
> runtime, and workspace-readiness qualification is complete. See
> [implementation status](docs/saw-blueprint-implementation.md).

The deployment owner is Argo CD:

```text
Reviewed tenant records in Git
  -> saw-blueprint: shared approved image + ApplicationSet
  -> one openshell-saw Argo Application per record
  -> isolated namespace, private root clone, ESO provider Secrets
  -> optional VM with read-only ConfigMap and Secret mounts
  -> image-owned guest service reconciles approved workspace inputs
```

Follow these steps in order for a new environment.

1. Check the cluster services.

   ```bash
   make saw-platform-check
   ```

   This checks the APIs only; it makes no changes. Install any missing required
   operator before proceeding. For GitOps mode, verify Argo explicitly with
   `SAW_REQUIRE_ARGO=1 make saw-platform-check`.

2. Choose the release BOM. An **InstallerBOM** is the versioned release record
   for the three OpenShell images installed in the guest: CLI, gateway, and
   supervisor. It pins every image by SHA-256 digest, so a later registry tag
   change cannot alter a workspace. Start with
   [examples/saw/installer-bom.yaml](/Users/saurabh/dev/ai/nvidia/openshell/secure-agent-workspace/examples/saw/installer-bom.yaml), copy it into your release repository, review its image digests, and give it a release name. The example is a reference, not a production approval.

3. Build the immutable VM disk from that BOM.

   ```bash
   mkdir -p /tmp/saw-release
   cp examples/saw/installer-bom.yaml /tmp/saw-release/installer-bom.yaml

   make saw-image-context \
     SAW_INSTALLER_BOM=/tmp/saw-release/installer-bom.yaml \
     SAW_IMAGE_CONTEXT=/tmp/saw-release/image-context

   make saw-image-build SAW_IMAGE_CONTEXT=/tmp/saw-release/image-context
   ```

   `saw-image-context` only prepares the allowlisted build files. `saw-image-build`
   creates/uses the isolated `saw-installer-validation` BuildConfig and starts a
   binary build. It prints the candidate immutable `repository@sha256:digest`.
   Do not use that image for tenants yet.

4. Render and run the disposable boot smoke test.

   ```bash
   make saw-image-smoke-render \
     SAW_INSTALLER_BOM=/tmp/saw-release/installer-bom.yaml \
     SAW_SMOKE_IMAGE=<repository@sha256:digest-printed-by-the-build> \
     SAW_SMOKE_OUTPUT=/tmp/saw-release/boot-smoke.yaml

   oc create --dry-run=server -f /tmp/saw-release/boot-smoke.yaml
   oc create -f /tmp/saw-release/boot-smoke.yaml
   oc get vm,vmi,dv,pvc -n saw-installer-validation
   ```

   Complete your organization’s scan, signature, and approval gates. Then place
   the approved disk digest in `sawBlueprint.goldenImages[].registryURL` and copy
   the BOM’s `spec` into `sawBlueprint.installer.releases[].bom` as shown below.
   [Guest image qualification](guest/image/README.md) explains the expected
   smoke evidence and failure diagnosis.

The repository includes a release workflow at
`.github/workflows/publish-saw-installer.yml`. Create a tag in the form
`saw-installer-<release-name>` (for example, `saw-installer-saw-2026-09`), or run the workflow from
the Actions tab with an explicit BOM path. The workflow validates the BOM,
builds the deterministic guest bundle, and publishes the bundle plus BOM as an
immutable OCI artifact in GHCR:

```text
ghcr.io/<organization>/saw-installer@sha256:<artifact-digest>
```

The workflow summary and downloadable artifact contain `bundleRef` and
`bundleDigest`. Copy those values, along with the BOM content, into
`sawPlatform.installerRelease` in `config/saw-platform.yaml`; do not use the
mutable release tag as `bundleRef`.

5. For GitOps mode, discover the Argo CD apply identity.

   ```bash
   make saw-argo-discover
   # If more than one candidate is printed:
   SAW_ARGO_NAMESPACE=<namespace> SAW_ARGO_DEPLOYMENT=<deployment> make saw-argo-discover
   ```

   Copy the emitted `deployerServiceAccount` block into the blueprint. The parent
   chart grants this identity only the CDI source-clone permission for approved
   golden images.

6. Create the blueprint values file. Copy the complete `sawBlueprint` example in
   [Per-user instances](#per-user-instances) to `overrides/saw-blueprint.yaml`.
   Set `enabled: true`, the Argo repository/revision, the approved disk digest,
   platform issuer/Vault details, and at least one tenant. Run this before
   committing:

   ```bash
   make saw-test-fast
   make saw-render-gitops SAW_VALUES=overrides/saw-blueprint.yaml
   ```

7. Have the Vault administrator create a least-privilege role before enabling the
   tenant. The helper derives the exact namespace, immutable tenant key, policy
   paths, and `vault` commands without contacting Vault or applying changes:

   ```bash
   make saw-vault-plan SAW_VALUES=overrides/saw-blueprint.yaml SAW_TENANT=research \
     > /tmp/research-vault-plan.txt
   less /tmp/research-vault-plan.txt
   ```

   Review the plan, save the displayed HCL policy, and run the displayed commands
   using an authorized Vault administrator session. Add the provider value at the
   generated path. The role is bound only to that tenant namespace and its
   `saw-vault-reader` ServiceAccount.

8. For GitOps mode, commit and push the values file to the exact revision configured in
   `applicationSet.targetRevision`, then install/reconcile the Pattern:

   ```bash
   ./pattern.sh make install
   oc get applicationset -n saw-system saw-tenants
   oc get application -A -l app.kubernetes.io/part-of=openshell-saw
   ```

   Argo creates the tenant namespace, DataVolume, ESO resources, and optional VM.
   ESO creates the provider Secret only after Vault authentication succeeds.

#### **Flow 2 — Standalone Helm (one user at a time)**

Use this for a disposable test or a cluster where Argo CD is intentionally not
installed. The manual flow keeps its local platform contract outside the
checked-in `overrides` directory. Follow the complete sequence below; create
and publish the shared platform ConfigMap only after identity and Vault setup.

The standalone sequence is:

1. Log in and validate the required APIs:

   ```bash
   oc login <cluster-api>
   oc whoami
   make saw-platform-check
   ```

   OpenShift Virtualization, CDI, and External Secrets Operator are required.
   If they are missing, a cluster administrator can run `make saw-platform-operators`,
   wait for the CSVs/CRDs, and run the check again.
2. Configure identity. For the bundled or administrator-managed Keycloak:

   ```bash
   make keycloak
   make keycloak-issuer
   make configure-keycloak
   ```

   `make keycloak` detects an existing Keycloak resource and asks before using an
   instance in another namespace. Use `KEYCLOAK_NS=<namespace>` (and, when needed,
   `KEYCLOAK_NAME=<resource>`) to select one explicitly. For an external OIDC
   provider, skip these commands and set `sawPlatform.platform.issuer` manually.
3. Configure Vault and ESO:

   ```bash
   make setup-vault
   ```

   `setup-vault` installs/checks the SAW ESO prerequisites and deploys only a
   standalone Vault release plus `ClusterSecretStore/vault-backend` when they are
   absent. It never runs `pattern.sh` or deploys the full application in Flow 2.
   The standalone Vault uses the chart's development mode and is suitable for
   evaluation: the Vault namespace is created automatically and Vault is
   initialized/unsealed automatically. It has no production seal/unseal or
   durable-storage workflow; use an approved production Vault configuration for
   production.
   `configure-vault` renders the
   tenant-scoped policy and Kubernetes-auth role plan for administrator review;
   it does not copy provider credentials into Git. An existing
   `vault-backend` ClusterSecretStore is reused.
4. Copy `config/saw-platform.yaml.example` to the ignored local
   `config/saw-platform.yaml`, discover safe values, and review the result:

   ```bash
   cp config/saw-platform.yaml.example config/saw-platform.yaml
   make saw-platform-discover
   ```

   The golden-image CDI `DataSource` is the named CDI object that points to the
   approved VM disk in `saw-images`; it is not the registry URL or the disk image
   digest. If discovery reports no DataSource, CDI or the golden-image import is
   not ready. Inspect the available objects with:

   ```bash
   oc get datasource -n saw-images
   oc get datasource -n saw-images <name> -o yaml
   ```

   Set the selected object name under `sawPlatform.image.dataSource` (and change
   `sawPlatform.image.namespace` if the image lives elsewhere). If multiple
   DataSources exist, choose the one approved for the SAW golden image. Fill any
   other values that cannot be discovered, especially the approved immutable
   `installerRelease`/InstallerBOM. The release owner supplies these values;
   they are not inferred from a running cluster. The shape is:

   ```yaml
   sawPlatform:
     image:
       namespace: saw-images
       dataSource: qualified-saw-release-2026-09
       diskSizeGi: 40
     installerRelease:
       name: saw-2026-09
       bundleRef: registry.example.com/saw-installer@sha256:<64-hex-digest>
       bundleDigest: sha256:<64-hex-digest>
       bom:
         installerVersion: 0.1.0
         openshell:
           cli: {version: <approved-version>, image: <image@sha256:digest>}
           gateway: {version: <approved-version>, image: <image@sha256:digest>}
           supervisor: {version: <approved-version>, image: <image@sha256:digest>}
   ```

   `installerRelease.bom` comes from the reviewed
   [`examples/saw/installer-bom.yaml`](examples/saw/installer-bom.yaml), with
   the release owner’s approved image digests. `bundleRef` and
   `bundleDigest` come from the immutable installer bundle published for that
   release. Do not use a mutable tag or the golden VM image digest in these
   fields; the golden VM digest belongs to the CDI import/DataSource.
5. Create or edit one `sawUser` file per user. Set the immutable OIDC subject,
   username, `instance.workspaces`, profile ConfigMaps/credential bindings, and
   guest sizing/settings.
6. Render the Vault policy plan:

   ```bash
   make configure-vault SAW_USER_VALUES=overrides/users/<username>.yaml
   ```

   Have the Vault administrator review and apply the printed policy and
   Kubernetes-auth role commands before the tenant is installed.
7. Publish the reviewed shared configuration once:

   ```bash
   make saw-platform-configmap
   ```

   This creates `ConfigMap/saw-platform-config` in `saw-system`. It is shared and
   is not recreated in every user namespace.
8. Preview the generated tenant values:

   ```bash
   make saw-user-values SAW_USER_VALUES=overrides/users/<username>.yaml
   ```

9. Create the user’s isolated SAW namespace and workspace:

   ```bash
   make saw-user-install SAW_USER_VALUES=overrides/users/<username>.yaml
   ```

10. Verify the resulting resources:

   ```bash
   helm list -A | grep saw-
   oc get vm,vmi,dv,pvc,secretstore,externalsecret -A
   ```

```bash
# Preview exactly what the per-user chart will receive.
make saw-user-values SAW_USER_VALUES=overrides/users/research.yaml

# Create/update only this tenant namespace and its VM resources.
make saw-user-install SAW_USER_VALUES=overrides/users/research.yaml
```

`saw-platform-discover` can fill the Keycloak issuer, Vault server and CA bundle,
and an unambiguous CDI `DataSource`. It leaves values empty when the cluster
cannot prove which resource is correct. The approved immutable installer release
must still be reviewed by an administrator. `saw-user-install` reads the
`saw-platform-config` ConfigMap when it exists and falls back to the local file.

`sawUser.name` is the SAW instance name and becomes part of a deterministic,
isolated Kubernetes namespace such as `saw-research-<identity-hash>`. It is not
the guest workspace name: guest workspaces are the items under
`sawUser.instance.workspaces` and may be named `default`, `research`, or another
reviewed profile workspace.

The direct installer deliberately rejects an Argo-managed request:

```bash
make saw-user-install SAW_USER_VALUES=overrides/users/research.yaml SAW_TENANT_MANAGEMENT=argocd
# Refuses: Argo-managed tenants must be created by the parent ApplicationSet.
```

When using standalone Helm, Helm owns the tenant resources; do not later enable
the ApplicationSet for that same tenant until you have intentionally transferred
ownership and reconciled the existing resources.

### Global installer release

Define the installer once in `sawBlueprint.installer`. The parent chart selects
the default immutable release (or a reviewed tenant canary override), then
ApplicationSet passes that resolved release to every `openshell-saw` Application.
Each tenant chart writes a namespace-local copy of the release ConfigMap because
Kubernetes does not allow a VM to mount a ConfigMap from another namespace.

The ConfigMap carries the installer bundle reference/digest and InstallerBOM. The
guest currently executes the image-owned installer and consumes the release BOM;
verified activation of a separately fetched bundle is the next guest-runtime gate.

### Per-user instances

The tenant blueprint is the multi-user deployment path. A reviewed Git record
creates one Argo CD Application and one deterministic namespace for each unique
`(OIDC issuer, immutable subject, SAW name)` tuple. The username is display
metadata only: changing it does not transfer a namespace or a Vault path.

The flow is:

```text
Reviewed plain tenant values in Git
  -> parent Argo application / ApplicationSet
  -> one tenant Argo application and namespace
  -> tenant root DataVolume cloned from saw-images
  -> ESO provider Secrets in that tenant namespace
  -> optional VM mounts reviewed ConfigMaps and provider Secrets read-only
```

Create one `tenants` item for each user/SAW tuple in the Git-tracked
`overrides/saw-blueprint.yaml` (or a reviewed environment-specific value file).
The following is a complete shape for an enabled VM; replace every example
identity, Vault endpoint, CA, registry location, and digest with reviewed values.
Provider values themselves never belong in this file.

```yaml
sawBlueprint:
  enabled: true
  imageNamespace: saw-images
  deployerServiceAccount:
    # The actual Argo application-controller apply identity for this cluster.
    name: argocd-application-controller
    namespace: openshift-gitops
  # Shared platform settings. They are set once, never copied into a tenant.
  platform:
    issuer: https://identity.example.com/realms/saw
    vault:
      server: https://vault.example.com
      mount: secret
      prefix: saw/users
      authMount: kubernetes
      audience: vault
      # Public trust anchor, not a Vault token. ESO needs this before it can
      # authenticate to Vault, so it cannot be fetched through ESO.
      caBundle: |-
        -----BEGIN CERTIFICATE-----
        REPLACE-WITH-ENTERPRISE-VAULT-CA
        -----END CERTIFICATE-----
  applicationSet:
    enabled: true
    repoURL: https://github.example.com/platform/secure-agent-workspace.git
    targetRevision: main
    destinationServer: https://kubernetes.default.svc
    project: default
    tenantChartPath: charts/openshell-saw
  installer:
    defaultRelease: saw-2026-09
    releases:
      - name: saw-2026-09
        bundleRef: registry.example.com/saw-installer@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bundleDigest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bom:
          # Versioned components are global. The chart builds the internal
          # InstallerBOM document consumed by the guest.
          installerVersion: 0.1.0
          openshell: {cli: {version: 0.0.116-rhaiv.0, image: quay.io/opendatahub/odh-openshell-cli@sha256:REPLACE}, gateway: {version: 0.0.116-rhaiv.0, image: quay.io/opendatahub/odh-openshell-gateway@sha256:REPLACE}, supervisor: {version: 0.0.116-rhaiv.0, image: quay.io/opendatahub/odh-openshell-supervisor@sha256:REPLACE}}
  goldenImages:
    - name: qualified-saw-release
      # Replace this example digest with the qualified VM image digest.
      registryURL: docker://registry.example.com/saw-vm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      diskSizeGi: 40
  tenants:
    - goldenImageRef: qualified-saw-release
      name: research
      subject: immutable-oidc-subject
      username: alice
      credentials:
        - name: inference-main
          remoteKey: inference-main
          properties: {api_key: api_key}
      # Instance intent, profiles, and optional VM configuration are reviewed
      # Git data. Never put provider values here.
      profileConfigMaps:
        - name: alice-profiles
          data:
            profiles__data-science__default__workspace.yaml: |-
              apiVersion: saw.redhat.com/v1alpha1
              kind: Workspace
              metadata: {name: default}
              spec: {inference: {provider: nvidia, model: nvidia/nemotron-3-super-120b-a12b}}
            profiles__data-science__default__providers.yaml: |-
              apiVersion: saw.redhat.com/v1alpha1
              kind: Providers
              metadata: {profile: data-science}
              spec:
                providers:
                  - name: nvidia
                    type: nvidia
                    credentialRef: inference-main
      instance:
        workspaces:
          - profileRef: {name: data-science, configMapRef: {name: alice-profiles}}
            credentialBindings:
              inference-main:
                secretRef: {name: saw-provider-inference-main, key: api_key}
      # Omit this to inherit installer.defaultRelease. Set it only for an
      # approved canary or exceptional tenant release.
      installerReleaseRef: saw-2026-09
      guest:
        enabled: true
        cores: 4
        memoryGi: 8
        runStrategy: Halted
```

Copy the tenant item, give the new user a different SAW name and immutable OIDC
subject, and change the display username, Vault record, profile, and instance as
needed. Each item becomes an independently reconciled Argo Application and an
isolated namespace. Do not change an existing tenant's issuer, subject, or SAW
name in place.

Commit and push to the revision Argo watches. The source revision must exist on
the remote because both the parent application and generated tenant Applications
fetch it from Git. Then reconcile the pattern:

```bash
./pattern.sh make install
oc get applicationset -n saw-system saw-tenants
oc get application -n openshift-gitops
```

For a manual deployment, use the same reviewed values and install only the parent
chart; never manually install a generated tenant Application:

```bash
helm upgrade --install saw-blueprint charts/saw-blueprint \
  --namespace saw-system --create-namespace \
  -f tenant-blueprint-values.yaml

oc get applicationset -n saw-system saw-tenants
oc get namespace -l app.kubernetes.io/managed-by=argocd
```

Do not manually create tenant namespaces, VMs, DataVolumes, or provider Secrets:
Argo owns desired Kubernetes resources and ESO owns Secret contents. To change a
profile or instance, change that tenant's reviewed Git values; the VM receives the
allowlisted projected inputs without a Kubernetes API token.

Use the disposable live-cluster isolation gate after onboarding two tenants:

```bash
make saw-test-tenant-integration \
  SAW_TEST_ALICE_NAMESPACE=saw-... \
  SAW_TEST_BOB_NAMESPACE=saw-... \
  SAW_TEST_APPROVED_DATASOURCE=<approved-datasource> \
  SAW_TEST_PROFILE_CONFIGMAP=profiles \
  SAW_TEST_PROFILE_KEY=profiles__data-science__default__workspace.yaml \
  SAW_TEST_ALICE_APPLICATION=saw-... \
  SAW_TEST_BOB_APPLICATION=saw-... \
  VAULT_ADDR=https://vault.example.com VAULT_TOKEN=<disposable-test-token>
```

The test checks cross-tenant denial, Vault role separation, ESO rotation, and
Argo reconciliation. It temporarily rotates a provider value and restores it;
run it only against disposable test credentials.

#### Supported inference providers

| Provider | Key | Example model |
|---|---|---|
| NVIDIA | `nvidia` | `nvidia/nemotron-3-super-120b-a12b` |
| OpenAI | `openai` | release-specific |
| Anthropic | `anthropic` | release-specific |

The current guest reconciler supports these single-key provider types in newly
owned workspaces. Provider metadata is reviewed in profiles; only the credential
value comes from Vault/ESO.

### Validate tenant provisioning

```bash
# Validate schema/chart contracts before committing.
make saw-test-fast
make saw-render-gitops

# Confirm Argo produced one tenant Application per entry and each namespace/root clone.
oc get applicationset -n saw-system saw-tenants
oc get application -A -l app.kubernetes.io/part-of=openshell-saw
oc get namespace -l app.kubernetes.io/managed-by=argocd
oc get datavolume,vm -A

# Run the disposable two-tenant isolation/ESO/Argo gate only with disposable credentials.
make saw-test-tenant-integration SAW_TEST_ALICE_NAMESPACE=saw-... SAW_TEST_BOB_NAMESPACE=saw-... \
  SAW_TEST_APPROVED_DATASOURCE=<approved-datasource> SAW_TEST_PROFILE_CONFIGMAP=profiles \
  SAW_TEST_PROFILE_KEY=profiles__data-science__default__workspace.yaml \
  SAW_TEST_ALICE_APPLICATION=saw-... VAULT_ADDR=https://vault.example.com \
  VAULT_TOKEN=<disposable-test-token>
```

### Delete

```bash
# Remove a tenant by removing its Git entry, committing, and reconciling Argo.
# Tenant resources intentionally use retain/no-prune protections; handle data
# retention and approved teardown according to your platform policy.

# Uninstall the parent pattern only when all tenant data has been handled.
./pattern.sh make uninstall
```

## Repository structure

```
.
├── Makefile                          # Root Makefile
├── Makefile-saw                      # Tenant/image validation and rendering targets
├── values-global.yaml                # Pattern config (name, ArgoCD, secret loader)
├── values-prod.yaml                  # ClusterGroup (operators, subscriptions, applications)
├── overrides/
│   └── saw-blueprint.yaml            # Git-tracked tenant blueprint defaults
├── charts/                           # ArgoCD-managed Helm charts
│   ├── saw-blueprint/            # Parent GitOps chart: shared images + ApplicationSet
│   ├── openshell-saw/            # Per-user namespace, ESO inputs, VM, installer release
│   └── saw-bom/                  # Profile and legacy installer packaging inputs
├── guest/                            # Image build, guest service, and qualification tooling
├── installer/                        # Versioned apply_bom.py implementation
├── examples/saw/                     # Enrollment, BOM, image, and instance contracts
├── tests/saw/                        # Tenant isolation and chart-contract tests
├── cli/                              # Blueprint rendering CLI
├── pattern.sh                        # VP utility container wrapper
└── ansible.cfg                       # VP ansible config
```

## References

- [NVIDIA Secure Agent Workspace Reference Design](https://docs.nvidia.com/enterprise-reference-architectures/secure-agent-workspace-reference-design/latest/)
- [OpenShift Virtualization Reference Implementation](https://docs.nvidia.com/enterprise-reference-architectures/secure-agent-workspace-reference-design/latest/openshift-virtualization-reference-implementation.html)
- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
- [Red Hat Validated Patterns](https://validatedpatterns.io/)
- [Red Hat Build of Keycloak](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/)

## Technical details

### Security model

The tenant path implements layered isolation:

1. **VM-level isolation** — Each user gets a dedicated KubeVirt VM (one VM per user, no shared agent process space)
2. **Immutable enrollment identity** — Namespace identity derives from the OIDC
   issuer, immutable subject, and SAW name; display usernames do not authorize access.
3. **Scoped Vault/ESO access** — A tenant ServiceAccount can read only its own
   provider records; ESO writes only tenant-local Secrets.
4. **Shared-image protection** — Argo has narrowly scoped clone access to a named
   DataSource; tenants cannot modify the shared golden image.
5. **Tokenless guest** — The guest VM mounts only allowlisted ConfigMaps and Secret
   keys read-only and has no Kubernetes API token.

## Tags

| Field | Value |
|---|---|
| **Title** | Secure Agent Workspace |
| **Description** | Deploy isolated, per-user AI agent sandboxes on OpenShift Virtualization |
| **Industry** | Cross-industry |
| **Product** | Red Hat OpenShift |
| **Use case** | AI agent sandboxing, secure coding environments |
| **Partner** | NVIDIA |
