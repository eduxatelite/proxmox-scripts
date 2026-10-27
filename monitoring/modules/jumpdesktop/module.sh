# shellcheck shell=bash
MOD_DESC="Jump Desktop: poller de la API + watcher de anomalías + alertas"
MOD_FOLDER="Jump Desktop"   # carpeta en Grafana
MOD_DEPENDS=""
jumpdesktop_defaults() {
  # 1 = solo aprende (no emite anomalías). Pasar a 0 a las 1-2 semanas y relanzar install.sh
  : "${JD_LEARNING_MODE:=1}"
  # Horario laboral del cliente (anomalía out_of_hours)
  : "${JD_WORK_START:=8}"
  : "${JD_WORK_END:=20}"
  : "${JD_ALERT_WEEKENDS:=1}"
}
jumpdesktop_validate() { require_vars jumpdesktop JUMPDESKTOP_TEAM_ID JUMPDESKTOP_API_TOKEN; }
jumpdesktop_post_install() {
  local dir=/opt/jumpdesktop-poller src="${REPO_DIR}/agentes/jumpdesktop"
  section "Jump Desktop — poller y watcher en ${dir}"
  mkdir -p "$dir/state" /var/log/jumpdesktop
  install -m 0755 "$src/jd_watcher.py" "$dir/jd_watcher.py"
  umask 077
  cat > "$dir/.env" <<ENV
TEAM_ID=${JUMPDESKTOP_TEAM_ID}
API_TOKEN=${JUMPDESKTOP_API_TOKEN}
LEARNING_MODE=${JD_LEARNING_MODE}
JD_WORK_START=${JD_WORK_START}
JD_WORK_END=${JD_WORK_END}
JD_ALERT_WEEKENDS=${JD_ALERT_WEEKENDS}
ENV
  umask 022
  chmod 600 "$dir/.env"
  [[ -f "$dir/LEARNING_SINCE" || "$JD_LEARNING_MODE" != "1" ]] || date +%F > "$dir/LEARNING_SINCE"

  local cron=/etc/cron.d/jumpdesktop
  {
    echo "# Generado por install.sh (módulo jumpdesktop). Logs del cron FUERA de /var/log/jumpdesktop/"
    echo "SHELL=/bin/bash"
    if [[ -f "$src/jumpdesktop_logs.py" ]]; then
      install -m 0755 "$src/jumpdesktop_logs.py" "$dir/jumpdesktop_logs.py"
      echo "*/5 * * * * root set -a; . $dir/.env; set +a; /usr/bin/python3 $dir/jumpdesktop_logs.py >> /var/log/jumpdesktop-poller.log 2>&1"
    fi
    echo "*/5 * * * * root set -a; . $dir/.env; set +a; /usr/bin/flock -n /run/jd_watcher.lock /usr/bin/python3 $dir/jd_watcher.py >> /var/log/jumpdesktop-watcher.log 2>&1"
  } > "$cron"
  chmod 644 "$cron"
  if [[ -f "$src/jumpdesktop_logs.py" ]]; then
    log "Poller y watcher programados cada 5 min"
  else
    warn "Falta agentes/jumpdesktop/jumpdesktop_logs.py en el repo: solo se ha programado el watcher."
  fi
  if [[ "$JD_LEARNING_MODE" == "1" ]]; then
    warn "Watcher en LEARNING_MODE desde $(cat "$dir/LEARNING_SINCE"). Pasar JD_LEARNING_MODE=0 a las 1-2 semanas."
  fi
}
