#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Librería base compartida para scripts VFX
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

# --- ISO y Kickstart ---
ROCKY_ISO_URL="http://ftp.madrid.xatelite.com:5005/2026/Rocky-9.6-x86_64-minimal.iso"
ROCKY_ISO_NAME="Rocky-9.6-x86_64-minimal.iso"
KS_URL="https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/kickstart/rocky9-base.ks"

# Variables que se rellenan con el menú interactivo
VM_NAME=""
VMID=""
CORES=""
RAM=""
DISK_SIZE=""
STORAGE=""
BRIDGE=""
ISO_STORAGE=""

# =============================================================================
# check_root
# =============================================================================
check_root() {
  [[ $EUID -ne 0 ]] && error "Ejecuta este script como root en el nodo Proxmox"
  command -v qm &>/dev/null || error "Este script debe ejecutarse en un nodo Proxmox VE"
}

# =============================================================================
# ask_config DEFAULT_NAME DEFAULT_CORES DEFAULT_RAM DEFAULT_DISK
# Muestra el menú interactivo y rellena las variables globales
# =============================================================================
ask_config() {
  local def_name="${1:-rocky-vm}"
  local def_cores="${2:-4}"
  local def_ram="${3:-4096}"
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

  # --- Storage para la ISO ---
  echo -e "\n${BOLD}Storages disponibles para ISOs:${NC}"
  local iso_storages=()
  while IFS= read -r line; do
    iso_storages+=("$line")
  done < <(pvesm status --content iso 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

  if [[ ${#iso_storages[@]} -eq 0 ]]; then
    warn "No se detectaron storages con ISOs. Usando 'local'."
    iso_storages=("local")
  fi

  for i in "${!iso_storages[@]}"; do
    echo -e "    $((i+1))) ${CYAN}${iso_storages[$i]}${NC}"
  done

  local iso_choice
  read -rp $'\n¿En qué storage guardar/buscar la ISO? [1]: ' iso_choice
  iso_choice="${iso_choice:-1}"
  ISO_STORAGE="${iso_storages[$((iso_choice-1))]}"
  [[ -z "$ISO_STORAGE" ]] && ISO_STORAGE="${iso_storages[0]}"

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

  local def_ram_gb=$(( def_ram / 1024 ))
  read -rp "$(echo -e "RAM en GB [${CYAN}${def_ram_gb}${NC}]: ")" RAM_GB
  RAM_GB="${RAM_GB:-$def_ram_gb}"
  RAM=$(( RAM_GB * 1024 ))

  read -rp "$(echo -e "Tamaño disco en GB [${CYAN}${def_disk}${NC}]: ")" DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-$def_disk}"

  read -rp "$(echo -e "VMID (vacío = autoasignar): ")" VMID
  [[ -z "$VMID" ]] && VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

  # --- Resumen y confirmación ---
  echo ""
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Resumen — VM a crear${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "  Nombre   : ${CYAN}${VM_NAME}${NC}"
  echo -e "  VMID     : ${CYAN}${VMID}${NC}"
  echo -e "  Cores    : ${CYAN}${CORES}${NC}  |  RAM: ${CYAN}${RAM} MB${NC}"
  echo -e "  Disco    : ${CYAN}${DISK_SIZE} GB${NC} en ${CYAN}${STORAGE}${NC}"
  echo -e "  Red      : ${CYAN}${BRIDGE}${NC}"
  echo -e "  ISO en   : ${CYAN}${ISO_STORAGE}${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo ""

  local confirm
  read -rp "¿Confirmar y crear la VM? [s/N]: " confirm
  [[ ! "$confirm" =~ ^[sS]$ ]] && echo "Cancelado." && exit 0
}

# =============================================================================
# download_rocky_iso
# =============================================================================
download_rocky_iso() {
  local iso_dir="/var/lib/vz/template/iso"

  local real_path
  real_path=$(pvesm path "${ISO_STORAGE}:iso/${ROCKY_ISO_NAME}" 2>/dev/null)
  if [[ -n "$real_path" ]]; then
    iso_dir=$(dirname "$real_path")
  fi

  local iso_path="${iso_dir}/${ROCKY_ISO_NAME}"

  if [[ -f "$iso_path" && -s "$iso_path" ]]; then
    log "ISO ya existe en ${iso_path}"
    return 0
  fi

  # Borrar fichero vacío si quedó de un intento anterior
  [[ -f "$iso_path" ]] && rm -f "$iso_path"

  info "Descargando Rocky 9.6 desde FTP..."
  mkdir -p "$iso_dir"
  wget --progress=bar:force -O "$iso_path" "$ROCKY_ISO_URL" 2>&1 \
    || error "No se pudo descargar la ISO. Comprueba la conexión o la URL del FTP."
  log "ISO descargada → ${iso_path}"
}

# =============================================================================
# create_vm
# =============================================================================
create_vm() {
  info "Creando VM ${VMID} (${VM_NAME})..."

  qm status "$VMID" &>/dev/null && error "Ya existe una VM con ID ${VMID}"

  # Detectar tipo de storage para elegir el formato correcto
  local storage_type
  storage_type=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $2}')
  local disk_format="qcow2"
  if [[ "$storage_type" == "lvmthin" || "$storage_type" == "lvm" || "$storage_type" == "zfspool" ]]; then
    disk_format="raw"
  fi
  info "Storage tipo '${storage_type}' → usando formato ${disk_format}"

  qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine i440fx \
    --bios seabios \
    --sockets 1 \
    --cores "$CORES" \
    --cpu x86-64-v3 \
    --memory "$RAM" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK_SIZE},format=${disk_format},iothread=1" \
    --ide2 "${ISO_STORAGE}:iso/${ROCKY_ISO_NAME},media=cdrom" \
    --boot "order=ide2;scsi0" \
    --vga std \
    --agent enabled=1 \
    || error "Fallo al crear la VM ${VMID}"

  log "VM ${VMID} creada"
}

# =============================================================================
# start_vm_and_wait — Arranca y espera al agente QEMU (max 10 min)
# =============================================================================
start_vm_and_wait() {
  info "Arrancando VM ${VMID}..."
  qm start "$VMID" || error "No se pudo arrancar la VM"

  info "Esperando a que Rocky se instale y el agente QEMU responda..."
  info "(La primera vez puede tardar 5-8 minutos mientras instala el SO)"
  local timeout=600 elapsed=0
  while ! qm agent "$VMID" ping &>/dev/null; do
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $timeout ]] && error "Timeout esperando el agente QEMU. Revisa la VM en la consola de Proxmox."
    printf "."
  done
  echo ""
  log "VM lista"
}

# =============================================================================
# get_vm_ip — Obtiene la IP por DHCP
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
  [[ -n "$extra" ]] && echo -e "${GREEN}║${NC} ${extra}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}[!]${NC} Fija la IP ${ip} por MAC en tu firewall/DHCP"
  echo ""
}
