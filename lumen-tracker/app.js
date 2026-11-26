(() => {
  "use strict";

  const seed = window.LUMEN_SEED;
  const REPO = seed.repository;
  const GH = "https://github.com/" + REPO;
  const API = "https://api.github.com/repos/" + REPO;
  const KEY = "lumen-reliability-console-v1";
  const app = document.getElementById("app");

  const AREAS = ["All", "Build", "Recording", "Transcription", "Paste", "Recovery", "Audio", "Zoom", "Motion", "Framing", "Export"];
  const RANK = { P0: 0, P1: 1, P2: 2, P3: 3 };
  const PRIORITY = {
    P0: { label: "Blocker", steps: 4, glyph: "cross", kind: "bad" },
    P1: { label: "Gate", steps: 3, glyph: "bar", kind: "accent" },
    P2: { label: "Watch", steps: 2, glyph: "dot", kind: "ok" },
    P3: { label: "Note", steps: 1, glyph: "dot", kind: "neutral" }
  };
  const PRIO_PIX = { bad: "cross", ok: "check", accent: "bar", neutral: "dot", run: "dot" };
  const TITLES = { overview: "Reliability", issues: "Issue map", agent: "Agent workspace", regressions: "Regression log" };
  const SUBS = {
    overview: "What ships, what breaks, and what is still a hypothesis.",
    issues: "Audit findings with test evidence and merge status.",
    agent: "Work orders for coding agents.",
    regressions: "Observations that never pass as release proof."
  };
  const NAV_ICON = { overview: "dashboard", issues: "issues", agent: "agent", regressions: "history" };
  /* Clove's instrument language: every mark is an integer bitmap, drawn with
     square cells and `shape-rendering: crispEdges`. No paths, no glyph font. */
  const PIX = {
    dashboard: ["###...###", "###...###", "###...###", ".........", ".........", ".........", "###...###", "###...###", "###...###"],
    issues:    ["..#####..", ".##...##.", "##.....##", "##..#..##", "##.....##", "##..#..##", "##.....##", ".##...##.", "..#####.."],
    agent:     ["..#####..", ".#######.", "##.###.##", "##.###.##", "#########", "##.###.##", ".##...##.", "##.....##", "##.....##"],
    history:   ["..#####..", ".##...##.", "##.....##", "##..##.##", "##..##.##", "##.....##", ".##...##.", "..#####..", "........."],
    sync:      [".#######.", "##.....##", "#.......#", "#..###..#", "#..#.#..#", "#..###..#", "#.......#", "##.....##", ".#####..."],
    plus:      ["....#....", "....#....", "....#....", "#########", "#########", "....#....", "....#....", "....#....", "........."],
    search:    ["..#####..", ".##...##.", "##.....##", "##.....##", "##.....##", ".##...##.", "..#####..", "....##...", "....##..."],
    cross:     ["##.....##", ".##...##.", "..##.##..", "...###...", "...###...", "..##.##..", ".##...##.", "##.....##", "........."],
    check:     ["........#", ".......##", "......##.", "#....##..", ".#..##...", "..###....", "...#.....", ".........", "........."],
    dot:       [".........", ".........", ".........", "....###..", "....###..", "....###..", ".........", ".........", "........."],
    bar:       ["....###..", "....###..", "....###..", "....###..", "....###..", "....###..", "....###..", "....###..", "........."],
    github:    ["..#####..", ".#######.", "##.###.##", "##.###.##", "#########", "#########", ".#######.", ".##...##.", "##.....##"],
    aperture:  ["###", "#.#", "###"],
    wave:      ["#........", "##.......", ".##......", "..##.##...", "...####..", "..##.##..", ".##...##.", "##.....##", "#.......#"],
    back:      ["....#....", "...##....", "..###....", ".#######.", "#########", "..###....", "...##....", "....#....", "........."],
    frame:     ["#########", "##.....##", "##.....##", "##.....##", "##.....##", "##.....##", "##.....##", "##.....##", "#########"],
    up:        ["....#....", "...###...", "..#####..", "....#....", "....#....", "....#....", "....#....", "....#....", "........."],
    clipboard: ["..#####..", ".##...##.", "##.....##", "##.....##", "##.....##", ".##...##.", "..#####..", "....#....", "....#...."]
  };
  const AREA_PIX = { All: "dot", Build: "bar", Recording: "wave", Transcription: "clipboard", Paste: "clipboard", Recovery: "back", Audio: "wave", Zoom: "search", Motion: "plus", Framing: "frame", Export: "up" };
  const pix = (name, size = 12) => {
    const rows = PIX[name] || PIX.dot;
    let minX = 99, maxX = -1, minY = 99, maxY = -1, d = "";
    rows.forEach((row, y) => [...row].forEach((ch, x) => {
      if (ch !== "#") return;
      minX = Math.min(minX, x); maxX = Math.max(maxX, x);
      minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      d += `M${x} ${y}h1v1h-1z`;
    }));
    if (maxX < 0) return "";
    return `<svg class="pix-svg" viewBox="${minX} ${minY} ${maxX - minX + 1} ${maxY - minY + 1}" width="${size}" height="${size}" shape-rendering="crispEdges" aria-hidden="true"><path fill="currentColor" d="${d}"/></svg>`;
  };
  const NAV_SVG = {
    dashboard: pix("dashboard", 16), issues: pix("issues", 16), agent: pix("agent", 16), history: pix("history", 16),
    sync: pix("sync", 14), "plus-one": pix("plus", 14)
  };
  const SYSTEM_LOGS = [
    { id: "CI-2026-11-13-PR22", issue: "PR #22", result: "FAIL", date: "2026-11-13T11:00:55Z", text: "Draft PR #22 at 1b8fe64: 219 tests ran; Agent3Tests expected four tools but received five.", url: "https://github.com/duggal1/lumen/actions/runs/43413001450", system: true },
    { id: "CI-2026-11-13-MAIN", issue: "LUM-001", result: "FAIL", date: "2026-11-13T09:34:09Z", text: "Main d8d32ff failed swift build: SCShareableContent is non-Sendable at Runner.swift:266; downstream tests and packaging skipped.", url: "https://github.com/duggal1/lumen/actions/runs/43402399453", system: true },
    { id: "CI-2026-11-06", issue: "LUM-001", result: "FAIL", date: "2026-11-06T10:34:31Z", text: "main af807d3: swift build failed at EditorModel.swift:381; downstream tests and packaging skipped.", url: "https://github.com/duggal1/lumen/actions/runs/42203513453", system: true },
    { id: "CI-2026-11-06-2", issue: "LUM-001", result: "FAIL", date: "2026-11-06T08:43:02Z", text: "Prior main revision 09ff779 also failed Build debug; exact error not independently established here.", url: "https://github.com/duggal1/lumen/actions/runs/42189670036", system: true },
    { id: "CI-2026-11-05", issue: "LUM-005", result: "PASS", date: "2026-11-05T21:46:11Z", text: "Earlier main revision 065b484 passed Swift verification; does not validate Nov 6 changes.", url: "https://github.com/duggal1/lumen/actions/runs/42115618589", system: true }
  ];

  /* ───────── helpers ───────── */
  const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const $ = id => document.getElementById(id);
  const ICON_PIX = { "magnifying-glass": "search", x: "cross", "check-circle": "check", "link-break": "cross", plug: "plus", "note-pencil": "bar", sparkle: "dot", "file-text": "bar", "arrow-square-out": "plus", "text-align-left": "bar", "github-logo": "github", "arrows-clockwise": "sync", plus: "plus" };
  const ic = n => pix(ICON_PIX[n] || "dot", 12);
  const badge = (t, c = "neutral", wrap = false) => '<span class="badge ' + c + (wrap ? " wrap" : "") + '">' + pix(PRIO_PIX[c] || "dot", 8) + "<span>" + esc(t) + "</span></span>";
  const pad = n => String(n).padStart(2, "0");
  const issueUrl = n => GH + "/issues/" + encodeURIComponent(n);
  const GH_MARK = pix("github", 14);
  const CHECK = pix("check", 12);
  const stamp = iso => {
    if (!iso) return "Unknown";
    const d = new Date(iso);
    return Number.isNaN(+d) ? "Unknown" : d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  };

  /* ───────── state ───────── */
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch {}
  const store = {
    custom: Array.isArray(saved.custom) ? saved.custom : [],
    notes: saved.notes && typeof saved.notes === "object" ? saved.notes : {},
    logs: Array.isArray(saved.logs) ? saved.logs : []
  };
  const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(store)); } catch { toast("Storage unavailable. Export your data."); } };

  const state = { view: "overview", selected: seed.issues[0] && seed.issues[0].id, query: "", filter: "All", ci: null, prs: null, activity: null, syncTime: null, syncing: false, issues: null, issuesError: null };
  const auth = { token: null, user: null, key: null };
  const ui = { modal: null, busy: false, draft: { title: "", body: "" }, ctx: null, originId: null, published: null, backTo: null, hint: "" };

  const all = () => seed.issues;
  const issue = id => all().find(x => x.id === id) || all()[0];
  const cmp = (a, b) => (RANK[a.priority] ?? 3) - (RANK[b.priority] ?? 3) || (b.state === "blocked") - (a.state === "blocked") || a.id.localeCompare(b.id);
  const ladder = n => '<span class="px-ladder" aria-hidden="true">' + Array.from({ length: 4 }, (_, k) => '<i class="' + (k < n ? "on" : "") + '"></i>').join("") + "</span>";
  const prio = i => {
    const p = PRIORITY[i.priority] || PRIORITY.P3;
    return '<span class="badge prio ' + p.kind + '" title="Priority ' + esc(i.priority) + '" aria-label="Priority ' + esc(i.priority) + ', ' + p.label + '">' +
      pix(p.glyph, 8) + ladder(p.steps) + "<span>" + p.label + '</span><span class="prio-code">' + esc(i.priority) + "</span></span>";
  };

  function codeStatus(i) {
    const p = i.pr != null && state.prs && state.prs[i.pr];
    if (p) return p.merged_at
      ? { label: "Merged (live)", color: "neutral", merged: true, source: "GitHub live" }
      : { label: p.state === "open" ? "PR open" : "Closed unmerged", color: p.state === "open" ? "neutral" : "bad", merged: false, source: "GitHub live" };
    if (i.pr != null && i.code === "merged") return { label: "Merged (snapshot)", color: "neutral", merged: true, source: "GitHub snapshot" };
    if (i.code === "merged" && i.commit) return { label: "On main (snapshot)", color: "neutral", merged: true, source: "Git history snapshot" };
    if (i.code === "unknown") return { label: "Scope unknown", color: "neutral", merged: false, source: "unverified" };
    return { label: "Plan only", color: "neutral", merged: false, source: "not merged" };
  }

  const causeOf = i => i.confidence === "confirmed" ? ["Cause confirmed", "neutral"] : i.confidence === "tentative" ? ["Cause tentative", "neutral"] : ["Cause unknown", "neutral"];

  function ciInfo() {
    const ci = state.ci || { status: "unknown", stage: "Waiting for GitHub" }, s = ci.status;
    const kind = s === "success" ? "ok"
      : ["failure", "timed_out", "cancelled", "startup_failure"].includes(s) ? "bad"
      : ["in_progress", "queued", "waiting", "pending", "requested"].includes(s) ? "run" : "unk";
    return { ...ci, kind, word: { ok: "Passed", bad: "Failed", run: "Running", unk: "Unknown" }[kind], foot: { ok: "passing", bad: "failing", run: "running", unk: "unknown" }[kind] };
  }

  const testColor = k => k === "failed" ? "bad" : k === "historical-pass" ? "ok" : "neutral";

  function filtered() {
    const q = state.query.trim().toLowerCase();
    return all().filter(i => (state.filter === "All" || i.area === state.filter) &&
      (!q || [i.id, i.title, i.area, i.summary, i.cause, i.impact, i.confidence, ...(i.files || []), ...(i.repro || []), ...(i.fix || [])].join(" ").toLowerCase().includes(q))
    ).sort(cmp);
  }

  /* ───────── custom dropdown ───────── */
  function dd(id, value, options, name) {
    const o = options.map(x => Array.isArray(x) ? { v: x[0], l: x[1] } : { v: x, l: x });
    const cur = o.find(x => x.v === value) || o[0];
    return '<div class="dd"><input type="hidden" id="' + id + '"' + (name ? ' name="' + name + '"' : "") + ' value="' + esc(cur.v) + '">' +
      '<button type="button" class="dd-btn" data-dd="' + id + '" data-options="' + esc(JSON.stringify(o)) + '" aria-haspopup="listbox" aria-expanded="false"><span>' + esc(cur.l) + "</span></button></div>";
  }

  const menu = { el: null, btn: null, input: null, opts: [], i: 0 };

  function openMenu(btn) {
    closeMenu();
    const input = $(btn.dataset.dd);
    const opts = JSON.parse(btn.dataset.options);
    const i = Math.max(0, opts.findIndex(o => o.v === input.value));
    const el = document.createElement("div");
    el.className = "menu";
    el.setAttribute("role", "listbox");
    el.innerHTML = '<div class="menu-hl"></div>' + opts.map((o, n) =>
      '<button type="button" class="menu-row" role="option" aria-selected="' + (n === i) + '" data-i="' + n + '"><span>' + esc(o.l) + "</span><b>" + (n === i ? CHECK : "") + "</b></button>").join("");
    document.body.appendChild(el);
    Object.assign(menu, { el, btn, input, opts, i });
    btn.classList.add("open");
    btn.setAttribute("aria-expanded", "true");
    const r = btn.getBoundingClientRect();
    el.style.minWidth = Math.max(r.width, 200) + "px";
    const w = el.offsetWidth, h = el.offsetHeight;
    let top = r.bottom + 6;
    if (top + h > innerHeight - 8) top = Math.max(8, r.top - 6 - h);
    el.style.top = top + "px";
    el.style.left = Math.min(Math.max(8, r.left), Math.max(8, innerWidth - w - 8)) + "px";
    moveHl();
    requestAnimationFrame(() => el.classList.add("ready"));
  }

  function moveHl() {
    const row = menu.el.querySelectorAll(".menu-row")[menu.i];
    const hl = menu.el.querySelector(".menu-hl");
    hl.style.transform = "translateY(" + row.offsetTop + "px)";
    hl.style.height = row.offsetHeight + "px";
    row.scrollIntoView({ block: "nearest" });
  }

  function closeMenu(refocus) {
    if (!menu.el) return;
    menu.el.remove();
    if (menu.btn) { menu.btn.classList.remove("open"); menu.btn.setAttribute("aria-expanded", "false"); if (refocus && menu.btn.isConnected) menu.btn.focus(); }
    menu.el = menu.btn = menu.input = null;
  }

  function pickOption(n) {
    const o = menu.opts[n];
    if (!o) return;
    menu.input.value = o.v;
    menu.btn.firstElementChild.textContent = o.l;
    menu.input.dispatchEvent(new Event("change", { bubbles: true }));
    closeMenu(true);
  }

  function menuKey(e) {
    const last = menu.opts.length - 1;
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeMenu(true); return; }
    if (e.key === "Tab") { closeMenu(); return; }
    if (e.key === "ArrowDown") menu.i = menu.i >= last ? 0 : menu.i + 1;
    else if (e.key === "ArrowUp") menu.i = menu.i <= 0 ? last : menu.i - 1;
    else if (e.key === "Home") menu.i = 0;
    else if (e.key === "End") menu.i = last;
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pickOption(menu.i); return; }
    else return;
    e.preventDefault();
    moveHl();
  }

  /* ───────── shell + views ───────── */
  function nav(id, label, count) {
    return '<button type="button" class="nav-item' + (state.view === id ? " on" : "") + '" data-a="view" data-view="' + id + '" title="' + label + '"><span class="nav-ic">' + (NAV_SVG[NAV_ICON[id]] || "") + '</span><span class="nav-text">' + label + "</span>" + (count != null ? '<span class="nav-count">' + count + "</span>" : "") + "</button>";
  }

  function shell() {
    const ci = ciInfo(), v = state.view;
    const body = v === "overview" ? overview() : v === "issues" ? issueWorkspace() : v === "agent" ? agent() : regressions();
    const headPrimary = v === "overview" || v === "issues";
    return '<div class="shell"><aside class="side">' +
      '<button type="button" class="brand" data-a="view" data-view="overview" aria-label="Lumen, overview"><img class="brand-logo" src="./assets/lumen.svg" alt="Lumen" width="112" height="32"><span class="brand-sub">Reliability<br>engineering</span></button>' +
      '<nav aria-label="Primary"><div class="nav-label">Workspace</div><div class="nav-list">' +
        nav("overview", "Overview") + nav("issues", "Issue map", all().length) + nav("agent", "Agent workspace") + nav("regressions", "Regression log", store.logs.length) +
      "</div></nav>" +
      '<div class="side-foot"><span class="pix ' + (ci.kind === "ok" || ci.kind === "bad" ? ci.kind : "") + '">' + pix("dot", 6) + '</span><span' + (ci.kind === "run" ? ' class="shimmer"' : "") + ">Main build " + ci.foot + "</span></div></aside>" +
      '<main class="main"><header class="top"><div class="crumb"><span>lumen</span><i>/</i><strong>' + TITLES[v] + '</strong><i>/</i><span>main</span></div>' +
        '<div class="top-r"><span class="muted">' + (state.syncTime ? "Live check " + esc(stamp(state.syncTime)) : "Snapshot") + "</span>" +
        '<button class="btn sm" data-a="connect" type="button">' + GH_MARK + (auth.user ? "@" + esc(auth.user) : "Connect GitHub") + "</button>" +
        '<button class="btn sm" id="sync-btn" data-a="sync" type="button"><span class="wait" aria-hidden="true"><i></i><i></i><i></i></span>' + NAV_SVG.sync + '<span id="sync-label">Sync GitHub</span></button></div></header>' +
      '<div class="page"><div class="head"><div><h1 class="title">' + TITLES[v] + '<span class="aperture">' + pix("aperture", 7) + "</span></h1><p class=\"sub\">" + SUBS[v] + "</p></div>" +
        '<div class="head-r"><button class="btn' + (headPrimary ? " primary" : "") + '" data-a="compose" type="button">New issue</button></div></div>' +
        body + "</div></main></div>";
  }

  function overview() {
    const ci = ciInfo();
    const merged = all().filter(i => codeStatus(i).merged).length;
    const blocked = all().filter(i => i.state === "blocked").length;
    const verified = all().filter(i => store.notes[i.id] && store.notes[i.id].result === "manual-pass").length;
    const stats = [
      ["Latest CI on main", ci.word, ci.stage || "Swift verification", ci.kind],
      ["Source issues", pad(all().length), blocked + " blocked", ""],
      ["Merged fixes", pad(merged), "Merged is not runtime verified", ""],
      ["Device verified", pad(verified), "Local notes, not release proof", ""]
    ];
    const next = all().slice().sort(cmp).filter(i => !codeStatus(i).merged).slice(0, 3);
    const activity = state.activity;
    const activityStates = activity
      ? '<div class="activity-state"><div class="activity-state-row"><div class="activity-state-head"><span>main</span><a class="activity-sha" href="' + GH + '/commit/' + encodeURIComponent(activity.head) + '" target="_blank" rel="noopener">' + esc(activity.head.slice(0, 7)) + '</a>' + badge(ci.word, ci.kind === "bad" ? "bad" : "neutral") + '</div><p>' + esc(ci.stage) + (ci.run ? ' <a class="activity-run" href="' + GH + '/actions/runs/' + encodeURIComponent(ci.run) + '" target="_blank" rel="noopener">Workflow</a>' : '') + '</p></div></div>'
      : '<div class="empty">Waiting for current GitHub activity.</div>';
    const activityEntries = activity ? activity.commits.map(commit => '<li class="activity-entry"><time class="activity-time">' + esc(stamp(commit.date)) + '</time><div class="activity-body"><div class="activity-title-row"><h3>' + esc(commit.message) + '</h3></div><div class="activity-links"><a href="' + GH + '/commit/' + encodeURIComponent(commit.sha) + '" target="_blank" rel="noopener">' + esc(commit.sha.slice(0, 7)) + '</a></div></div></li>').join("") : "";
    const openPulls = activity ? activity.openPulls.map(pr => '<li class="activity-entry"><div class="activity-body"><a href="' + GH + '/pull/' + encodeURIComponent(pr.number) + '" target="_blank" rel="noopener">#' + esc(pr.number) + ' ' + esc(pr.title) + '</a></div></li>').join("") : "";
    return '<div class="ledger">' + stats.map(s => '<div class="stat"><span class="stat-k">' + esc(s[0]) + '</span><strong class="stat-v' + (s[3] === "bad" ? " bad" : s[3] === "run" ? " shimmer" : "") + '">' + esc(s[1]) + '</strong><span class="stat-n">' + esc(s[2]) + "</span></div>").join("") + "</div>" +
      '<section class="block"><div class="block-h"><h2>Audit findings</h2><span class="muted">Historical snapshot · ranked by priority</span></div><div class="card list">' +
      (next.length ? next.map(i => '<button class="row" type="button" data-a="open" data-id="' + esc(i.id) + '">' + prio(i) +
        '<span class="row-m"><span class="row-t">' + esc(i.title) + '</span><span class="row-s">' + esc(i.impact) + '</span></span><span class="muted">' + esc(i.id) + "</span></button>").join("") : '<div class="empty">Every issue has a merged implementation.</div>') +
      "</div></section>" +
      '<section class="block"><div class="block-h"><h2>Recent code activity</h2><span class="muted">' + (state.syncTime ? 'Updated ' + esc(stamp(state.syncTime)) : 'Not yet synchronized') + '</span></div><div class="card activity-card">' +
      activityStates + '<ol class="activity-list">' + activityEntries + '</ol><div class="block-h"><h3>Open pull requests</h3></div><ol class="activity-list">' + (activity ? (openPulls || '<li class="activity-entry">No open pull requests</li>') : '') + '</ol></div></section>' + liveIssues();
  }

  function liveIssues() {
    const list = state.issues;
    const body = state.issuesError ? '<div class="empty bad">' + esc(state.issuesError) + "</div>"
      : list === null ? '<div class="empty">Loading issues from GitHub…</div>'
      : !list.length ? '<div class="empty">No GitHub issues in ' + esc(REPO) + ". Audit findings are tracked separately.</div>"
      : list.slice(0, 5).map(x => '<a class="row" href="' + issueUrl(x.number) + '" target="_blank" rel="noopener">' + GH_MARK + '<span class="row-m"><span class="row-t">#' + esc(x.number) + " " + esc(x.title) + '</span><span class="row-s">@' + esc(x.user || "unknown") + ", " +
        esc(new Date(x.updated_at).toLocaleDateString(undefined, { month: "short", day: "numeric" })) + ", " + esc(x.comments || 0) + " comments</span></span>" + badge(x.state === "open" ? "Open" : "Closed", "neutral") + "</a>").join("");
    return '<section class="block"><div class="block-h"><h2>GitHub issues' + (list === null && !state.issuesError ? "" : badge(state.issuesError ? "Error" : list.length + " live", state.issuesError ? "bad" : "neutral")) +
      '</h2><button class="btn sm" data-a="refresh" type="button">Refresh</button></div><div class="card list">' + body + "</div></section>";
  }

  function areaRail() {
    const counts = {};
    for (const i of all()) counts[i.area] = (counts[i.area] || 0) + 1;
    return '<nav class="areas" aria-label="Filter findings by area">' + AREAS.map(a =>
      '<button class="area' + (state.filter === a ? " on" : "") + '" data-a="filter" data-filter="' + esc(a) + '" type="button" aria-pressed="' + (state.filter === a) + '">' +
      '<span class="area-px">' + pix(AREA_PIX[a] || "dot", 12) + '</span><span class="area-n">' + esc(a) + '</span><span class="area-c">' + (a === "All" ? all().length : (counts[a] || 0)) + "</span></button>").join("") + "</nav>";
  }

  function issueWorkspace() {
    const list = filtered();
    return '<div class="split split-areas">' + areaRail() + '<section class="card"><div class="p-head"><h2 class="p-title">Audit findings<span class="n" id="issues-count">' + list.length + " / " + all().length + "</span></h2>" +
      '<div class="tools"><label class="search">' + ic("magnifying-glass") + '<input id="issue-search" autocomplete="off" value="' + esc(state.query) + '" placeholder="Search issues" aria-label="Search issues"><span class="keycap">/</span></label></div></div>' +
      '<table class="tbl"><colgroup><col class="c-pri"><col><col class="c-area"><col class="c-code"><col class="c-test"></colgroup><thead><tr><th>Priority</th><th>Issue</th><th>Area</th><th>Code</th><th>Tests</th></tr></thead><tbody id="issue-list">' + rows(list) + "</tbody></table>" +
      '<div class="t-foot">Select a row for evidence. Press / to search.</div></section>' +
      '<aside class="card detail" id="issue-detail">' + detail(issue(state.selected)) + "</aside></div>";
  }

  function rows(list) {
    if (!list.length) return '<tr><td colspan="5"><div class="empty">No matching issues.</div></td></tr>';
    return list.map(i => {
      const c = codeStatus(i), t = i.tests.kind;
      const label = { failed: "Failed", skipped: "Skipped", "historical-pass": "Earlier pass", blocked: "Blocked" }[t] || "Unverified";
      return '<tr class="entry' + (state.selected === i.id ? " on" : "") + '" data-issue="' + esc(i.id) + '" tabindex="0" aria-selected="' + (state.selected === i.id) + '">' +
        "<td>" + prio(i) + "</td>" +
        '<td><span class="issue-id">' + esc(i.id) + '</span><div class="issue-t" title="' + esc(i.title) + '">' + esc(i.title) + "</div></td>" +
        "<td>" + esc(i.area) + "</td><td>" + badge(c.label, c.color) + "</td><td>" + badge(label, testColor(t)) + "</td></tr>";
    }).join("");
  }

  function detail(i) {
    if (!i) return '<div class="empty">Select an issue.</div>';
    const c = codeStatus(i), n = store.notes[i.id] || {}, t = i.tests, cause = causeOf(i);
    const files = (i.files || []).length
      ? i.files.map(f => '<a class="file" href="' + GH + "/blob/main/" + encodeURI(f) + '" target="_blank" rel="noopener">' + esc(f) + "</a>").join("")
      : '<p class="muted">No owning source module established.</p>';
    return '<div class="d-top"><span class="muted">' + esc(i.id) + " / " + esc(i.area) + '</span><button class="btn quiet sm" data-a="agent" data-id="' + esc(i.id) + '" type="button">Agent work order</button></div>' +
      '<div class="d-badges">' + prio(i) + badge(c.label, c.color) + badge(cause[0], cause[1]) + "</div>" +
      "<h2>" + esc(i.title) + '</h2><p class="d-sum">' + esc(i.summary) + "</p>" +
      '<div class="d-block"><span class="lbl">Impact</span><p class="copy">' + esc(i.impact) + "</p></div>" +
      '<div class="d-block"><span class="lbl">Reproduce and verify</span><ol class="steps">' + (i.repro || []).map(x => "<li>" + esc(x) + "</li>").join("") + "</ol></div>" +
      '<div class="d-block"><span class="lbl">Suspected cause, ' + esc(i.confidence) + '</span><p class="copy">' + esc(i.cause) + "</p></div>" +
      '<div class="d-block"><span class="lbl">Affected files</span><div class="files">' + files + "</div></div>" +
      '<div class="d-block"><span class="lbl">CI and release evidence</span><div class="evidence nest">' + badge(t.text, testColor(t.kind), true) +
        "<p>Code: " + esc(c.label) + ", " + esc(c.source) + ". Device verification is separate.</p>" +
        (t.url ? '<a class="link" href="' + esc(t.url) + '" target="_blank" rel="noopener">Workflow run</a>' : "") +
        (i.pr ? '<a class="link" href="' + GH + "/pull/" + i.pr + '" target="_blank" rel="noopener">Pull request #' + i.pr + "</a>" : "") + "</div></div>" +
      '<div class="d-block"><span class="lbl">Your verification notes, stored in this browser</span>' +
        dd("local-result", n.result || "", [["", "Not recorded"], ["manual-pass", "Observed pass (local only)"], ["manual-fail", "Observed failure (local only)"]]) +
        '<textarea class="field" id="local-note" style="margin-top:8px" placeholder="Trace, hardware, reproduction or test output">' + esc(n.text || "") + "</textarea>" +
        '<div class="acts"><button class="btn sm" data-a="save-note" type="button">Save evidence</button><button class="btn sm quiet" data-a="regress" data-id="' + esc(i.id) + '" type="button">Log regression</button><button class="btn sm quiet" data-a="draft" type="button">' + GH_MARK + "Draft GitHub issue</button></div></div>";
  }

  /* ───────── agent workspace ───────── */
  function buildPrompt(i) {
    const c = codeStatus(i), ci = ciInfo(), manual = store.notes[i.id];
    const evidence = i.tests.url || (i.pr ? GH + "/pull/" + i.pr : "No CI/run link verified");
    const sourceFiles = (i.files || []).length ? i.files.map(x => "- " + x).join("\n") : "- UNKNOWN: first identify owning modules; do not invent file paths";
    return [
      "ROLE: Senior Swift 6 / Metal reliability engineer. Repository: " + REPO + ".",
      "TASK: " + i.id + " | " + i.title + " | " + i.priority + " | " + i.area,
      "",
      "AUTHORITATIVE STATE",
      "- Main snapshot at creation: " + seed.sourceSha + ". Re-fetch current main before editing.",
      "- Implementation: " + c.label + " (" + c.source + ").",
      "- Current CI: " + ci.status + " / " + (ci.stage || "unknown") + ".",
      "- Evidence: " + i.tests.text + ". Link: " + evidence,
      "- Root cause confidence: " + i.confidence + ".",
      "- Actual code tree uses Sources/. DO NOT rename it to studio/ or change directory conventions. Treat code as source of truth.",
      "",
      "OBSERVED OR REPORTED SYMPTOM",
      i.summary,
      "Impact: " + i.impact,
      "",
      "SUSPECTED CAUSE (NOT FACT UNLESS CONFIRMED)",
      i.cause,
      "",
      "REPRODUCTION AND ACCEPTANCE GATES",
      ...(i.repro || []).map((x, n) => (n + 1) + ". " + x),
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
      ...(i.fix || []).map((x, n) => (n + 1) + ". " + x),
      "",
      "REQUIRED FINAL REPORT",
      "Root cause [confirmed/tentative/unknown] | files changed | tests run with links/results | limitations | PR URL | merged_at or NOT MERGED | main SHA | remaining regressions.",
      "A PR number is not merge proof. A merge is not a CI pass. A CI pass is not a device reliability claim.",
      ...(manual && manual.text ? ["", "LOCAL OPERATOR NOTE (UNVERIFIED): " + manual.text] : [])
    ].join("\n");
  }

  function agent() {
    const i = issue(state.selected), c = codeStatus(i), cause = causeOf(i), q = all().slice().sort(cmp);
    return '<div class="agent"><aside class="card queue"><h2 class="p-title queue-h">Queue<span class="n">' + q.length + '</span></h2><div class="queue-list">' +
      q.map(x => '<button class="q-row' + (x.id === i.id ? " on" : "") + '" data-a="pick" data-id="' + esc(x.id) + '" type="button">' +
        '<span class="q-top"><span>' + esc(x.id) + " " + esc(x.area) + "</span>" + prio(x) + '</span><span class="q-title">' + esc(x.title) + "</span></button>").join("") +
      "</div></aside>" +
      '<section class="card prompt"><div class="pr-head"><div style="min-width:0"><h2 class="pr-title">' + esc(i.id) + " " + esc(i.title) + "</h2>" +
        '<div class="pr-badges">' + prio(i) + badge(i.area) + badge(c.label, c.color) + badge(cause[0], cause[1]) + "</div></div>" +
        '<div class="pr-acts"><button class="btn sm" data-a="draft" type="button">' + GH_MARK + 'Draft issue</button><button class="btn primary sm" data-a="copy-prompt" type="button">Copy prompt</button></div></div>' +
      '<textarea id="prompt-body" class="field prompt-text" spellcheck="false" aria-label="Implementation prompt">' + esc(buildPrompt(i)) + "</textarea>" +
      '<div class="pr-foot"><span class="notice">Edit before copying. This page never merges code or runs tests.</span>' +
        '<a class="link gh-link" href="' + (i.pr ? GH + "/pull/" + i.pr : GH + "/actions") + '" target="_blank" rel="noopener">' + GH_MARK + "GitHub evidence</a></div></section></div>";
  }

  /* ───────── regressions ───────── */
  function regressions() {
    const logs = [...store.logs, ...SYSTEM_LOGS].sort((a, b) => new Date(b.date) - new Date(a.date));
    const color = r => r === "FAIL" ? "bad" : r === "PASS" ? "ok" : "neutral";
    return '<div class="split reg"><section class="card form"><div class="p-head"><h2 class="p-title">Log an observation</h2>' + badge("Local only") + "</div>" +
      '<form id="reg-form"><div><span class="lbl">Linked issue</span>' + dd("reg-issue", state.selected, all().map(x => [x.id, x.id + " / " + x.area]), "issue") + "</div>" +
      '<div><span class="lbl">Outcome</span>' + dd("reg-result", "FAIL", [["FAIL", "Failure reproduced"], ["PASS", "Observed pass"], ["INCONCLUSIVE", "Inconclusive"]], "result") + "</div>" +
      '<div><label class="lbl" for="reg-text">Environment and actual result</label><textarea class="field" id="reg-text" name="text" style="min-height:150px" required placeholder="Device, OS, commit SHA, setup, exact failure, log link"></textarea></div>' +
      '<button class="btn primary" type="submit">Append observation</button><p class="notice">Manual logs never change merge state or the official CI status.</p></form></section>' +
      '<section class="card"><div class="p-head"><h2 class="p-title">History<span class="n">' + logs.length + '</span></h2><div class="tools"><button class="btn sm" data-a="import" type="button">Import</button><button class="btn sm" data-a="export" type="button">Export</button></div></div><div class="list">' +
      (logs.length ? logs.map(l => '<article class="log"><div class="log-top"><div class="log-tags">' + badge(l.result, color(l.result)) + '<span class="log-issue">' + esc(l.issue) + "</span>" + (l.system ? badge("CI evidence", "neutral") : badge("Local")) + '</div><span class="muted">' + esc(stamp(l.date)) + "</span></div>" +
        '<p class="log-note">' + esc(l.text) + '</p><div class="log-foot"><span class="muted">' + esc(l.id) + "</span>" +
        (l.url ? '<a class="link" href="' + esc(l.url) + '" target="_blank" rel="noopener">Workflow</a>' : !l.system ? '<button class="btn sm quiet" data-a="delete-log" data-id="' + esc(l.id) + '" type="button">Remove</button>' : "") + "</div></article>").join("") : '<div class="empty">No regression entries yet.</div>') +
      '</div></section></div><input type="file" id="import-file" accept="application/json,.json" hidden>';
  }

  function render() { closeMenu(); app.innerHTML = shell(); }
  function setView(v) { state.view = v; render(); scrollTo({ top: 0, behavior: "instant" }); }
  function selectRow(id) {
    state.selected = id;
    const l = $("issue-list"), d = $("issue-detail");
    if (l && d) { l.innerHTML = rows(filtered()); d.innerHTML = detail(issue(id)); } else render();
  }

  function toast(msg) {
    document.querySelector(".toast")?.remove();
    const el = document.createElement("div");
    el.className = "toast"; el.setAttribute("role", "status"); el.textContent = msg;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 3000);
  }

  /* ───────── GitHub sync ───────── */
  function setSync(on) {
    state.syncing = on;
    const b = $("sync-btn");
    if (!b) return;
    b.classList.toggle("busy", on);
    b.disabled = on;
    $("sync-label").textContent = on ? "Checking" : "Sync GitHub";
  }

  async function sync() {
    if (state.syncing) return;
    setSync(true);
    refreshIssues();
    try {
      const get = async p => {
        const r = await fetch(API + p, { headers: { Accept: "application/vnd.github+json" }, cache: "no-store" });
        if (!r.ok) throw Error("GitHub HTTP " + r.status);
        return r.json();
      };
      const [prs, openPrs, head, commits, runs] = await Promise.all([
        get("/pulls?state=all&per_page=100"), get("/pulls?state=open&per_page=100"), get("/commits/main"),
        get("/commits?sha=main&per_page=8"), get("/actions/runs?branch=main&event=push&per_page=100")
      ]);
      const map = {};
      for (const p of [...prs, ...openPrs]) map[p.number] = { state: p.state, merged_at: p.merged_at };
      state.prs = map;
      const latest = (runs.workflow_runs || []).find(x => x.name === "Swift verification" && x.head_branch === "main" && x.event === "push" && x.head_sha === head.sha);
      state.ci = latest
        ? { status: latest.conclusion || latest.status || "unknown", stage: "Swift verification", sha: head.sha, run: latest.id }
        : { status: "unknown", stage: "No verification run for this commit", sha: head.sha };
      state.activity = { head: head.sha, commits: commits.map(c => ({ sha: c.sha, message: (c.commit?.message || "").split("\n")[0], date: c.commit?.committer?.date })), openPulls: openPrs.map(p => ({ number: p.number, title: p.title })) };
      state.syncTime = new Date().toISOString();
      state.syncing = false; render();
      toast("GitHub metadata refreshed");
    } catch {
      state.syncing = false; render();
      toast("Sync failed. Showing the snapshot.");
    }
  }

  async function refreshIssues() {
    try {
      const headers = auth.token ? { Authorization: "Bearer " + auth.token } : {};
      const res = await fetch("/api/github?resource=issues", { headers, cache: "no-store" });
      const json = await res.json();
      if (!res.ok) throw Error(json.error || "Could not load GitHub issues");
      state.issues = Array.isArray(json.issues) ? json.issues : [];
      state.issuesError = null;
    } catch (e) { state.issuesError = String(e.message || e); }
    if (state.view === "overview") render();
  }

  /* ───────── local data ───────── */
  function exportData() {
    const payload = { schema: "lumen-reliability-console-v1", exportedAt: new Date().toISOString(), source: REPO, sourceSha: seed.sourceSha, custom: store.custom, notes: store.notes, logs: store.logs };
    const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url; a.download = "lumen-reliability-" + new Date().toISOString().slice(0, 10) + ".json";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("Exported");
  }

  async function importData(file) {
    if (!file) return;
    try {
      if (file.size > 2000000) throw Error("File exceeds 2 MB");
      const d = JSON.parse(await file.text());
      if (d.schema !== "lumen-reliability-console-v1" || d.source !== REPO || !Array.isArray(d.logs) || !d.notes || typeof d.notes !== "object") throw Error("Not a Lumen export");
      if (!confirm("Replace this browser's notes and regression log with the imported export?")) return;
      store.notes = d.notes; store.logs = d.logs;
      if (Array.isArray(d.custom)) store.custom = d.custom;
      persist(); render(); toast("Imported");
    } catch (e) { toast("Import rejected: " + String(e.message || e)); }
  }

  /* ───────── issue composer: title + description, nothing else ───────── */
  const SKELETON = "## Problem\n\n\n## Steps to reproduce\n1. \n\n## Expected\n\n\n## Actual\n";

  function bodyFor(i) {
    const steps = (i.repro || []).map((s, n) => (n + 1) + ". " + s).join("\n") || "Not established";
    const files = (i.files || []).map(f => "- " + f).join("\n") || "Not established";
    return [
      "## Problem", i.summary || "Not established", "",
      "## Steps to reproduce", steps, "",
      "## Affected files", files, "",
      "## Evidence",
      "Audit record " + i.id + ": " + ((i.tests && i.tests.text) || "Unknown"),
      ...(i.tests && i.tests.url ? ["CI: " + i.tests.url] : []),
      ...(i.pr ? ["PR: " + GH + "/pull/" + i.pr] : []),
      "Suspected cause (" + i.confidence + "): " + (i.cause || "Unknown"), "",
      "## Priority", i.priority + " (initial estimate)", "",
      "## Acceptance",
      "- Reproduce on the current source revision.",
      "- Add a regression test where possible.",
      "- Verify the exact merge and CI status before claiming completion."
    ].join("\n");
  }

  function ctxFor(i) {
    return {
      symptoms: i.summary || "", reproduction: (i.repro || []).join("\n"), modules: (i.files || []).join("\n"), priority: i.priority || "P1",
      evidence: "Audit record " + i.id + ": " + ((i.tests && i.tests.text) || "Unknown") + (i.tests && i.tests.url ? "\nCI: " + i.tests.url : "") +
        (i.pr ? "\nPR: " + GH + "/pull/" + i.pr : "") + "\nSuspected cause (" + i.confidence + "): " + (i.cause || "Unknown")
    };
  }

  function captureDraft() {
    if (ui.modal !== "compose") return;
    const t = $("ix-title"), b = $("ix-body");
    if (t) ui.draft.title = t.value;
    if (b) ui.draft.body = b.value;
  }

  function openCompose(i) {
    ui.originId = i ? i.id : null;
    ui.ctx = i ? ctxFor(i) : null;
    ui.draft = { title: i ? i.title : "", body: i ? bodyFor(i) : "" };
    ui.published = null; ui.backTo = null; ui.modal = "compose"; showModal();
  }
  function openConnect() {
    captureDraft(); ui.backTo = ui.modal === "compose" ? "compose" : null; ui.modal = "connect"; showModal();
  }
  function closeModal() { captureDraft(); ui.modal = null; ui.busy = false; showModal(); }
  function backFromConnect() { ui.modal = ui.backTo === "compose" ? "compose" : null; ui.backTo = null; showModal(); }

  function showModal() {
    closeMenu();
    $("modal")?.remove();
    document.body.style.overflow = ui.modal ? "hidden" : "";
    if (!ui.modal) return;
    const o = document.createElement("div");
    o.id = "modal"; o.className = "overlay";
    o.innerHTML = ui.modal === "connect" ? connectView() : ui.modal === "done" ? doneView() : composeView();
    o.addEventListener("pointerdown", e => { if (e.target === o && !ui.busy && !menu.el) actions.close(); });
    document.body.appendChild(o);
    o.querySelector("#ix-token, #ix-title")?.focus({ preventScroll: true });
  }

  function mHead(title, sub) {
    return '<div class="m-head"><div><h2>' + title + '</h2><p class="muted">' + sub + '</p></div><button class="x" data-a="close" type="button" aria-label="Close">' + ic("x") + "</button></div>";
  }

  function composeView() {
    const d = ui.draft;
    return '<div class="modal" role="dialog" aria-modal="true" aria-label="New GitHub issue">' +
      mHead("New GitHub issue", esc(REPO) + (ui.originId ? ", from " + esc(ui.originId) : "")) +
      '<div class="m-body">' +
        '<div><label class="lbl" for="ix-title">Title</label><input class="field" id="ix-title" maxlength="180" placeholder="State exactly what fails" value="' + esc(d.title) + '"></div>' +
        '<div><div class="lbl-row"><label class="lbl" for="ix-body">Description</label><div class="tools"><button class="btn sm" data-a="template" type="button">Template</button><button class="btn sm" id="ix-generate" data-a="generate" type="button">Write with Beam</button></div></div>' +
          '<textarea class="field body" id="ix-body" placeholder="What fails, how to reproduce it, what you expected. Markdown works.">' + esc(d.body) + "</textarea></div>" +
        '<div id="ix-feedback" class="fb" aria-live="polite"></div></div>' +
      '<div class="m-foot"><button class="btn quiet sm" data-a="connect" type="button">' + GH_MARK + (auth.user ? "@" + esc(auth.user) : "Connect GitHub") + "</button>" +
        '<div class="tools"><button class="btn" data-a="close" type="button">Cancel</button><button class="btn primary deep" id="ix-publish" data-a="publish" type="button">Publish issue</button></div></div></div>';
  }

  function connectView() {
    const hint = ui.hint || (auth.user ? "Connected as @" + auth.user : "");
    ui.hint = "";
    return '<div class="modal narrow" role="dialog" aria-modal="true" aria-label="Connect GitHub">' +
      mHead("Connect GitHub", 'Use a <a class="link" href="https://github.com/settings/personal-access-tokens/new" target="_blank" rel="noopener">fine-grained token</a> for ' + esc(REPO) + " with Issues: read and write.") +
      '<div class="m-body"><div><label class="lbl" for="ix-token">Token</label><input type="password" class="field" id="ix-token" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="github_pat_…"></div>' +
        '<div><label class="lbl" for="ix-key">Reflection API key, optional</label><input type="password" class="field" id="ix-key" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="' + (auth.key ? "Key set for this tab" : "Only needed for Write with Beam") + '"></div>' +
        '<div id="ix-feedback" class="fb" aria-live="polite">' + esc(hint) + "</div></div>" +
      '<div class="m-foot"><span class="muted">Kept in this tab only.</span><div class="tools">' + (auth.token ? '<button class="btn quiet" data-a="disconnect" type="button">Disconnect</button>' : "") +
        '<button class="btn" data-a="close" type="button">Cancel</button><button class="btn primary" data-a="verify" type="button">Verify</button></div></div></div>';
  }

  function doneView() {
    const p = ui.published;
    return '<div class="modal narrow" role="dialog" aria-modal="true" aria-label="Issue created">' +
      mHead("Issue #" + esc(p.number) + " created", "Published to " + esc(REPO) + " as @" + esc(auth.user || "your account")) +
      '<div class="m-body"><div class="done nest"><span class="row-t">' + esc(p.title) + '</span><a class="link gh-link" href="' + issueUrl(p.number) + '" target="_blank" rel="noopener">' + GH_MARK + "View on GitHub</a></div></div>" +
      '<div class="m-foot"><span></span><div class="tools"><button class="btn" data-a="close" type="button">Close</button><button class="btn primary deep" data-a="another" type="button">Create another</button></div></div></div>';
  }

  function feedback(text, type = "err") {
    const el = $("ix-feedback");
    if (el) { el.className = "fb " + type; el.textContent = text; }
  }

  async function verify() {
    if (ui.busy) return;
    const token = $("ix-token").value.trim(), key = $("ix-key").value.trim();
    if (key) auth.key = key;
    if (!token) {
      if (key) { toast("Reflection key saved"); backFromConnect(); return; }
      feedback("Enter a fine-grained GitHub token first."); return;
    }
    ui.busy = true;
    const btn = document.querySelector('[data-a="verify"]');
    if (btn) { btn.disabled = true; btn.textContent = "Checking"; }
    try {
      const r = await fetch("/api/github", { method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify({ action: "verify" }) });
      const payload = await r.json();
      if (!r.ok) throw Error(payload.error || "GitHub rejected this token");
      auth.token = token; auth.user = payload.login; ui.busy = false;
      backFromConnect(); render(); refreshIssues();
      toast("Connected as @" + payload.login);
    } catch (e) {
      ui.busy = false; feedback(String(e.message || e));
      if (btn) { btn.disabled = false; btn.textContent = "Verify"; }
    }
  }

  async function publish() {
    if (ui.busy) return;
    captureDraft();
    const d = ui.draft;
    if (!d.title.trim() || d.title.trim().length < 6) { feedback("Enter a precise title of at least 6 characters."); return; }
    if (!d.body.trim()) { feedback("The description is empty."); return; }
    if (!auth.token) { ui.hint = "Connect GitHub with Issues: write to publish."; openConnect(); return; }
    ui.busy = true;
    const btn = $("ix-publish");
    if (btn) { btn.disabled = true; btn.textContent = "Publishing"; }
    try {
      const r = await fetch("/api/github", { method: "POST", headers: { Authorization: "Bearer " + auth.token, "Content-Type": "application/json" }, body: JSON.stringify({ action: "create", title: d.title.trim(), body: d.body.trim() }) });
      const json = await r.json();
      if (!r.ok) throw Error(json.error || "GitHub did not create the issue");
      ui.published = json; ui.busy = false; ui.modal = "done"; showModal(); refreshIssues();
      toast("Issue #" + json.number + " published");
    } catch (e) {
      ui.busy = false; feedback(String(e.message || e));
      if (btn) { btn.disabled = false; btn.textContent = "Publish issue"; }
    }
  }

  async function generate() {
    if (ui.busy) return;
    captureDraft();
    const d = ui.draft, ctx = ui.ctx;
    if (!d.title.trim()) { feedback("Add a title first."); return; }
    const notes = ctx ? ctx.symptoms : d.body;
    if (!notes.trim()) { feedback("Write rough notes in the description first."); return; }
    ui.busy = true;
    const btn = $("ix-generate"), ta = $("ix-body");
    if (btn) { btn.disabled = true; btn.textContent = "Writing"; }
    if (ta) { ta.value = ""; ta.disabled = true; }
    feedback("Connecting to Reflection Beam…", "ok");
    try {
      const headers = { "Content-Type": "application/json" };
      if (auth.key) headers["X-Reflection-Key"] = auth.key;
      if (auth.token) headers["X-GitHub-Token"] = auth.token;
      const payload = {
        title: d.title.trim(), symptoms: notes, reproduction: ctx ? ctx.reproduction : "", expected: "", observed: "",
        modules: ctx ? ctx.modules : "", priority: ctx ? ctx.priority : "P1", evidence: ctx ? ctx.evidence : "", body: ""
      };
      const r = await fetch("/api/ai", { method: "POST", headers, body: JSON.stringify(payload) });
      if (!r.ok) { const j = await r.json().catch(() => ({})); throw Error(j.error || "Reflection request failed (" + r.status + ")"); }
      const reader = r.body && r.body.getReader();
      if (!reader) throw Error("Streaming response unavailable");
      const decoder = new TextDecoder();
      let buffer = "", count = 0, finalError = null;
      const frameOf = frame => {
        const event = (frame.match(/^event:\s*(.+)$/m) || [])[1] || "token";
        const content = (frame.match(/^data:\s*(.+)$/m) || [])[1];
        if (!content) return;
        const p = JSON.parse(content);
        if (event === "error") { finalError = p.error || "Model stopped early"; return; }
        if (event === "token" && typeof p.content === "string") { count += p.content.length; if (ta) { ta.value += p.content; ta.scrollTop = ta.scrollHeight; } }
      };
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        buffer += decoder.decode(next.value, { stream: true }).replace(/\r\n/g, "\n");
        let at;
        while ((at = buffer.indexOf("\n\n")) !== -1) {
          const frame = buffer.slice(0, at); buffer = buffer.slice(at + 2);
          try { frameOf(frame); } catch (e) { finalError = String(e.message || e); }
        }
        if (finalError) { try { reader.cancel(); } catch {} break; }
      }
      ui.draft.body = ta ? ta.value : "";
      if (finalError) throw Error(finalError);
      if (count < 30) throw Error("Model returned no usable issue body");
      feedback("Generated " + count + " characters. Review before publishing.", "ok");
    } catch (e) { feedback(String(e.message || e)); }
    finally {
      ui.busy = false;
      const b = $("ix-generate"), t = $("ix-body");
      if (b) { b.disabled = false; b.textContent = "Write with Beam"; }
      if (t) t.disabled = false;
    }
  }

  /* ───────── actions ───────── */
  const actions = {
    view: el => setView(el.dataset.view),
    open: el => { state.selected = el.dataset.id; setView("issues"); },
    pick: el => {
      const l = document.querySelector(".queue-list"), top = l ? l.scrollTop : 0;
      state.selected = el.dataset.id; render();
      const n = document.querySelector(".queue-list");
      if (n) n.scrollTop = top;
    },
    agent: el => { state.selected = el.dataset.id; setView("agent"); },
    regress: el => { state.selected = el.dataset.id; setView("regressions"); },
    filter: el => { state.filter = el.dataset.filter; render(); },
    sync,
    refresh: () => { state.issues = null; state.issuesError = null; if (state.view === "overview") render(); refreshIssues(); },
    export: exportData,
    import: () => $("import-file") && $("import-file").click(),
    compose: () => openCompose(null),
    draft: () => openCompose(issue(state.selected)),
    connect: openConnect,
    disconnect: () => { auth.token = null; auth.user = null; auth.key = null; backFromConnect(); render(); refreshIssues(); toast("Disconnected"); },
    verify, publish, generate,
    another: () => openCompose(null),
    template: () => {
      captureDraft();
      if (ui.draft.body.trim()) { toast("Description already has content"); return; }
      ui.draft.body = SKELETON; $("ix-body").value = SKELETON; $("ix-body").focus();
    },
    close: () => {
      if (ui.busy) return;
      if (ui.modal === "connect") backFromConnect(); else closeModal();
    },
    "save-note": () => {
      const i = issue(state.selected);
      if (!i) return;
      store.notes[i.id] = { result: $("local-result").value, text: $("local-note").value, updatedAt: new Date().toISOString() };
      persist(); render(); toast("Evidence saved");
    },
    "delete-log": el => { store.logs = store.logs.filter(x => x.id !== el.dataset.id); persist(); render(); toast("Entry removed"); },
    "copy-prompt": async () => {
      const ta = $("prompt-body");
      try { await navigator.clipboard.writeText(ta.value); toast("Prompt copied"); }
      catch { ta.select(); toast("Select and copy manually"); }
    }
  };

  document.addEventListener("click", e => {
    const row = e.target.closest(".menu-row");
    if (row) { pickOption(+row.dataset.i); return; }
    const trigger = e.target.closest("[data-dd]");
    if (trigger) { const same = menu.btn === trigger; closeMenu(); if (!same) openMenu(trigger); return; }
    const el = e.target.closest("[data-a]");
    if (el && actions[el.dataset.a]) { actions[el.dataset.a](el, e); return; }
    const tr = e.target.closest("tr[data-issue]");
    if (tr) selectRow(tr.dataset.issue);
  });

  document.addEventListener("pointerdown", e => {
    if (menu.el && !menu.el.contains(e.target) && !e.target.closest("[data-dd]")) closeMenu();
  });

  document.addEventListener("mouseover", e => {
    const row = e.target.closest(".menu-row");
    if (row && menu.el && +row.dataset.i !== menu.i) { menu.i = +row.dataset.i; moveHl(); }
  });

  document.addEventListener("input", e => {
    if (e.target.id !== "issue-search") return;
    state.query = e.target.value;
    const list = filtered();
    $("issue-list").innerHTML = rows(list);
    $("issues-count").textContent = list.length + " / " + all().length;
  });

  document.addEventListener("submit", e => {
    if (e.target.id !== "reg-form") return;
    e.preventDefault();
    const f = e.target.elements, text = f.text.value.trim();
    if (!text) return;
    store.logs.push({ id: "manual-" + (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : Date.now()), issue: f.issue.value, result: f.result.value, text, date: new Date().toISOString(), system: false });
    state.selected = f.issue.value;
    persist(); render(); toast("Observation logged");
  });

  document.addEventListener("change", e => { if (e.target.id === "import-file") importData(e.target.files && e.target.files[0]); });

  document.addEventListener("keydown", e => {
    if (menu.el) { menuKey(e); return; }
    if (e.key === "Escape" && ui.modal) { e.stopPropagation(); actions.close(); return; }
    const tr = e.target.closest && e.target.closest("tr[data-issue]");
    if (tr && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); selectRow(tr.dataset.issue); return; }
    const tag = document.activeElement && document.activeElement.tagName;
    if (e.key === "/" && !e.metaKey && !e.ctrlKey && !ui.modal && !["INPUT", "TEXTAREA"].includes(tag)) {
      e.preventDefault();
      if (state.view !== "issues") setView("issues");
      $("issue-search") && $("issue-search").focus();
    }
    if (e.key === "Escape" && document.activeElement && document.activeElement.id === "issue-search") document.activeElement.blur();
  });

  addEventListener("resize", () => closeMenu());
  addEventListener("scroll", e => { if (menu.el && !menu.el.contains(e.target)) closeMenu(); }, true);

  render();
  sync();
  // Refresh while the dashboard is visible. Never overlap requests or keep
  // polling a background tab; refresh immediately when the user returns.
  const LIVE_SYNC_MS = 30_000;
  setInterval(() => {
    if (document.visibilityState === "visible" && !state.syncing) sync();
  }, LIVE_SYNC_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !state.syncing) sync();
  });
})();
