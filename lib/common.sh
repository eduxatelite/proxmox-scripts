#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Librería base compartida para scripts VFX
# Usa Rocky 9.6 Cloud Image (sin instalador, arranca en ~30 segundos)
# =============================================================================

# --- Colores ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}";
           echo -e "${BLUE}  $1${NC}";
           echo -e "${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Rocky 9.6 Cloud Image ---
# Imagen pre-instalada, no necesita instalador
ROCKY_VERSION="9.6"
ROCKY_IMG_URL="http://ftp.madrid.xatelite.com:5005/2026/Rocky-9-6.x86_64.qcow2"
ROCKY_IMG_NAME="Rocky-9-6.x86_64.qcow2"

# --- Cloud-Init: credenciales por defecto ---
CI_USER="root"
CI_PASSWORD="Ab12345"

# Variables rellenadas por el menú interactivo
VM_NAME=""
VMID=""
CORES=""
RAM=""
DISK_SIZE=""
STORAGE=""
BRIDGE=""
IMG_STORAGE=""

# =============================================================================
# check_root
# =============================================================================
check_root() {
  [[ $EUID -ne 0 ]] && error "Ejecuta este script como root en el nodo Proxmox"
  command -v qm &>/dev/null || error "Este script debe ejecutarse en un nodo Proxmox VE"
}

# =============================================================================
# ask_config DEFAULT_NAME DEFAULT_CORES DEFAULT_RAM_GB DEFAULT_DISK
# =============================================================================
ask_config() {
  local def_name="${1:-rocky-vm}"
  local def_cores="${2:-4}"
  local def_ram_gb="${3:-4}"
  local def_disk="${4:-50}"

  header "Configuración de la VM"

  # --- Storage para el disco ---
  echo -e "${BOLD}Storages disponibles en este nodo:${NC}"
  local storages=()
  while IFS= read -r line; do
    storages+=("$line")
  done < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

  if [[ ${#storages[@]} -eq 0 ]]; then
    warn "No se detectaron storages para discos. Usando 'local-lvm' por defecto."
    storages=("local-lvm")
  fi
  for i in "${!storages[@]}"; do
    echo -e "    $((i+1))) ${CYAN}${storages[$i]}${NC}"
  done
  local st_choice
  read -rp $'\n¿En qué storage quieres el disco? [1]: ' st_choice
  st_choice="${st_choice:-1}"
  STORAGE="${storages[$((st_choice-1))]}"
  [[ -z "$STORAGE" ]] && STORAGE="${storages[0]}"

  # --- Storage para la imagen (necesita soportar imágenes qcow2/raw) ---
  # Usamos el mismo storage temporal para descargar
  IMG_STORAGE="$STORAGE"

  # --- Bridge de red ---
  echo -e "\n${BOLD}Bridges de red disponibles:${NC}"
  local bridges=()
  while IFS= read -r line; do
    bridges+=("$line")
  done < <(ip link show | awk '/^[0-9]+: vmbr/{gsub(":",""); print $2}')

  if [[ ${#bridges[@]} -eq 0 ]]; then
    warn "No se detectaron bridges. Usando 'vmbr0'."
    bridges=("vmbr0")
  fi
  for i in "${!bridges[@]}"; do
    echo -e "    $((i+1))) ${CYAN}${bridges[$i]}${NC}"
  done
  local br_choice
  read -rp $'\n¿Qué bridge de red usar? [1]: ' br_choice
  br_choice="${br_choice:-1}"
  BRIDGE="${bridges[$((br_choice-1))]}"
  [[ -z "$BRIDGE" ]] && BRIDGE="${bridges[0]}"

  # --- Parámetros de la VM ---
  echo ""
  read -rp "$(echo -e "Nombre de la VM [${CYAN}${def_name}${NC}]: ")" VM_NAME
  VM_NAME="${VM_NAME:-$def_name}"

  read -rp "$(echo -e "Número de cores [${CYAN}${def_cores}${NC}]: ")" CORES
  CORES="${CORES:-$def_cores}"

  read -rp "$(echo -e "RAM en GB [${CYAN}${def_ram_gb}${NC}]: ")" RAM_GB
  RAM_GB="${RAM_GB:-$def_ram_gb}"
  RAM=$(( RAM_GB * 1024 ))

  read -rp "$(echo -e "Tamaño disco en GB [${CYAN}${def_disk}${NC}]: ")" DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-$def_disk}"

  read -rp "$(echo -e "VMID (vacío = autoasignar): ")" VMID
  [[ -z "$VMID" ]] && VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

  # --- Resumen ---
  echo ""
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Resumen — VM a crear${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "  Nombre   : ${CYAN}${VM_NAME}${NC}"
  echo -e "  VMID     : ${CYAN}${VMID}${NC}"
  echo -e "  Cores    : ${CYAN}${CORES}${NC}  |  RAM: ${CYAN}${RAM_GB} GB${NC}"
  echo -e "  Disco    : ${CYAN}${DISK_SIZE} GB${NC} en ${CYAN}${STORAGE}${NC}"
  echo -e "  Red      : ${CYAN}${BRIDGE}${NC}"
  echo -e "  Rocky    : ${CYAN}${ROCKY_VERSION}${NC} (Cloud Image)"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo ""

  local confirm
  read -rp "¿Confirmar y crear la VM? [s/N]: " confirm
  [[ ! "$confirm" =~ ^[sS]$ ]] && echo "Cancelado." && exit 0
}

# =============================================================================
# download_rocky_image
# Descarga la cloud image al directorio temporal del nodo
# =============================================================================
download_rocky_image() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  if [[ -f "$img_path" && -s "$img_path" ]]; then
    log "Cloud image ya existe en ${img_path}"
    return 0
  fi

  [[ -f "$img_path" ]] && rm -f "$img_path"

  info "Descargando Rocky ${ROCKY_VERSION} Cloud Image..."
  wget --progress=bar:force -O "$img_path" "$ROCKY_IMG_URL" 2>&1 \
    || error "No se pudo descargar la cloud image."
  log "Cloud image descargada → ${img_path}"
}

# =============================================================================
# create_vm
# Crea la VM, importa el disco y configura Cloud-Init
# =============================================================================
create_vm() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  info "Creando VM ${VMID} (${VM_NAME})..."
  qm status "$VMID" &>/dev/null && error "Ya existe una VM con ID ${VMID}"

  # Detectar formato según tipo de storage
  local storage_type
  storage_type=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $2}')
  local disk_format="qcow2"
  if [[ "$storage_type" == "lvmthin" || "$storage_type" == "lvm" || "$storage_type" == "zfspool" ]]; then
    disk_format="raw"
  fi
  info "Storage tipo '${storage_type}' → formato ${disk_format}"

  # Crear VM base (sin disco aún)
  qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --sockets 1 \
    --cores "$CORES" \
    --cpu x86-64-v3 \
    --memory "$RAM" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --vga std \
    --agent enabled=1 \
    || error "Fallo al crear la VM ${VMID}"

  # Importar la cloud image como disco
  info "Importando cloud image como disco..."
  qm importdisk "$VMID" "$img_path" "$STORAGE" --format "$disk_format" \
    || error "Fallo al importar el disco"

  # El disco importado queda como 'unusedX' — obtener su nombre exacto
  local disk_ref
  disk_ref=$(qm config "$VMID" | grep '^unused' | head -1 | awk -F: '{print $1}')
  local disk_val
  disk_val=$(qm config "$VMID" | grep "^${disk_ref}" | cut -d' ' -f2)
  [[ -z "$disk_val" ]] && error "No se encontró el disco importado en la VM ${VMID}"

  # Asignar el disco importado a scsi0
  qm set "$VMID" --scsi0 "${disk_val},discard=on" \
    || error "Fallo al asignar el disco a scsi0"

  # Añadir disco Cloud-Init
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

  # Boot desde disco
  qm set "$VMID" --boot "order=scsi0"

  # Redimensionar disco al tamaño elegido
  info "Redimensionando disco a ${DISK_SIZE}GB..."
  qm resize "$VMID" scsi0 "${DISK_SIZE}G" \
    || warn "No se pudo redimensionar — el disco quedará con el tamaño de la imagen base (~10GB)"

  # Configurar Cloud-Init
  info "Configurando Cloud-Init..."
  qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --searchdomain local \
    --nameserver 8.8.8.8

  log "VM ${VMID} creada y configurada"
}

# =============================================================================
# start_vm_and_wait — Arranca y espera al agente QEMU
# Con cloud image tarda ~30 segundos
# =============================================================================
start_vm_and_wait() {
  info "Arrancando VM ${VMID}..."
  qm start "$VMID" || error "No se pudo arrancar la VM"

  info "Esperando a que Rocky arranque (cloud image ~30 segundos)..."
  local timeout=300 elapsed=0
  while ! qm agent "$VMID" ping &>/dev/null; do
    sleep 5; elapsed=$((elapsed+5))
    [[ $elapsed -ge $timeout ]] && error "Timeout. Revisa la VM en la consola de Proxmox."
    printf "."
  done
  echo ""
  log "VM lista"
}

# =============================================================================
# get_vm_ip
# =============================================================================
get_vm_ip() {
  local ip="" attempts=0
  while [[ -z "$ip" && $attempts -lt 12 ]]; do
    ip=$(qm agent "$VMID" network-get-interfaces 2>/dev/null \
      | grep -oP '(?<="ip-address":")[^"]+' \
      | grep -v '127.0.0.1' | grep -v '^::' | head -1)
    sleep 5; attempts=$((attempts+1))
  done
  echo "$ip"
}

# =============================================================================
# post_install — Configuración post-arranque vía agente QEMU
# Aplica todas las settings que pediste
# =============================================================================
post_install() {
  info "Aplicando configuración post-instalación..."

  qm agent "$VMID" exec -- bash -c "
    # Desactivar SELinux
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null || true

    # Desactivar firewall
    systemctl disable --now firewalld 2>/dev/null || true

    # Teclado español
    localectl set-keymap es
    localectl set-x11-keymap es

    # Timezone Madrid
    timedatectl set-timezone Europe/Madrid

    # Idioma inglés
    localectl set-locale LANG=en_US.UTF-8

    # Actualizar sistema
    dnf update -y -q

    # Habilitar qemu-guest-agent (por si acaso)
    systemctl enable --now qemu-guest-agent 2>/dev/null || true
  " && log "Configuración aplicada" || warn "Algún paso de configuración falló — revisa manualmente"
}

# =============================================================================
# print_summary
# =============================================================================
print_summary() {
  local ip="$1" extra="$2"
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        INSTALACIÓN COMPLETADA ✔          ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC} VM ID   : ${CYAN}${VMID}${NC}"
  echo -e "${GREEN}║${NC} Nombre  : ${CYAN}${VM_NAME}${NC}"
  echo -e "${GREEN}║${NC} IP      : ${CYAN}${ip:-'Ver DHCP del router'}${NC}"
  echo -e "${GREEN}║${NC} Usuario : ${CYAN}root${NC}  /  Pass: ${CYAN}Ab12345${NC}"
  echo -e "${GREEN}║${NC} Rocky   : ${CYAN}${ROCKY_VERSION}${NC}"
  [[ -n "$extra" ]] && echo -e "${GREEN}║${NC} ${extra}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}[!]${NC} Fija la IP ${ip} por MAC en tu firewall/DHCP"
  echo ""
}
