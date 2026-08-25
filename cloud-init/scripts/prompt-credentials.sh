#!/usr/bin/env bash
# Prompt for any missing inference credentials and export them.
# Source this script: source scripts/prompt-credentials.sh
set -euo pipefail

prompt() {
  local var="$1" label="$2" secret="${3:-false}"
  if [[ -z "${!var:-}" ]]; then
    if [[ "${secret}" == "true" ]]; then
      read -rsp "  ${label}: " value </dev/tty
      echo "" >/dev/tty
    else
      read -rp "  ${label}: " value </dev/tty
    fi
    export "${var}=${value}"
  else
    echo "  ${label}: (already set)"
  fi
}

echo ""
echo "=== Inference credentials ==="
echo "Press Enter to keep an existing value, or type a new one."
echo ""
prompt INFERENCE_PROVIDER    "Provider (e.g. openai, glm)"
prompt INFERENCE_MODEL       "Model   (e.g. gpt-4o)"
prompt INFERENCE_API_KEY     "API key" true
prompt INFERENCE_ENDPOINT_URL "Endpoint URL (e.g. https://api.openai.com/v1)"
echo ""
