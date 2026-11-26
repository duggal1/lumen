# Sub-agent 3 of 6 — Overzoom

## Goal (2–3 lines)

- A static page with no activity and no clicks must get **no auto zoom**: derive of an idle input
  yields no auto segments, and `LUMEN_ZOOM_DEBUG=1` on an idle page prints no `LUMEN_ZOOM` events.
- The trigger that let idle pages zoom is in `ActivityShotBuilder`: the non-loader gate
  `tr.samples >= s.onsetSamples, continuity >= 0.35 || span < 1.2` — the `span < 1.2` escape
  opened a shot for a couple of weak cells anywhere, so a page with nothing happening could still
  produce a zoom.

## Non-goals

- Manual zooms untouched (`origin == .manual` path, `ZoomPlanner` visual-intent open,
  `CameraSolver`). The `LUMEN_DIP` gap invariant untouched.
- No changes to `ActivityAnalyzer`/`lumen_activity_diff`, `VisualZoom` (legacy path, dead in the
  planner), `TypingFocus`, `dialogIntents`, or the `Planner` scene loop beyond what the builder
  now feeds it.
- No weakening/deleting existing tests.

## Where it changes (files)

- `Sources/LumenDirector/Activity/ActivityShotBuilder.swift` — `shots(from:)` non-loader gate.
- `Tests/LumenTests/VisualAutofocusTests.swift` — new regression test: a weak-activity blip
  (two cells 0.6 s apart, nothing between) must open no shot and no intent. (Fails today via the
  `span < 1.2` hatch.)
- `Tests/LumenTests/AutoZoomRegressionTests.swift` — new Director-level idle invariant: zero-energy
  grids + no events → `tl.zoom` empty.

## How (approach)

- Replace the non-loader gate with: `tr.samples >= s.onsetSamples && continuity >= 0.35` —
  activity must be sustained for at least 35% of the track's span to open a shot. Loaders
  (`maxCells < minCells`, `zoomOnLoaders`) keep their existing gate (`span >= 0.8`,
  `continuity >= 0.8`).
- Downstream (`VisualAutofocus.intents` → `ZoomPlanner.plan`) opens zooms only from shots; with no
  shots they produce no intents, and with real activity they behave exactly as before. No
  ActivityShotBuilder/VisualAutofocus/Planner signature changes; `VisualShot` semantics unchanged.

## Verification (aggressive real checks)

1. `swift build` — must pass.
2. `swift test --filter "AutoZoomRegressionTests"` — must pass, including the new idle test.
3. `swift test --filter "VisualAutofocusTests|VisualAutofocusCompositionTests"` — positives intact
   (stable regions still open shots; hover/scroll/flash still never do).
4. `swift test --filter "BrutalZoom"` — all BrutalZoom suites (Sweep, Invariants, Q1, Agent1,
   Degenerate, SingleTarget, Cost, TypingStillness) must pass.
5. Idle-page run: `LUMEN_ZOOM_DEBUG=1 swift test --filter "IdlePageWithZeroGridsAndNoEventsGetsNoAutoZoom"`
   — no `LUMEN_ZOOM` events in the output; the derive asserts `out.zoom.isEmpty`.
6. Report actual results honestly, including anything that fails.
