# Camera motion contract — model 5

The planner chooses shots in source time. The recorded camera turns those shots
into a single baked track of centre x/y and log-scale, and `Timeline.evaluate`
reads that track with quintic Hermite interpolation. There is no live filter to
retarget, no caret follow path and no second animation system. Preview and export
consume the same track.

## Recorded camera

- The track is baked at **480 Hz**, an exact multiple of 24 / 30 / 60 / 120 /
  240 fps. Every export frame lands on a sample. Velocity and acceleration are
  published alongside position, computed by numerical differentiation, and the
  evaluator uses all three for its quintic interpolation.
- A shot is a rest-to-rest quintic: 1.0× → target over the lead-in, landing
  **exactly** on the target at the settle time; the hold is then written per grid
  tick. Entrance velocities are matched to the hold's own velocity so the camera
  does not stop dead on arrival.
- `leadIn = 0.30` is a floor, not a fixed duration: the runway grows with
  magnification and saved easing. `tail = 0.70` seconds; `hold = 0.9` seconds;
  `zoomOutGap = 2.6` seconds.
- Shots are ordered by **settle time** and written in one forward pass. One camera
  has one target, so the planner never emits two overlapping segments. A subject
  that arrives before the open shot can close is reached by panning inside that
  shot, not by opening a second one.
- When shots do not bridge, the outgoing shot returns fully to 1.0× before the
  next lead-in begins. The recording always ends on the full frame, centred —
  the final tail is mandatory and anchored to whichever shot holds furthest
  forward, so a click near the trim end cannot leave the export zoomed in.
- Every sample is clamped into the feasible centre box for its own scale; the
  frame never shows canvas outside the source.
- `maxScale` is a hard cap at every stage, including `minScale` clamping. The
  Inspector exposes it down to 1.2×.
- Clicks retain exact pixel targets. A resolved accessibility frame makes the
  control itself the subject and the shot centres on its rect. Typing frames the
  whole resolved field **once** — there is no caret follow path, so the camera
  cannot drift while the caret moves, selects or wraps. Hover only steers a shot
  that hover itself opened.
- Saved easing values contribute a geometric-mean frequency multiplier to the
  whole camera. There is no per-segment transition-duration engine or UI control.
  Tilt retains its existing policy.

## Live input

Live input cannot use future events. `LiveCamera` keeps its own causal response
on centre x/y and log-scale so the recording monitor reacts immediately;
retargeting preserves velocity. It is deliberately a different path from the
future-aware recorded framing. Focus enrichment updates the live target without
replaying a press or resetting camera state; older event times cannot replace
newer focus. The two paths share coordinates, not timing.

## Saved projects and preview

Camera parameters migrate to model 5: maximum 2×, minimum 1.25×, hold 0.9 seconds,
scene gap 2.6 seconds, base scale 1.8×. Manual zoom segments remain intact.
Legacy minimum-hold metadata is ignored. Cinematic uses a longer lead-in and a
slower response multiplier.

Preview returns one sharp sample below a three-pixel shutter streak. Larger
streaks request approximately one sample per pixel within the measured GPU
budget and saved cap (default 12); export uses the same streak calculation.

## Autonomous product shots

Visual activity is analyzed for ordinary desktop recordings as well as imported
and device footage. Analysis version 2 records changed-region bounds and coverage
at 10 Hz. A newly static result is checked against its pre-change frame for 0.4
seconds, so a single persistent result can trigger a shot while a one-frame flash
cannot.

The planner groups nearby changes (gap up to 0.6 seconds, spatial drift up to
16% of the source diagonal) into a stable region. At least three observations
spanning 0.3 seconds are required. Tiny regions below 0.8% of frame area, changes
across more than 55% of the frame and heavy full-screen change are ignored. These
are visual heuristics, not semantic recognition of AI tasks.

Clicks/typing within a second and scrolling/dragging near the change take
priority. Eligible regions use at most 1.6× magnification with 35% framing room
and hold through the change plus reading time. Manual shots, the fixed preset,
auto-zoom off and suppressed automatic shots retain their behavior. Visual
activity also interrupts idle speed-ramp planning so generated results are not
skipped as if nothing happened. Activity publishes as soon as its background
analyzer completes; Studio replans without waiting for the other scans.

## Verification

Accuracy is verified headlessly, without a window or a render. The brutal suites
in `Tests/LumenTests` seed a scenario generator and check every camera invariant
across 200 sessions, replay derivation for determinism, mutate every input the
digest is supposed to cover, sweep click times and export frame rates for
pixel-exact arrival, hold the frame still through typing bursts, feed degenerate
inputs, and bound derive/evaluate cost. No visual smoothness or caret accuracy
claim is made from a build alone.
