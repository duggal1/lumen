# Plan: Accurate, click-timed camera motion
## Goal
Remove premature and unrelated automatic zooms; keep transitions smooth and click locations exact.
## Non-goals
UI, capture, new dependencies, and changes to manual shots.
## Invariants
Manual shots survive. Cursor remains pinned at clicks. Camera stays within source bounds. No zoom from unanchored scrolling or typing. Auto shots begin at the triggering click.
## Failure modes
Nearby but distinct targets must not average into empty space. Large AX containers must not distort focus. Source edges must not create camera jumps.
## Approach
Test public Director behavior first. Anchor automatic shots to valid clicks, limit spatial clustering, and use continuous third-derivative transition envelopes. Widen click correction to avoid short acceleration spikes.
## Steps
1. Add regression tests and confirm failures with swift test.
2. Adjust Planner.swift; rerun motion tests.
3. Adjust Camera.swift and Cursor.swift; run complete swift test and release build.
4. Review diff, commit/push each file change, package signed application when possible.
## Files
Tests/LumenTests/MotionAccuracyTests.swift, Sources/LumenDirector/Planner.swift, Sources/LumenDirector/Camera.swift, Sources/LumenDirector/Cursor.swift.
