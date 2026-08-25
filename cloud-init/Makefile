# Cloud-init provisioning for three-VM architecture.
# All logic lives in Ansible playbooks — this Makefile is a convenience wrapper.
#
# Usage:
#   make create-all PLATFORM=cirrus NS=my-namespace
#   make delete-all
#   make verify

PLATFORM             ?= openshift-cnv
NS                   ?= $(shell oc project -q 2>/dev/null)
BRANCH               ?= main
SSH_PUBKEY           ?=
SSH_PUBKEY_PATH      ?= ~/.ssh/id_ed25519.pub
CONTAINER_DISK_IMAGE ?= registry.cirrus.ibm.com/mici-golden-images/cirrus-rhel-9-golden-image:latest
GOLDEN_IMAGE_PVC     ?= openshell-gateway-podman-golden
BASE_IMAGE_URL       ?= https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
INSTALLER_IMAGE             ?= quay.io/sauagarw/saw-installer-agent:latest
INTEGRATION_INSTALLER_IMAGE ?= quay.io/sauagarw/saw-installer-integration:latest
INFERENCE_PROVIDER          ?=
INFERENCE_MODEL             ?=
INFERENCE_API_KEY           ?=
INFERENCE_ENDPOINT_URL      ?=
CACHE                ?= false
ANSIBLE_DIR          := ansible

export NS PLATFORM BRANCH SSH_PUBKEY SSH_PUBKEY_PATH CONTAINER_DISK_IMAGE GOLDEN_IMAGE_PVC BASE_IMAGE_URL \
       INSTALLER_IMAGE INTEGRATION_INSTALLER_IMAGE \
       INFERENCE_PROVIDER INFERENCE_MODEL INFERENCE_API_KEY INFERENCE_ENDPOINT_URL

SSH_KEY          ?= ~/.ssh/id_ed25519
VIRTCTL_SSH      = virtctl -n $(NS) ssh openshell@vm/$(1) \
		--identity-file=$(SSH_KEY) \
		--local-ssh-opts=-oStrictHostKeyChecking=no \
		--local-ssh-opts=-oUserKnownHostsFile=/dev/null

WAIT_FOR_VM = @bash scripts/wait-for-vm.sh $(1) $(NS) openshell $(SSH_KEY)

.PHONY: help build-installer create-all create-agent secrets delete-all verify status \
	agent-logs agent-logs-init agent-ssh \
	integration-logs integration-logs-init integration-ssh \
	infra-logs infra-ssh

help: ## Show this help
	@echo ""
	@echo "SAW Cloud-Init Provisioning"
	@echo "==========================="
	@echo ""
	@echo "Variables:"
	@printf "  \033[33m%-25s\033[0m %s [%s]\n" \
		"PLATFORM" "Target platform: cirrus | openshift-cnv" "$(PLATFORM)" \
		"NS" "Kubernetes namespace" "$(NS)" \
		"BRANCH" "Git branch for cloud-init bootstrap" "$(BRANCH)" \
		"SSH_PUBKEY" "SSH public key string (overrides file)" "$(if $(SSH_PUBKEY),set,unset)" \
		"SSH_PUBKEY_PATH" "Path to SSH public key file" "$(SSH_PUBKEY_PATH)" \
		"CONTAINER_DISK_IMAGE" "Base VM image (cirrus)" "$(CONTAINER_DISK_IMAGE)" \
		"GOLDEN_IMAGE_PVC" "Golden image PVC (openshift-cnv)" "$(GOLDEN_IMAGE_PVC)" \
		"BASE_IMAGE_URL" "Fedora Cloud qcow2 URL (openshift-cnv)" "$(BASE_IMAGE_URL)" \
		"INSTALLER_IMAGE" "SAW BOM installer container image" "$(INSTALLER_IMAGE)" \
		"CACHE" "Cache base image as golden DV, openshift-cnv only (true|false)" "$(CACHE)"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+[a-zA-Z0-9_-]*:.*## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make create-all PLATFORM=cirrus NS=rh-vm-test1"
	@echo "  make create-all PLATFORM=openshift-cnv NS=openshell-agents SSH_PUBKEY=\"ssh-ed25519 ...\""
	@echo "  make delete-all NS=rh-vm-test1"
	@echo "  make verify"

build-installer: ## Build and push agent + integration installer images
	@echo "Building base installer image..."
	podman build -t saw-installer-base:latest \
		-f installer/Dockerfile.base installer/
	@echo "Building agent installer image..."
	podman build -t $(INSTALLER_IMAGE) \
		--build-arg BASE_IMAGE=saw-installer-base:latest \
		-f installer/Dockerfile.agent ..
	@echo "Building integration installer image..."
	podman build -t $(INTEGRATION_INSTALLER_IMAGE) \
		--build-arg BASE_IMAGE=saw-installer-base:latest \
		-f installer/Dockerfile.integration ..
	@echo "Pushing $(INSTALLER_IMAGE)..."
	podman push $(INSTALLER_IMAGE)
	@echo "Pushing $(INTEGRATION_INSTALLER_IMAGE)..."
	podman push $(INTEGRATION_INSTALLER_IMAGE)
	@echo "Done: agent=$(INSTALLER_IMAGE) integration=$(INTEGRATION_INSTALLER_IMAGE)"

secrets: ## Generate and push K8s secrets (bearer + front-door + per-role credentials)
	@source scripts/prompt-credentials.sh && \
	ansible-playbook $(ANSIBLE_DIR)/provision.yml \
		-e platform=$(PLATFORM) \
		-e ns=$(NS) \
		--tags secrets

create-agent: ## Create secrets + agent VM only
	@echo "Installing agent VM in namespace: $(NS)"
	@SSH_PUBKEY="$(or $(SSH_PUBKEY),$(shell cat $(SSH_PUBKEY_PATH) 2>/dev/null))"; \
	if [ -z "$${SSH_PUBKEY}" ]; then \
	  echo "ERROR: SSH public key not found. Set SSH_PUBKEY or SSH_PUBKEY_PATH." >&2; exit 1; \
	fi; \
	echo "SSH public key: $${SSH_PUBKEY:0:40}..."
	@$(MAKE) secrets
	@SSH_PUBKEY="$(or $(SSH_PUBKEY),$(shell cat $(SSH_PUBKEY_PATH) 2>/dev/null))"; \
	sed -e "s|\$${NS}|$(NS)|g" \
	    -e "s|\$${BASE_IMAGE_URL}|$(BASE_IMAGE_URL)|g" \
	    -e "s|\$${SSH_PUBKEY}|$${SSH_PUBKEY}|g" \
	    -e "s|\$${INSTALLER_IMAGE}|$(INSTALLER_IMAGE)|g" \
	  kubernetes/$(PLATFORM)/agent-vm.yml | oc apply -n $(NS) -f -

create-all: ## Create secrets + all three VMs (infrastructure, integration, agent)
	@echo "Installing VMs in namespace: $(NS)"
	@ansible-playbook $(ANSIBLE_DIR)/provision.yml \
		-e platform=$(PLATFORM) \
		-e ns=$(NS) \
		-e branch=$(BRANCH) \
		-e ssh_pubkey="$(SSH_PUBKEY)" \
		-e container_disk_image="$(CONTAINER_DISK_IMAGE)" \
		-e golden_image_pvc="$(GOLDEN_IMAGE_PVC)" \
		-e cache=$(CACHE)

delete-all: ## Delete all three VMs + K8s Secrets
	@ansible-playbook $(ANSIBLE_DIR)/provision.yml \
		-e platform=$(PLATFORM) \
		-e ns=$(NS) \
		-e action=delete

verify: ## Verify all VMs are running
	@bash scripts/verify-vms.sh

status: ## Show VM status
	@echo "=== VMs in $(NS) ==="
	@kubectl get vmi -n $(NS) 2>/dev/null || echo "No running VMIs"

agent-logs: ## Stream agent VM installer logs (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-agent)
	$(call VIRTCTL_SSH,saw-agent) --command="sudo journalctl -u saw-bom-install.service -f --no-pager"

agent-logs-init: ## Show agent VM cloud-init boot log (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-agent)
	$(call VIRTCTL_SSH,saw-agent) --command="sudo cat /var/log/saw-cloud-init.log"

agent-ssh: ## SSH into agent VM (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-agent)
	$(call VIRTCTL_SSH,saw-agent)

integration-logs: ## Stream integration VM installer logs (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-integration)
	$(call VIRTCTL_SSH,saw-integration) --command="sudo journalctl -u saw-bom-install.service -f --no-pager"

integration-logs-init: ## Show integration VM cloud-init boot log (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-integration)
	$(call VIRTCTL_SSH,saw-integration) --command="sudo cat /var/log/saw-cloud-init.log"

integration-ssh: ## SSH into integration VM (waits for VM to be running)
	$(call WAIT_FOR_VM,saw-integration)
	$(call VIRTCTL_SSH,saw-integration)

infra-ssh: ## SSH into infrastructure VM
	$(call WAIT_FOR_VM,saw-infrastructure)
	$(call VIRTCTL_SSH,saw-infrastructure)
