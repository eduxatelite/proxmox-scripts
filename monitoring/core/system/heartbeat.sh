#!/usr/bin/env bash
# =============================================================================
# Latido al Uptime Kuma de Xatélite.
# Solo manda la señal si el stack está REALMENTE sano: si Loki, Grafana o
# Prometheus no responden, sale sin mandar nada y el monitor salta.
#
# Lo lanza xat-heartbeat.timer cada 5 min. La URL sale de HEARTBEAT_URL en
# /opt/grafana-stack/.env (EnvironmentFile del servicio).
# Prueba manual:  systemctl start xat-heartbeat.service; journalctl -u xat-heartbeat -n 5
# =============================================================================
URL="${HEARTBEAT_URL:-}"
GPORT="${GRAFANA_PORT:-3000}"
[[ -z "$URL" ]] && { echo "HEARTBEAT_URL no definida"; exit 1; }

fail() { echo "NO se envía latido: $1"; exit 1; }

curl -sf --max-time 5 http://localhost:3100/ready | grep -q "ready" || fail "Loki no está ready"
curl -sf --max-time 5 -o /dev/null "http://localhost:${GPORT}/api/health"  || fail "Grafana no responde"
curl -sf --max-time 5 -o /dev/null http://localhost:9090/-/healthy        || fail "Prometheus no responde"

# Uptime Kuma acepta status/msg: se ve en el panel qué VM ha mandado el latido
curl -sf --max-time 10 --retry 3 -G "$URL" --data-urlencode "status=up" --data-urlencode "msg=OK $(hostname -s)" >/dev/null \
  && echo "Latido enviado" || fail "No se alcanza Uptime Kuma"
