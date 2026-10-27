#!/usr/bin/env bash
# =============================================================================
# monitoring-firewall.sh — restringe el push a Loki (3100) a las IPs autorizadas
#
# Docker se salta firewalld, por eso va en DOCKER-USER. Usa una cadena propia
# (XAT-MON) que se vacía y rehace en cada ejecución: es idempotente y no
# depende de iptables-save (que guardaría también las reglas internas de Docker).
#
# IPs autorizadas: LOKI_ALLOWED_SOURCES en /opt/grafana-stack/.env
# Lo lanza monitoring-firewall.service después de docker.service.
# =============================================================================
set -euo pipefail
ENV_FILE="${1:-/opt/grafana-stack/.env}"
CHAIN="XAT-MON"

ALLOWED="$(grep -E '^LOKI_ALLOWED_SOURCES=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'" || true)"
EXT_IF="$(ip route show default | awk '{print $5; exit}')"

# Espera a que Docker haya creado DOCKER-USER
for _ in $(seq 1 30); do iptables -nL DOCKER-USER >/dev/null 2>&1 && break; sleep 2; done
iptables -nL DOCKER-USER >/dev/null 2>&1 || { echo "DOCKER-USER no existe (¿Docker parado?)"; exit 1; }

iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER 1 -j "$CHAIN"

if [[ -z "$ALLOWED" ]]; then
  echo "LOKI_ALLOWED_SOURCES vacío: Loki 3100 queda abierto (no hay agentes remotos)."
  exit 0
fi

# Solo tráfico que entra por la interfaz externa: el tráfico interno de Docker
# (promtail → loki, grafana → loki) no se toca.
for ip in $ALLOWED; do
  iptables -A "$CHAIN" -i "$EXT_IF" -p tcp -m conntrack --ctorigdstport 3100 --ctdir ORIGINAL -s "$ip" -j RETURN
done
iptables -A "$CHAIN" -i "$EXT_IF" -p tcp -m conntrack --ctorigdstport 3100 --ctdir ORIGINAL -j DROP

echo "Loki 3100 permitido solo desde: $ALLOWED (interfaz $EXT_IF)"
iptables -nL "$CHAIN" --line-numbers
