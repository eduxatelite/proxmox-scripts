#!/usr/bin/env python3
"""
Watcher de anomalias de Jump Desktop.

Lee /var/log/jumpdesktop/connections.log (lo que escribe el poller) y mantiene
un historico de IPs conocidas POR USUARIO. Cuando aparece algo fuera del patron
habitual, escribe una linea en /var/log/jumpdesktop/anomalies.log que Promtail
ya recoge, y sobre la que se pueden montar alertas en Grafana.

Detecta:
    new_ip        -> IP que ese usuario no habia usado nunca
    new_country   -> pais que ese usuario no habia usado nunca
    out_of_hours  -> conexion fuera de horario laboral o en fin de semana
    auth_failed   -> intento de autenticacion fallido

Modo aprendizaje:
    Con LEARNING_MODE=1 registra el historico pero NO emite anomalias.
    Pensado para dejarlo correr 1-2 semanas y construir la base antes de
    activar las alertas y evitar una avalancha de falsos positivos.

Uso via cron, justo despues del poller.
"""

import json
import logging
import os
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

# ─── Configuracion ─────────────────────────────────────────────────────────

LOG_DIR = Path(os.getenv("JD_LOG_DIR", "/var/log/jumpdesktop"))
CONNECTIONS_LOG = LOG_DIR / "connections.log"
ANOMALIES_LOG = LOG_DIR / "anomalies.log"

STATE_DIR = Path(os.getenv("JD_STATE_DIR", "/opt/jumpdesktop-poller/state"))
KNOWN_IPS_FILE = STATE_DIR / "known_ips.json"
GEO_CACHE_FILE = STATE_DIR / "geo_cache.json"
PROCESSED_FILE = STATE_DIR / "processed_ids.json"

# Horario laboral (hora local del servidor). Fuera de esto -> out_of_hours
WORK_START_HOUR = int(os.getenv("JD_WORK_START", "8"))
WORK_END_HOUR = int(os.getenv("JD_WORK_END", "20"))
ALERT_WEEKENDS = os.getenv("JD_ALERT_WEEKENDS", "1") == "1"

# Modo aprendizaje: registra pero no alerta
LEARNING_MODE = os.getenv("LEARNING_MODE", "0") == "1"

# Geolocalizacion. Si se desactiva, no se consulta nada externo.
GEO_ENABLED = os.getenv("JD_GEO_ENABLED", "1") == "1"
GEO_API = "http://ip-api.com/json/{ip}?fields=status,country,countryCode,as,city"

# Cuantos ids recordar para no reprocesar (el log es pequeno, sobra de largo)
MAX_PROCESSED_IDS = 20000

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("jd_watcher")


# ─── Utilidades de estado ──────────────────────────────────────────────────

def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


# ─── Geolocalizacion ───────────────────────────────────────────────────────

def geo_lookup(ip, cache):
    """Resuelve pais/ASN de una IP. Cachea para no repetir consultas."""
    if ip in cache:
        return cache[ip]

    unknown = {"country": "unknown", "country_code": "??", "asn": "", "city": ""}

    if not GEO_ENABLED or is_private(ip):
        cache[ip] = unknown if not is_private(ip) else {
            "country": "private", "country_code": "--", "asn": "", "city": ""
        }
        return cache[ip]

    try:
        with urllib.request.urlopen(GEO_API.format(ip=ip), timeout=5) as resp:
            data = json.loads(resp.read().decode())
        if data.get("status") == "success":
            result = {
                "country": data.get("country", "unknown"),
                "country_code": data.get("countryCode", "??"),
                "asn": data.get("as", ""),
                "city": data.get("city", ""),
            }
        else:
            result = unknown
    except Exception as exc:  # noqa: BLE001
        log.warning("Fallo geolocalizando %s: %s", ip, exc)
        result = unknown

    cache[ip] = result
    time.sleep(1.5)  # respeta el rate limit de la api gratuita
    return result


def is_private(ip):
    return (
        ip.startswith("10.")
        or ip.startswith("192.168.")
        or ip.startswith("127.")
        or any(ip.startswith(f"172.{i}.") for i in range(16, 32))
    )


# ─── Parseo de eventos ─────────────────────────────────────────────────────

def extract_event(raw):
    """Saca los campos que interesan de un evento del poller."""
    event_id = raw.get("id")
    ts_ms = raw.get("timestamp")
    host = raw.get("computerHostName", "")

    incoming = raw.get("incomingConnectionEvent")
    auth_ok = raw.get("authSucceededEvent")
    auth_fail = raw.get("authFailedEvent")

    peer = None
    kind = None
    local_user = ""

    if incoming:
        peer = incoming.get("peerInfo", {})
        kind = "connection"
    elif auth_ok:
        peer = auth_ok.get("associatedIncomingConnectionEvent", {}).get("peerInfo", {})
        kind = "auth_ok"
        local_user = auth_ok.get("localUserName", "")
    elif auth_fail:
        peer = auth_fail.get("associatedIncomingConnectionEvent", {}).get("peerInfo", {})
        kind = "auth_failed"
        local_user = auth_fail.get("localUserName", "")

    if not peer:
        return None

    email = peer.get("email", "")
    ip = peer.get("ipAddress", "")
    if not email or not ip:
        return None

    return {
        "event_id": event_id,
        "ts_ms": ts_ms,
        "kind": kind,
        "user": email,
        "ip": ip,
        "host": host,
        "local_user": local_user,
    }


def is_out_of_hours(ts_ms):
    dt = datetime.fromtimestamp(ts_ms / 1000)
    if ALERT_WEEKENDS and dt.weekday() >= 5:
        return True, dt
    if dt.hour < WORK_START_HOUR or dt.hour >= WORK_END_HOUR:
        return True, dt
    return False, dt


# ─── Emision de anomalias ──────────────────────────────────────────────────

def emit(anomaly, ev, geo, extra=None):
    record = {
        "anomaly": anomaly,
        "user": ev["user"],
        "ip": ev["ip"],
        "host": ev["host"],
        "local_user": ev["local_user"],
        "country": geo.get("country", ""),
        "country_code": geo.get("country_code", ""),
        "asn": geo.get("asn", ""),
        "city": geo.get("city", ""),
        "event_kind": ev["kind"],
        "event_time": datetime.fromtimestamp(ev["ts_ms"] / 1000).isoformat(),
        "detected_at": datetime.now().isoformat(),
    }
    if extra:
        record.update(extra)

    with open(ANOMALIES_LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")

    log.info("ANOMALIA %s: %s desde %s (%s)",
             anomaly, ev["user"], ev["ip"], geo.get("country", "?"))


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    if not CONNECTIONS_LOG.exists():
        log.error("No existe %s", CONNECTIONS_LOG)
        sys.exit(1)

    known = load_json(KNOWN_IPS_FILE, {})
    geo_cache = load_json(GEO_CACHE_FILE, {})
    processed = set(load_json(PROCESSED_FILE, []))

    if LEARNING_MODE:
        log.info("MODO APRENDIZAJE activo: se registra historico, no se alerta")

    nuevos = 0
    anomalias = 0

    with open(CONNECTIONS_LOG, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue

            ev = extract_event(raw)
            if not ev or ev["event_id"] in processed:
                continue

            processed.add(ev["event_id"])
            nuevos += 1

            user = ev["user"]
            ip = ev["ip"]
            geo = geo_lookup(ip, geo_cache)

            perfil = known.setdefault(user, {"ips": {}, "countries": []})
            ip_conocida = ip in perfil["ips"]
            pais = geo.get("country_code", "??")
            pais_conocido = pais in perfil["countries"]

            # Registrar historico siempre
            visto = datetime.fromtimestamp(ev["ts_ms"] / 1000).isoformat()
            entry = perfil["ips"].setdefault(
                ip, {"first_seen": visto, "count": 0, "country": geo.get("country", "")}
            )
            entry["last_seen"] = visto
            entry["count"] += 1
            if pais not in perfil["countries"]:
                perfil["countries"].append(pais)

            if LEARNING_MODE:
                continue

            # Anomalias
            if not ip_conocida:
                emit("new_ip", ev, geo,
                     {"known_ips_before": len(perfil["ips"]) - 1})
                anomalias += 1

            if not pais_conocido and pais not in ("--", "??"):
                emit("new_country", ev, geo,
                     {"known_countries_before": [c for c in perfil["countries"] if c != pais]})
                anomalias += 1

            fuera, _dt = is_out_of_hours(ev["ts_ms"])
            if fuera and ev["kind"] in ("connection", "auth_ok"):
                emit("out_of_hours", ev, geo)
                anomalias += 1

            if ev["kind"] == "auth_failed":
                emit("auth_failed", ev, geo)
                anomalias += 1

    # Guardar estado
    save_json(KNOWN_IPS_FILE, known)
    save_json(GEO_CACHE_FILE, geo_cache)
    save_json(PROCESSED_FILE, list(processed)[-MAX_PROCESSED_IDS:])

    log.info("Procesados %d eventos nuevos, %d anomalias, %d usuarios en historico",
             nuevos, anomalias, len(known))


if __name__ == "__main__":
    main()
