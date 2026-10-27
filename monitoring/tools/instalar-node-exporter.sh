#!/usr/bin/env bash
# =============================================================================
# instalar-node-exporter.sh — node_exporter como servicio systemd (nodos Proxmox)
# Uso desde la VM de monitorización:
#   ssh root@<IP_NODO> 'bash -s' < tools/instalar-node-exporter.sh
# Idempotente. Puerto 9100.
# =============================================================================
set -euo pipefail
VER="${NODE_EXPORTER_VERSION:-1.12.1}"
if /usr/local/bin/node_exporter --version 2>&1 | grep -q "version ${VER}"; then
  echo "node_exporter ${VER} ya instalado"; systemctl enable --now node_exporter; exit 0
fi
cd /tmp
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${VER}/node_exporter-${VER}.linux-amd64.tar.gz" -o node_exporter.tgz
tar -xzf node_exporter.tgz
install -m 0755 "node_exporter-${VER}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
rm -rf node_exporter.tgz "node_exporter-${VER}.linux-amd64"
id node_exporter &>/dev/null || useradd -rs /bin/false node_exporter
cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now node_exporter
sleep 1
curl -sf http://localhost:9100/metrics | head -2 && echo "node_exporter ${VER} OK"
