# Dedicated agent plan: effortless zoom-in and zoom-out

## Goal

Make Lumen's zoom feel continuous, immediate, and natural. The current experience feels forced, jerky, and robotic. **Solve that with less machinery: fewer target changes, one coherent motion curve, correct timing, and stable frame delivery.** A longer animation or stronger blur is not a fix.

This is an implementation handoff, not a claim that the application is fixed. Source inspected at `9b0a211`. Read `AGENTS.md`, `RULES.md`, `GIT-SKILLS.md`, and `PLAN.md` before implementing. This plan refines the motion portion of [the broader Studio handoff](STUDIO-RELIABILITY-HANDOFF.md); it does not expand into audio, privacy, or an editor redesign.

## What “zero lag” means

- In recorded footage, use the known upcoming interaction to begin a deliberate move beforehand. Arrive at the useful framing when the click/typing happens. Do not delay the recording, audio, or event timestamps to make the camera appear synchronized.
- During sustained typing, keep the caret visible without a camera that constantly chases its previous position. Keep a stable frame while the caret has room; move before it runs out of room.
- In genuinely live input, respond on the next available display tick and ease from the current state. Future events are unavailable; do not promise instantaneous arrival at an unknown distant target. Measure input-to-motion latency separately from transition duration.
- Smoothness includes the whole zoom-out and its last few frames. No final snap, asymptotic crawl, bounce, repeated settling, or recentering twitch.

## Start with these source-level suspects

These are observations to test, not proven explanations of the reported appearance:

| Location | Observation | First investigation |
|---|---|---|
| `Sources/LumenDirector/Planner.swift`, `smoothPath` and `follow` | Caret fixes are smoothed, then scene/path updates are gated by thresholds and a **2.4-second** minimum interval. | Plot raw caret, planned path, and camera together. Does sparse target publication produce stop→catch-up motion or miss the active line? |
| `Sources/LumenDirector/Camera.swift:196–210, 348–370` | The path then enters another exponential follower with `omega: 8`. | Measure added phase/settling delay. An unconstrained first-order step at this omega takes about 290 ms to reach 90%; this is not a measurement of the whole camera. |
| `Camera.swift:310–374` | Quintic transitions hand control to a different follower; some handoffs reconstruct state from the target path rather than the actually displayed trajectory. | Compare position, velocity, and acceleration on both sides of each handoff. Preserving position alone does not preserve motion. |
| `Camera.swift:383–403`, `Sources/LumenProject/Derived.swift`, `Sources/LumenDirector/Director.swift`, `qhm` | Camera samples get estimated monotone velocities, but acceleration arrays remain initialized to zero. Evaluation reconstructs a quintic between every sample using those derivatives. | Check intermediate times between the 240 Hz samples for repeated easing/acceleration artifacts. A smooth coarse sample plot can miss them. |
| `Camera.swift:241–289` | Closely spaced intents can compress durations to meet arrival deadlines. Zoom-out has separate timing rules. | Find rushed moves, brief zoom-out→zoom-in reversals, and direction changes caused by scheduling. |
| `Sources/LumenUI/PreviewView.swift:174–198` | After a slow decode, presentation/camera time can advance while the decoded source still belongs to the earlier request. | Check source PTS, evaluated camera time, and actual presentation together. Distinguish an intentional held source frame from stale-content mismatch. |

The existing `Sources/LumenCore/Motion.swift` already supplies `QuinticMove` with position/velocity/acceleration endpoints. Reuse it. Do not start by adding another spring, smoothing pass, prediction system, or animation library.

## The intended motion

One scene follows this rhythm: **approach → arrive → hold/read → leave**. Nearby related actions continue the same scene. A new keystroke does not restart the entrance. A segment boundary does not require stopping the camera.

1. **One owner of the final camera pose.** The planner decides meaningful targets and timing; one motion evaluator produces pan and log-scale. Input cleanup may remove measurement noise, but no downstream filter should ease an already-eased camera again. Keep a cleanup pass only when a fixture proves it necessary.
2. **Reuse the existing quintic for deliberate moves.** For a rest-to-rest move, use the minimum-jerk progress `s(u) = 10u³ − 15u⁴ + 6u⁵`, with `u = clamp((t − start) / duration, 0, 1)`. Evaluate `logZoom = log(z0) + (log(z1) − log(z0)) × s(u)`, then exponentiate. The endpoint is reached exactly at the specified end time.
3. **Coordinate pan and scale.** Use a common transition interval so the camera does not zoom first and drag the subject into place afterward. Preserve the current bounded pan representation unless evidence identifies it as the defect. Check the actual projected subject path and viewport throughout a move, including zoom-out; endpoint bounds alone are insufficient.
4. **Keep momentum when interrupted.** Sample the current curve's actual position, velocity, and acceleration at the interruption, then seed the next `QuinticMove` from that state. Do not restart from rest, stale segment centers, or raw target velocity. Choose a feasible duration/target; inherited momentum can cause overshoot even with a quintic. Do not hide that by hard-clamping each frame.
5. **Keep typing framed, not constantly centered.** Reserve room ahead of the caret and leave the camera still inside that useful region. For recorded footage, anticipate an impending exit using the known caret path. Produce a continuous target trajectory with matching handoff derivatives. Remove artificial multi-second update gates when the fixture demonstrates lag; do not replace them with per-key scene restarts.
6. **Make the exit the same quality as the entrance.** Return to scale 1 and the intended full framing on one finite curve. Do not immediately zoom out when an imminent related action makes staying zoomed more useful. Never force a brief return to full frame between related targets.

Do not add random asymmetry or “humanized” motion. Naturalness comes from choosing when to move, holding when reading, and carrying motion through a change of target.

## Tuning policy

Use the existing controls. The following are initial review values for typical 1.5–2× moves, not measured final defaults or new preferences:

| Quantity | Starting point |
|---|---|
| Zoom-in duration | 500–650 ms; start review at 550 ms. |
| Zoom-out duration | 650–850 ms; start review at 750 ms. |
| Reframing while already zoomed | 250–450 ms for an ordinary nearby target. |
| Subject placement | Keep the clicked location accurate; keep the active text line and room ahead visible. |
| Recorded-event timing | For an isolated event with sufficient lead-in, finish by the event; preserve source/audio timing. |

Map those durations through the existing parameter contract deliberately; `omegaZoom` is currently used in duration formulas, not only as a physical spring frequency. Preserve saved manual easing choices. Allow modest distance-dependent duration within measured bounds; do not introduce a different curve per event type.

**Do not crush a large move into a tiny available gap just to pass an arrival percentage.** Merge a related scene, keep the useful current view, or use a shallower framing that includes both targets. At the start of a clip with no lead-in, choose an explicit initial composition for an immediate known action or a bounded entrance with the target visible. No invisible pre-roll or one-frame jump.

## Implementation order — stop adding machinery once it works

### 1. Capture a short baseline and identify the dominant defect

Use one deterministic 15–30 second fixture: isolated click, sustained typing with the pointer elsewhere, line wrap, nearby second click, an interrupted exit, then enough idle footage to see the entire exit. Include an edge target. Record preview and export with the same settings. First review with motion blur and tilt off; then restore the user's enabled content effects.

Overlay planned targets and evaluated camera data in debug output only. Plot `logZoom`, screen-space subject position, velocity, and acceleration. Inspect both semantic transition boundaries and times between stored samples. Separate wrong targeting, filter delay, curve discontinuity, and missed display deadlines before editing.

**Verify:** save the baseline clip and a failing regression that isolates the demonstrated defect. Reuse existing zoom/motion tests. Do not build a general benchmark platform.

### 2. Repair the motion contract with the smallest change

Start in `Camera.swift`, `Planner.swift`, and the existing `QuinticMove` path. Correct demonstrated follower/handoff and target-publication defects before adjusting the feel. Preserve one coherent output curve and explicit held intervals.

Fix sampled interpolation using the existing camera-track contract: publish derivatives consistent with the actual transformed trajectory, and ensure `qhm` reproduces that trajectory between samples. Do not manufacture zero-acceleration endpoints at every stored sample. Only evaluate compiled segments directly if it demonstrably simplifies the code more than repairing the existing representation; do not ship both competing paths. Keep the 240 Hz solve rate initially.

**Verify:** focused continuity, interruption, sub-sample, focus-visibility, and bounds tests. Check actual projected motion after interpolation and clamping, not just the internal scalar polynomial.

### 3. Tune timing and scene continuity

Review the starting durations above on the same fixture. Fix only the parameter mapping and scene boundaries that cause forced entrances, unnecessary exits, or repeated easing. Keep the subject readable throughout typing. Prefer fewer well-timed moves over a camera that reacts to every event.

**Verify:** compare original and final clips side by side at normal speed, then at quarter speed. Both entrance and exit must improve. Do not trade smoothness for delayed typing focus.

### 4. Repair presentation only where traces show it is responsible

In `PreviewView.swift` and the existing frame source/renderer, keep pose, source sample, and scheduled presentation consistent with the same playback clock. Drop obsolete work and present the newest useful frame; do not queue delayed camera states. Preserve sample-and-hold semantics for lower-rate source footage. Do not remove existing presentation slack blindly; reduce it only if measured deadlines remain reliable.

**Verify:** real 60/120 Hz preview under normal background analysis, plus 60/120/240 fps exports. A higher export rate does not create extra captured screen frames. If export is smooth and preview hitches, fix preview delivery rather than repeatedly changing the curve.

## Acceptance criteria

- Isolated recorded click/typing with sufficient lead-in: reach at least 95% of planned log-scale by the event within one output frame, with the subject correctly framed. Dense-action/clip-start fixtures use the explicit fallback above, not impossibly compressed moves.
- No stop→lurch on typing updates, no pointer-away focus theft, no unnecessary full-frame flash between related targets, and no last-frame snap on zoom-out. Correct focus evidence is an input requirement; use the broader handoff if capture lacks it.
- Verify C2 continuity at semantic handoffs: matching position, velocity, and acceleration in the evaluated trajectory. Set unit-aware numerical tolerances from deterministic fixtures. Also sample between storage ticks and compare to the generating curve; do not prove continuity by checking only identical sample endpoints. C2 does not mean continuous jerk, so do not add a higher-order solver merely for that label.
- At rest, the finite curve reaches its specified endpoint and stays there. Rest-to-rest scale is monotonic, with no overshoot. Interrupted reversals preserve continuity and bounds rather than being forced to satisfy an incompatible monotonicity rule.
- Viewport bounds and caret visibility hold across edge targets, portrait/landscape output, cuts, speed ramps, and seeks. Presets/manual zooms still work. Preview and export agree at equal output time with equal render options.
- Preserve the existing spectral gate of <1% camera trajectory energy above 8 Hz, but do not use it as the sole quality test. In `Tests/LumenTests/MotionTraceTests.swift`, the current `maxJerk` helper is not asserted; its existence is not jerk coverage. Add a meaningful bounded-motion assertion where the new regression needs one.
- Zero added time-map offset to synchronize the camera. Live input-to-first-visible-motion target: within two display intervals under the measured supported workload; report actual p95 latency and missed deadlines instead of claiming literal zero physical latency.
- Preserve existing GPU frame budgets: <8 ms at 60 Hz and <4 ms at 120 Hz on the reference supported machine. Do not increase solve rate, blur samples, workers, or memory to hide the defect. This camera math belongs on the CPU; investigate GPU scheduling only for measured presentation/render bottlenecks.
- Normal-speed before/after review is mandatory. Numerical continuity alone can still feel robotic. The final result should feel like one deliberate move, a stable hold, and one relaxed release.

## Files and verification

Start with `Sources/LumenDirector/{Camera,Planner}.swift`, `Sources/LumenCore/Motion.swift`, `Sources/LumenProject/Derived.swift`, and `Sources/LumenDirector/Director.swift`. Touch `Sources/LumenUI/PreviewView.swift` only for a proven delivery issue. Reuse `Tests/LumenTests/{ZoomEasingTests,ZoomPrecisionTests,MotionTraceTests,ZoomTransformTests,AutoZoomRegressionTests}.swift` and the existing CLI verifier. Update conflicting motion documentation in the same implementation change.

```sh
swift test --no-parallel --filter 'zoom|Zoom|camera|Camera|motion|Motion|caret|Caret'
make test
make verify
swift run --skip-build lumen-cli smoothness "$PROJECT"
swift run --skip-build lumen-cli zoom-verify "$PROJECT" --video "$EXPORTED_VIDEO" --out "$REPORT"
```

Use the existing marker/caret verification fixture for `zoom-verify`; arbitrary footage is not sufficient. Confirm tests actually run. `make verify` does not replace playback inspection or hardware frame-pacing measurements.

Deliver the smallest reliable patch, the removed/simplified motion layers, the final timing values, passing regression results, measured latency/frame delivery, and a short before/after clip showing the full entrance, typing hold, interruption, and exit. Do not declare success from an easing formula alone.

## Implementation status

The solver is `CameraSolver.solve` in `Sources/LumenDirector/Camera.swift`; the
plan below is the shipped behaviour, and `PLAN.md` §10.4 is the reference.

- One degree-5 Hermite per channel (log zoom, pan x, pan y) with position,
  velocity and acceleration at both ends, so C2 holds at every handoff.
- Durations: zoom-in 550 ms, zoom-out 750 ms, same-scale reframe 350 ms,
  scaled by easing and a capped distance term, clamped to 220–950 ms.
- Auto shots lead by `leadIn` so the camera arrives *on* the click.
- The follow target is a two-pass dead-zone plus a zero-phase Gaussian, so it
  neither trails constant motion nor chases wiggles.
- `nx, ny, lz` and their first and second derivatives are published at 240 Hz,
  differentiated through `centre = 0.5 + pan·margin(z)`, and evaluated with the
  same Hermite.
- Gates: `motionTracesAreSmooth`, `cameraTrackPublishesAcceleration`,
  `evaluatedAccelerationHasNoTickBoundaryStep`,
  `handoffsKeepAccelerationContinuous`, `zoomOutReachesFullFrameAndStays`,
  `typingKeepsCaretFramedWithoutTrailing`.

Not measured here (needs a real project and hardware): the before/after motion
clips, p95 input-to-first-visible-motion, and the 60/120/240 fps frame budgets.
