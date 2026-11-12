# Plan: Camera motion and pointer accuracy

## Goal
Make camera motion arrive predictably at clicks, keep pan inside the visible crop without edge kinks, and preserve the real pointer path closely enough for hover timing. Fix typing fallback priority and launcher focus coverage.

## Non-goals
Do not change the existing display-clock preview loop or raise ScreenCaptureKit queue depth without evidence; the writer currently drops/replaces pending frames when it is not ready, and a deeper queue adds memory and latency. Do not run the test suite.

## Invariants
- Camera moves have a definite end and C2-continuous retargets; focus stays inside the feasible crop.
- Cursor glide stays within 50 ms of source-path time and never runs while dragging.
- AX caret data wins, tracer data precedes guessed field positions, and click fallback remains last.
- Window capture coordinates follow the current window origin; dimensions and scale are checked against the first real pixel buffer.

## Failure modes and expected behavior
- Clicks too close together to settle: retain continuous motion and report the miss rather than teleporting.
- Missing cursor samples: use a centered follow path without indexing empty arrays.
- Window unavailable: keep the last known origin until it is visible again.
- Nonuniform measured scale: report the mismatch and map X/Y independently.

## Approach
Add a reusable quintic move, schedule offline camera transitions against interaction time, constrain pan in normalized feasible-crop coordinates, and apply the same crop-aware state model to live camera motion. Bound cursor glide, reorder typing fallbacks, add the Tahoe launcher candidate, and expose settled-click counts. Confirm the preview is already display-clock driven; keep the capture queue depth at three because the one-slot writer path discards stale frames.

## Steps
1. Add quintic motion and replace camera spring-to-target with planned transitions. Verify with `swift build -c release`.
2. Bound cursor glide, lower click retarget thresholds, and prioritize tracing over field guesses. Verify with `swift build -c release`.
3. Add launcher coverage, dynamic window-origin mapping, first-frame scale measurement, and shadow exclusion. Verify with `swift build -c release`.
4. Align live camera pan/zoom constraints and report settled arrivals. Verify with `swift build -c release`.

## Files
- `Sources/LumenCore/Motion.swift`
- `Sources/LumenDirector/Camera.swift`
- `Sources/LumenDirector/Cursor.swift`
- `Sources/LumenDirector/Planner.swift`
- `Sources/LumenCapture/Input.swift`
- `Sources/LumenCapture/Capture.swift`
- `Sources/LumenCapture/Session.swift`
- `Sources/LumenDirector/LiveCamera.swift`
- `Sources/LumenDirector/Accuracy.swift`
- `Sources/LumenCLI/LumenCLI.swift`
