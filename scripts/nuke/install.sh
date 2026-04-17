#!/usr/bin/env bash
# =============================================================================
#  Nuke License Dashboard — Docker Installer
#  Monitors Foundry / RLM license usage via Prometheus + Grafana.
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

ensure_whiptail() {
  command -v whiptail &>/dev/null && return
  info "Installing whiptail…"
  if   is_debian_based; then apt-get install -y whiptail &>/dev/null
  elif is_rhel_based;   then (dnf install -y newt || yum install -y newt) &>/dev/null
  fi
}

ensure_curl() {
  command -v curl &>/dev/null && return
  info "Installing curl…"
  if   is_debian_based; then apt-get install -y curl &>/dev/null
  elif is_rhel_based;   then (dnf install -y curl || yum install -y curl) &>/dev/null
  fi
}

install_docker_rhel() {
  info "Installing Docker on RHEL/Rocky/CentOS…"
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
  info "Installing Docker on Debian/Ubuntu…"
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
  2. Deploy a Prometheus exporter for Foundry / RLM licenses
  3. Deploy Grafana with the Nuke license dashboard pre-loaded

Your RLM license server is NOT modified.
This installer only reads license data (read-only).

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

The installer will now install Docker automatically.
This requires an internet connection.

Distribution detected: ${DISTRO}

Press OK to install Docker."

  step "Installing Docker"
  echo "" > /tmp/docker-install.log

  if   is_debian_based; then install_docker_debian
  elif is_rhel_based;   then install_docker_rhel
  else die "Unsupported distribution: ${DISTRO}. Please install Docker manually."; fi

  if ! command -v docker &>/dev/null; then
    err "Docker installation failed. Check /tmp/docker-install.log"
    die "Run: cat /tmp/docker-install.log"
  fi

  systemctl enable docker >> /tmp/docker-install.log 2>&1 || true
  systemctl start docker  || die "Failed to start Docker."
  ok "Docker installed successfully"
fi

if ! docker compose version &>/dev/null; then
  die "Docker Compose plugin not found. Please install it: https://docs.docker.com/compose/install/"
fi
ok "Docker Compose available"

# =============================================================================
# STEP 2 — Studio + install directory
# =============================================================================
step "Studio Configuration"

wt_input STUDIO_NAME "Studio Name" \
  "Enter your studio name (shown in Grafana):" \
  "My Studio"

wt_input INSTALL_DIR "Install Directory" \
  "Where should the dashboard be installed?" \
  "/opt/nuke-licenses"

# =============================================================================
# STEP 3 — Grafana password
# =============================================================================
step "Grafana Credentials"

wt_password GRAFANA_PASS "Grafana Admin Password" \
  "Set a password for the Grafana admin user:"

[[ -z "$GRAFANA_PASS" ]] && GRAFANA_PASS="nukedashboard"

# =============================================================================
# STEP 4 — RLM License Server
# =============================================================================
step "RLM License Server"

wt_msg "RLM License Server" \
"Now we need to connect to your Foundry / RLM license server.

You will need:
  • IP or hostname of the license server
  • RLM web interface port (default: 5054)
  • ISV name (almost always: foundry)

The RLM web interface must be accessible from this machine.
It is usually enabled by default on port 5054."

wt_input RLM_HOST "RLM License Server" \
  "Enter the IP or hostname of your RLM license server:" \
  "192.168.1.100"

wt_input RLM_WEB_PORT "RLM License Server" \
  "Enter the RLM web interface port:\n(Foundry default is 4102. Check your browser URL when opening the RLM admin page.)" \
  "4102"

wt_input RLM_ISV "RLM License Server" \
  "Enter the ISV name (usually 'foundry' for Nuke):" \
  "foundry"

# ── Test connection ────────────────────────────────────────────────────────────
step "Testing RLM Connection"
info "Connecting to http://${RLM_HOST}:${RLM_WEB_PORT}…"

HTTP_CODE=$(curl -s -o /tmp/rlm_test.html -w "%{http_code}" \
  --max-time 10 \
  "http://${RLM_HOST}:${RLM_WEB_PORT}/rlmstat?isv=${RLM_ISV}&stats=1" \
  2>/dev/null || echo "000")

case "$HTTP_CODE" in
  200)
    # Try to count products from response
    PRODUCTS=$(grep -oE '[a-z_]+ v[0-9]+\.[0-9]+' /tmp/rlm_test.html 2>/dev/null | wc -l || echo "?")
    ok "Connected to RLM server!"
    wt_msg "Connection Successful" \
"✔  Successfully connected to RLM web interface!

  Host    : ${RLM_HOST}:${RLM_WEB_PORT}
  ISV     : ${RLM_ISV}
  Products: ${PRODUCTS} detected

Press OK to continue with the installation."
    ;;
  000)
    warn "Cannot reach http://${RLM_HOST}:${RLM_WEB_PORT}"
    wt_msg "Connection Failed" \
"Could not reach the RLM web interface at:
  http://${RLM_HOST}:${RLM_WEB_PORT}

Please check:
  • The IP address / hostname is correct
  • Port ${RLM_WEB_PORT} is open in the firewall
  • The RLM server is running
  • The RLM web interface is enabled (it usually is by default)

The installer will continue. You can update the connection
settings later in:
  ${INSTALL_DIR}/config/exporter.env"
    ;;
  *)
    warn "Unexpected HTTP ${HTTP_CODE} from RLM server"
    wt_msg "Unexpected Response" \
"Received HTTP ${HTTP_CODE} from the RLM server.

Installation will continue. Check connection settings later in:
  ${INSTALL_DIR}/config/exporter.env"
    ;;
esac

# =============================================================================
# STEP 5 — Ports
# =============================================================================
step "Port Configuration"

wt_input PORT_GRAFANA   "Ports" "Grafana port (web UI):"        "3001"
wt_input PORT_PROM      "Ports" "Prometheus port:"              "9091"
wt_input PORT_EXPORTER  "Ports" "License exporter port:"        "9200"

# =============================================================================
# STEP 6 — Summary
# =============================================================================
wt_msg "Ready to Install" \
"Installation Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Studio name    : ${STUDIO_NAME}
  Install dir    : ${INSTALL_DIR}
  RLM server     : ${RLM_HOST}:${RLM_WEB_PORT}
  ISV            : ${RLM_ISV}
  Grafana port   : ${PORT_GRAFANA}
  Prometheus port: ${PORT_PROM}
  Exporter port  : ${PORT_EXPORTER}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press OK to start the installation."

# =============================================================================
# STEP 7 — Deploy
# =============================================================================
step "Deploying Nuke License Dashboard"

REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/nuke"

# Create directory structure
mkdir -p "${INSTALL_DIR}"/{config,prometheus,grafana/provisioning/{datasources,dashboards},grafana/dashboards}

# ── exporter config ───────────────────────────────────────────────────────────
info "Writing configuration…"
cat > "${INSTALL_DIR}/config/exporter.env" <<EOF
RLM_HOST=${RLM_HOST}
RLM_WEB_PORT=${RLM_WEB_PORT}
RLM_ISV=${RLM_ISV}
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

# ── grafana datasource ────────────────────────────────────────────────────────
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

# ── grafana dashboard provider ────────────────────────────────────────────────
cat > "${INSTALL_DIR}/grafana/provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1
providers:
  - name: Nuke Licenses
    orgId: 1
    folder: Nuke
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

# ── download source files ─────────────────────────────────────────────────────
info "Downloading source files…"
curl -fsSL "${REPO_RAW}/nuke_exporter.py"            -o "${INSTALL_DIR}/nuke_exporter.py"           || die "Failed to download nuke_exporter.py"
curl -fsSL "${REPO_RAW}/Dockerfile"                  -o "${INSTALL_DIR}/Dockerfile"                 || die "Failed to download Dockerfile"
curl -fsSL "${REPO_RAW}/grafana_nuke_dashboard.json" -o "${INSTALL_DIR}/grafana/dashboards/nuke.json" || die "Failed to download dashboard JSON"
ok "Source files downloaded"

# ── docker-compose.yml ────────────────────────────────────────────────────────
info "Writing docker-compose.yml…"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:

  # ── Nuke License Exporter (reads RLM → exposes Prometheus metrics) ──────────
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

  # ── Prometheus (stores metrics history) ────────────────────────────────────
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

  # ── Grafana (Nuke license dashboard) ───────────────────────────────────────
  grafana:
    image: grafana/grafana:latest
    container_name: nuke-grafana
    restart: unless-stopped
    ports:
      - "${PORT_GRAFANA}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_ROOT_URL=http://localhost:${PORT_GRAFANA}
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/nuke.json
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
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
  err "Docker build failed. Last 20 lines of log:"
  tail -20 /tmp/nuke-build.log
  die "Fix the error above, then re-run the installer."
fi
ok "Image built"

info "Starting all services…"
if ! docker compose up -d > /tmp/nuke-up.log 2>&1; then
  err "Failed to start containers. Last 20 lines of log:"
  tail -20 /tmp/nuke-up.log
  die "Fix the error above, then run: cd ${INSTALL_DIR} && docker compose up -d"
fi
ok "All containers started"

sleep 4
SERVER_IP=$(hostname -I | awk '{print $1}')

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
echo -e "  The Nuke license dashboard loads automatically when you log into Grafana."
echo ""
echo -e "  ${BLD}Useful commands:${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose logs -f nuke-exporter${RST}   (live logs)"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose restart${RST}                 (restart all)"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose down${RST}                    (stop all)"
echo ""
echo -e "  ${BLD}Config file:${RST}  ${INSTALL_DIR}/config/exporter.env"
echo ""
echo -e "  ${YLW}If Grafana shows no data, make sure the RLM web interface${RST}"
echo -e "  ${YLW}is reachable from this machine on port ${RLM_WEB_PORT}.${RST}"
echo ""
