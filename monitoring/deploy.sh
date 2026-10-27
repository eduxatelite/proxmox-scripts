#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Monitorización de un cliente nuevo, de cero, en un solo paso
#
# En un NODO PROXMOX del cliente, como root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/monitoring/deploy.sh)
#
#   1. Asistente: módulo a módulo (FortiGate, Proxmox, NAS, DCs, Jump, Deadline,
#      Nuke). Si dices que sí, pide sus IPs; si no, pasa al siguiente.
#      En Proxmox crea él mismo el usuario/token de solo lectura.
#   2. Crea la VM Rocky 9 (lib/common.sh de este repo) con onboot=1 y una clave SSH del nodo
#   3. Copia monitoring/ y la configuración a la VM y lanza install.sh
#   4. Cambia la contraseña root por defecto de la VM y muestra el resumen
#
# Todas las preguntas van al principio: después son ~10 min desatendidos.
# =============================================================================
set -euo pipefail
PS_REPO="${PS_REPO:-eduxatelite/proxmox-scripts}"
PS_REF="${PS_REF:-main}"

# ─── Lanzado con bash <(curl ...): no hay árbol local → se baja el repo y se relanza
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ ! -f "${SELF_DIR}/lib/common.sh" || ! -f "${SELF_DIR}/install.sh" ]]; then
  [[ $EUID -eq 0 ]] || { echo "Lanzar como root en un nodo Proxmox"; exit 1; }
  TREE="$(mktemp -d /root/.proxmox-scripts.XXXXXX)"
  echo "Descargando ${PS_REPO} (${PS_REF})..."
  curl -fsSL "https://codeload.github.com/${PS_REPO}/tar.gz/${PS_REF}" | tar xz -C "$TREE" --strip-components=1 \
    || { echo "No se pudo descargar ${PS_REPO}"; rm -rf "$TREE"; exit 1; }
  chmod +x "$TREE"/monitoring/*.sh "$TREE"/monitoring/tools/*.sh
  rc=0; DEPLOY_TREE="$TREE" bash "$TREE/monitoring/deploy.sh" || rc=$?
  rm -rf "$TREE"; exit "$rc"
fi

SRC="$SELF_DIR"                       # .../proxmox-scripts/monitoring
PS_ROOT="$(cd "$SRC/.." && pwd)"      # .../proxmox-scripts
source "${SRC}/lib/common.sh"

ROCKY_FALLBACK_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
KEY=/root/.ssh/xat_monitoring_ed25519
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

[[ $EUID -eq 0 ]] || die "Lanzar como root en un nodo Proxmox"
command -v qm >/dev/null || die "Esto se lanza en un nodo Proxmox (no encuentro 'qm')"

WORK="$(mktemp -d /root/.monitoring-deploy.XXXXXX)"
ENVF="${WORK}/cliente.env"
cleanup() { [[ -f "$ENVF" ]] && shred -u "$ENVF" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
  ╔═══════════════════════════════════════════════════╗
  ║   Xatélite — Monitorización de cliente nuevo      ║
  ║   VM Rocky 9 + Grafana · Prometheus · Loki        ║
  ╚═══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# =============================================================================
# 1. Asistente (se ejecuta aquí en el nodo: detecta gateway, DNS y cluster)
# =============================================================================
DEPLOY_MODE=1 bash "${SRC}/configurar.sh" "$ENVF"
[[ -s "$ENVF" ]] || die "El asistente no ha generado la configuración"
CLIENTE="$(grep -E "^CLIENTE=" "$ENVF" | cut -d"'" -f2)"
CLIENTE_NOMBRE="$(grep -E "^CLIENTE_NOMBRE=" "$ENVF" | cut -d"'" -f2)"

# =============================================================================
# 2. VM Rocky 9 (funciones de lib/common.sh de proxmox-scripts)
# =============================================================================
section "VM de monitorización"
# Las funciones de proxmox-scripts no están pensadas para set -eu: se relaja aquí
set +eu
# shellcheck disable=SC1090
source "${PS_ROOT}/lib/common.sh"
declare -F create_vm >/dev/null || die "No se pudo cargar ${PS_ROOT}/lib/common.sh"

# La imagen se baja del FTP de Madrid; si el cliente no llega, de rockylinux.org
download_rocky_image() {
  local img="/tmp/${ROCKY_IMG_NAME}"
  [[ -s "$img" ]] && { log "Imagen ya descargada: $img"; return 0; }
  if curl -fsI --connect-timeout 5 "$ROCKY_IMG_URL" >/dev/null 2>&1; then
    info "Descargando Rocky desde el FTP de Xatélite..."
    wget -q --show-progress -O "$img" "$ROCKY_IMG_URL" && return 0
  fi
  warn "FTP de Xatélite no accesible → imagen oficial de rockylinux.org"
  wget -q --show-progress -O "$img" "$ROCKY_FALLBACK_URL" || die "No se pudo descargar la imagen de Rocky"
}

ask_config "monitoring-${CLIENTE}" "4" "8" "100"

[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "xat-monitoring@$(hostname -s)" -f "$KEY"
[[ -s "${KEY}.pub" ]] || die "No se pudo generar la clave SSH ${KEY}"

download_rocky_image
create_vm

# Clave SSH del nodo en la VM (para copiar el repo y lanzar la instalación)
SNIP="/var/lib/vz/snippets/userdata-${VMID}.yml"
[[ -f "$SNIP" ]] || die "No encuentro ${SNIP}"
printf 'ssh_authorized_keys:\n  - %s\n' "$(cat "${KEY}.pub")" >> "$SNIP"
qm set "$VMID" --onboot 1 --description "Monitorización ${CLIENTE_NOMBRE} — monitoring-stack ($(date +%F))" >/dev/null
log "onboot=1 (avería real: una VM de monitorización 82 días caída tras un reinicio del host)"

start_vm_and_wait
info "Obteniendo IP..."
get_vm_ip_and_mac
[[ -n "${VM_IP:-}" ]] || die "La VM ${VMID} no ha cogido IP por DHCP. Revisa la red/VLAN y relanza."
log "VM ${VMID} → ${VM_IP} (MAC ${VM_MAC})"

info "Esperando SSH..."
for _ in $(seq 1 60); do ssh "${SSHO[@]}" "root@${VM_IP}" true 2>/dev/null && break; sleep 5; done
ssh "${SSHO[@]}" "root@${VM_IP}" true || die "No hay SSH con ${VM_IP}"
set -eu

# =============================================================================
# 3. Repo + configuración → VM, e instalación
# =============================================================================
section "Instalando el stack en la VM"
# rlmutil (licencias Nuke) vive en scripts/nuke/ del repo: se incluye si existe
RLM_BIN="${PS_ROOT}/scripts/nuke/rlmutil"
[[ -f "$RLM_BIN" && ! -f "$SRC/modules/nuke/build/rlmutil" ]] && cp "$RLM_BIN" "$SRC/modules/nuke/build/rlmutil"
tar czf - -C "$SRC" --exclude=.git . | ssh "${SSHO[@]}" "root@${VM_IP}" \
  "mkdir -p /opt/monitoring-stack-src && tar xzf - -C /opt/monitoring-stack-src"
ssh "${SSHO[@]}" "root@${VM_IP}" "umask 077; cat > /root/monitoring-${CLIENTE}.env" < "$ENVF"
log "Repo en /opt/monitoring-stack-src, configuración en /root/monitoring-${CLIENTE}.env"

ssh -t "${SSHO[@]}" "root@${VM_IP}" \
  "cd /opt/monitoring-stack-src && ./install.sh --env /root/monitoring-${CLIENTE}.env" \
  || die "install.sh ha fallado. Para reintentar: ssh root@${VM_IP} 'cd /opt/monitoring-stack-src && ./install.sh --env /root/monitoring-${CLIENTE}.env'"

# =============================================================================
# 4. Contraseña root de la VM (la de la imagen base es conocida)
# =============================================================================
ROOT_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
ssh "${SSHO[@]}" "root@${VM_IP}" "echo 'root:${ROOT_PW}' | chpasswd" && log "Contraseña root cambiada"

GPW="$(grep -E "^GRAFANA_ADMIN_PASSWORD=" "$ENVF" | cut -d"'" -f2)"
section "Monitorización de ${CLIENTE_NOMBRE} lista"
cat <<EOF
  VM         : ${VMID} (${VM_NAME}) en $(hostname -s) — onboot=1
  IP / MAC   : ${VM_IP} / ${VM_MAC}
  Grafana    : http://${VM_IP}:3000   admin / ${GPW}
  Root VM    : ${ROOT_PW}   (SSH también con la clave ${KEY} de este nodo)

  ► Guarda en el gestor de contraseñas: Grafana, root de la VM y lo que hay en
    /root/monitoring-${CLIENTE}.env dentro de la VM (SNMP, SMTP, tokens).
  ► Reserva en el DHCP/FortiGate:  ${VM_IP} → ${VM_MAC}
  ► Lo que hay que configurar en FortiGate, NAS y DCs está impreso arriba.
  ► Para cambiar algo:  ssh root@${VM_IP}
      cd /opt/monitoring-stack-src && ./configurar.sh /root/monitoring-${CLIENTE}.env
EOF
