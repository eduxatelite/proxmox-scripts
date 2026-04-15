#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Librería base compartida para scripts VFX
# Usa Rocky 9.7 Cloud Image (sin instalador, arranca en ~30 segundos)
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

# --- Rocky 9.7 Cloud Image ---
ROCKY_VERSION="9.7"
ROCKY_IMG_URL="http://ftp.madrid.xatelite.com:5005/2026/Rocky-9-6.x86_64.qcow2"
ROCKY_IMG_NAME="Rocky-9-6.x86_64.qcow2"

# --- Cloud-Init: credenciales por defecto ---
CI_USER="root"
CI_PASSWORD="Ab12345"

# --- Variables globales rellenadas por el menú ---
VM_NAME=""
VMID=""
CORES=""
RAM=""
DISK_SIZE=""
STORAGE=""
BRIDGE=""
IMG_STORAGE=""
VLAN_TAG=""
NET0_EXTRA=""
VM_IP=""
VM_MAC=""

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
  IMG_STORAGE="$STORAGE"

  # --- Bridge de red ---
  echo -e "\n${BOLD}Bridges de red disponibles:${NC}"
  local bridges=()
  while IFS= read -r line; do
    bridges+=("$line")
  done < <(ip link show | awk -F': ' '/^[0-9]+: / && $2 !~ /^(lo|eth|ens|enp|bond|dummy|sit|tun|tap|wlan|docker|veth|virbr)/ {gsub("@.*","",$2); print $2}' | grep -v '^

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

  # --- VLAN ---
  echo ""
  echo -e "VLAN Tag (Enter = sin VLAN):"
  read -rp "> " VLAN_TAG
  if [[ -n "$VLAN_TAG" ]]; then
    NET0_EXTRA=",tag=${VLAN_TAG}"
  else
    NET0_EXTRA=""
  fi

  # --- Parámetros de la VM ---
  echo ""
  read -rp "Nombre de la VM [${def_name}]: " VM_NAME
  VM_NAME="${VM_NAME:-$def_name}"
  # Validar nombre: solo letras, números y guiones (no guión bajo)
  while [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; do
    warn "Nombre inválido — solo letras, números y guiones (-). Sin espacios ni guiones bajos (_)."
    read -rp "Nombre de la VM [${def_name}]: " VM_NAME
    VM_NAME="${VM_NAME:-$def_name}"
  done

  read -rp "Número de cores [${def_cores}]: " CORES
  CORES="${CORES:-$def_cores}"

  read -rp "RAM en GB [${def_ram_gb}]: " RAM_GB
  RAM_GB="${RAM_GB:-$def_ram_gb}"
  RAM=$(( RAM_GB * 1024 ))

  read -rp "Tamaño disco en GB [${def_disk}]: " DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-$def_disk}"

  read -rp "VMID (vacío = autoasignar): " VMID
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
  echo -e "  Red      : ${CYAN}${BRIDGE}${NC}${VLAN_TAG:+ (VLAN ${VLAN_TAG})}"
  echo -e "  Rocky    : ${CYAN}${ROCKY_VERSION}${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo ""

  local confirm
  read -rp "¿Confirmar y crear la VM? [s/N]: " confirm
  [[ ! "$confirm" =~ ^[sS]$ ]] && echo "Cancelado." && exit 0
}

# =============================================================================
# download_rocky_image
# =============================================================================
download_rocky_image() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  if [[ -f "$img_path" && -s "$img_path" ]]; then
    log "Imagen ya existe en ${img_path}"
    return 0
  fi

  [[ -f "$img_path" ]] && rm -f "$img_path"

  info "Descargando Rocky ${ROCKY_VERSION}..."
  wget --progress=bar:force -O "$img_path" "$ROCKY_IMG_URL" 2>&1 \
    || error "No se pudo descargar la cloud image."
  log "Cloud image descargada → ${img_path}"
}

# =============================================================================
# create_vm
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
    --net0 "virtio,bridge=${BRIDGE}${NET0_EXTRA}" \
    --scsihw virtio-scsi-single \
    --vga std \
    --agent enabled=1 \
    || error "Fallo al crear la VM ${VMID}"

  # Importar la cloud image como disco
  info "Importando cloud image como disco..."
  qm importdisk "$VMID" "$img_path" "$STORAGE" --format "$disk_format" \
    || error "Fallo al importar el disco"

  # El disco importado queda como 'unusedX' — obtener su nombre exacto
  local disk_ref disk_val
  disk_ref=$(qm config "$VMID" | grep '^unused' | head -1 | awk -F: '{print $1}')
  disk_val=$(qm config "$VMID" | grep "^${disk_ref}" | cut -d' ' -f2)
  [[ -z "$disk_val" ]] && error "No se encontró el disco importado en la VM ${VMID}"

  # Asignar disco a scsi0
  qm set "$VMID" --scsi0 "${disk_val},discard=on" \
    || error "Fallo al asignar el disco a scsi0"

  # Cloud-Init y boot
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --boot "order=scsi0"

  # Redimensionar disco
  info "Redimensionando disco a ${DISK_SIZE}GB..."
  qm resize "$VMID" scsi0 "${DISK_SIZE}G" \
    || warn "No se pudo redimensionar el disco"

  # Configurar Cloud-Init
  info "Configurando Cloud-Init..."

  # Script de usuario que se ejecuta en el primer arranque
  local userdata_file="/tmp/userdata-${VMID}.yml"
  cat > "$userdata_file" << EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local
manage_etc_hosts: true
chpasswd:
  list: |
    root:${CI_PASSWORD}
  expire: false
ssh_pwauth: true
disable_root: false
runcmd:
  - sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  - setenforce 0
  - systemctl disable --now firewalld
  - localectl set-keymap es
  - timedatectl set-timezone Europe/Madrid
  - localectl set-locale LANG=en_US.UTF-8
  - dnf update -y -q
  - systemctl restart qemu-guest-agent
EOF

  qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --searchdomain local \
    --nameserver 8.8.8.8 \
    --cicustom "user=local:snippets/userdata-${VMID}.yml"

  # Copiar el userdata al storage local de snippets
  mkdir -p /var/lib/vz/snippets/
  cp "$userdata_file" "/var/lib/vz/snippets/userdata-${VMID}.yml"
  rm -f "$userdata_file"

  log "VM ${VMID} creada y configurada"
}

# =============================================================================
# start_vm_and_wait
# =============================================================================
start_vm_and_wait() {
  info "Arrancando VM ${VMID}..."
  qm start "$VMID" || error "No se pudo arrancar la VM"

  info "Esperando a que Rocky arranque..."
  local timeout=300 elapsed=0
  while ! qm agent "$VMID" ping &>/dev/null; do
    sleep 5; elapsed=$((elapsed+5))
    [[ $elapsed -ge $timeout ]] && error "Timeout. Revisa la VM en la consola de Proxmox."
    printf "."
  done
  echo ""
  log "VM lista — Rocky arrancado"

  # Esperar a que Cloud-Init termine (dnf update tarda ~3-5 min)
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0 waited=0 total=240
  while [[ $waited -lt $total ]]; do
    printf "\r  ${CYAN}%s${NC} Actualizando Rocky ${ROCKY_VERSION}... (%ds/%ds)" \
      "${spinner:$((i%10)):1}" "$waited" "$total"
    sleep 3; i=$((i+1)); waited=$((waited+3))
  done
  printf "\r  ${GREEN}✔${NC} Sistema actualizado                              \n"
}

# =============================================================================
# get_vm_ip_and_mac
# =============================================================================
get_vm_ip_and_mac() {
  local ip="" mac="" attempts=0
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while [[ -z "$ip" && $attempts -lt 24 ]]; do
    local ifaces
    ifaces=$(qm agent "$VMID" network-get-interfaces 2>/dev/null)
    # Extraer IPs IPv4 ignorando loopback
    ip=$(echo "$ifaces" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data:
    if iface.get('name') == 'lo':
        continue
    for addr in iface.get('ip-addresses', []):
        if addr.get('ip-address-type') == 'ipv4':
            print(addr['ip-address'])
            sys.exit()
" 2>/dev/null)
    mac=$(echo "$ifaces" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data:
    hw = iface.get('hardware-address','')
    if hw and hw != '00:00:00:00:00:00':
        print(hw)
        sys.exit()
" 2>/dev/null)
    if [[ -z "$ip" ]]; then
      printf "\r  ${CYAN}%s${NC} Esperando IP por DHCP..." "${spinner:$((i%10)):1}"
      sleep 5
      i=$((i+1))
    fi
    attempts=$((attempts+1))
  done
  printf "\r                                        \r"
  VM_IP="$ip"
  VM_MAC="$mac"
}

# =============================================================================
# post_install
# =============================================================================
post_install() {
  info "Configuración aplicada vía Cloud-Init (SELinux, timezone, teclado)"
  log "La configuración se aplica automáticamente en el primer arranque"
}

# =============================================================================
# print_summary
# =============================================================================
print_summary() {
  local ip="$1" mac="$2" extra="$3"
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        INSTALACIÓN COMPLETADA ✔          ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC} VM ID   : ${CYAN}${VMID}${NC}"
  echo -e "${GREEN}║${NC} Nombre  : ${CYAN}${VM_NAME}${NC}"
  echo -e "${GREEN}║${NC} IP      : ${CYAN}${ip:-'Ver DHCP del router'}${NC}"
  echo -e "${GREEN}║${NC} MAC     : ${CYAN}${mac:-'No detectada'}${NC}"
  echo -e "${GREEN}║${NC} Usuario : ${CYAN}root${NC}  /  Pass: ${CYAN}Ab12345${NC}"
  echo -e "${GREEN}║${NC} Rocky   : ${CYAN}${ROCKY_VERSION}${NC}"
  [[ -n "$extra" ]] && echo -e "${GREEN}║${NC} ${extra}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}[!]${NC} Fija la IP ${ip:-'?'} → MAC ${mac:-'?'} en tu firewall/DHCP"
  echo ""
}
)

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

  # --- VLAN ---
  echo ""
  echo -e "VLAN Tag (Enter = sin VLAN):"
  read -rp "> " VLAN_TAG
  if [[ -n "$VLAN_TAG" ]]; then
    NET0_EXTRA=",tag=${VLAN_TAG}"
  else
    NET0_EXTRA=""
  fi

  # --- Parámetros de la VM ---
  echo ""
  read -rp "Nombre de la VM [${def_name}]: " VM_NAME
  VM_NAME="${VM_NAME:-$def_name}"
  # Validar nombre: solo letras, números y guiones (no guión bajo)
  while [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; do
    warn "Nombre inválido — solo letras, números y guiones (-). Sin espacios ni guiones bajos (_)."
    read -rp "Nombre de la VM [${def_name}]: " VM_NAME
    VM_NAME="${VM_NAME:-$def_name}"
  done

  read -rp "Número de cores [${def_cores}]: " CORES
  CORES="${CORES:-$def_cores}"

  read -rp "RAM en GB [${def_ram_gb}]: " RAM_GB
  RAM_GB="${RAM_GB:-$def_ram_gb}"
  RAM=$(( RAM_GB * 1024 ))

  read -rp "Tamaño disco en GB [${def_disk}]: " DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-$def_disk}"

  read -rp "VMID (vacío = autoasignar): " VMID
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
  echo -e "  Red      : ${CYAN}${BRIDGE}${NC}${VLAN_TAG:+ (VLAN ${VLAN_TAG})}"
  echo -e "  Rocky    : ${CYAN}${ROCKY_VERSION}${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo ""

  local confirm
  read -rp "¿Confirmar y crear la VM? [s/N]: " confirm
  [[ ! "$confirm" =~ ^[sS]$ ]] && echo "Cancelado." && exit 0
}

# =============================================================================
# download_rocky_image
# =============================================================================
download_rocky_image() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  if [[ -f "$img_path" && -s "$img_path" ]]; then
    log "Imagen ya existe en ${img_path}"
    return 0
  fi

  [[ -f "$img_path" ]] && rm -f "$img_path"

  info "Descargando Rocky ${ROCKY_VERSION}..."
  wget --progress=bar:force -O "$img_path" "$ROCKY_IMG_URL" 2>&1 \
    || error "No se pudo descargar la cloud image."
  log "Cloud image descargada → ${img_path}"
}

# =============================================================================
# create_vm
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
    --net0 "virtio,bridge=${BRIDGE}${NET0_EXTRA}" \
    --scsihw virtio-scsi-single \
    --vga std \
    --agent enabled=1 \
    || error "Fallo al crear la VM ${VMID}"

  # Importar la cloud image como disco
  info "Importando cloud image como disco..."
  qm importdisk "$VMID" "$img_path" "$STORAGE" --format "$disk_format" \
    || error "Fallo al importar el disco"

  # El disco importado queda como 'unusedX' — obtener su nombre exacto
  local disk_ref disk_val
  disk_ref=$(qm config "$VMID" | grep '^unused' | head -1 | awk -F: '{print $1}')
  disk_val=$(qm config "$VMID" | grep "^${disk_ref}" | cut -d' ' -f2)
  [[ -z "$disk_val" ]] && error "No se encontró el disco importado en la VM ${VMID}"

  # Asignar disco a scsi0
  qm set "$VMID" --scsi0 "${disk_val},discard=on" \
    || error "Fallo al asignar el disco a scsi0"

  # Cloud-Init y boot
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --boot "order=scsi0"

  # Redimensionar disco
  info "Redimensionando disco a ${DISK_SIZE}GB..."
  qm resize "$VMID" scsi0 "${DISK_SIZE}G" \
    || warn "No se pudo redimensionar el disco"

  # Configurar Cloud-Init
  info "Configurando Cloud-Init..."

  # Script de usuario que se ejecuta en el primer arranque
  local userdata_file="/tmp/userdata-${VMID}.yml"
  cat > "$userdata_file" << EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local
manage_etc_hosts: true
chpasswd:
  list: |
    root:${CI_PASSWORD}
  expire: false
ssh_pwauth: true
disable_root: false
runcmd:
  - sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  - setenforce 0
  - systemctl disable --now firewalld
  - localectl set-keymap es
  - timedatectl set-timezone Europe/Madrid
  - localectl set-locale LANG=en_US.UTF-8
  - dnf update -y -q
  - systemctl restart qemu-guest-agent
EOF

  qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --searchdomain local \
    --nameserver 8.8.8.8 \
    --cicustom "user=local:snippets/userdata-${VMID}.yml"

  # Copiar el userdata al storage local de snippets
  mkdir -p /var/lib/vz/snippets/
  cp "$userdata_file" "/var/lib/vz/snippets/userdata-${VMID}.yml"
  rm -f "$userdata_file"

  log "VM ${VMID} creada y configurada"
}

# =============================================================================
# start_vm_and_wait
# =============================================================================
start_vm_and_wait() {
  info "Arrancando VM ${VMID}..."
  qm start "$VMID" || error "No se pudo arrancar la VM"

  info "Esperando a que Rocky arranque..."
  local timeout=300 elapsed=0
  while ! qm agent "$VMID" ping &>/dev/null; do
    sleep 5; elapsed=$((elapsed+5))
    [[ $elapsed -ge $timeout ]] && error "Timeout. Revisa la VM en la consola de Proxmox."
    printf "."
  done
  echo ""
  log "VM lista — Rocky arrancado"

  # Esperar a que Cloud-Init termine (dnf update tarda ~3-5 min)
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0 waited=0 total=240
  while [[ $waited -lt $total ]]; do
    printf "\r  ${CYAN}%s${NC} Actualizando Rocky ${ROCKY_VERSION}... (%ds/%ds)" \
      "${spinner:$((i%10)):1}" "$waited" "$total"
    sleep 3; i=$((i+1)); waited=$((waited+3))
  done
  printf "\r  ${GREEN}✔${NC} Sistema actualizado                              \n"
}

# =============================================================================
# get_vm_ip_and_mac
# =============================================================================
get_vm_ip_and_mac() {
  local ip="" mac="" attempts=0
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while [[ -z "$ip" && $attempts -lt 24 ]]; do
    local ifaces
    ifaces=$(qm agent "$VMID" network-get-interfaces 2>/dev/null)
    # Extraer IPs IPv4 ignorando loopback
    ip=$(echo "$ifaces" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data:
    if iface.get('name') == 'lo':
        continue
    for addr in iface.get('ip-addresses', []):
        if addr.get('ip-address-type') == 'ipv4':
            print(addr['ip-address'])
            sys.exit()
" 2>/dev/null)
    mac=$(echo "$ifaces" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iface in data:
    hw = iface.get('hardware-address','')
    if hw and hw != '00:00:00:00:00:00':
        print(hw)
        sys.exit()
" 2>/dev/null)
    if [[ -z "$ip" ]]; then
      printf "\r  ${CYAN}%s${NC} Esperando IP por DHCP..." "${spinner:$((i%10)):1}"
      sleep 5
      i=$((i+1))
    fi
    attempts=$((attempts+1))
  done
  printf "\r                                        \r"
  VM_IP="$ip"
  VM_MAC="$mac"
}

# =============================================================================
# post_install
# =============================================================================
post_install() {
  info "Configuración aplicada vía Cloud-Init (SELinux, timezone, teclado)"
  log "La configuración se aplica automáticamente en el primer arranque"
}

# =============================================================================
# print_summary
# =============================================================================
print_summary() {
  local ip="$1" mac="$2" extra="$3"
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        INSTALACIÓN COMPLETADA ✔          ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC} VM ID   : ${CYAN}${VMID}${NC}"
  echo -e "${GREEN}║${NC} Nombre  : ${CYAN}${VM_NAME}${NC}"
  echo -e "${GREEN}║${NC} IP      : ${CYAN}${ip:-'Ver DHCP del router'}${NC}"
  echo -e "${GREEN}║${NC} MAC     : ${CYAN}${mac:-'No detectada'}${NC}"
  echo -e "${GREEN}║${NC} Usuario : ${CYAN}root${NC}  /  Pass: ${CYAN}Ab12345${NC}"
  echo -e "${GREEN}║${NC} Rocky   : ${CYAN}${ROCKY_VERSION}${NC}"
  [[ -n "$extra" ]] && echo -e "${GREEN}║${NC} ${extra}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}[!]${NC} Fija la IP ${ip:-'?'} → MAC ${mac:-'?'} en tu firewall/DHCP"
  echo ""
}
