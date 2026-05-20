#!/usr/bin/env bash
# =============================================================================
# rocky-base.sh — VM base Rocky 9.7 (Cloud Image, sin software adicional)
# Uso: bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/scripts/base/rocky-base.sh)
# =============================================================================

source <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/lib/common.sh)

main() {
  check_root
  header "Rocky ${ROCKY_VERSION} — VM Base"

  ask_config "rocky-base" "4" "4" "50"

  download_rocky_image
  create_vm
  start_vm_and_wait
  post_install

  info "Obteniendo IP y MAC..."
  get_vm_ip_and_mac
  print_summary "$VM_IP" "$VM_MAC"
}

main "$@"
