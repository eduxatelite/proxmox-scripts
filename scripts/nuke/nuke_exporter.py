#!/usr/bin/env python3
"""
Nuke License Monitor — Prometheus Exporter
Reads Foundry / RLM license server via its built-in HTTP web interface.
No binary (rlmutil) required — just HTTP access to the RLM web port.

Environment variables (set via config/exporter.env):
  RLM_HOST        - RLM server IP or hostname
  RLM_WEB_PORT    - RLM web interface port (default: 5054)
  RLM_ISV         - ISV name (default: foundry)
  EXPORTER_PORT   - Port this exporter listens on (default: 9200)
  SCRAPE_INTERVAL - Seconds between scrapes (default: 60)
"""

import os
import re
import time
import logging
import requests
from prometheus_client import start_http_server, Gauge, Counter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("nuke_exporter")

# ── config ─────────────────────────────────────────────────────────────────────
RLM_HOST        = os.environ.get("RLM_HOST",        "localhost")
RLM_WEB_PORT    = int(os.environ.get("RLM_WEB_PORT",    "5054"))
RLM_ISV         = os.environ.get("RLM_ISV",         "foundry")
EXPORTER_PORT   = int(os.environ.get("EXPORTER_PORT",   "9200"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "60"))

BASE_URL = f"http://{RLM_HOST}:{RLM_WEB_PORT}"

# ── prometheus metrics ─────────────────────────────────────────────────────────
g_total    = Gauge("rlm_product_license_total",    "Total licenses per product",      ["product"])
g_used     = Gauge("rlm_product_license_used",     "Licenses currently in use",       ["product"])
g_handles  = Gauge("rlm_user_active_handles",      "Active handles per user/host",    ["product", "user", "host"])
g_denials  = Gauge("rlm_isv_denials_today",        "License denials today",           ["isv"])
g_up       = Gauge("rlm_exporter_up",              "1 if RLM server reachable, 0 otherwise")
c_errors   = Counter("rlm_scrape_errors_total",    "Total scrape errors")
g_duration = Gauge("rlm_scrape_duration_seconds",  "Time taken for last scrape")

# ── track active handles to clear stale label sets ────────────────────────────
_prev_handles: dict = {}


def fetch_rlm_stat() -> str:
    """Fetch raw text from RLM web interface."""
    url = f"{BASE_URL}/rlmstat?isv={RLM_ISV}&stats=1"
    r = requests.get(url, timeout=15)
    r.raise_for_status()
    # RLM can return HTML or plain text depending on version — strip tags
    text = re.sub(r"<[^>]+>", " ", r.text)
    return text


def fetch_denials() -> int:
    """Try to get denial count from RLM ISV stats page."""
    try:
        url = f"{BASE_URL}/rlm_isv_stat?isv={RLM_ISV}"
        r = requests.get(url, timeout=10)
        text = re.sub(r"<[^>]+>", " ", r.text)
        # Look for "N denials" in the page
        m = re.search(r"(\d+)\s+denial", text, re.IGNORECASE)
        return int(m.group(1)) if m else 0
    except Exception:
        return 0


def parse_rlm_stat(text: str):
    """
    Parse RLM rlmstat output.

    Product line formats (vary by RLM version):
      nuke_i v16.0: 10 licenses, 3 in use
      nuke_i 16.0: 10 licenses, 3 in use
      nuke_i v16.0: 10 licenses, 3 licenses in use

    User line formats:
      "alice" alice@machine1 16.0 Wed Apr 17 09:15 2024 1 handles
      "alice" alice@machine1 16.0 17-apr-2024 09:15 1 handles
    """
    global _prev_handles

    products: dict = {}   # product → (total, used)
    handles:  dict = {}   # (product, user, host) → count

    current_product = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        # ── product line ───────────────────────────────────────────────────────
        m = re.match(
            r"^([\w]+)\s+v?[\d.]+[^:]*:\s+(\d+)\s+licens\w+,\s+(\d+)\s+(?:licens\w+\s+)?in use",
            line, re.IGNORECASE,
        )
        if m:
            current_product = m.group(1).lower()
            products[current_product] = (int(m.group(2)), int(m.group(3)))
            continue

        # ── user / handle line ─────────────────────────────────────────────────
        if current_product:
            # Pattern: "username" user@host version date(s) N handles
            m = re.match(
                r'^"([^"]+)"\s+(\S+)@(\S+)\s+[\d.]+\s+.+?\s+(\d+)\s+handles?',
                line,
            )
            if m:
                user  = m.group(1)
                host  = m.group(3)
                count = int(m.group(4))
                key   = (current_product, user, host)
                handles[key] = handles.get(key, 0) + count

    return products, handles


def collect():
    start = time.time()
    global _prev_handles

    try:
        text = fetch_rlm_stat()
        products, handles = parse_rlm_stat(text)
        denials = fetch_denials()

        # ── product metrics ────────────────────────────────────────────────────
        for product, (total, used) in products.items():
            g_total.labels(product=product).set(total)
            g_used.labels(product=product).set(used)

        # ── user handle metrics — clear stale entries ──────────────────────────
        for key in _prev_handles:
            if key not in handles:
                g_handles.labels(product=key[0], user=key[1], host=key[2]).set(0)
        for (product, user, host), count in handles.items():
            g_handles.labels(product=product, user=user, host=host).set(count)
        _prev_handles = dict(handles)

        # ── denials & health ───────────────────────────────────────────────────
        g_denials.labels(isv=RLM_ISV).set(denials)
        g_up.set(1)

        elapsed = time.time() - start
        g_duration.set(elapsed)

        total_used = sum(u for _, u in products.values())
        log.info(
            "Scraped OK — %d products, %d total in use, %d denials today | %.2fs",
            len(products), total_used, denials, elapsed,
        )

    except requests.exceptions.ConnectionError:
        log.warning("Cannot connect to RLM server at %s", BASE_URL)
        g_up.set(0)
        c_errors.inc()
        g_duration.set(time.time() - start)
    except Exception as e:
        log.error("Scrape error: %s", e)
        g_up.set(0)
        c_errors.inc()
        g_duration.set(time.time() - start)


# ── main ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("Nuke License Exporter starting…")
    log.info("RLM web interface: %s  ISV: %s", BASE_URL, RLM_ISV)
    log.info("Exporter port: %d  Scrape interval: %ds", EXPORTER_PORT, SCRAPE_INTERVAL)

    start_http_server(EXPORTER_PORT)
    log.info("Metrics at http://0.0.0.0:%d/metrics", EXPORTER_PORT)

    while True:
        try:
            collect()
        except Exception as e:
            log.error("Unexpected error: %s", e)
            c_errors.inc()
            g_up.set(0)
        time.sleep(SCRAPE_INTERVAL)
