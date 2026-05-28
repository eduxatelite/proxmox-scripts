#!/usr/bin/env bash
# =============================================================================
#  Grafana Stack Installer
#  Installs: Grafana + Prometheus + Loki + Promtail (Docker Compose)
#  Optional: FortiGate dashboard | Proxmox dashboard | node_exporter
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/grafana-stack/install.sh)
#
#  github.com/eduxatelite/proxmox-scripts
# =============================================================================
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $*"; }
info()    { echo -e "${BLUE}[i]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }
ask()     { echo -e "${YELLOW}[?]${NC} $*"; }

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local yn
  while true; do
    if [[ "$default" == "y" ]]; then
      ask "$prompt [Y/n]: "
    else
      ask "$prompt [y/N]: "
    fi
    read -r yn
    yn="${yn:-$default}"
    case "${yn,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    ask "$prompt_text [default: $default]: "
  else
    ask "$prompt_text: "
  fi
  read -r value
  value="${value:-$default}"
  eval "$var_name='$value'"
}

# ─── State ───────────────────────────────────────────────────────────────────
INSTALL_FORTIGATE=false
INSTALL_PROXMOX=false
INSTALL_NODE_EXPORTER=false
PROXMOX_NODES=()   # "alias|host|port|user|password|verify_ssl"
REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/grafana-stack"

# When run via bash <(curl ...), BASH_SOURCE[0] is /dev/fd/XX — create install dir and download files
if [[ "${BASH_SOURCE[0]}" == "/dev/fd/"* ]] || [[ "${BASH_SOURCE[0]}" == "bash" ]]; then
  INSTALL_DIR="/opt/grafana-stack"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  SCRIPT_DIR="$INSTALL_DIR"

  info "Downloading project files from GitHub..."
  # Config files
  mkdir -p config/prometheus config/loki config/promtail \
           config/grafana/provisioning/datasources \
           config/grafana/provisioning/dashboards \
           dashboards/fortigate dashboards/proxmox

  curl -fsSL "$REPO_RAW/docker-compose.yml"                                              -o docker-compose.yml
  curl -fsSL "$REPO_RAW/config/prometheus/prometheus.yml"                                -o config/prometheus/prometheus.yml
  curl -fsSL "$REPO_RAW/config/loki/loki-config.yml"                                    -o config/loki/loki-config.yml
  curl -fsSL "$REPO_RAW/config/promtail/promtail-config.yml"                             -o config/promtail/promtail-config.yml
  curl -fsSL "$REPO_RAW/config/grafana/provisioning/datasources/datasources.yml"         -o config/grafana/provisioning/datasources/datasources.yml
  curl -fsSL "$REPO_RAW/config/grafana/provisioning/dashboards/dashboards.yml"           -o config/grafana/provisioning/dashboards/dashboards.yml
  curl -fsSL "$REPO_RAW/dashboards/fortigate/fortigate.json"                             -o dashboards/fortigate/fortigate.json
  curl -fsSL "$REPO_RAW/dashboards/proxmox/proxmox.json"                                 -o dashboards/proxmox/proxmox.json
  log "Files downloaded."
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ─── Banner ──────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ╔═══════════════════════════════════════════╗
  ║         Grafana Stack Installer           ║
  ║   Grafana · Prometheus · Loki · Promtail  ║
  ╚═══════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo -e "  This script will install a full monitoring stack using Docker."
echo -e "  You can optionally enable dashboards for FortiGate and Proxmox.\n"

# ─── Root check ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Please run this script as root or with sudo."
fi

# ─── Detect OS ───────────────────────────────────────────────────────────────
section "Detecting Operating System"
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS_ID="${ID}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VERSION="${VERSION_ID:-}"
  info "Detected: ${PRETTY_NAME}"
else
  error "Cannot detect OS. /etc/os-release not found."
fi

# ─── Install Docker ──────────────────────────────────────────────────────────
section "Docker"
install_docker() {
  info "Installing Docker..."
  case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${OS_ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf &>/dev/null; then
        dnf -y -q install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      else
        yum -y -q install yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      fi
      ;;
    opensuse*|sles)
      zypper -q install -y docker docker-compose
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm docker docker-compose
      ;;
    *)
      if [[ "${OS_LIKE}" =~ "debian" ]]; then
        apt-get update -qq && apt-get install -y -qq docker.io docker-compose-v2
      elif [[ "${OS_LIKE}" =~ "rhel" ]] || [[ "${OS_LIKE}" =~ "fedora" ]]; then
        dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin \
          || yum -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      else
        info "Unknown distro — trying get.docker.com script..."
        curl -fsSL https://get.docker.com | sh
      fi
      ;;
  esac
  systemctl enable --now docker
  log "Docker installed and started."
}

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version)
  log "Docker already installed: $DOCKER_VER"
else
  install_docker
fi

# Docker Compose check (plugin or standalone)
if docker compose version &>/dev/null 2>&1; then
  log "Docker Compose plugin available."
  DC="docker compose"
elif command -v docker-compose &>/dev/null; then
  log "docker-compose (standalone) available."
  DC="docker-compose"
else
  info "Installing Docker Compose plugin..."
  COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  DC="docker-compose"
  log "Docker Compose installed."
fi

# ─── Basic configuration ─────────────────────────────────────────────────────
section "Basic Configuration"

prompt GRAFANA_PORT      "Grafana port"          "3000"
prompt GRAFANA_USER      "Grafana admin username" "admin"
prompt GRAFANA_PASSWORD  "Grafana admin password" "changeme"

if [[ "$GRAFANA_PASSWORD" == "changeme" ]]; then
  warn "You are using the default password. Please change it after install!"
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
info "Detected server IP: ${SERVER_IP}"

# ─── Optional dashboards ─────────────────────────────────────────────────────
section "Optional Dashboards"

# ── FortiGate ─────────────────────────────────────────────────────────────
echo ""
info "The FortiGate dashboard collects syslog from your FortiGate firewall."
info "Syslog will be received on port 1514 (UDP/TCP). You will configure your"
info "FortiGate to send syslog to this server after installation."
echo ""
if confirm "Install FortiGate dashboard?" "n"; then
  INSTALL_FORTIGATE=true
  log "FortiGate dashboard will be installed."
else
  info "Skipping FortiGate dashboard."
fi

echo ""

# ── Proxmox ───────────────────────────────────────────────────────────────
info "The Proxmox dashboard shows cluster/node metrics via the Proxmox API."
info "You will need a Proxmox API user/token for each node."
echo ""
if confirm "Install Proxmox dashboard?" "n"; then
  INSTALL_PROXMOX=true

  echo ""
  prompt NUM_NODES "How many Proxmox nodes do you want to monitor?" "1"

  for (( i=1; i<=NUM_NODES; i++ )); do
    echo ""
    info "─── Proxmox Node #${i} ───"
    prompt NODE_ALIAS    "  Alias (e.g. pve-node1)"        "pve-node${i}"
    prompt NODE_HOST     "  Hostname or IP"                 ""
    prompt NODE_PORT     "  API port"                       "8006"
    prompt NODE_USER     "  API user (e.g. root@pam)"       "root@pam"
    prompt NODE_PASS     "  API password or token value"    ""
    prompt NODE_VERIFY   "  Verify SSL? (true/false)"       "false"
    PROXMOX_NODES+=("${NODE_ALIAS}|${NODE_HOST}|${NODE_PORT}|${NODE_USER}|${NODE_PASS}|${NODE_VERIFY}")
    log "Node #${i} (${NODE_ALIAS} @ ${NODE_HOST}) added."
  done

  echo ""
  info "node_exporter enables CPU/disk temperatures and detailed hardware metrics."
  info "It must be installed on each Proxmox node (instructions will be shown)."
  if confirm "Enable node_exporter support?" "n"; then
    INSTALL_NODE_EXPORTER=true
    log "node_exporter support enabled."
  else
    info "Skipping node_exporter."
  fi
else
  info "Skipping Proxmox dashboard."
fi

# ─── Generate configs ────────────────────────────────────────────────────────
section "Generating Configuration"

cd "${SCRIPT_DIR}"

# .env file
info "Writing .env..."
cat > .env << EOF
GRAFANA_PORT=${GRAFANA_PORT}
GRAFANA_ADMIN_USER=${GRAFANA_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
GRAFANA_ROOT_URL=http://${SERVER_IP}:${GRAFANA_PORT}
PROMETHEUS_RETENTION=30d
EOF
log ".env written."

# ── prometheus.yml: add pve-exporter scrape targets ──────────────────────
if [[ "$INSTALL_PROXMOX" == true ]] && [[ ${#PROXMOX_NODES[@]} -gt 0 ]]; then
  info "Generating Prometheus scrape configs for Proxmox nodes..."

  PROXMOX_SCRAPE_BLOCK=""
  for NODE_ENTRY in "${PROXMOX_NODES[@]}"; do
    IFS='|' read -r ALIAS HOST PORT USER PASS VERIFY <<< "$NODE_ENTRY"
    PROXMOX_SCRAPE_BLOCK+="
  - job_name: \"pve_${ALIAS}\"
    static_configs:
      - targets: [\"pve-exporter:9221\"]
    metrics_path: /pve
    params:
      target: [\"${HOST}\"]
      module: [\"${ALIAS}\"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __address__
        replacement: pve-exporter:9221
      - source_labels: [__param_target]
        target_label: instance
"
    if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
      PROXMOX_SCRAPE_BLOCK+="
  - job_name: \"node_${ALIAS}\"
    static_configs:
      - targets: [\"${HOST}:9100\"]
        labels:
          node: \"${ALIAS}\"
"
    fi
  done

  # Remove placeholder line and append scrape configs (sed can't handle multiline)
  sed -i '/# PROXMOX_SCRAPE_CONFIGS/d' "${SCRIPT_DIR}/config/prometheus/prometheus.yml"
  printf '%s\n' "$PROXMOX_SCRAPE_BLOCK" >> "${SCRIPT_DIR}/config/prometheus/prometheus.yml"
  log "Prometheus config updated with Proxmox nodes."
fi

# ── pve-exporter config ───────────────────────────────────────────────────
if [[ "$INSTALL_PROXMOX" == true ]]; then
  info "Generating pve-exporter config..."
  mkdir -p "${SCRIPT_DIR}/config/pve-exporter"
  PVE_CONFIG="${SCRIPT_DIR}/config/pve-exporter/pve.yml"
  echo "" > "$PVE_CONFIG"
  for NODE_ENTRY in "${PROXMOX_NODES[@]}"; do
    IFS='|' read -r ALIAS HOST PORT USER PASS VERIFY <<< "$NODE_ENTRY"
    cat >> "$PVE_CONFIG" << EOF
${ALIAS}:
  user: ${USER}
  password: ${PASS}
  verify_ssl: ${VERIFY}
EOF
  done
  log "pve-exporter config written."

  # Add pve-exporter service to docker-compose override
  info "Adding pve-exporter to Docker Compose..."
  cat > "${SCRIPT_DIR}/docker-compose.override.yml" << 'DCEOF'
version: "3.8"
services:
  pve-exporter:
    image: prompve/prometheus-pve-exporter:latest
    container_name: pve-exporter
    restart: unless-stopped
    ports:
      - "9221:9221"
    volumes:
      - ./config/pve-exporter/pve.yml:/etc/prometheus/pve.yml:ro
    command: --config.file=/etc/prometheus/pve.yml
    networks:
      - monitoring
DCEOF
  log "docker-compose.override.yml written."
fi

# ── Remove dashboard files not selected ──────────────────────────────────
if [[ "$INSTALL_FORTIGATE" == false ]]; then
  rm -rf "${SCRIPT_DIR}/dashboards/fortigate"
  info "FortiGate dashboard skipped."
fi

if [[ "$INSTALL_PROXMOX" == false ]]; then
  rm -rf "${SCRIPT_DIR}/dashboards/proxmox"
  info "Proxmox dashboard skipped."
fi

# ─── Start the stack ─────────────────────────────────────────────────────────
section "Starting the Stack"
info "Pulling images (this may take a minute)..."
$DC pull -q

info "Starting services..."
$DC up -d

log "Stack is up!"

# ─── Wait for Grafana ─────────────────────────────────────────────────────────
info "Waiting for Grafana to be ready..."
RETRIES=30
until curl -sf "http://localhost:${GRAFANA_PORT}/api/health" > /dev/null 2>&1 || [[ $RETRIES -eq 0 ]]; do
  sleep 2
  RETRIES=$((RETRIES - 1))
done

if [[ $RETRIES -eq 0 ]]; then
  warn "Grafana did not respond in time. Check: docker logs grafana"
else
  log "Grafana is ready."
fi

# ─── Post-install summary ────────────────────────────────────────────────────
section "Installation Complete"

echo -e "${BOLD}${GREEN}  Grafana Stack is running!${NC}\n"
echo -e "  ${BOLD}Grafana:${NC}    http://${SERVER_IP}:${GRAFANA_PORT}"
echo -e "  ${BOLD}Username:${NC}   ${GRAFANA_USER}"
echo -e "  ${BOLD}Password:${NC}   ${GRAFANA_PASSWORD}"
echo -e "  ${BOLD}Prometheus:${NC} http://${SERVER_IP}:9090"
echo -e "  ${BOLD}Loki:${NC}       http://${SERVER_IP}:3100\n"

if [[ "$INSTALL_FORTIGATE" == true ]]; then
  echo -e "${BOLD}${CYAN}  ── FortiGate Configuration ──────────────────────────────${NC}"
  echo -e "  The FortiGate dashboard is installed and waiting for logs."
  echo -e "  Configure your FortiGate to send syslog to this server:\n"
  echo -e "    1. Go to: ${BOLD}Log & Report → Log Settings → Remote Logging${NC}"
  echo -e "    2. Enable ${BOLD}Send Logs to Syslog${NC}"
  echo -e "    3. Set ${BOLD}IP/FQDN${NC}:  ${SERVER_IP}"
  echo -e "    4. Set ${BOLD}Port${NC}:     1514"
  echo -e "    5. Set ${BOLD}Format${NC}:   Default"
  echo -e "    6. Enable the log levels you want (traffic, event, security, etc.)"
  echo -e "    7. Click ${BOLD}Apply${NC}\n"
  echo -e "  Once configured, logs will appear in Grafana automatically. 🔄\n"
fi

if [[ "$INSTALL_PROXMOX" == true ]]; then
  echo -e "${BOLD}${CYAN}  ── Proxmox Configuration ───────────────────────────────${NC}"
  echo -e "  pve-exporter is configured and connected to your nodes."
  echo -e "  Metrics will appear in Grafana within the next scrape cycle (~15s).\n"

  if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
    echo -e "  ${BOLD}node_exporter setup (run on each Proxmox node as root):${NC}\n"
    for NODE_ENTRY in "${PROXMOX_NODES[@]}"; do
      IFS='|' read -r ALIAS HOST PORT USER PASS VERIFY <<< "$NODE_ENTRY"
      echo -e "  ${CYAN}Node: ${ALIAS} (${HOST})${NC}"
      echo -e '    wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz \\'
      echo -e '      -O /tmp/node_exporter.tar.gz'
      echo -e '    tar -xzf /tmp/node_exporter.tar.gz -C /tmp'
      echo -e '    mv /tmp/node_exporter-*/node_exporter /usr/local/bin/'
      echo -e '    useradd -rs /bin/false node_exporter 2>/dev/null || true'
      echo -e '    cat > /etc/systemd/system/node_exporter.service << EOF'
      echo -e '    [Unit]'
      echo -e '    Description=Prometheus Node Exporter'
      echo -e '    After=network.target'
      echo -e '    [Service]'
      echo -e '    User=node_exporter'
      echo -e '    ExecStart=/usr/local/bin/node_exporter'
      echo -e '    Restart=on-failure'
      echo -e '    [Install]'
      echo -e '    WantedBy=multi-user.target'
      echo -e '    EOF'
      echo -e '    systemctl daemon-reload && systemctl enable --now node_exporter'
      echo -e "    # Verify: curl http://${HOST}:9100/metrics\n"
    done
  fi
fi

echo -e "${BOLD}${CYAN}  ── Useful Commands ─────────────────────────────────────${NC}"
echo -e "  View logs:    ${BOLD}docker compose logs -f${NC}"
echo -e "  Stop stack:   ${BOLD}docker compose down${NC}"
echo -e "  Restart:      ${BOLD}docker compose restart${NC}"
echo -e "  Update:       ${BOLD}docker compose pull && docker compose up -d${NC}\n"

echo -e "${BOLD}${GREEN}  Happy monitoring! 📊${NC}\n"

  if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
    echo -e "  ${BOLD}node_exporter setup (run on each Proxmox node as root):${NC}\n"
    for NODE_ENTRY in "${PROXMOX_NODES[@]}"; do
      IFS='|' read -r ALIAS HOST PORT USER PASS VERIFY <<< "$NODE_ENTRY"
      echo -e "  ${CYAN}Node: ${ALIAS} (${HOST})${NC}"
      echo -e '    wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz \'
      echo -e '      -O /tmp/node_exporter.tar.gz'
      echo -e '    tar -xzf /tmp/node_exporter.tar.gz -C /tmp'
      echo -e '    mv /tmp/node_exporter-*/node_exporter /usr/local/bin/'
      echo -e '    useradd -rs /bin/false node_exporter 2>/dev/null || true'
      echo -e '    cat > /etc/systemd/system/node_exporter.service << EOF'
      echo -e '    [Unit]'
      echo -e '    Description=Prometheus Node Exporter'
      echo -e '    After=network.target'
      echo -e '    [Service]'
      echo -e '    User=node_exporter'
      echo -e '    ExecStart=/usr/local/bin/node_exporter'
      echo -e '    Restart=on-failure'
      echo -e '    [Install]'
      echo -e '    WantedBy=multi-user.target'
      echo -e '    EOF'
      echo -e '    systemctl daemon-reload && systemctl enable --now node_exporter'
      echo -e "    # Verify: curl http://${HOST}:9100/metrics\n"
    done
  fi
fi

echo -e "${BOLD}${CYAN}  ── Useful Commands ─────────────────────────────────────${NC}"
echo -e "  View logs:    ${BOLD}docker compose logs -f${NC}"
echo -e "  Stop stack:   ${BOLD}docker compose down${NC}"
echo -e "  Restart:      ${BOLD}docker compose restart${NC}"
echo -e "  Update:       ${BOLD}docker compose pull && docker compose up -d${NC}\n"

echo -e "${BOLD}${GREEN}  Happy monitoring! 📊${NC}\n"
