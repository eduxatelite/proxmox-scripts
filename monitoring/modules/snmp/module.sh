# shellcheck shell=bash
MOD_DESC="snmp_exporter compartido (lo activan fortigate y synology)"
MOD_FOLDER=""   # carpeta en Grafana
MOD_DEPENDS=""
snmp_validate() {
  require_vars snmp SNMP_COMMUNITY
  [[ "$SNMP_COMMUNITY" =~ ^(public|private)$ ]] && die "SNMP_COMMUNITY no puede ser public/private. Genera una: openssl rand -hex 12"
  return 0
}
snmp_render() { mkdir -p "$STAGE/config/snmp-exporter"; cp "${REPO_DIR}/modules/snmp/snmp.yml" "$STAGE/config/snmp-exporter/snmp.yml"; }
