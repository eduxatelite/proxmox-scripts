#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared base library for VFX scripts
# =============================================================================

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}";
           echo -e "${BLUE}  $1${NC}";
           echo -e "${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Rocky 9.7 ---
ROCKY_VERSION="9.7"
ROCKY_IMG_URL="http://ftp.madrid.xatelite.com:5005/2026/Rocky-9-7.x86_64.qcow2"
ROCKY_IMG_NAME="Rocky-9-7.x86_64.qcow2"

# --- Cloud-Init ---
CI_USER="root"
CI_PASSWORD="Ab12345"

# --- Global variables ---
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
  [[ $EUID -ne 0 ]] && error "Run this script as root on the Proxmox node"
  command -v qm &>/dev/null || error "This script must be run on a Proxmox VE node"
}

# =============================================================================
# ask_config
# =============================================================================
ask_config() {
  local def_name="${1:-rocky-vm}"
  local def_cores="${2:-4}"
  local def_ram_gb="${3:-4}"
  local def_disk="${4:-50}"

  header "VM Configuration"

  # --- Storage ---
  echo -e "${BOLD}Available storages on this node:${NC}"
  local storages=()
  while IFS= read -r line; do
    storages+=("$line")
  done < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

  if [[ ${#storages[@]} -eq 0 ]]; then
    warn "No storages detected. Using 'local-lvm' as default."
    storages=("local-lvm")
  fi
  for i in "${!storages[@]}"; do
    echo -e "    $((i+1))) ${CYAN}${storages[$i]}${NC}"
  done
  local st_choice
  read -rp $'\nWhich storage for the disk? [1]: ' st_choice
  st_choice="${st_choice:-1}"
  STORAGE="${storages[$((st_choice-1))]}"
  [[ -z "$STORAGE" ]] && STORAGE="${storages[0]}"
  IMG_STORAGE="$STORAGE"

  # --- Bridge ---
  echo -e "\n${BOLD}Available network bridges:${NC}"
  local bridges=()
  while IFS= read -r line; do
    bridges+=("$line")
  done < <(pvesh get /nodes/$(hostname)/network --type bridge --output-format json 2>/dev/null \
    | python3 -c "import sys,json; [print(i['iface']) for i in json.load(sys.stdin)]" \
    | sort)

  if [[ ${#bridges[@]} -eq 0 ]]; then
    warn "No bridges detected. Using 'vmbr0'."
    bridges=("vmbr0")
  fi
  for i in "${!bridges[@]}"; do
    echo -e "    $((i+1))) ${CYAN}${bridges[$i]}${NC}"
  done
  local br_choice
  read -rp $'\nWhich network bridge? [1]: ' br_choice
  br_choice="${br_choice:-1}"
  BRIDGE="${bridges[$((br_choice-1))]}"
  [[ -z "$BRIDGE" ]] && BRIDGE="${bridges[0]}"

  # --- VLAN ---
  echo ""
  echo -e "VLAN Tag (Enter = no VLAN):"
  read -rp "> " VLAN_TAG
  if [[ -n "$VLAN_TAG" ]]; then
    NET0_EXTRA=",tag=${VLAN_TAG}"
  else
    NET0_EXTRA=""
  fi

  # --- VM Parameters ---
  echo ""
  read -rp "VM name [${def_name}]: " VM_NAME
  VM_NAME="${VM_NAME:-$def_name}"
  while [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; do
    warn "Invalid name — only letters, numbers and hyphens (-)."
    read -rp "VM name [${def_name}]: " VM_NAME
    VM_NAME="${VM_NAME:-$def_name}"
  done

  read -rp "Number of cores [${def_cores}]: " CORES
  CORES="${CORES:-$def_cores}"

  read -rp "RAM in GB [${def_ram_gb}]: " RAM_GB
  RAM_GB="${RAM_GB:-$def_ram_gb}"
  RAM=$(( RAM_GB * 1024 ))

  read -rp "Disk size in GB [${def_disk}]: " DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-$def_disk}"

  read -rp "VMID (leave empty = auto-assign): " VMID
  [[ -z "$VMID" ]] && VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

  # --- Summary ---
  echo ""
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Summary — VM to create${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo -e "  Name     : ${CYAN}${VM_NAME}${NC}"
  echo -e "  VMID     : ${CYAN}${VMID}${NC}"
  echo -e "  Cores    : ${CYAN}${CORES}${NC}  |  RAM: ${CYAN}${RAM_GB} GB${NC}"
  echo -e "  Disk     : ${CYAN}${DISK_SIZE} GB${NC} on ${CYAN}${STORAGE}${NC}"
  echo -e "  Network  : ${CYAN}${BRIDGE}${NC}${VLAN_TAG:+ (VLAN ${VLAN_TAG})}"
  echo -e "  Rocky    : ${CYAN}${ROCKY_VERSION}${NC}"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
  echo ""

  local confirm
  read -rp "Confirm and create the VM? [y/N]: " confirm
  [[ ! "$confirm" =~ ^[yY]$ ]] && echo "Cancelled." && exit 0
}

# =============================================================================
# download_rocky_image
# =============================================================================
download_rocky_image() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  if [[ -f "$img_path" && -s "$img_path" ]]; then
    log "Image already exists at ${img_path}"
    return 0
  fi

  [[ -f "$img_path" ]] && rm -f "$img_path"

  info "Downloading Rocky ${ROCKY_VERSION}..."
  wget --progress=bar:force -O "$img_path" "$ROCKY_IMG_URL" 2>&1 \
    || error "Could not download the image."
  log "Image downloaded → ${img_path}"
}

# =============================================================================
# create_vm
# =============================================================================
create_vm() {
  local img_path="/tmp/${ROCKY_IMG_NAME}"

  info "Creating VM ${VMID} (${VM_NAME})..."
  qm status "$VMID" &>/dev/null && error "A VM with ID ${VMID} already exists"

  local storage_type
  storage_type=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $2}')
  local disk_format="qcow2"
  if [[ "$storage_type" == "lvmthin" || "$storage_type" == "lvm" || "$storage_type" == "zfspool" ]]; then
    disk_format="raw"
  fi
  info "Storage type '${storage_type}' → format ${disk_format}"

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
    || error "Failed to create VM ${VMID}"

  info "Importing image as disk..."
  qm importdisk "$VMID" "$img_path" "$STORAGE" --format "$disk_format" \
    || error "Failed to import disk"

  local disk_ref disk_val
  disk_ref=$(qm config "$VMID" | grep '^unused' | head -1 | awk -F: '{print $1}')
  disk_val=$(qm config "$VMID" | grep "^${disk_ref}" | cut -d' ' -f2)
  [[ -z "$disk_val" ]] && error "Imported disk not found"

  qm set "$VMID" --scsi0 "${disk_val},discard=on" || error "Failed to assign disk"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --boot "order=scsi0"

  info "Resizing disk to ${DISK_SIZE}GB..."
  qm resize "$VMID" scsi0 "${DISK_SIZE}G" || warn "Could not resize disk"

  info "Configuring Cloud-Init..."
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

  mkdir -p /var/lib/vz/snippets/
  cp "$userdata_file" "/var/lib/vz/snippets/userdata-${VMID}.yml"
  rm -f "$userdata_file"

  qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --searchdomain local \
    --nameserver 8.8.8.8 \
    --cicustom "user=local:snippets/userdata-${VMID}.yml"

  log "VM ${VMID} created and configured"
}

# =============================================================================
# start_vm_and_wait
# =============================================================================
start_vm_and_wait() {
  info "Starting VM ${VMID}..."
  qm start "$VMID" || error "Could not start the VM"

  info "Waiting for Rocky to boot..."
  local timeout=300 elapsed=0
  while ! qm agent "$VMID" ping &>/dev/null; do
    sleep 5; elapsed=$((elapsed+5))
    [[ $elapsed -ge $timeout ]] && error "Timeout. Check the VM in the Proxmox console."
    printf "."
  done
  echo ""
  log "VM ready — Rocky booted"

  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0 waited=0 total=240
  while [[ $waited -lt $total ]]; do
    printf "\r  ${CYAN}%s${NC} Updating Rocky ${ROCKY_VERSION}... (%ds/%ds)" \
      "${spinner:$((i%10)):1}" "$waited" "$total"
    sleep 3; i=$((i+1)); waited=$((waited+3))
  done
  printf "\r  ${GREEN}✔${NC} System updated                                   \n"
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
      printf "\r  ${CYAN}%s${NC} Waiting for DHCP IP..." "${spinner:$((i%10)):1}"
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
  info "Configuration applied via Cloud-Init (SELinux, timezone, keyboard, dnf update)"
  log "Settings are applied automatically on first boot"
}

# =============================================================================
# print_summary
# =============================================================================
print_summary() {
  local ip="$1" mac="$2" extra="$3"
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        INSTALLATION COMPLETE ✔           ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC} VM ID   : ${CYAN}${VMID}${NC}"
  echo -e "${GREEN}║${NC} Name    : ${CYAN}${VM_NAME}${NC}"
  echo -e "${GREEN}║${NC} IP      : ${CYAN}${ip:-'Check DHCP on your router'}${NC}"
  echo -e "${GREEN}║${NC} MAC     : ${CYAN}${mac:-'Not detected'}${NC}"
  echo -e "${GREEN}║${NC} User    : ${CYAN}root${NC}  /  Pass: ${CYAN}Ab12345${NC}"
  echo -e "${GREEN}║${NC} Rocky   : ${CYAN}${ROCKY_VERSION}${NC}"
  [[ -n "$extra" ]] && echo -e "${GREEN}║${NC} ${extra}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}[!]${NC} Set a static lease for IP ${ip:-'?'} → MAC ${mac:-'?'} on your firewall/DHCP"
  echo ""
}
