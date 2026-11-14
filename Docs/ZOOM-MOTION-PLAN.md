# Camera motion contract — model 5

The planner chooses source-time scenes and framing. The recorded camera turns
those scenes into step targets for log-scale and normalized centre x/y, then
applies the same forward/backward critically damped response to all channels.
There are no per-scene quintic moves, sparse follow waypoints or pan-space
conversion in the solver. `Motion.swift` stays: timeline sample interpolation
still uses its quintic position/velocity/acceleration primitive.

## Recorded camera

- Default `omegaZoom = 7.5`, `omegaPan = 4`, `leadIn = 0.30` seconds.
- Automatic entrance targets start leadIn before the interaction.
- Exit targets start 0.15 seconds after a scene ends.
- If the next entrance is less than 1.6 seconds after the exit target, retain
  the current scale and centre until the next entrance. Never start that exit.
- Targets are clamped to their intended scale before filtering. Centre and
  scale share a response; pan is never multiplied by a growing zoom margin.
- Typing passes the full 30 Hz caret path, rather than thresholded waypoints.
  Caret framing reserves reading room at 38% viewport x, with horizontal and
  vertical dead zones of ±10% and ±16% of the viewport, followed by the gentle
  omegaPan response. This reading composition is recorded-footage policy.
- Missing caret evidence frames the complete single-line field with 25%
  horizontal breathing room when possible; otherwise it creates no typing zoom.
- Saved easing values contribute a geometric-mean frequency multiplier to the
  whole camera. There is no per-segment transition-duration engine or UI control.
- Publish centre/log-scale, velocity and acceleration at 240 Hz. Evaluation,
  preview and export consume this same track. Tilt retains its existing policy.

## Live input

Live input cannot use future events or a zero-phase pass. One exact critically
damped three-channel spring integrates normalized centre x/y and log-scale at
240 Hz using the same spring primitive as the offline filter. Retargeting
preserves its velocity. Clicks always update the target. Typing uses resolved
caret evidence with no directional offset; absent caret evidence may frame a
complete single-line field. Bare keys sustain activity without aiming at the
pointer. Focus enrichment updates the target, without replaying a press or
resetting camera state. Older event times cannot replace newer focus.

The pointer uses one live spring. Offline cursor resampling retains its PCHIP,
one zero-lag Gaussian pass, saved glide setting and exact click pins; the extra
median filter is removed. Live and offline share camera coordinates and spring
math, while future-aware framing and causal input timing remain different.

## Saved projects and preview

Camera parameters migrate to model 5: maximum 2×, minimum 1.25×, hold 0.9 seconds,
scene gap 2.6 seconds, base scale 1.8×. Manual zoom segments remain intact.
Legacy minimum-hold metadata is ignored. Cinematic uses leadIn 0.45 seconds,
omegaZoom 5.5 and omegaPan 3.

Preview returns one sharp sample below a three-pixel shutter streak. Larger
streaks request approximately one sample per pixel within the measured GPU
budget and saved cap (default 12); export uses the same streak calculation.

## Verification for this change

Per the user's instruction, run `make build` only; no new tests, suite, render
matrix or benchmark. `LUMEN_ZOOM_DEBUG=1` exposes `LUMEN_TYPING` and `LUMEN_DIP`
for reviewing a real recording. Do not claim measured caret accuracy, dip
thresholds, minimum full-scale hold duration or visual smoothness from a build.
AXObserver capture changes are deferred until those recording diagnostics have
been reviewed. Existing immediate key delivery and asynchronous enrichment stay.
