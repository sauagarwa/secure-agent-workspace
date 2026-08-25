#!/usr/bin/env bash
# Phase: Bootstrap Integration — apply proxy BOM profiles + deploy inference proxy.

log_phase "Bootstrap Integration"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would apply integration profiles from ${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
  report_add "bootstrap-integration: dry-run skipped"
  return 0
fi

PROFILES_DIR="${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
APPLY_BOM="${INSTALLER_DIR}/lib/apply_bom.py"

if [[ ! -d "${PROFILES_DIR}" ]]; then
  die "Profiles directory not found: ${PROFILES_DIR}"
fi

if [[ ! -f "${APPLY_BOM}" ]]; then
  die "apply_bom.py not found: ${APPLY_BOM}"
fi

USER_HOME="$(eval echo ~"${BOM_USER}")"

# --- Map secret disk keys to env vars for proxy sandboxes ---
# The secret disk contains: inter-vm-bearer-sha256, gmail-write-frontdoor, etc.
# Compute SHA256 digests that the proxy sandbox env vars expect.
if [[ -n "${INTER_VM_BEARER_SHA256:-}" ]]; then
  export INTER_VM_BEARER_SHA256
  log "Using INTER_VM_BEARER_SHA256 from credentials"
fi

if [[ -n "${GMAIL_WRITE_FRONTDOOR:-}" ]]; then
  export GMAIL_WRITE_FRONTDOOR_SHA256
  GMAIL_WRITE_FRONTDOOR_SHA256="$(echo -n "${GMAIL_WRITE_FRONTDOOR}" | sha256sum | cut -d' ' -f1)"
  log "Computed GMAIL_WRITE_FRONTDOOR_SHA256"
fi

if [[ -n "${M365_WRITE_FRONTDOOR:-}" ]]; then
  export M365_WRITE_FRONTDOOR_SHA256
  M365_WRITE_FRONTDOOR_SHA256="$(echo -n "${M365_WRITE_FRONTDOOR}" | sha256sum | cut -d' ' -f1)"
  log "Computed M365_WRITE_FRONTDOOR_SHA256"
fi

# --- Transfer only the role-specific profile to user home ---
BOM_DIR="${USER_HOME}/bom-profiles"
run_as_user "rm -rf '${BOM_DIR}' && mkdir -p '${BOM_DIR}'"

ROLE_DIR="${BOM_PROFILES_SOURCE}/${BOM_PROFILES_ROLE}"
if [[ ! -d "${ROLE_DIR}" ]]; then
  die "Profile role directory not found: ${ROLE_DIR}"
fi
for ws_dir in "${ROLE_DIR}"/*/; do
  [[ ! -d "${ws_dir}" ]] && continue
  ws_name="$(basename "${ws_dir}")"
  run_as_user "mkdir -p '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}'"
  for file in "${ws_dir}"*; do
    [[ ! -f "${file}" ]] && continue
    fname="$(basename "${file}")"
    cp "${file}" "/tmp/bom-${fname}"
    run_as_user "cp '/tmp/bom-${fname}' '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}/${fname}'"
    rm -f "/tmp/bom-${fname}"
    [[ "${fname}" == *.sh ]] && run_as_user "chmod +x '${BOM_DIR}/${BOM_PROFILES_ROLE}/${ws_name}/${fname}'"
  done
done

cp "${APPLY_BOM}" "/tmp/apply_bom.py"
run_as_user "cp /tmp/apply_bom.py '${USER_HOME}/apply_bom.py'"
rm -f /tmp/apply_bom.py

# Governance profiles
GOV_DIR="${INSTALLER_DIR}/governance-profiles"
GOV_VM_DIR="${USER_HOME}/governance-profiles"
if [[ -d "${GOV_DIR}" ]]; then
  run_as_user "mkdir -p '${GOV_VM_DIR}'"
  for file in "${GOV_DIR}"/*.yaml; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "/tmp/gov-$(basename "${file}")"
    run_as_user "cp '/tmp/gov-$(basename "${file}")' '${GOV_VM_DIR}/$(basename "${file}")'"
    rm -f "/tmp/gov-$(basename "${file}")"
  done
fi

# --- Build bom.env with placeholder credentials ---
# Integration providers use placeholder keys — real auth is handled by the proxy processes.
BOM_ENV="/tmp/bom-integ.env"
: > "${BOM_ENV}"

log "Injecting placeholder credentials for BOM providers"
for file in "${PROFILES_DIR}"/*/providers.yaml; do
  [[ -f "${file}" ]] || continue
  while IFS= read -r line; do
    if echo "${line}" | grep -q '^\s*- name:'; then
      pname="$(echo "${line}" | sed 's/.*name: *//' | tr -d '"' | tr -d "'")"
      env_var="$(echo "PROV_${pname}_KEY" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
      echo "${env_var}=placeholder-api-key" >> "${BOM_ENV}"
      log "  placeholder: ${pname}"
    fi
  done < "${file}"
done

# Pass secret-derived env vars
[[ -n "${INTER_VM_BEARER_SHA256:-}" ]] && echo "INTER_VM_BEARER_SHA256=${INTER_VM_BEARER_SHA256}" >> "${BOM_ENV}"
[[ -n "${GMAIL_WRITE_FRONTDOOR_SHA256:-}" ]] && echo "GMAIL_WRITE_FRONTDOOR_SHA256=${GMAIL_WRITE_FRONTDOOR_SHA256}" >> "${BOM_ENV}"
[[ -n "${M365_WRITE_FRONTDOOR_SHA256:-}" ]] && echo "M365_WRITE_FRONTDOOR_SHA256=${M365_WRITE_FRONTDOOR_SHA256}" >> "${BOM_ENV}"

run_as_user "cp '${BOM_ENV}' '${USER_HOME}/bom-integ.env'"
rm -f "${BOM_ENV}"

# --- Run apply_bom.py ---
log "Running apply_bom.py for integration profiles..."
run_as_user "
  set -a; source '${USER_HOME}/bom-integ.env' 2>/dev/null; set +a
  python3 '${USER_HOME}/apply_bom.py' \
    --profiles-dir '${BOM_DIR}' \
    --mtls-gateway '${BOM_GATEWAY_NAME}' \
    --governance-profiles-dir '${GOV_VM_DIR}'
" 2>&1

# --- Deploy inference reverse proxy ---
INFERENCE_PORT=18083
log "Deploying inference reverse proxy on port ${INFERENCE_PORT}..."

INFERENCE_KEY_PATH="${USER_HOME}/.config/secure-agent-workspace/nvidia-api-key"
BEARER_SHA_PATH="${USER_HOME}/.config/secure-agent-workspace/inter-vm-bearer-sha256"

run_as_user "
  mkdir -p ~/.config/secure-agent-workspace ~/.local/bin ~/.config/systemd/user

  echo -n '${INTER_VM_BEARER_SHA256:-}' > '${BEARER_SHA_PATH}'
  chmod 600 '${BEARER_SHA_PATH}'
"

# Write inference proxy script
cat > /tmp/inference-proxy.py << 'PYEOF'
#!/usr/bin/env python3
import hashlib, http.client, json, os, ssl, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

NVIDIA_HOST = os.environ.get('INFERENCE_HOST', 'integrate.api.nvidia.com')
KEY_PATH = os.path.expanduser('~/.config/secure-agent-workspace/nvidia-api-key')
SHA_PATH = os.path.expanduser('~/.config/secure-agent-workspace/inter-vm-bearer-sha256')

NVIDIA_API_KEY = ''
if os.path.exists(KEY_PATH):
    with open(KEY_PATH) as f: NVIDIA_API_KEY = f.read().strip()
    print(f'Loaded API key: {NVIDIA_API_KEY[:12]}...', file=sys.stderr)

BEARER_SHA256 = ''
if os.path.exists(SHA_PATH):
    with open(SHA_PATH) as f: BEARER_SHA256 = f.read().strip()
    print(f'Loaded bearer SHA256: {BEARER_SHA256[:16]}...', file=sys.stderr)

class InferenceProxy(BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            self.send_error(401, 'Bearer token required'); return
        token_hash = hashlib.sha256(auth[7:].encode()).hexdigest()
        if BEARER_SHA256 and token_hash != BEARER_SHA256:
            self.send_error(403, 'Invalid bearer'); return
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b''
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(NVIDIA_HOST, context=ctx, timeout=120)
        headers = {'Content-Type': self.headers.get('Content-Type', 'application/json'),
                   'Authorization': f'Bearer {NVIDIA_API_KEY}', 'Content-Length': str(len(body))}
        conn.request(self.command, self.path, body, headers)
        resp = conn.getresponse()
        resp_body = resp.read()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in ('transfer-encoding', 'connection', 'content-length', 'content-encoding'):
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)
        conn.close()
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200); self.send_header('Content-Length', '2')
            self.end_headers(); self.wfile.write(b'ok'); return
        self.send_error(404)
    def log_message(self, fmt, *args): print(f'[proxy] {fmt % args}', file=sys.stderr)

if __name__ == '__main__':
    port = int(os.environ.get('PORT', '18083'))
    print(f'Inference proxy listening on 0.0.0.0:{port}', file=sys.stderr)
    HTTPServer(('0.0.0.0', port), InferenceProxy).serve_forever()
PYEOF
chmod 755 /tmp/inference-proxy.py
run_as_user "cp /tmp/inference-proxy.py ~/.local/bin/inference-proxy.py && chmod +x ~/.local/bin/inference-proxy.py"
rm -f /tmp/inference-proxy.py

# Systemd user service for inference proxy
cat > /tmp/inference-proxy.service << EOF
[Unit]
Description=Inference Reverse Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/inference-proxy.py
Restart=always
RestartSec=3
Environment=PORT=${INFERENCE_PORT}

[Install]
WantedBy=default.target
EOF

SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
run_as_user "mkdir -p '${SYSTEMD_DIR}'"
run_as_user "cp /tmp/inference-proxy.service '${SYSTEMD_DIR}/inference-proxy.service'"
rm -f /tmp/inference-proxy.service

run_as_user "systemctl --user daemon-reload"
run_as_user "systemctl --user enable inference-proxy"
run_as_user "systemctl --user restart inference-proxy"

sleep 2
if run_as_user "curl -sf http://localhost:${INFERENCE_PORT}/healthz" &>/dev/null; then
  log "Inference proxy healthy on port ${INFERENCE_PORT}"
else
  warn "Inference proxy health check failed (may start later)"
fi

report_add "bootstrap-integration: OK (profiles=${BOM_PROFILES_SOURCE}, inference-proxy=${INFERENCE_PORT})"
log "Integration bootstrap complete"
