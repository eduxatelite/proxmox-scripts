#!/usr/bin/env python3
"""
Deadline Farm Monitor — Dashboard Proxy
Serves the React dashboard and proxies all /api/* calls to the
Deadline Web Service, injecting the API Key header automatically.

The browser never sees the API Key — it only talks to this proxy.

Environment variables (from config/exporter.env):
  DEADLINE_HOST   - IP or hostname of Deadline Web Service
  DEADLINE_PORT   - Port (default: 8081)
  DEADLINE_APIKEY - API Key (leave empty if auth disabled)
  PROXY_PORT      - Port this proxy listens on (default: 8080)
"""

import os
import json
import logging
import requests
from flask import Flask, request, Response, send_from_directory, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("deadline_proxy")

DEADLINE_HOST   = os.environ.get("DEADLINE_HOST",   "localhost")
DEADLINE_PORT   = os.environ.get("DEADLINE_PORT",   "8081")
DEADLINE_APIKEY = os.environ.get("DEADLINE_APIKEY", "")
PROXY_PORT      = int(os.environ.get("PROXY_PORT",  "8080"))

BASE_URL = f"http://{DEADLINE_HOST}:{DEADLINE_PORT}"

app = Flask(__name__, static_folder="static")


def dl_headers():
    """Build headers for Deadline API requests."""
    h = {"Content-Type": "application/json"}
    if DEADLINE_APIKEY:
        h["X-Thinkbox-DeadlineWebAPI-Password"] = DEADLINE_APIKEY
    return h


# ── static files ──────────────────────────────────────────────────────────────

@app.route("/")
@app.route("/index.html")
def index():
    return send_from_directory("static", "index.html")


@app.route("/<path:path>")
def static_files(path):
    """Serve any static asset (JS, CSS, fonts, etc.) from the React build."""
    try:
        return send_from_directory("static", path)
    except Exception:
        # Fall back to index.html for client-side routing
        return send_from_directory("static", "index.html")


# ── Deadline API proxy ────────────────────────────────────────────────────────

@app.route("/api/<path:path>", methods=["GET", "PUT", "DELETE", "POST"])
def proxy(path):
    url = f"{BASE_URL}/api/{path}"
    try:
        resp = requests.request(
            method   = request.method,
            url      = url,
            headers  = dl_headers(),
            params   = request.args,
            data     = request.get_data(),
            timeout  = 10,
        )
        content_type = resp.headers.get("content-type", "application/json")
        log.info("%s /api/%s → HTTP %d", request.method, path, resp.status_code)
        return Response(resp.content, status=resp.status_code, content_type=content_type)

    except requests.exceptions.ConnectionError:
        log.warning("Cannot connect to Deadline at %s", BASE_URL)
        return Response(
            json.dumps({"error": "Cannot connect to Deadline Web Service", "host": BASE_URL}),
            status=503, content_type="application/json",
        )
    except requests.exceptions.Timeout:
        log.warning("Timeout connecting to Deadline at %s", BASE_URL)
        return Response(
            json.dumps({"error": "Timeout connecting to Deadline Web Service"}),
            status=504, content_type="application/json",
        )
    except Exception as e:
        log.error("Proxy error: %s", e)
        return Response(
            json.dumps({"error": str(e)}),
            status=500, content_type="application/json",
        )


# ── debug endpoint (shows raw Deadline API response) ─────────────────────────

@app.route("/debug/slaves")
def debug_slaves():
    """Return first 2 workers raw so we can inspect field names."""
    try:
        r = requests.get(f"{BASE_URL}/api/slaves", headers=dl_headers(), timeout=10)
        data = r.json()
        sample = data[:2] if isinstance(data, list) else data
        return jsonify({"count": len(data) if isinstance(data, list) else 1, "sample": sample})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── health endpoint ───────────────────────────────────────────────────────────

@app.route("/health")
def health():
    try:
        r = requests.get(f"{BASE_URL}/api/slaves", headers=dl_headers(), timeout=5)
        deadline_ok = r.status_code == 200
    except Exception:
        deadline_ok = False

    return jsonify({
        "status":       "ok",
        "deadline_url": BASE_URL,
        "deadline_up":  deadline_ok,
        "auth":         bool(DEADLINE_APIKEY),
    })


# ── config endpoint (no secrets) ──────────────────────────────────────────────

@app.route("/config")
def config():
    """Returns non-sensitive config so the dashboard knows the Deadline host."""
    return jsonify({
        "deadline_host": DEADLINE_HOST,
        "deadline_port": DEADLINE_PORT,
        "auth_enabled":  bool(DEADLINE_APIKEY),
    })


if __name__ == "__main__":
    log.info("Deadline Farm Monitor Proxy starting…")
    log.info("Deadline Web Service: %s", BASE_URL)
    log.info("Auth: %s", "enabled" if DEADLINE_APIKEY else "disabled")
    log.info("Listening on http://0.0.0.0:%d", PROXY_PORT)
    app.run(host="0.0.0.0", port=PROXY_PORT, debug=False)
