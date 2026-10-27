# shellcheck shell=bash
MOD_DESC="Dashboard de auditoría TPN (AD, FortiGate, Synology, Jump Desktop)"
MOD_FOLDER="Auditoría TPN"   # carpeta en Grafana
MOD_DEPENDS="ad"
tpn_audit_render() {
  local f="$STAGE/dashboards/Auditoría TPN/tpn-audit.json" name="${CLIENTE_NOMBRE//\"/}"
  sed -i "s/__CLIENTE_NOMBRE__/${name//\//\\/}/" "$f"
  local m
  for m in fortigate synology jumpdesktop; do
    [[ " ${MODS[*]} " == *" $m "* ]] || warn "tpn-audit: módulo '$m' no activo → sus paneles saldrán vacíos"
  done
}
