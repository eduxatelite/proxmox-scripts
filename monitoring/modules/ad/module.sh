# shellcheck shell=bash
MOD_DESC="Active Directory: windows_exporter + eventos de seguridad (Alloy) + alertas"
MOD_FOLDER="Domain Controllers"   # carpeta en Grafana
MOD_DEPENDS=""
ad_defaults() {
  : "${ALERT_AD_BRUTEFORCE:=10}"
  : "${ALERT_AD_LOCKOUTS:=3}"
  : "${ALERT_DC_DISK_FREE_PCT:=10}"
}
ad_validate() { require_vars ad AD_DCS; list_ips "$AD_DCS" >/dev/null; }
# Los DCs empujan a Loki → se añaden a la lista blanca del 3100
ad_loki_sources() { list_ips "$AD_DCS"; }
ad_render() {
  {
    echo "scrape_configs:"
    echo "  - job_name: windows_dc"
    echo "    static_configs:"
    targets_yaml "$AD_DCS" 9182 dc_name
  } > "$STAGE/config/prometheus/scrape.d/ad.yml"
}
ad_post_install() {
  section "Active Directory — en CADA DC, PowerShell como administrador"
  local item
  for item in $AD_DCS; do
    echo -e "  ${BOLD}${item%%:*}${NC} (${item#*:}):"
    echo "    .\\instalar-agentes-windows.ps1 -MonitoringVM ${VM_IP} -DCName ${item%%:*}"
  done
  echo
  echo "  El script está en agentes/windows/ del repo. GPO de auditoría: docs/INVENTARIO-STACK.md §8"
  warn "Tras enlazar la GPO con security filtering: reiniciar el DC o 'klist -li 0x3e7 purge'. gpupdate no basta."
}
