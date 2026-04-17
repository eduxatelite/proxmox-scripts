#!/usr/bin/env python3
"""
Nuke License Dashboard — Prometheus Exporter
Runs rlmutil rlmstat directly against the remote RLM server (no SSH needed).

Environment variables (config/exporter.env):
    RLM_HOST        - IP/hostname of the RLM license server
    RLM_PORT        - RLM license port (default: 4101)
    RLMUTIL_PATH    - Path to rlmutil binary (default: /app/rlmutil)
    EXPORTER_PORT   - Port this exporter listens on (default: 9200)
    SCRAPE_INTERVAL - Seconds between scrapes (default: 60)
"""

import os
import re
import time
import logging
import threading
import subprocess
from collections import defaultdict
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("nuke_exporter")

# ── config ─────────────────────────────────────────────────────────────────────
RLM_HOST        = os.getenv("RLM_HOST",       "localhost")
RLM_PORT        = os.getenv("RLM_PORT",       "4101")
RLMUTIL_PATH    = os.getenv("RLMUTIL_PATH",   "/app/rlmutil")
EXPORTER_PORT   = int(os.getenv("EXPORTER_PORT",   "9200"))
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "60"))

# ── shared state ───────────────────────────────────────────────────────────────
_metrics_lock = threading.Lock()
_metrics_text = b""


# ── rlmutil runner ─────────────────────────────────────────────────────────────

def run_rlmutil() -> str:
    """Run rlmutil rlmstat -a pointing directly at the remote RLM server."""
    cmd = [RLMUTIL_PATH, "rlmstat", "-a", "-c", f"{RLM_PORT}@{RLM_HOST}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0 and not result.stdout:
        raise RuntimeError(f"rlmutil error: {result.stderr.strip()}")
    return result.stdout


# ── parsers ────────────────────────────────────────────────────────────────────

def parse_pool_status(text: str) -> list[dict]:
    """
    Parses the 'license pool status' block:

        nuke_r v2026.1016
                count: 4, # reservations: 0, inuse: 3, exp: 16-oct-2026
                obsolete: 0, min_remove: 120, total checkouts: 23579
    """
    results = []
    pool_section = re.search(
        r"license pool status.*?(?=license usage status|\Z)",
        text, re.DOTALL | re.IGNORECASE,
    )
    if not pool_section:
        log.warning("Block 'license pool status' not found in rlmutil output")
        return results

    block = pool_section.group(0)
    prod_pattern  = re.compile(r"^\s{0,12}(\w+)\s+v([\d\.]+)\s*$", re.MULTILINE)
    count_pattern = re.compile(
        r"count:\s*(\d+).*?inuse:\s*(\d+).*?exp:\s*([\w\-]+).*?total checkouts:\s*(\d+)",
        re.DOTALL,
    )

    for m in prod_pattern.finditer(block):
        product = m.group(1).lower()
        version = m.group(2)
        rest  = block[m.end():]
        nxt   = prod_pattern.search(rest)
        chunk = rest[:nxt.start()] if nxt else rest[:500]
        cm = count_pattern.search(chunk)
        if cm:
            results.append({
                "product":         product,
                "version":         version,
                "total":           int(cm.group(1)),
                "used":            int(cm.group(2)),
                "exp":             cm.group(3),
                "total_checkouts": int(cm.group(4)),
            })
    return results


def parse_usage(text: str) -> list[dict]:
    """
    Parses the 'license usage status' block:

        nuke_i v2026.1016: asierra@spa438w 1/0 at 04/14 17:30  (handle: 1b40)
    """
    usage_section = re.search(r"license usage status.*", text, re.DOTALL | re.IGNORECASE)
    if not usage_section:
        return []

    block = usage_section.group(0)
    line_pattern = re.compile(
        r"(\w+)\s+v([\d\.]+):\s+(\w+)@([\w\-\.]+)\s+\d+/\d+\s+at"
    )
    counter: dict = defaultdict(int)
    for m in line_pattern.finditer(block):
        key = (m.group(1).lower(), m.group(2), m.group(3).lower(), m.group(4).lower())
        counter[key] += 1

    return [
        {"product": k[0], "version": k[1], "user": k[2], "host": k[3], "handles": v}
        for k, v in counter.items()
    ]


def parse_isv_stats(text: str) -> dict:
    """Extract denial and checkout counts from the ISV section."""
    stats = {"denials_today": 0, "checkouts_today": 0}

    today_block = re.search(
        r"foundry ISV server.*?Todays Statistics.*?Denials:\s+\d+[^\d]*(\d+)",
        text, re.DOTALL | re.IGNORECASE,
    )
    if today_block:
        stats["denials_today"] = int(today_block.group(1))

    checkouts_today = re.search(
        r"foundry ISV server.*?Todays Statistics.*?Checkouts:\s+\d+[^\d]*(\d+)",
        text, re.DOTALL | re.IGNORECASE,
    )
    if checkouts_today:
        stats["checkouts_today"] = int(checkouts_today.group(1))

    return stats


# ── metrics builder ────────────────────────────────────────────────────────────

def scrape_rlm() -> str:
    lines     = []
    scrape_ok = 1

    try:
        raw   = run_rlmutil()
        pool  = parse_pool_status(raw)
        usage = parse_usage(raw)
        isv   = parse_isv_stats(raw)

        log.info("Products found: %s", sorted({p["product"] for p in pool}))

        # ── per product + version ──────────────────────────────────────────────
        lines += ["# HELP rlm_license_total Total licenses per product/version",
                  "# TYPE rlm_license_total gauge"]
        for p in pool:
            lines.append(f'rlm_license_total{{product="{p["product"]}",version="{p["version"]}",exp="{p["exp"]}"}} {p["total"]}')

        lines += ["# HELP rlm_license_used Licenses in use per product/version",
                  "# TYPE rlm_license_used gauge"]
        for p in pool:
            lines.append(f'rlm_license_used{{product="{p["product"]}",version="{p["version"]}",exp="{p["exp"]}"}} {p["used"]}')

        lines += ["# HELP rlm_license_free Free licenses per product/version",
                  "# TYPE rlm_license_free gauge"]
        for p in pool:
            lines.append(f'rlm_license_free{{product="{p["product"]}",version="{p["version"]}",exp="{p["exp"]}"}} {p["total"] - p["used"]}')

        lines += ["# HELP rlm_license_usage_ratio Usage ratio (0.0-1.0)",
                  "# TYPE rlm_license_usage_ratio gauge"]
        for p in pool:
            ratio = round(p["used"] / p["total"], 4) if p["total"] > 0 else 0.0
            lines.append(f'rlm_license_usage_ratio{{product="{p["product"]}",version="{p["version"]}",exp="{p["exp"]}"}} {ratio}')

        lines += ["# HELP rlm_license_checkouts_total Historical total checkouts",
                  "# TYPE rlm_license_checkouts_total counter"]
        for p in pool:
            lines.append(f'rlm_license_checkouts_total{{product="{p["product"]}",version="{p["version"]}"}} {p["total_checkouts"]}')

        # ── aggregated per product (skip 'permanent' legacy entries) ──────────
        agg_total: dict = defaultdict(int)
        agg_used:  dict = defaultdict(int)
        for p in pool:
            if p["exp"].lower() == "permanent":
                continue
            agg_total[p["product"]] += p["total"]
            agg_used[p["product"]]  += p["used"]

        lines += ["# HELP rlm_product_license_total Aggregated total licenses per product",
                  "# TYPE rlm_product_license_total gauge"]
        for prod, total in agg_total.items():
            lines.append(f'rlm_product_license_total{{product="{prod}"}} {total}')

        lines += ["# HELP rlm_product_license_used Aggregated licenses in use per product",
                  "# TYPE rlm_product_license_used gauge"]
        for prod, used in agg_used.items():
            lines.append(f'rlm_product_license_used{{product="{prod}"}} {used}')

        lines += ["# HELP rlm_product_license_usage_ratio Aggregated usage ratio per product",
                  "# TYPE rlm_product_license_usage_ratio gauge"]
        for prod in agg_total:
            ratio = round(agg_used[prod] / agg_total[prod], 4) if agg_total[prod] > 0 else 0.0
            lines.append(f'rlm_product_license_usage_ratio{{product="{prod}"}} {ratio}')

        # ── active user handles ────────────────────────────────────────────────
        if usage:
            lines += ["# HELP rlm_user_active_handles Active handles per user/host/product",
                      "# TYPE rlm_user_active_handles gauge"]
            for u in usage:
                lines.append(
                    f'rlm_user_active_handles{{user="{u["user"]}",host="{u["host"]}",'
                    f'product="{u["product"]}",version="{u["version"]}"}} {u["handles"]}'
                )

        # ── unique active users per product ────────────────────────────────────
        users_per_product: dict = defaultdict(set)
        for u in usage:
            users_per_product[u["product"]].add(u["user"])

        lines += ["# HELP rlm_product_active_users Unique users with an active license",
                  "# TYPE rlm_product_active_users gauge"]
        for prod, users in users_per_product.items():
            lines.append(f'rlm_product_active_users{{product="{prod}"}} {len(users)}')

        # ── ISV stats ──────────────────────────────────────────────────────────
        lines += ["# HELP rlm_isv_denials_today License denials today",
                  "# TYPE rlm_isv_denials_today gauge",
                  f'rlm_isv_denials_today{{isv="foundry"}} {isv["denials_today"]}']

        lines += ["# HELP rlm_isv_checkouts_today License checkouts today",
                  "# TYPE rlm_isv_checkouts_today gauge",
                  f'rlm_isv_checkouts_today{{isv="foundry"}} {isv["checkouts_today"]}']

    except Exception as e:
        log.error("Scrape error: %s", e)
        scrape_ok = 0

    # ── health ─────────────────────────────────────────────────────────────────
    lines += [
        "# HELP rlm_exporter_up 1 if last scrape succeeded, 0 otherwise",
        "# TYPE rlm_exporter_up gauge",
        f"rlm_exporter_up {scrape_ok}",
        "# HELP rlm_exporter_scrape_timestamp_seconds Unix timestamp of last scrape",
        "# TYPE rlm_exporter_scrape_timestamp_seconds gauge",
        f"rlm_exporter_scrape_timestamp_seconds {time.time():.0f}",
    ]

    return "\n".join(lines) + "\n"


# ── background loop ────────────────────────────────────────────────────────────

def background_scraper():
    global _metrics_text
    while True:
        try:
            text = scrape_rlm()
            with _metrics_lock:
                _metrics_text = text.encode("utf-8")
            log.info("Scrape OK — %d bytes", len(_metrics_text))
        except Exception as e:
            log.exception("Unexpected error in scraper: %s", e)
        time.sleep(SCRAPE_INTERVAL)


# ── HTTP server ────────────────────────────────────────────────────────────────

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/metrics", "/metrics/"):
            with _metrics_lock:
                body = _metrics_text
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/":
            body = b"<html><body><h3>Nuke RLM Exporter</h3><a href='/metrics'>/metrics</a></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


# ── main ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    log.info("Nuke RLM Exporter starting…")
    log.info("  RLM server : %s (port %s)", RLM_HOST, RLM_PORT)
    log.info("  rlmutil    : %s", RLMUTIL_PATH)
    log.info("  Command    : %s rlmstat -a -c %s@%s", RLMUTIL_PATH, RLM_PORT, RLM_HOST)
    log.info("  Metrics    : http://0.0.0.0:%d/metrics", EXPORTER_PORT)
    log.info("  Interval   : %ds", SCRAPE_INTERVAL)

    # First scrape immediately
    try:
        text = scrape_rlm()
        with _metrics_lock:
            _metrics_text = text.encode("utf-8")
        log.info("First scrape OK")
    except Exception as e:
        log.warning("First scrape failed: %s", e)

    t = threading.Thread(target=background_scraper, daemon=True)
    t.start()

    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), MetricsHandler)
    log.info("Listening on http://0.0.0.0:%d", EXPORTER_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Exporter stopped.")
