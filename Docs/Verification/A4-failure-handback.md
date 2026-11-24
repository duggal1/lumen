# A4 hand-back: two full-suite failures are not A4 regressions

Agent cw-8479. Command used for every run:
`CW_ID=8479 .comms/bin/cw build -- swift test --no-parallel --filter 'BrutalZoomSweepTests|ZoomArrivalAccuracyTests'`

## 1. Baseline — CURRENT tree, A4 changes ON

| Test | Result |
|---|---|
| `elementClicksArrivePixelExact` 60 fps | FAIL: case 0 t=1.517 centre (535.29,301.10) != (532.41,299.48); case 2 (1384.71,301.10) != (1387.59,299.48); case 3 (535.29,778.90) != (532.41,780.52) |
| same, 120 fps | identical numbers, t=1.508 |
| same, 240 fps | identical numbers, t=1.504 |
| `caretSelectsTheSmallestContainingField` | FAIL `warm.zoom.count == 1` — actual `warm.zoom.count == 0` |

Residual is constant (+2.88 / −2.88 x, +1.62 / −1.62 y) across all frame rates → spatial, not timing.

## 2. Controlled comparison — A4 behaviour OFF, same tests

Method (no test file touched):
- Backed up `Sources/LumenDirector/Crop/CropPlanner.swift` and `Sources/LumenDirector/TypingFocus.swift` to `/tmp/a4-controlled-backup/`.
- `CropPlanner`: replaced the aspect-fitted `.content` case with the exact HEAD expression
  `web.at(t).insetBy(s.insetPx).intersection(source)`.
  `TypingFocus`: replaced `shots()` with the byte-for-byte `git show HEAD:...` body.
  New declarations (`Caret`, `exitDebounce`, `carets`, `aspectFit`, `contentRect(fromEdges:)`) were kept
  solely so the test target still compiles; they are not used by these two tests.
- `Capture.swift`, `WindowContent.swift`, `ChromeDetector.swift` were left in place: neither test
  supplies `DirectorInput.viewportSamples`, so no crop/capture/WindowContent code is on the
  `Director.derive` path for them.

Result: **byte-identical failures** — same centres at 60/120/240 fps and same
`warm.zoom.count == 0`. Files were then restored from backup; `git diff --stat` returned to the
exact pre-experiment values (CropPlanner +56, TypingFocus +53).

## 3. Clean HEAD baseline (isolated detached worktree at ba23409)

- `caretSelectsTheSmallestContainingField`: **fails identically at HEAD** (`warm.zoom.count == 0`).
  Pre-existing at HEAD; not introduced by A1 or A4.
- `elementClicksArrivePixelExact`: **also fails at HEAD**, but with a different symptom —
  “control not framed” and centre (960.00,540.00) != (885.00,495.00) at all three frame rates,
  i.e. the camera never aims. The current tree aims at the control and is only ~3 px off, so the
  A1/Camera work improved this test rather than breaking it.

Worktree removed afterwards; no other agent's file was edited.

## 4. Likely owners / root-cause pointers

- `caretSelectsTheSmallestContainingField`: pre-existing at HEAD. Analysis of the fixture:
  outer AXFrame (100,400,1700,60) caret x=250 and inner (200,405,400,50) fail
  `TypingFocus.Field.matches` (centre delta 550 > max(8·b, 400·0.15)=60), so the run splits into
  a 0.2 s shot and a zero-length shot; `Planner.swift` has zero diff and forms no segment. This is a
  test-fixture/planner-contract mismatch, not a product regression from A4 or A1.
- `elementClicksArrivePixelExact`: residual is inside A1's `Director.swift` delta. That file adds
  `qhm(..., monotone: true)` for the log-zoom channel with the comment “at integer ticks this is a
  no-op”. The test evaluates at t=1.517/1.508/1.504 s — sub-tick on the 480 Hz grid
  (728.16 / 723.84 / 721.92) — where the clamp is NOT a no-op and can shift the evaluated centre
  by a few pixels. Hypothesis only: I did not edit `Director.swift` (A1's file) to test it.

## 5. A4 regression check after restore

`swift test --filter 'AutoCropFixtureTests|TypingZoomFixtureTests'`: **14/14 pass**, 0.23 s;
crop bake 5 × (30 s @ 480 Hz) = **79.4 ms**. No test file was edited or weakened.
