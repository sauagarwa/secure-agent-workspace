# OpenShift reference design: published chapter vs. draft Chapter 12

Compared on October 8, 2026.

## Sources and scope

- **Published chapter:** [Red Hat OpenShift Virtualization Reference Implementation](https://docs.nvidia.com/enterprise-reference-architectures/secure-agent-workspace-reference-design/latest/openshift-virtualization-reference-implementation.html), showing a last-updated date of June 28, 2026 when reviewed. The `/latest/` URL may change over time.
- **Draft:** `RH - DRAFT - Secure Agent Workspace Reference Design.pdf`, Chapter 12, **Red Hat OpenShift Reference Implementation**, PDF pages 37-47. Local source: `/Users/saurabh/Downloads/RH - DRAFT - Secure Agent Workspace Reference Design.pdf`.

This is a comparison of the two documents, not a claim that the proposed integrations are implemented or production-supported. “New” below means new to this OpenShift chapter; some concepts were already mentioned elsewhere in the published design.

## Main takeaway

The draft expands the existing persistent VM design rather than replacing it. It adds an optional Kata-based execution profile, confidential inference, and BlueField DPU networking. It also makes component placement, policy activation, and deployment qualification more explicit.

## Changes at a glance

| Topic | Published chapter | Draft Chapter 12 |
| --- | --- | --- |
| Main scope | Persistent workspaces using OpenShift Virtualization. | Broader OpenShift design covering persistent VMs and application-created Linux agent sessions. |
| Persistent VM model | One dedicated VM per user. | Retained. |
| Kata-backed sessions | No dedicated implementation section. | Adds a proposed optional execution profile with session management, controlled provisioning, cleanup, and recovery. |
| Security component placement | Opening description places execution, enforcement, enterprise-tool access, and audit inside the managed VM boundary. | Explicitly separates workspace execution from surrounding access, policy, credential, audit, and inference services. |
| Confidential inference | No dedicated implementation section. | Adds an optional protected AI-serving design with attestation and controlled key release. |
| DPU networking | No dedicated implementation section. | Adds optional BlueField networking and infrastructure telemetry integration. |
| Policy updates | Signed bundles verified and applied through a runtime API. | Clarifies signing-key custody, trusted activation, version-specific limits, and possible runtime recreation for static policy changes. |
| Deployment readiness | Describes Phase I as deployable with standard OpenShift Virtualization and enterprise practices. | Requires qualification of the selected images, network paths, identity integration, and operating controls before claiming readiness. |
| Storage and core controls | GitOps, NFS guidance, SSO, network allowlists, audit, human review, and Phase I/II controls. | Substantially retained. |

## 1. Two ways to run agents

### Persistent workspace: a dedicated remote computer

Each user gets a VM containing their tools, files, and agent environment. The user connects through a browser or terminal and can return to saved work later. If the VM remains running, the agent can continue working after the user disconnects.

Persistence does not mean continuous execution or automatic backup. Stopping the VM stops execution; resuming an interrupted task may require saved progress.

### Application-created session: an environment requested for agent work

An application can request an approved, isolated Linux environment for an agent. For example, a bug-tracking application could request a session to investigate a ticket and save a proposed fix.

The draft proposes Kata-backed pods for this option. Each sandboxed pod has a VM and guest-kernel boundary; containers inside that pod share it. This is not ordinary shared-kernel container isolation.

The platform supplies two responsibilities:

- **Agent Session Service:** binds the user, application, and task to approved policies, model/tool access, quotas, and credentials.
- **Sandbox Lifecycle Service:** creates or assigns the approved sandbox and manages expiry and cleanup.

Kata does not automatically supply those services. The application requests work, while the platform controls what can be created and what it may access.

These sessions can support tasks or restartable background services; they are not necessarily limited to short jobs. Recovery requires checkpoints and retained data, plus renewed identity, policy, and credential bindings. Saved files alone do not preserve in-memory execution.

**Draft reference:** pages 40-42.

## 2. Clearer security component placement

The draft separates the place where the agent executes from the services that govern it.

For the proposed Kubernetes/Kata integration, it describes the trusted OpenShell supervisor running in a separate pod outside the agent sandbox pod. The supervisor evaluates network policy and adds approved provider credentials. Network controls must prevent the agent from bypassing that path.

Being outside the agent pod does not automatically protect the supervisor from compromise of its worker host. The supervisor and its hosting environment remain trusted infrastructure.

The trusted access broker is not new. Its role remains controlling the human user's connection to the workspace using enterprise identity, authorized sessions, and audit. It is an architectural responsibility, not a claim that OpenShift Virtualization automatically provides a complete broker.

**Draft reference:** pages 37-38 and 41.

## 3. Optional confidential inference

**Inference** means an AI model processing a question and producing an answer. Confidential inference runs that processing in a hardware-protected environment intended to protect selected assets from infrastructure operators outside its trusted boundary.

The draft describes:

1. A separate inference service using compatible CPU and GPU confidential-computing capabilities.
2. **Attestation:** checking hardware-backed evidence about the environment against security policy.
3. **Controlled key release:** supplying decryption material only after the required verification and resource-authorization checks pass.
4. Encrypted request paths that keep protected prompts confidential until they reach the trusted inference workload.

Trustee coordinates attestation and conditional resource release; NVIDIA Remote Attestation Service contributes GPU verification. These roles are distinct from an optional enterprise key-management service.

Either Phase I or Phase II workspaces can use the confidential inference path. It does **not** automatically make the agent workspace confidential. Data before encryption and answers returned to the workspace still depend on normal workspace protections.

The draft calls this a proposed integration and notes support qualifications, including Technology Preview status for confidential GPU functionality in the cited downstream context. Support must be checked for the selected stack. Stopping future key release also cannot recall keys already released.

**Draft reference:** pages 42-45.

## 4. Optional BlueField DPU networking

A **DPU (Data Processing Unit)** is a specialized processor on a network device. BlueField is NVIDIA's DPU product.

The draft describes moving selected infrastructure networking work onto BlueField while agents continue running on the compute servers. It also describes infrastructure telemetry: measurements of hardware and networking behavior that help operators monitor the system.

The proposed OpenShift integration identifies BlueField-3, DPF, Host-Based Networking, and DOCA Telemetry Service. It explicitly notes that Egress Firewall is supported but not offloaded in the described profile.

Important limits:

- Network offload does not automatically establish protection against host compromise.
- Accelerated network paths must not bypass the supervisor or approved service boundary.
- Hardware/network measurements do not prove that an agent action was authorized.
- DPU networking does not replace workspace isolation, credential mediation, or human approval.

This option is independent of whether the agent uses a persistent VM or a Kata session.

**Draft reference:** page 45.

## 5. More explicit policy activation and readiness requirements

The draft preserves the signed-policy delivery approach and adds qualifications:

- Validate ConfigMap and runtime-policy size limits for the selected releases.
- Delivering or mounting a policy file is not the same as activating enforcement.
- Apply dynamic network policy through the supported runtime API.
- Static filesystem and process-policy changes may require runtime recreation.
- Explicitly implement signing-key custody, signature verification, and trusted activation.
- Qualify the complete configuration before claiming Phase I or Phase II readiness.

In plain language: delivering a new rulebook is different from proving that the security guard is enforcing it.

**Draft reference:** pages 39-42.

## What does not materially change

- Persistent, single-user VM workspaces remain a supported design choice.
- The user's endpoint provides the interface; autonomous execution happens remotely.
- Enterprise SSO and a trusted access broker remain part of the design.
- Git remains the source of policy intent; GitOps reconciles platform desired state.
- The Phase I and Phase II control lists for the managed VM profile are substantially unchanged.
- Signed runtime policy, mediated credentials, human review, audit, and operator termination controls remain required parts of the design.
- NFS guidance still calls for read-only policy delivery, immutable release directories, integrity checks, and reliable refresh mechanisms.

The new execution and infrastructure options are not new security phases and do not automatically satisfy the existing controls.

## Implication for our current implementation

Repository review at commit `0dac5b63` found the persistent VM path: the portal provisions a dedicated VM, and OpenShell uses Podman for sandboxes inside that VM. It did not find the proposed Kata RuntimeClass configuration or Agent Session/Sandbox Lifecycle services. This was a repository review, not a live-cluster inspection.

The existing VM implementation can therefore remain the foundation. Application-created Kata sessions, confidential inference, and DPU networking are separate optional implementation tracks. The draft's qualification and enforcement requirements also apply when retaining only the VM path.
