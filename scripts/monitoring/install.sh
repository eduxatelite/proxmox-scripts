#!/usr/bin/env bash
# Alias del despliegue de monitorización. El script real es monitoring/deploy.sh:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/monitoring/deploy.sh)
exec bash <(curl -fsSL https://raw.githubusercontent.com/eduxatelite/proxmox-scripts/main/monitoring/deploy.sh)
