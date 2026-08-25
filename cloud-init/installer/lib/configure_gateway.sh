#!/usr/bin/env bash
# Phase: Configure gateway — generate TLS certs, systemd service, register gateway.

log_phase "Configure Gateway"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[dry-run] Would configure gateway service and mTLS"
  report_add "configure-gateway: dry-run skipped"
  return 0
fi

USER_HOME="$(eval echo ~"${BOM_USER}")"
SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
TLS_DIR="${USER_HOME}/.local/state/openshell/tls"
CLIENT_DIR="${TLS_DIR}/client"

# --- Generate mTLS PKI ---
# Gateway expects: ca.crt, server/tls.crt, server/tls.key, client/tls.crt, client/tls.key
log "Generating mTLS PKI..."
SERVER_DIR="${TLS_DIR}/server"
run_as_user "mkdir -p '${TLS_DIR}' '${CLIENT_DIR}' '${SERVER_DIR}'"

run_as_user "
  TLS='${TLS_DIR}'
  # CA
  if [[ ! -f \${TLS}/ca.key ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout \${TLS}/ca.key -out \${TLS}/ca.crt \
      -days 3650 -subj '/CN=openshell-ca' 2>/dev/null
    echo 'CA generated'
  fi
  # Server cert → server/tls.crt, server/tls.key
  if [[ ! -f \${TLS}/server/tls.key ]]; then
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout \${TLS}/server/tls.key \
      -subj '/CN=openshell-gateway' \
      -out /tmp/server.csr 2>/dev/null
    openssl x509 -req -in /tmp/server.csr \
      -CA \${TLS}/ca.crt -CAkey \${TLS}/ca.key -CAcreateserial \
      -days 3650 -out \${TLS}/server/tls.crt \
      -extfile <(printf 'subjectAltName=DNS:localhost,IP:127.0.0.1') 2>/dev/null
    rm -f /tmp/server.csr
    echo 'Server cert generated'
  fi
  # Client cert → client/tls.crt, client/tls.key
  if [[ ! -f \${TLS}/client/tls.key ]]; then
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout \${TLS}/client/tls.key \
      -subj '/CN=openshell-client/OU=openshell-admin' \
      -out /tmp/client.csr 2>/dev/null
    openssl x509 -req -in /tmp/client.csr \
      -CA \${TLS}/ca.crt -CAkey \${TLS}/ca.key -CAcreateserial \
      -days 3650 -out \${TLS}/client/tls.crt 2>/dev/null
    rm -f /tmp/client.csr
    echo 'Client cert generated (OU=openshell-admin)'
  fi
" || die "TLS PKI generation failed"

# --- Build environment block for systemd ---
ENV_BLOCK=""
for var in $(compgen -v | grep '^BOM_GW_ENV_'); do
  key="${var#BOM_GW_ENV_}"
  ENV_BLOCK="${ENV_BLOCK}Environment=${key}=${!var}\n"
done

# --- Create systemd user service ---
run_as_user "mkdir -p '${SYSTEMD_DIR}'"

cat > /tmp/openshell-gateway.service <<EOF
[Unit]
Description=OpenShell Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BOM_GATEWAY_BIN} --tls-cert ${TLS_DIR}/server/tls.crt --tls-key ${TLS_DIR}/server/tls.key --tls-client-ca ${TLS_DIR}/ca.crt
Restart=on-failure
RestartSec=5
$(echo -e "${ENV_BLOCK}")
[Install]
WantedBy=default.target
EOF

run_as_user "cp /tmp/openshell-gateway.service '${SYSTEMD_DIR}/openshell-gateway.service'"
rm -f /tmp/openshell-gateway.service

# Enable lingering so user services survive logout
sudo loginctl enable-linger "${BOM_USER}" 2>/dev/null || true

# Enable podman API socket (required by gateway)
run_as_user "systemctl --user enable --now podman.socket" 2>/dev/null || true

# Start gateway
log "Starting gateway service..."
run_as_user "systemctl --user daemon-reload"
run_as_user "systemctl --user enable openshell-gateway.service"
run_as_user "systemctl --user restart openshell-gateway.service"

# Wait for gateway to be healthy
GW_READY=0
for i in $(seq 1 15); do
  if run_as_user "systemctl --user is-active openshell-gateway.service" 2>/dev/null | grep -q "active"; then
    if run_as_user "curl -sk --max-time 2 --cert '${CLIENT_DIR}/tls.crt' --key '${CLIENT_DIR}/tls.key' https://127.0.0.1:17670/healthz" &>/dev/null; then
      GW_READY=1
      break
    fi
  fi
  log "  waiting for gateway... (attempt $i)"
  sleep 2
done

if [[ "${GW_READY}" -ne 1 ]]; then
  warn "Gateway did not become healthy"
  run_as_user "journalctl --user -u openshell-gateway.service --no-pager 2>/dev/null | tail -10" || true
else
  log "Gateway healthy"
fi

# Register gateway with openshell CLI
log "Registering gateway: ${BOM_GATEWAY_NAME}"
run_as_user "
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  openshell gateway remove '${BOM_GATEWAY_NAME}' 2>/dev/null || true
  openshell gateway add '${BOM_GATEWAY_ENDPOINT}' --name '${BOM_GATEWAY_NAME}' --local
  openshell gateway select '${BOM_GATEWAY_NAME}'
" 2>/dev/null || warn "Gateway registration failed (non-fatal)"

# Copy client cert to gateway config dir
run_as_user "
  for gw_dir in \$HOME/.config/openshell/gateways/*/mtls; do
    [[ -d \${gw_dir} ]] && cp '${CLIENT_DIR}/tls.crt' '${CLIENT_DIR}/tls.key' \${gw_dir}/
  done
" 2>/dev/null || true

report_add "configure-gateway: OK (${BOM_GATEWAY_NAME} @ ${BOM_GATEWAY_ENDPOINT})"
