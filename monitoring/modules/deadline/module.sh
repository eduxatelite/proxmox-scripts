# shellcheck shell=bash
MOD_DESC="Deadline: exporter del Web Service + dashboard de la granja"
MOD_FOLDER="Deadline"   # carpeta en Grafana
MOD_DEPENDS=""
deadline_defaults() {
  : "${DEADLINE_PORT:=8081}"
  : "${DEADLINE_APIKEY:=}"
  : "${DEADLINE_SCRAPE_INTERVAL:=30}"
}
deadline_validate() { require_vars deadline DEADLINE_HOST; }
deadline_post_install() {
  info "Deadline: comprobar http://${VM_IP}:9090/targets → job deadline_farm_exporter en UP"
}
