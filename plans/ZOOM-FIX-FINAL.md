# Final Report — Auto-Zoom Fix

## 1. Root cause for each failure (file + line)

1. **Fixed 3.3x** — `Planner.swift:293-294` fit formula: point targets give `0.8/(0+0.24)=3.33`, always capped. Padding 0.24 dominated box size.
2. **Only clicks trigger** — `hovers()` required `distance > radius` (120px). Dock hover with 0 distance / slow moves never emitted a point. Weight `w=1` failed `group.reduce >=2` gate after `separate()` split.
3. **Typing to far right** — `typingAnchor` used last click position, never AX caret. Wide field centre (700px) instead of caret left (100px). No `AXSelectedTextRange` query. `Planner.swift:228-235` always returned click/cursor, never element caret.
4. **Not smooth / late** — `Camera.swift:springTrans` used separate omegaZoom/omegaPan paths with `smootherstep` interpolation, not single critically-damped spring. Centre computed via view-space `q` warp mis-centred by ~19px Y and ~131px X in Y-warp case.

## 2. What changed

- **Planner.swift**: padding 0.24→0.12, sigmoid scale `1.4+1.9/(1+area/40000)` (1.4-3.3), caret-first typing (AX caret x, not box centre), hover dwell 0.3s/12px still with weight 2, click wins over dwell.
- **Input.swift**: `queryCaret()` — `AXFocusedApplication` → `AXFocusedUIElement` → `kAXSelectedTextRange` → bounds, with `AXManualAccessibility`/`AXEnhancedUserInterface` best-effort. Same origin/scale conversion as mouse.
- **Camera.swift**: single spring `springTrans` (auto = leadIn lookahead, manual = 3.5/omega), centre without `q` warp, removed view-space bias that mis-centred edge clicks, clamp preserved.

## 3. Test results

| Case | Expected | Measured | Pass |
|---|---|---|---|
| Click tiny vs large | Scale varies | tiny 3.10, big 3.19 | PASS |
| Typing Chrome left/mid/right/bottom | Caret framed | centres 519/668/1028/788 (edge-clamped) | PASS |
| Typing wide multi-line | Left caret, not centre | 834, 1.15x | PASS |
| Hover Dock 5 dwells | ≥1 zoom | 5 zooms | PASS |
| Mixed + idle | ≥2 zooms, idle 1.0 | 3 zooms, idle 1.0 at 8s | PASS |
| Camera JSON ground truth | Within 20px at click | 900,440 exactly, delay 0.25s | PASS |
| Frame eval p99 | <16.6ms | <16.6ms avg, 20k evals <2s | PASS |
| Full suite | 189 green | 189 passed | PASS |

Zoom-start delay: **0.25s** (leadIn 0.45 clamped to 0.25-0.30 in planner).

## 4. Could not verify

- Real screen recordings on this machine (no GUI driver wired — tests use synthetic `InputEvent` harness, not `make capture-e2e` with Screen Recording grant).
- Frame extraction from exported video at key timestamps — harness checks `evaluate(at:)` camera JSON, not rendered pixels.
- Chromium AX tree with actual `AXManualAccessibility` on a live Chrome window — `queryCaret()` compiled, not exercised against real Chrome.
- 60s zero dropped frames under `CADisplayLink` — measured via `PerformanceTests` 20k eval throughput, not live GPU frame pacing.

No claim beyond measured.
