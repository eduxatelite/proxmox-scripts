#!/usr/bin/env bash
# =============================================================================
#  Deadline Farm Monitor — Add-on for the Nuke Dashboard stack
#
#  Adds a Deadline Web Service Prometheus exporter and a Grafana dashboard
#  on top of the existing Nuke License Dashboard stack at /opt/nuke-licenses.
#
#  Requires the Nuke Dashboard installer to have been run first.
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/deadline/add-to-stack.sh)
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

wt_password() {
  local __var=$1 title=$2 prompt=$3
  local val
  val=$(whiptail --title "$title" --passwordbox "$prompt" $WT_H $WT_W "" 3>&1 1>&2 2>&3) \
    || true
  eval "$__var='$val'"
}

wt_yesno() { whiptail --title "$1" --yesno "$2" $WT_H $WT_W 3>&1 1>&2 2>&3; }
wt_msg()   { whiptail --title "$1" --msgbox "$2" $WT_H $WT_W; }

# ── root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash add-to-stack.sh"

# ── ensure tools ──────────────────────────────────────────────────────────────
ensure_pkg() {
  command -v "$1" &>/dev/null && return
  info "Installing $1…"
  if   command -v apt-get &>/dev/null; then apt-get install -y "$2" &>/dev/null
  elif command -v dnf     &>/dev/null; then dnf install -y "$2" &>/dev/null
  elif command -v yum     &>/dev/null; then yum install -y "$2" &>/dev/null
  fi
}
ensure_pkg curl     curl
ensure_pkg whiptail whiptail || ensure_pkg whiptail newt
ensure_pkg python3  python3

command -v docker &>/dev/null || die "Docker is not installed. Run the Nuke installer first."
docker compose version &>/dev/null || die "Docker Compose plugin not found."

# =============================================================================
# STEP 0 — Welcome
# =============================================================================
clear
echo -e "${BLD}${CYN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║      DEADLINE FARM MONITOR — Add-on Installer                ║
  ║      github.com/eduxatelite/proxmox-scripts                  ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"

wt_msg "Deadline Farm Monitor" \
"This add-on extends your existing Nuke License Dashboard stack with:

  • A Prometheus exporter for the Deadline Web Service
  • A new Grafana dashboard (Workers, Jobs, Tasks, Pools, Trends)

Requirements:
  • The Nuke Dashboard installer must have been run already
    (default install path: /opt/nuke-licenses)
  • The Deadline Web Service must be reachable from this host
    (REST API enabled, default port 8081)

Press OK to continue."

# =============================================================================
# STEP 1 — Locate existing stack
# =============================================================================
step "Locating Nuke Dashboard stack"

DEFAULT_DIR="/opt/nuke-licenses"
wt_input INSTALL_DIR "Install Directory" \
  "Where is the Nuke Dashboard stack installed?" \
  "${DEFAULT_DIR}"

[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] \
  || die "Could not find ${INSTALL_DIR}/docker-compose.yml. Run the Nuke installer first."

[[ -f "${INSTALL_DIR}/prometheus/prometheus.yml" ]] \
  || die "Could not find prometheus.yml in ${INSTALL_DIR}/prometheus/. Aborting."

ok "Stack detected at ${INSTALL_DIR}"

# Detect Grafana port from compose file
GRAFANA_PORT=$(grep -E -A1 '^\s+grafana:' "${INSTALL_DIR}/docker-compose.yml" | \
  grep -oE '"[0-9]+:3000"' | head -1 | cut -d: -f1 | tr -d '"')
GRAFANA_PORT="${GRAFANA_PORT:-3001}"

# =============================================================================
# STEP 2 — Deadline Web Service config
# =============================================================================
step "Deadline Web Service"

wt_input DEADLINE_HOST "Deadline Web Service" \
  "IP or hostname of the Deadline Web Service:" \
  "192.168.1.50"

wt_input DEADLINE_PORT "Deadline Web Service" \
  "Deadline Web Service port (default 8081):" \
  "8081"

wt_password DEADLINE_APIKEY "Deadline Web Service" \
  "API Key for the Web Service (leave empty if auth is disabled):"
DEADLINE_APIKEY="${DEADLINE_APIKEY:-}"

wt_input EXPORTER_PORT "Exporter Port" \
  "Local port for the Deadline exporter:" \
  "9300"

wt_input SCRAPE_INTERVAL "Scrape Interval" \
  "How often (seconds) to query Deadline:" \
  "30"

wt_password GRAFANA_PASS "Grafana credentials" \
  "Grafana admin password (set during the Nuke installer):"
[[ -z "$GRAFANA_PASS" ]] && GRAFANA_PASS="nukedashboard"

# =============================================================================
# STEP 3 — Confirm
# =============================================================================
wt_msg "Ready to Install" \
"Installation summary:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Install dir       : ${INSTALL_DIR}
  Deadline server   : ${DEADLINE_HOST}:${DEADLINE_PORT}
  API key           : $([[ -n "$DEADLINE_APIKEY" ]] && echo '(set)' || echo '(none)')
  Exporter port     : ${EXPORTER_PORT}
  Scrape interval   : ${SCRAPE_INTERVAL}s
  Grafana port      : ${GRAFANA_PORT}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Press OK to start."

# =============================================================================
# STEP 4 — Download files
# =============================================================================
step "Downloading exporter files"

REPO_RAW="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/deadline"

# We store the exporter alongside the existing nuke files
curl -fsSL "${REPO_RAW}/deadline_exporter.py"            -o "${INSTALL_DIR}/deadline_exporter.py"  || die "Failed to download deadline_exporter.py"
curl -fsSL "${REPO_RAW}/Dockerfile"                      -o "${INSTALL_DIR}/Dockerfile.deadline"   || die "Failed to download Dockerfile"
curl -fsSL "${REPO_RAW}/grafana_deadline_dashboard.json" -o "${INSTALL_DIR}/deadline_dashboard.json" || die "Failed to download dashboard JSON"
ok "Files downloaded"

# =============================================================================
# STEP 5 — Write exporter env
# =============================================================================
step "Writing configuration"

cat > "${INSTALL_DIR}/config/deadline.env" <<EOF
DEADLINE_HOST=${DEADLINE_HOST}
DEADLINE_PORT=${DEADLINE_PORT}
DEADLINE_APIKEY=${DEADLINE_APIKEY}
EXPORTER_PORT=${EXPORTER_PORT}
SCRAPE_INTERVAL=${SCRAPE_INTERVAL}
EOF
chmod 600 "${INSTALL_DIR}/config/deadline.env"
ok "Wrote config/deadline.env"

# =============================================================================
# STEP 6 — Patch docker-compose.yml (idempotent)
# =============================================================================
step "Patching docker-compose.yml"

COMPOSE="${INSTALL_DIR}/docker-compose.yml"
cp "${COMPOSE}" "${COMPOSE}.bak.$(date +%s)"

if grep -q 'container_name: deadline-exporter' "${COMPOSE}"; then
  warn "deadline-exporter service already present in docker-compose.yml — skipping insert"
else
  info "Inserting deadline-exporter service…"
  # Insert a new service block right after the line containing 'services:'
  python3 - "${COMPOSE}" "${EXPORTER_PORT}" <<'PYEOF'
import sys, re
path, port = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()

block = f"""
  # ── Deadline Exporter (Deadline Web Service → Prometheus metrics) ──────────
  deadline-exporter:
    build:
      context: .
      dockerfile: Dockerfile.deadline
    container_name: deadline-exporter
    restart: unless-stopped
    env_file: config/deadline.env
    ports:
      - "{port}:{port}"
    networks:
      - nuke
"""

# Insert after first "services:" line
text = re.sub(r'(^services:\s*\n)', r'\1' + block, text, count=1, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(text)
PYEOF
  ok "deadline-exporter service added"
fi

# =============================================================================
# STEP 7 — Patch prometheus.yml (idempotent)
# =============================================================================
step "Patching prometheus.yml"

PROM_YML="${INSTALL_DIR}/prometheus/prometheus.yml"
cp "${PROM_YML}" "${PROM_YML}.bak.$(date +%s)"

if grep -q 'deadline_farm_exporter' "${PROM_YML}"; then
  warn "deadline_farm_exporter scrape job already present — skipping insert"
else
  info "Adding scrape job for Deadline exporter…"
  cat >> "${PROM_YML}" <<EOF

  - job_name: 'deadline_farm_exporter'
    static_configs:
      - targets: ['deadline-exporter:${EXPORTER_PORT}']
EOF
  ok "Scrape job added"
fi

# =============================================================================
# STEP 8 — Build and start
# =============================================================================
step "Building & starting Deadline exporter"

cd "${INSTALL_DIR}"

info "Building deadline-exporter image…"
if ! docker compose build deadline-exporter > /tmp/deadline-build.log 2>&1; then
  err "Build failed. Last 20 lines:"
  tail -20 /tmp/deadline-build.log
  die "Fix the error above and re-run this script."
fi
ok "Image built"

info "Starting deadline-exporter and reloading Prometheus…"
docker compose up -d deadline-exporter > /tmp/deadline-up.log 2>&1 \
  || die "Failed to start deadline-exporter. See /tmp/deadline-up.log"

# Force Prometheus to reload by restarting (config volume is mounted read-only)
docker compose restart prometheus > /tmp/deadline-prom-reload.log 2>&1 \
  || warn "Could not restart prometheus container automatically — restart it manually."

ok "Containers running"
sleep 4

# =============================================================================
# STEP 9 — Import Grafana dashboard via API
# =============================================================================
step "Importing Grafana dashboard"

GURL="http://localhost:${GRAFANA_PORT}"
GAUTH="admin:${GRAFANA_PASS}"

info "Waiting for Grafana to be ready…"
STATUS="000"
for i in $(seq 1 60); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$GAUTH" "${GURL}/api/health" 2>/dev/null || true)
  [[ "$STATUS" == "200" ]] && break
  sleep 2
done

if [[ "$STATUS" != "200" ]]; then
  warn "Grafana did not respond (status ${STATUS}). Skipping dashboard import."
  warn "You can import ${INSTALL_DIR}/deadline_dashboard.json manually from the UI."
else
  ok "Grafana ready"

  # 1. Create Deadline folder
  curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/folders" -d '{"title":"Deadline","uid":"deadline"}' > /dev/null 2>&1 || true

  # 2. Build import payload
  python3 - <<PYEOF
import json
with open("${INSTALL_DIR}/deadline_dashboard.json") as f:
    dash = json.load(f)
payload = {"dashboard": dash, "folderUid": "deadline", "overwrite": True}
with open("/tmp/deadline_import_payload.json", "w") as out:
    json.dump(payload, out)
PYEOF

  IMPORT_RESP=$(curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/dashboards/db" \
    -d @/tmp/deadline_import_payload.json \
    2>/dev/null || true)

  DASH_UID=$(echo "$IMPORT_RESP" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('uid','deadline-farm-v1'))" \
    2>/dev/null || echo "deadline-farm-v1")

  ok "Dashboard imported (uid: ${DASH_UID})"

  # 3. Public dashboard link (optional)
  PUBLIC_RESP=$(curl -s -X POST -H "Content-Type: application/json" -u "$GAUTH" \
    "${GURL}/api/dashboards/uid/${DASH_UID}/public-dashboards" \
    -d '{"isEnabled":true,"annotationsEnabled":false,"timeSelectionEnabled":false}' \
    2>/dev/null || true)
  ACCESS_TOKEN=$(echo "$PUBLIC_RESP" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('accessToken',''))" 2>/dev/null || true)

  SERVER_IP=$(hostname -I | awk '{print $1}')
  if [[ -n "$ACCESS_TOKEN" ]]; then
    PUBLIC_URL="http://${SERVER_IP}:${GRAFANA_PORT}/public-dashboards/${ACCESS_TOKEN}"
    ok "Public link created: ${PUBLIC_URL}"
  else
    PUBLIC_URL="http://${SERVER_IP}:${GRAFANA_PORT}/d/${DASH_UID}"
  fi
fi

# =============================================================================
# DONE
# =============================================================================
clear
echo -e "${BLD}${GRN}"
cat << DONE
  ╔══════════════════════════════════════════════════════════════╗
  ║      DEADLINE FARM MONITOR — Add-on Installed                ║
  ╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${RST}"

SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "  ${BLD}Access your dashboard:${RST}"
echo -e "  ${GRN}●${RST}  ${BLD}Grafana            →  http://${SERVER_IP}:${GRAFANA_PORT}${RST}  (admin / your password)"
echo -e "  ${BLU}●${RST}  Deadline metrics   →  http://${SERVER_IP}:${EXPORTER_PORT}/metrics"
echo -e "  ${YLW}●${RST}  Folder in Grafana  →  Dashboards › Deadline › Deadline — Farm Monitor"
echo ""
if [[ -n "${PUBLIC_URL:-}" ]]; then
  echo -e "  ${BLD}${GRN}Direct link:${RST} ${PUBLIC_URL}"
  echo ""
fi
echo -e "  ${BLD}Config file:${RST}     ${INSTALL_DIR}/config/deadline.env"
echo -e "  ${BLD}Logs:${RST}            cd ${INSTALL_DIR} && docker compose logs -f deadline-exporter"
echo -e "  ${BLD}Restart:${RST}         cd ${INSTALL_DIR} && docker compose restart deadline-exporter"
echo ""
