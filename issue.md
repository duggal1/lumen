# Lumen — Core Motion & Zoom: Real Issues

Audit date: 2026-11-16. Scope: the four things the user says are broken.

1. Hyper-smooth zoom in/out, with real upscaling (not 60 fps, not 1.4×).
2. Where the zoom lands when typing (accuracy is "almost 0").
3. Motion tracking beyond clicks (cursor, hover, visual change).
4. Natural intent instead of a robotic, static camera.

Method: read the full Director → Render → Capture → Analysis path, the UI
bindings, the models, and the existing test contract. Reproduced the current
behaviour against the test suite. No guessing: every item below names the code
that causes it.

---

## A. Zoom motion is not actually finite, and the controls are dead

### A1. The camera is a zero-phase spring, so it never truly arrives or rests
`CameraSolver.solve` builds a step target and calls `zeroPhaseSmooth`
(forward + backward critically-damped spring) on `lz`, `cx`, `cy`
(`Sources/LumenDirector/Camera.swift:139-142`). A zero-phase filter is
non-causal and exponential:

- The zoom-out starts *before* the shot ends (the backward pass smears the
  fall backwards in time).
- The zoom never reaches exactly 1.0. Measured: 0.7 % residual at 4.2 s in
  `MotionTraceTests.zoomOutReachesFullFrameAndStays` (fails today).
- Because the tail is exponential, the next scene's lead-in overlaps a
  non-zero scale, which reads as "breathing" / a double move.

There is no explicit zoom-in duration, hold duration or zoom-out duration.
`CameraParams.tail` is never read anywhere.

### A2. `leadIn` is the only timing control, and it is fixed at 0.30 s
The zoom starts `p.leadIn` before the event. For a 2× zoom that is not enough
for a settled arrival; for a 1.2× zoom it is too early. The UI "Smoothness"
slider is bound to `leadIn` (`Inspector.swift:585`), not to the response speed.
So the control the user reaches for does not do what it says.

### A3. The primary "Zoom amount" slider is dead in auto mode
`Inspector.swift:588` binds "Zoom amount" to `camera.baseScale`. `Planner`
never reads `baseScale` except for the `.fixed` preset
(`Planner.swift:159-163`). In auto mode the scale comes from `maxScale`,
`minScale` and element size. Moving the slider changes nothing. This is the
single biggest "it feels static" cause: the main zoom control is disconnected.

### A4. The 6.0× "Max zoom" slider is a lie
`Planner.hi = clamp(p.maxScale, 1.3, 2.6)` (`Planner.swift:166`). The UI
offers 1.2…6.0. Any value above 2.6 is silently ignored. The user's "10×"
request cannot be expressed at all.

### A5. Click zoom is capped at 1.7×
`chooseScale` for a click without an AX rect returns `clamp(1.7, lo, hi)`
(`Planner.swift:277`). With an AX rect it is `clamp(min(fit, 1.7), lo, hi)`
(`Planner.swift:276`). A click never zooms past 1.7×, regardless of settings.
For a large element, `fit < 1.2` and the click produces **no zoom at all**
(`Planner.swift:275`).

### A6. Unused camera parameters
Read by nobody: `sensitivity`, `clickWeight`, `minTrigger`, `lookahead`,
`mergeGap`, `panThroughGap`, `tail`
(`Sources/LumenProject/Models.swift:230-255`). These are the exact knobs that
would produce intent-sensitive, anticipatory motion.

### A7. 240 Hz camera track is the same rate as the highest output
`CameraSolver` bakes at 240 Hz (`Camera.swift:43`). Export supports 240 fps
(`Capability.rates = [24,30,60,120,144,240]`). At 240 fps output there is one
camera sample per frame, so `qhm` reconstruction has no headroom and any
derivative error is visible as a step. The track should be 2–4× the output
rate.

---

## B. Typing accuracy

### B1. The largest AX field wins, not the field with the caret
`caretFixes` collects every key's AX frame and then
`biggest = fields.max { $0.width * $0.height < $1.width * $1.height }`
(`Planner.swift:110`). A browser or document window is a single AX element
larger than the text field. It wins, so the zoom frames the window and the
caret is a few pixels somewhere inside it. This alone explains "accuracy 0"
on real recordings.

### B2. No provenance check on the caret frame
Clicks validate AX with `usableAX` (size + position + slack). Carets only check
finite and bounds (`Planner.swift:94-105`). A stale frame from another app, or
an unresolved placeholder (`AXFrame(x:0,y:0,w:0,h:0, anchor.resolved=false)`),
is treated as evidence. The analysis service does check `anchor.resolved`
(`Service.swift:466-470`); the planner does not.

### B3. One focus query at a time, plus an artificial 25 ms delay
`reserveFocus` allows a single in-flight AX query and queues the rest
latest-wins (`Input.swift:500-515`). `focusQ.asyncAfter(deadline: .now() + delay)`
uses `debugFocusDelay = 0.025` in production (`Input.swift:216, 511`). During a
typing burst most key events therefore carry an unresolved slot, and the
planner falls through to the pixel tracer or to nothing.

### B4. No "last good caret" fallback
`cachedFocusFrame()` exists for live delivery (`Input.swift:517-522`) but is
never published into the AX array. The planner only sees the event's own slot.
A 1.5 s-old caret from the same field is better evidence than nothing, and it
is thrown away.

### B5. Typing with no click within 20 s produces no zoom
`Planner.swift:196` requires `lastClick` within 20 s. A user who clicks into a
field, reads for 25 s, then types gets no zoom. There is no hover/dwell anchor
and no OCR anchor fallback.

### B6. Typing near the end of the recording is dropped
`ok(t)` requires `t <= tm.trimEnd - 0.8` (`Planner.swift:165`). The last 0.8 s
of typing is always dropped.

### B7. Typing framing bias is arbitrary
`typingCenter` shifts the camera right by `0.24 * half`
(`Planner.swift:252-254`). There is no relation to the field width, the caret
velocity, or the reading direction. The caret sits at 38 % of the viewport,
which is okay, but it is a magic number and it is applied even when the caret
is already centred.

---

## C. Motion tracking beyond clicks

### C1. Every auto zoom is `.fixed`
`close()` appends `focus: .fixed(x: o.c.x / W, y: o.c.y / H)`
(`Planner.swift:223-224`). The camera therefore never moves inside a shot.
`CameraSolver` has a full cursor-follow path (`followX/followY`,
`centredPlay`, dead zone, `p.followDelay`), but `needsCursor` is only true for
`.follow` segments, and the planner never emits one. The result is exactly what
the user describes: motion tracking works "apart from clicking" because only
clicks create scenes, and once created they are frozen.

### C2. No hover / dwell intent
A user who moves to a control, pauses, reads, and moves on produces no zoom.
There is no dwell detector anywhere. `sensitivity` (0 = clicks only,
1 = purposeful hovers count) is documented but unimplemented.

### C3. No look-ahead
`p.lookahead` is unused. The camera reacts to the path, never anticipates it.
`Screen Studio` starts the move early and settles before the action; our
`leadIn` is the only anticipation and it is a constant.

### C4. Visual activity is over-constrained
`VisualZoom.intents` (`VisualZoom.swift`) requires:
- `coverage >= 0.002` and `<= 0.35`
- `rect.area >= 0.008 * screen` and `<= 0.55 * screen`
- `count >= 3` points, each within 0.6 s
- no click within ±1 s, no scroll/drag within ±0.8 s
- `rect.midY > 0.08 * H`

Real content changes (a panel opening, a chart updating, a terminal line) are
smaller or shorter than this. The feature is effectively off. It also ignores
where the cursor is, which is the strongest available intent signal.

### C5. Retargeting splits the scene and restarts the move
`retarget` closes the current scene and opens a new one whenever the target
moves > 0.12 of the half-view (`Planner.swift:228-236`). Each split gets a new
lead-in and a new whoosh pair, so a continuous gesture becomes a series of
small moves. This is the "robotic" feel even when the individual moves are
smooth.

### C6. Cursor path is not used as a follow path
The cursor pipeline produces a smoothed `CursorTrack`, but the planner runs
before it and never reads it. The only continuous path is the typing caret.
So the camera cannot glide with the pointer.

---

## D. Upscaling

### D1. The ladder is capped at 8 in the default params
`UpscaleParams.maxFactor = 8` (`FXModels.swift:16`). The renderer overwrites
it from `camera.upscaleMaxFactor` (default 10), so the camera path can reach
10×, but the default model and any other consumer cannot. The ladder itself is
`{2,3,4,5,6,8,10}` (`Upscaler.swift:32`).

### D2. The crop is quantised to 64 px
`Upscaler.quantize(..., grid: 64)` (`Upscaler.swift:61`). While the camera
drifts, the crop stays fixed for up to 64 source px, then jumps. The margin is
8 px, so a jump can pull the sampled region by up to 64 px with no content
outside the view. On a slow zoom this reads as a "swim" / micro-jump. It is a
smoothness defect in the upscaler, not a quality defect.

### D3. `blendStart = 1.5` means no upscale at 1.4×
That is correct, but combined with A5 (click zoom capped at 1.7×) the upscaler
is only engaged in a narrow band. Users never see the 10× path.

---

## E. Capture / analysis evidence

### E1. `ActivityAnalyzer` is 10 fps, 80×50 luma, delta ≥ 24
(`Activity.swift:5, 68-79`). A caret or a spinner changes a handful of cells
below the threshold. The 0.4 s "settling" hold (`Activity.swift:80-84`)
smears one change across half a second. This is why visual intent is weak.

### E2. `TypingTracer` anchor is only the first AX event in the burst
`Service.swift:459-471` takes the first key with a frame. If that one is
unresolved, the trace runs unanchored and can lock onto the wrong line.

### E3. `typingBursts()` treats option-arrow navigation as typing
`Core.swift:183` filters `.keyDown`, no cmd/ctrl, keyCode < 53, not
36/48/51. Option-left/right (keyCode 123/124 with flags 0x08) are included.
A user navigating a text field with option-arrows produces a typing burst.

---

## F. Reference repo (recordful) — what is actually worth taking

`recordful` is a Chrome extension. Its zoom is a live CSS transform
(`ZoomContainer.jsx`): `scale(1.5) translate(...)` with
`transform-origin: cursorX cursorY`. It is not cinematic and its transition is
a single 0.5 s CSS ease. Do **not** copy the motion.

Worth taking (ideas only, re-implemented natively):

1. **Anchor the zoom at the pointer, not the viewport centre.** Their
   `transform-origin` is the live cursor. Our camera already does this for
   typing (`typingCenter`); generalise it to all intents via the follow path.
2. **Map client coords to screen coords through window bounds.** Their
   `placed()` sends `screenX/screenY`, `windowLeft/windowTop`,
   `outerWidth/outerHeight` with every sample
   (`recordful/src/pages/Content/cursor/trackClicks.js:56-75`). Our capture
   already converts to source pixels once (`Input.swift:414`), which is the
   same idea done correctly.
3. **Send the clicked control's DOM box, not just the point**
   (`trackClicks.js:106-113`). Our AX element rect is the equivalent; the fix
   is to use the *smallest* one (B1), not to add a new one.
4. **Batch pointer samples with monotonic timestamps** (`trackClicks.js:139-151`).
   We already record every move; the fix is to *use* them (C6).

Everything else in recordful (the extension UI, the canvas, the WebCodecs
recorder) is worse for this product and is ignored.

---

## G. Test contract today

Baseline `swift test` on the zoom/motion suites:

- 32 tests, 3 failing:
  - `clickFocusIgnoresLargePopupAXFrameCenter`
  - `oversizedPopupDoesNotForceCursorFollow`
  - `zoomOutReachesFullFrameAndStays`

The first two are stale assertions: they demand the *segment focus* equal the
raw click, but the planner correctly clamps the focus to the feasible viewport
(the click at y=300 with scale 1.7 is outside the feasible centre range). The
real guarantee — the evaluated camera contains the click — is what the test
should assert.

The third is a real defect (A1): the exponential tail leaves 0.7 % scale at
4.2 s.

These are the only existing failures; the rest of the suite is the contract the
rewrite must keep green.

---

## H. Priority order (impact × confidence)

1. **A1** finite C2 camera (fixes smoothness + the failing zoom-out test).
2. **B1/B2** smallest containing AX field + provenance (fixes typing accuracy).
3. **C1/C6** follow paths for every auto shot (fixes motion tracking).
4. **A3/A4/A5** make the zoom controls real and allow 6× (fixes "not 10×").
5. **C2/C3** hover intent + look-ahead (fixes "robotic / no intent").
6. **B3/B4** capture-side last-good-caret + lower focus latency (fixes fast typing).
7. **C4/E1** relax visual activity (autonomous zooms on real content).
8. **D2** finer upscale crop quantisation (removes swim).
9. **A7** 480/960 Hz camera track (headroom at 240 fps output).
10. UI sliders for the newly-wired parameters; tests for each.