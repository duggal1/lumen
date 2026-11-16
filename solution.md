# Lumen — Core Motion & Zoom: Solution Plan

Companion to `issue.md`. Every item maps to a file and a test.
Principle: delete the zero-phase camera and the magic scale clamps; replace
them with finite, C2, rest-to-rest moves and an attention planner that emits
follow paths. Keep the public Director API (`ZoomPlanner.plan`,
`CameraSolver.solve`, `Director.derive`) byte-compatible.

---

## 1. Finite, C2 camera — `Sources/LumenDirector/Camera.swift`

### 1.1 Data model (internal)

```swift
private struct Scene {
    var event: Double          // source seconds the move should land on
    var start: Double          // output seconds, first frame of the scene
    var end: Double            // output seconds, last frame of the hold
    var lz: Double             // log target scale
    var segment: ZoomSegment
    var path: [(t: Double, c: SIMD2<Double>)]   // output seconds, normalised
    var center: SIMD2<Double>  // normalised fixed centre
    var kind: Kind             // .click, .typing, .visual, .hover
}
```

### 1.2 Build a target track analytically, then sample it

No `zeroPhaseSmooth` on `lz`. For every 240 Hz (soon 480 Hz) tick `t`:

1. Find the active scene.
2. `lz(t)`:
   - before `start`: `0`
   - `start .. event`: quintic `0 → lz` with zero v/a at both ends
     (`QuinticMove`), duration `event - start`
   - `event .. end`: `lz`
   - `end .. end + tail`: quintic `lz → 0`, duration `p.tail`
   - after: `0`
3. If the next scene starts before `end + tail`, **bridge**: do not fall to 0.
   Replace the tail with a quintic from `lz` to the next scene's `lz` over
   `[end, next.start]` (or `[end, next.event]` if `next.start < end`).
   This is the end of "double move" at scene handoffs.
4. `center(t)`:
   - if the scene has a follow path: sample the path at `t + p.lookahead`
     (clamped), then `centredPlay` with the scene's half-view dead zone,
     then add the `lean` bias (`0.12 / scale`) so the pointer sits left of
     centre.
   - else: the scene's fixed normalised centre.
   - during a bridge: quintic from the outgoing centre to the incoming centre
     with matched end velocities estimated from each side's path (finite
     difference over 30 ms). If no path, rest-to-rest.
5. Clamp the centre to the feasible range at `lz` (`clampCenter`).

Because every transition is a finite quintic, `lz` and `center` reach their
targets exactly and reach 0 exactly at `end + tail`. That fixes
`zoomOutReachesFullFrameAndStays` and removes the pre-end zoom-out.

### 1.3 Derivatives and rate

- Bake `nx, ny, lz, vx..az, yaw, pitch` at **`cameraRate = 480`**.
- Compute derivatives analytically from the quintic segments where possible;
  otherwise central differences at 480 Hz. `evaluate`'s `qhm` then has 2×
  headroom at 240 fps output.
- Keep the existing `CameraTrack` layout and `gridRate` indexing for the cursor
  (`qhm(c.nx, ...)` uses `c.rate`, so this is transparent).

### 1.4 Lead-in

`lead = max(p.leadIn, 0.22 + 0.16 * log2(scale))` clamped to `[0.22, 1.2]`.
- 1.8× → `0.22 + 0.16*0.85 = 0.36 s` (close to the old 0.30).
- 3.0× → `0.22 + 0.16*1.58 = 0.47 s`.
- 6.0× → `0.22 + 0.16*2.58 = 0.63 s`.
This is the "start early so the frame is already settled" requirement, derived
from magnitude instead of a constant.

### 1.5 Retarget without splitting

`retarget` in the planner no longer closes the scene for pointer motion. It
appends a follow point. A split happens only for a **strong** new click/typing
intent that is far from the current target (existing test
`distinctTargetsDoNotMergeIntoEmptySpace`). This removes the per-gesture
double move.

---

## 2. Attention planner — `Sources/LumenDirector/Planner.swift`

### 2.1 Intent kinds

```swift
enum Kind { case click, typing, hover, visual }
```

Add `.hover`. `.visual` is unchanged in spirit.

### 2.2 Build intents

**Clicks** (unchanged priority):
- left down, no cmd/ctrl, inside source, not a double-click.
- rect = smallest usable AX frame containing the point (see 2.4).
- weight `p.clickWeight` (default 3).

**Typing** (rewritten):
- For each `typingBursts()`:
  - collect AX carets from key events **and** the last good caret (capture
    publishes it into the AX array, see §5).
  - choose the **smallest** AX field containing the caret (not the biggest).
  - reject frames whose `anchor.resolved == false`.
  - if no caret, use the typing trace's `line ?? rect` and its samples.
  - if neither, and a click landed within `30 s` (was 20), synthesise a field
    around the click.
  - if none of the above, **no typing intent** (never invent).
- `ok(t)` becomes `t <= trimEnd - 0.2` (was `- 0.8`).

**Hover / dwell** (new):
- Walk consecutive `.move` events. A dwell is a window of at least
  `dwell = 0.28 + 0.45 * (1 - sensitivity)` seconds in which the pointer stays
  within `max(10, 0.012 * min(W,H))` px and there is no button-down, scroll,
  drag or keyDown.
- Emit `.hover` at the window end, position = window centroid.
- Suppress if a click happened within 1.2 s or typing within 0.8 s.
- If `p.sensitivity <= 0.05`, emit none.
- Hover never splits an active click/typing scene (preserves
  `clickClusterCenterStaysOnClickNotHoverCentroid`). It only opens a scene if
  no scene is active and the dwell is long enough.

**Visual** (relaxed):
- `coverage` range `0.0012 ... 0.45`.
- `count >= 2`, each within `0.75 s`.
- area `0.004 ... 0.60` of the screen.
- keep the scroll/drag veto and the click veto (±1 s).
- if the region contains the current pointer, allow `count >= 2` and lower the
  area floor to `0.0025`.

**Scroll / drag**: keep-alive only; never creates a scene.

### 2.3 Scale (the real zoom control)

```
hi = clamp(max(p.maxScale, p.baseScale * 1.2), 1.3, 6.0)
lo = clamp(p.minScale, 1.0, hi)
s  = p.baseScale
if let r = intent.rect {
    let coverage = r.w*r.h / (W*H)
    s *= clamp(pow(0.06 / max(coverage, 1e-4), 0.18), 0.85, 1.45)
}
if kind == .visual { s = min(s, 1.6) }
s = clamp(s, lo, hi)
```

- `baseScale` is now the primary control, so the UI slider works.
- Tiny targets get up to +45 %, large targets -15 %.
- `maxScale` is honoured up to 6.0.
- `minScale` is the floor.
- Keep the existing "don't jitter" rule: if
  `|log(s/prev)| < log(1.12)`, reuse `prev`.

Checked against the existing contract:
- default `baseScale = 1.8`; `fiveNearbyClicks` → 1.8 ✓
- AX 40×20 → 2.61 ✓ (test range 1.3…3.2)
- AX 0,0,960,540 rejected by `usableAX` → 1.8; click y=300 clamps exactly to
  the feasible centre → the two "popup" tests now assert the evaluated camera,
  which is the real guarantee ✓
- visual 500×280 → 1.6 ✓ (test expects ≤ 1.6)

### 2.4 AX selection

`usableAX` stays. Add:

```swift
static func smallestField(containing p: SIMD2<Double>, in frames: [AXFrame],
                          slack: Double, minW: Double, minH: Double) -> AXFrame?
```

- filter: finite, `w >= minW`, `h >= minH`, `p` inside `frame ± slack`,
  `anchor.resolved == true`.
- return the frame with the smallest area.
- if several frames have the same area, prefer the one whose `anchor` matches
  the event's app/window context (we have `anchor.appName/windowID`).

For clicks, the same helper returns the smallest control under the pointer.
If it is too large (`usableAX` fails), rect = nil and the click point is used.

### 2.5 Follow paths

For every auto scene, after the segments are chosen:

```
path = []
for each raw move event in [start - 0.4, end + 0.4]:
    p = (x/W, y/H)
    if p inside (scene centre ± 0.65 * view): path.append(t, p)
if kind == .typing: prepend/merge the caret path (caret wins)
if path.count >= 2: focus = .follow, follow[id] = smoothPath(path)
else: focus = .fixed(centre)
```

- `smoothPath` already exists (30 Hz, hold-then-jump across pauses,
  `zeroPhaseSmooth(omega: 9)`). Reuse it.
- For clicks, include the click point itself at the click time so the camera
  starts on the target even if the pointer moved before the first move event.
- For hover, the path is a single point → `.fixed`.

`CameraSolver.needsCursor` already becomes true for `.follow`; the global
cursor track is the fallback when a scene has no path.

### 2.6 Grouping / scene lifetime

- `gap = max(p.zoomOutGap, hold + 0.5)` (unchanged).
- A strong click/typing intent splits if the target moves more than
  `0.55 * halfView` (was 0.12). This keeps `distinctTargets...` at 500 px,
  1 s apart → 2 scenes.
- Hover and cursor motion never split.
- `panThroughGap` controls whether a bridge is allowed:
  if `next.start - current.end > p.panThroughGap`, zoom out to 0 instead of
  bridging.

### 2.7 Whooshes

The existing scene grouping in `Director.derive` already makes one whoosh pair
per scene. With fewer splits (2.6), there are fewer spurious whooshes.

---

## 3. Visual activity — `Sources/LumenDirector/VisualZoom.swift`

- Relax as in §2.2.
- Add cursor proximity: if the pointer is inside the region (or within
  0.2 * min(W,H)), lower `count` to 2 and the area floor to 0.0025.
- Keep the "tiny spinner" rejection: `area >= 0.004 * screen` by default.
  A 16×16 rect on 1920×1080 is 0.000123 → rejected even with the cursor
  proximity floor (0.0025).
- Keep the scroll veto.

---

## 4. UI — `Sources/LumenUI/Inspector.swift`

Camera tab, in order:

- Auto zoom (existing toggle)
- **Zoom amount** → `camera.baseScale`, range 1.3…3.0 (now functional)
- **Smoothness** → `camera.leadIn`, range 0.3…1.0 (unchanged, now the lead-in floor)
- **Motion tracking** → `camera.sensitivity`, range 0…1, format `%`
- **Look-ahead** → `camera.lookahead`, range 0…0.4, format `ms`
- Preset (existing)
- Advanced:
  - Max zoom → `camera.maxScale`, 1.2…6.0 (now honoured)
  - Zoom-out → `camera.tail`, 0.3…1.5
  - Max upscale, real-time upscale, min zoom, zoom-out delay, hold, safe zone,
    motion blur, follow delay, focus X/Y, focus debug (existing)

Add a one-line readout under the sliders? No: DESIGN.md forbids help text.
The labels are enough.

---

## 5. Capture — `Sources/LumenCapture/Input.swift`

### 5.1 Publish the last good caret

- Add `lastGood: (frame: AXFrame, at: Double, context: String)?` to
  `FocusState` (the existing `lastGood` already has this shape; reuse it).
- In `finishFocusQuery`, when `probe == nil`:
  - read the current focused context key (`focusedContextKey(system)`);
  - if it equals `state.lastContext` and `lastGood` is within **1.5 s**,
    publish `lastGood.frame` at `flight.index` with its original
    `anchor.sampledAt` (so the planner can tell it is held, not fresh).
- The planner's provenance check (§2.2) treats
  `anchor.sampledAt < event.t - 0.35` as a held sample, which is exactly what
  it is.

### 5.2 Lower focus latency

- `debugFocusDelay` default `0.025 → 0.004`.
- Keep one in flight (the AX server is serial); the latest-wins queue already
  prevents a slow query from blocking newer keys.

### 5.3 `typingBursts()` (Core.swift)

- Exclude option-arrow / navigation keycodes: 123 (left), 124 (right),
  125 (down), 126 (up) when `flags & 0x08 != 0` (option).
- Keep the existing exclusions.

---

## 6. Upscale — `Sources/LumenRender/Upscaler.swift`, `FXModels.swift`

- `UpscaleParams.maxFactor: 8 → 10`.
- `quantize(..., grid: 64 → 32)`; margin `8 → 12`.
- Keep the chain and the blend; at 32 px the cache key changes twice as often,
  but the crop only grows, so the sampled content stays correct.

---

## 7. Tests

### 7.1 Update the two stale focus tests (strengthen, don't weaken)

`AutoZoomRegressionTests`:
- `clickFocusIgnoresLargePopupAXFrameCenter`
- `oversizedPopupDoesNotForceCursorFollow`

New assertion: the segment focus is `.fixed`, and the **evaluated camera at
3.0 s** contains the click within 6 px (same bar as
`verifiedButtonCentersLandWithinTwoSourcePixelsAtNinePositions`). This proves
the popup centre was not used, which is the test's intent.

### 7.2 New file `Tests/LumenTests/CoreZoomIntentTests.swift`

1. `zoomAmountSliderChangesAutoScale` — same click, `baseScale` 1.4 vs 2.6 →
   different `zoom[0].scale`.
2. `maxZoomSliderIsRespected` — tiny AX target, `maxScale = 1.5` →
   `zoom[0].scale <= 1.5`.
3. `clickZoomCanReachSixX` — tiny AX target, `maxScale = 6`, `baseScale = 3` →
   `zoom[0].scale > 3`.
4. `typingUsesSmallestAXField` — two AX frames (window + field), caret inside
   the field → focus is inside the field, not the window.
5. `typingWithoutAXUsesTypingTrace` — no AX, one trace → one zoom whose focus
   is inside the trace's line.
6. `hoverDwellOpensAMildZoom` — 1.2 s dwell, `sensitivity = 1` → one zoom;
   `sensitivity = 0` → none.
7. `hoverDoesNotStealClickFocus` — click at (900,440), then a dwell at
   (1050,550) 1.4 s later → one scene, evaluated centre stays on the click.
8. `autoShotFollowsCursorInsideViewport` — click at (500,400), then moves to
   (700,450) → `zoom[0].focus == .follow` and the evaluated centre moves.
9. `zoomOutReachesExactlyOne` — redundant with the existing test, kept as a
   named guard.
10. `upscaleFactorTenIsValid` — `Upscaler.factor(forMagnification: 9.5,
    maxFactor: 10) == 10`.
11. `visualZoomNearCursorUsesLowerCoverage` — two points, coverage 0.0015,
    cursor inside → one visual zoom.
12. `typingNearRecordingEndIsNotDropped` — burst ending at `duration - 0.3` →
    a zoom exists.

### 7.3 Run

```
swift build
swift test --filter "ZoomPrecisionTests"
swift test --filter "MotionTraceTests"
swift test --filter "AutoZoomRegressionTests"
swift test --filter "MotionAccuracyTests"
swift test --filter "ZoomEasingTests"
swift test --filter "CoreZoomIntentTests"
swift test --filter "ZoomTypingVerifyTests"
swift test --filter "TypingTraceTests"
swift test --filter "UpscalerTests"
```

Then the full suite once (`swift test --no-parallel`) because the camera is a
shared dependency of render/export tests.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Finite camera breaks `motionTracesAreSmooth` (HF energy) | Quintic rest-to-rest has bounded jerk; verify with the existing DFT test before moving on. |
| Follow paths make the camera chase the cursor across the screen | Only include samples inside `0.65 * view` of the scene centre; the dead zone and `centredPlay` absorb jitter. |
| Relaxing visual zoom re-enables spinner zooms | Keep the area floor at 0.004 (0.0025 with the cursor inside); the 16×16 spinner is 0.000123. |
| Publishing a held caret misattributes a different field | Require the current AX context to equal the cached context; otherwise publish nothing. |
| `baseScale` > `maxScale` | `hi = max(maxScale, baseScale * 1.2)` so the slider is never silently capped. |
| 480 Hz track doubles bake time | 480 Hz over a 10 min recording is 288k samples × 10 arrays; still small. Measure with the existing `longCapture` test. |
| Existing tests encode the old scale clamps | Update only the assertions that check the *mechanism* (segment focus) to check the *guarantee* (evaluated camera). No test is deleted. |

---

## 9. What is explicitly not changing

- The capture pipeline, audio, export, captions, layouts, cursor rendering,
  masks, privacy, and the renderer's shader stack.
- The public `Timeline` / `ZoomSegment` / `CameraTrack` data shapes.
- The rule that manual zooms survive every derive.
- The rule that a deleted auto zoom stays deleted (`suppressedAuto`).
- Recordful's motion model: its CSS transition is not used.