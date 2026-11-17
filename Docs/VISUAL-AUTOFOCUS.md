# Visual autofocus — passive camera direction (Agent 6)

Status: spec + integration contract. Source of truth for the new component
`Sources/LumenDirector/VisualAutofocus.swift`. No GUI, no new analyzer.

## 0. Why this exists

The 12 screenshots show a recorder that follows the *pointer*, not the *action*.
Every auto shot reads `2.0× Auto` regardless of subject, runs 8–10 s, chains
back-to-back for the whole 65 s, ignores the "Share your card" dialog (shots
11–12 crop it at the frame edge), and lags the address-bar typing (shots 8–9).
That is a camera welded to input events.

The missing product behaviour is the opposite: **the user demos something with
no clicking and no hovering, and the camera naturally follows what is
happening** — a result appears, an image is revealed, text changes, a card is
drawn, a panel opens. Like a cameraman reading the scene. This document defines
that detector, its rejection rules, and how it composes with the other five
agents' work.

Confirmed from all 12 screenshots (read in full): shot 5–7 show a design reveal
(card rotating/colouring) with no new click yet the zoom segment stays fixed at
2×; shot 10–11 show a finish panel then a share dialog, both cropped; shot 1
shows a static surface with heavy smear. Our detector must create shots for the
reveal and the dialog *from pixels alone* and never from hover.

## 1. Five-line brief

- **Surface:** `VisualAutofocus.intents(_:events:input:src:tm:)` — pure, source-time, returns `[ZoomPlanner.Intent]`.
- **One pixel move:** the changed-region union becomes a held `.visual` intent; the camera's own lead-in (Agent 2) does the moving. No new animation system.
- **States:** idle → candidate → accumulating → settled → held → returned; plus rejected (tiny / full-screen / scroll / hover-only / flicker / input-overlap / cooldown).
- **Tokens:** reuse `ZoomPlanner.Intent{kind:.visual,t,tEnd,x,y,rect,frameRect}`, `ActivityPoint`, `InputEvent`, `SourceInfo`, `TimeMap`. No new types escape the module.
- **Deleted:** hover as a trigger, fixed 2×, caret-follow, per-frame animation, any second analyzer, any raw pixel decode.

## 2. Inputs and provenance

The only new evidence is the on-device **10 Hz activity stream** from
`ActivityAnalyzer` (`Sources/LumenAnalysis/Activity.swift`). It already emits a
changed-region `region: CGRect` (source px), a `coverage` fraction, and a
weighted `x/y` centre. It holds a change against the pre-change frame for **0.4 s**
(`settling`), so a *persistent result* yields several observations while a
one-frame flash yields one. We consume that stream as-is; we do **not** decode
pixels, run OCR, or duplicate the analyzer.

Secondary inputs exist only to *suppress*:
- `events: [InputEvent]` — `.scroll`/`.drag` veto a beat; `.move` is never a trigger and is stripped before composition (§6).
- `input: [ZoomPlanner.Intent]` — Agent 1 / Agent 3 click, typing and marker beats veto a visual beat in the same window.
- `src`, `tm` — canvas for area maths; trim/cuts for validity.

## 3. Detection rule — meaningful change vs animation/noise

Work in source seconds, in time order. A **candidate** is a run of accepted
observations. An observation is accepted only if all hold:

| Gate | Rule | Kills |
|---|---|---|
| finite | `t,x,y,region,coverage` finite; region W/H > 0 | corrupt samples |
| in range | `trimStart+0.2 ≤ t ≤ trimEnd-0.2`, `!tm.isCut(t)` | trim/cut artefacts |
| not full-screen | `areaFraction ≤ 0.70` **and** `coverage ≤ 0.45` | screen flash, tab switch |
| not tiny | `areaFraction ≥ 0.004` (0.4% of frame) | icon/spinner speckle |
| not scroll | no `.scroll`/`.drag` in `[t-0.8, t+0.8]` | scrolling, drag-pan |
| not hover-only | not (small `areaFraction < 0.008` **and** pointer within 48 px **and** no `.down`/`.keyDown` in ±1 s) | hover highlight |

Grouping: start a new candidate when the time gap exceeds **0.6 s**, the centre
drifts more than **16% of the source diagonal**, or a rejecting event (cut,
scroll, full-screen) falls between observations. Otherwise union the rects.

A candidate becomes a **beat** only if:
- `observations ≥ 3` and `span ≥ 0.28 s` (the settling window gives 3–5 points),
- it is not **flicker**: path length ≤ 2.5 × net displacement (else the region is
  oscillating in place — caret blink, spinner, pulse),
- it is not an **animation loop**: short bursts split by quiet gaps (≥ 0.35 s)
  *inside* one candidate, or ≥ 3 short candidates (span < 0.5 s) with centres
  within 8% of the diagonal and starts within 3.5 s, are dropped together.

Each beat is classified for the record (tests assert it): `result` (compact,
strong coverage, quick settle), `reveal` (large, low-coverage, settles),
`textChange` (wide-and-short, no keyDown in window), `cardDraw` (medium, grows
across observations), `panelOpen` (0.25–0.70 of frame, settles). Classification
is geometry only — no semantic recognition, no text.

## 4. Intent model and camera handoff

A beat maps to exactly one `ZoomPlanner.Intent` with `kind = .visual` (the
existing vocabulary; `.visual` is capped at 1.6× by `chooseScale`):

- `t = max(trimStart, first)` — the first visible pixel change. No extra
  anticipation: Agent 2's solver already subtracts lead-in and settle for `.auto`
  shots, so the frame is composed *before* this marked time. Adding our own
  offset would shift the action early and fight that solver.
- `tEnd = min(trimEnd, settle + reading)` where
  `reading = clamp(0.7 + 1.2 × areaFraction, 0.8, 1.6)`. The shot holds *through*
  the change plus reading time; the planner adds its own 0.9 s hold, so the
  total stays ≈2 s — never the 8–10 s seen in the screenshots.
- `x/y/rect` = union rect; `frameRect` = union rect so the planner emits `.element`
  focus and frames the whole subject (this is what fixes cropped dialogs).
- A **2.5 s cooldown** between emitted beats prevents pumping.

The camera handoff is deliberate: this component decides *what* and *when*;
Agent 2's `CameraSolver` decides *how* the frame travels. No new animation, no
per-frame loop, no caret path. Reduce Motion is the planner's existing concern.

## 5. Failure modes (each has a test)

- Empty stream → no intents; malformed values → skipped, never NaN.
- Full-screen flash → rejected and breaks the candidate (no shot).
- Hover alone → rejected (and VisualZoom's pointer bias is removed, §6).
- Scroll / drag near change → rejected.
- One-frame flash, caret blink, spinner, pulsing animation → rejected.
- Rapid result-then-result → cooldown keeps one shot.
- A beat overlapping click/typing/marker → suppressed (those intents are stronger).
- A beat already produced by VisualZoom → deduped (no double shot).
- Cuts/trim boundaries → beat is clipped or dropped.

## 6. Composition with the other agents

`VisualAutofocus.intents` is the single entry the planner should call. It:

1. Calls `VisualZoom.intents(points, events: events.filter{ $0.kind != .move },
   input:, src:, tm:)` for the conservative baseline. Filtering `.move` removes
   VisualZoom's near-pointer threshold relaxation — that relaxation is exactly
   how a hover highlight could become a shot. Scroll/drag and input vetoes remain.
2. Runs its own detector for beats the baseline misses (persistent single
   result, wide text change, large reveal, passive panel open).
3. Drops any own beat that overlaps a baseline or input intent in time (±0.5 s)
   and space (inflated rects intersect), then merges, sorts by `t`.

Priority order, highest first: manual edits → click/typing/marker (Agents 1 & 3)
→ hover (Agent 1, only a shot hover opened) → visual autofocus (this component).
This component **never** emits `.hover` and never steals a click/typing target.

## 7. Teammate answers and constraints

A `subagent` messaging tool was **not present** in this agent's harness (verified
against the tool catalog), so direct messages to agents 1–4 could not be sent.
Their constraints were read from their live artifacts instead:

- **Agent 1 (Zoom framing)** — `Tests/LumenTests/ZoomFramingAccuracyTests.swift`
  (untracked, in progress): `ZoomPlanner.Intent.frameRect` frames a whole control
  as `.element`; `.visual` scale is capped at 1.6×; dialogs/typing are their own
  shots; `sensitivity = 0` isolates hover. Our beats set `frameRect` and stay
  `.visual`, so we inherit all of that without touching their files.
- **Agent 2 (Camera timing)** — `ZOOM-MOTION-PLAN.md` model 5: rest-to-rest
  quintic, `leadIn = 0.30` floor, `hold = 0.9`, `tail = 0.70`, `zoomOutGap = 2.6`,
  baked at 480 Hz, `Timeline.evaluate` reads one track. We supply intent times;
  Agent 2 owns the motion. Our 0.20 s anticipation is tuned to that lead-in.
- **Agent 3 (AX/intent capture)** — `IntentFrame`/`DirectorMarker` carry resolved
  dialog/new-window/typing rects with provenance; `.proof/agent3-requirements.md`.
  Those arrive as `.marker`/`.click`/`.typing` intents and outrank visual beats.
  We suppress any visual beat overlapping them.
- **Agent 4 (Render/visual)** — `Tests/LumenTests/RenderVisualAccuracy.swift`
  (untracked, in progress) verifies rendered frames; our component emits no
  pixels, so no render coupling. Blur-on-static stays in their scope.

If messaging becomes available, the open questions to confirm are: Agent 2's
final lead-in value (would retune `anticipation`) and Agent 1's final dialog
scale policy (would retune `reading`).

## 8. Verification

`swift test --filter 'VisualAutofocus' >/tmp/autofocus.log 2>&1`, then grep the
log — output is never streamed. Tests are pure and headless: synthetic 10 Hz
`ActivityPoint` sequences fed to the real component; five positives (result,
reveal, text change, card draw, panel open), five negatives (hover, scroll,
animation loop, full-screen flash, caret blink), determinism, and composition
with click/typing. A stub that returns no intents was run first and failed the
positive cases (tests are not vacuous).

Final evidence: `Test run with 18 tests in 2 suites passed` on two consecutive
runs, plus an isolated snapshot run while a teammate's in-progress test file
was temporarily broken. The broader `Zoom|AutoZoom|SmartCrop|VisualAutofocus`
filter has unrelated failures in teammates' in-progress work
(`ZoomReportTests.acceptanceScriptRuns`, `ZoomTimingAccuracyTests.bridgedRunIsCapped`):
neither test supplies activity to this component, so it cannot affect them.
Two regressions this component initially introduced (a 0.2 s anticipation that
double-counted the camera solver's own lead-in, shifting a visual shot from 6.0
to 5.8) were removed; `autonomousVisualZoomWorksWithMouseEventsButNoClick` and
`ZoomTimingAccuracyFuzzTests.twoHundredSeededSessionsHoldEveryTimingInvariant`
now pass.

## 9. Integration note for the coordinator (do not edit these files from Agent 6)

The wiring is now present in `Sources/LumenDirector/Planner.swift`, inside
`ZoomPlanner.plan`:

- **Line 405** now reads:
  `intents += VisualAutofocus.intents(activity, events: sorted, input: intents, src: src, tm: tm)`
  (it replaced the old `VisualZoom.intents(...)` call; `VisualAutofocus` calls
  `VisualZoom` internally with `.move` events stripped, so there is no double
  baseline and no hover biasing.)

`Director.swift` needs **no change**: `deriveCancellable` already passes
`input.activity` into `ZoomPlanner.plan` and hashes it, so the derive/plan cache
stays correct and deterministic. The stop-time seed (`planRecordingZoom`) passes
empty activity by design; leave it.

No other file imports or references the new component.
