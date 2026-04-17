#!/usr/bin/env bash
# =============================================================================
#  Nuke License Dashboard — Docker Installer
#  Monitors Foundry / RLM license usage via rlmutil → Prometheus + Grafana
#  Works on any Linux distro with or without Docker pre-installed.
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/nuke/install.sh)
#
#  github.com/eduxatelite/proxmox-scripts
# =============================================================================
set -uo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✔${RST}  $*"; }
info() { echo -e "  ${BLU}→${RST}  $*"; }
warn() { echo -e "  ${YLW}⚠${RST}  $*"; }
err()  { echo -e "  ${RED}✘${RST}  $*"; }
step() { echo -e "\n${BLD}${CYN}══ $* ${RST}"; }
die()  { err "$*"; exit 1; }

# ── whiptail helpers ──────────────────────────────────────────────────────────
WT_H=20; WT_W=72

wt_input() {
  local __var=$1 title=$2 prompt=$3 default=$4
  local val
  val=$(whiptail --title "$title" --inputbox "$prompt" $WT_H $WT_W "$default" 3>&1 1>&2 2>&3) \
    || die "Installation cancelled."
  eval "$__var='$val'"
}

wt_yesno() { whiptail --title "$1" --yesno "$2" $WT_H $WT_W 3>&1 1>&2 2>&3; }
wt_msg()   { whiptail --title "$1" --msgbox "$2" $WT_H $WT_W; }

wt_password() {
  local __var=$1 title=$2 prompt=$3
  local val
  val=$(whiptail --title "$title" --passwordbox "$prompt" $WT_H $WT_W "" 3>&1 1>&2 2>&3) \
    || die "Installation cancelled."
  eval "$__var='$val'"
}

# ── root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash install.sh"

# ── detect distro ─────────────────────────────────────────────────────────────
detect_distro() {
  if   [[ -f /etc/os-release ]]; then source /etc/os-release; DISTRO="${ID,,}"; DISTRO_LIKE="${ID_LIKE,,}"
  elif command -v apt-get &>/dev/null; then DISTRO="debian"
  elif command -v dnf     &>/dev/null; then DISTRO="rhel"
  elif command -v yum     &>/dev/null; then DISTRO="rhel"
  else die "Cannot detect Linux distribution."; fi
}

is_debian_based() { [[ "$DISTRO" =~ ^(ubuntu|debian|linuxmint|pop)$ ]] || [[ "${DISTRO_LIKE:-}" =~ debian ]]; }
is_rhel_based()   { [[ "$DISTRO" =~ ^(rhel|centos|rocky|almalinux|fedora|ol)$ ]] || [[ "${DISTRO_LIKE:-}" =~ rhel|fedora ]]; }

ensure_whiptail() {
  command -v whiptail &>/dev/null && return
  if   is_debian_based; then apt-get install -y whiptail &>/dev/null
  elif is_rhel_based;   then (dnf install -y newt || yum install -y newt) &>/dev/null
  fi
}

ensure_curl() {
  command -v curl &>/dev/null && return
  if   is_debian_based; then apt-get install -y curl &>/dev/null
  elif is_rhel_based;   then (dnf install -y curl || yum install -y curl) &>/dev/null
  fi
}

install_docker_rhel() {
  set +e
  if command -v dnf &>/dev/null; then
    dnf install -y yum-utils >> /tmp/docker-install.log 2>&1
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >> /tmp/docker-install.log 2>&1
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> /tmp/docker-install.log 2>&1
  else
    yum install -y yum-utils >> /tmp/docker-install.log 2>&1
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >> /tmp/docker-install.log 2>&1
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> /tmp/docker-install.log 2>&1
  fi
  set -e
}

install_docker_debian() {
  set +e
  apt-get update -qq >> /tmp/docker-install.log 2>&1
  apt-get install -y ca-certificates curl gnupg lsb-release >> /tmp/docker-install.log 2>&1
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/"${DISTRO}"/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq >> /tmp/docker-install.log 2>&1
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> /tmp/docker-install.log 2>&1
  set -e
}

# =============================================================================
# STEP 0 — Welcome
# =============================================================================
clear
echo -e "${BLD}${CYN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║          NUKE LICENSE DASHBOARD — Docker Installer          ║
  ║          github.com/eduxatelite/proxmox-scripts             ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

detect_distro
ensure_curl
ensure_whiptail

wt_msg "Nuke License Dashboard" \
"Welcome to the Nuke License Dashboard installer.

This script will:

  1. Install Docker (if not already installed)
  2. Ask for your RLM license server details
  3. Deploy Prometheus + Grafana with the Nuke dashboard pre-loaded

The rlmutil binary is bundled inside the Docker image — no SSH
access to your license server is required.

Your RLM license server is NOT modified — this is read-only.

Press OK to continue."

# =============================================================================
# STEP 1 — Docker
# =============================================================================
step "Checking Docker"

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  ok "Docker already installed (${DOCKER_VER})"
else
  wt_msg "Docker Not Found" \
"Docker is not installed on this system.
The installer will install it automatically.

Distribution detected: ${DISTRO}

Press OK to install Docker."

  echo "" > /tmp/docker-install.log
  if   is_debian_based; then install_docker_debian
  elif is_rhel_based;   then install_docker_rhel
  else die "Unsupported distribution: ${DISTRO}. Install Docker manually."; fi

  if ! command -v docker &>/dev/null; then
    err "Docker installation failed."
    die "Check /tmp/docker-install.log"
  fi
  systemctl enable docker >> /tmp/docker-install.log 2>&1 || true
  systemctl start docker  || die "Failed to start Docker."
  ok "Docker installed"
fi

if ! docker compose version &>/dev/null; then
  die "Docker Compose plugin not found. See https://docs.docker.com/compose/install/"
fi
ok "Docker Compose available"

# =============================================================================
# STEP 2 — Studio + install directory
# =============================================================================
step "Configuration"

wt_input STUDIO_NAME "Studio Name" \
  "Enter your studio name (shown in Grafana):" \
  "My Studio"

wt_input INSTALL_DIR "Install Directory" \
  "Where should the dashboard be installed?" \
  "/opt/nuke-licenses"

wt_password GRAFANA_PASS "Grafana Password" \
  "Set a password for the Grafana admin user:"
[[ -z "$GRAFANA_PASS" ]] && GRAFANA_PASS="nukedashboard"

# =============================================================================
# STEP 3 — RLM License Server
# =============================================================================
step "RLM License Server"

wt_input RLM_HOST "RLM License Server" \
  "Enter the IP or hostname of your RLM license server:" \
  "192.168.1.100"

wt_input RLM_PORT "RLM License Server" \
  "RLM license port (shown in the RLM web admin page next to 'rlm'):" \
  "4101"

# =============================================================================
# STEP 4 — Ports
# =============================================================================
step "Port Configuration"

wt_input PORT_GRAFANA   "Ports" "Grafana port (web UI):"     "3001"
wt_input PORT_PROM      "Ports" "Prometheus port:"           "9091"
wt_input PORT_EXPORTER  "Ports" "License exporter port:"     "9200"

# =============================================================================
# STEP 5 — Summary
# =============================================================================
wt_msg "Ready to Install" \
"Installation Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Studio          : ${STUDIO_NAME}
  Install dir     : ${INSTALL_DIR}
  RLM server      : ${RLM_HOST} (port ${RLM_PORT})
  Grafana port    : ${PORT_GRAFANA}
  Prometheus port : ${PORT_PROM}
  Exporter port   : ${PORT_EXPORTER}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press OK to start the installation."

# Detect server IP early so it's available for Grafana config and final URLs
SERVER_IP=$(hostname -I | awk '{print $1}')

# =============================================================================
# STEP 6 — Deploy
# =============================================================================
step "Deploying Nuke License Dashboard"

REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/nuke"

mkdir -p "${INSTALL_DIR}"/{config,prometheus,grafana/provisioning/datasources}

# ── exporter config ───────────────────────────────────────────────────────────
info "Writing configuration…"
cat > "${INSTALL_DIR}/config/exporter.env" <<EOF
RLM_HOST=${RLM_HOST}
RLM_PORT=${RLM_PORT}
RLMUTIL_PATH=/app/rlmutil
EXPORTER_PORT=${PORT_EXPORTER}
SCRAPE_INTERVAL=60
EOF
chmod 600 "${INSTALL_DIR}/config/exporter.env"

# ── prometheus config ─────────────────────────────────────────────────────────
cat > "${INSTALL_DIR}/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s

scrape_configs:
  - job_name: 'nuke_license_exporter'
    static_configs:
      - targets: ['nuke-exporter:${PORT_EXPORTER}']
EOF

# ── grafana datasource provisioning (only datasource — dashboard via API) ─────
cat > "${INSTALL_DIR}/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

# ── download source files ─────────────────────────────────────────────────────
info "Downloading source files…"
curl -fsSL "${REPO_RAW}/nuke_exporter.py"            -o "${INSTALL_DIR}/nuke_exporter.py"  || die "Failed to download nuke_exporter.py"
curl -fsSL "${REPO_RAW}/Dockerfile"                  -o "${INSTALL_DIR}/Dockerfile"        || die "Failed to download Dockerfile"
curl -fsSL "${REPO_RAW}/rlmutil"                     -o "${INSTALL_DIR}/rlmutil"           || die "Failed to download rlmutil binary"
curl -fsSL "${REPO_RAW}/grafana_nuke_dashboard.json" -o "${INSTALL_DIR}/nuke_dashboard.json" || die "Failed to download dashboard JSON"
chmod +x "${INSTALL_DIR}/rlmutil"
ok "Source files downloaded"

# ── docker-compose.yml ────────────────────────────────────────────────────────
info "Writing docker-compose.yml…"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:

  # ── Nuke License Exporter (rlmutil → Prometheus metrics) ───────────────────
  nuke-exporter:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: nuke-exporter
    restart: unless-stopped
    env_file: config/exporter.env
    ports:
      - "${PORT_EXPORTER}:${PORT_EXPORTER}"
    networks:
      - nuke

  # ── Prometheus ──────────────────────────────────────────────────────────────
  prometheus:
    image: prom/prometheus:latest
    container_name: nuke-prometheus
    restart: unless-stopped
    ports:
      - "${PORT_PROM}:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - nuke_prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=90d'
    networks:
      - nuke

  # ── Grafana ─────────────────────────────────────────────────────────────────
  grafana:
    image: grafana/grafana:latest
    container_name: nuke-grafana
    restart: unless-stopped
    ports:
      - "${PORT_GRAFANA}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_ROOT_URL=http://${SERVER_IP}:${PORT_GRAFANA}
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/nuke.json
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./nuke_dashboard.json:/var/lib/grafana/dashboards/nuke.json:ro
      - nuke_grafana_data:/var/lib/grafana
    networks:
      - nuke

volumes:
  nuke_prometheus_data:
  nuke_grafana_data:

networks:
  nuke:
    driver: bridge
EOF

# ── build & start ─────────────────────────────────────────────────────────────
step "Starting containers"
cd "${INSTALL_DIR}"

info "Building exporter image…"
if ! docker compose build > /tmp/nuke-build.log 2>&1; then
  err "Docker build failed. Last 20 lines:"
  tail -20 /tmp/nuke-build.log
  die "Fix the error above, then re-run the installer."
fi
ok "Image built"

info "Starting all services…"
if ! docker compose up -d > /tmp/nuke-up.log 2>&1; then
  err "Failed to start containers. Last 20 lines:"
  tail -20 /tmp/nuke-up.log
  die "Fix the error above, then run: cd ${INSTALL_DIR} && docker compose up -d"
fi
ok "All containers started"

sleep 4

# ── Grafana API setup ─────────────────────────────────────────────────────────
step "Configuring Grafana via API"
PUBLIC_URL=""
GURL="http://localhost:${PORT_GRAFANA}"
GAUTH="admin:${GRAFANA_PASS}"

# Wait up to 60s for Grafana to be ready
info "Waiting for Grafana to start…"
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$GAUTH" "${GURL}/api/health" 2>/dev/null || true)
  [[ "$STATUS" == "200" ]] && break
  sleep 2
done

if [[ "$STATUS" != "200" ]]; then
  warn "Grafana did not respond in time — skipping API setup"
else
  ok "Grafana ready"

  # 1. Create Nuke folder (ignore error if it already exists)
  curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/folders" -d '{"title":"Nuke","uid":"nuke"}' > /dev/null 2>&1 || true

  # 2. Build import payload via python3 (avoids shell escaping issues with large JSON)
  info "Importing dashboard…"
  python3 - <<PYEOF
import json, sys
with open("${INSTALL_DIR}/nuke_dashboard.json") as f:
    dash = json.load(f)
payload = {"dashboard": dash, "folderUid": "nuke", "overwrite": True}
with open("/tmp/nuke_import_payload.json", "w") as out:
    json.dump(payload, out)
PYEOF

  IMPORT_RESP=$(curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/dashboards/db" \
    -d @/tmp/nuke_import_payload.json \
    2>/dev/null || true)
  sleep 2

  # Show import result for debugging
  IMPORT_STATUS=$(echo "$IMPORT_RESP" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('status', d.get('message', str(d)[:120])))" \
    2>/dev/null || echo "unknown")
  info "Import API response: ${IMPORT_STATUS}"

  # 3. Find the dashboard by title (most reliable method)
  SEARCH_RESP=$(curl -s -u "$GAUTH" \
    "${GURL}/api/search?query=Nuke&type=dash-db" 2>/dev/null || true)

  DASH_UID=$(echo "$SEARCH_RESP" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d[0]['uid'] if d else '')" \
    2>/dev/null || true)

  # Fallback: check import response uid field
  if [[ -z "$DASH_UID" ]]; then
    DASH_UID=$(echo "$IMPORT_RESP" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d.get('uid',''))" \
      2>/dev/null || true)
  fi

  if [[ -n "$DASH_UID" ]]; then
    ok "Dashboard in DB (uid: ${DASH_UID})"
  else
    warn "Dashboard not found in DB — home works via file mount, but public link unavailable"
    warn "Check /tmp/nuke_import_payload.json and try: curl -s -u admin:PASS ${GURL}/api/dashboards/db -X POST -H 'Content-Type: application/json' -d @/tmp/nuke_import_payload.json"
  fi

  # 4. Set as home dashboard for the org
  curl -s -X PUT -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/org/preferences" \
    -d "{\"homeDashboardUID\":\"${DASH_UID}\"}" > /dev/null 2>&1 || true
  ok "Home dashboard set"

  # 5. Create public (externally shareable) link
  info "Creating public dashboard link…"
  PUBLIC_RESP=$(curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/dashboards/uid/${DASH_UID}/public-dashboards" \
    -d '{"isEnabled":true,"annotationsEnabled":false,"timeSelectionEnabled":false}' \
    2>/dev/null || true)

  ACCESS_TOKEN=$(echo "$PUBLIC_RESP" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('accessToken',''))" \
    2>/dev/null || true)

  if [[ -n "$ACCESS_TOKEN" ]]; then
    PUBLIC_URL="http://${SERVER_IP}:${PORT_GRAFANA}/public-dashboards/${ACCESS_TOKEN}"
    ok "Public link created"
  else
    warn "Could not auto-create public link — in Grafana: Share → Share externally"
  fi
fi

# =============================================================================
# DONE
# =============================================================================
clear
echo -e "${BLD}${GRN}"
cat << DONE
  ╔══════════════════════════════════════════════════════════════╗
  ║        NUKE LICENSE DASHBOARD — Installation Complete        ║
  ╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${RST}"

echo -e "  ${BLD}Access your services:${RST}"
echo -e "  ${GRN}●${RST}  ${BLD}Grafana Dashboard  →  http://${SERVER_IP}:${PORT_GRAFANA}${RST}  (admin / ${GRAFANA_PASS})"
echo -e "  ${BLU}●${RST}  Prometheus         →  http://${SERVER_IP}:${PORT_PROM}"
echo -e "  ${YLW}●${RST}  License Exporter   →  http://${SERVER_IP}:${PORT_EXPORTER}/metrics"
echo ""
if [[ -n "$PUBLIC_URL" ]]; then
echo -e "  ${BLD}${GRN}Public dashboard (no login needed):${RST}"
echo -e "  ${GRN}●${RST}  ${BLD}${PUBLIC_URL}${RST}"
echo ""
fi
echo -e "  ${BLD}Config file:${RST}  ${INSTALL_DIR}/config/exporter.env"
echo ""
echo -e "  ${BLD}Useful commands:${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose logs -f nuke-exporter${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose restart${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose down${RST}"
echo ""
