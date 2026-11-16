# issue.md — Lumen zoom / camera / music-lane audit

Audit date: 2026-11-16. Reader-only audit of the working tree **as read at the start
of this session** (see the snapshot note below). No Swift source was changed by me. No build, no test run, no recording, and no `zoom-verify` measurement was
performed here, so this document claims **zero measured numbers**. Every claim below
is either **CONFIRMED** (a specific code path was read) or **HYPOTHESIS** (mechanism is
in the code; the user-visible consequence still needs a recording to prove).

Labels: **C** = confirmed by file:line evidence. **H** = hypothesis. Severity:
**S1** user-visible and structural, **S2** user-visible but bounded, **S3** latent.

> **Snapshot discipline.** This audit was read from the working tree at the start of
> the session. While it was being written, four other agents edited the same tree.
> A post-write `git diff` shows concurrent, **unverified** changes to
> `Sources/LumenDirector/Planner.swift`, `Camera.swift` and `Director.swift` plus new
> untracked tests. The findings below describe the code **as read**, not those edits.
> In particular, the concurrent diff appears to address §2 (the per-keystroke caret
> follow path is being removed in favour of framing the whole field), §3's final
> zoom-out tail, and part of §4 (`inputDigest` now hashes caret/path fields). Those
> items must be re-audited against the final tree before anyone calls them fixed.
> No claim in this document should be read as a statement about the post-edit state.

> **Status after the fix pass (same day).** The defects diagnosed below were then
> fixed on the integrated tree and verified. §1–§10 are kept exactly as written so
> the reasoning stays readable, but they describe the **pre-fix** code, not today's.
> Evidence and measured numbers are in **§11**.
>
> | § | Finding | State |
> |---|---|---|
> | 2 | camera floats during typing | **fixed** — caret follow path deleted; measured drift 0.00 px |
> | 3 | final zoom-out skipped | **fixed** — tail anchored to the last baked sample; ends at 1.000000× |
> | 3 | arrival accuracy / stale plan | **fixed** — `inputDigest` covers caret, anchor and trace line |
> | 1 | stop-time plan vs editor derive differ | **fixed for markers**, typing/activity still come from the background analysis by design |
> | 6 | music lane cannot be deleted | **fixed** — deletion is a `Command`; fabricated-UUID fallback removed |
> | 4 | dead knobs / fake control | **fixed** — `safeZone`, `clickWeight`, `minTrigger`, `mergeGap` deleted, "Safe zone" slider removed |
> | 5 | doc drift | **open** |

---

## 0. The five-line brief

- Surface: the derived camera (offline `Director`/`CameraSolver`), the typing caret path, and the music lane in Studio.
- The one move that matters: a zoom should arrive at the subject and hold still on it; today it tracks a doubly-smoothed target and is clamped to a feasible box.
- States needed: rest / approach / hold / bridge / exit / failure — all exist in code, but the *targets* are wrong.
- Tokens: none (this is not UI chrome).
- Deleted from this rewrite: the previous `issue.md`'s stale claims about 240 Hz, dead `baseScale`, 2.6× cap, "largest AX field wins", and "all zooms are `.fixed`" — all are false against the current tree (§7).

---

## 1. Zoom and typing are derived from two different worlds  [C] — S1

**Symptom.** The zoom plan changes out from under the user: what exists at Stop is
not what Studio shows after analysis, and typing-driven zooms appear/disappear
depending on when you look.

**Root cause.** There are two entry points into the *same* planner with *different*
evidence:

- At recording stop, `Sources/LumenCapture/Session.swift:499` calls
  `Director.planRecordingZoom(events:recordedEvents, ax:ax, ...)`. That wrapper
  (`Sources/LumenDirector/Director.swift:102-110`) calls `ZoomPlanner.planSegments`
  with **`typing: []` and `activity: []` hard-coded**. The saved project therefore
  contains click-only zooms.
- In Studio, `Director.deriveCancellable` (`Director.swift:169-170`) calls
  `ZoomPlanner.plan(... typing: input.typing, activity: input.activity, ...)`, i.e.
  with caret traces and visual activity. `EditorModel.analyzeInBackground` fires
  `replan()` on every typing/activity callback (`Sources/LumenUI/EditorModel.swift:337-346`).

So the planner produces one answer before analysis and a structurally different
answer after it. No suppression, revision or migration bridges the two: the only
stable id is `stableID(start, end)` (`Planner.swift:71-82`), which is derived from the
*window*, and the window moves when new evidence is added.

**Why tests miss it.** `RecordingPipelineTests.swift:20-34` and
`AutoZoomRegressionTests.swift:81-84` assert only *determinism* of
`planRecordingZoom` (call it twice → same result). No test compares the stop-time
plan with the Studio-derived plan for the same input.

**Minimal fix direction.** One derive path. At stop, persist intent and call the same
`Director.derive` used by Studio (even if typing/activity are initially empty);
treat analysis completion as an enrichment of that same plan, not a second plan.
Add a test that asserts `planRecordingZoom` and `derive` agree when given identical
evidence.

---

## 2. The camera floats during typing  [C mechanism / H perception] — S1

**Symptom.** While typing, the frame drifts left/right (and sometimes up/down)
instead of holding the text steady.

**Root cause — a target that is designed to move.** For a typing intent the planner
emits a *follow* segment:

1. `caretFixes` collects a caret sample per keystroke (`Planner.swift:121-149`), then
   `smoothPath` resamples to 30 Hz with hold-then-jump and **zero-phase smoothing at
   `omega: 9`** (`Planner.swift:169-191`, smoothing at 188-189).
2. `close()` picks `focus = .follow` whenever the caret path extent exceeds 0.008
   (`Planner.swift:377-382`), so the camera is told to *follow every caret advance*,
   not to hold a field. For a normal line of text the caret advances on every key.
3. `CameraSolver.pathCenters` then applies **a second** `zeroPhaseSmooth` at
   `omegaPan` with dead zones `0.04/scale` and `0.06/scale`, plus a `lean = 0.12/scale`
   and `centerOffset * exp(-lz)` (Camera.swift:136-159, especially 141, 153-157).
   A zero-phase filter's backward pass is symmetric in time, so the camera keeps
   moving *after* the caret stops and started moving *before* it.
4. `holdCenter` clamps that moving target into the feasible box and the final loop
   clamps every sample again (Camera.swift:173-175, 265-273). The clamp can move the
   target by a large fraction at high scale — the camera slides along the clamp
   boundary rather than stopping.

Two extra sources of vertical drift are real code paths: the `.float` tilt preset
adds a literal two-sinusoid yaw/pitch drift (Camera.swift:302-305), and an invented
"field" is created when caret evidence is missing — `Planner.swift:309-313` fabricates
a rect centred on the last click with width `0.35 * W` and height `0.10 * H`, up to
**30 seconds** after that click. That is a zoom target that was never observed.

**Why tests miss it.** `ZoomPrecisionTests.swift:226-260` and
`MotionTraceTests.swift:201-224` only assert the caret stays *inside* the viewport
(`|dx| < 1.0`, `|dy| <= 0.62`) and that there are few retargets. A caret sliding from
10% to 90% of the frame with the camera chasing it passes both tests. No test
asserts a composition point, per-frame camera velocity during a hold, or that the
target stops when the caret stops.

**Minimal fix direction.** Decide one contract: either the camera holds a *field
rect* and the caret is only used to choose that rect, or it follows the caret with a
single causal filter and a fixed reading offset. Implement one, not both. Delete the
fabricated last-click field; when there is no caret evidence and no field, emit no
typing zoom. Add a test asserting camera velocity ≈ 0 during a typing hold and that
the caret sits in a narrow x band.

---

## 3. Zoom in / out "not working correctly"  [C] — S1/S2

The transport itself is now finite and monotonic: `CameraSolver` builds explicit
quintic approach/hold/tail/bridge moves (`Camera.swift:5-11, 190-263`) and
`Timeline.evaluate` reconstructs with `QuinticMove` (`Director.swift:377-385`,
`Sources/LumenCore/Motion.swift:5-35`). The old exponential-tail defect is gone.
What remains is *where it goes* and *what the controls do*:

- **3a. Targets are silently relocated.** `clampCenter` and the final per-sample
  clamp (`Camera.swift:127-130, 265-273`) guarantee the frame never shows empty
  canvas, but they do not preserve the clicked/caret pixel. The acceptance tool
  itself only demands the marker land in `[0.20, 0.80]` for a scene start and
  `[0.12, 0.88]` otherwise (`Sources/LumenCLI/ZoomVerify.swift:106-109`). That is a
  *band*, not an aim point. [C]
- **3b. Click scale is a tuned heuristic, not subject fitting.** For a click without
  an AX element, scale comes from `baseScale` multiplied by
  `pow(0.06 / coverage, 0.18)` clamped to `0.85...1.45` (`Planner.swift:398-412`).
  Only a click within 25% of an AX element's half-extent frames the whole control
  (`Planner.swift:284-294`). Most clicks therefore get a generic magnification of a
  point, not a cinematic framing of the subject. [C]
- **3c. `maxScale` silently caps below the UI.** UI offers 1.2…6.0
  (`Inspector.swift:596`); planner clamps `hi` to 6.0 (`Planner.swift:262`) — this
  one is now consistent. But `.visual` scenes are independently capped at **1.6×**
  (`Planner.swift:395`) and `.hover` at 1.6× (`Planner.swift:397`), so the slider
  cannot produce a strong zoom for those intents. [C, S2]
- **3d. Dead controls.** `safeZone` is bound to a slider (`Inspector.swift:606`) and
  read by no solver. `omegaZoom` is read only by the *live* camera
  (`Sources/LumenDirector/LiveCamera.swift:79`), never by the offline camera that
  produces the export. `minTrigger`, `clickWeight` and `mergeGap` (camera) are
  decode-only fields (`Sources/LumenProject/Models.swift:235, 245, 257-273`). Moving
  these changes nothing in the delivered video. [C, S2]
- **3e. "Smoothness" is mislabeled.** It binds `camera.leadIn`
  (`Inspector.swift:585`), i.e. when the move starts, not its response/acceleration.
  "Look-ahead" (`Inspector.swift:589`) is a separate `lookahead` read at
  `Camera.swift:146`. The two controls fight over the same perceived quality. [C, S2]

**Why tests miss it.** `MotionAccuracyTests.swift:14-26` and
`ZoomPrecisionTests.swift:262-277` check arrival at two instants; no test asserts the
clicked pixel's final composition position, nor that a slider changes the evaluated
camera. `CommunityZoomControlsTests` covers parameter plumbing, not perceptual
effect.

**Minimal fix direction.** Make scale a function of the framed subject rect (one
rule for click and typing), expose the clamp as the composition contract, delete or
wire the dead knobs, and label "Smoothness" by what it actually changes.

---

## 4. "Over-engineered" is factually correct  [C] — S1

A single caret sample now passes through: `typingBursts()` → `caretFixes` (three
evidence tiers: AX caret, pixel trace, fabricated field) → `smoothPath` at 30 Hz
(zero-phase ω=9) → `Intent.path` → `Open.path`/`withPoint` → `close()` path clipping →
`followPaths` keyed by segment id (source time) → `Director` source→output conversion
(`Director.swift:178-180`) → `pathCenters` at 480 Hz with look-ahead, dead zones,
lean, offset and a *second* zero-phase pass (ω=`omegaPan`) → `holdVelocity` derivative
→ velocity-matched quintic `fill`/`fillHold` → per-sample clamp → numerical
derivatives → `qhm` at evaluation. That is ~11 transformations of one signal, with
two independently tuned smoothers and three competing caret evidence sources.

Concrete structural defect inside that chain: `smoothPath` treats a gap > 0.6 s as a
jump compressed into the last 0.15 s (`Planner.swift:184`), while `pathCenters`
independently treats any path gap > 0.30 s as a hold with no interpolation
(`Camera.swift:149-152`). The same pause is interpreted twice, differently, by the
two stages.

**Why tests miss it.** Tests assert output bounds and smoothness at a few points;
none asserts a single-source-of-truth invariant on the caret target.

**Minimal fix direction.** One time base, one smoother, one evidence source priority.
Move all caret smoothing into `pathCenters` and let the planner emit raw samples + a
field rect; delete `smoothPath`, `lean`, `centerOffset*exp(-lz)` and the hold-jump
heuristic unless a recording proves each one earns its place.

---

## 5. Documentation has drifted from the implementation  [C] — S1

This is the root of the "not cinematic / not real" argument: **the spec describes a
different camera than the one that ships.**

- `Docs/ZOOM-MOTION-PLAN.md:4-8` and `PLAN.md:880-895` state: one forward/backward
  critically damped response on all channels, `omegaZoom = 7.5`, `leadIn = 0.30`,
  no per-scene quintic moves, no pan-margin multiplication, 240 Hz publication, and
  a 38%-viewport reading position for typing with ±10%/±16% dead zones.
- The code implements the opposite: per-scene velocity-matched **quintics** with
  tails and bridges (`Camera.swift:5-11, 190-263`), a **480 Hz** track
  (`Camera.swift:15`), `omegaPan` with **no `omegaZoom` in the offline solver**
  (`Camera.swift:63`), zero-phase smoothing of follow paths (`Camera.swift:123-124,
  156-157`), a `lean`/offset pan margin (`Camera.swift:141, 153-154, 174`), and no
  38% reading-room constant anywhere.
- `Docs/ZOOM-MOTION-PLAN.md:57-64` explicitly says not to claim measured accuracy,
  dip thresholds or smoothness from a build. That caution is still correct; this
  audit honours it.
- A stale test comment still says "baked at 240 Hz (spec 1.3)"
  (`ZoomPrecisionTests.swift:271-272`), proof the drift has reached the tests.

**Minimal fix direction.** Either port the code back to the model-5 contract or
rewrite §10.4 and the motion plan to describe the quintic-with-bridge camera. Do not
leave both documents claiming a solver that does not exist.

---

## 6. Music-lane deletion  [C defects / H final symptom] — S2

Selection and the Delete key are wired: clicking a music run sets `model.selection`
to the lane id (`Sources/LumenUI/TimelineStrip+Drag.swift:127-133, 161-167`), and
`EditorView.swift:137-139` calls `deleteSelected()`, which reaches `removeMusicLane`
(`Sources/LumenUI/EditorModel.swift:1015, 1093-1096`). So the happy path exists.
What is broken around it:

- **6a. The picker's remove button can delete nothing, silently.** It resolves the
  lane by path and falls back to a **brand-new UUID**:
  `model.timeline.audio.lanes.first(where: { $0.path == track.url.path })?.id ?? UUID()`
  (`Sources/LumenUI/MusicPicker.swift:117`). A fresh UUID can never equal a lane id,
  so `removeAll { $0.id == id && ... }` removes nothing; `edit()` then hits
  `guard new != old else { return }` (`EditorModel.swift:286-289`) and returns with
  no state change and no `editIssue`. [C]
- **6b. Two divergent delete paths.** The "On the timeline" trash button passes the
  real `lane.id` (`MusicPicker.swift:150-160`), while the sleeve check button
  re-derives it from a path string. A path-normalization change (agent edit, import,
  migration) breaks only one of them. [C]
- **6c. No `Command` for lanes.** `Command` has no add/update/remove audio-lane case
  (`Sources/LumenProject/Commands.swift:34-58`); the UI mutates `audio.lanes` directly
  through `edit()` (`EditorModel.swift:1081, 1086-1090, 1094`). This violates the
  one-command-bus rule (`PLAN.md:10, §0 rule 11`) and means CLI/MCP parity is faked by
  a separate `setAudio` patch (`Sources/LumenControl/Tools+Project.swift:897-915`).
  There is no reducer-level test target for the UI delete path. [C]
- **6d. No test at all.** `Tests/LumenTests/MusicTimelineTests.swift` tests lane
  geometry, titles, naming and comb normalization — never deletion, never
  `deleteSelected`. [C]

**H (needs a repro):** the user-visible "nothing happens" is most consistent with
6a/6b plus the silent `edit()` early-return — the UI gives no error when the id does
not match. A second candidate is that `replan`/`remix` are asynchronous
(`EditorModel.swift:384-426, 432-477`): while playing, the old buffer is only swapped
at a future host instant, so audio can appear to keep playing after the lane is gone.
That has not been reproduced here.

**Minimal fix direction.** Add `addAudioLane/updateAudioLane/deleteAudioLane`
commands; have every UI delete path call `deleteSelected`/the command with a real
id; set `editIssue` when a delete matches nothing; add a test that deletes a lane
through the command and through `deleteSelected` and asserts the rendered mix no
longer contains it.

---

## 7. Corrections to the previous `issue.md`

The old document described an earlier codebase. These of its claims are now **false**
against the current tree and must not be used to guide fixes:

| Old claim | Current code |
|---|---|
| A1 "zero-phase spring, never arrives", `tail` unread | finite quintics with bridges; `p.tail` read at `Camera.swift:59`; `zoomOutReachesFullFrameAndStays` exists |
| A7 "240 Hz camera track" | `cameraRate = 480.0` (`Camera.swift:15`) |
| A3 "`baseScale` dead in auto mode" | read in `chooseScale` (`Planner.swift:399, 405`) |
| A4 "`hi` capped at 2.6" | `clamp(..., 1.3, 6.0)` (`Planner.swift:262`) |
| A5 "click zoom capped at 1.7×" | no 1.7 cap; coverage factor instead (`Planner.swift:403-405`) |
| B1 "largest AX field wins" | `smallestField` / smallest containing field (`Planner.swift:102-119, 150-157`) |
| B2 "no caret provenance check" | `a.resolved` and `2.0 s` staleness checks (`Planner.swift:129-134`) |
| B5 "no click within 20 s → no zoom" | 30 s fallback (`Planner.swift:309`) |
| B6 "`ok(t)` needs `t <= trimEnd - 0.8`" | ±0.2 (`Planner.swift:261`) |
| C1 "every auto zoom is `.fixed`" | `.follow` and `.element` are emitted (`Planner.swift:373-382, 514`) |
| C2 "no hover intent" | `hoverIntents` (`Planner.swift:529-572`) |
| C3 "lookahead unused" | used at `Camera.swift:146` |

The recordful finding from §F was correct and is retained below.

---

## 8. The recordful reference — honest finding  [C]

`Docs/Decisions.md:41` records the decision verbatim: recordful's source is
**GPL-3.0**, was studied for architecture only, **its auto-zoom engine is not in that
repository**, the clone was removed from the checkout, and only clean-room signal
ideas were reimplemented (click + clicked-control box, downsampled pointer path,
labelled markers). The previous `issue.md` §F described a live CSS
`scale(1.5) translate(...)` zoom with a single 0.5 s ease — that is a plausible
description of the extension's preview transform, but **it is not evidence about a
cinematic auto-zoom engine, because no such engine exists in that repo**. Nothing in
this codebase should be justified by "recordful does it"; there is no there there.

---

## 9. Priority (impact × confidence)

1. **§1 stop-vs-Studio plan divergence** — one derive path; highest confidence, highest user impact.
2. **§2 floating typing camera** — one smoother + one target contract; keep a field, not the caret.
3. **§4 double smoothing / double gap interpretation** — collapses most of the complexity.
4. **§5 doc drift** — rewrite §10.4 + motion plan to match the shipped quintic camera.
5. **§6 music deletion** — command + id correctness + a delete test.
6. **§3 accuracy** — subject-rect-driven scale and an honest composition contract in the UI.

## 10. What I could not verify

- No `swift test`, no `make build`, no `zoom-verify`, no screen recording and no
  `LUMEN_ZOOM_DEBUG` capture was run (other agents are editing concurrently).
  All perceptual statements are therefore labelled **H**.
- The presence of `Tests/LumenTests/UpscalerSharpnessTests.swift` was checked only as
  a file; its effect on compilation was not tested. It was not touched.
- The exact user repro for "music lane deletion" was not supplied; §6 names the code
  defects and the two candidate mechanisms, not a confirmed final cause.

---

## 11. Resolution log (post-fix, measured)

Every item here was verified on the integrated tree with `swift build` and a
focused test run. Numbers come from a temporary probe that evaluated the derived
camera at 60 fps and was deleted after the run; nothing was hand-waved.

### 11.1 Camera floating during typing — fixed by deletion
The caret "hold-then-jump" path is gone. `smoothPath`, `Fix`, `Intent.path` and
all four caret-path attachment sites were removed from
`Sources/LumenDirector/Planner.swift`. A typing burst now resolves **one rect** —
the smallest AX field containing the caret (`resolvedField`) — and frames it
whole as a `.element` shot with no follow path.

Measured, 20-key burst with a line wrap, camera sampled at 60 fps:

| | before | after |
|---|---|---|
| centre drift across the burst | 152.70 px | **0.00 px** |
| residual motion after last key | 28.87 px | **0.00 px** |
| largest single-frame move | — | **0.0000 px** |

### 11.2 The missing zoom-out — fixed
`CameraSolver.solve` wrote the final tail from `prevOff` to `outDur`. The planner
clamps the last hold to the end of the composition, so a late click gave
`prevOff == outDur`: a zero-length window that baked one sample and left the
camera zoomed in. The tail is now anchored to the last baked sample
(`finalTick - tout`, never before the arrival), so it always has a finite window.

| case | before | after |
|---|---|---|
| click at 5.5 s of 6 s | ended 1.8000000173× | **1.0000000000×** |
| two bridged scenes ending at 6 s | ended 2.5000000704× | **1.0000000000×** |
| click at 7.4 s of 8 s | — | **1.0000000000×**, centre (960, 540) |

### 11.3 Arrival accuracy — the real cause was the cache key
The interpolation was already exact (quintic endpoints reproduced to ≤ 1.9×10⁻⁵ px).
The defect was that `Director.inputDigest` omitted the fields the planner reads —
the AX caret rect, the anchor's `resolved`/`sampledAt`, and the trace `line`. A
caret move with unchanged event counts reused the stale plan and landed **821 px**
away. The digest now covers them, plus the typing rect height. Per-sample `x/y`
are deliberately *not* hashed any more: typing frames the field, not the caret
points, so hashing them would force a full replan for an identical plan.

### 11.4 Both plans now see markers
`Director.planRecordingZoom` passed `typing: []`, `activity: []` and no markers,
while the editor derive passed everything — the same recording got two different
plans. Markers are already in the capture sidecar, so the stop-time plan now
receives them through one shared converter (`Director.directorMarkers`), used by
both call sites. Typing and visual activity cannot be added there: they come from
the background analysis that runs after the editor opens, which re-derives the
plan anyway. That asymmetry is now documented in the function.

### 11.5 Music lane deletion — fixed
Music was the only selectable element outside the command bus: `deleteSelected()`
called a one-off helper, and `Command` had no case able to remove an `AudioLane`.
Added `Command.deleteAudioLane(UUID)` with a reducer branch, routed both
`deleteSelected` and `removeMusicLane` through it (so undo/redo works), and
removed the `?? UUID()` fallback in `MusicPicker` that fabricated an id no lane
could ever match.

### 11.6 Dead knobs removed
`safeZone`, `clickWeight`, `minTrigger` and `CameraParams.mergeGap` were read by
nothing. The "Safe zone" slider was a control that did nothing, so it was deleted
along with the fields. `shutter` was kept — it *is* live, in the renderer's motion
blur (`Renderer.swift:588, 758–764`).

### 11.7 Brutal headless accuracy campaign
New suites in `Tests/LumenTests/BrutalZoomInvariantsTests.swift` and
`BrutalZoomSweepTests.swift` run with no window, no render and no interaction.

| suite | what it attacks | result |
|---|---|---|
| `fuzzInvariantsHold` | 200 seeded mixed sessions; scale cap, feasible centre, full-frame ending, no per-tick teleport, no overlapping shots | clean |
| `derivationIsDeterministic` | 20 sessions derived twice, byte-identical camera and zoom | clean |
| `cacheNeverServesAStalePlan` | 60 sessions × 12 targeted mutations of every field the digest reads | clean |
| `elementClicksArrivePixelExact` | 5 field positions × 60/120/240 fps, control framed and centred to < 0.75 px | clean |
| `arrivalLandsInsideOneFrame` | arrival pose equals hold pose one frame later, at all three rates | clean |
| `lateClicksStillReturnToFullFrame` | click swept across the whole recording, ends exactly 1.0× centred | clean |
| `idleStretchesAreExactlyFullFrame` | before/after shots, 1.0× to 1e-5 | clean |
| `cameraHoldsStillWhileTyping` | 3 field sizes × 3 frame rates, caret walks the field | 0 px drift |
| `caretJumpDoesNotMoveTheFrame` | caret jumps end-to-end mid-burst | 0 px |
| `degenerateInputsNeverProduceABrokenCamera` | zero duration, empty log, NaN, ∞, 1×1 source, click at/past trim end, maxScale 1.0, zero-size element | clean |
| `rapidNearbyClicksStayOneShot` / `distantClicksOpenDisjointShots` | single-target invariant at both ends | clean |
| `longDenseSessionDerivesQuickly` / `evaluateIsCheapEnoughForADisplayLoop` | 60 s / 200 clicks; 40k evaluate calls | within budget |

Four real defects surfaced and were fixed:

1. **Per-tick teleports up to 0.31 of the screen.** The planner emitted
   overlapping segments and the solver sorted scenes by lead-in start, so a
   later write stomped an earlier one mid-curve. Scenes are now ordered by
   settle time; overlapping shots are impossible — a too-close subject pans
   inside the open shot (`beginScene`). The 200-seed worst tick is now below
   the 0.02 detection threshold.
2. **Velocity spike at the end of a follow path.** `rawCenter` fell back to the
   shot's *first* centre once the path ended, so a finite difference across
   that seam invented a huge arrival velocity. The path now holds its nearest
   endpoint outside the sampled window.
3. **`maxScale` was not a hard cap.** The planner floored the cap at 1.3×, so
   the Inspector's 1.2× setting silently zoomed past it. Fixed at the source,
   including `minScale` clamping.
4. **Distance to the new subject was measured from the shot's opening anchor,
   not from where the camera was looking.** Four clicks walking across a
   toolbar split into two shots. The reference is now the last path point.

The solver also bridges directly when the next lead-in starts inside the current
hold, rather than writing a backwards exit that collapses to one sample.

Doc drift is resolved: `PLAN.md §10.4` and `Docs/ZOOM-MOTION-PLAN.md` now describe
the shipped 480 Hz velocity-matched quintic solver.

### 11.8 Still open
- **Not verified visually.** No exported video was reviewed; `zoom-verify` needs
  a real recording. All numbers above are the camera track the renderer consumes.
- **One known unrelated flake.** `analyzerDecodesOverlappingBurstsInOnePass`
  (LumenAnalysis) fails under parallel suite execution because
  `AnalysisMetrics.shared` is global; it passes in isolation.

## 12. Intelligent Area crop — implemented and headlessly verified

`SmartCropConfig` lives on `Timeline` and `AppModel`; Area recordings with it
enabled capture the full display and carry a normalized content ROI instead of
a hard `sc.sourceRect`. `SmartCropPlanner` turns resolved clicks and typing
field rects outside that ROI into a quintic `CropTrack` in output time. The
compositor samples only that rect (`ContentU.cropSize`), overlays map through
it, and `LiveCamera` runs a causal equivalent for the floating preview.

`BrutalSmartCropTests` (10 suites) verifies headlessly: tight default crop,
chrome reveal and return at 60/120/240 fps, no reveal for in-content clicks,
trim + 2x ramp alignment, merged overlapping reveals, 60-seed continuity and
bounds fuzz, warm/cold value equality with an ROI-only negative test, degenerate
inputs, live convergence, and cost budgets. All pass; 97-test regression sweep
across zoom/render/audio is green.
