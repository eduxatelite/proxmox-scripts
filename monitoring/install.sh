#!/usr/bin/env bash
# =============================================================================
# install.sh — Stack de monitorización estandarizado Xatélite
#
# Se ejecuta DENTRO de la VM de monitorización (Rocky 9 creada con
# proxmox-scripts/rocky-base.sh). Es idempotente: relanzarlo con el mismo .env
# regenera la configuración y aplica los cambios.
#
# Uso:
#   ./install.sh                                      # asistente: pregunta IPs y datos
#   ./install.sh --env /root/cliente.env              # instala / actualiza
#   ./install.sh --env /root/cliente.env --render-only --target /tmp/prueba
#
# Opciones:
#   --env FICHERO     .env del cliente. Sin él se lanza configurar.sh (asistente)
#   --target DIR      Directorio de instalación (por defecto /opt/grafana-stack)
#   --render-only     Solo genera la configuración, no toca el sistema ni Docker
#   --list-modules    Muestra los módulos disponibles
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

ENV_FILE=""
TARGET="/opt/grafana-stack"
RENDER_ONLY=false

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

list_modules() {
  local d
  for d in "${REPO_DIR}"/modules/*/; do
    local m; m="$(basename "$d")"
    ( MOD_DESC=""; source "${d}module.sh"; printf "  %-12s %s\n" "$m" "$MOD_DESC" )
  done
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENV_FILE="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --render-only)  RENDER_ONLY=true; shift ;;
    --list-modules) list_modules ;;
    -h|--help)      usage 0 ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

[[ -z "$ENV_FILE" ]] && exec "${REPO_DIR}/configurar.sh"
[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE. Copia clientes/cliente.env.example, rellénalo y vuelve a lanzar."
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
if ! $RENDER_ONLY; then
  [[ $EUID -eq 0 ]] || die "Lanza el script como root."
fi

# =============================================================================
# 1. Variables del cliente + valores derivados
# =============================================================================
section "Configuración del cliente"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_vars core CLIENTE GRAFANA_ADMIN_PASSWORD
: "${MODULES:=}"
[[ "$CLIENTE" =~ ^[a-z0-9-]+$ ]] || die "CLIENTE solo admite minúsculas, números y guiones (ej: rojo)"
[[ "$GRAFANA_ADMIN_PASSWORD" == "changeme" ]] && die "GRAFANA_ADMIN_PASSWORD es 'changeme'. Genera una: openssl rand -base64 18"
[[ ${#GRAFANA_ADMIN_PASSWORD} -lt 12 ]] && warn "GRAFANA_ADMIN_PASSWORD tiene menos de 12 caracteres: cámbiala cuando puedas"

set -a
: "${CLIENTE_NOMBRE:=$CLIENTE}"
: "${VM_IP:=$(hostname -I 2>/dev/null | awk '{print $1}')}"
: "${GRAFANA_PORT:=3000}"
: "${GRAFANA_ADMIN_USER:=admin}"
: "${GRAFANA_ROOT_URL:=http://${VM_IP}:${GRAFANA_PORT}}"
: "${GRAFANA_ANONYMOUS:=false}"
: "${PROMETHEUS_RETENTION:=90d}"
: "${PROMETHEUS_RETENTION_SIZE:=20GB}"
: "${LOKI_RETENTION:=2160h}"
: "${SMTP_PASSWORD:=${GRAFANA_SMTP_PASSWORD:-}}"          # alias de la plantilla antigua
: "${SMTP_HOST:=${GRAFANA_SMTP_HOST:-notificaciones-xatelite-com.correoseguro.dinaserver.com:587}}"
: "${SMTP_USER:=${GRAFANA_SMTP_USER:-${CLIENTE}.grafana@notificaciones.xatelite.com}}"
: "${SMTP_FROM_ADDRESS:=${GRAFANA_SMTP_FROM:-${SMTP_USER}}}"
: "${SMTP_FROM_NAME:=Grafana ${CLIENTE_NOMBRE}}"
if [[ -z "${SMTP_ENABLED:-}" ]]; then [[ -n "$SMTP_PASSWORD" ]] && SMTP_ENABLED=true || SMTP_ENABLED=false; fi
# 465 = SSL implícito (NoStartTLS); 587 = STARTTLS
if [[ -z "${SMTP_STARTTLS_POLICY:-}" ]]; then
  [[ "$SMTP_HOST" == *:465 ]] && SMTP_STARTTLS_POLICY=NoStartTLS || SMTP_STARTTLS_POLICY=OpportunisticStartTLS
fi
: "${ALERT_CONTACT_EMAIL:=}"
: "${ALERT_VM_DISK_PCT:=85}"
: "${HEARTBEAT_URL:=}"
: "${LOKI_ALLOWED_SOURCES:=}"
set +a
[[ -z "$VM_IP" ]] && die "No se ha podido detectar VM_IP. Defínela en el .env."

# =============================================================================
# 2. Resolución de módulos (dependencias, defaults, validación)
# =============================================================================
declare -a MODS=()
add_module() {
  local m="$1" dep
  [[ " ${MODS[*]:-} " == *" $m "* ]] && return 0
  [[ -f "${REPO_DIR}/modules/${m}/module.sh" ]] || die "Módulo desconocido: '$m' (ver --list-modules)"
  MOD_DEPENDS=""
  # shellcheck disable=SC1090
  source "${REPO_DIR}/modules/${m}/module.sh"
  for dep in $MOD_DEPENDS; do add_module "$dep"; done
  MODS+=("$m")
}
for m in $MODULES; do add_module "$m"; done

fn() { echo "${1//-/_}_$2"; }   # nombre de función de hook: tpn-audit → tpn_audit_render
call_hook() { local f; f="$(fn "$1" "$2")"; if declare -F "$f" >/dev/null; then "$f"; fi; }

set -a
for m in "${MODS[@]}"; do call_hook "$m" defaults; done
set +a
for m in "${MODS[@]}"; do call_hook "$m" validate; done

# Fuentes autorizadas a hacer push a Loki (los módulos añaden las suyas, p.ej. los DCs)
for m in "${MODS[@]}"; do
  f="$(fn "$m" loki_sources)"
  if declare -F "$f" >/dev/null; then LOKI_ALLOWED_SOURCES="${LOKI_ALLOWED_SOURCES} $("$f")"; fi
done
LOKI_ALLOWED_SOURCES="$(echo "$LOKI_ALLOWED_SOURCES" | xargs -n1 2>/dev/null | sort -u | xargs || true)"
export LOKI_ALLOWED_SOURCES

# docker compose usa COMPOSE_FILE del .env para unir core + módulos
COMPOSE_FILE="docker-compose.yml"
for m in "${MODS[@]}"; do
  [[ -f "${REPO_DIR}/modules/${m}/compose.yml" ]] && COMPOSE_FILE+=":modules/${m}/compose.yml"
done
export COMPOSE_FILE COMPOSE_PROJECT_NAME="grafana-stack"

log "Cliente   : ${BOLD}${CLIENTE_NOMBRE}${NC} (${CLIENTE})"
log "VM        : ${VM_IP}"
log "Módulos   : ${MODS[*]}"
[[ -n "$LOKI_ALLOWED_SOURCES" ]] && log "Push Loki : ${LOKI_ALLOWED_SOURCES}"

# =============================================================================
# 3. Render de la configuración en un directorio temporal
# =============================================================================
section "Generando configuración"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
export STAGE

cp "${REPO_DIR}/core/docker-compose.yml" "$STAGE/docker-compose.yml"
mkdir -p "$STAGE/config/prometheus/scrape.d" "$STAGE/dashboards" "$STAGE/modules"

# Core: .tmpl → renderizado, el resto se copia tal cual
( cd "${REPO_DIR}/core/config" && find . -type f ) | while read -r f; do
  if [[ "$f" == *.tmpl ]]; then
    render_tmpl "${REPO_DIR}/core/config/$f" "$STAGE/config/${f%.tmpl}"
  else
    mkdir -p "$(dirname "$STAGE/config/$f")"; cp "${REPO_DIR}/core/config/$f" "$STAGE/config/$f"
  fi
done
# Sin destinatario no se provisiona contact point (Grafana fallaría con addresses vacío)
[[ -z "$ALERT_CONTACT_EMAIL" ]] && rm -f "$STAGE/config/grafana/provisioning/alerting/contact-points.yaml" \
  && warn "ALERT_CONTACT_EMAIL vacío: las alertas no se enviarán por correo."

PROMTAIL="$STAGE/config/promtail/promtail-config.yml"

for m in "${MODS[@]}"; do
  src="${REPO_DIR}/modules/${m}"
  [[ -f "$src/compose.yml" ]]       && { mkdir -p "$STAGE/modules/$m"; cp "$src/compose.yml" "$STAGE/modules/$m/"; }
  [[ -d "$src/build" ]]             && { mkdir -p "$STAGE/modules/$m"; cp -a "$src/build" "$STAGE/modules/$m/"; }
  [[ -f "$src/scrape.yml.tmpl" ]]   && render_tmpl "$src/scrape.yml.tmpl" "$STAGE/config/prometheus/scrape.d/${m}.yml"
  [[ -f "$src/alerts.yaml.tmpl" ]]  && render_tmpl "$src/alerts.yaml.tmpl" "$STAGE/config/grafana/provisioning/alerting/${m}.yaml"
  if [[ -f "$src/promtail.yml.tmpl" ]]; then
    render_tmpl "$src/promtail.yml.tmpl" "$STAGE/promtail-${m}.part"
    { echo; echo "  # ─── módulo: ${m} ───"; cat "$STAGE/promtail-${m}.part"; } >> "$PROMTAIL"
    rm -f "$STAGE/promtail-${m}.part"
  fi
  if [[ -d "$src/dashboards" ]]; then
    folder="$(MOD_FOLDER=""; source "$src/module.sh"; echo "${MOD_FOLDER:-$m}")"
    mkdir -p "$STAGE/dashboards/$folder"; cp "$src"/dashboards/*.json "$STAGE/dashboards/$folder/"
  fi
  call_hook "$m" render
  log "módulo ${m}"
done

# .env final del stack (secretos: solo aquí, chmod 600)
# Se escriben los valores YA evaluados y entre comillas simples: así lo leen
# igual bash, docker compose y systemd (EnvironmentFile), y un '$' en una
# contraseña no se interpola.
ENV_KEYS="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$ENV_FILE" | tr -d '=' ; \
            echo VM_IP GRAFANA_ROOT_URL GRAFANA_PORT LOKI_ALLOWED_SOURCES SMTP_ENABLED SMTP_HOST SMTP_USER SMTP_PASSWORD \
                 SMTP_FROM_ADDRESS SMTP_FROM_NAME SMTP_STARTTLS_POLICY \
                 SYSLOG_PORT_UDP SYSLOG_PORT_FORTI SYSLOG_PORT_NAS SYSLOG_PORT_TRUENAS COMPOSE_FILE COMPOSE_PROJECT_NAME)"
{
  echo "# Generado por install.sh el $(date '+%F %T') — NO subir a git"
  echo "# Fuente: ${ENV_FILE}. Para cambiar algo: editar la fuente y relanzar install.sh"
  for k in $(echo "$ENV_KEYS" | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do
    v="${!k:-}"
    [[ -z "$v" && "$k" == SYSLOG_PORT_* ]] && continue
    [[ "$v" == *"'"* ]] && die "El valor de $k contiene una comilla simple: no soportado"
    echo "${k}='${v}'"
  done
} > "$STAGE/.env"
chmod 600 "$STAGE/.env"

if $RENDER_ONLY; then
  mkdir -p "$TARGET"
  cp -a "$STAGE/." "$TARGET/"
  log "Render terminado en ${TARGET} (no se ha tocado el sistema)"
  exit 0
fi

# =============================================================================
# 4. Sistema: paquetes, Docker, daemon.json
# =============================================================================
section "Sistema"

source /etc/os-release
case "${ID}" in
  rocky|almalinux|rhel|centos)
    dnf -y -q install gettext curl tar cronie net-snmp-utils nmap-ncat tcpdump iptables-nft python3 >/dev/null
    systemctl enable --now crond >/dev/null 2>&1 || true
    if ! command -v docker >/dev/null; then
      info "Instalando Docker CE..."
      dnf -y -q install dnf-plugins-core >/dev/null
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
      dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
    fi ;;
  debian|ubuntu)
    apt-get update -qq
    apt-get install -y -qq gettext-base curl tar cron snmp netcat-openbsd tcpdump iptables python3 >/dev/null
    command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh ;;
  *) die "Distribución no soportada: ${ID}" ;;
esac
log "Paquetes base"

# Límite de logs de Docker (avería real: un log de 31 GB llenó un disco)
DAEMON_CHANGED=false
mkdir -p /etc/docker
NEW_DAEMON="$(python3 - "${REPO_DIR}/core/system/daemon.json" <<'PY'
import json, sys, os
want = json.load(open(sys.argv[1]))
cur = {}
if os.path.exists("/etc/docker/daemon.json"):
    try: cur = json.load(open("/etc/docker/daemon.json"))
    except Exception: cur = {}
cur.update(want)
print(json.dumps(cur, indent=2))
PY
)"
if [[ ! -f /etc/docker/daemon.json ]] || [[ "$(cat /etc/docker/daemon.json)" != "$NEW_DAEMON" ]]; then
  [[ -f /etc/docker/daemon.json ]] && cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  echo "$NEW_DAEMON" > /etc/docker/daemon.json
  DAEMON_CHANGED=true
fi
systemctl enable docker >/dev/null 2>&1
if $DAEMON_CHANGED; then systemctl restart docker; log "daemon.json aplicado (max-size 100m x3)"; else systemctl start docker; log "daemon.json ya correcto"; fi
docker compose version >/dev/null 2>&1 || die "Falta el plugin docker compose"

# =============================================================================
# 5. Despliegue de ficheros en ${TARGET}
# =============================================================================
section "Despliegue en ${TARGET}"
MARKER="$TARGET/.monitoring-stack"
if [[ -d "$TARGET" && ! -f "$MARKER" ]]; then
  BK="/root/grafana-stack-previo-$(date +%Y%m%d-%H%M%S).tgz"
  tar czf "$BK" -C "$(dirname "$TARGET")" "$(basename "$TARGET")"
  chmod 600 "$BK"
  warn "Instalación previa no gestionada por este repo → copia en ${BK}"
  warn "Los volúmenes Docker (datos de Grafana/Prometheus/Loki) se conservan: mismo proyecto 'grafana-stack'."
fi
mkdir -p "$TARGET"
# config/, dashboards/ y modules/ se regeneran completos (los datos viven en volúmenes Docker)
for d in config dashboards modules; do rm -rf "${TARGET:?}/$d"; done
cp -a "$STAGE/." "$TARGET/"
chmod 600 "$TARGET/.env"
chmod 700 "$TARGET"
echo "$(date '+%F %T') $(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo sin-git)" >> "$MARKER"
log "Configuración copiada"

# =============================================================================
# 6. Firewall (Docker se salta firewalld → cadena DOCKER-USER)
# =============================================================================
install -m 0755 "${REPO_DIR}/core/system/monitoring-firewall.sh" /usr/local/sbin/monitoring-firewall.sh
install -m 0644 "${REPO_DIR}/core/system/monitoring-firewall.service" /etc/systemd/system/monitoring-firewall.service

# =============================================================================
# 7. Heartbeat al Uptime Kuma de Xatélite
# =============================================================================
install -m 0755 "${REPO_DIR}/core/system/heartbeat.sh" /usr/local/bin/xat-heartbeat.sh
install -m 0644 "${REPO_DIR}/core/system/xat-heartbeat.service" /etc/systemd/system/xat-heartbeat.service
install -m 0644 "${REPO_DIR}/core/system/xat-heartbeat.timer"   /etc/systemd/system/xat-heartbeat.timer
systemctl daemon-reload

# =============================================================================
# 8. Arranque del stack
# =============================================================================
section "Arrancando contenedores"
cd "$TARGET"
UP_ARGS=(-d --build --remove-orphans)
$DAEMON_CHANGED && UP_ARGS+=(--force-recreate)   # el límite de logs solo aplica a contenedores nuevos
docker compose pull -q --ignore-buildable
docker compose up "${UP_ARGS[@]}"

# Comprobación: ningún servicio sin política de reinicio (avería real: Loki 7 semanas caído)
NORESTART="$(docker compose ps -q | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' | awk '$2!="unless-stopped"{print $1}')"
[[ -n "$NORESTART" ]] && warn "Contenedores sin restart: unless-stopped → ${NORESTART}"

systemctl enable --now monitoring-firewall.service >/dev/null
systemctl restart monitoring-firewall.service
log "Firewall DOCKER-USER aplicado"

if [[ -n "$HEARTBEAT_URL" ]]; then
  systemctl enable --now xat-heartbeat.timer >/dev/null
  log "Heartbeat activo cada 5 min"
else
  systemctl disable --now xat-heartbeat.timer >/dev/null 2>&1 || true
  warn "HEARTBEAT_URL vacío: este stack NO está vigilado desde fuera. Crea el push monitor en Uptime Kuma."
fi

info "Esperando a Grafana..."
for _ in $(seq 1 45); do
  curl -sf "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null && break
  sleep 2
done
if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null; then
  log "Grafana responde"
  # GF_SECURITY_ADMIN_PASSWORD solo se aplica al crear la BD: se fuerza para que el .env sea la verdad
  docker compose exec -T grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null 2>&1 \
    && log "Contraseña admin de Grafana sincronizada con el .env" \
    || warn "No se pudo fijar la contraseña admin (¿el usuario admin se renombró?)"
else
  warn "Grafana no responde: cd ${TARGET} && docker compose logs grafana"
fi

# =============================================================================
# 9. Post-instalación de módulos (agentes, instrucciones de dispositivos)
# =============================================================================
for m in "${MODS[@]}"; do call_hook "$m" post_install; done

section "Instalación completada — ${CLIENTE_NOMBRE}"
echo -e "  Grafana    : ${CYAN}${GRAFANA_ROOT_URL}${NC}  (usuario ${GRAFANA_ADMIN_USER})"
echo -e "  Prometheus : ${CYAN}http://${VM_IP}:9090/targets${NC}"
echo -e "  Módulos    : ${MODS[*]}"
echo
echo -e "  ${BOLD}Recuerda en el nodo Proxmox:${NC} esta VM debe tener 'onboot: 1'"
echo -e "    qm set <VMID> --onboot 1      (o tools/comprobar-onboot.sh --fix)"
echo
