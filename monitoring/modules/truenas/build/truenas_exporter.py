#!/usr/bin/env python3
"""
truenas_exporter.py — Métricas de TrueNAS SCALE para Prometheus (API WebSocket JSON-RPC)

TrueNAS 25.04+ (la API REST desaparece en 26). Se conecta a wss://<nas>/api/current,
se autentica con auth.login_ex (API_KEY_PLAIN) y consulta:
  system.info · pool.query (salud, capacidad, scrub, errores por disco)
  disk.query + disk.temperatures · alert.list (alertas activas del propio TrueNAS)

Variables de entorno:
  TRUENAS_TARGETS   "nombre:ip nombre2:ip2"
  TRUENAS_API_USER  usuario dueño de las API keys (rol Read-only Administrator)
  TRUENAS_API_KEYS  "nombre=clave nombre2=clave2"
  TRUENAS_VERIFY_SSL  false (certificado autofirmado por defecto)
  POLL_INTERVAL     segundos entre lecturas (60)
  EXPORTER_PORT     9310

Nunca usar ws:// sin TLS: TrueNAS revoca automáticamente una API key enviada en claro.
"""
import json, logging, os, ssl, threading, time
from prometheus_client import start_http_server
from prometheus_client.core import GaugeMetricFamily, REGISTRY
import websocket

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("truenas_exporter")

TARGETS = [t.split(":", 1) for t in os.environ.get("TRUENAS_TARGETS", "").split() if ":" in t]
USER = os.environ.get("TRUENAS_API_USER", "monitoring")
KEYS = dict(k.split("=", 1) for k in os.environ.get("TRUENAS_API_KEYS", "").split() if "=" in k)
VERIFY = os.environ.get("TRUENAS_VERIFY_SSL", "false").lower() == "true"
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
PORT = int(os.environ.get("EXPORTER_PORT", "9310"))

ALERT_LEVELS = ["INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL", "ALERT", "EMERGENCY"]


class RPC:
    def __init__(self, host):
        opts = {} if VERIFY else {"cert_reqs": ssl.CERT_NONE, "check_hostname": False}
        self.ws = websocket.create_connection(f"wss://{host}/api/current", sslopt=opts, timeout=30)
        self.n = 0

    def call(self, method, params=None):
        self.n += 1
        self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or []}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") != self.n:
                continue  # notificaciones de eventos: se ignoran
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error'].get('message', msg['error'])}")
            return msg.get("result")

    def close(self):
        try: self.ws.close()
        except Exception: pass


def ts(v):
    """Fechas de la API: {"$date": ms} o epoch."""
    if isinstance(v, dict) and "$date" in v: return v["$date"] / 1000.0
    if isinstance(v, (int, float)): return v / 1000.0 if v > 1e11 else float(v)
    return None


def walk_disks(node, out):
    """Recorre la topología del pool y devuelve los discos con su estado y errores."""
    if not isinstance(node, dict): return
    if node.get("type") == "DISK":
        out.append(node)
    for ch in node.get("children") or []:
        walk_disks(ch, out)


def poll(name, host):
    snap = {"up": 0, "duration": 0.0}
    key = KEYS.get(name)
    if not key:
        log.error("%s: falta su API key en TRUENAS_API_KEYS", name); return snap
    t0 = time.time()
    rpc = None
    try:
        rpc = RPC(host)
        r = rpc.call("auth.login_ex", [{"mechanism": "API_KEY_PLAIN", "username": USER, "api_key": key}])
        if not isinstance(r, dict) or r.get("response_type") != "SUCCESS":
            # TrueNAS < 25.04
            if not rpc.call("auth.login_with_api_key", [key]):
                raise RuntimeError(f"login rechazado ({r.get('response_type') if isinstance(r, dict) else r})")
        snap["info"] = rpc.call("system.info") or {}
        snap["pools"] = rpc.call("pool.query") or []
        disks = rpc.call("disk.query") or []
        snap["disks"] = disks
        names = [d["name"] for d in disks if d.get("name")]
        try:
            snap["temps"] = rpc.call("disk.temperatures", [names]) if names else {}
        except Exception as e:
            log.warning("%s: disk.temperatures: %s", name, e); snap["temps"] = {}
        try:
            snap["alerts"] = [a for a in (rpc.call("alert.list") or []) if not a.get("dismissed")]
        except Exception as e:
            log.warning("%s: alert.list: %s", name, e); snap["alerts"] = []
        snap["up"] = 1
    except Exception as e:
        log.error("%s (%s): %s", name, host, e)
    finally:
        if rpc: rpc.close()
        snap["duration"] = time.time() - t0
    return snap


STATE = {}
LOCK = threading.Lock()


def loop():
    while True:
        for name, host in TARGETS:
            s = poll(name, host)
            with LOCK: STATE[name] = s
        time.sleep(INTERVAL)


class Collector:
    def collect(self):
        g = lambda n, h, l: GaugeMetricFamily(n, h, labels=l)
        up = g("truenas_up", "1 si la API responde y el login es correcto", ["nas"])
        dur = g("truenas_scrape_duration_seconds", "Duración de la última lectura", ["nas"])
        info = g("truenas_system_info", "Versión y hostname", ["nas", "version", "hostname"])
        upt = g("truenas_uptime_seconds", "Uptime del NAS", ["nas"])
        ph = g("truenas_pool_healthy", "1 = pool sano", ["nas", "pool"])
        pst = g("truenas_pool_status", "Estado del pool (valor 1, estado en la etiqueta)", ["nas", "pool", "status"])
        psz = g("truenas_pool_size_bytes", "Tamaño del pool", ["nas", "pool"])
        pal = g("truenas_pool_allocated_bytes", "Espacio usado", ["nas", "pool"])
        pfr = g("truenas_pool_free_bytes", "Espacio libre", ["nas", "pool"])
        pfg = g("truenas_pool_fragmentation_percent", "Fragmentación", ["nas", "pool"])
        sce = g("truenas_pool_scan_errors", "Errores del último scrub/resilver", ["nas", "pool", "function"])
        scend = g("truenas_pool_scan_end_timestamp_seconds", "Fin del último scrub/resilver", ["nas", "pool", "function"])
        scrun = g("truenas_pool_scan_running", "1 = scrub/resilver en curso", ["nas", "pool", "function"])
        dok = g("truenas_pool_disk_online", "1 = disco ONLINE dentro del pool", ["nas", "pool", "disk", "status"])
        derr = g("truenas_pool_disk_errors", "Errores ZFS por disco", ["nas", "pool", "disk", "type"])
        dtmp = g("truenas_disk_temperature_celsius", "Temperatura del disco", ["nas", "disk", "serial", "model", "pool"])
        alc = g("truenas_alerts", "Alertas activas del TrueNAS por nivel", ["nas", "level"])
        ali = g("truenas_alert_info", "Alertas activas del TrueNAS", ["nas", "level", "klass", "text"])
        with LOCK: state = dict(STATE)
        for nas, s in state.items():
            up.add_metric([nas], s.get("up", 0)); dur.add_metric([nas], s.get("duration", 0))
            if not s.get("up"): continue
            i = s.get("info", {})
            info.add_metric([nas, str(i.get("version", "")), str(i.get("hostname", ""))], 1)
            if i.get("uptime_seconds") is not None: upt.add_metric([nas], float(i["uptime_seconds"]))
            disk_pool = {}
            for p in s.get("pools", []):
                pn = p.get("name", "?")
                ph.add_metric([nas, pn], 1 if p.get("healthy") else 0)
                pst.add_metric([nas, pn, str(p.get("status", "UNKNOWN"))], 1)
                for fam, k in ((psz, "size"), (pal, "allocated"), (pfr, "free")):
                    if p.get(k) is not None: fam.add_metric([nas, pn], float(p[k]))
                try: pfg.add_metric([nas, pn], float(str(p.get("fragmentation") or "").rstrip("%")))
                except ValueError: pass
                sc = p.get("scan") or {}
                fn = str(sc.get("function") or "NONE")
                if sc:
                    sce.add_metric([nas, pn, fn], float(sc.get("errors") or 0))
                    e = ts(sc.get("end_time"))
                    if e: scend.add_metric([nas, pn, fn], e)
                    scrun.add_metric([nas, pn, fn], 1 if sc.get("state") == "SCANNING" else 0)
                found = []
                for section in (p.get("topology") or {}).values():
                    for vdev in section or []:
                        walk_disks(vdev, found)
                for d in found:
                    dn = d.get("disk") or d.get("name") or "?"
                    disk_pool[dn] = pn
                    st = str(d.get("status", "UNKNOWN"))
                    dok.add_metric([nas, pn, dn, st], 1 if st == "ONLINE" else 0)
                    stats = d.get("stats") or {}
                    for t in ("read", "write", "checksum"):
                        derr.add_metric([nas, pn, dn, t], float(stats.get(f"{t}_errors") or 0))
            temps = s.get("temps") or {}
            for d in s.get("disks", []):
                v = temps.get(d.get("name"))
                if isinstance(v, dict):
                    v = v.get("temperature", v.get("temp"))
                if isinstance(v, (int, float)):
                    dtmp.add_metric([nas, d["name"], str(d.get("serial", "")), str(d.get("model", "")),
                                     disk_pool.get(d["name"], "")], float(v))
            counts = {l: 0 for l in ALERT_LEVELS}
            for a in s.get("alerts", []):
                lv = str(a.get("level", "INFO"))
                counts[lv] = counts.get(lv, 0) + 1
                txt = str(a.get("formatted") or a.get("text") or "")[:200]
                ali.add_metric([nas, lv, str(a.get("klass", "")), txt], 1)
            for lv, c in counts.items(): alc.add_metric([nas, lv], c)
        return [up, dur, info, upt, ph, pst, psz, pal, pfr, pfg, sce, scend, scrun, dok, derr, dtmp, alc, ali]


if __name__ == "__main__":
    if not TARGETS:
        raise SystemExit("TRUENAS_TARGETS vacío")
    log.info("TrueNAS: %s (usuario %s, verify_ssl=%s)", ", ".join(f"{n}={h}" for n, h in TARGETS), USER, VERIFY)
    REGISTRY.register(Collector())
    start_http_server(PORT)
    threading.Thread(target=loop, daemon=True).start()
    while True: time.sleep(3600)
