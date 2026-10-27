#!/usr/bin/env bash
# =============================================================================
# configurar.sh — Asistente: pregunta los datos del cliente y genera su .env
#
#   ./configurar.sh                         # cliente nuevo
#   ./configurar.sh /root/monitoring-cliente.env       # editar uno existente (sus valores son los defaults)
#
# - Propone valores detectados (gateway → FortiGate, DNS → DCs)
# - Genera solo las contraseñas (Grafana, community SNMP)
# - Va módulo a módulo: si contestas que sí, pide sus IPs; si no, pasa al siguiente
# - En un nodo Proxmox crea el token de solo lectura e instala node_exporter
# Al terminar ofrece lanzar install.sh directamente.
# =============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_DIR}/lib/common.sh"

OUT="${1:-}"
PREV=/opt/grafana-stack
if [[ -n "$OUT" && -f "$OUT" ]]; then
  set -a; source "$OUT"; set +a
  info "Editando ${OUT}: Enter mantiene el valor actual"
elif [[ -f "$PREV/.env" && ! -f "$PREV/.monitoring-stack" ]]; then
  # ─── Migración: instalación hecha a mano (montada antes de este repo) ───
  # Se reaprovecha todo lo que ya funciona: contraseñas (Grafana NO cambia su
  # admin al cambiar el .env), community SNMP (los equipos ya la tienen) e IPs.
  warn "Hay una instalación previa en ${PREV}: se importan sus valores como propuesta"
  set -a; source "$PREV/.env" 2>/dev/null || warn "No se pudo leer entero ${PREV}/.env"; set +a
  : "${SMTP_PASSWORD:=${GRAFANA_SMTP_PASSWORD:-}}"
  if [[ -f "$PREV/docker-compose.yml" ]]; then   # SMTP fijado a mano en el compose 
    for kv in HOST USER PASSWORD FROM_ADDRESS FROM_NAME; do
      v="$(grep -oE "GF_SMTP_${kv}=[^\$].*" "$PREV/docker-compose.yml" | head -1 | cut -d= -f2- | tr -d '"' || true)"
      [[ -n "$v" && -z "$(eval echo "\${SMTP_${kv}:-}")" ]] && printf -v "SMTP_${kv}" '%s' "$v"
    done
  fi
  eval "$(python3 - "$PREV" <<'PY' 2>/dev/null || true
import sys, re, glob, os
base = sys.argv[1]
out = {}
try:
    s = open(os.path.join(base, "config/snmp-exporter/snmp.yml")).read()
    m = re.search(r"community:\s*['\"]?([^\s'\"]+)", s)
    if m and not m.group(1).startswith("$"): out["SNMP_COMMUNITY"] = m.group(1)
except Exception: pass
try:
    import yaml
    p = yaml.safe_load(open(os.path.join(base, "config/prometheus/prometheus.yml")))
    for job in p.get("scrape_configs", []):
        name = job.get("job_name", "")
        tg = []
        for sc in job.get("static_configs", []):
            for t in sc.get("targets", []):
                lab = sc.get("labels", {})
                tg.append((lab.get("dc_name") or lab.get("device") or lab.get("name") or "", t.split(":")[0]))
        if name == "snmp_fortigate" and tg: out["FORTIGATE_IP"] = tg[0][1]
        if name == "snmp_synology" and tg:  out["NAS_TARGETS"] = " ".join(f"{n or 'nas%d' % (i+1)}:{ip}" for i, (n, ip) in enumerate(tg))
        if name == "windows_dc" and tg:     out["AD_DCS"] = " ".join(f"{n or 'DC%02d' % (i+1)}:{ip}" for i, (n, ip) in enumerate(tg))
except Exception: pass
for k, v in out.items():
    print(f"[[ -z \"${{{k}:-}}\" ]] && {k}='{v}'")
PY
)"
  log "Importado: ${SNMP_COMMUNITY:+community SNMP, }${FORTIGATE_IP:+FortiGate, }${NAS_TARGETS:+NAS, }${AD_DCS:+DCs, }${GRAFANA_ADMIN_PASSWORD:+contraseña Grafana, }${SMTP_PASSWORD:+SMTP}"
fi

# ask VAR "Pregunta" "default"
ask() {
  local var="$1" q="$2" def="${!1:-${3:-}}" val
  read -rp "$(echo -e "${YELLOW}[?]${NC} ${q}${def:+ [${def}]}: ")" val
  printf -v "$var" '%s' "${val:-$def}"
}
ask_secret() {   # no muestra el valor; Enter = mantener (o generar si se indica cómo)
  local var="$1" q="$2" gen="${3:-}" val hint=""
  if [[ -n "${!var:-}" ]]; then hint=" [Enter = mantener]"; elif [[ -n "$gen" ]]; then hint=" [Enter = generar]"; fi
  read -rsp "$(echo -e "${YELLOW}[?]${NC} ${q}${hint}: ")" val; echo
  if [[ -n "$val" ]]; then printf -v "$var" '%s' "$val"
  elif [[ -z "${!var:-}" && -n "$gen" ]]; then printf -v "$var" '%s' "$(eval "$gen")"; log "generado"
  fi
  return 0
}
yesno() { local a; read -rp "$(echo -e "${YELLOW}[?]${NC} $1 [${2:-n}]: ")" a; a="${a:-${2:-n}}"; [[ "${a,,}" =~ ^(s|si|sí|y|yes)$ ]]; }
has_mod() { [[ " ${MODULES:-} " == *" $1 "* ]]; }
ip_ok() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# ask_list VAR "Pregunta" "default"  → valida formato nombre:ip nombre:ip
ask_list() {
  while true; do
    ask "$@"
    local ok=1 i
    for i in ${!1}; do ip_ok "${i#*:}" && [[ "$i" == *:* ]] || { ok=0; warn "Formato: nombre:ip nombre2:ip2 ('$i' no vale)"; }; done
    [[ -n "${!1}" && $ok -eq 1 ]] && return 0
  done
}

DETECT_GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)"
DETECT_DNS="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -vE '^(127\.|8\.8\.|1\.1\.)' | head -2 | xargs || true)"
dc_default() {   # "NOMBRE:IP" a partir de los DNS detectados (nombre por DNS inverso si se puede)
  local ip n i=0 out=""
  for ip in $DETECT_DNS; do
    i=$((i+1))
    n="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
    out+="${n:-DC0${i}}:${ip} "
  done
  echo "${out% }"
}

ON_PVE=false; command -v pveum >/dev/null 2>&1 && ON_PVE=true
pve_nodes_default() {   # en un nodo Proxmox: nodos del cluster como alias:ip
  $ON_PVE || return 0
  local r
  r="$(pvesh get /cluster/status --output-format json 2>/dev/null | python3 -c "$(cat <<'PY'
import json, sys
nodes = [n["name"] + ":" + n["ip"] for n in json.load(sys.stdin) if n.get("type") == "node" and n.get("ip")]
print(" ".join(nodes))
PY
)" 2>/dev/null || true)"
  [[ -n "$r" ]] && echo "$r" || echo "$(hostname -s):$(hostname -I | awk '{print $1}')"
}
ensure_snmp() {
  [[ -n "${SNMP_COMMUNITY:-}" ]] && return 0
  ask_secret SNMP_COMMUNITY "Community SNMP (la misma para FortiGate y NAS)" "openssl rand -hex 12"
}
# mod_on MODULO "Pregunta"  → pregunta sí/no y lo añade a MODULES
NEW_MODS=""
mod_on() {
  local m="$1" def=n
  has_mod "$m" && def=s
  echo
  if yesno "${BOLD}$2${NC}" "$def"; then NEW_MODS+="$m "; return 0; fi
  return 1
}

section "Cliente"
ask CLIENTE        "Código del cliente (minúsculas, sin espacios: estudio1, rojo...)"
until [[ "$CLIENTE" =~ ^[a-z0-9-]+$ ]]; do warn "Solo minúsculas, números y guiones"; CLIENTE=""; ask CLIENTE "Código del cliente"; done
ask CLIENTE_NOMBRE "Nombre para mostrar" "${CLIENTE_NOMBRE:-$CLIENTE}"
# En deploy.sh la VM aún no existe: su IP se detecta al instalar
[[ "${DEPLOY_MODE:-}" == "1" ]] || ask VM_IP "IP de esta VM" "${VM_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

section "Grafana y alertas"
ask_secret GRAFANA_ADMIN_PASSWORD "Contraseña admin de Grafana" "openssl rand -base64 18 | tr -d '/+=' | cut -c1-20"
ask ALERT_CONTACT_EMAIL "Correo(s) que reciben las alertas (separados por ;)" "${ALERT_CONTACT_EMAIL:-}"
# Estándar: una cuenta por cliente en notificaciones.xatelite.com, puerto 587
ask SMTP_HOST "Servidor SMTP" "${SMTP_HOST:-notificaciones-xatelite-com.correoseguro.dinaserver.com:587}"
ask SMTP_USER "Cuenta de envío (crearla en dinahosting si no existe)" "${SMTP_USER:-${CLIENTE}.grafana@notificaciones.xatelite.com}"
ask_secret SMTP_PASSWORD "Contraseña de esa cuenta (del gestor de contraseñas)"
SMTP_FROM_ADDRESS="${SMTP_FROM_ADDRESS:-$SMTP_USER}"
SMTP_FROM_NAME="${SMTP_FROM_NAME:-Grafana ${CLIENTE_NOMBRE}}"
SMTP_ENABLED=false; [[ -n "${SMTP_PASSWORD:-}" ]] && SMTP_ENABLED=true
ask HEARTBEAT_URL "URL del push monitor de Uptime Kuma (vacío = después)" "${HEARTBEAT_URL:-}"

section "Qué se monitoriza (cada uno trae su dashboard y sus alertas)"

# ─── FortiGate ───
if mod_on fortigate "¿FortiGate? (dashboard de tráfico/VPN/admin + SNMP + 7 alertas)"; then
  ask FORTIGATE_IP   "  IP del FortiGate (la que ve la VM de monitorización)" "${FORTIGATE_IP:-$DETECT_GW}"
  until ip_ok "$FORTIGATE_IP"; do warn "IP no válida"; FORTIGATE_IP=""; ask FORTIGATE_IP "  IP del FortiGate"; done
  ask FORTIGATE_NAME "  Nombre del FortiGate" "${FORTIGATE_NAME:-fortigate-${CLIENTE}}"
  ensure_snmp
fi

# ─── Proxmox ───
if mod_on proxmox "¿Proxmox? (dashboard de nodos y VMs)"; then
  ask_list PVE_NODES "  Nodos Proxmox (alias:ip, separados por espacio)" "${PVE_NODES:-$(pve_nodes_default)}"
  PVE_USER="${PVE_USER:-monitoring@pve}"; PVE_TOKEN_NAME="${PVE_TOKEN_NAME:-grafana}"
  if [[ -z "${PVE_TOKEN_VALUE:-}" ]]; then
    TOKEN_CMD="pveum user add ${PVE_USER} --comment 'Monitorizacion Xatelite' >/dev/null 2>&1
      pveum acl modify / --users ${PVE_USER} --roles PVEAuditor >/dev/null
      pveum user token remove ${PVE_USER} ${PVE_TOKEN_NAME} >/dev/null 2>&1
      pveum user token add ${PVE_USER} ${PVE_TOKEN_NAME} --privsep 0 --output-format json"
    if $ON_PVE; then
      info "  Creando usuario ${PVE_USER} (PVEAuditor) y token en este cluster..."
      PVE_TOKEN_VALUE="$(bash -c "$TOKEN_CMD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')" \
        && log "  Token ${PVE_USER}!${PVE_TOKEN_NAME} creado" || warn "  No se pudo crear el token"
    elif yesno "  ¿Crear el token de solo lectura por SSH? (pide la contraseña root del nodo)" s; then
      PVE_TOKEN_VALUE="$(ssh -o StrictHostKeyChecking=accept-new "root@$(list_ips "$PVE_NODES" | awk '{print $1}')" "$TOKEN_CMD" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')" \
        && log "  Token creado" || warn "  No se pudo crear el token"
    fi
  fi
  [[ -z "${PVE_TOKEN_VALUE:-}" ]] && ask_secret PVE_TOKEN_VALUE "  Valor del token (pveum user token add ${PVE_USER} ${PVE_TOKEN_NAME} --privsep 0)"
  if yesno "  ¿node_exporter en los nodos (temperaturas, discos físicos)?" "$([[ ${PVE_NODE_EXPORTER:-no} == yes ]] && echo s || echo n)"; then
    PVE_NODE_EXPORTER=yes
    if $ON_PVE && yesno "  ¿Instalarlo ahora en todos los nodos por SSH?" s; then
      for ip in $(list_ips "$PVE_NODES"); do
        ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "root@${ip}" 'bash -s' < "${REPO_DIR}/tools/instalar-node-exporter.sh" \
          | tail -1 || warn "  node_exporter en ${ip}: falló (instalar a mano con tools/instalar-node-exporter.sh)"
      done
    fi
  else
    PVE_NODE_EXPORTER=no
  fi
fi

# ─── Synology ───
if mod_on synology "¿NAS Synology? (dashboard de RAID/discos/volúmenes + logs del DSM + 8 alertas)"; then
  ask_list NAS_TARGETS "  NAS (nombre:ip, separados por espacio)" "${NAS_TARGETS:-}"
  ask NAS_VOLUME "  Volumen principal a vigilar" "${NAS_VOLUME:-/volume1}"
  ensure_snmp
fi

# ─── TrueNAS ───
if mod_on truenas "¿NAS TrueNAS? (dashboard de pools/discos/temperaturas + alertas del propio TrueNAS + 9 alertas)"; then
  ask_list TRUENAS_TARGETS "  TrueNAS (nombre:ip, separados por espacio)" "${TRUENAS_TARGETS:-}"
  ask TRUENAS_API_USER "  Usuario de la API en el TrueNAS (rol Read-only Administrator)" "${TRUENAS_API_USER:-monitoring}"
  echo "  Si aún no tienes la API key, deja vacío: el resumen final explica cómo crearla."
  NEWKEYS=""
  for item in $TRUENAS_TARGETS; do
    tn="${item%%:*}"
    cur="$(tr ' ' '\n' <<<"${TRUENAS_API_KEYS:-}" | awk -F= -v n="$tn" '$1==n{print substr($0,length(n)+2)}')"
    printf -v "TNKEY" '%s' "$cur"
    ask_secret TNKEY "  API key de ${tn}"
    [[ -n "${TNKEY:-}" ]] && NEWKEYS+="${tn}=${TNKEY} "
  done
  TRUENAS_API_KEYS="${NEWKEYS% }"
  if [[ -z "$TRUENAS_API_KEYS" ]]; then
    warn "  Sin API keys: se omite TrueNAS en esta instalación. Añádelas luego con ./configurar.sh"
    NEW_MODS="${NEW_MODS/truenas /}"
  fi
fi

# ─── Active Directory ───
if mod_on ad "¿Domain Controllers? (dashboard de DCs + eventos de seguridad + 12 alertas)"; then
  ask_list AD_DCS "  Controladores de dominio (NOMBRE:ip, separados por espacio)" "${AD_DCS:-$(dc_default)}"
  if mod_on tpn-audit "¿Dashboard de auditoría TPN? (AD, FortiGate, NAS y Jump Desktop en uno)"; then :; fi
fi

# ─── Jump Desktop ───
if mod_on jumpdesktop "¿Jump Desktop? (conexiones remotas + detección de anomalías + 5 alertas)"; then
  ask JUMPDESKTOP_TEAM_ID "  Team ID" "${JUMPDESKTOP_TEAM_ID:-}"
  ask_secret JUMPDESKTOP_API_TOKEN "  API token"
  ask JD_WORK_START "  Hora de inicio de jornada" "${JD_WORK_START:-8}"
  ask JD_WORK_END   "  Hora de fin de jornada" "${JD_WORK_END:-20}"
  JD_LEARNING_MODE="${JD_LEARNING_MODE:-1}"
fi

# ─── Deadline ───
if mod_on deadline "¿Deadline? (dashboard de la granja de render)"; then
  ask DEADLINE_HOST "  IP del Deadline Web Service" "${DEADLINE_HOST:-}"
  ask DEADLINE_PORT "  Puerto" "${DEADLINE_PORT:-8081}"
  ask_secret DEADLINE_APIKEY "  API key (vacío si no hay auth)"
fi

# ─── Nuke ───
if mod_on nuke "¿Licencias de Nuke? (dashboard de RLM)"; then
  ask RLM_HOST "  IP del servidor RLM" "${RLM_HOST:-}"
  ask RLM_PORT "  Puerto RLM" "${RLM_PORT:-4101}"
fi

MODULES="${NEW_MODS% }"
echo
[[ -n "$MODULES" ]] && log "Módulos: ${MODULES}" || warn "Ningún módulo: solo el core (Grafana, Prometheus, Loki, disco de la VM)."

# ─── Escritura ────────────────────────────────────────────────────────────────
OUT="${OUT:-/root/monitoring-${CLIENTE}.env}"
[[ -f "$OUT" ]] && cp "$OUT" "${OUT}.bak.$(date +%s)"
q() { local v="${!1:-}"; [[ "$v" == *"'"* ]] && die "$1 contiene comilla simple"; echo "$1='${v}'"; }
umask 077
{
  echo "# Cliente ${CLIENTE_NOMBRE} — generado por configurar.sh el $(date '+%F %T')"
  echo "# Contiene secretos: guardar copia en el gestor de contraseñas. NUNCA a git."
  for v in CLIENTE CLIENTE_NOMBRE VM_IP MODULES GRAFANA_ADMIN_PASSWORD ALERT_CONTACT_EMAIL \
           SMTP_ENABLED SMTP_HOST SMTP_USER SMTP_PASSWORD SMTP_FROM_ADDRESS SMTP_FROM_NAME HEARTBEAT_URL GRAFANA_PORT \
           PROMETHEUS_RETENTION LOKI_RETENTION LOKI_ALLOWED_SOURCES SNMP_COMMUNITY \
           FORTIGATE_IP FORTIGATE_NAME NAS_TARGETS NAS_VOLUME AD_DCS \
           PVE_NODES PVE_USER PVE_TOKEN_NAME PVE_TOKEN_VALUE PVE_VERIFY_SSL PVE_NODE_EXPORTER \
           JUMPDESKTOP_TEAM_ID JUMPDESKTOP_API_TOKEN JD_WORK_START JD_WORK_END JD_LEARNING_MODE \
           DEADLINE_HOST DEADLINE_PORT DEADLINE_APIKEY RLM_HOST RLM_PORT \
           TRUENAS_TARGETS TRUENAS_API_USER TRUENAS_API_KEYS \
           $(compgen -v | grep -E '^ALERT_[A-Z_]+$' | grep -v ALERT_CONTACT_EMAIL); do
    if [[ -n "${!v:-}" ]]; then q "$v"; fi
  done
} | awk '!seen[$0]++' > "$OUT"
chmod 600 "$OUT"
section "Listo"
log "Configuración guardada en ${OUT} (600)"
warn "Guarda las contraseñas generadas en el gestor:  grep -E 'PASSWORD|COMMUNITY|TOKEN' ${OUT}"

[[ "${DEPLOY_MODE:-}" == "1" ]] && exit 0
if [[ "${CONFIGURAR_NO_INSTALL:-}" != "1" ]] && yesno "¿Instalar ahora?" s; then
  exec "${REPO_DIR}/install.sh" --env "$OUT"
fi
echo "Para instalar más tarde:  ${REPO_DIR}/install.sh --env ${OUT}"
