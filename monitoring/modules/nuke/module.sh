# shellcheck shell=bash
MOD_DESC="Nuke: licencias RLM (rlmutil) + dashboard"
MOD_FOLDER="Nuke"   # carpeta en Grafana
MOD_DEPENDS=""
nuke_defaults() {
  : "${RLM_PORT:=4101}"
  : "${NUKE_SCRAPE_INTERVAL:=60}"
}
nuke_validate() {
  require_vars nuke RLM_HOST
  local b="${REPO_DIR}/modules/nuke/build/rlmutil"
  [[ -f "$b" ]] || { [[ -f "${REPO_DIR}/../scripts/nuke/rlmutil" ]] && cp "${REPO_DIR}/../scripts/nuke/rlmutil" "$b"; }
  [[ -f "$b" ]] || die "Falta rlmutil: cópialo a ${b} (está en proxmox-scripts/scripts/nuke/)"
  return 0
}
nuke_post_install() {
  info "Nuke: comprobar http://${VM_IP}:9090/targets → job nuke_license_exporter en UP"
}
