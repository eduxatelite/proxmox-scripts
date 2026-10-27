#!/usr/bin/env bash
# =============================================================================
# comprobar-onboot.sh — VMs del nodo Proxmox que NO arrancan solas tras reinicio
#
#   bash comprobar-onboot.sh            # solo informa
#   bash comprobar-onboot.sh --fix      # pone onboot=1 en las que no lo tienen
#   bash comprobar-onboot.sh --fix 105  # solo en la VM 105
#
# Lanzar en CADA nodo del cluster (qm solo ve las VMs del nodo local).
# Avería real: VM de monitorización con onboot:0, 82 días caída sin aviso.
# =============================================================================
set -uo pipefail
command -v qm >/dev/null || { echo "Esto se lanza en un nodo Proxmox"; exit 1; }
FIX=false; ONLY=""
[[ "${1:-}" == "--fix" ]] && { FIX=true; ONLY="${2:-}"; }

for id in $(qm list | awk 'NR>1 {print $1}'); do
  [[ -n "$ONLY" && "$id" != "$ONLY" ]] && continue
  nombre=$(qm config "$id" | awk -F': ' '/^name:/ {print $2}')
  if qm config "$id" | grep -q '^onboot: 1'; then
    echo "OK    VM $id  $nombre"
  elif $FIX; then
    qm set "$id" --onboot 1 >/dev/null && echo "FIJADO VM $id  $nombre -> onboot 1"
  else
    echo "AVISO VM $id  $nombre  -> no arranca sola tras reinicio del host"
  fi
done
