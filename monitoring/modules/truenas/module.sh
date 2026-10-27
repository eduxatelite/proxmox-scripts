# shellcheck shell=bash
MOD_DESC="TrueNAS SCALE: pools, discos, temperaturas y alertas (API) + syslog + alertas"
MOD_FOLDER="NAS"   # misma carpeta de Grafana que el Synology
MOD_DEPENDS=""
truenas_defaults() {
  : "${TRUENAS_API_USER:=monitoring}"
  : "${TRUENAS_VERIFY_SSL:=false}"
  : "${SYSLOG_PORT_TRUENAS:=1517}"
  : "${ALERT_TRUENAS_POOL_PCT:=80}"
  : "${ALERT_TRUENAS_DISK_TEMP:=50}"
  : "${ALERT_TRUENAS_SCRUB_DAYS:=40}"
}
truenas_validate() {
  require_vars truenas TRUENAS_TARGETS TRUENAS_API_KEYS
  local item name
  for item in $TRUENAS_TARGETS; do
    name="${item%%:*}"
    [[ " $TRUENAS_API_KEYS" == *" ${name}="* ]] || die "Módulo truenas: falta la API key de '${name}' en TRUENAS_API_KEYS (formato nombre=clave)"
  done
  return 0
}
truenas_post_install() {
  section "TrueNAS — en CADA NAS (${TRUENAS_TARGETS})"
  cat <<TXT
  1. Credenciales → Usuarios → Añadir: usuario '${TRUENAS_API_USER}', sin contraseña ni shell,
     Rol/privilegio: "Read-only Administrator".
  2. Usuario '${TRUENAS_API_USER}' → API Keys → Añadir. Copiar la clave a TRUENAS_API_KEYS
     (formato nombre=clave) y relanzar install.sh.
  3. Sistema → Avanzado → Syslog → Servidor remoto: ${VM_IP}:${SYSLOG_PORT_TRUENAS}, transporte TCP,
     nivel Info. Marcar "Include Audit Logs" para tener los accesos SMB/UI.
TXT
  warn "La API va SIEMPRE por HTTPS (wss://). Si una key viaja por http, TrueNAS la revoca sola."
  info "Verificar dentro de la VM: curl -s localhost:9090/api/v1/query --data-urlencode 'query=truenas_up'"
}
