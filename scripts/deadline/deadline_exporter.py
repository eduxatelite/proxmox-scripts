#!/usr/bin/env python3
"""
Deadline Farm Monitor — Prometheus Exporter
Reads the Deadline Web Service REST API and exposes metrics for Prometheus.

Environment variables (set in config/deadline.env):
  DEADLINE_HOST         IP/hostname of Deadline Web Service
  DEADLINE_PORT         Port (default 8081)
  DEADLINE_APIKEY       API Key (leave empty if auth is disabled)
  EXPORTER_PORT         Port this exporter listens on (default 9300)
  SCRAPE_INTERVAL       Seconds between scrapes (default 30)
  HTTP_TIMEOUT          HTTP timeout (default 60s)
  JOBS_FILTER           Optional query string for /api/jobs (e.g. 'Status=Active')
  JOBS_MAX_AGE_DAYS     Drop jobs whose Date is older than N days (default 60, 0 = unlimited)
  DEPT_REGEX            Regex with one capture group extracting the department
                        from the job name. Default: '^[^-]+-[^-]+-([a-zA-Z]+)'
                        which extracts 'ani' from 'da1-251_LVB_0140-ani_3dBlock-...'.
"""

import os
import re
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

# ── config ────────────────────────────────────────────────────────────────────
DEADLINE_HOST     = os.environ.get("DEADLINE_HOST",   "localhost")
DEADLINE_PORT     = os.environ.get("DEADLINE_PORT",   "8081")
DEADLINE_APIKEY   = os.environ.get("DEADLINE_APIKEY", "")
EXPORTER_PORT     = int(os.environ.get("EXPORTER_PORT",   "9300"))
SCRAPE_INTERVAL   = int(os.environ.get("SCRAPE_INTERVAL", "30"))
HTTP_TIMEOUT      = int(os.environ.get("HTTP_TIMEOUT",    "60"))
JOBS_FILTER       = os.environ.get("JOBS_FILTER",     "")
JOBS_MAX_AGE_DAYS = int(os.environ.get("JOBS_MAX_AGE_DAYS", "60"))

# Department regex: must have exactly one capture group.
# Default targets 'da1-<shot>-<dept>_<rest>...' naming.
DEPT_REGEX_PATTERN = os.environ.get("DEPT_REGEX", r"^[^-]+-[^-]+-([a-zA-Z]+)")
try:
    DEPT_REGEX = re.compile(DEPT_REGEX_PATTERN)
except re.error as e:
    log.error("Invalid DEPT_REGEX %r (%s) — falling back to default", DEPT_REGEX_PATTERN, e)
    DEPT_REGEX = re.compile(r"^[^-]+-[^-]+-([a-zA-Z]+)")

BASE_URL = f"http://{DEADLINE_HOST}:{DEADLINE_PORT}"
HEADERS  = {}
if DEADLINE_APIKEY:
    HEADERS["X-Thinkbox-DeadlineWebAPI-Password"] = DEADLINE_APIKEY


# ── prometheus metrics ────────────────────────────────────────────────────────

# Workers
g_workers_active   = Gauge("deadline_workers_active",   "Workers currently rendering")
g_workers_idle     = Gauge("deadline_workers_idle",     "Workers idle, waiting for jobs")
g_workers_offline  = Gauge("deadline_workers_offline",  "Workers offline or in error")
g_workers_stalled  = Gauge("deadline_workers_stalled",  "Workers stalled")
g_workers_total    = Gauge("deadline_workers_total",    "Total workers registered")

# Jobs (aggregate)
g_jobs_rendering   = Gauge("deadline_jobs_rendering",   "Jobs currently rendering")
g_jobs_queued      = Gauge("deadline_jobs_queued",      "Jobs waiting in queue (pending tasks, none rendering)")
g_jobs_completed   = Gauge("deadline_jobs_completed",   "Jobs completed")
g_jobs_failed      = Gauge("deadline_jobs_failed",      "Jobs failed")
g_jobs_suspended   = Gauge("deadline_jobs_suspended",   "Jobs suspended")
g_jobs_total       = Gauge("deadline_jobs_total",       "Total jobs in the scrape window")

# Performance
g_farm_utilization = Gauge("deadline_farm_utilization_pct", "Farm utilization percentage (rendering/total workers)")

# Scrape health
c_scrape_errors    = Counter("deadline_scrape_errors_total",    "Total number of scrape errors")
g_scrape_duration  = Gauge("deadline_scrape_duration_seconds",  "Time taken to scrape Deadline API")
g_up               = Gauge("deadline_up",                       "1 if Deadline Web Service is reachable, 0 otherwise")
g_jobs_window      = Gauge("deadline_jobs_window_days",         "Age window applied to /api/jobs (days; 0 = unlimited)")

# Per-pool aggregates (existing)
g_pool_workers     = Gauge("deadline_pool_workers", "Workers per pool", ["pool"])
g_pool_jobs        = Gauge("deadline_pool_jobs",    "Jobs per pool",    ["pool"])

# Per-department aggregates (Production View)
g_dept_pending_jobs   = Gauge("deadline_dept_pending_jobs",       "Pending jobs per department",                ["department"])
g_dept_pending_tasks  = Gauge("deadline_dept_pending_tasks",      "Pending tasks per department",               ["department"])
g_dept_avg_task_secs  = Gauge("deadline_dept_avg_task_seconds",   "Avg seconds per task per dept (from recent completed jobs)", ["department"])
g_dept_est_secs_left  = Gauge("deadline_dept_est_seconds_left",   "Estimated seconds remaining per department", ["department"])

# Per-job metrics — ONLY set for jobs with RenderingChunks > 0 so cardinality
# stays bounded. Cleared at the start of every scrape so finished/stopped
# jobs disappear immediately from the dashboard.
g_job_progress_pct   = Gauge("deadline_job_progress_pct",      "Job render progress %",          ["job_id", "name", "pool"])
g_job_remaining_secs = Gauge("deadline_job_remaining_seconds", "Estimated seconds remaining",    ["job_id", "name", "pool"])
g_job_elapsed_secs   = Gauge("deadline_job_elapsed_seconds",   "Seconds since job started",      ["job_id", "name", "pool"])


# ── helpers ───────────────────────────────────────────────────────────────────

def parse_iso_date(raw):
    """Parse an ISO datetime string into a timezone-aware UTC datetime, or None."""
    if not raw or not isinstance(raw, str):
        return None
    # Deadline uses "0001-01-01T00:00:00Z" as sentinel for "unset"
    if raw.startswith("0001-"):
        return None
    s = raw.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def extract_department(name):
    """Extract the department code from a job name using DEPT_REGEX.
    Returns 'unknown' if the name doesn't match."""
    if not name or not isinstance(name, str):
        return "unknown"
    m = DEPT_REGEX.match(name)
    return m.group(1).lower() if m else "unknown"


def filter_jobs_by_age(jobs, max_age_days):
    """Drop jobs whose submission Date is older than max_age_days. Jobs with
    unparseable dates are kept (better to over-include). Returns (filtered, stats)."""
    if max_age_days <= 0 or not jobs:
        return jobs, {"kept": len(jobs or []), "dropped": 0, "no_date": 0}
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    kept, dropped, no_date = [], 0, 0
    for j in jobs:
        dt = parse_iso_date(j.get("Date"))
        if dt is None:
            kept.append(j); no_date += 1
        elif dt >= cutoff:
            kept.append(j)
        else:
            dropped += 1
    return kept, {"kept": len(kept), "dropped": dropped, "no_date": no_date}


def fetch(endpoint):
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


def classify_job(job):
    """Return effective status using Stat for done-states and chunk counters
    for in-flight states. Reflects what the user thinks of as the job's state."""
    stat = job.get("Stat", 0)
    if stat == 3:
        return "completed"
    if stat == 4:
        return "failed"
    if stat == 2:
        return "suspended"
    if job.get("RenderingChunks", 0) > 0:
        return "rendering"
    if (job.get("QueuedChunks", 0) + job.get("PendingChunks", 0)) > 0:
        return "queued"
    return "unknown"


# ── main collection ──────────────────────────────────────────────────────────

def collect():
    """Scrape Deadline API and update Prometheus metrics. Workers and jobs are
    fetched independently — a slow /api/jobs doesn't break worker metrics."""
    start = time.time()

    workers = fetch("/api/slaves")

    jobs_endpoint = "/api/jobs"
    if JOBS_FILTER:
        jobs_endpoint += "?" + JOBS_FILTER.lstrip("?")
    jobs = fetch(jobs_endpoint)

    # Age filter
    if jobs is not None:
        total_before = len(jobs)
        jobs, stats = filter_jobs_by_age(jobs, JOBS_MAX_AGE_DAYS)
        if JOBS_MAX_AGE_DAYS > 0 and total_before:
            log.info("Jobs age-filter (<=%d days): kept %d / dropped %d / no-date %d (from %d total)",
                     JOBS_MAX_AGE_DAYS, stats["kept"], stats["dropped"], stats["no_date"], total_before)

    if workers is None and jobs is None:
        g_up.set(0)
        c_scrape_errors.inc()
        g_scrape_duration.set(time.time() - start)
        log.error("Both /api/slaves and %s failed", jobs_endpoint)
        return

    g_up.set(1)
    if workers is None:
        c_scrape_errors.inc()
        log.warning("/api/slaves unreachable — keeping last worker values")
    if jobs is None:
        c_scrape_errors.inc()
        log.warning("%s unreachable — keeping last job values", jobs_endpoint)

    total = active = 0
    job_counts = {"rendering": 0, "queued": 0, "failed": 0, "completed": 0, "suspended": 0, "unknown": 0}

    # ── workers ─────────────────────────────────────────────────────────────
    if workers is not None:
        WORKER_STAT = {0:"unknown", 1:"rendering", 2:"idle", 3:"offline", 4:"disabled", 5:"stalled"}
        status_map = {}
        pool_workers = {}
        for w in workers:
            info     = w.get("Info", w)
            settings = w.get("Settings", {})
            enabled  = settings.get("Enable", True)
            stat_num = info.get("Stat", 0)
            status   = "disabled" if not enabled else WORKER_STAT.get(stat_num, "unknown")
            status_map[status] = status_map.get(status, 0) + 1
            pool = info.get("Pools", "none") or "none"
            pool_workers[pool] = pool_workers.get(pool, 0) + 1

        g_workers_active.set(status_map.get("rendering", 0))
        g_workers_idle.set(status_map.get("idle", 0))
        g_workers_offline.set(status_map.get("offline", 0) + status_map.get("unknown", 0))
        g_workers_stalled.set(status_map.get("stalled", 0) + status_map.get("disabled", 0))
        g_workers_total.set(len(workers))

        g_pool_workers.clear()
        for pool, count in pool_workers.items():
            g_pool_workers.labels(pool=pool).set(count)

        total = len(workers)
        active = status_map.get("rendering", 0)
        g_farm_utilization.set(round((active / total * 100) if total > 0 else 0, 1))

    # ── jobs ────────────────────────────────────────────────────────────────
    if jobs is not None:
        pool_jobs          = {}
        dept_pending_jobs  = {}
        dept_pending_tasks = {}
        dept_task_times    = {}  # dept -> [seconds_per_task, ...] from completed jobs

        # Clear per-job gauges so completed/stopped jobs disappear immediately
        g_job_progress_pct.clear()
        g_job_remaining_secs.clear()
        g_job_elapsed_secs.clear()

        now = datetime.now(timezone.utc)

        for j in jobs:
            props   = j.get("Props", {}) or {}
            name    = props.get("Name", "") or ""
            pool    = props.get("Pool", "none") or "none"
            tasks_n = props.get("Tasks", 0) or 0

            completed_chunks = j.get("CompletedChunks", 0) or 0
            rendering_chunks = j.get("RenderingChunks", 0) or 0
            pending_chunks   = j.get("PendingChunks", 0)   or 0
            queued_chunks    = j.get("QueuedChunks", 0)    or 0

            status = classify_job(j)
            job_counts[status] = job_counts.get(status, 0) + 1
            pool_jobs[pool] = pool_jobs.get(pool, 0) + 1

            dept = extract_department(name)

            # Production view: count pending jobs/tasks per department
            if status in ("rendering", "queued"):
                dept_pending_jobs[dept]  = dept_pending_jobs.get(dept, 0) + 1
                pending_count = queued_chunks + pending_chunks
                dept_pending_tasks[dept] = dept_pending_tasks.get(dept, 0) + pending_count

            # Collect time-per-task data from completed jobs (per dept)
            if status == "completed" and tasks_n > 0:
                ds = parse_iso_date(j.get("DateStart"))
                dc = parse_iso_date(j.get("DateComp"))
                if ds and dc and dc > ds:
                    secs_per_task = (dc - ds).total_seconds() / tasks_n
                    dept_task_times.setdefault(dept, []).append(secs_per_task)

            # Per-job metrics for currently rendering jobs
            if rendering_chunks > 0:
                job_id = j.get("_id", "") or name[:24]
                short_name = (name[:80] + "…") if len(name) > 80 else name
                progress = (completed_chunks / tasks_n * 100) if tasks_n > 0 else 0

                ds = parse_iso_date(j.get("DateStart"))
                elapsed_s  = 0
                remaining  = 0
                if ds:
                    elapsed_s = max(0, (now - ds).total_seconds())
                    if completed_chunks > 0:
                        secs_per_task = elapsed_s / completed_chunks
                        remaining = secs_per_task * max(0, tasks_n - completed_chunks)

                g_job_progress_pct.labels(job_id=job_id, name=short_name, pool=pool).set(progress)
                g_job_remaining_secs.labels(job_id=job_id, name=short_name, pool=pool).set(remaining)
                g_job_elapsed_secs.labels(job_id=job_id, name=short_name, pool=pool).set(elapsed_s)

        # Set aggregate job counters
        g_jobs_rendering.set(job_counts["rendering"])
        g_jobs_queued.set(job_counts["queued"] + job_counts["unknown"])
        g_jobs_completed.set(job_counts["completed"])
        g_jobs_failed.set(job_counts["failed"])
        g_jobs_suspended.set(job_counts["suspended"])
        g_jobs_total.set(len(jobs))

        # Pool jobs
        g_pool_jobs.clear()
        for pool, count in pool_jobs.items():
            g_pool_jobs.labels(pool=pool).set(count)

        # Department gauges — clear and re-set so disappearing depts go to 0
        g_dept_pending_jobs.clear()
        g_dept_pending_tasks.clear()
        g_dept_avg_task_secs.clear()
        g_dept_est_secs_left.clear()
        all_depts = set(dept_pending_jobs.keys()) | set(dept_task_times.keys())
        for dept in all_depts:
            pending_j = dept_pending_jobs.get(dept, 0)
            pending_t = dept_pending_tasks.get(dept, 0)
            times     = dept_task_times.get(dept, [])
            avg       = (sum(times) / len(times)) if times else 0
            g_dept_pending_jobs.labels(department=dept).set(pending_j)
            g_dept_pending_tasks.labels(department=dept).set(pending_t)
            g_dept_avg_task_secs.labels(department=dept).set(avg)
            g_dept_est_secs_left.labels(department=dept).set(avg * pending_t)

    elapsed = time.time() - start
    g_scrape_duration.set(elapsed)
    log.info(
        "Scraped — Workers: %d active/%d total%s | Jobs: %d rendering / %d queued / %d failed / %d completed%s | %.2fs",
        active, total, "" if workers is not None else " (skipped)",
        job_counts.get("rendering", 0), job_counts.get("queued", 0) + job_counts.get("unknown", 0),
        job_counts.get("failed", 0), job_counts.get("completed", 0),
        "" if jobs is not None else " (skipped)",
        elapsed,
    )


# ── main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("Deadline Farm Monitor Exporter starting…")
    log.info("Deadline Web Service: %s", BASE_URL)
    log.info("Authentication: %s", "enabled" if DEADLINE_APIKEY else "disabled")
    log.info("Exporter port: %d", EXPORTER_PORT)
    log.info("Scrape interval: %ds", SCRAPE_INTERVAL)
    log.info("HTTP timeout: %ds", HTTP_TIMEOUT)
    log.info("Jobs filter: %s", JOBS_FILTER if JOBS_FILTER else "(none — fetching all jobs)")
    log.info("Jobs max age: %s", f"{JOBS_MAX_AGE_DAYS} days" if JOBS_MAX_AGE_DAYS > 0 else "unlimited")
    log.info("Department regex: %s", DEPT_REGEX_PATTERN)

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
