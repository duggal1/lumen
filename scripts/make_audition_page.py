#!/usr/bin/env python3
"""Generate a local audition page for the shipped interaction sounds.

    python3 scripts/make_audition_page.py

Writes Docs/Part-03/audition.html. Open it in a browser (or serve the repository
with `python3 -m http.server`) and listen: individual clicks, every key class,
down and release variants, and realistic rapid-typing / mixed sequences.

The page decodes the shipped 48 kHz files with Web Audio and schedules them at
exact AudioContext times, so the sequence preview uses the same timing model as
the editor: cue time -> sample-accurate buffer start.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOUNDS = ROOT / "Resources" / "Sounds"
OUT = ROOT / "Docs" / "Part-03" / "audition.html"

CLASSES = ["alpha", "number", "space", "enter", "backspace", "shift", "modifier", "nav", "fn"]


def main() -> None:
    manifest = json.loads((SOUNDS / "manifest.json").read_text())
    files = manifest["files"]
    by_path = {f["path"]: f for f in files}
    groups: dict[str, dict[str, list[str]]] = {}
    for key in CLASSES:
        groups[key] = {"down": [], "up": []}
        for phase in ("down", "up"):
            for f in files:
                if f["keyClass"] == key and f["phase"] == phase:
                    groups[key][phase].append(f["path"])
            groups[key][phase].sort()
    clicks = [f["path"] for f in files if f["keyClass"] == "click"]
    clicks.sort()
    sources = sorted({f["source"] for f in files})
    payload = {
        "clicks": clicks,
        "groups": groups,
        "meta": {
            path: {
                "author": by_path[path]["author"],
                "pageUrl": by_path[path]["pageUrl"],
                "license": by_path[path]["license"],
                "sha256": by_path[path]["sha256"],
                "releaseEvidence": by_path[path].get("releaseEvidence"),
            }
            for path in by_path
        },
        "sources": sources,
        "sampleRate": manifest["sampleRate"],
    }
    html = TEMPLATE.replace("__DATA__", json.dumps(payload, ensure_ascii=False))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(files)} sounds)")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lumen — Part 3 interaction sound audition</title>
<style>
  :root { color-scheme: light dark; --bg:#0f1115; --panel:#171a21; --line:#2a2f3a; --text:#e8ebf0; --muted:#9aa4b2; --accent:#8ab4ff; }
  @media (prefers-color-scheme: light) { :root { --bg:#f6f7f9; --panel:#fff; --line:#dfe3e8; --text:#16181d; --muted:#5c6673; --accent:#2457c5; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif; }
  header { padding:28px 32px 18px; border-bottom:1px solid var(--line); }
  h1 { margin:0 0 6px; font-size:20px; letter-spacing:-0.01em; }
  p { margin:0; color:var(--muted); max-width:78ch; }
  main { padding:24px 32px 64px; display:grid; gap:18px; grid-template-columns:repeat(auto-fit,minmax(340px,1fr)); }
  section { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:16px; }
  h2 { margin:0 0 10px; font-size:13px; text-transform:uppercase; letter-spacing:0.08em; color:var(--muted); }
  .row { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:8px; }
  button { font:inherit; color:var(--text); background:transparent; border:1px solid var(--line); border-radius:7px; padding:5px 9px; cursor:pointer; }
  button:hover { border-color:var(--accent); }
  button.on { border-color:var(--accent); color:var(--accent); }
  .seq { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .seq button { background:var(--accent); color:#0b0d10; border-color:transparent; font-weight:600; }
  @media (prefers-color-scheme: dark) { .seq button { color:#0b0d10; } }
  label { color:var(--muted); display:flex; gap:8px; align-items:center; }
  input[type=range] { width:160px; }
  code { font:12px ui-monospace,SFMono-Regular,Menlo,monospace; color:var(--muted); word-break:break-all; }
  .now { color:var(--accent); font-variant-numeric:tabular-nums; }
  footer { padding:0 32px 40px; color:var(--muted); }
</style>
</head>
<body>
<header>
  <h1>Part 3 — interaction sound audition</h1>
  <p>Every sound below is a real CC0 recording shipped in <code>Resources/Sounds</code>, 48 kHz mono.
  Sequences are scheduled at exact AudioContext times. Judge the attack, the body and the release:
  reject hollow, metallic, exaggerated, robotic or over-loud takes.</p>
</header>
<main id="grid"></main>
<footer>
  <p id="meta"></p>
</footer>
<script>
const DATA = __DATA__;
const BASE = "../../Resources/Sounds/";
const ctx = new (window.AudioContext || window.webkitAudioContext)();
const cache = new Map();
let master = null;
async function decode(path) {
  if (cache.has(path)) return cache.get(path);
  const res = await fetch(BASE + path);
  if (!res.ok) throw new Error(path + ": " + res.status);
  const buf = await ctx.decodeAudioData(await res.arrayBuffer());
  cache.set(path, buf);
  return buf;
}
function ensureMaster() {
  if (!master) {
    master = ctx.createGain();
    master.gain.value = Number(document.getElementById("gain")?.value ?? 0.8);
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -6; comp.knee.value = 6; comp.ratio.value = 2;
    comp.attack.value = 0.003; comp.release.value = 0.12;
    master.connect(comp).connect(ctx.destination);
  }
  return master;
}
async function play(path, when = 0, gain = 1) {
  const buf = await decode(path);
  const src = ctx.createBufferSource();
  src.buffer = buf;
  const g = ctx.createGain(); g.gain.value = gain;
  src.connect(g).connect(ensureMaster());
  src.start(Math.max(ctx.currentTime + 0.01, when));
  return buf.duration;
}
function button(text, fn) {
  const b = document.createElement("button"); b.textContent = text; b.onclick = fn; return b;
}
function section(title) {
  const s = document.createElement("section");
  const h = document.createElement("h2"); h.textContent = title; s.appendChild(h);
  document.getElementById("grid").appendChild(s);
  return s;
}
function row(s) { const d = document.createElement("div"); d.className = "row"; s.appendChild(d); return d; }

function build() {
  const clicks = section("Mouse clicks");
  const cr = row(clicks);
  DATA.clicks.forEach(p => cr.appendChild(button(p.split("/").pop(), () => play(p))));

  const typing = section("Keys — individual down / release");
  for (const key of Object.keys(DATA.groups)) {
    const wrap = document.createElement("div");
    const label = document.createElement("div");
    label.innerHTML = `<strong>${key}</strong> <code>${DATA.groups[key].down.length} down · ${DATA.groups[key].up.length} release</code>`;
    wrap.appendChild(label);
    const d = row(wrap);
    DATA.groups[key].down.forEach(p => d.appendChild(button("↓" + p.match(/-(\d+)\.wav$/)[1], () => play(p))));
    DATA.groups[key].up.forEach(p => d.appendChild(button("↑" + p.match(/-(\d+)\.wav$/)[1], () => play(p, 0, 0.9))));
    typing.appendChild(wrap);
  }

  const seq = section("Sequences");
  const controls = document.createElement("div"); controls.className = "seq";
  const gainWrap = document.createElement("label");
  gainWrap.innerHTML = 'Level <input id="gain" type="range" min="0.1" max="1" step="0.05" value="0.8">';
  controls.appendChild(gainWrap);
  seq.appendChild(controls);

  const srow = row(seq);
  const phrases = {
    "Rapid letters (120 wpm)": { keys: ["alpha"], count: 40, gap: 0.05 },
    "Numbers": { keys: ["number"], count: 24, gap: 0.08 },
    "Sentence (letters + space)": { keys: ["alpha", "space"], count: 44, gap: 0.075 },
    "Code (letters + numbers + enter)": { keys: ["alpha", "number", "enter"], count: 48, gap: 0.07 },
    "Editing (backspace + nav + enter)": { keys: ["backspace", "nav", "enter"], count: 28, gap: 0.11 },
    "Modifiers + shortcuts": { keys: ["modifier", "alpha", "shift"], count: 20, gap: 0.12 },
    "Mixed click + typing": { keys: ["alpha", "space", "click"], count: 36, gap: 0.09 },
  };
  for (const [name, spec] of Object.entries(phrases)) {
    srow.appendChild(button(name, () => runPhrase(spec)));
  }

  const meta = document.getElementById("meta");
  const first = DATA.meta[DATA.clicks[0]];
  meta.innerHTML = `${DATA.sources.length} CC0 sources · ${Object.keys(DATA.meta).length} files · 48 kHz. ` +
    `Example: ${first.author}, ${first.license}, <a href="${first.pageUrl}">${first.pageUrl}</a>. ` +
    `Full hashes and source URLs are in <code>Resources/Sounds/manifest.json</code>.`;
}

async function runPhrase(spec) {
  const start = ctx.currentTime + 0.15;
  let t = 0;
  let prev = null;
  for (let i = 0; i < spec.count; i++) {
    const key = spec.keys[i % spec.keys.length];
    let path;
    if (key === "click") {
      path = DATA.clicks[i % DATA.clicks.length];
      t += 0.22;
    } else {
      const downs = DATA.groups[key].down;
      path = downs[i % downs.length];
      // Fast typing is slightly quieter, as in the editor.
      const gain = spec.gap < 0.06 ? 0.78 : spec.gap < 0.1 ? 0.9 : 1;
      const dur = await play(path, start + t, gain);
      // Release 55–90 ms later, from the same class, with its own recording.
      const ups = DATA.groups[key].up;
      if (ups.length && Math.random() < 0.55) {
        await play(ups[i % ups.length], start + t + 0.055 + Math.random() * 0.03, gain * 0.75);
      }
      prev = dur;
    }
    t += spec.gap * (0.75 + Math.random() * 0.5);
  }
}

build();
document.addEventListener("click", () => { if (ctx.state === "suspended") ctx.resume(); }, { once: true });
</script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
