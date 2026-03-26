#!/usr/bin/env bash
# =============================================================================
# rocky-base.sh — VM base Rocky 9.6, sin software adicional
# Uso: bash <(curl -s https://raw.githubusercontent.com/TU_USUARIO/proxmox-vfx-scripts/main/scripts/base/rocky-base.sh)
# =============================================================================

source <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/lib/common.sh)

main() {
  check_root
  header "Rocky 9.6 — VM Base"

  # Menú interactivo: pregunta storage, bridge, nombre, cores, RAM, disco, VMID
  # Valores por defecto: nombre=rocky-base, cores=4, RAM=4096MB, disco=50GB
  ask_config "rocky-base" "4" "4096" "50"

  download_rocky_iso
  create_vm
  start_vm_and_wait

  info "Obteniendo IP..."
  VM_IP=$(get_vm_ip)
  print_summary "$VM_IP"
}

main "$@"
