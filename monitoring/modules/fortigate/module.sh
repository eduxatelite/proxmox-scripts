# shellcheck shell=bash
MOD_DESC="FortiGate: syslog (Loki) + SNMP (Prometheus) + alertas + dashboard"
MOD_FOLDER="FortiGate"   # carpeta en Grafana
MOD_DEPENDS="snmp"
fortigate_defaults() {
  : "${FORTIGATE_NAME:=fortigate}"
  : "${SYSLOG_PORT_UDP:=1514}"
  : "${SYSLOG_PORT_FORTI:=1515}"
  : "${ALERT_FG_CPU_PCT:=85}"
  : "${ALERT_FG_MEM_PCT:=85}"
  : "${ALERT_FG_SESSIONS:=40000}"
}
fortigate_validate() { require_vars fortigate FORTIGATE_IP; }
fortigate_post_install() {
  section "FortiGate — pegar en la CLI de ${FORTIGATE_NAME} (${FORTIGATE_IP})"
  cat <<CLI
config system snmp sysinfo
    set status enable
    set description "${CLIENTE_NOMBRE}"
end
config system snmp community
    edit 10
        set name "${SNMP_COMMUNITY}"
        config hosts
            edit 1
                set ip ${VM_IP} 255.255.255.255
            next
        end
        set query-v2c-status enable
        set trap-v1-status disable
        set trap-v2c-status disable
    next
end
config log syslogd setting
    set status enable
    set server "${VM_IP}"
    set port ${SYSLOG_PORT_FORTI}
    set mode reliable
    set format rfc5424
end
config log syslogd filter
    set severity information
    set forward-traffic disable
    set local-traffic disable
    set multicast-traffic disable
    set sniffer-traffic disable
end
CLI
  warn "Habilita SNMP en el acceso administrativo de la interfaz/VLAN por la que llega ${VM_IP} (set allowaccess ... snmp)."
  warn "forward-traffic DEBE quedar en disable (con enable: ~14 GB/día en un cliente real)."
  info "Verificar: snmpwalk -v2c -c '<community>' ${FORTIGATE_IP} 1.3.6.1.4.1.12356.101.4.1.3"
}
