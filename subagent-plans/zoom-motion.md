# Plan: Remove camera floating, add zoom in/out

## Goal (2-3 lines)

1. Remove floating: when no zoom is active, the camera track from CameraSolver
   (Sources/LumenDirector/Camera.swift) is dead still — pinned to a fixed idle
   center (lz = 0, pan = (0.5, 0.5), zero velocities and accelerations) so the
   viewport cannot drift when idle.
2. Add zoom in/out: zoom segments drive the existing critically damped zoom
   springs — smooth rise to each segment's scale (zoom in) and decay back to
   1x (zoom out).

## Non-goals

- LiveCamera (real-time capture preview) — out of scope; the task names CameraSolver.
- ZoomPlanner, ZoomTransform, renderer changes.
- New tests in the permanent suite beyond the requested targeted runs.

## Where it changes

- Sources/LumenDirector/Camera.swift (tickTargets, bake) — only file.

## How

1. In `tickTargets`, the final "drift home and rest" branch becomes the idle
   branch: target (0, 0.5, 0.5), panOmega 0, `idle: true`.
2. In `bake`, when the selection is idle (`activeAt[k] < 0 && scaleSpring <= 1e-6`
   via the returned flag), after the spring steps pin the state exactly:
   `scaleSpring = 0; scaleVel = 0; panX = panY = 0.5; velX = velY = 0`, applied
   after the quiescence snap and clamp so the springs sit on the idle state
   with zero velocity. Rise/settle during segments already use the existing
   critically damped springs (holdTarget rise, release decay).

## Verification (aggressive real checks)

1. `swift build` — compiles.
2. `swift test --filter CameraMotionTests` — targeted.
3. `swift test --filter BrutalZoomInvariantsTests` — targeted (fuzz invariants).
4. `LUMEN_ZOOM_DEBUG=1` trace on a derived manual-zoom timeline:
   - camera float-exact when idle: lz == 0, nx == ny == 0.5, vz/vx/vy == 0 at ticks with no active zoom;
   - zoom arrival: first track tick with lz >= targetLz - 0.01 occurs within ~0.6 s of the click;
   - zoom-out: after the segment ends, lz returns to 0 and scale returns to 1 within ~0.6 s; then temp test deleted.
