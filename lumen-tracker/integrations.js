(() => {
  "use strict";
  const REPO="duggal1/lumen";
  const root=document.getElementById("app");
  const data=window.LUMEN_SEED;
  const memory={token:null,githubUser:null,reflectionKey:null,mode:null,returnTo:null,originId:null,
    busy:false,draft:{},issues:null,fetching:false,lastSync:null,lastError:null,published:null};
  const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const ph=(name)=>'<i class="ph ph-'+name+'" aria-hidden="true"></i>';
  const PLUS_ONE_SVG='<svg class="ic-svg" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><mask id="plus-one-m" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><g fill="none" stroke="#fff" stroke-width="2" stroke-linecap="square" stroke-linejoin="miter"><path d="M3 12H11"/><path d="M7 8V16"/><path d="M15.5 9L18 7V17"/><path d="M15 17H21"/></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#plus-one-m)"/></svg>';
  const badge=(txt,kind="orange")=>'<span class="badge '+kind+'">'+esc(txt)+'</span>';
  const element=(tag,cls,html)=>{const d=document.createElement(tag);d.className=cls;d.innerHTML=html;return d};
  const safeUrl=(number)=>"https://github.com/"+REPO+"/issues/"+encodeURIComponent(String(number));
  function feedback(text,type="error"){
    const spot=document.getElementById("ix-feedback");
    if(spot){spot.className=type==="success"?"ix-success":"ix-error";spot.textContent=text}
  }
  function selectedIssue(){
    const id=document.querySelector("#issue-detail .detail-id")?.textContent?.match(/LUM-\d+/)?.[0]
      ||document.querySelector(".agent-prompt h2")?.textContent?.match(/LUM-\d+/)?.[0];
    if(!id)return null;
    const local=(()=>{try{return JSON.parse(localStorage.getItem("lumen-reliability-console-v1")||"{}")?.custom||[]}catch{return []}})();
    return [...(data?.issues||[]),...local].find(x=>x.id===id)||null;
  }
  function draftForIssue(issue){
    if(!issue)return {title:"",symptoms:"",reproduction:"",expected:"",observed:"",modules:"",priority:"P1",evidence:"",body:""};
    return {title:issue.title||"",symptoms:issue.summary||"",reproduction:(issue.repro||[]).join("\n"),
      expected:"",observed:"",modules:(issue.files||[]).join("\n"),priority:issue.priority||"P1",
      evidence:"Audit record "+issue.id+": "+(issue.tests?.text||"Unknown")+
      (issue.tests?.url?"\nCI: "+issue.tests.url:"")+
      (issue.pr?"\nPR: https://github.com/"+REPO+"/pull/"+issue.pr:"")+
      "\nSuspected cause ("+issue.confidence+"): "+(issue.cause||"Unknown"),
      body:""};
  }
  function captureDraft(){
    if(memory.mode!=="compose")return;
    for(const key of ["title","symptoms","reproduction","expected","observed","modules","priority","evidence","body"]){
      const input=document.getElementById("ix-"+key);if(input)memory.draft[key]=input.value;
    }
    const ai=document.getElementById("ix-reflection-key");if(ai?.value)memory.reflectionKey=ai.value.trim();
  }
  function openComposer(issue=null){
    memory.originId=issue?.id||null;memory.draft=draftForIssue(issue);memory.published=null;memory.mode="compose";memory.returnTo=null;
    renderModal();
  }
  function openConnect(){
    captureDraft();memory.returnTo=memory.mode==="compose"?"compose":null;memory.mode="connect";renderModal();
  }
  function closeModal(){
    captureDraft();memory.mode=null;memory.busy=false;document.getElementById("issue-portal")?.remove();document.body.style.overflow="";
  }
  function renderModal(){
    document.getElementById("issue-portal")?.remove();
    if(!memory.mode){document.body.style.overflow="";return}
    document.body.style.overflow="hidden";
    const overlay=element("div","ix-overlay",memory.mode==="connect"?connectHTML():composeHTML());
    overlay.id="issue-portal";overlay.setAttribute("role","presentation");
    document.body.appendChild(overlay);
    overlay.addEventListener("click",e=>{if(e.target===overlay&&!memory.busy)closeModal()});
    const focus=overlay.querySelector(memory.mode==="connect"?"#ix-token":"#ix-title");
    focus?.focus({preventScroll:true});
  }
  function connectHTML(){
    return '<div class="ix-modal" style="max-width:640px" role="dialog" aria-modal="true" aria-label="Connect GitHub">'+
      '<div class="ix-head"><div><div class="kicker">Authenticated repository actions</div><h2>'+ph("github-logo")+' Connect GitHub</h2><p>Issue publishing uses GitHub’s actual REST API, attributed to your GitHub account. No shared deployment token.</p></div>'+
      '<button class="ix-close" data-ix="close" aria-label="Close">'+ph("x")+'</button></div>'+
      '<div class="ix-section"><div class="ix-section-head"><div class="ix-section-title"><img class="github-mark" src="./assets/github-mark.svg" alt=""> Repository permissions</div>'+badge(REPO)+'</div>'+
      '<p class="notice">Create a <a href="https://github.com/settings/personal-access-tokens/new" target="_blank" rel="noopener" style="color:var(--accent-ink)">fine-grained personal access token</a> restricted to <strong>'+REPO+'</strong> with <strong>Issues: read and write</strong>. This connection is not OAuth; the token is kept in tab memory only, sent over HTTPS to this app for GitHub API calls, and forgotten on refresh.</p>'+
      '<label class="field-label" for="ix-token" style="margin-top:20px">Fine-grained GitHub token</label><input type="password" class="field" id="ix-token" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="github_pat_…">'+
      '<div class="ix-action-compact" style="margin-top:17px"><button class="btn primary" data-ix="verify">'+ph("plug")+' Verify connection</button>'+
      (memory.token?'<button class="btn quiet" data-ix="disconnect">Disconnect</button>':"")+'</div><div id="ix-feedback" aria-live="polite"></div></div>'+
      (memory.githubUser?'<p class="ix-success">'+ph("check-circle")+' Connected as @'+esc(memory.githubUser)+'</p>':"")+'</div>';
  }
  function composeHTML(){
    const d=memory.draft;const v=k=>esc(d[k]||"");
    const connect=memory.githubUser?
      '<span class="badge good">'+ph("check-circle")+' @'+esc(memory.githubUser)+'</span>':
      '<span class="badge dimmed">'+ph("link-break")+' GitHub not connected</span>';
    if(memory.published){
      return '<div class="ix-modal" style="max-width:640px" role="dialog" aria-modal="true" aria-label="Issue created">'+
        '<div class="ix-head"><div><div class="kicker">GitHub confirms publication</div><h2>Issue #'+esc(memory.published.number)+' created</h2><p>Published to the real <strong>'+REPO+'</strong> repository as @'+esc(memory.githubUser||"your account")+'.</p></div>'+
        '<button class="ix-close" data-ix="close" aria-label="Close">'+ph("x")+'</button></div>'+
        '<div class="ix-section"><a class="ix-link" href="'+safeUrl(memory.published.number)+'" target="_blank" rel="noopener">'+ph("arrow-square-out")+' View issue #'+esc(memory.published.number)+' on GitHub</a><div class="ix-help">'+esc(memory.published.title)+'</div></div>'+
        '<div class="ix-action-compact"><button class="btn primary" data-ix="another">'+ph("plus")+' Create another</button><button class="btn" data-ix="close">Close</button></div></div>';
    }
    return '<div class="ix-modal" role="dialog" aria-modal="true" aria-label="Create GitHub issue">'+
      '<div class="ix-head"><div><div class="kicker">GitHub · '+REPO+'</div><h2>Create a real issue.</h2><p>Write directly, or use Reflection Beam to turn your evidence into a structured report. Review the result before publishing.</p></div>'+
      '<button class="ix-close" data-ix="close" aria-label="Close">'+ph("x")+'</button></div>'+
      '<div class="ix-section"><div class="ix-section-head"><div class="ix-section-title">'+ph("github-logo")+' Repository connection</div>'+connect+'</div>'+
      '<div class="ix-row-wrap"><button class="btn sm" data-ix="connect">'+ph(memory.token?"arrows-clockwise":"plug")+(memory.token?"Change GitHub token":"Connect GitHub")+'</button>'+
      '<span class="ix-help">Posting is disabled until a token with Issues: write access is verified.</span></div></div>'+
      '<div class="ix-section"><div class="ix-section-head"><div class="ix-section-title">'+ph("note-pencil")+' Issue details</div>'+
      (memory.originId?badge("From "+memory.originId):badge("New report"))+'</div>'+
      '<div><label class="field-label" for="ix-title">Title <span style="color:var(--bad)">*</span></label><input class="field" id="ix-title" maxlength="180" placeholder="State exactly what fails" value="'+v("title")+'"></div>'+
      '<div class="ix-grid" style="margin-top:18px"><div><label class="field-label" for="ix-symptoms">Problem / evidence</label><textarea class="textarea" id="ix-symptoms" rows="5" placeholder="Observed symptom and environment…">'+v("symptoms")+'</textarea></div>'+
      '<div><label class="field-label" for="ix-reproduction">Steps to reproduce</label><textarea class="textarea" id="ix-reproduction" rows="5" placeholder="One step per line; no guessed steps…">'+v("reproduction")+'</textarea></div></div>'+
      '<div class="ix-grid" style="margin-top:18px"><div><label class="field-label" for="ix-expected">Expected behavior</label><textarea class="textarea" id="ix-expected" rows="2" placeholder="What should happen?">'+v("expected")+'</textarea></div>'+
      '<div><label class="field-label" for="ix-observed">Actual behavior</label><textarea class="textarea" id="ix-observed" rows="2" placeholder="What actually happened?">'+v("observed")+'</textarea></div></div>'+
      '<div class="ix-grid" style="margin-top:18px"><div><label class="field-label" for="ix-modules">Affected modules (known only)</label><textarea class="textarea" id="ix-modules" rows="2" placeholder="Sources/LumenCapture/…">'+v("modules")+'</textarea></div>'+
      '<div><label class="field-label" for="ix-evidence">Logs and source links</label><textarea class="textarea" id="ix-evidence" rows="2" placeholder="CI run URL, commit, trace…">'+v("evidence")+'</textarea></div></div>'+
      '<div style="max-width:180px;margin-top:17px"><label class="field-label" for="ix-priority">Priority estimate</label><select class="select" id="ix-priority">'+["P0","P1","P2","P3"].map(p=>'<option '+(d.priority===p?"selected":"")+'>'+p+'</option>').join("")+'</select></div></div>'+
      '<div class="ix-section"><div class="ix-section-head"><div class="ix-section-title">'+ph("sparkle")+' AI issue writer <span class="badge orange">Reflection Beam</span></div><span class="ix-help">Optional</span></div>'+
      '<label class="field-label" for="ix-reflection-key">Reflection API key (optional when Vercel has a server key)</label>'+
      '<input class="field" type="password" id="ix-reflection-key" autocomplete="off" autocapitalize="off" placeholder="'+(memory.reflectionKey?"Key set for this tab":"Enter session-only Reflection API key")+'">'+
      '<p class="ix-help">Never stored in your browser or GitHub. The app sends it to its Vercel function, which forwards it to Reflection. A server-side key, when configured, is restricted to the repository owner.</p>'+
      '<div class="ix-action-compact" style="margin-top:16px"><button class="btn primary" id="ix-generate" data-ix="generate">'+ph("sparkle")+' Generate with Beam</button>'+
      '<button class="btn" data-ix="template">'+ph("text-align-left")+' Use evidence template</button></div></div>'+
      '<div class="ix-section"><div class="ix-section-head"><div class="ix-section-title">'+ph("file-text")+' GitHub issue body</div><span class="ix-help">Editable Markdown</span></div>'+
      '<textarea class="textarea ix-editor" id="ix-body" placeholder="Generate with Beam, use the evidence template, or write Markdown manually…">'+v("body")+'</textarea>'+
      '<div id="ix-feedback" class="ix-feedback" aria-live="polite"></div></div>'+
      '<div class="ix-footer"><span class="notice">The report is only published when you explicitly click Publish. No invented CI, merge or runtime evidence.</span>'+
      '<div class="ix-action-compact"><button class="btn" data-ix="close">Cancel</button><button class="btn primary ix-publish" id="ix-publish" data-ix="publish">'+ph("github-logo")+' Publish GitHub issue</button></div></div>'+
      '</div>';
  }
  function makeTemplate(d){
    const line=s=>String(s||"").trim()||"Not established";
    const steps=line(d.reproduction);
    return [
      "## Observed problem",line(d.symptoms||d.observed),"",
      "## Reproduction",steps==="Not established"?"To verify: reproducible steps and environment have not been documented.":steps.split("\n").filter(Boolean).map((s,i)=>(i+1)+". "+s.replace(/^\d+[.)]\s*/,"")).join("\n"),"",
      "## Expected behavior",line(d.expected),"",
      "## Actual behavior",line(d.observed||d.symptoms),"",
      "## Affected source files",line(d.modules),"",
      "## Evidence",line(d.evidence),"",
      "## Priority",line(d.priority)+" (initial estimate)","",
      "## Acceptance criteria","- Reproduce the reported failure on the current source revision.",
      "- Add a deterministic regression test for the confirmed failure where possible.",
      "- Make the smallest source change and document what was verified.",
      "- Run the applicable Swift build, tests and release gates on macOS; distinguish hardware tests.",
      "- Link the resulting PR and verify the exact merge status before claiming completion.","",
      "## Unknowns","Exact root cause and final device verification are not established unless independently evidenced."
    ].join("\n");
  }
  async function verify(){
    if(memory.busy)return;
    const token=document.getElementById("ix-token")?.value.trim();
    if(!token){feedback("Enter a fine-grained GitHub token first.");return}
    memory.busy=true;const button=document.querySelector('[data-ix="verify"]');if(button){button.disabled=true;button.textContent="Checking GitHub…"}
    try{
      const r=await fetch("/api/github",{method:"POST",headers:{"Authorization":"Bearer "+token,"Content-Type":"application/json"},
        body:JSON.stringify({action:"verify"})});
      const payload=await r.json();
      if(!r.ok)throw Error(payload.error||"GitHub rejected this token");
      memory.token=token;memory.githubUser=payload.login;memory.busy=false;
      const returnTo=memory.returnTo;memory.returnTo=null;
      if(returnTo==="compose")memory.mode="compose";else memory.mode=null;
      renderModal();decorate();refreshIssues();
      notify("Connected to GitHub as @"+payload.login);
    }catch(e){memory.busy=false;feedback(String(e.message||e));if(button){button.disabled=false;button.innerHTML=ph("plug")+" Verify connection"}}
  }
  async function publish(){
    if(memory.busy)return;
    captureDraft();const d=memory.draft;
    if(!memory.token){feedback("Connect GitHub with Issues: write permissions before publishing.");return}
    if(!d.title?.trim()||d.title.trim().length<6){feedback("Enter a precise title of at least 6 characters.");return}
    if(!d.body?.trim()){feedback("The Markdown body is empty. Generate or write the issue first.");return}
    memory.busy=true;const button=document.getElementById("ix-publish");if(button){button.disabled=true;button.innerHTML=ph("spinner-gap")+" Publishing…"}
    try{
      const r=await fetch("/api/github",{method:"POST",headers:{"Authorization":"Bearer "+memory.token,"Content-Type":"application/json"},
        body:JSON.stringify({action:"create",title:d.title.trim(),body:d.body.trim()})});
      const json=await r.json();
      if(!r.ok)throw Error(json.error||"GitHub did not create the issue");
      memory.published=json;memory.busy=false;renderModal();refreshIssues();
      notify("GitHub issue #"+json.number+" published");
    }catch(e){memory.busy=false;feedback(String(e.message||e));if(button){button.disabled=false;button.innerHTML=ph("github-logo")+" Publish GitHub issue"}}
  }
  async function generate(){
    if(memory.busy)return;
    captureDraft();const d=memory.draft;
    if(!d.title?.trim()||!(d.symptoms?.trim()||d.observed?.trim())){feedback("Add a precise title and actual observed problem before asking the model.");return}
    memory.busy=true;
    const btn=document.getElementById("ix-generate");
    const ta=document.getElementById("ix-body");
    if(btn){btn.disabled=true;btn.innerHTML=ph("spinner-gap")+" Writing…"}
    if(ta){ta.value="";ta.disabled=true}
    feedback("Connecting to Reflection Beam…","success");
    try{
      const headers={"Content-Type":"application/json"};
      if(memory.reflectionKey)headers["X-Reflection-Key"]=memory.reflectionKey;
      if(memory.token)headers["X-GitHub-Token"]=memory.token;
      const r=await fetch("/api/ai",{method:"POST",headers,body:JSON.stringify(d)});
      if(!r.ok){const j=await r.json().catch(()=>({}));throw Error(j.error||"Reflection request failed ("+r.status+")")}
      const reader=r.body?.getReader();if(!reader)throw Error("Streaming response unavailable");
      const decoder=new TextDecoder();let buffer="",count=0,finalError=null;
      function parseFrame(frame){
        const event=frame.match(/^event:\s*(.+)$/m)?.[1]||"token";
        const content=frame.match(/^data:\s*(.+)$/m)?.[1];
        if(!content)return;
        const payload=JSON.parse(content);
        if(event==="error"){finalError=payload.error||"Model stopped early";return}
        if(event==="token"&&typeof payload.content==="string"){count+=payload.content.length;if(ta){ta.value+=payload.content;ta.scrollTop=ta.scrollHeight}}
      }
      while(true){
        const next=await reader.read();if(next.done)break;
        buffer+=decoder.decode(next.value,{stream:true}).replace(/\r\n/g,"\n");
        let at;while((at=buffer.indexOf("\n\n"))!==-1){
          const frame=buffer.slice(0,at);buffer=buffer.slice(at+2);
          try{parseFrame(frame)}catch(e){finalError=String(e.message||e)}
        }
        if(finalError){try{reader.cancel()}catch{}break}
      }
      memory.draft.body=ta?.value||"";
      if(finalError)throw Error(finalError);
      if(count<30)throw Error("Model returned no usable issue body");
      feedback("Generated "+count+" characters. Review and edit before publishing.","success");
    }catch(e){feedback(String(e.message||e))}
    finally{
      memory.busy=false;
      if(btn){btn.disabled=false;btn.innerHTML=ph("sparkle")+" Generate with Beam"}
      if(ta)ta.disabled=false;
    }
  }
  function notify(s){
    let e=document.querySelector(".ix-toast");
    e?.remove();e=element("div","toast ix-toast",esc(s));e.setAttribute("role","status");document.body.appendChild(e);setTimeout(()=>e.remove(),3000)
  }
  async function refreshIssues(){
    if(memory.fetching)return;
    memory.fetching=true;
    try{
      const headers={};if(memory.token)headers.Authorization="Bearer "+memory.token;
      const res=await fetch("/api/github?resource=issues",{headers,cache:"no-store"});
      const json=await res.json();
      if(!res.ok)throw Error(json.error||"Could not load GitHub issues");
      memory.issues=Array.isArray(json.issues)?json.issues:[];
      memory.lastSync=new Date().toISOString();memory.lastError=null;
    }catch(e){memory.lastError=String(e.message||e)}
    finally{memory.fetching=false;decorate()}
  }
  function issuesSection(){
    const count=memory.issues===null?"Checking":memory.issues.length;
    const latest=(memory.issues||[]).slice(0,5);
    const state=memory.issues===null?
      '<div class="remote-empty">Loading live issues from GitHub…</div>':
      memory.lastError?'<div class="remote-error">'+esc(memory.lastError)+'</div>':
      !latest.length?'<div class="remote-empty">No GitHub issues were returned for '+REPO+'. Audit findings below are source inspections, not GitHub issue numbers.</div>':
      '<div class="remote-list">'+latest.map(x=>'<a class="remote-row" href="'+safeUrl(x.number)+'" target="_blank" rel="noopener">'+
        '<img class="github-mark" src="./assets/github-mark.svg" alt=""><div class="remote-body"><div class="remote-title">#'+esc(x.number)+' · '+esc(x.title)+'</div>'+
        '<div class="remote-meta">Opened by @'+esc(x.user||"unknown")+' · '+esc(new Date(x.updated_at).toLocaleDateString())+' · '+esc(x.comments||0)+' comments</div></div>'+
        badge(x.state==="open"?"Open":"Closed",x.state==="open"?"good":"dimmed")+ph("arrow-square-out")+'</a>').join("")+'</div>';
    return '<section class="remote-section" id="live-issues-section"><div class="remote-head"><div><h2>'+ph("github-logo")+' GitHub issues '+badge(String(count)+" live",memory.lastError?"rose":"green")+'</h2>'+
      '<p class="remote-sub">Actual repository issues from the GitHub API. The source-audit findings below are tracked separately.</p></div>'+
      '<div class="ix-action-compact"><button class="btn sm" data-ix="refresh">'+ph("arrows-clockwise")+' Refresh</button><button class="btn primary sm" data-ix="new">'+ph("plus")+' Create issue</button></div></div>'+
      state+'</section>';
  }
  let decorating=false;
  function decorate(){
    if(decorating)return;
    decorating=true;
    try{
      const nav=root.querySelector(".nav-list");
      if(nav&&!nav.querySelector("#ix-nav-issue")){
        const button=element("button","nav-item nav-link-write",
          '<span class="nav-ic">'+PLUS_ONE_SVG+'</span><span class="nav-text">Create issue</span>');
        button.id="ix-nav-issue";button.type="button";button.setAttribute("data-ix","new");
        nav.appendChild(button);
      }
      const top=root.querySelector(".top-actions");
      if(top&&!top.querySelector("#ix-connect-top")){
        const b=element("button","btn sm",'<img class="github-mark" src="./assets/github-mark.svg" alt=""> '+(memory.githubUser?"@"+esc(memory.githubUser):"Connect GitHub"));
        b.id="ix-connect-top";b.type="button";b.setAttribute("data-ix","connect");
        top.insertBefore(b,top.firstChild);
      }
      const head=root.querySelector(".head-action");
      if(head&&!head.querySelector("#ix-create-top")){
        const b=element("button","btn sm primary",ph("plus")+' GitHub issue');
        b.id="ix-create-top";b.type="button";b.setAttribute("data-ix","new");head.insertBefore(b,head.firstChild);
      }
      const area=root.querySelector(".page .workspace");
      if(area&&!root.querySelector("#live-issues-section")){
        area.insertAdjacentHTML("beforebegin",issuesSection());
      }
      const detail=root.querySelector("#issue-detail .detail-actions");
      if(detail&&!detail.querySelector("#ix-create-from")){
        const b=element("button","btn sm",ph("github-logo")+' Draft GitHub issue');b.type="button";b.id="ix-create-from";b.setAttribute("data-ix","from-selected");detail.appendChild(b);
      }
      const bar=root.querySelector(".agent-prompt .prompt-toolbar");
      if(bar&&!bar.querySelector("#ix-create-from-agent")){
        const b=element("button","btn sm",ph("github-logo")+' Open GitHub draft');b.type="button";b.id="ix-create-from-agent";
        b.setAttribute("data-ix","from-selected");bar.appendChild(b);
      }
    }finally{decorating=false}
  }
  let scheduled=false;
  const observer=new MutationObserver(()=>{
    if(scheduled)return;scheduled=true;
    queueMicrotask(()=>{scheduled=false;decorate()});
  });
  observer.observe(root,{subtree:true,childList:true});
  root.addEventListener("click",e=>{
    if(e.target.closest('[data-action="new"]')){
      e.preventDefault();e.stopImmediatePropagation();openComposer();return;
    }
  },true);
  document.addEventListener("click",e=>{
    const b=e.target.closest("[data-ix]");if(!b)return;
    e.preventDefault();
    switch(b.dataset.ix){
      case "close":if(!memory.busy)closeModal();break;
      case "new":openComposer();break;
      case "from-selected":openComposer(selectedIssue());break;
      case "connect":openConnect();break;
      case "disconnect":
        memory.token=null;memory.githubUser=null;renderModal();decorate();refreshIssues();notify("GitHub token disconnected");break;
      case "verify":verify();break;
      case "publish":publish();break;
      case "generate":generate();break;
      case "template":
        captureDraft();memory.draft.body=makeTemplate(memory.draft);
        const ta=document.getElementById("ix-body");if(ta)ta.value=memory.draft.body;
        feedback("Evidence-based Markdown prepared. Review and publish when ready.","success");break;
      case "another":openComposer();break;
      case "refresh":refreshIssues();break;
    }
  });
  document.addEventListener("keydown",e=>{
    if(e.key==="Escape"&&memory.mode&&!memory.busy){e.stopPropagation();closeModal()}
  });
  root.addEventListener("click",e=>{
    if(e.target.closest('[data-action="sync"]')){setTimeout(refreshIssues,180)}
  });
  decorate();refreshIssues();
})();