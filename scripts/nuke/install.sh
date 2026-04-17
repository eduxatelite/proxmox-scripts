#!/usr/bin/env bash
# =============================================================================
#  Nuke License Dashboard — Docker Installer
#  Monitors Foundry / RLM license usage via SSH + rlmutil → Prometheus + Grafana
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
  2. Generate an SSH key to connect to your RLM license server
  3. Guide you through authorising that key on the server
  4. Deploy Prometheus + Grafana with the Nuke dashboard pre-loaded

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

wt_msg "RLM License Server" \
"Now we need the details of your Foundry RLM license server.

You will need:
  • IP or hostname of the license server
  • SSH user (usually root)
  • RLM license port — this is the port shown on the RLM web
    admin page next to the 'rlm' entry (usually 4101 or 4102)

The installer will generate an SSH key and guide you through
authorising it on the license server.

Press OK to continue."

wt_input RLM_HOST "RLM License Server" \
  "Enter the IP or hostname of your RLM license server:" \
  "192.168.1.100"

wt_input RLM_SSH_USER "RLM License Server" \
  "SSH user on the license server:" \
  "root"

wt_input RLM_PORT "RLM License Server" \
  "RLM license port (shown in the RLM web admin page next to 'rlm'):" \
  "4101"

# =============================================================================
# STEP 4 — SSH key setup
# =============================================================================
step "SSH Key Setup"

KEY_DIR="${INSTALL_DIR}/config"
KEY_PATH="${KEY_DIR}/id_nuke_rlm"
mkdir -p "$KEY_DIR"

if [[ -f "$KEY_PATH" ]]; then
  info "SSH key already exists at ${KEY_PATH}"
else
  info "Generating SSH key…"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "nuke-license-exporter" \
    || die "Failed to generate SSH key"
  ok "SSH key generated"
fi

chmod 600 "$KEY_PATH"
PUB_KEY=$(cat "${KEY_PATH}.pub")

wt_msg "Authorise SSH Key" \
"An SSH key has been generated. You must now copy it to
the license server so the exporter can connect without a password.

Run this command FROM ANOTHER TERMINAL on this machine:

  ssh-copy-id -i ${KEY_PATH}.pub ${RLM_SSH_USER}@${RLM_HOST}

Or manually add this line to ${RLM_SSH_USER}@${RLM_HOST}:~/.ssh/authorized_keys:

  ${PUB_KEY}

Press OK once you have authorised the key."

# ── Test SSH connection ────────────────────────────────────────────────────────
step "Testing SSH Connection"
info "Connecting to ${RLM_SSH_USER}@${RLM_HOST}…"

SSH_TEST=$(ssh \
  -i "$KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  -o BatchMode=yes \
  "${RLM_SSH_USER}@${RLM_HOST}" \
  "echo OK" 2>&1 || true)

if [[ "$SSH_TEST" == "OK" ]]; then
  ok "SSH connection successful"
else
  warn "SSH connection failed: ${SSH_TEST}"
  wt_msg "SSH Connection Failed" \
"Could not connect via SSH to:
  ${RLM_SSH_USER}@${RLM_HOST}

Error: ${SSH_TEST}

Please make sure you have:
  1. Added the public key to ~/.ssh/authorized_keys on the server
  2. The server is reachable from this machine
  3. The SSH user is correct

The installer will continue. You can fix SSH access later —
the exporter will retry automatically on each scrape.

Check connection manually with:
  ssh -i ${KEY_PATH} ${RLM_SSH_USER}@${RLM_HOST} 'echo OK'"
fi

# ── Auto-detect rlmutil ────────────────────────────────────────────────────────
RLMUTIL_PATH=""
if [[ "$SSH_TEST" == "OK" ]]; then
  step "Detecting rlmutil"
  info "Searching for rlmutil on the license server…"

  for CANDIDATE in \
    "/opt/FoundryLicensingUtility/bin/rlmutil" \
    "/usr/local/foundry/LicensingTools8.0/bin/RLM/rlmutil"; do

    FOUND=$(ssh \
      -i "$KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${RLM_SSH_USER}@${RLM_HOST}" \
      "test -x ${CANDIDATE} && echo FOUND || echo NOTFOUND" 2>/dev/null || echo "NOTFOUND")

    if [[ "$FOUND" == "FOUND" ]]; then
      RLMUTIL_PATH="$CANDIDATE"
      ok "rlmutil found at: ${RLMUTIL_PATH}"
      break
    fi
  done

  if [[ -z "$RLMUTIL_PATH" ]]; then
    warn "rlmutil not found in known locations — will auto-detect at runtime"
    wt_msg "rlmutil Not Found" \
"Could not find rlmutil in the standard locations:

  /opt/FoundryLicensingUtility/bin/rlmutil
  /usr/local/foundry/LicensingTools8.0/bin/RLM/rlmutil

The exporter will try to auto-detect it at runtime.
If it still fails, set RLMUTIL_PATH in:
  ${INSTALL_DIR}/config/exporter.env"
  fi

  # Quick license test
  if [[ -n "$RLMUTIL_PATH" ]]; then
    info "Running test: ${RLMUTIL_PATH} rlmstat -a -c ${RLM_PORT}@localhost"
    TEST_OUT=$(ssh \
      -i "$KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${RLM_SSH_USER}@${RLM_HOST}" \
      "${RLMUTIL_PATH} rlmstat -a -c ${RLM_PORT}@localhost" 2>/dev/null | head -5 || true)

    if echo "$TEST_OUT" | grep -qi "license\|rlm\|foundry"; then
      ok "rlmutil responding — license data looks good"
    else
      warn "rlmutil ran but output looks unexpected — check manually"
    fi
  fi
fi

# =============================================================================
# STEP 5 — Ports
# =============================================================================
step "Port Configuration"

wt_input PORT_GRAFANA   "Ports" "Grafana port (web UI):"     "3001"
wt_input PORT_PROM      "Ports" "Prometheus port:"           "9091"
wt_input PORT_EXPORTER  "Ports" "License exporter port:"     "9200"

# =============================================================================
# STEP 6 — Summary
# =============================================================================
wt_msg "Ready to Install" \
"Installation Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Studio          : ${STUDIO_NAME}
  Install dir     : ${INSTALL_DIR}
  RLM server      : ${RLM_SSH_USER}@${RLM_HOST} (port ${RLM_PORT})
  rlmutil         : ${RLMUTIL_PATH:-auto-detect}
  Grafana port    : ${PORT_GRAFANA}
  Prometheus port : ${PORT_PROM}
  Exporter port   : ${PORT_EXPORTER}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press OK to start the installation."

# =============================================================================
# STEP 7 — Deploy
# =============================================================================
step "Deploying Nuke License Dashboard"

REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/nuke"

mkdir -p "${INSTALL_DIR}"/{config,prometheus,grafana/provisioning/{datasources,dashboards},grafana/dashboards}

# Copy SSH key to config dir (already there, just set perms)
chmod 600 "${KEY_PATH}"

# ── exporter config ───────────────────────────────────────────────────────────
info "Writing configuration…"
cat > "${INSTALL_DIR}/config/exporter.env" <<EOF
RLM_HOST=${RLM_HOST}
RLM_PORT=${RLM_PORT}
RLM_SSH_USER=${RLM_SSH_USER}
RLM_SSH_KEY=/config/id_nuke_rlm
RLMUTIL_PATH=${RLMUTIL_PATH}
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

# ── grafana provisioning ──────────────────────────────────────────────────────
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
curl -fsSL "${REPO_RAW}/nuke_exporter.py"            -o "${INSTALL_DIR}/nuke_exporter.py"              || die "Failed to download nuke_exporter.py"
curl -fsSL "${REPO_RAW}/Dockerfile"                  -o "${INSTALL_DIR}/Dockerfile"                    || die "Failed to download Dockerfile"
curl -fsSL "${REPO_RAW}/grafana_nuke_dashboard.json" -o "${INSTALL_DIR}/grafana/dashboards/nuke.json"  || die "Failed to download dashboard JSON"
ok "Source files downloaded"

# ── docker-compose.yml ────────────────────────────────────────────────────────
info "Writing docker-compose.yml…"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:

  # ── Nuke License Exporter (SSH → rlmutil → Prometheus metrics) ─────────────
  nuke-exporter:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: nuke-exporter
    restart: unless-stopped
    env_file: config/exporter.env
    volumes:
      - ./config:/config:ro          # SSH key + exporter.env
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
echo -e "  ${BLD}SSH key location:${RST}  ${KEY_PATH}"
echo -e "  ${BLD}Config file:${RST}       ${INSTALL_DIR}/config/exporter.env"
echo ""
echo -e "  ${BLD}Useful commands:${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose logs -f nuke-exporter${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose restart${RST}"
echo -e "  ${CYN}cd ${INSTALL_DIR} && docker compose down${RST}"
echo ""
echo -e "  ${YLW}If the exporter shows errors, verify SSH access:${RST}"
echo -e "  ${CYN}ssh -i ${KEY_PATH} ${RLM_SSH_USER}@${RLM_HOST} '${RLMUTIL_PATH:-rlmutil} rlmstat -a -c ${RLM_PORT}@localhost'${RST}"
echo ""
