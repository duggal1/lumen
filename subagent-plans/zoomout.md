# Plan: Auto zooms zoom back out

## Goal (2-3 lines)
Every auto-zoom segment must end when its action ends, and in the gaps between
zooms the camera returns to scale 1.0 — not pinned to the last subject. Today
the camera stays zoomed once a shot ends: the idle path of the camera solver
does not bring the plate back to full frame.

## Non-goals
- Zoom magnitudes, margins, speeds, easing of active shots: unchanged.
- Planner subject selection (clicks, typing, markers, visual shots): unchanged.
- Fixed-camera preset and manual zoom segments: unchanged.
- End-of-recording state: stays at full frame.
- UI, tests infra, audio, render: not touched.

## Where it changes (files)
- Sources/LumenDirector/Camera.swift — tickTargets/bake: the idle path returns the camera to scale 1 when nothing is active and no bridge is running.
- Sources/LumenDirector/Planner.swift — scene close timing: every auto shot ends on time (action end + hold, capped, never overlapping the next shot).

## How (approach)
- In Camera.swift, confirm with the baseline LUMEN_DIP run which branch fails to return to full frame when the last shot of a gap ends (idle activeAt, merged bridge, or slow decay), then make the idle branch drive lzTarget to 0 while the centre drifts toward the full-frame centre as the scale decays.
- In Planner.swift, if any auto shot does not end on time, move its close() to the action end + hold (or shot cap), keeping the no-overlap invariant the solver relies on.

## Verification (aggressive real checks)
- swift build
- swift test --filter BrutalZoomInvariantsTests (200 seeded scenarios: camera ends at 1x, no overlaps, no teleports)
- swift test --filter CameraMotionTests
- LUMEN_ZOOM_DEBUG=1 swift test --filter BrutalZoomInvariantsTests — LUMEN_DIP lines in the gaps between zooms dip to ~1.0 (scale 1) when nothing is active.
