# shellcheck shell=bash
MOD_DESC="Proxmox VE: pve-exporter (API token) + node_exporter opcional + dashboard"
MOD_FOLDER="Proxmox"   # carpeta en Grafana
MOD_DEPENDS=""
proxmox_defaults() {
  : "${PVE_USER:=monitoring@pve}"
  : "${PVE_TOKEN_NAME:=grafana}"
  : "${PVE_VERIFY_SSL:=false}"
  : "${PVE_NODE_EXPORTER:=no}"
}
proxmox_validate() { require_vars proxmox PVE_NODES PVE_TOKEN_VALUE; list_ips "$PVE_NODES" >/dev/null; }
proxmox_render() {
  local f="$STAGE/config/prometheus/scrape.d/proxmox.yml" first=1 item
  {
    echo "scrape_configs:"
    echo "  # El primer nodo aporta también las métricas de cluster (cluster=1);"
    echo "  # el resto solo las de nodo, para no duplicar series."
    echo "  - job_name: pve"
    echo "    metrics_path: /pve"
    echo "    params:"
    echo "      module: [default]"
    echo "      node: [\"1\"]"
    echo "    static_configs:"
    for item in $PVE_NODES; do
      echo "      - targets: [\"${item#*:}\"]"
      echo "        labels:"
      echo "          pve_alias: \"${item%%:*}\""
      echo "          __param_cluster: \"${first}\""
      first=0
    done
    echo "    relabel_configs:"
    echo "      - source_labels: [__address__]"
    echo "        target_label: __param_target"
    echo "      - source_labels: [__param_target]"
    echo "        target_label: instance"
    echo "      - target_label: __address__"
    echo "        replacement: pve-exporter:9221"
    if [[ "$PVE_NODE_EXPORTER" == "yes" ]]; then
      echo
      echo "  - job_name: pve_node"
      echo "    static_configs:"
      targets_yaml "$PVE_NODES" 9100 node
    fi
  } > "$f"
}
proxmox_post_install() {
  section "Proxmox — token de solo lectura (una vez, en cualquier nodo del cluster)"
  cat <<CMD
pveum user add ${PVE_USER} --comment "Monitorizacion Xatelite" 2>/dev/null; \\
pveum acl modify / --users ${PVE_USER} --roles PVEAuditor && \\
pveum user token add ${PVE_USER} ${PVE_TOKEN_NAME} --privsep 0
CMD
  echo "  → copiar el 'value' a PVE_TOKEN_VALUE del .env y relanzar install.sh"
  echo
  echo -e "  ${BOLD}onboot de TODAS las VMs del cluster${NC} (en cada nodo):  bash tools/comprobar-onboot.sh"
  if [[ "$PVE_NODE_EXPORTER" == "yes" ]]; then
    echo
    echo -e "  ${BOLD}node_exporter en cada nodo${NC} (desde esta VM):"
    for ip in $(list_ips "$PVE_NODES"); do
      echo "    ssh root@${ip} 'bash -s' < ${REPO_DIR}/tools/instalar-node-exporter.sh"
    done
  fi
}
