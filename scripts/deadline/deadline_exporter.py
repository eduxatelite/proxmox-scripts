#!/usr/bin/env python3
"""
Deadline Farm Monitor — Prometheus Exporter
Reads the Deadline Web Service REST API and exposes metrics for Prometheus.

Environment variables (set in config/exporter.env):
  DEADLINE_HOST    - IP or hostname of Deadline Web Service
  DEADLINE_PORT    - Port (default: 8081)
  DEADLINE_APIKEY  - API Key (leave empty if auth is disabled)
  EXPORTER_PORT    - Port this exporter listens on (default: 9100)
"""

import os
import sys
import time
import logging
import requests
from datetime import datetime, timedelta, timezone
from prometheus_client import start_http_server, Gauge, Counter, Info

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("deadline_exporter")

# ── config from environment ────────────────────────────────────────────────────
DEADLINE_HOST   = os.environ.get("DEADLINE_HOST",   "localhost")
DEADLINE_PORT   = os.environ.get("DEADLINE_PORT",   "8081")
DEADLINE_APIKEY = os.environ.get("DEADLINE_APIKEY", "")
EXPORTER_PORT   = int(os.environ.get("EXPORTER_PORT", "9100"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "15"))
HTTP_TIMEOUT    = int(os.environ.get("HTTP_TIMEOUT",    "60"))
JOBS_FILTER     = os.environ.get("JOBS_FILTER",     "")
# Drop jobs whose submission date is older than this. 0 = no age filter.
# Default 60 days — keeps the dashboard responsive even on farms that never
# purge their Deadline history.
JOBS_MAX_AGE_DAYS = int(os.environ.get("JOBS_MAX_AGE_DAYS", "60"))

BASE_URL = f"http://{DEADLINE_HOST}:{DEADLINE_PORT}"
HEADERS  = {}
if DEADLINE_APIKEY:
    HEADERS["X-Thinkbox-DeadlineWebAPI-Password"] = DEADLINE_APIKEY

# ── prometheus metrics ─────────────────────────────────────────────────────────

# Workers
g_workers_active  = Gauge("deadline_workers_active",  "Workers currently rendering")
g_workers_idle    = Gauge("deadline_workers_idle",    "Workers idle, waiting for jobs")
g_workers_offline = Gauge("deadline_workers_offline", "Workers offline or in error")
g_workers_stalled = Gauge("deadline_workers_stalled", "Workers stalled")
g_workers_total   = Gauge("deadline_workers_total",   "Total workers registered")

# Jobs
g_jobs_rendering  = Gauge("deadline_jobs_rendering",  "Jobs currently rendering")
g_jobs_queued     = Gauge("deadline_jobs_queued",     "Jobs waiting in queue")
g_jobs_completed  = Gauge("deadline_jobs_completed",  "Jobs completed")
g_jobs_failed     = Gauge("deadline_jobs_failed",     "Jobs failed")
g_jobs_suspended  = Gauge("deadline_jobs_suspended",  "Jobs suspended")
g_jobs_total      = Gauge("deadline_jobs_total",      "Total jobs in the system")

# Tasks
g_tasks_completed = Gauge("deadline_tasks_completed_total", "Total tasks completed across all active jobs")
g_tasks_total     = Gauge("deadline_tasks_total",           "Total tasks across all active jobs")

# Performance
g_farm_utilization = Gauge("deadline_farm_utilization_pct", "Farm utilization percentage (active/total workers)")

# Scrape health
c_scrape_errors   = Counter("deadline_scrape_errors_total", "Total number of scrape errors")
g_scrape_duration = Gauge("deadline_scrape_duration_seconds", "Time taken to scrape Deadline API")
g_up              = Gauge("deadline_up", "1 if Deadline Web Service is reachable, 0 otherwise")
g_jobs_window     = Gauge("deadline_jobs_window_days", "Age window applied to /api/jobs (days; 0 = unlimited)")

# Per-pool metrics
g_pool_workers    = Gauge("deadline_pool_workers",    "Workers per pool", ["pool"])
g_pool_jobs       = Gauge("deadline_pool_jobs",       "Jobs per pool",    ["pool"])


def parse_job_date(job: dict):
    """Try to extract a job's submission datetime from the API payload.

    Deadline's JSON shape varies slightly across versions. We probe a few
    likely fields and return a timezone-aware datetime, or None if no
    parseable date is present.
    """
    props = job.get("Props", {}) or {}
    candidates = (
        props.get("SubDate"),
        props.get("SubmitTime"),
        props.get("SubmitDateTime"),
        props.get("Sub"),
        props.get("Date"),
        job.get("Date"),
        job.get("DateStart"),
    )
    for raw in candidates:
        if not raw or not isinstance(raw, str):
            continue
        # Accept '...Z' suffix and trim sub-second precision past microseconds
        s = raw.replace("Z", "+00:00")
        try:
            dt = datetime.fromisoformat(s)
        except ValueError:
            # Fallback: strip fractional seconds if present
            try:
                base, _, rest = s.partition(".")
                tz = ""
                if "+" in rest:
                    rest, sep, tz = rest.partition("+"); tz = sep + tz
                elif "-" in rest:
                    rest, sep, tz = rest.partition("-"); tz = sep + tz
                dt = datetime.fromisoformat(base + tz)
            except Exception:
                continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    return None


def filter_jobs_by_age(jobs: list, max_age_days: int):
    """Drop jobs older than max_age_days. Jobs with unparseable dates are kept
    (better to over-include than silently drop). Returns (filtered, stats)."""
    if max_age_days <= 0 or not jobs:
        return jobs, {"kept": len(jobs or []), "dropped": 0, "no_date": 0}
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    kept, dropped, no_date = [], 0, 0
    for j in jobs:
        dt = parse_job_date(j)
        if dt is None:
            kept.append(j)
            no_date += 1
        elif dt >= cutoff:
            kept.append(j)
        else:
            dropped += 1
    return kept, {"kept": len(kept), "dropped": dropped, "no_date": no_date}


def fetch(endpoint: str):
    """Fetch JSON from Deadline Web Service. Returns None on error."""
    url = f"{BASE_URL}{endpoint}"
    try:
        r = requests.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
        if r.status_code == 401:
            log.error("[AUTH ERROR] Invalid or missing API Key for %s", url)
            return None
        if r.status_code == 403:
            log.error("[AUTH ERROR] Access forbidden for %s", url)
            return None
        r.raise_for_status()
        return r.json()
    except requests.exceptions.ConnectionError:
        log.warning("Cannot connect to Deadline Web Service at %s", BASE_URL)
        return None
    except requests.exceptions.Timeout:
        log.warning("Timeout connecting to %s", url)
        return None
    except Exception as e:
        log.error("Error fetching %s: %s", url, e)
        return None


def collect():
    """Scrape Deadline API and update all Prometheus metrics.

    Workers and jobs are fetched independently so a slow/failing /api/jobs
    (common on busy farms with large historical job tables) does not break
    worker metrics — and vice versa.
    """
    start = time.time()

    workers = fetch("/api/slaves")

    jobs_endpoint = "/api/jobs"
    if JOBS_FILTER:
        jobs_endpoint += "?" + JOBS_FILTER.lstrip("?")
    jobs = fetch(jobs_endpoint)

    # Apply client-side age filter to drop ancient completed jobs that
    # explode the API response on farms that never purge history.
    if jobs is not None:
        total_before = len(jobs)
        jobs, stats = filter_jobs_by_age(jobs, JOBS_MAX_AGE_DAYS)
        if JOBS_MAX_AGE_DAYS > 0 and total_before:
            log.info(
                "Jobs age-filter (<=%d days): kept %d / dropped %d / no-date %d (from %d total)",
                JOBS_MAX_AGE_DAYS, stats["kept"], stats["dropped"], stats["no_date"], total_before,
            )

    if workers is None and jobs is None:
        g_up.set(0)
        c_scrape_errors.inc()
        g_scrape_duration.set(time.time() - start)
        log.error("Both /api/slaves and %s failed", jobs_endpoint)
        return

    # at least one endpoint responded — flag exporter as UP
    g_up.set(1)
    if workers is None:
        c_scrape_errors.inc()
        log.warning("/api/slaves unreachable — keeping last worker values")
    if jobs is None:
        c_scrape_errors.inc()
        log.warning("%s unreachable — keeping last job values", jobs_endpoint)

    # initialise summary vars so the final log line works regardless of which
    # endpoint(s) actually responded
    total = active = 0
    job_counts = {"rendering": 0, "queued": 0, "failed": 0}

    # ── worker metrics ──────────────────────────────────────────────────────
    # Deadline API: each worker is {"Info": {..., "Stat": <int>, "Pools": "..."}, "Settings": {...}}
    # Info.Stat codes: 0=Unknown, 1=Rendering, 2=Idle, 3=Offline, 4=Disabled, 5=Stalled
    if workers is not None:
        WORKER_STAT  = {0:"unknown", 1:"rendering", 2:"idle", 3:"offline", 4:"disabled", 5:"stalled"}
        status_map   = {}
        pool_workers = {}

        for w in workers:
            info     = w.get("Info", w)           # real API nests data in Info{}
            settings = w.get("Settings", {})
            enabled  = settings.get("Enable", True)
            stat_num = info.get("Stat", 0)
            if not enabled:
                status = "disabled"
            else:
                status = WORKER_STAT.get(stat_num, "unknown")
            status_map[status] = status_map.get(status, 0) + 1

            # Info.Pools is a string in this API version
            pool = info.get("Pools", "none") or "none"
            pool_workers[pool] = pool_workers.get(pool, 0) + 1

        g_workers_active.set(status_map.get("rendering", 0))
        g_workers_idle.set(status_map.get("idle", 0))
        g_workers_offline.set(
            status_map.get("offline", 0) +
            status_map.get("unknown", 0)
        )
        g_workers_stalled.set(status_map.get("stalled", 0) + status_map.get("disabled", 0))
        g_workers_total.set(len(workers))

        for pool, count in pool_workers.items():
            g_pool_workers.labels(pool=pool).set(count)

        # farm utilization
        total = len(workers)
        active = status_map.get("rendering", 0)
        g_farm_utilization.set(round((active / total * 100) if total > 0 else 0, 1))

    # ── job metrics ─────────────────────────────────────────────────────────
    # Deadline job status codes: 0=Unknown,1=Active,2=Suspended,3=Completed,4=Failed,5=Pending
    if jobs is not None:
        JOB_STATUS = {0: "unknown", 1: "rendering", 2: "suspended", 3: "completed", 4: "failed", 5: "queued"}

        job_counts  = {s: 0 for s in JOB_STATUS.values()}
        pool_jobs   = {}
        tasks_done  = 0
        tasks_total = 0

        for j in jobs:
            props  = j.get("Props", {})
            status = JOB_STATUS.get(props.get("Stat", 0), "unknown")
            job_counts[status] = job_counts.get(status, 0) + 1

            # per-pool
            pool = props.get("Pool", "none") or "none"
            pool_jobs[pool] = pool_jobs.get(pool, 0) + 1

            # task progress
            comp = props.get("CompF", 0) or 0
            tot  = props.get("Tasks", 0) or 0
            tasks_done  += comp
            tasks_total += tot

        g_jobs_rendering.set(job_counts["rendering"])
        g_jobs_queued.set(job_counts["queued"] + job_counts["unknown"])
        g_jobs_completed.set(job_counts["completed"])
        g_jobs_failed.set(job_counts["failed"])
        g_jobs_suspended.set(job_counts["suspended"])
        g_jobs_total.set(len(jobs))
        g_tasks_completed.set(tasks_done)
        g_tasks_total.set(tasks_total)

        for pool, count in pool_jobs.items():
            g_pool_jobs.labels(pool=pool).set(count)

    elapsed = time.time() - start
    g_scrape_duration.set(elapsed)
    log.info(
        "Scraped — Workers: %d active / %d total%s | Jobs: %d rendering / %d queued / %d failed%s | %.2fs",
        active, total, "" if workers is not None else " (skipped: /api/slaves down)",
        job_counts.get("rendering", 0), job_counts.get("queued", 0), job_counts.get("failed", 0),
        "" if jobs is not None else " (skipped: /api/jobs down)",
        elapsed,
    )


# ── main ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("Deadline Farm Monitor Exporter starting…")
    log.info("Deadline Web Service: %s", BASE_URL)
    log.info("Authentication: %s", "enabled" if DEADLINE_APIKEY else "disabled")
    log.info("Exporter port: %d", EXPORTER_PORT)
    log.info("Scrape interval: %ds", SCRAPE_INTERVAL)
    log.info("HTTP timeout: %ds", HTTP_TIMEOUT)
    log.info("Jobs filter: %s", JOBS_FILTER if JOBS_FILTER else "(none — fetching all jobs)")
    log.info("Jobs max age: %s",
             f"{JOBS_MAX_AGE_DAYS} days" if JOBS_MAX_AGE_DAYS > 0 else "unlimited")

    start_http_server(EXPORTER_PORT)
    log.info("Prometheus metrics available at http://0.0.0.0:%d/metrics", EXPORTER_PORT)
    g_jobs_window.set(JOBS_MAX_AGE_DAYS)

    while True:
        try:
            collect()
        except Exception as e:
            log.error("Unexpected error during collection: %s", e)
            c_scrape_errors.inc()
            g_up.set(0)
        time.sleep(SCRAPE_INTERVAL)
