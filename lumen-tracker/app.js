(() => {
  "use strict";
  const seed = window.LUMEN_SEED;
  const app = document.getElementById("app");
  const KEY = "lumen-reliability-console-v1";
  const GH = "https://github.com/" + seed.repository;
  const API = "https://api.github.com/repos/" + seed.repository;
  const priorityOrder = {P0:0,P1:1,P2:2,P3:3};
  const areas = ["All","Build","Recording","Transcription","Paste","Recovery","Audio","Zoom","Motion","Framing","Export"];
  const now = () => new Date().toISOString();
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const short = s => (s || "unknown").slice(0,7);
  const safeJSON = x => {try{return JSON.stringify(x,null,2)}catch{return "{}"}};
  const stamp = iso => {if(!iso)return "Unknown";let d=new Date(iso);return Number.isNaN(+d)?"Unknown":d.toLocaleString(undefined,{month:"short",day:"numeric",hour:"numeric",minute:"2-digit"})};
  const initial = {view:"overview",selected:"LUM-001",query:"",filter:"All",custom:[],notes:{},logs:[],ci:null,prs:null,syncTime:null,syncError:null,showNew:false};
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch {}
  const state = {...initial, custom:Array.isArray(saved.custom)?saved.custom:[],notes:saved.notes && typeof saved.notes==="object"?saved.notes:{},logs:Array.isArray(saved.logs)?saved.logs:[]};
  const all = () => [...seed.issues,...state.custom];
  const issue = id => all().find(x=>x.id===id) || all()[0];
  const persist = () => { try { localStorage.setItem(KEY,JSON.stringify({custom:state.custom,notes:state.notes,logs:state.logs}));}catch{toast("Storage unavailable. Export your data.")} };
  function selected(){return issue(state.selected)}
  function statusBadge(label, kind=""){return '<span class="badge '+esc(kind)+'">'+esc(label)+'</span>'}
  function priorityBadge(p){return statusBadge(p,p.toLowerCase())}
  function codeStatus(i){
    if(i.pr != null && state.prs && state.prs[i.pr]){
      const p=state.prs[i.pr];
      return p.merged_at?{label:"Merged · live",kind:"orange",merged:true,source:"GitHub live"}
        :{label:p.state==="open"?"PR open":"Closed / unmerged",kind:"rose",merged:false,source:"GitHub live"};
    }
    if(i.pr != null && i.code==="merged")return {label:"Merged · snapshot",kind:"orange",merged:true,source:"GitHub snapshot"};
    if(i.code==="merged" && i.commit)return {label:"On main · snapshot",kind:"orange",merged:true,source:"Git history snapshot"};
    if(i.code==="unknown")return {label:"Scope unknown",kind:"dimmed",merged:false,source:"unverified"};
    return {label:"Plan only",kind:"dimmed",merged:false,source:"not merged"};
  }
  function currentCI(){return state.ci || seed.ci}
  function filtered(){
    const q=state.query.trim().toLowerCase();
    return all().filter(i=>(state.filter==="All"||i.area===state.filter) &&
      (!q || [i.id,i.title,i.area,i.summary,i.cause,i.impact,i.confidence,
        ...(i.files||[]),...(i.repro||[]),...(i.fix||[])].join(" ").toLowerCase().includes(q)))
      .sort((a,b)=>(priorityOrder[a.priority]??3)-(priorityOrder[b.priority]??3) || (a.state==="blocked"?-1:0)-(b.state==="blocked"?-1:0) || a.id.localeCompare(b.id));
  }
  function icon(n){return ({overview:"▣",issues:"≡",agent:"⌘",regressions:"↺"})[n] || "·"}
  function nav(id,title,count=""){
    return '<button type="button" class="nav-item '+(state.view===id?"active":"")+'" data-action="view" data-view="'+id+'" title="'+title+'"><span class="nav-glyph">'+icon(id)+'</span><span class="nav-text">'+title+'</span>'+(count?'<span class="nav-idx">'+count+'</span>':"")+'</button>';
  }
  function shell(){
    const ci=currentCI();
    const ciIsGood=ci.status==="success";
    const headline={overview:"Reliability",issues:"Issue map",agent:"Agent workspace",regressions:"Regression log"}[state.view];
    return '<div class="shell">'+
      '<aside class="side"><div class="brand"><span class="pixel-mark" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><b></b></span><span class="brand-txt"><div class="brand-title">lumen<span style="color:var(--accent)">.</span></div><div class="brand-sub">Engineering console</div></span></div>'+
        '<nav aria-label="Primary navigation"><div class="nav-label">Workspace</div><div class="nav-list">'+nav("overview","Overview")+nav("issues","Issue map",all().length)+nav("agent","Agent workspace")+nav("regressions","Regression log",state.logs.length)+'</div></nav>'+
        '<div class="side-bottom"><div class="source-mini"><span class="kicker">Source of truth</span><span class="mono" style="font-size:11px">'+esc(seed.repository)+'</span><span class="tiny">Merge state is independent of CI and device verification.</span><a href="'+GH+'" target="_blank" rel="noopener" class="mono" style="font-size:10px;color:var(--accent-ink)">Open repository ↗</a></div><div class="side-footer"><span class="status-pixel '+(ciIsGood?"ok":"bad")+'"></span><span>MAIN BUILD '+(ciIsGood?"PASS":"NOT GREEN")+'</span></div></div></aside>'+
      '<main class="main"><header class="topbar"><div class="crumb"><span>lumen</span><span class="crumb-sep">/</span><strong>'+esc(headline)+'</strong><span class="crumb-sep">/</span><span class="mono">main</span></div><div class="top-actions"><span class="top-meta">'+(state.syncTime?"Live check "+esc(stamp(state.syncTime)):"Snapshot · Nov 06, 2026")+'</span><button class="btn sm" data-action="sync" id="sync-button"><span class="sync-icon">↻</span> <span id="sync-label">Sync GitHub</span></button><a class="btn sm" href="'+GH+'" target="_blank" rel="noopener">GitHub ↗</a></div></header>'+
      '<div class="page">'+
        '<div class="page-head"><div><div class="kicker">Lumen / Engineering intelligence</div><h1 class="heading">'+esc(headline)+'<span class="aperture" aria-hidden="true"></span></h1><div class="subtitle">'+esc(({overview:"A clear picture of what ships, what breaks, and what is still a hypothesis.",issues:"Trace every failure to reproduction, ownership, test evidence and merge state.",agent:"Strict work orders for coding agents. No speculative fixes disguised as verified changes.",regressions:"Repeatable observations, without silently upgrading local notes to release proof."})[state.view])+'</div></div><div class="head-action">'+(state.view==="issues"||state.view==="overview"?'<button class="btn sm" data-action="new">+ New issue</button>':"")+'<button class="btn sm quiet" data-action="export">Export data ↗</button></div></div>'+
        (state.view==="overview"?dashboard() : state.view==="issues"?issueWorkspace() : state.view==="agent"?agentWorkspace():regressionWorkspace())+
        '<div class="information"><div><span class="kicker">Evidence discipline</span><p>PR merged ≠ current build passed ≠ runtime verified. Source paths match the inspected GitHub tree: <span class="mono">Sources/</span>. No native source directories were renamed. Personal annotations live only in this browser.</p></div><a class="btn sm" href="'+GH+'/actions/workflows/swift-verify.yml" target="_blank" rel="noopener">Workflow ↗</a></div>'+
      '</div></main></div>';
  }
  function dashboard(){
    const ci=currentCI();
    const merged=all().filter(i=>codeStatus(i).merged).length;
    const blocked=all().filter(i=>i.state==="blocked").length;
    const unverified=all().filter(i=>!["manual-pass"].includes(state.notes[i.id]?.result)).length;
    const metrics=[
      {label:"Latest CI / main",value:ci.status==="success"?"Passed":"Failed",extra:ci.stage||"Swift verification",cls:ci.status==="success"?"":"bad"},
      {label:"Source issues",value:String(all().length).padStart(2,"0"),extra:blocked+" blocked in current snapshot"},
      {label:"Merged issue implementations",value:String(merged).padStart(2,"0"),extra:"Does not imply runtime verification"},
      {label:"Device-verified entries",value:String(all().length-unverified).padStart(2,"0"),extra:"Local observations only; not release proof"}
    ];
    const cards=metrics.map(m=>'<div class="metric"><div class="metric-top">'+esc(m.label)+'</div><div class="metric-value '+m.cls+'">'+esc(m.value)+'</div><div class="metric-foot">'+esc(m.extra)+'</div></div>').join("");
    const next=["LUM-001","LUM-002","LUM-003"].map((id,j)=>{let i=issue(id);return '<button class="next-card" data-action="open" data-id="'+id+'"><div class="next-top">'+priorityBadge(i.priority)+'<span class="next-count">0'+(j+1)+' / NEXT</span></div><div class="next-title">'+esc(i.title)+'</div><div class="next-sub">'+esc(i.impact)+'</div></button>'}).join("");
    return '<div class="metrics">'+cards+'</div><div class="section-head"><h2 class="section-title">Next three fixes <span class="count">ranked by impact + verification gate</span></h2><span class="section-label">P0 QUEUE</span></div><div class="next-grid">'+next+'</div>'+issueWorkspace();
  }
  function issueWorkspace(){
    const list=filtered();
    return '<div class="workspace"><section class="pane"><div class="pane-header"><div class="pane-title">Issues <span id="issues-count" class="count">'+list.length+' / '+all().length+'</span></div><div class="tools"><label class="search-wrap" aria-label="Search issues"><span class="search-glyph">⌕</span><input id="issue-search" autocomplete="off" value="'+esc(state.query)+'" placeholder="Search issues, modules, causes…" aria-label="Search issues"><span class="keycap">/</span></label></div></div>'+
      '<div class="filters" id="filters">'+areas.map(a=>'<button class="filter '+(state.filter===a?"active":"")+'" data-action="filter" data-filter="'+a+'">'+a+'</button>').join("")+'</div>'+
      '<div style="overflow-x:auto"><table class="issue-table"><colgroup><col style="width:91px"><col><col style="width:90px"><col style="width:100px"><col style="width:87px"></colgroup><thead><tr><th>PRIORITY</th><th>ISSUE / SCOPE</th><th>AREA</th><th>IMPLEMENTATION</th><th>TEST GATE</th></tr></thead><tbody id="issue-list">'+issueRows(list)+'</tbody></table></div><div class="table-foot">Select any row to inspect evidence · Keyboard shortcut / to search</div></section>'+
      '<aside class="pane detail" id="issue-detail">'+(state.showNew?newIssueForm():detail(selected()))+'</aside></div>';
  }
  function issueRows(list){
    if(!list.length)return '<tr><td colspan="5"><div class="table-empty">No matching issues. Try another module or clear the search.</div></td></tr>';
    return list.map(i=>{
      const code=codeStatus(i);
      const test=i.tests.kind;
      const testLabel=(test==="failed"?"Failed":test==="skipped"?"Skipped":test==="historical-pass"?"Earlier pass":test==="blocked"?"Blocked":"Unverified");
      return '<tr class="entry '+(state.selected===i.id?"selected":"")+'" data-issue="'+esc(i.id)+'" tabindex="0" aria-selected="'+(state.selected===i.id)+'"><td>'+priorityBadge(i.priority)+'</td><td><span class="issue-id">'+esc(i.id)+'</span><div class="issue-main" title="'+esc(i.title)+'">'+esc(i.title)+'</div></td><td><span class="issue-area">'+esc(i.area)+'</span></td><td>'+statusBadge(code.label,code.kind)+'</td><td class="lastcol">'+statusBadge(testLabel,test==="failed"?"rose":test==="historical-pass"?"good":"dimmed")+'</td></tr>';
    }).join("");
  }
  function detail(i){
    if(!i)return '<div class="empty-state">Select an issue.</div>';
    const code=codeStatus(i);
    const n=state.notes[i.id]||{};
    const files=(i.files||[]).length?i.files.map(f=>'<a class="file-link" href="'+GH+'/blob/main/'+encodeURI(f)+'" target="_blank" rel="noopener"><span>'+esc(f)+'</span><b>↗</b></a>').join(""):'<span class="notice">No owning source module established.</span>';
    const rootWarning=i.confidence==="confirmed"?"Confirmed by cited evidence":i.confidence==="tentative"?"Tentative investigation, not a proven cause":"Unknown / needs reproduction";
    return '<div class="detail-top"><span class="detail-id">'+esc(i.id)+' / '+esc(i.area.toUpperCase())+'</span><button class="btn quiet sm" data-action="agent" data-id="'+esc(i.id)+'">Agent work order ↗</button></div>'+
      '<div class="detail-badges">'+priorityBadge(i.priority)+statusBadge(code.label,code.kind)+statusBadge(rootWarning,i.confidence==="confirmed"?"good":"dimmed")+'</div><h2>'+esc(i.title)+'</h2><p class="detail-desc">'+esc(i.summary)+'</p>'+
      '<div class="detail-block"><div class="detail-label">Impact</div><p class="detail-copy">'+esc(i.impact)+'</p></div>'+
      '<div class="detail-block"><div class="detail-label">Reproduce / verify</div><ol class="steps">'+(i.repro||[]).map(x=>'<li>'+esc(x)+'</li>').join("")+'</ol></div>'+
      '<div class="detail-block"><div class="detail-label">Suspected root cause · '+esc(i.confidence)+'</div><p class="detail-copy">'+esc(i.cause)+'</p></div>'+
      '<div class="detail-block"><div class="detail-label">Affected files / modules</div><div class="file-links">'+files+'</div></div>'+
      '<div class="detail-block"><div class="detail-label">CI and release evidence</div><div class="evidence-box">'+statusBadge(i.tests.text,i.tests.kind==="failed"?"rose":i.tests.kind==="historical-pass"?"good":"dimmed")+'<p>Commit integration: '+esc(code.label)+' · '+esc(code.source)+'. Device verification is separate.</p>'+(i.tests.url?'<a href="'+esc(i.tests.url)+'" target="_blank" rel="noopener">View workflow evidence ↗</a>':"")+(i.pr?'<p><a href="'+GH+'/pull/'+i.pr+'" target="_blank" rel="noopener">Pull request #'+i.pr+' ↗</a></p>':"")+'</div></div>'+
      '<div class="detail-block"><div class="detail-label">Verification notes · stored locally</div><label class="field-label" for="local-result">Device / manual test observation</label><select class="select" id="local-result"><option value="" '+(!n.result?"selected":"")+'>Not recorded</option><option value="manual-pass" '+(n.result==="manual-pass"?"selected":"")+'>Observed pass (local only)</option><option value="manual-fail" '+(n.result==="manual-fail"?"selected":"")+'>Observed failure (local only)</option></select><label class="field-label" for="local-note" style="margin-top:11px">Trace, hardware, reproduction or test output</label><textarea class="textarea" id="local-note" placeholder="Record concrete evidence, not assumptions…">'+esc(n.text||"")+'</textarea><div class="detail-actions"><button class="btn sm" data-action="save-note">Save evidence</button><button class="btn sm quiet" data-action="regress" data-id="'+esc(i.id)+'">Log regression ↗</button></div></div>';
  }
  function newIssueForm(){
    return '<div class="detail-top"><span class="detail-id">NEW / LOCAL</span><button class="btn sm quiet" data-action="cancel-new">Cancel</button></div><h2>Track a new failure.</h2><p class="detail-desc">New items are marked as locally reported. Add source evidence before claiming a fix.</p>'+
    '<form id="new-issue-form" class="form-pad" style="padding:0">'+
      '<div><label class="field-label">Issue title</label><input class="field" name="title" maxlength="130" required placeholder="Precise failing behavior"></div>'+
      '<div><label class="field-label">Module</label><select class="select" name="area">'+areas.slice(1).map(x=>'<option>'+x+'</option>').join("")+'</select></div>'+
      '<div><label class="field-label">Severity</label><select class="select" name="priority"><option>P0</option><option selected>P1</option><option>P2</option></select></div>'+
      '<div><label class="field-label">Observed evidence</label><textarea class="textarea" name="summary" required placeholder="What actually happened? On what build?"></textarea></div>'+
      '<button type="submit" class="btn primary">Create local issue</button></form>';
  }
  function buildPrompt(i){
    const code=codeStatus(i);
    const manual=state.notes[i.id];
    const evidence=i.tests.url|| (i.pr?GH+"/pull/"+i.pr:"No CI/run link verified");
    const sourceFiles=(i.files||[]).length?i.files.map(x=>"- "+x).join("\n"):"- UNKNOWN: first identify owning modules; do not invent file paths";
    return [
      "ROLE: Senior Swift 6 / Metal reliability engineer. Repository: "+seed.repository+".",
      "TASK: "+i.id+" | "+i.title+" | "+i.priority+" | "+i.area,
      "",
      "AUTHORITATIVE STATE",
      "- Main snapshot at creation: "+seed.sourceSha+". Re-fetch current main before editing.",
      "- Implementation: "+code.label+" ("+code.source+").",
      "- Current CI: "+currentCI().status+" / "+(currentCI().stage||"unknown")+".",
      "- Evidence: "+i.tests.text+". Link: "+evidence,
      "- Root cause confidence: "+i.confidence+".",
      "- Actual code tree uses Sources/. DO NOT rename it to studio/ or change directory conventions. Treat code as source of truth.",
      "",
      "OBSERVED OR REPORTED SYMPTOM",
      i.summary,
      "Impact: "+i.impact,
      "",
      "SUSPECTED CAUSE (NOT FACT UNLESS CONFIRMED)",
      i.cause,
      "",
      "REPRODUCTION AND ACCEPTANCE GATES",
      ...(i.repro||[]).map((x,n)=>(n+1)+". "+x),
      "",
      "SOURCE SCOPE (INSPECT BEFORE TOUCHING)",
      sourceFiles,
      "",
      "IMPLEMENTATION ORDER",
      "A. Read exact current source, git history and relevant CI logs. Produce a concise evidence-based root cause. Do not assert a hypothesis as proven.",
      "B. Add or strengthen a failing regression test where feasible. Record the before result and environment.",
      "C. Make the smallest focused implementation change. Preserve public signatures, native project data compatibility and established UI design. No unrelated refactor or dependencies.",
      "D. Run swift build, swift test, bash Tools/make-app.sh, and codesign --verify --strict .build/Lumen.app on macOS. Reproduce on-device if the issue requires hardware. Do not fabricate results.",
      "E. Review changed files and regression risk, commit a focused branch, open a PR, and merge ONLY when the actual latest SHA has green required CI. Verify merged_at and main ancestry from GitHub.",
      "",
      "ISSUE-SPECIFIC ACTIONS",
      ...(i.fix||[]).map((x,n)=>(n+1)+". "+x),
      "",
      "REQUIRED FINAL REPORT",
      "Root cause [confirmed/tentative/unknown] | files changed | tests run with links/results | limitations | PR URL | merged_at or NOT MERGED | main SHA | remaining regressions.",
      "A PR number is not merge proof. A merge is not a CI pass. A CI pass is not a device reliability claim.",
      ...(manual?.text?["","LOCAL OPERATOR NOTE (UNVERIFIED): "+manual.text]:[])
    ].join("\n");
  }
  function agentWorkspace(){
    const i=selected();
    const code=codeStatus(i);
    return '<div class="agent-layout"><aside class="pane agent-queue"><div class="pane-title" style="padding:4px 8px 14px">Implementation queue <span class="count">'+all().length+'</span></div>'+
      all().slice().sort((a,b)=>(priorityOrder[a.priority]??3)-(priorityOrder[b.priority]??3)).map(x=>'<button class="queue-row '+(x.id===i.id?"active":"")+'" data-action="choose-agent" data-id="'+esc(x.id)+'"><div class="a">'+esc(x.id)+' / '+esc(x.priority)+' / '+esc(x.area)+'</div><div class="b">'+esc(x.title)+'</div></button>').join("")+'</aside>'+
      '<section class="pane agent-prompt"><div class="prompt-toolbar"><div><span class="kicker">Execution contract</span><h2 style="font-size:17px;font-weight:500;margin:9px 0 0">'+esc(i.id)+' · '+esc(i.title)+'</h2></div><button class="btn primary" data-action="copy-prompt">Copy prompt ⧉</button></div>'+
      '<div class="merge-strip" style="margin-bottom:14px"><span class="status-pixel '+(code.merged?"ok":"bad")+'"></span><span class="mono" style="font-size:11px">'+esc(code.label)+'</span><span class="grow"></span><a href="'+(i.pr?GH+"/pull/"+i.pr:GH+"/actions")+'" target="_blank" rel="noopener" class="mono" style="font-size:10px;color:var(--accent-ink)">GitHub evidence ↗</a></div>'+
      '<textarea id="prompt-body" class="prompt-input" spellcheck="false" aria-label="Implementation prompt">'+esc(buildPrompt(i))+'</textarea>'+
      '<p class="notice">You may edit this work order before copying. Status synchronizes from GitHub PR metadata where a PR exists. This site never claims to merge code or run macOS tests on its own.</p></section></div>';
  }
  function regressionWorkspace(){
    const system=[
      {id:"CI-2026-11-06",issue:"LUM-001",result:"FAIL",date:"2026-11-06T10:34:31Z",text:"main af807d3: swift build failed at EditorModel.swift:381; downstream tests and packaging skipped.",url:"https://github.com/duggal1/lumen/actions/runs/42203513453",system:true},
      {id:"CI-2026-11-06-2",issue:"LUM-001",result:"FAIL",date:"2026-11-06T08:43:02Z",text:"Prior main revision 09ff779 also failed Build debug; exact error not independently established here.",url:"https://github.com/duggal1/lumen/actions/runs/42189670036",system:true},
      {id:"CI-2026-11-05",issue:"LUM-005",result:"PASS",date:"2026-11-05T21:46:11Z",text:"Earlier main revision 065b484 passed Swift verification; does not validate Nov 6 changes.",url:"https://github.com/duggal1/lumen/actions/runs/42115618589",system:true}
    ];
    const logs=[...state.logs,...system].sort((a,b)=>new Date(b.date)-new Date(a.date));
    return '<div class="regression-layout"><section class="pane"><div class="pane-header"><span class="pane-title">Log an observation</span>'+statusBadge("Local only","dimmed")+'</div><form class="form-pad" id="regression-form">'+
      '<div><label class="field-label">Linked issue</label><select name="issue" class="select">'+all().map(x=>'<option value="'+esc(x.id)+'" '+(state.selected===x.id?"selected":"")+'>'+esc(x.id)+' · '+esc(x.area)+'</option>').join("")+'</select></div>'+
      '<div><label class="field-label">Outcome</label><select name="result" class="select"><option value="FAIL">Failure reproduced</option><option value="PASS">Observed pass</option><option value="INCONCLUSIVE">Inconclusive</option></select></div>'+
      '<div><label class="field-label">Environment and actual result</label><textarea name="text" class="textarea" style="min-height:150px" required placeholder="Device, OS, commit SHA, setup, exact failure, log link…"></textarea></div>'+
      '<button type="submit" class="btn primary">Append observation</button><p class="notice">Manual logs do not change GitHub merge state or the official CI status.</p></form></section>'+
      '<section class="pane"><div class="pane-header"><span class="pane-title">Regression history <span class="count">'+logs.length+'</span></span><div class="tools"><button class="btn sm" data-action="import">Import JSON</button><button class="btn sm" data-action="export">Export JSON</button></div></div>'+
      '<div class="log-list">'+(logs.length?logs.map(l=>'<article class="log-entry"><div class="log-row"><div><span class="badge '+(l.result==="FAIL"?"rose":l.result==="PASS"?"good":"dimmed")+'">'+esc(l.result)+'</span> <span class="log-title">'+esc(l.issue)+'</span> '+(l.system?statusBadge("CI evidence","orange"):statusBadge("Local observation","dimmed"))+'</div><span class="log-meta">'+esc(stamp(l.date))+'</span></div><div class="log-note">'+esc(l.text)+'</div><div class="log-row" style="margin-top:8px"><span class="log-meta">'+esc(l.id)+'</span>'+(l.url?'<a href="'+esc(l.url)+'" target="_blank" rel="noopener" class="mono" style="font-size:10px;color:var(--accent-ink)">Workflow ↗</a>':!l.system?'<button class="btn sm quiet" data-action="delete-log" data-id="'+esc(l.id)+'">Remove</button>':"")+'</div></article>').join(""):'<div class="log-empty">No regression entries yet.</div>')+'</div></section></div><input type="file" id="import-file" accept="application/json,.json" hidden>';
  }
  function render(){app.innerHTML=shell();}
  function toast(msg){document.querySelector(".toast")?.remove();let el=document.createElement("div");el.className="toast";el.setAttribute("role","status");el.textContent=msg;document.body.appendChild(el);setTimeout(()=>el.remove(),2800)}
  function setView(v){state.view=v;state.showNew=false;render();scrollTo({top:0,behavior:"instant"})}
  async function syncGitHub(){
    let b=document.getElementById("sync-button");
    if(b){b.classList.add("busy");b.disabled=true;document.getElementById("sync-label").textContent="Checking…"}
    try{
      const headers={Accept:"application/vnd.github+json"};
      const request=async path=>{const r=await fetch(API+path,{headers,cache:"no-store"});if(!r.ok)throw Error("GitHub HTTP "+r.status);return r.json()};
      const [prs,runs,commit]=await Promise.all([
        request("/pulls?state=all&per_page=100"),request("/actions/runs?per_page=6"),request("/commits/main")
      ]);
      const map={};for(const p of prs)map[p.number]={state:p.state,merged_at:p.merged_at,title:p.title,html_url:p.html_url};
      state.prs=map;
      const latest=runs.workflow_runs?.find(x=>x.name==="Swift verification")||runs.workflow_runs?.[0];
      if(latest)state.ci={status:latest.conclusion||latest.status||"unknown",stage:latest.conclusion==="failure"?"Build/test failure · inspect log":"Swift verification",sha:latest.head_sha,run:latest.id,detail:"GitHub workflow status only. No macOS device test implied."};
      state.headSha=commit.sha;
      state.syncTime=now();state.syncError=null;
      render();
      toast("GitHub metadata refreshed");
    }catch(e){
      state.syncError=String(e?.message||e);render();toast("Sync unavailable · keeping labeled snapshot");
    }
  }
  function exportData(){
    const payload={schema:"lumen-reliability-console-v1",exportedAt:now(),source:seed.repository,sourceSha:seed.sourceSha,custom:state.custom,notes:state.notes,logs:state.logs};
    const blob=new Blob([safeJSON(payload)],{type:"application/json"});
    const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download="lumen-reliability-"+new Date().toISOString().slice(0,10)+".json";document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);toast("Evidence exported");
  }
  function saveNote(){
    const i=selected();if(!i)return;
    const text=document.getElementById("local-note")?.value||"";
    const result=document.getElementById("local-result")?.value||"";
    state.notes[i.id]={result,text,updatedAt:now()};
    persist();render();toast("Local evidence saved");
  }
  function createIssue(form){
    const title=form.elements.title.value.trim(),summary=form.elements.summary.value.trim();
    if(!title||!summary)return;
    let max=Math.max(100,...all().map(x=>Number(x.id.split("-")[1])||0))+1;
    const id="LUM-"+max;
    const i={id,title,area:form.elements.area.value,priority:form.elements.priority.value,state:"needs-test",evidence:"report",confidence:"unknown",code:"unknown",pr:null,impact:"Impact to be measured",summary,
      repro:["Capture exact reproduction steps and environment.","Attach logs/screenshots and commit SHA.","Repeat after implementing a regression test."],
      cause:"Unknown. Investigation required.",files:[],tests:{kind:"not-run",text:"Local report only; no CI or hardware proof"},fix:["Reproduce before changing code.","Identify precise owning files from current main.","Add regression test and use full macOS CI as merge gate."]};
    state.custom.unshift(i);state.selected=id;state.showNew=false;persist();setView("issues");toast("Local issue created");
  }
  function appendLog(form){
    let id="manual-"+(typeof crypto!=="undefined"&&crypto.randomUUID?crypto.randomUUID():Date.now());
    state.logs.push({id,issue:form.elements.issue.value,result:form.elements.result.value,
      text:form.elements.text.value.trim(),date:now(),system:false});
    state.selected=form.elements.issue.value;persist();render();toast("Regression observation recorded");
  }
  async function importData(file){
    if(!file)return;
    try{
      if(file.size>2_000_000)throw Error("File exceeds 2 MB");
      const data=JSON.parse(await file.text());
      if(data.schema!=="lumen-reliability-console-v1"||data.source!==seed.repository||!Array.isArray(data.custom)||!Array.isArray(data.logs)||typeof data.notes!=="object"||data.notes===null)
        throw Error("Not a Lumen evidence export");
      if(!confirm("Replace this browser's local issues, notes and regression log with the imported export?"))return;
      state.custom=data.custom;state.notes=data.notes;state.logs=data.logs;persist();render();toast("Evidence import complete");
    }catch(e){toast("Import rejected: "+String(e?.message||e))}
  }
  app.addEventListener("click",async e=>{
    const link=e.target.closest("[data-action]");
    const row=e.target.closest("tr[data-issue]");
    if(row&&!link){state.selected=row.dataset.issue;state.showNew=false;const focusWasSearch=document.activeElement?.id==="issue-search";render();if(focusWasSearch)document.getElementById("issue-search")?.focus();return}
    if(!link)return;
    const a=link.dataset.action;
    if(a==="view")setView(link.dataset.view);
    if(a==="open"){state.selected=link.dataset.id;setView("issues")}
    if(a==="filter"){state.filter=link.dataset.filter;render()}
    if(a==="new"){state.showNew=true;render()}
    if(a==="cancel-new"){state.showNew=false;render()}
    if(a==="agent"){state.selected=link.dataset.id;setView("agent")}
    if(a==="choose-agent"){state.selected=link.dataset.id;render()}
    if(a==="copy-prompt"){const value=document.getElementById("prompt-body")?.value||"";try{await navigator.clipboard.writeText(value);toast("Work order copied")}catch{document.getElementById("prompt-body")?.select();toast("Select prompt and copy manually")}}
    if(a==="save-note")saveNote();
    if(a==="regress"){state.selected=link.dataset.id;setView("regressions")}
    if(a==="sync")await syncGitHub();
    if(a==="export")exportData();
    if(a==="import")document.getElementById("import-file")?.click();
    if(a==="delete-log"){state.logs=state.logs.filter(x=>x.id!==link.dataset.id);persist();render();toast("Local entry removed")}
  });
  app.addEventListener("input",e=>{
    if(e.target.id==="issue-search"){
      state.query=e.target.value;
      const tbody=document.getElementById("issue-list"),count=document.getElementById("issues-count");
      if(tbody)tbody.innerHTML=issueRows(filtered());
      if(count)count.textContent=filtered().length+" / "+all().length;
    }
  });
  app.addEventListener("keydown",e=>{
    const row=e.target.closest("tr[data-issue]");
    if(row&&(e.key==="Enter"||e.key===" ")){e.preventDefault();state.selected=row.dataset.issue;render()}
  });
  app.addEventListener("submit",e=>{
    if(e.target.id==="new-issue-form"){e.preventDefault();createIssue(e.target)}
    if(e.target.id==="regression-form"){e.preventDefault();appendLog(e.target)}
  });
  app.addEventListener("change",e=>{if(e.target.id==="import-file")importData(e.target.files?.[0])});
  document.addEventListener("keydown",e=>{
    const tag=document.activeElement?.tagName;
    if(e.key==="/"&&!e.metaKey&&!e.ctrlKey&&!["INPUT","TEXTAREA","SELECT"].includes(tag)){
      e.preventDefault();if(!["overview","issues"].includes(state.view))setView("issues");document.getElementById("issue-search")?.focus();
    }
    if(e.key==="Escape"&&document.activeElement?.id==="issue-search")document.activeElement.blur();
  });
  render();
  syncGitHub();
})();