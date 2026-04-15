import { useState, useEffect, useRef, useCallback } from "react";
import {
  AreaChart, Area, BarChart, Bar,
  XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";

// ── palette ───────────────────────────────────────────────────────────────────
const C = {
  bg: "#111217", panel: "#181b1f", border: "#2a2d3a",
  text: "#d0d4e0", muted: "#6e7281",
  green: "#73bf69", yellow: "#fade2a", red: "#f2495c",
  blue: "#5794f2", orange: "#ff9830", purple: "#b877d9",
};

// ── API helpers ───────────────────────────────────────────────────────────────
// In production (served by proxy), calls go to /api/* on the same origin.
// In dev/mockup mode, BASE_URL can be overridden.
const BASE = typeof window !== "undefined" && window.DEADLINE_BASE
  ? window.DEADLINE_BASE
  : "";

async function dlGet(path) {
  const r = await fetch(`${BASE}/api/${path}`);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

async function dlPut(path, body) {
  const r = await fetch(`${BASE}/api/${path}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json().catch(() => ({}));
}

async function dlDelete(path) {
  const r = await fetch(`${BASE}/api/${path}`, { method: "DELETE" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

// ── data mappers ──────────────────────────────────────────────────────────────
function mapWorkerStat(stat, enabled) {
  // Deadline worker Info.Stat: 0=Unknown,1=Rendering,2=Idle,3=Offline,4=Disabled,5=Stalled
  if (enabled === false) return "disabled";
  const m = { 1: "active", 2: "idle", 4: "disabled", 5: "stalled" };
  return m[stat] ?? "offline"; // 0=Unknown, 3=Offline → offline
}

function mapJobStat(stat) {
  // Deadline Job Props.Stat: 0=Unknown,1=Active,2=Suspended,3=Completed,4=Failed,5=Pending
  const m = { 0:"queued", 1:"rendering", 2:"suspended", 3:"completed", 4:"failed", 5:"queued" };
  return m[stat] ?? "queued";
}

function parseWorkers(raw = []) {
  return raw.map(w => {
    const info     = w.Info     ?? w;          // real API wraps data in Info{}
    const settings = w.Settings ?? {};
    const stat     = info.Stat  ?? 0;
    const enabled  = settings.Enable !== false;
    return {
      id:     info.Name ?? info._id ?? "unknown",
      job:    info.JobName || "—",
      pool:   info.Pools  || (Array.isArray(settings.Pools) ? settings.Pools[0] : settings.Pools) || "—",
      cpu:    Math.round(info.CPU ?? 0),
      status: mapWorkerStat(stat, enabled),
      rawSt:  stat,
      ip:     info.IP ?? "",
    };
  });
}

function parseJobs(raw = []) {
  return raw
    .filter(j => mapJobStat(j.Props?.Stat) !== "completed") // hide completed
    .map(j => {
      const p    = j.Props ?? {};
      const done = p.CompF  ?? 0;
      const tot  = p.Tasks  ?? 0;
      return {
        id:     j._id ?? j.JobID ?? "",
        name:   p.Name  ?? "Unnamed Job",
        pool:   p.Pool  ?? "—",
        pri:    p.Pri   ?? 0,
        tasks:  `${done}/${tot}`,
        status: mapJobStat(p.Stat),
        pct:    tot > 0 ? Math.round((done / tot) * 100) : 0,
      };
    });
}

// pool bar data derived from jobs
function buildPoolData(jobs) {
  const counts = {};
  jobs.forEach(j => { counts[j.pool] = (counts[j.pool] || 0) + 1; });
  return Object.entries(counts)
    .map(([pool, jobs]) => ({ pool, jobs }))
    .sort((a, b) => b.jobs - a.jobs)
    .slice(0, 7);
}

// ── colour helpers ────────────────────────────────────────────────────────────
const workerColor = s => ({
  active:   C.green,
  idle:     C.yellow,
  offline:  C.red,
  disabled: C.muted,
  stalled:  C.orange,
}[s] ?? C.muted);
const jobColor    = s => ({ rendering: C.blue, queued: C.yellow, failed: C.red, suspended: "#888" }[s] ?? C.muted);

// ── TOAST ─────────────────────────────────────────────────────────────────────
function Toast({ toasts }) {
  return (
    <div style={{ position: "fixed", bottom: 24, right: 24, display: "flex", flexDirection: "column", gap: 8, zIndex: 9999 }}>
      {toasts.map(t => (
        <div key={t.id} style={{
          background: "#23262e", border: `1px solid ${t.color}44`,
          borderLeft: `3px solid ${t.color}`, borderRadius: 4,
          padding: "10px 16px", color: C.text, fontSize: 12,
          boxShadow: "0 4px 20px #0008", minWidth: 260,
          animation: "fadeIn .2s ease",
        }}>
          <span style={{ color: t.color, marginRight: 8 }}>{t.icon}</span>{t.msg}
        </div>
      ))}
    </div>
  );
}

// ── CONTEXT MENU ──────────────────────────────────────────────────────────────
function ContextMenu({ x, y, items, onClose }) {
  const ref = useRef();
  useEffect(() => {
    const h = e => { if (ref.current && !ref.current.contains(e.target)) onClose(); };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, [onClose]);
  return (
    <div ref={ref} style={{
      position: "fixed", left: x, top: y, zIndex: 9000,
      background: "#1e2128", border: `1px solid ${C.border}`,
      borderRadius: 6, boxShadow: "0 8px 32px #000a",
      minWidth: 210, overflow: "hidden",
    }}>
      {items.map((it, i) =>
        it === "---"
          ? <div key={i} style={{ height: 1, background: C.border, margin: "2px 0" }} />
          : (
            <div key={i} onClick={() => { it.action(); onClose(); }} style={{
              padding: "9px 14px", cursor: "pointer",
              color: it.danger ? C.red : it.color ?? C.text,
              fontSize: 12, display: "flex", alignItems: "center", gap: 10,
              transition: "background .1s",
            }}
              onMouseEnter={e => e.currentTarget.style.background = "#2a2d3a"}
              onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
              <span style={{ fontSize: 14 }}>{it.icon}</span>
              <div>
                <div>{it.label}</div>
                {it.desc && <div style={{ fontSize: 10, color: C.muted, marginTop: 1 }}>{it.desc}</div>}
              </div>
            </div>
          )
      )}
    </div>
  );
}

// ── CONFIRM DIALOG ────────────────────────────────────────────────────────────
function ConfirmDialog({ msg, onYes, onNo }) {
  return (
    <div style={{ position: "fixed", inset: 0, background: "#0009", zIndex: 9500, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <div style={{ background: "#1e2128", border: `1px solid ${C.border}`, borderRadius: 8, padding: "24px 28px", maxWidth: 360, width: "90%", boxShadow: "0 16px 48px #000c" }}>
        <div style={{ fontSize: 14, color: C.text, marginBottom: 20, lineHeight: 1.6 }}>{msg}</div>
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button onClick={onNo} style={{ background: "transparent", border: `1px solid ${C.border}`, color: C.muted, borderRadius: 4, padding: "6px 18px", cursor: "pointer", fontSize: 12 }}>Cancel</button>
          <button onClick={onYes} style={{ background: C.red, border: "none", color: "#fff", borderRadius: 4, padding: "6px 18px", cursor: "pointer", fontSize: 12, fontWeight: 700 }}>Confirm</button>
        </div>
      </div>
    </div>
  );
}

// ── PANEL ─────────────────────────────────────────────────────────────────────
function Panel({ title, children, style = {} }) {
  return (
    <div style={{ background: C.panel, border: `1px solid ${C.border}`, borderRadius: 4, padding: "12px 14px", ...style }}>
      {title && <div style={{ fontSize: 11, color: C.muted, marginBottom: 10, textTransform: "uppercase", letterSpacing: 1 }}>{title}</div>}
      {children}
    </div>
  );
}

// ── STAT CARD with hover popover ──────────────────────────────────────────────
function StatCard({ label, value, unit = "", color = C.text, sub, popover }) {
  const [open, setOpen] = useState(false);
  const ref = useRef();
  useEffect(() => {
    if (!open) return;
    const h = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, [open]);
  return (
    <div ref={ref} style={{ flex: 1, position: "relative" }}
      onMouseEnter={() => popover && setOpen(true)}
      onMouseLeave={() => setOpen(false)}>
      <div style={{
        background: C.panel, border: `1px solid ${open && popover ? color : C.border}`,
        borderRadius: 4, padding: "12px 14px", textAlign: "center",
        cursor: popover ? "pointer" : "default",
        transition: "border-color .15s,box-shadow .15s",
        boxShadow: open && popover ? `0 0 0 1px ${color}44` : "none",
      }}>
        <div style={{ fontSize: 11, color: C.muted, marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>{label}</div>
        <div style={{ fontSize: 36, fontWeight: 700, color, lineHeight: 1 }}>
          {value}<span style={{ fontSize: 16, color: C.muted, marginLeft: 4 }}>{unit}</span>
        </div>
        {sub && <div style={{ fontSize: 11, color: C.muted, marginTop: 6 }}>{sub}</div>}
        {popover && <div style={{ fontSize: 10, color: `${color}88`, marginTop: 4 }}>▼ hover for details</div>}
      </div>
      {open && popover && (
        <div style={{
          position: "absolute", top: "calc(100% + 6px)", left: "50%", transform: "translateX(-50%)",
          background: "#1e2128", border: `1px solid ${color}55`, borderRadius: 6,
          boxShadow: `0 12px 40px #000c,0 0 0 1px ${color}22`,
          zIndex: 8000, minWidth: 280, maxWidth: 360, overflow: "hidden",
          animation: "fadeIn .15s ease",
        }}
          onMouseEnter={() => setOpen(true)}
          onMouseLeave={() => setOpen(false)}>
          <div style={{ position: "absolute", top: -6, left: "50%", transform: "translateX(-50%)", width: 10, height: 10, background: "#1e2128", border: `1px solid ${color}55`, borderRight: "none", borderBottom: "none", rotate: "45deg" }} />
          <div style={{ padding: "10px 14px", borderBottom: `1px solid ${C.border}`, fontSize: 11, color, fontWeight: 600, textTransform: "uppercase", letterSpacing: 1 }}>{label}</div>
          <div style={{ maxHeight: 280, overflowY: "auto" }}>{popover()}</div>
        </div>
      )}
    </div>
  );
}

// ── GAUGE ─────────────────────────────────────────────────────────────────────
function GaugeArc({ value, color }) {
  const r = 70, cx = 90, cy = 90, startAngle = 210, endAngle = 330;
  const range = endAngle - startAngle, filled = (value / 100) * range;
  const toRad = deg => (deg - 90) * (Math.PI / 180);
  const pt = (deg, rad) => ({ x: cx + rad * Math.cos(toRad(deg)), y: cy + rad * Math.sin(toRad(deg)) });
  const arc = (s, e, rad) => { const a = pt(s, rad), b = pt(e, rad); return `M${a.x} ${a.y}A${rad} ${rad} 0 ${e - s > 180 ? 1 : 0} 1 ${b.x} ${b.y}`; };
  const gaugeColor = value > 90 ? C.red : value > 70 ? C.orange : C.green;
  return (
    <svg width={180} height={130} style={{ display: "block", margin: "0 auto" }}>
      <path d={arc(startAngle, startAngle + range, r)} fill="none" stroke={C.border} strokeWidth={14} strokeLinecap="round" />
      {value > 0 && <path d={arc(startAngle, startAngle + filled, r)} fill="none" stroke={gaugeColor} strokeWidth={14} strokeLinecap="round" />}
      <text x={cx} y={cy + 4} textAnchor="middle" fill={gaugeColor} style={{ fontSize: 28, fontWeight: 700 }}>{value}%</text>
      <text x={cx} y={cy + 22} textAnchor="middle" fill={C.muted} style={{ fontSize: 11 }}>utilization</text>
    </svg>
  );
}

function ProgressBar({ pct, color }) {
  return (
    <div style={{ background: C.border, borderRadius: 2, height: 6, width: "100%" }}>
      <div style={{ width: `${pct}%`, height: "100%", background: color, borderRadius: 2 }} />
    </div>
  );
}

function Clock() {
  const [t, setT] = useState(new Date());
  useEffect(() => { const id = setInterval(() => setT(new Date()), 1000); return () => clearInterval(id); }, []);
  return <span style={{ color: C.muted, fontSize: 12 }}>{t.toLocaleTimeString("en-GB")}</span>;
}

// ── CONNECTION BADGE ──────────────────────────────────────────────────────────
function ConnectionBadge({ status }) {
  const cfg = {
    connected:    { color: C.green,  label: "Live",         dot: true  },
    connecting:   { color: C.yellow, label: "Connecting…",  dot: true  },
    disconnected: { color: C.red,    label: "Disconnected", dot: false },
  }[status] ?? { color: C.muted, label: status, dot: false };
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11 }}>
      {cfg.dot && (
        <div style={{
          width: 7, height: 7, borderRadius: "50%", background: cfg.color,
          boxShadow: `0 0 6px ${cfg.color}`,
          animation: status === "connecting" ? "pulse 1s infinite" : "none",
        }} />
      )}
      <span style={{ color: cfg.color }}>{cfg.label}</span>
    </div>
  );
}

// ── WORKER DOT ────────────────────────────────────────────────────────────────
function WorkerDot({ w, onContextMenu }) {
  const col = workerColor(w.status);
  const [hov, setHov] = useState(false);
  return (
    <div onMouseEnter={() => setHov(true)} onMouseLeave={() => setHov(false)}
      onContextMenu={e => { e.preventDefault(); onContextMenu(e, w); }}
      style={{ position: "relative", cursor: "context-menu" }}>
      <div style={{
        width: 42, height: 42, borderRadius: 4,
        background: `${col}22`, border: `2px solid ${col}`,
        display: "flex", flexDirection: "column", alignItems: "center",
        justifyContent: "center", gap: 2,
        transition: "transform .1s,box-shadow .1s",
        transform: hov ? "scale(1.12)" : "scale(1)",
        boxShadow: hov ? `0 0 12px ${col}66` : "none",
      }}>
        <div style={{ width: 8, height: 8, borderRadius: "50%", background: col }} />
        <span style={{ fontSize: 8, color: C.muted }}>{w.id.replace("render", "r")}</span>
      </div>
      {hov && (
        <div style={{
          position: "absolute", bottom: 50, left: "50%", transform: "translateX(-50%)",
          background: "#23262e", border: `1px solid ${C.border}`,
          borderRadius: 4, padding: "8px 10px", zIndex: 99, whiteSpace: "nowrap",
          fontSize: 11, color: C.text, lineHeight: 1.8, pointerEvents: "none",
        }}>
          <div style={{ fontWeight: 700, color: col }}>{w.id}</div>
          {w.ip && <div style={{ color: C.muted, fontSize: 10 }}>{w.ip}</div>}
          <div>Status: <span style={{ color: col }}>{w.status}</span></div>
          <div>Job: {w.job}</div>
          <div>Pool: {w.pool}</div>
          <div>CPU: {w.cpu}%</div>
          <div style={{ color: C.muted, fontSize: 10, marginTop: 4 }}>Right-click → actions</div>
        </div>
      )}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN DASHBOARD
// ═══════════════════════════════════════════════════════════════════════════════
export default function DeadlineDashboard() {
  const [workers, setWorkers]       = useState([]);
  const [jobs, setJobs]             = useState([]);
  const [utilHistory, setUtilHistory] = useState([]);
  const [poolData, setPoolData]     = useState([]);
  const [ctx, setCtx]               = useState(null);
  const [toasts, setToasts]         = useState([]);
  const [confirm, setConfirm]       = useState(null);
  const [connStatus, setConnStatus] = useState("connecting");
  const [lastUpdate, setLastUpdate] = useState(null);
  const [secondsAgo, setSecondsAgo] = useState(0);

  const REFRESH_INTERVAL = 15; // seconds

  // ── toast helper ────────────────────────────────────────────────────────────
  const toast = useCallback((msg, color = C.green, icon = "✓") => {
    const id = Date.now();
    setToasts(t => [...t, { id, msg, color, icon }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 3500);
  }, []);

  // ── data fetch ───────────────────────────────────────────────────────────────
  const fetchData = useCallback(async () => {
    try {
      const [rawWorkers, rawJobs] = await Promise.all([
        dlGet("slaves"),
        dlGet("jobs"),
      ]);
      const w = parseWorkers(rawWorkers);
      const j = parseJobs(rawJobs);
      setWorkers(w);
      setJobs(j);
      setPoolData(buildPoolData(j));

      // rolling utilization history (last 12 points)
      const total  = w.length;
      const active = w.filter(x => x.status === "active").length;
      const util   = total > 0 ? Math.round((active / total) * 100) : 0;
      const now    = new Date().toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
      setUtilHistory(h => [...h.slice(-11), { t: now, util }]);

      setConnStatus("connected");
      setLastUpdate(new Date());
      setSecondsAgo(0);
    } catch (err) {
      setConnStatus("disconnected");
      console.error("Deadline fetch error:", err);
    }
  }, []);

  // initial fetch + auto-refresh
  useEffect(() => {
    fetchData();
    const id = setInterval(fetchData, REFRESH_INTERVAL * 1000);
    return () => clearInterval(id);
  }, [fetchData]);

  // seconds-ago counter
  useEffect(() => {
    const id = setInterval(() => {
      if (lastUpdate) setSecondsAgo(Math.round((Date.now() - lastUpdate) / 1000));
    }, 1000);
    return () => clearInterval(id);
  }, [lastUpdate]);

  // escape closes context menu
  useEffect(() => {
    const h = e => { if (e.key === "Escape") setCtx(null); };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  // ── worker actions ────────────────────────────────────────────────────────
  const workerActions = (e, w) => {
    const items = [];

    if (w.status === "offline") items.push(
      {
        icon: "▶", label: "Start Worker", color: C.green,
        desc: "Enable and bring slave online",
        action: async () => {
          try {
            // Deadline 10: PUT /api/slaves?Name=xxx with body to enable
            await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { IsDisabled: false });
            toast(`${w.id} started`, C.green, "▶");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed to start ${w.id}: ${err.message}`, C.red, "✘");
          }
        },
      },
      {
        icon: "🔁", label: "Restart Service",
        desc: "Restart Deadline Slave service",
        action: () => toast(`Restart must be done manually on ${w.id}`, C.orange, "🔁"),
      },
    );

    if (w.status === "idle") items.push(
      {
        icon: "⏸", label: "Set to Stasis",
        desc: "Worker will not accept new jobs",
        action: async () => {
          try {
            await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { IsInStasis: true });
            toast(`${w.id} set to stasis`, C.yellow, "⏸");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    if (w.status === "active") items.push(
      {
        icon: "⏹", label: "Dequeue Current Job",
        desc: "Return task to queue without cancelling",
        action: async () => {
          try {
            await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { DequeueJob: true });
            toast(`Job returned to queue from ${w.id}`, C.yellow, "⏹");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    items.push("---",
      {
        icon: "📋", label: "View Logs",
        desc: "Open last render log",
        action: () => toast(`Logs must be accessed directly on ${w.id}`, C.blue, "📋"),
      },
      {
        icon: "💻", label: "Remote Desktop",
        desc: "Open RDP / VNC session",
        action: () => toast(`Connect to ${w.id} via RDP/VNC`, C.purple, "💻"),
      },
    );

    if (w.status !== "offline") {
      items.push("---", {
        icon: "🔴", label: "Force Offline", danger: true,
        desc: "Remove worker from farm immediately",
        action: () => setConfirm({
          msg: `Force ${w.id} offline? Current job progress will be lost.`,
          onYes: async () => {
            try {
              await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { IsDisabled: true });
              toast(`${w.id} forced offline`, C.red, "🔴");
              setTimeout(fetchData, 2000);
            } catch (err) {
              toast(`Failed: ${err.message}`, C.red, "✘");
            }
            setConfirm(null);
          },
        }),
      });
    }
    setCtx({ x: e.clientX, y: e.clientY, items });
  };

  // ── job actions ───────────────────────────────────────────────────────────
  const jobActions = (e, j) => {
    e.preventDefault();
    const items = [];

    if (j.status === "failed" || j.status === "rendering") items.push(
      {
        icon: "🔄", label: "Requeue", color: C.green,
        desc: "Move job back to queue",
        action: async () => {
          try {
            await dlPut(`jobs?JobID=${j.id}`, { Status: "Active" });
            toast(`"${j.name}" requeued`, C.green, "🔄");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    if (j.status === "failed") items.push(
      {
        icon: "📤", label: "Resubmit",
        desc: "Submit as new job with same parameters",
        action: async () => {
          try {
            await dlPut(`jobs?JobID=${j.id}&Resubmit=true`, {});
            toast(`"${j.name}" resubmitted`, C.blue, "📤");
            setTimeout(fetchData, 3000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    if (j.status === "rendering" || j.status === "queued") items.push(
      {
        icon: "⏸", label: "Suspend",
        desc: "Pause without losing progress",
        action: async () => {
          try {
            await dlPut(`jobs?JobID=${j.id}`, { Status: "Suspended" });
            toast(`"${j.name}" suspended`, C.yellow, "⏸");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    if (j.status === "suspended") items.push(
      {
        icon: "▶", label: "Resume", color: C.green,
        desc: "Continue from where it paused",
        action: async () => {
          try {
            await dlPut(`jobs?JobID=${j.id}`, { Status: "Active" });
            toast(`"${j.name}" resumed`, C.green, "▶");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
    );

    items.push("---",
      {
        icon: "⬆", label: "Increase Priority", desc: "+10 priority",
        action: async () => {
          const newPri = Math.min(100, j.pri + 10);
          try {
            await dlPut(`jobs?JobID=${j.id}`, { Priority: newPri });
            toast(`Priority → ${newPri}`, C.orange, "⬆");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
      {
        icon: "⬇", label: "Decrease Priority", desc: "-10 priority",
        action: async () => {
          const newPri = Math.max(0, j.pri - 10);
          try {
            await dlPut(`jobs?JobID=${j.id}`, { Priority: newPri });
            toast(`Priority → ${newPri}`, C.muted, "⬇");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
        },
      },
      {
        icon: "📋", label: "View Task Report", desc: "Open job error log",
        action: () => toast(`Opening report for "${j.name}"…`, C.blue, "📋"),
      },
      {
        icon: "📁", label: "Open Output Folder", desc: "Browse rendered frames",
        action: () => toast(`Opening output for "${j.name}"…`, C.purple, "📁"),
      },
    );

    items.push("---", {
      icon: "🗑", label: "Delete Job", danger: true,
      desc: "Permanently remove from farm",
      action: () => setConfirm({
        msg: `Delete "${j.name}"? This cannot be undone.`,
        onYes: async () => {
          try {
            await dlDelete(`jobs?JobID=${j.id}`);
            toast(`"${j.name}" deleted`, C.red, "🗑");
            setTimeout(fetchData, 2000);
          } catch (err) {
            toast(`Failed: ${err.message}`, C.red, "✘");
          }
          setConfirm(null);
        },
      }),
    });

    setCtx({ x: e.clientX, y: e.clientY, items });
  };

  // ── derived stats ─────────────────────────────────────────────────────────
  const active  = workers.filter(w => w.status === "active").length;
  const idle    = workers.filter(w => w.status === "idle").length;
  const offline = workers.filter(w => w.status === "offline").length;
  const failed  = jobs.filter(j => j.status === "failed").length;
  const queued  = jobs.filter(j => j.status === "queued").length;
  const util    = workers.length > 0 ? Math.round((active / workers.length) * 100) : 0;

  // ── render ────────────────────────────────────────────────────────────────
  return (
    <div style={{ background: C.bg, minHeight: "100vh", color: C.text, fontFamily: "'Inter','Segoe UI',sans-serif", fontSize: 13, padding: "0 0 24px" }}
      onClick={() => setCtx(null)}>

      {/* TOP BAR */}
      <div style={{ background: "#0d0f13", borderBottom: `1px solid ${C.border}`, padding: "10px 20px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <div style={{ width: 28, height: 28, borderRadius: 6, background: "linear-gradient(135deg,#f46800,#fa9f3a)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 900, color: "#fff" }}>D</div>
          <span style={{ fontWeight: 700, fontSize: 15 }}>Deadline Dashboard</span>
          <span style={{ background: "#2a2d3a", borderRadius: 10, padding: "2px 10px", fontSize: 11, color: C.muted }}>Production</span>
        </div>
        <div style={{ display: "flex", gap: 20, alignItems: "center" }}>
          <ConnectionBadge status={connStatus} />
          {lastUpdate && <span style={{ fontSize: 11, color: C.muted }}>Updated <span style={{ color: C.text }}>{secondsAgo}s ago</span></span>}
          <Clock />
          <button onClick={fetchData} style={{ background: "transparent", border: `1px solid ${C.border}`, color: C.muted, borderRadius: 4, padding: "4px 10px", cursor: "pointer", fontSize: 11 }}>↻ Refresh</button>
        </div>
      </div>

      <div style={{ padding: "16px 20px", display: "flex", flexDirection: "column", gap: 14 }}>

        {/* hint bar */}
        <div style={{ background: "#1a1d24", border: `1px dashed ${C.border}`, borderRadius: 4, padding: "8px 14px", fontSize: 11, color: C.muted, display: "flex", gap: 8 }}>
          <span style={{ color: C.orange }}>💡</span>
          <span>Hover stat cards for quick actions · Right-click any <strong style={{ color: C.text }}>worker</strong> or <strong style={{ color: C.text }}>job row</strong> for the full action menu · Auto-refresh every {REFRESH_INTERVAL}s</span>
        </div>

        {/* ROW 1 — stat cards */}
        <div style={{ display: "flex", gap: 12 }}>

          <StatCard label="Active Workers" value={active} color={C.green} sub={`of ${workers.length} total`}
            popover={() => (
              <div>
                {workers.filter(w => w.status === "active").map(w => (
                  <div key={w.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 14px", borderBottom: `1px solid ${C.border}22` }}>
                    <div style={{ width: 8, height: 8, borderRadius: "50%", background: C.green, flexShrink: 0 }} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ color: C.text, fontSize: 12, fontWeight: 600 }}>{w.id}</div>
                      <div style={{ color: C.muted, fontSize: 11, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{w.job}</div>
                    </div>
                    <div style={{ textAlign: "right", flexShrink: 0 }}>
                      <div style={{ fontSize: 11, color: w.cpu > 90 ? C.orange : C.muted }}>{w.cpu}% CPU</div>
                      <div style={{ fontSize: 10, color: C.muted }}>{w.pool}</div>
                    </div>
                  </div>
                ))}
                {active === 0 && <div style={{ padding: "16px 14px", color: C.muted, fontSize: 12, textAlign: "center" }}>No active workers</div>}
              </div>
            )}
          />

          <StatCard label="Idle Workers" value={idle} color={C.yellow} sub="no job assigned"
            popover={() => (
              <div>
                {workers.filter(w => w.status === "idle").map(w => (
                  <div key={w.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 14px", borderBottom: `1px solid ${C.border}22` }}>
                    <div style={{ width: 8, height: 8, borderRadius: "50%", background: C.yellow, flexShrink: 0 }} />
                    <div style={{ flex: 1 }}>
                      <div style={{ color: C.text, fontSize: 12, fontWeight: 600 }}>{w.id}</div>
                      <div style={{ color: C.muted, fontSize: 11 }}>Waiting for job</div>
                    </div>
                    <button onClick={async () => {
                      try {
                        await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { IsInStasis: true });
                        toast(`${w.id} set to stasis`, C.yellow, "⏸");
                        setTimeout(fetchData, 2000);
                      } catch (err) { toast(`Failed: ${err.message}`, C.red, "✘"); }
                    }} style={{ background: "transparent", border: `1px solid ${C.yellow}`, color: C.yellow, borderRadius: 4, padding: "3px 10px", cursor: "pointer", fontSize: 11 }}>Stasis</button>
                  </div>
                ))}
                {idle === 0 && <div style={{ padding: "16px 14px", color: C.muted, fontSize: 12, textAlign: "center" }}>No idle workers</div>}
              </div>
            )}
          />

          <StatCard label="Offline / Error" value={offline} color={C.red} sub="needs attention"
            popover={() => (
              <div>
                {workers.filter(w => w.status === "offline").map(w => (
                  <div key={w.id} style={{ padding: "9px 14px", borderBottom: `1px solid ${C.border}22` }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
                      <div style={{ width: 8, height: 8, borderRadius: "50%", background: C.red, flexShrink: 0 }} />
                      <div style={{ flex: 1 }}>
                        <div style={{ color: C.text, fontSize: 12, fontWeight: 600 }}>{w.id}</div>
                        <div style={{ color: C.red, fontSize: 11 }}>● offline</div>
                      </div>
                    </div>
                    <div style={{ display: "flex", gap: 6 }}>
                      <button onClick={async () => {
                        try {
                          await dlPut(`slaves?Name=${encodeURIComponent(w.id)}`, { IsDisabled: false });
                          toast(`${w.id} started`, C.green, "▶");
                          setTimeout(fetchData, 2000);
                        } catch (err) { toast(`Failed: ${err.message}`, C.red, "✘"); }
                      }} style={{ flex: 1, background: `${C.green}22`, border: `1px solid ${C.green}`, color: C.green, borderRadius: 4, padding: "5px 0", cursor: "pointer", fontSize: 11, fontWeight: 600 }}>▶ Start Worker</button>
                      <button onClick={() => toast(`Restart ${w.id} manually`, C.orange, "🔁")}
                        style={{ flex: 1, background: `${C.orange}11`, border: `1px solid ${C.orange}44`, color: C.orange, borderRadius: 4, padding: "5px 0", cursor: "pointer", fontSize: 11 }}>🔁 Restart</button>
                    </div>
                  </div>
                ))}
                {offline === 0 && <div style={{ padding: "16px 14px", color: C.muted, fontSize: 12, textAlign: "center" }}>All workers online ✓</div>}
              </div>
            )}
          />

          <StatCard label="Jobs in Queue" value={queued} color={C.blue} sub="waiting for worker"
            popover={() => (
              <div>
                {jobs.filter(j => j.status === "queued").map((j, i) => (
                  <div key={i} style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 14px", borderBottom: `1px solid ${C.border}22` }}>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ color: C.text, fontSize: 12, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{j.name}</div>
                      <div style={{ color: C.muted, fontSize: 11 }}>{j.pool} · Pri {j.pri}</div>
                    </div>
                    <button onClick={async () => {
                      const newPri = Math.min(100, j.pri + 10);
                      try {
                        await dlPut(`jobs?JobID=${j.id}`, { Priority: newPri });
                        toast(`Priority → ${newPri}`, C.orange, "⬆");
                        setTimeout(fetchData, 2000);
                      } catch (err) { toast(`Failed: ${err.message}`, C.red, "✘"); }
                    }} style={{ background: "transparent", border: `1px solid ${C.orange}66`, color: C.orange, borderRadius: 4, padding: "3px 8px", cursor: "pointer", fontSize: 11 }}>⬆ Pri</button>
                  </div>
                ))}
                {queued === 0 && <div style={{ padding: "16px 14px", color: C.muted, fontSize: 12, textAlign: "center" }}>Queue is empty</div>}
              </div>
            )}
          />

          <StatCard label="Failed Jobs" value={failed} color={C.red} sub="today"
            popover={() => (
              <div>
                {jobs.filter(j => j.status === "failed").map((j, i) => (
                  <div key={i} style={{ padding: "9px 14px", borderBottom: `1px solid ${C.border}22` }}>
                    <div style={{ color: C.text, fontSize: 12, marginBottom: 4, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{j.name}</div>
                    <div style={{ color: C.muted, fontSize: 11, marginBottom: 8 }}>{j.pool} · {j.tasks} tasks</div>
                    <div style={{ display: "flex", gap: 6 }}>
                      <button onClick={async () => {
                        try {
                          await dlPut(`jobs?JobID=${j.id}`, { Status: "Active" });
                          toast(`"${j.name}" requeued`, C.green, "🔄");
                          setTimeout(fetchData, 2000);
                        } catch (err) { toast(`Failed: ${err.message}`, C.red, "✘"); }
                      }} style={{ flex: 1, background: `${C.green}22`, border: `1px solid ${C.green}`, color: C.green, borderRadius: 4, padding: "5px 0", cursor: "pointer", fontSize: 11, fontWeight: 600 }}>🔄 Requeue</button>
                      <button onClick={async () => {
                        try {
                          await dlPut(`jobs?JobID=${j.id}&Resubmit=true`, {});
                          toast(`"${j.name}" resubmitted`, C.blue, "📤");
                          setTimeout(fetchData, 3000);
                        } catch (err) { toast(`Failed: ${err.message}`, C.red, "✘"); }
                      }} style={{ flex: 1, background: `${C.blue}11`, border: `1px solid ${C.blue}44`, color: C.blue, borderRadius: 4, padding: "5px 0", cursor: "pointer", fontSize: 11 }}>📤 Resubmit</button>
                    </div>
                  </div>
                ))}
                {failed === 0 && <div style={{ padding: "16px 14px", color: C.muted, fontSize: 12, textAlign: "center" }}>No failures today ✓</div>}
              </div>
            )}
          />

          <StatCard label="Total Jobs" value={jobs.length} color={C.purple} sub="active + queued + failed" />

        </div>

        {/* ROW 2 — gauge + utilization chart + pool bars */}
        <div style={{ display: "flex", gap: 12 }}>
          <Panel title="Farm Utilization" style={{ width: 200, flexShrink: 0 }}>
            <GaugeArc value={util} color={util > 90 ? C.red : util > 70 ? C.orange : C.green} />
            <div style={{ display: "flex", justifyContent: "space-around", marginTop: 4 }}>
              {[["Active", active, C.green], ["Idle", idle, C.yellow], ["Off", offline, C.red]].map(([l, v, c]) => (
                <div key={l} style={{ textAlign: "center" }}>
                  <div style={{ fontSize: 16, fontWeight: 700, color: c }}>{v}</div>
                  <div style={{ fontSize: 10, color: C.muted }}>{l}</div>
                </div>
              ))}
            </div>
          </Panel>

          <Panel title="Farm Utilization % (live)" style={{ flex: 1 }}>
            <ResponsiveContainer width="100%" height={160}>
              <AreaChart data={utilHistory}>
                <defs>
                  <linearGradient id="ug" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor={C.green} stopOpacity={0.35} />
                    <stop offset="95%" stopColor={C.green} stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid stroke={C.border} vertical={false} />
                <XAxis dataKey="t" tick={{ fill: C.muted, fontSize: 10 }} axisLine={false} tickLine={false} />
                <YAxis domain={[0, 100]} tick={{ fill: C.muted, fontSize: 10 }} axisLine={false} tickLine={false} width={30} tickFormatter={v => `${v}%`} />
                <Tooltip contentStyle={{ background: "#23262e", border: `1px solid ${C.border}`, borderRadius: 4 }} labelStyle={{ color: C.muted }} itemStyle={{ color: C.green }} formatter={v => [`${v}%`, "Utilization"]} />
                <Area type="monotone" dataKey="util" stroke={C.green} strokeWidth={2} fill="url(#ug)" dot={false} />
              </AreaChart>
            </ResponsiveContainer>
          </Panel>

          <Panel title="Jobs by Pool / Renderer" style={{ width: 220, flexShrink: 0 }}>
            {poolData.length === 0
              ? <div style={{ color: C.muted, fontSize: 12, textAlign: "center", paddingTop: 40 }}>No job data</div>
              : (
                <ResponsiveContainer width="100%" height={160}>
                  <BarChart data={poolData} layout="vertical" barSize={14}>
                    <CartesianGrid stroke={C.border} horizontal={false} />
                    <XAxis type="number" tick={{ fill: C.muted, fontSize: 10 }} axisLine={false} tickLine={false} />
                    <YAxis dataKey="pool" type="category" tick={{ fill: C.text, fontSize: 10 }} axisLine={false} tickLine={false} width={52} />
                    <Tooltip contentStyle={{ background: "#23262e", border: `1px solid ${C.border}`, borderRadius: 4 }} labelStyle={{ color: C.muted }} itemStyle={{ color: C.orange }} />
                    <Bar dataKey="jobs" fill={C.orange} radius={[0, 3, 3, 0]} name="Jobs" />
                  </BarChart>
                </ResponsiveContainer>
              )}
          </Panel>
        </div>

        {/* ROW 3 — workers grid + job table */}
        <div style={{ display: "flex", gap: 12 }}>

          <Panel title="Workers — right-click for actions" style={{ width: 320, flexShrink: 0 }}>
            {workers.length === 0
              ? <div style={{ color: C.muted, fontSize: 12, textAlign: "center", padding: "30px 0" }}>
                  {connStatus === "connecting" ? "Connecting to Deadline…" : "No workers found"}
                </div>
              : (
                <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
                  {workers.map(w => <WorkerDot key={w.id} w={w} onContextMenu={workerActions} />)}
                </div>
              )}
            <div style={{ display: "flex", gap: 16, marginTop: 14, fontSize: 11 }}>
              {[["● Active", C.green], ["● Idle", C.yellow], ["● Offline", C.red], ["● Stalled", C.orange], ["● Disabled", C.muted]].map(([l, c]) => (
                <span key={l} style={{ color: c }}>{l}</span>
              ))}
            </div>
          </Panel>

          <Panel title="Job Queue — right-click for actions" style={{ flex: 1 }}>
            {jobs.length === 0
              ? <div style={{ color: C.muted, textAlign: "center", padding: "30px 0" }}>
                  {connStatus === "connecting" ? "Connecting to Deadline…" : connStatus === "disconnected" ? "⚠ Cannot connect to Deadline Web Service" : "No jobs in queue"}
                </div>
              : (
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
                  <thead>
                    <tr>
                      {["Name", "Pool", "Pri", "Tasks", "Progress", "Status"].map(h => (
                        <th key={h} style={{ textAlign: "left", color: C.muted, fontWeight: 500, padding: "0 8px 8px", borderBottom: `1px solid ${C.border}`, fontSize: 11, textTransform: "uppercase", letterSpacing: .8 }}>{h}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {jobs.map((j, i) => (
                      <tr key={i} onContextMenu={e => jobActions(e, j)}
                        style={{ borderBottom: `1px solid ${C.border}22`, cursor: "context-menu", transition: "background .1s" }}
                        onMouseEnter={e => e.currentTarget.style.background = "#ffffff08"}
                        onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                        <td style={{ padding: "7px 8px", color: C.text, maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }} title={j.name}>{j.name}</td>
                        <td style={{ padding: "7px 8px", color: C.muted }}>{j.pool}</td>
                        <td style={{ padding: "7px 8px", color: j.pri >= 80 ? C.orange : C.muted, fontWeight: j.pri >= 80 ? 700 : 400 }}>{j.pri}</td>
                        <td style={{ padding: "7px 8px", color: C.muted, fontFamily: "monospace" }}>{j.tasks}</td>
                        <td style={{ padding: "7px 8px", width: 100 }}>
                          <ProgressBar pct={j.pct} color={jobColor(j.status)} />
                          <span style={{ fontSize: 10, color: C.muted }}>{j.pct}%</span>
                        </td>
                        <td style={{ padding: "7px 8px" }}>
                          <span style={{ background: `${jobColor(j.status)}22`, color: jobColor(j.status), borderRadius: 10, padding: "2px 8px", fontSize: 11 }}>{j.status}</span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
          </Panel>
        </div>

        <div style={{ textAlign: "center", color: C.muted, fontSize: 11, marginTop: 4 }}>
          Deadline Dashboard · Auto-refresh every {REFRESH_INTERVAL}s
        </div>
      </div>

      {ctx && <ContextMenu x={ctx.x} y={ctx.y} items={ctx.items} onClose={() => setCtx(null)} />}
      {confirm && <ConfirmDialog msg={confirm.msg} onYes={confirm.onYes} onNo={() => setConfirm(null)} />}
      <Toast toasts={toasts} />
      <style>{`
        @keyframes fadeIn { from { opacity:0; transform:translateY(8px) } to { opacity:1; transform:none } }
        @keyframes pulse  { 0%,100% { opacity:1 } 50% { opacity:0.4 } }
      `}</style>
    </div>
  );
}
