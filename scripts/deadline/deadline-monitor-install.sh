#!/usr/bin/env bash
# =============================================================================
#  Deadline Farm Monitor — Installer
#  Assumes Deadline is already installed in the studio.
#  This script installs ONLY the monitoring stack:
#    Prometheus · Deadline Exporter · Grafana · Nginx (optional)
#  then connects it to the studio's existing Deadline Web Service.
#
#  Rocky Linux 9.x
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
  while kill -0 $pid 2>/dev/null; do
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

wt_msg() { whiptail --title "$1" --msgbox "$2" $WT_H $WT_W; }

wt_checklist() {
  local __var=$1 title=$2 prompt=$3; shift 3
  local val
  val=$(whiptail --title "$title" --checklist "$prompt" $WT_H $WT_W 8 "$@" 3>&1 1>&2 2>&3) \
    || die "Installation cancelled."
  eval "$__var='$val'"
}

wt_gauge() {
  # wt_gauge "title" "message" pct
  echo "$3" | whiptail --title "$1" --gauge "$2" 8 $WT_W 0
}

# ── banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BLD}${CYN}
  ██████╗ ███████╗ █████╗ ██████╗ ██╗     ██╗███╗   ██╗███████╗
  ██╔══██╗██╔════╝██╔══██╗██╔══██╗██║     ██║████╗  ██║██╔════╝
  ██║  ██║█████╗  ███████║██║  ██║██║     ██║██╔██╗ ██║█████╗
  ██║  ██║██╔══╝  ██╔══██║██║  ██║██║     ██║██║╚██╗██║██╔══╝
  ██████╔╝███████╗██║  ██║██████╔╝███████╗██║██║ ╚████║███████╗
  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝╚══════╝
${RST}${BLD}
         Farm Monitor Installer  ·  Rocky Linux 9.x
         github.com/eduxatelite/proxmox-scripts
${RST}"
sleep 1

# ── preflight ─────────────────────────────────────────────────────────────────
step "Pre-flight checks"
[[ $EUID -ne 0 ]] && die "Please run as root (sudo -i)"
command -v whiptail &>/dev/null || dnf install -yq newt
HOST_IP=$(hostname -I | awk '{print $1}')
ok "Running on: $(hostname)  [${HOST_IP}]"
ok "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"


# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — WELCOME & COMPONENT SELECTION
#  (no Deadline questions yet — just what to install)
# ═════════════════════════════════════════════════════════════════════════════

wt_msg "Deadline Farm Monitor" \
"This installer sets up the monitoring stack
for your existing Deadline render farm.

  ──────────────────────────────────────────
  It does NOT install or modify Deadline.
  ──────────────────────────────────────────

What it installs on this machine:

  • Prometheus         metrics time-series DB
  • Deadline Exporter  reads your Deadline API
  • Grafana            dashboards & graphs
  • Nginx              web server / proxy

After installation it will ask for your
Deadline Web Service address and test the
connection automatically.

Press OK to choose components."


wt_checklist COMPONENTS \
  "Select Components" \
  "Space to toggle · Enter to confirm" \
  "prometheus" "Prometheus         (required — metrics DB)"     ON \
  "exporter"   "Deadline Exporter  (required — reads Deadline)" ON \
  "grafana"    "Grafana            (dashboards & graphs)"        ON \
  "nginx"      "Nginx              (web server on port 80)"      ON

# validate required components
for req in prometheus exporter; do
  echo "$COMPONENTS" | grep -q "$req" \
    || { wt_msg "Error" "\"${req}\" is required and must be selected."; die "Aborted."; }
done

INSTALL_GRAFANA=false; INSTALL_NGINX=false
echo "$COMPONENTS" | grep -q grafana && INSTALL_GRAFANA=true
echo "$COMPONENTS" | grep -q nginx   && INSTALL_NGINX=true


# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — INSTALL (no Deadline questions here)
# ═════════════════════════════════════════════════════════════════════════════

step "Installing base packages"
(dnf install -yq epel-release python3 python3-pip curl wget 2>/dev/null) &
spinner "Installing base packages…"
ok "Base packages ready"

# ── Prometheus ────────────────────────────────────────────────────────────────
step "Prometheus"
PROM_VER="2.52.0"
info "Downloading Prometheus ${PROM_VER}…"
(wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-amd64.tar.gz" \
  -O /tmp/prometheus.tar.gz && tar -xzf /tmp/prometheus.tar.gz -C /tmp/) &
spinner "Downloading Prometheus ${PROM_VER}…"

cp /tmp/prometheus-${PROM_VER}.linux-amd64/{prometheus,promtool} /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus

# prometheus.yml — exporter target added later in phase 3
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: 'deadline_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF

cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=:9090 \
  --storage.tsdb.retention.time=30d
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable prometheus &>/dev/null
systemctl start  prometheus
ok "Prometheus installed (port 9090) — waiting for Deadline config"

# ── Deadline Exporter skeleton ────────────────────────────────────────────────
step "Deadline Exporter"
pip3 install -q requests prometheus_client
mkdir -p /opt/deadline-exporter

# Write the exporter with placeholder — phase 3 will fill in the real values
cat > /opt/deadline-exporter/exporter.py <<'PYEOF'
#!/usr/bin/env python3
"""
Deadline Farm Monitor — Prometheus Exporter
Reads Deadline Web Service REST API (with optional API Key auth)
and exposes metrics on :9100/metrics for Prometheus to scrape.

Config file: /opt/deadline-exporter/config.env
Restart after changes: systemctl restart deadline-exporter
"""
import os, time, requests
from prometheus_client import start_http_server, Gauge, Info

# ── load config.env ───────────────────────────────────────────────────────────
cfg_file = "/opt/deadline-exporter/config.env"
if os.path.exists(cfg_file):
    for line in open(cfg_file):
        line = line.strip()
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())

DEADLINE_HOST   = os.environ.get("DEADLINE_HOST",     "localhost")
DEADLINE_PORT   = os.environ.get("DEADLINE_PORT",     "8081")
USE_AUTH        = os.environ.get("DEADLINE_USE_AUTH", "false").lower() == "true"
API_KEY         = os.environ.get("DEADLINE_API_KEY",  "")
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "30"))
EXPORTER_PORT   = int(os.environ.get("EXPORTER_PORT",  "9100"))

DEADLINE_URL = f"http://{DEADLINE_HOST}:{DEADLINE_PORT}"

# ── build request headers ─────────────────────────────────────────────────────
# Deadline Web Service API Key goes in this header when auth is enabled.
# Generate / find keys in: Deadline Monitor → Tools → Configure Web Service → Authentication
HEADERS = {}
if USE_AUTH and API_KEY:
    HEADERS["X-Thinkbox-DeadlineWebAPI-Password"] = API_KEY
    print(f"[AUTH] Using API Key authentication (key: {API_KEY[:8]}…)")
else:
    print("[AUTH] No authentication (open Web Service)")

def dl_get(endpoint):
    """GET from Deadline Web Service, returns parsed JSON or raises."""
    url = f"{DEADLINE_URL}{endpoint}"
    r = requests.get(url, headers=HEADERS, timeout=10)
    if r.status_code == 401:
        raise PermissionError(f"401 Unauthorized — check API Key in config.env")
    if r.status_code == 403:
        raise PermissionError(f"403 Forbidden — API Key may have insufficient permissions")
    r.raise_for_status()
    return r.json()

# ── prometheus metrics ────────────────────────────────────────────────────────
farm_info        = Info("deadline_farm",                "Farm info")
workers_active   = Gauge("deadline_workers_active",     "Workers actively rendering")
workers_idle     = Gauge("deadline_workers_idle",       "Workers idle / waiting")
workers_offline  = Gauge("deadline_workers_offline",    "Workers offline or disabled")
workers_total    = Gauge("deadline_workers_total",      "Total registered workers")
jobs_queued      = Gauge("deadline_jobs_queued",        "Jobs pending in queue")
jobs_rendering   = Gauge("deadline_jobs_rendering",     "Jobs currently rendering")
jobs_completed   = Gauge("deadline_jobs_completed",     "Jobs completed")
jobs_failed      = Gauge("deadline_jobs_failed",        "Jobs failed")
jobs_suspended   = Gauge("deadline_jobs_suspended",     "Jobs suspended")
farm_utilization = Gauge("deadline_farm_utilization",   "Farm utilization %")
frames_per_hour  = Gauge("deadline_frames_per_hour",    "Estimated frames rendered per hour")
scrape_errors    = Gauge("deadline_scrape_errors_total","Total number of scrape errors")
auth_errors      = Gauge("deadline_auth_errors_total",  "Total number of auth errors (bad API key)")

_errors = 0
_auth_errors = 0

def collect():
    global _errors, _auth_errors
    try:
        workers = dl_get("/api/slaves")
        jobs    = dl_get("/api/jobs")

    except PermissionError as e:
        _auth_errors += 1
        auth_errors.set(_auth_errors)
        print(f"[AUTH ERROR] {e}")
        print(f"[AUTH ERROR] Edit /opt/deadline-exporter/config.env and set the correct DEADLINE_API_KEY")
        return

    except Exception as e:
        _errors += 1
        scrape_errors.set(_errors)
        print(f"[ERROR] Could not reach Deadline at {DEADLINE_URL}: {e}")
        return

    # ── workers ───────────────────────────────────────────────────────────────
    # SlaveStatus values: Rendering | Idle | Offline | Disabled | Stalled
    active  = sum(1 for w in workers if w.get("SlaveStatus") == "Rendering")
    idle    = sum(1 for w in workers if w.get("SlaveStatus") == "Idle")
    offline = sum(1 for w in workers if w.get("SlaveStatus") in ("Offline","Disabled","Stalled"))
    total   = len(workers)

    workers_active.set(active)
    workers_idle.set(idle)
    workers_offline.set(offline)
    workers_total.set(total)

    # ── jobs ──────────────────────────────────────────────────────────────────
    # Props.Stat: 0=Unknown 1=Active(Rendering) 2=Suspended 3=Completed 4=Failed 5=Pending(Queued)
    q = sum(1 for j in jobs if j.get("Props",{}).get("Stat") == 5)
    r = sum(1 for j in jobs if j.get("Props",{}).get("Stat") == 1)
    c = sum(1 for j in jobs if j.get("Props",{}).get("Stat") == 3)
    f = sum(1 for j in jobs if j.get("Props",{}).get("Stat") == 4)
    s = sum(1 for j in jobs if j.get("Props",{}).get("Stat") == 2)

    jobs_queued.set(q)
    jobs_rendering.set(r)
    jobs_completed.set(c)
    jobs_failed.set(f)
    jobs_suspended.set(s)

    # ── derived ───────────────────────────────────────────────────────────────
    util = round((active / total) * 100) if total > 0 else 0
    farm_utilization.set(util)
    frames_per_hour.set(active * 12)   # rough estimate — tune per studio

    farm_info.info({
        "host":     DEADLINE_HOST,
        "port":     DEADLINE_PORT,
        "auth":     "api_key" if USE_AUTH else "none",
    })

    print(f"[OK] workers {active}A/{idle}I/{offline}O  |  jobs {r}R/{q}Q/{f}F/{s}S  |  util {util}%")

if __name__ == "__main__":
    print(f"[START] Deadline Exporter")
    print(f"[START] Connecting to: {DEADLINE_URL}")
    print(f"[START] Auth: {'API Key' if USE_AUTH else 'None (open)'}")
    start_http_server(EXPORTER_PORT)
    print(f"[START] Metrics available at :{EXPORTER_PORT}/metrics")
    print(f"[START] Scrape interval: {SCRAPE_INTERVAL}s")
    while True:
        collect()
        time.sleep(SCRAPE_INTERVAL)
PYEOF

cat > /etc/systemd/system/deadline-exporter.service <<'EOF'
[Unit]
Description=Deadline Prometheus Exporter
After=network.target
Wants=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/deadline-exporter/exporter.py
EnvironmentFile=/opt/deadline-exporter/config.env
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

# config.env starts empty — phase 3 fills it in
cat > /opt/deadline-exporter/config.env <<'EOF'
# Deadline Farm Monitor — Exporter configuration
# This file is written by the installer. Edit as needed.
DEADLINE_HOST=PENDING
DEADLINE_PORT=8081
SCRAPE_INTERVAL=30
EXPORTER_PORT=9100
EOF

systemctl daemon-reload
systemctl enable deadline-exporter &>/dev/null
ok "Deadline Exporter installed — will start after Deadline config (phase 2)"

# ── Grafana ───────────────────────────────────────────────────────────────────
if [ "$INSTALL_GRAFANA" = true ]; then
  step "Grafana"
  cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
  (dnf install -yq grafana 2>/dev/null) &
  spinner "Installing Grafana…"
  systemctl enable --now grafana-server &>/dev/null
  ok "Grafana installed and running (port 3000)"
fi

# ── Nginx ─────────────────────────────────────────────────────────────────────
if [ "$INSTALL_NGINX" = true ]; then
  step "Nginx"
  dnf install -yq nginx 2>/dev/null

  cat > /etc/nginx/conf.d/deadline-monitor.conf <<EOF
server {
    listen 80;
    server_name _;

    # Grafana proxy
    location / {
        proxy_pass         http://localhost:3000/;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
    }

    # Prometheus (internal access only)
    location /prometheus/ {
        proxy_pass http://localhost:9090/;
        allow 127.0.0.1;
        deny  all;
    }
}
EOF

  nginx -t &>/dev/null
  systemctl enable --now nginx &>/dev/null
  setsebool -P httpd_can_network_connect 1 &>/dev/null || true
  ok "Nginx running — Grafana accessible on port 80"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
step "Firewall"
systemctl enable --now firewalld &>/dev/null
firewall-cmd --permanent --add-port=80/tcp   &>/dev/null || true
firewall-cmd --permanent --add-port=3000/tcp &>/dev/null || true
firewall-cmd --permanent --add-port=9090/tcp &>/dev/null || true
firewall-cmd --reload &>/dev/null
ok "Firewall rules applied"


# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — DEADLINE CONNECTION
#  Now that everything is installed, ask for the studio's Deadline details
# ═════════════════════════════════════════════════════════════════════════════
clear
echo -e "${BLD}${CYN}
  ══════════════════════════════════════════════════════════════
   Phase 2 of 2 — Connect to your Deadline Web Service
  ══════════════════════════════════════════════════════════════
${RST}"

wt_msg "Connect to Deadline" \
"The monitoring stack is now installed.

Next: connect it to your studio's Deadline.

You will need:
  • IP or hostname of the Deadline Repository
    machine running the Web Service
  • Web Service port  (default: 8081)
  • API Key  (only if auth is enabled)

─────────────────────────────────────────
To enable the Deadline Web Service:
  Deadline Monitor → Tools
    → Configure Web Service → Enable

To find / create an API Key:
  Deadline Monitor → Tools
    → Configure Web Service
      → Authentication → API Keys
─────────────────────────────────────────

Press OK to enter your Deadline details."


# ── Step 1 — host & port ─────────────────────────────────────────────────────
wt_input DL_HOST \
  "Deadline — Web Service Host" \
  "IP address or hostname of the machine\nrunning the Deadline Web Service:" \
  "192.168.1.100"

wt_input DL_PORT \
  "Deadline — Web Service Port" \
  "Deadline Web Service port\n(check: Deadline Monitor → Tools → Configure Web Service):" \
  "8081"

DL_URL="http://${DL_HOST}:${DL_PORT}"

# ── Step 2 — authentication ──────────────────────────────────────────────────
DL_API_KEY=""
DL_USE_AUTH=false

if wt_yesno "Deadline — Authentication" \
"Does your Deadline Web Service require
authentication / API Key?

  YES → you have SSL & Auth enabled in
        Configure Web Service

  NO  → the Web Service is open (no auth)
        which is common on private studio LANs"; then

  DL_USE_AUTH=true

  # show where to get the key
  wt_msg "Deadline — API Key" \
"To find or create your API Key:

  1. Open Deadline Monitor
  2. Tools → Configure Web Service
  3. Click the 'Authentication' tab
  4. Copy an existing key  OR
     click 'Add' to create a new one

The key looks like:
  a1b2c3d4-e5f6-7890-abcd-ef1234567890

Press OK to enter the key."

  # ask for key (shown as plain text so they can check it)
  wt_input DL_API_KEY \
    "Deadline — API Key" \
    "Paste your Deadline Web Service API Key:" \
    ""

  [[ -z "$DL_API_KEY" ]] && { warn "API Key cannot be empty when auth is enabled."; die "Aborted."; }
fi

# ── Step 3 — test connection (with or without key) ───────────────────────────
_dl_curl() {
  if [ "$DL_USE_AUTH" = true ]; then
    curl -s "$@" -H "X-Thinkbox-DeadlineWebAPI-Password: ${DL_API_KEY}"
  else
    curl -s "$@"
  fi
}

while true; do
  info "Testing connection to ${DL_URL}/api/jobs …"

  HTTP_CODE=$(_dl_curl -o /dev/null -w "%{http_code}" --max-time 8 "${DL_URL}/api/jobs" 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "Connected to Deadline Web Service ✔  (HTTP 200)"

    WORKER_COUNT=$(_dl_curl --max-time 8 "${DL_URL}/api/slaves" 2>/dev/null \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
    JOB_COUNT=$(_dl_curl --max-time 8 "${DL_URL}/api/jobs" 2>/dev/null \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")

    wt_msg "Connection Successful" \
"✔  Connected to Deadline Web Service

  Host:         ${DL_HOST}
  Port:         ${DL_PORT}
  Auth:         $([ "$DL_USE_AUTH" = true ] && echo 'API Key ✔' || echo 'None (open)')

  Workers detected:  ${WORKER_COUNT}
  Jobs detected:     ${JOB_COUNT}

Press OK to continue."
    break

  elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    # auth error — let them fix the key without re-entering host/port
    warn "Authentication failed (HTTP ${HTTP_CODE})"
    wt_msg "Authentication Error" \
"The Web Service responded but rejected the request.
  HTTP ${HTTP_CODE} — Unauthorized / Forbidden

This usually means:
  • Wrong or expired API Key
  • Auth is enabled but you selected 'No auth'

Press OK to re-enter the API Key."

    wt_input DL_API_KEY \
      "Deadline — API Key (retry)" \
      "Re-enter your Deadline API Key:" \
      "$DL_API_KEY"
    DL_USE_AUTH=true
    continue

  else
    warn "Could not connect (HTTP ${HTTP_CODE})"
    if wt_yesno "Connection Failed" \
"Could not reach Deadline Web Service at:
  ${DL_URL}/api/jobs
  (HTTP response: ${HTTP_CODE})

Common causes:
  • Web Service not enabled in Deadline Monitor
    (Tools → Configure Web Service → Enable)
  • Firewall blocking port ${DL_PORT} on ${DL_HOST}
  • Wrong IP or port

Try again with different settings?"; then
      wt_input DL_HOST "Deadline — Web Service Host" "IP or hostname:" "$DL_HOST"
      wt_input DL_PORT "Deadline — Web Service Port" "Port:" "$DL_PORT"
      DL_URL="http://${DL_HOST}:${DL_PORT}"
      continue
    else
      warn "Skipping — edit /opt/deadline-exporter/config.env later and restart the service"
      break
    fi
  fi
done

# ── Step 4 — studio branding ─────────────────────────────────────────────────
wt_input STUDIO_NAME \
  "Studio Settings" \
  "Studio name (shown in Grafana dashboard header):" \
  "My Studio"

# ── write config and start exporter ──────────────────────────────────────────
step "Saving configuration"
cat > /opt/deadline-exporter/config.env <<EOF
# Deadline Farm Monitor — Exporter configuration
# Edit this file and restart the service to apply changes:
#   systemctl restart deadline-exporter

DEADLINE_HOST=${DL_HOST}
DEADLINE_PORT=${DL_PORT}
DEADLINE_USE_AUTH=${DL_USE_AUTH}
DEADLINE_API_KEY=${DL_API_KEY}
SCRAPE_INTERVAL=30
EXPORTER_PORT=9100
STUDIO_NAME=${STUDIO_NAME}
EOF

# lock down the config file so the API key is not world-readable
chmod 600 /opt/deadline-exporter/config.env

systemctl start deadline-exporter
sleep 2

if systemctl is-active --quiet deadline-exporter; then
  ok "Deadline Exporter started and collecting metrics"
else
  warn "Exporter failed to start — check: journalctl -u deadline-exporter"
fi

# ── Grafana: auto-provision Prometheus datasource ─────────────────────────────
if [ "$INSTALL_GRAFANA" = true ]; then
  step "Grafana — provisioning Prometheus datasource"
  mkdir -p /etc/grafana/provisioning/datasources

  cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://localhost:9090
    access: proxy
    isDefault: true
    editable: true
EOF

  systemctl restart grafana-server
  ok "Prometheus datasource provisioned in Grafana"
fi


# ═════════════════════════════════════════════════════════════════════════════
#  DONE — FINAL SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
clear
echo -e "
${BLD}${GRN}
  ╔══════════════════════════════════════════════════════════════╗
  ║       Installation Complete — Deadline Farm Monitor          ║
  ╚══════════════════════════════════════════════════════════════╝
${RST}
  ${BLD}Studio:${RST}     ${STUDIO_NAME}
  ${BLD}This host:${RST}  ${HOST_IP}
  ${BLD}Deadline:${RST}   http://${DL_HOST}:${DL_PORT}

  ${BLD}${CYN}Access URLs:${RST}
  ┌──────────────────────────────────────────────────────────┐"

[ "$INSTALL_NGINX" = true ] && \
  echo -e "  │  Dashboard  →  ${BLD}http://${HOST_IP}/${RST}  (via Nginx)              │"
[ "$INSTALL_GRAFANA" = true ] && \
  echo -e "  │  Grafana    →  ${BLD}http://${HOST_IP}:3000/${RST}                      │"
echo -e "  │  Prometheus →  ${BLD}http://${HOST_IP}:9090/${RST}                      │
  │  Metrics    →  ${BLD}http://${HOST_IP}:9100/metrics${RST}               │
  └──────────────────────────────────────────────────────────┘

  ${BLD}Service status:${RST}"

for svc in prometheus deadline-exporter grafana-server nginx; do
  systemctl is-active --quiet "$svc" 2>/dev/null \
    && echo -e "  ${GRN}✔${RST}  $svc" \
    || echo -e "  ${RED}✘${RST}  $svc  (not installed or failed)"
done

echo -e "
  ${BLD}Useful commands:${RST}
  Check exporter:   ${CYN}journalctl -fu deadline-exporter${RST}
  Check Prometheus: ${CYN}journalctl -fu prometheus${RST}
  Edit config:      ${CYN}nano /opt/deadline-exporter/config.env${RST}
  Restart exporter: ${CYN}systemctl restart deadline-exporter${RST}

  ${YLW}First login to Grafana:${RST}
  URL:  http://${HOST_IP}:3000
  User: admin   Password: admin
  ${YLW}(change the password on first login)${RST}

  ${BLD}Prometheus is already connected to Grafana as the default datasource.
  Go to Dashboards → Import and use the Deadline dashboard JSON from:
  github.com/eduxatelite/proxmox-scripts/scripts/deadline/${RST}
"
