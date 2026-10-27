# shellcheck shell=bash
MOD_DESC="Synology: SNMP (RAID, discos, volumen) + syslog DSM + alertas"
MOD_FOLDER="NAS"   # carpeta en Grafana
MOD_DEPENDS="snmp"
synology_defaults() {
  : "${NAS_VOLUME:=/volume1}"
  : "${SYSLOG_PORT_NAS:=1516}"
  : "${ALERT_NAS_VOLUME_PCT:=90}"
  : "${ALERT_NAS_LOGIN_FAILS:=4}"
  : "${ALERT_NAS_MASS_DELETE:=200}"
}
synology_validate() { require_vars synology NAS_TARGETS; list_ips "$NAS_TARGETS" >/dev/null; }
synology_render() {
  {
    echo "scrape_configs:"
    echo "  - job_name: snmp_synology"
    echo "    scrape_interval: 60s"
    echo "    scrape_timeout: 30s"
    echo "    metrics_path: /snmp"
    echo "    params:"
    echo "      auth: [xat_v2]"
    echo "      module: [synology]"
    echo "    static_configs:"
    targets_yaml "$NAS_TARGETS" "" device
    echo "    relabel_configs:"
    echo "      - source_labels: [__address__]"
    echo "        target_label: __param_target"
    echo "      - source_labels: [__param_target]"
    echo "        target_label: instance"
    echo "      - target_label: __address__"
    echo "        replacement: snmp-exporter:9116"
  } > "$STAGE/config/prometheus/scrape.d/synology.yml"
}
synology_post_install() {
  section "Synology — configurar en DSM (${NAS_TARGETS})"
  echo "  1. Panel de control → Terminal y SNMP → SNMP: activar SNMPv1/v2c, community = SNMP_COMMUNITY del .env"
  echo "     (restringir a ${VM_IP} si el DSM lo permite)"
  echo "  2. Centro de registros → Envío de registros: servidor ${VM_IP}, puerto ${SYSLOG_PORT_NAS}, TCP, formato IETF (RFC 5424)"
  warn "Con formato BSD/RFC3164 los logs NO entran y parece un problema de red."
  for ip in $(list_ips "$NAS_TARGETS"); do
    info "Verificar: snmpwalk -v2c -c '<community>' ${ip} 1.3.6.1.4.1.6574.1.1"
  done
}
