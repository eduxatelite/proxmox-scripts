#!/usr/bin/env bash
# =============================================================================
#  Deadline Farm Monitor — Docker Installer
#  Works on any Linux distro with or without Docker pre-installed.
#  Installs: Docker (if needed) · Prometheus · Deadline Exporter · Grafana
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/deadline/install.sh)
#
#  github.com/eduxatelite/proxmox-scripts
# =============================================================================
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✔${RST}  $*"; }
info() { echo -e "  ${BLU}→${RST}  $*"; }
warn() { echo -e "  ${YLW}⚠${RST}  $*"; }
err()  { echo -e "  ${RED}✘${RST}  $*"; }
step() { echo -e "\n${BLD}${CYN}══ $* ${RST}"; }
die()  { err "$*"; exit 1; }

spinner() {
  local pid=$! chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${BLU}%s${RST}  %s " "${chars:$((i%10)):1}" "$1"
    ((i++)); sleep 0.1
  done
  printf "\r"
}

# ── whiptail helpers ──────────────────────────────────────────────────────────
WT_H=18; WT_W=68

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

# ── install whiptail if missing ───────────────────────────────────────────────
ensure_whiptail() {
  command -v whiptail &>/dev/null && return
  info "Installing whiptail…"
  if   is_debian_based; then apt-get install -y whiptail &>/dev/null
  elif is_rhel_based;   then (dnf install -y newt || yum install -y newt) &>/dev/null
  fi
}

# ── install curl if missing ───────────────────────────────────────────────────
ensure_curl() {
  command -v curl &>/dev/null && return
  info "Installing curl…"
  if   is_debian_based; then apt-get install -y curl &>/dev/null
  elif is_rhel_based;   then (dnf install -y curl || yum install -y curl) &>/dev/null
  fi
}

# =============================================================================
# STEP 0 — Welcome
# =============================================================================
clear
echo -e "${BLD}${CYN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║         DEADLINE FARM MONITOR — Docker Installer            ║
  ║         github.com/eduxatelite/proxmox-scripts              ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

detect_distro
ensure_curl
ensure_whiptail

wt_msg "Deadline Farm Monitor" \
"Welcome to the Deadline Farm Monitor installer.

This script will:

  1. Install Docker (if not already installed)
  2. Deploy Prometheus, Grafana & Deadline Exporter
  3. Connect to your existing Deadline Web Service

Your Deadline installation is NOT modified.

Press OK to continue."

# =============================================================================
# STEP 1 — Install Docker
# =============================================================================
step "Checking Docker"

install_docker_debian() {
  info "Installing Docker on Debian/Ubuntu…"
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release &>/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/"${DISTRO}"/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>/dev/null
}

install_docker_rhel() {
  info "Installing Docker on RHEL/Rocky/CentOS…"
  if command -v dnf &>/dev/null; then
    dnf install -y yum-utils &>/dev/null
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &>/dev/null
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>/dev/null
  else
    yum install -y yum-utils &>/dev/null
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &>/dev/null
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>/dev/null
  fi
}

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  ok "Docker already installed (${DOCKER_VER})"
else
  wt_msg "Docker Not Found" \
"Docker is not installed on this system.

The installer will now install Docker automatically.
This requires an internet connection.

Distribution detected: ${DISTRO}

Press OK to install Docker."

  step "Installing Docker"
  if is_debian_based; then
    install_docker_debian &
  elif is_rhel_based; then
    install_docker_rhel &
  else
    die "Unsupported distribution: ${DISTRO}. Please install Docker manually: https://docs.docker.com/engine/install/"
  fi
  spinner "Installing Docker…"
  wait $!

  systemctl enable docker &>/dev/null
  systemctl start docker
  ok "Docker installed successfully"
fi

# Ensure Docker Compose plugin works
if ! docker compose version &>/dev/null; then
  die "Docker Compose plugin not found. Please install it manually: https://docs.docker.com/compose/install/"
fi
ok "Docker Compose available"

# =============================================================================
# STEP 2 — Studio branding
# =============================================================================
step "Studio Configuration"

wt_input STUDIO_NAME "Studio Name" \
  "Enter your studio name (shown in the dashboard header):" \
  "My Studio"

wt_input INSTALL_DIR "Install Directory" \
  "Where should the monitor be installed?" \
  "/opt/deadline-monitor"

# =============================================================================
# STEP 3 — Grafana admin password
# =============================================================================
step "Grafana Credentials"

wt_msg "Grafana Admin Password" \
"You will now set the Grafana admin password.

This is used to log into the Grafana web interface.
Username will be: admin"

wt_password GRAFANA_PASS "Grafana Admin Password" \
  "Enter a password for the Grafana admin user:"

[[ -z "$GRAFANA_PASS" ]] && GRAFANA_PASS="deadlinemonitor"

# =============================================================================
# STEP 4 — Deadline Web Service connection
# =============================================================================
step "Deadline Web Service"

wt_msg "Deadline Web Service" \
"Now we need to connect to your Deadline Web Service.

Make sure it is enabled in Deadline Monitor:
  Tools → Configure Web Service → Enable Web Service

You will need:
  • IP or hostname of the Deadline Repository server
  • Port (default: 8081)
  • API Key (if authentication is enabled)"

wt_input DL_HOST "Deadline Web Service" \
  "Enter the IP or hostname of your Deadline server:" \
  "192.168.1.100"

wt_input DL_PORT "Deadline Web Service" \
  "Enter the Web Service port:" \
  "8081"

# Check auth
DL_APIKEY=""
if wt_yesno "Deadline Authentication" \
  "Does your Deadline Web Service have authentication enabled?\n\n(Tools → Configure Web Service → Authentication)"; then

  wt_msg "Find your API Key" \
"To find your API Key in Deadline Monitor:

  Tools
  └─ Configure Web Service
     └─ Authentication
        └─ API Keys → Generate / Copy

Paste it on the next screen."

  wt_password DL_APIKEY "Deadline API Key" \
    "Paste your Deadline API Key:"
fi

# Test connection
step "Testing Deadline Connection"
info "Connecting to ${DL_HOST}:${DL_PORT}…"

HTTP_CODE=$(curl -s -o /tmp/dl_test.json -w "%{http_code}" \
  --max-time 10 \
  ${DL_APIKEY:+-H "X-Thinkbox-DeadlineWebAPI-Password: ${DL_APIKEY}"} \
  "http://${DL_HOST}:${DL_PORT}/api/slaves" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
  200)
    WORKER_COUNT=$(python3 -c "import json,sys; d=json.load(open('/tmp/dl_test.json')); print(len(d))" 2>/dev/null || echo "?")
    ok "Connected! Workers detected: ${WORKER_COUNT}"
    wt_msg "Connection Successful" \
"✔  Successfully connected to Deadline Web Service!

  Host    : ${DL_HOST}:${DL_PORT}
  Workers : ${WORKER_COUNT}

Press OK to continue with the installation."
    ;;
  401|403)
    warn "Authentication error (HTTP ${HTTP_CODE})"
    wt_msg "Authentication Error" \
"Could not authenticate with the Deadline Web Service.

  Error: HTTP ${HTTP_CODE} — Invalid or missing API Key.

Please check:
  • The API Key is correct
  • Authentication is enabled in Deadline Monitor

The installer will continue but the exporter may not
collect data until the API Key is corrected in:
  ${INSTALL_DIR}/config/exporter.env"
    ;;
  000)
    warn "Cannot reach ${DL_HOST}:${DL_PORT}"
    wt_msg "Connection Failed" \
"Could not reach the Deadline Web Service at:
  ${DL_HOST}:${DL_PORT}

Please check:
  • The IP address is correct
  • Port 8081 is open in the firewall
  • The Web Service is running in Deadline Monitor
  • This machine can reach the Deadline server

The installer will continue. You can update the
connection settings later in:
  ${INSTALL_DIR}/config/exporter.env"
    ;;
  *)
    warn "Unexpected response: HTTP ${HTTP_CODE}"
    wt_msg "Unexpected Response" \
"Received HTTP ${HTTP_CODE} from the Deadline Web Service.

The installer will continue. Check the connection
settings later in:
  ${INSTALL_DIR}/config/exporter.env"
    ;;
esac

# =============================================================================
# STEP 5 — Ports
# =============================================================================
step "Port Configuration"

wt_input PORT_DASHBOARD "Ports" "Deadline Dashboard port (main UI):" "8080"
wt_input PORT_GRAFANA  "Ports" "Grafana port (metrics/graphs):"    "3000"
wt_input PORT_PROM     "Ports" "Prometheus port:"                  "9090"
wt_input PORT_EXPORTER "Ports" "Deadline Exporter port:"           "9100"

# =============================================================================
# STEP 6 — Summary
# =============================================================================
wt_msg "Ready to Install" \
"Installation Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Studio name    : ${STUDIO_NAME}
  Install dir    : ${INSTALL_DIR}
  Deadline host  : ${DL_HOST}:${DL_PORT}
  Auth           : ${DL_APIKEY:+Enabled}${DL_APIKEY:-Disabled}
  Dashboard port : ${PORT_DASHBOARD}
  Grafana port   : ${PORT_GRAFANA}
  Prometheus port: ${PORT_PROM}
  Exporter port  : ${PORT_EXPORTER}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press OK to start the installation."

# =============================================================================
# STEP 7 — Deploy
# =============================================================================
step "Deploying Deadline Farm Monitor"

REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/deadline"

# Create directory structure
mkdir -p "${INSTALL_DIR}"/{config,prometheus,grafana/provisioning/{datasources,dashboards}}

# ── exporter config ───────────────────────────────────────────────────────────
info "Writing configuration…"
cat > "${INSTALL_DIR}/config/exporter.env" <<EOF
DEADLINE_HOST=${DL_HOST}
DEADLINE_PORT=${DL_PORT}
DEADLINE_APIKEY=${DL_APIKEY}
EXPORTER_PORT=${PORT_EXPORTER}
EOF
chmod 600 "${INSTALL_DIR}/config/exporter.env"

# ── prometheus config ─────────────────────────────────────────────────────────
cat > "${INSTALL_DIR}/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'deadline_exporter'
    static_configs:
      - targets: ['deadline-exporter:${PORT_EXPORTER}']
EOF

# ── grafana datasource ────────────────────────────────────────────────────────
cat > "${INSTALL_DIR}/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:${PORT_PROM}
    isDefault: true
EOF

# ── download source files ─────────────────────────────────────────────────────
info "Downloading source files…"
curl -fsSL "${REPO_RAW}/deadline_exporter.py"   -o "${INSTALL_DIR}/deadline_exporter.py"   || die "Failed to download deadline_exporter.py"
curl -fsSL "${REPO_RAW}/deadline_proxy.py"      -o "${INSTALL_DIR}/deadline_proxy.py"      || die "Failed to download deadline_proxy.py"
curl -fsSL "${REPO_RAW}/deadline_dashboard.jsx" -o "${INSTALL_DIR}/deadline_dashboard.jsx" || die "Failed to download deadline_dashboard.jsx"
curl -fsSL "${REPO_RAW}/Dockerfile.dashboard"   -o "${INSTALL_DIR}/Dockerfile.dashboard"   || die "Failed to download Dockerfile.dashboard"
ok "Source files downloaded"

# ── Dockerfile for exporter ───────────────────────────────────────────────────
cat > "${INSTALL_DIR}/Dockerfile.exporter" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir prometheus-client requests
COPY deadline_exporter.py .
CMD ["python", "deadline_exporter.py"]
EOF

# ── docker-compose.yml ────────────────────────────────────────────────────────
info "Writing docker-compose.yml…"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:

  # ── Main interactive dashboard (React + proxy) ──────────────────────────────
  deadline-dashboard:
    build:
      context: .
      dockerfile: Dockerfile.dashboard
    container_name: deadline-dashboard
    restart: unless-stopped
    env_file: config/exporter.env
    environment:
      - PROXY_PORT=${PORT_DASHBOARD}
    ports:
      - "${PORT_DASHBOARD}:${PORT_DASHBOARD}"
    networks:
      - monitor

  # ── Prometheus exporter (reads Deadline API → exposes metrics) ──────────────
  deadline-exporter:
    build:
      context: .
      dockerfile: Dockerfile.exporter
    container_name: deadline-exporter
    restart: unless-stopped
    env_file: config/exporter.env
    ports:
      - "${PORT_EXPORTER}:${PORT_EXPORTER}"
    networks:
      - monitor

  # ── Prometheus (stores metrics history) ────────────────────────────────────
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "${PORT_PROM}:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
    networks:
      - monitor

  # ── Grafana (graphs / alerts / historical data) ─────────────────────────────
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "${PORT_GRAFANA}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_ROOT_URL=http://localhost:${PORT_GRAFANA}
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana_data:/var/lib/grafana
    networks:
      - monitor

volumes:
  prometheus_data:
  grafana_data:

networks:
  monitor:
    driver: bridge
EOF

# ── build & start ─────────────────────────────────────────────────────────────
step "Starting containers"
cd "${INSTALL_DIR}"

info "Building exporter image…"
docker compose build --quiet &
spinner "Building Deadline Exporter image…"
wait $!
ok "Image built"

info "Starting services…"
docker compose up -d &
spinner "Starting all services…"
wait $!
ok "All containers running"

# ── verify ────────────────────────────────────────────────────────────────────
sleep 3
RUNNING=$(docker compose ps --status running --format json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "?")
ok "Containers running: ${RUNNING}/4"

# ── detect server IP ──────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

# =============================================================================
# DONE
# =============================================================================
clear
echo -e "${BLD}${GRN}"
cat << DONE
  ╔══════════════════════════════════════════════════════════════╗
  ║          DEADLINE FARM MONITOR — Installation Complete       ║
  ╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${RST}"

echo -e "  ${BLD}Access your services:${RST}"
echo -e "  ${GRN}●${RST}  ${BLD}Deadline Dashboard →  http://${SERVER_IP}:${PORT_DASHBOARD}${RST}  ← main UI (workers, jobs, actions)"
echo -e "  ${BLU}●${RST}  Grafana (graphs)   →  http://${SERVER_IP}:${PORT_GRAFANA}  (admin / ${GRAFANA_PASS})"
echo -e "  ${BLU}●${RST}  Prometheus         →  http://${SERVER_IP}:${PORT_PROM}"
echo -e "  ${YLW}●${RST}  Deadline Exporter  →  http://${SERVER_IP}:${PORT_EXPORTER}/metrics"
echo ""
echo -e "  ${BLD}Useful commands:${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose logs -f${RST}   (live logs)"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose restart${RST}   (restart all)"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose down${RST}      (stop all)"
echo ""
echo -e "  ${BLD}Config file:${RST}  ${INSTALL_DIR}/config/exporter.env"
echo ""
echo -e "  ${YLW}If Grafana shows no data, make sure the Deadline Web Service${RST}"
echo -e "  ${YLW}is running and reachable from this machine.${RST}"
echo ""
