#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — utilidades compartidas por install.sh y los hooks de módulo
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${CYAN}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

# -----------------------------------------------------------------------------
# render_tmpl SRC DST
#   Sustituye SOLO variables ${MAYUSCULAS} que existan en el entorno.
#   Así no se tocan los {{ $labels.x }} / {{ $value }} de Grafana ni nada en
#   minúsculas. Si queda algún ${VAR} sin resolver, aborta.
# -----------------------------------------------------------------------------
render_tmpl() {
  local src="$1" dst="$2" vars
  vars="$(compgen -e | grep -E '^[A-Z][A-Z0-9_]*$' | sed 's/.*/${&}/' | tr '\n' ' ')"
  mkdir -p "$(dirname "$dst")"
  envsubst "$vars" < "$src" > "$dst"
  local left
  left="$(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$dst" | sort -u | tr '\n' ' ' || true)"
  [[ -n "$left" ]] && die "Variables sin definir en $(basename "$src"): ${left}— añádelas al .env del cliente"
  return 0
}

# -----------------------------------------------------------------------------
# Listas "nombre:ip nombre2:ip2" → bloques static_configs de Prometheus
#   targets_yaml "LISTA" PUERTO LABEL [EXTRA_LABELS_YAML]
# -----------------------------------------------------------------------------
targets_yaml() {
  local list="$1" port="$2" label="$3" item name ip
  for item in $list; do
    name="${item%%:*}"; ip="${item#*:}"
    [[ "$name" == "$item" || -z "$ip" ]] && die "Formato inválido '$item' (esperado nombre:ip)"
    echo "      - targets: [\"${ip}${port:+:$port}\"]"
    echo "        labels:"
    echo "          ${label}: \"${name}\""
  done
}

# IPs de una lista "nombre:ip ..."
list_ips() { local i; for i in $1; do echo -n "${i#*:} "; done; }

# Comprueba que las variables existen y no están vacías
require_vars() {
  local mod="$1"; shift
  local v missing=()
  for v in "$@"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
  [[ ${#missing[@]} -gt 0 ]] && die "Módulo '${mod}': faltan variables en el .env: ${missing[*]}"
  return 0
}
