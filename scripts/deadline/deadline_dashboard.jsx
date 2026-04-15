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

// ── sample data ───────────────────────────────────────────────────────────────
const throughputData = [
  {t:"08:00",frames:120},{t:"09:00",frames:310},{t:"10:00",frames:540},
  {t:"11:00",frames:490},{t:"12:00",frames:280},{t:"13:00",frames:430},
  {t:"14:00",frames:610},{t:"15:00",frames:720},{t:"16:00",frames:680},
  {t:"17:00",frames:590},{t:"18:00",frames:410},{t:"now",frames:390},
];
const utilizationData = [
  {t:"08:00",util:22},{t:"09:00",util:68},{t:"10:00",util:87},
  {t:"11:00",util:91},{t:"12:00",util:55},{t:"13:00",util:73},
  {t:"14:00",util:94},{t:"15:00",util:97},{t:"16:00",util:89},
  {t:"17:00",util:82},{t:"18:00",util:64},{t:"now",util:71},
];
const poolData = [
  {pool:"Maya",jobs:14},{pool:"Houdini",jobs:9},{pool:"Nuke",jobs:6},
  {pool:"Arnold",jobs:11},{pool:"V-Ray",jobs:4},
];

const INIT_WORKERS = [
  {id:"render01",job:"EP04_shot_012",pool:"Arnold",  cpu:98,status:"active"},
  {id:"render02",job:"EP04_shot_013",pool:"Arnold",  cpu:96,status:"active"},
  {id:"render03",job:"hero_plate_v3", pool:"Nuke",   cpu:72,status:"active"},
  {id:"render04",job:"crowd_sim_01",  pool:"Houdini",cpu:99,status:"active"},
  {id:"render05",job:"—",             pool:"—",      cpu:0, status:"idle"},
  {id:"render06",job:"char_rig_test", pool:"Maya",   cpu:45,status:"active"},
  {id:"render07",job:"—",             pool:"—",      cpu:0, status:"offline"},
  {id:"render08",job:"lighting_v7",   pool:"Arnold", cpu:88,status:"active"},
  {id:"render09",job:"fx_dust_v2",    pool:"Houdini",cpu:91,status:"active"},
  {id:"render10",job:"comp_final",    pool:"Nuke",   cpu:61,status:"active"},
  {id:"render11",job:"—",             pool:"—",      cpu:0, status:"idle"},
  {id:"render12",job:"EP04_shot_021", pool:"Arnold", cpu:97,status:"active"},
];

const INIT_JOBS = [
  {name:"EP04_shot_012_beauty", pool:"Arnold",  pri:90,tasks:"128/256",status:"rendering",pct:50},
  {name:"hero_plate_comp_v3",   pool:"Nuke",    pri:85,tasks:"44/60",  status:"rendering",pct:73},
  {name:"crowd_sim_01_cache",   pool:"Houdini", pri:70,tasks:"12/80",  status:"rendering",pct:15},
  {name:"char_rig_turntable",   pool:"Maya",    pri:50,tasks:"0/30",   status:"queued",   pct:0},
  {name:"fx_dust_v2_sim",       pool:"Houdini", pri:75,tasks:"33/100", status:"rendering",pct:33},
  {name:"EP04_shot_021_beauty", pool:"Arnold",  pri:90,tasks:"0/200",  status:"queued",   pct:0},
  {name:"lighting_LookDev_v7",  pool:"Arnold",  pri:60,tasks:"88/120", status:"rendering",pct:73},
  {name:"OLD_test_scene_r001",  pool:"Maya",    pri:10,tasks:"3/50",   status:"failed",   pct:6},
];

// ── colour helpers ────────────────────────────────────────────────────────────
const workerColor = s => ({active:C.green,idle:C.yellow,offline:C.red}[s]??C.muted);
const jobColor    = s => ({rendering:C.blue,queued:C.yellow,failed:C.red,suspended:"#888"}[s]??C.muted);

// ── TOAST ─────────────────────────────────────────────────────────────────────
function Toast({toasts}){
  return(
    <div style={{position:"fixed",bottom:24,right:24,display:"flex",flexDirection:"column",gap:8,zIndex:9999}}>
      {toasts.map(t=>(
        <div key={t.id} style={{
          background:"#23262e",border:`1px solid ${t.color}44`,
          borderLeft:`3px solid ${t.color}`,borderRadius:4,
          padding:"10px 16px",color:C.text,fontSize:12,
          boxShadow:"0 4px 20px #0008",minWidth:260,
          animation:"fadeIn .2s ease",
        }}>
          <span style={{color:t.color,marginRight:8}}>{t.icon}</span>{t.msg}
        </div>
      ))}
    </div>
  );
}

// ── CONTEXT MENU ──────────────────────────────────────────────────────────────
function ContextMenu({x,y,items,onClose}){
  const ref=useRef();
  useEffect(()=>{
    const h=e=>{if(ref.current&&!ref.current.contains(e.target))onClose();};
    document.addEventListener("mousedown",h);
    return()=>document.removeEventListener("mousedown",h);
  },[onClose]);
  return(
    <div ref={ref} style={{
      position:"fixed",left:x,top:y,zIndex:9000,
      background:"#1e2128",border:`1px solid ${C.border}`,
      borderRadius:6,boxShadow:"0 8px 32px #000a",
      minWidth:210,overflow:"hidden",
    }}>
      {items.map((it,i)=>
        it==="---"
          ? <div key={i} style={{height:1,background:C.border,margin:"2px 0"}}/>
          : (
            <div key={i} onClick={()=>{it.action();onClose();}} style={{
              padding:"9px 14px",cursor:"pointer",
              color:it.danger?C.red:it.color??C.text,
              fontSize:12,display:"flex",alignItems:"center",gap:10,
              transition:"background .1s",
            }}
            onMouseEnter={e=>e.currentTarget.style.background="#2a2d3a"}
            onMouseLeave={e=>e.currentTarget.style.background="transparent"}>
              <span style={{fontSize:14}}>{it.icon}</span>
              <div>
                <div>{it.label}</div>
                {it.desc&&<div style={{fontSize:10,color:C.muted,marginTop:1}}>{it.desc}</div>}
              </div>
            </div>
          )
      )}
    </div>
  );
}

// ── CONFIRM DIALOG ────────────────────────────────────────────────────────────
function ConfirmDialog({msg,onYes,onNo}){
  return(
    <div style={{position:"fixed",inset:0,background:"#0009",zIndex:9500,
      display:"flex",alignItems:"center",justifyContent:"center"}}>
      <div style={{background:"#1e2128",border:`1px solid ${C.border}`,
        borderRadius:8,padding:"24px 28px",maxWidth:360,width:"90%",
        boxShadow:"0 16px 48px #000c"}}>
        <div style={{fontSize:14,color:C.text,marginBottom:20,lineHeight:1.6}}>{msg}</div>
        <div style={{display:"flex",gap:10,justifyContent:"flex-end"}}>
          <button onClick={onNo} style={{
            background:"transparent",border:`1px solid ${C.border}`,
            color:C.muted,borderRadius:4,padding:"6px 18px",cursor:"pointer",fontSize:12,
          }}>Cancel</button>
          <button onClick={onYes} style={{
            background:C.red,border:"none",color:"#fff",
            borderRadius:4,padding:"6px 18px",cursor:"pointer",fontSize:12,fontWeight:700,
          }}>Confirm</button>
        </div>
      </div>
    </div>
  );
}

// ── PANEL ─────────────────────────────────────────────────────────────────────
function Panel({title,children,style={}}){
  return(
    <div style={{background:C.panel,border:`1px solid ${C.border}`,borderRadius:4,padding:"12px 14px",...style}}>
      {title&&<div style={{fontSize:11,color:C.muted,marginBottom:10,textTransform:"uppercase",letterSpacing:1}}>{title}</div>}
      {children}
    </div>
  );
}

// ── STAT CARD with hover popover ──────────────────────────────────────────────
function StatCard({label,value,unit="",color=C.text,sub,popover}){
  const [open,setOpen]=useState(false);
  const ref=useRef();
  useEffect(()=>{
    if(!open)return;
    const h=e=>{if(ref.current&&!ref.current.contains(e.target))setOpen(false);};
    document.addEventListener("mousedown",h);
    return()=>document.removeEventListener("mousedown",h);
  },[open]);

  return(
    <div ref={ref} style={{flex:1,position:"relative"}}
      onMouseEnter={()=>popover&&setOpen(true)}
      onMouseLeave={()=>setOpen(false)}>
      <div style={{
        background:C.panel,border:`1px solid ${open&&popover?color:C.border}`,
        borderRadius:4,padding:"12px 14px",textAlign:"center",
        cursor:popover?"pointer":"default",
        transition:"border-color .15s,box-shadow .15s",
        boxShadow:open&&popover?`0 0 0 1px ${color}44`:"none",
      }}>
        <div style={{fontSize:11,color:C.muted,marginBottom:6,textTransform:"uppercase",letterSpacing:1}}>{label}</div>
        <div style={{fontSize:36,fontWeight:700,color,lineHeight:1}}>
          {value}<span style={{fontSize:16,color:C.muted,marginLeft:4}}>{unit}</span>
        </div>
        {sub&&<div style={{fontSize:11,color:C.muted,marginTop:6}}>{sub}</div>}
        {popover&&<div style={{fontSize:10,color:`${color}88`,marginTop:4}}>▼ hover for details</div>}
      </div>

      {open&&popover&&(
        <div style={{
          position:"absolute",top:"calc(100% + 6px)",left:"50%",transform:"translateX(-50%)",
          background:"#1e2128",border:`1px solid ${color}55`,borderRadius:6,
          boxShadow:`0 12px 40px #000c,0 0 0 1px ${color}22`,
          zIndex:8000,minWidth:280,maxWidth:360,overflow:"hidden",
          animation:"fadeIn .15s ease",
        }}
        onMouseEnter={()=>setOpen(true)}
        onMouseLeave={()=>setOpen(false)}>
          <div style={{position:"absolute",top:-6,left:"50%",transform:"translateX(-50%)",
            width:10,height:10,background:"#1e2128",border:`1px solid ${color}55`,
            borderRight:"none",borderBottom:"none",rotate:"45deg"}}/>
          <div style={{padding:"10px 14px",borderBottom:`1px solid ${C.border}`,
            fontSize:11,color,fontWeight:600,textTransform:"uppercase",letterSpacing:1}}>
            {label}
          </div>
          <div style={{maxHeight:280,overflowY:"auto"}}>{popover()}</div>
        </div>
      )}
    </div>
  );
}

// ── GAUGE ─────────────────────────────────────────────────────────────────────
function GaugeArc({value,color}){
  const r=70,cx=90,cy=90,startAngle=210,endAngle=330;
  const range=endAngle-startAngle,filled=(value/100)*range;
  const toRad=deg=>(deg-90)*(Math.PI/180);
  const pt=(deg,rad)=>({x:cx+rad*Math.cos(toRad(deg)),y:cy+rad*Math.sin(toRad(deg))});
  const arc=(s,e,rad)=>{const a=pt(s,rad),b=pt(e,rad);return`M${a.x} ${a.y}A${rad} ${rad} 0 ${e-s>180?1:0} 1 ${b.x} ${b.y}`;};
  return(
    <svg width={180} height={130} style={{display:"block",margin:"0 auto"}}>
      <path d={arc(startAngle,startAngle+range,r)} fill="none" stroke={C.border} strokeWidth={14} strokeLinecap="round"/>
      {value>0&&<path d={arc(startAngle,startAngle+filled,r)} fill="none" stroke={color} strokeWidth={14} strokeLinecap="round"/>}
      <text x={cx} y={cy+4} textAnchor="middle" fill={color} style={{fontSize:28,fontWeight:700}}>{value}%</text>
      <text x={cx} y={cy+22} textAnchor="middle" fill={C.muted} style={{fontSize:11}}>utilization</text>
    </svg>
  );
}

function ProgressBar({pct,color}){
  return(
    <div style={{background:C.border,borderRadius:2,height:6,width:"100%"}}>
      <div style={{width:`${pct}%`,height:"100%",background:color,borderRadius:2}}/>
    </div>
  );
}

function Clock(){
  const [t,setT]=useState(new Date());
  useEffect(()=>{const id=setInterval(()=>setT(new Date()),1000);return()=>clearInterval(id);},[]);
  return <span style={{color:C.muted,fontSize:12}}>{t.toLocaleTimeString("en-GB")}</span>;
}

// ── WORKER DOT ────────────────────────────────────────────────────────────────
function WorkerDot({w,onContextMenu}){
  const col=workerColor(w.status);
  const [hov,setHov]=useState(false);
  return(
    <div onMouseEnter={()=>setHov(true)} onMouseLeave={()=>setHov(false)}
      onContextMenu={e=>{e.preventDefault();onContextMenu(e,w);}}
      style={{position:"relative",cursor:"context-menu"}}>
      <div style={{
        width:42,height:42,borderRadius:4,
        background:`${col}22`,border:`2px solid ${col}`,
        display:"flex",flexDirection:"column",alignItems:"center",
        justifyContent:"center",gap:2,
        transition:"transform .1s,box-shadow .1s",
        transform:hov?"scale(1.12)":"scale(1)",
        boxShadow:hov?`0 0 12px ${col}66`:"none",
      }}>
        <div style={{width:8,height:8,borderRadius:"50%",background:col}}/>
        <span style={{fontSize:8,color:C.muted}}>{w.id.replace("render","r")}</span>
      </div>
      {hov&&(
        <div style={{
          position:"absolute",bottom:50,left:"50%",transform:"translateX(-50%)",
          background:"#23262e",border:`1px solid ${C.border}`,
          borderRadius:4,padding:"8px 10px",zIndex:99,whiteSpace:"nowrap",
          fontSize:11,color:C.text,lineHeight:1.8,pointerEvents:"none",
        }}>
          <div style={{fontWeight:700,color:col}}>{w.id}</div>
          <div>Status: <span style={{color:col}}>{w.status}</span></div>
          <div>Job: {w.job}</div>
          <div>Pool: {w.pool}</div>
          <div>CPU: {w.cpu}%</div>
          <div style={{color:C.muted,fontSize:10,marginTop:4}}>Right-click → actions</div>
        </div>
      )}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN DASHBOARD
// ═══════════════════════════════════════════════════════════════════════════════
export default function DeadlineDashboard(){
  const [workers,setWorkers]=useState(INIT_WORKERS);
  const [jobs,setJobs]      =useState(INIT_JOBS);
  const [ctx,setCtx]        =useState(null);
  const [toasts,setToasts]  =useState([]);
  const [confirm,setConfirm]=useState(null);

  const toast=useCallback((msg,color=C.green,icon="✓")=>{
    const id=Date.now();
    setToasts(t=>[...t,{id,msg,color,icon}]);
    setTimeout(()=>setToasts(t=>t.filter(x=>x.id!==id)),3500);
  },[]);

  useEffect(()=>{
    const h=e=>{if(e.key==="Escape")setCtx(null);};
    window.addEventListener("keydown",h);
    return()=>window.removeEventListener("keydown",h);
  },[]);

  // ── worker right-click actions ────────────────────────────────────────────
  const workerActions=(e,w)=>{
    const items=[];
    if(w.status==="offline") items.push(
      {icon:"▶",label:"Start Worker",color:C.green,
        desc:"Send pulse → bring slave online",
        action:()=>{
          setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"idle",cpu:0,job:"—",pool:"—"}:x));
          toast(`${w.id} started successfully`,C.green,"▶");
        }},
      {icon:"🔁",label:"Restart Service",
        desc:"Restart Deadline Slave service",
        action:()=>toast(`Restarting service on ${w.id}…`,C.orange,"🔁")},
    );
    if(w.status==="idle") items.push(
      {icon:"⏸",label:"Set to Stasis",
        desc:"Worker will not accept new jobs",
        action:()=>{
          setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"offline"}:x));
          toast(`${w.id} set to stasis`,C.yellow,"⏸");
        }},
    );
    if(w.status==="active") items.push(
      {icon:"⏹",label:"Dequeue Current Job",
        desc:"Stop task without cancelling it",
        action:()=>{
          setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"idle",cpu:0,job:"—",pool:"—"}:x));
          toast(`Job returned to queue from ${w.id}`,C.yellow,"⏹");
        }},
    );
    items.push("---");
    items.push(
      {icon:"📋",label:"View Logs",desc:"Open last render log",
        action:()=>toast(`Opening logs for ${w.id}…`,C.blue,"📋")},
      {icon:"💻",label:"Remote Desktop",desc:"Open RDP / VNC session",
        action:()=>toast(`Connecting to ${w.id}…`,C.purple,"💻")},
    );
    if(w.status!=="offline"){
      items.push("---");
      items.push({icon:"🔴",label:"Force Offline",danger:true,
        desc:"Remove worker from farm immediately",
        action:()=>{
          setConfirm({
            msg:`Force ${w.id} offline? The current job progress will be lost.`,
            onYes:()=>{
              setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"offline",cpu:0,job:"—",pool:"—"}:x));
              toast(`${w.id} forced offline`,C.red,"🔴");
              setConfirm(null);
            }
          });
        }
      });
    }
    setCtx({x:e.clientX,y:e.clientY,items});
  };

  // ── job right-click actions ───────────────────────────────────────────────
  const jobActions=(e,j)=>{
    e.preventDefault();
    const items=[];
    if(j.status==="failed"||j.status==="rendering") items.push(
      {icon:"🔄",label:"Requeue",color:C.green,
        desc:"Move job to front of queue",
        action:()=>{
          setJobs(js=>js.map(x=>x.name===j.name?{...x,status:"queued",pct:0,tasks:x.tasks.replace(/^\d+/,"0")}:x));
          toast(`"${j.name}" requeued`,C.green,"🔄");
        }},
    );
    if(j.status==="failed") items.push(
      {icon:"📤",label:"Resubmit",
        desc:"Submit as new job with same parameters",
        action:()=>toast(`Resubmitting "${j.name}"…`,C.blue,"📤")},
    );
    if(j.status==="rendering"||j.status==="queued") items.push(
      {icon:"⏸",label:"Suspend",
        desc:"Pause without losing progress",
        action:()=>{
          setJobs(js=>js.map(x=>x.name===j.name?{...x,status:"suspended"}:x));
          toast(`"${j.name}" suspended`,C.yellow,"⏸");
        }},
    );
    if(j.status==="suspended") items.push(
      {icon:"▶",label:"Resume",color:C.green,
        desc:"Continue from where it paused",
        action:()=>{
          setJobs(js=>js.map(x=>x.name===j.name?{...x,status:"queued"}:x));
          toast(`"${j.name}" resumed`,C.green,"▶");
        }},
    );
    items.push("---");
    items.push(
      {icon:"⬆",label:"Increase Priority",desc:"+10 priority",
        action:()=>{
          setJobs(js=>js.map(x=>x.name===j.name?{...x,pri:Math.min(100,x.pri+10)}:x));
          toast(`Priority +10 → ${Math.min(100,j.pri+10)}`,C.orange,"⬆");
        }},
      {icon:"⬇",label:"Decrease Priority",desc:"-10 priority",
        action:()=>{
          setJobs(js=>js.map(x=>x.name===j.name?{...x,pri:Math.max(0,x.pri-10)}:x));
          toast(`Priority -10 → ${Math.max(0,j.pri-10)}`,C.muted,"⬇");
        }},
      {icon:"📋",label:"View Task Report",desc:"Open job error log",
        action:()=>toast(`Opening task report for "${j.name}"…`,C.blue,"📋")},
      {icon:"📁",label:"Open Output Folder",desc:"Browse rendered frames",
        action:()=>toast(`Opening output for "${j.name}"…`,C.purple,"📁")},
    );
    items.push("---");
    items.push(
      {icon:"🗑",label:"Delete Job",danger:true,desc:"Permanently remove from farm",
        action:()=>{
          setConfirm({
            msg:`Delete "${j.name}"? This action cannot be undone.`,
            onYes:()=>{
              setJobs(js=>js.filter(x=>x.name!==j.name));
              toast(`"${j.name}" deleted`,C.red,"🗑");
              setConfirm(null);
            }
          });
        }},
    );
    setCtx({x:e.clientX,y:e.clientY,items});
  };

  const active  =workers.filter(w=>w.status==="active").length;
  const idle    =workers.filter(w=>w.status==="idle").length;
  const offline =workers.filter(w=>w.status==="offline").length;
  const failed  =jobs.filter(j=>j.status==="failed").length;
  const queued  =jobs.filter(j=>j.status==="queued").length;

  return(
    <div style={{background:C.bg,minHeight:"100vh",color:C.text,
      fontFamily:"'Inter','Segoe UI',sans-serif",fontSize:13,padding:"0 0 24px"}}
      onClick={()=>setCtx(null)}>

      {/* ── TOP BAR ── */}
      <div style={{background:"#0d0f13",borderBottom:`1px solid ${C.border}`,
        padding:"10px 20px",display:"flex",alignItems:"center",justifyContent:"space-between"}}>
        <div style={{display:"flex",alignItems:"center",gap:14}}>
          <div style={{width:28,height:28,borderRadius:6,
            background:"linear-gradient(135deg,#f46800,#fa9f3a)",
            display:"flex",alignItems:"center",justifyContent:"center",
            fontSize:14,fontWeight:900,color:"#fff"}}>D</div>
          <span style={{fontWeight:700,fontSize:15}}>Deadline Farm Monitor</span>
          <span style={{background:"#2a2d3a",borderRadius:10,padding:"2px 10px",
            fontSize:11,color:C.muted}}>Production · Studio A</span>
        </div>
        <div style={{display:"flex",gap:20,alignItems:"center"}}>
          <span style={{fontSize:11,color:C.muted}}>
            Last update: <span style={{color:C.text}}>5s ago</span>
          </span>
          <Clock/>
        </div>
      </div>

      <div style={{padding:"16px 20px",display:"flex",flexDirection:"column",gap:14}}>

        {/* hint bar */}
        <div style={{background:"#1a1d24",border:`1px dashed ${C.border}`,
          borderRadius:4,padding:"8px 14px",fontSize:11,color:C.muted,display:"flex",gap:8}}>
          <span style={{color:C.orange}}>💡</span>
          <span>Hover the stat cards for quick actions · Right-click any
            <strong style={{color:C.text}}> worker</strong> or
            <strong style={{color:C.text}}> job row</strong> for the full action menu
          </span>
        </div>

        {/* ── ROW 1 — stat cards ── */}
        <div style={{display:"flex",gap:12}}>

          {/* Active Workers */}
          <StatCard label="Active Workers" value={active} color={C.green} sub={`of ${workers.length} total`}
            popover={()=>(
              <div>
                {workers.filter(w=>w.status==="active").map(w=>(
                  <div key={w.id} style={{display:"flex",alignItems:"center",gap:10,
                    padding:"9px 14px",borderBottom:`1px solid ${C.border}22`}}>
                    <div style={{width:8,height:8,borderRadius:"50%",background:C.green,flexShrink:0}}/>
                    <div style={{flex:1,minWidth:0}}>
                      <div style={{color:C.text,fontSize:12,fontWeight:600}}>{w.id}</div>
                      <div style={{color:C.muted,fontSize:11,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{w.job}</div>
                    </div>
                    <div style={{textAlign:"right",flexShrink:0}}>
                      <div style={{fontSize:11,color:w.cpu>90?C.orange:C.muted}}>{w.cpu}% CPU</div>
                      <div style={{fontSize:10,color:C.muted}}>{w.pool}</div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          />

          {/* Idle Workers */}
          <StatCard label="Idle Workers" value={idle} color={C.yellow} sub="no job assigned"
            popover={()=>(
              <div>
                {workers.filter(w=>w.status==="idle").map(w=>(
                  <div key={w.id} style={{display:"flex",alignItems:"center",gap:10,
                    padding:"9px 14px",borderBottom:`1px solid ${C.border}22`}}>
                    <div style={{width:8,height:8,borderRadius:"50%",background:C.yellow,flexShrink:0}}/>
                    <div style={{flex:1}}>
                      <div style={{color:C.text,fontSize:12,fontWeight:600}}>{w.id}</div>
                      <div style={{color:C.muted,fontSize:11}}>Waiting for job</div>
                    </div>
                    <button onClick={()=>{
                      setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"offline"}:x));
                      toast(`${w.id} set to stasis`,C.yellow,"⏸");
                    }} style={{
                      background:"transparent",border:`1px solid ${C.yellow}`,
                      color:C.yellow,borderRadius:4,padding:"3px 10px",
                      cursor:"pointer",fontSize:11,
                    }}>Stasis</button>
                  </div>
                ))}
                {idle===0&&<div style={{padding:"16px 14px",color:C.muted,fontSize:12,textAlign:"center"}}>No idle workers</div>}
              </div>
            )}
          />

          {/* Offline / Error */}
          <StatCard label="Offline / Error" value={offline} color={C.red} sub="needs attention"
            popover={()=>(
              <div>
                {workers.filter(w=>w.status==="offline").map(w=>(
                  <div key={w.id} style={{padding:"9px 14px",borderBottom:`1px solid ${C.border}22`}}>
                    <div style={{display:"flex",alignItems:"center",gap:10,marginBottom:8}}>
                      <div style={{width:8,height:8,borderRadius:"50%",background:C.red,flexShrink:0}}/>
                      <div style={{flex:1}}>
                        <div style={{color:C.text,fontSize:12,fontWeight:600}}>{w.id}</div>
                        <div style={{color:C.red,fontSize:11}}>● offline</div>
                      </div>
                    </div>
                    <div style={{display:"flex",gap:6}}>
                      <button onClick={()=>{
                        setWorkers(ws=>ws.map(x=>x.id===w.id?{...x,status:"idle",cpu:0,job:"—",pool:"—"}:x));
                        toast(`${w.id} started`,C.green,"▶");
                      }} style={{
                        flex:1,background:`${C.green}22`,border:`1px solid ${C.green}`,
                        color:C.green,borderRadius:4,padding:"5px 0",
                        cursor:"pointer",fontSize:11,fontWeight:600,
                      }}>▶ Start Worker</button>
                      <button onClick={()=>toast(`Restarting ${w.id}…`,C.orange,"🔁")}
                        style={{flex:1,background:`${C.orange}11`,border:`1px solid ${C.orange}44`,
                          color:C.orange,borderRadius:4,padding:"5px 0",cursor:"pointer",fontSize:11}}>
                        🔁 Restart
                      </button>
                      <button onClick={()=>toast(`Opening logs for ${w.id}…`,C.blue,"📋")}
                        style={{background:`${C.blue}11`,border:`1px solid ${C.blue}44`,
                          color:C.blue,borderRadius:4,padding:"5px 10px",cursor:"pointer",fontSize:11}}>
                        📋
                      </button>
                    </div>
                  </div>
                ))}
                {offline===0&&<div style={{padding:"16px 14px",color:C.muted,fontSize:12,textAlign:"center"}}>All workers online ✓</div>}
              </div>
            )}
          />

          {/* Jobs in Queue */}
          <StatCard label="Jobs in Queue" value={queued} color={C.blue} sub="waiting for worker"
            popover={()=>(
              <div>
                {jobs.filter(j=>j.status==="queued").map((j,i)=>(
                  <div key={i} style={{display:"flex",alignItems:"center",gap:10,
                    padding:"9px 14px",borderBottom:`1px solid ${C.border}22`}}>
                    <div style={{flex:1,minWidth:0}}>
                      <div style={{color:C.text,fontSize:12,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{j.name}</div>
                      <div style={{color:C.muted,fontSize:11}}>{j.pool} · Pri {j.pri}</div>
                    </div>
                    <button onClick={()=>{
                      setJobs(js=>js.map(x=>x.name===j.name?{...x,pri:Math.min(100,x.pri+10)}:x));
                      toast(`Priority +10 → ${Math.min(100,j.pri+10)}`,C.orange,"⬆");
                    }} style={{
                      background:"transparent",border:`1px solid ${C.orange}66`,
                      color:C.orange,borderRadius:4,padding:"3px 8px",
                      cursor:"pointer",fontSize:11,
                    }}>⬆ Pri</button>
                  </div>
                ))}
                {queued===0&&<div style={{padding:"16px 14px",color:C.muted,fontSize:12,textAlign:"center"}}>Queue is empty</div>}
              </div>
            )}
          />

          {/* Failed Jobs */}
          <StatCard label="Failed Jobs" value={failed} color={C.red} sub="today"
            popover={()=>(
              <div>
                {jobs.filter(j=>j.status==="failed").map((j,i)=>(
                  <div key={i} style={{padding:"9px 14px",borderBottom:`1px solid ${C.border}22`}}>
                    <div style={{color:C.text,fontSize:12,marginBottom:4,
                      overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{j.name}</div>
                    <div style={{color:C.muted,fontSize:11,marginBottom:8}}>{j.pool} · {j.tasks} tasks</div>
                    <div style={{display:"flex",gap:6}}>
                      <button onClick={()=>{
                        setJobs(js=>js.map(x=>x.name===j.name?{...x,status:"queued",pct:0,tasks:x.tasks.replace(/^\d+/,"0")}:x));
                        toast(`"${j.name}" requeued`,C.green,"🔄");
                      }} style={{
                        flex:1,background:`${C.green}22`,border:`1px solid ${C.green}`,
                        color:C.green,borderRadius:4,padding:"5px 0",
                        cursor:"pointer",fontSize:11,fontWeight:600,
                      }}>🔄 Requeue</button>
                      <button onClick={()=>toast(`Resubmitting "${j.name}"…`,C.blue,"📤")}
                        style={{flex:1,background:`${C.blue}11`,border:`1px solid ${C.blue}44`,
                          color:C.blue,borderRadius:4,padding:"5px 0",cursor:"pointer",fontSize:11}}>
                        📤 Resubmit
                      </button>
                      <button onClick={()=>toast(`Opening errors for "${j.name}"…`,C.muted,"📋")}
                        style={{background:C.border,border:`1px solid ${C.border}`,
                          color:C.muted,borderRadius:4,padding:"5px 10px",cursor:"pointer",fontSize:11}}>
                        📋
                      </button>
                    </div>
                  </div>
                ))}
                {failed===0&&<div style={{padding:"16px 14px",color:C.muted,fontSize:12,textAlign:"center"}}>No failures today ✓</div>}
              </div>
            )}
          />

          {/* Frames / Hour */}
          <StatCard label="Frames / Hour" value="720" color={C.purple} unit="fps" sub="today's peak"/>

        </div>

        {/* ── ROW 2 — gauge + throughput + pool bars ── */}
        <div style={{display:"flex",gap:12}}>
          <Panel title="Farm Utilization" style={{width:200,flexShrink:0}}>
            <GaugeArc value={71} color={C.orange}/>
            <div style={{display:"flex",justifyContent:"space-around",marginTop:4}}>
              {[["Active",active,C.green],["Idle",idle,C.yellow],["Off",offline,C.red]].map(([l,v,c])=>(
                <div key={l} style={{textAlign:"center"}}>
                  <div style={{fontSize:16,fontWeight:700,color:c}}>{v}</div>
                  <div style={{fontSize:10,color:C.muted}}>{l}</div>
                </div>
              ))}
            </div>
          </Panel>

          <Panel title="Frame Throughput (today)" style={{flex:1}}>
            <ResponsiveContainer width="100%" height={160}>
              <AreaChart data={throughputData}>
                <defs>
                  <linearGradient id="tg" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor={C.blue} stopOpacity={0.4}/>
                    <stop offset="95%" stopColor={C.blue} stopOpacity={0}/>
                  </linearGradient>
                </defs>
                <CartesianGrid stroke={C.border} vertical={false}/>
                <XAxis dataKey="t" tick={{fill:C.muted,fontSize:10}} axisLine={false} tickLine={false}/>
                <YAxis tick={{fill:C.muted,fontSize:10}} axisLine={false} tickLine={false} width={36}/>
                <Tooltip contentStyle={{background:"#23262e",border:`1px solid ${C.border}`,borderRadius:4}}
                  labelStyle={{color:C.muted}} itemStyle={{color:C.blue}}/>
                <Area type="monotone" dataKey="frames" stroke={C.blue} strokeWidth={2}
                  fill="url(#tg)" name="Frames/h" dot={false}/>
              </AreaChart>
            </ResponsiveContainer>
          </Panel>

          <Panel title="Jobs by Pool / Renderer" style={{width:200,flexShrink:0}}>
            <ResponsiveContainer width="100%" height={160}>
              <BarChart data={poolData} layout="vertical" barSize={14}>
                <CartesianGrid stroke={C.border} horizontal={false}/>
                <XAxis type="number" tick={{fill:C.muted,fontSize:10}} axisLine={false} tickLine={false}/>
                <YAxis dataKey="pool" type="category" tick={{fill:C.text,fontSize:10}} axisLine={false} tickLine={false} width={52}/>
                <Tooltip contentStyle={{background:"#23262e",border:`1px solid ${C.border}`,borderRadius:4}}
                  labelStyle={{color:C.muted}} itemStyle={{color:C.orange}}/>
                <Bar dataKey="jobs" fill={C.orange} radius={[0,3,3,0]} name="Jobs"/>
              </BarChart>
            </ResponsiveContainer>
          </Panel>
        </div>

        {/* ── ROW 3 — utilization timeline ── */}
        <Panel title="Farm Utilization % (today)">
          <ResponsiveContainer width="100%" height={90}>
            <AreaChart data={utilizationData}>
              <defs>
                <linearGradient id="ug" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor={C.green} stopOpacity={0.35}/>
                  <stop offset="95%" stopColor={C.green} stopOpacity={0}/>
                </linearGradient>
              </defs>
              <CartesianGrid stroke={C.border} vertical={false}/>
              <XAxis dataKey="t" tick={{fill:C.muted,fontSize:10}} axisLine={false} tickLine={false}/>
              <YAxis domain={[0,100]} tick={{fill:C.muted,fontSize:10}} axisLine={false} tickLine={false} width={30}
                tickFormatter={v=>`${v}%`}/>
              <Tooltip contentStyle={{background:"#23262e",border:`1px solid ${C.border}`,borderRadius:4}}
                labelStyle={{color:C.muted}} itemStyle={{color:C.green}} formatter={v=>[`${v}%`,"Utilization"]}/>
              <Area type="monotone" dataKey="util" stroke={C.green} strokeWidth={2} fill="url(#ug)" dot={false}/>
            </AreaChart>
          </ResponsiveContainer>
        </Panel>

        {/* ── ROW 4 — workers grid + job table ── */}
        <div style={{display:"flex",gap:12}}>

          <Panel title="Workers — right-click for actions" style={{width:320,flexShrink:0}}>
            <div style={{display:"flex",flexWrap:"wrap",gap:8}}>
              {workers.map(w=><WorkerDot key={w.id} w={w} onContextMenu={workerActions}/>)}
            </div>
            <div style={{display:"flex",gap:16,marginTop:14,fontSize:11}}>
              {[["● Active",C.green],["● Idle",C.yellow],["● Offline",C.red]].map(([l,c])=>(
                <span key={l} style={{color:c}}>{l}</span>
              ))}
            </div>
          </Panel>

          <Panel title="Job Queue — right-click for actions" style={{flex:1}}>
            {jobs.length===0
              ? <div style={{color:C.muted,textAlign:"center",padding:"30px 0"}}>No jobs in queue</div>
              : (
              <table style={{width:"100%",borderCollapse:"collapse",fontSize:12}}>
                <thead>
                  <tr>
                    {["Name","Pool","Pri","Tasks","Progress","Status"].map(h=>(
                      <th key={h} style={{textAlign:"left",color:C.muted,fontWeight:500,
                        padding:"0 8px 8px",borderBottom:`1px solid ${C.border}`,
                        fontSize:11,textTransform:"uppercase",letterSpacing:.8}}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {jobs.map((j,i)=>(
                    <tr key={i} onContextMenu={e=>jobActions(e,j)}
                      style={{borderBottom:`1px solid ${C.border}22`,cursor:"context-menu",transition:"background .1s"}}
                      onMouseEnter={e=>e.currentTarget.style.background="#ffffff08"}
                      onMouseLeave={e=>e.currentTarget.style.background="transparent"}>
                      <td style={{padding:"7px 8px",color:C.text,maxWidth:180,
                        overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}
                        title={j.name}>{j.name}</td>
                      <td style={{padding:"7px 8px",color:C.muted}}>{j.pool}</td>
                      <td style={{padding:"7px 8px",
                        color:j.pri>=80?C.orange:C.muted,
                        fontWeight:j.pri>=80?700:400}}>{j.pri}</td>
                      <td style={{padding:"7px 8px",color:C.muted,fontFamily:"monospace"}}>{j.tasks}</td>
                      <td style={{padding:"7px 8px",width:100}}>
                        <ProgressBar pct={j.pct} color={jobColor(j.status)}/>
                        <span style={{fontSize:10,color:C.muted}}>{j.pct}%</span>
                      </td>
                      <td style={{padding:"7px 8px"}}>
                        <span style={{background:`${jobColor(j.status)}22`,color:jobColor(j.status),
                          borderRadius:10,padding:"2px 8px",fontSize:11}}>{j.status}</span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </Panel>
        </div>

        <div style={{textAlign:"center",color:C.muted,fontSize:11,marginTop:4}}>
          Deadline Farm Monitor · Auto-refresh every 10s
        </div>
      </div>

      {ctx&&<ContextMenu x={ctx.x} y={ctx.y} items={ctx.items} onClose={()=>setCtx(null)}/>}
      {confirm&&<ConfirmDialog msg={confirm.msg} onYes={confirm.onYes} onNo={()=>setConfirm(null)}/>}
      <Toast toasts={toasts}/>
      <style>{`@keyframes fadeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}`}</style>
    </div>
  );
}
