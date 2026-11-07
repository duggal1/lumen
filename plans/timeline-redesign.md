# Plan: Timeline redesign (zoom / events / audio lanes)

## Goal
Replace the floating 128pt single-canvas strip with four fixed lanes (ruler, clip slot, zoom, events, audio) sharing one `tm.outputDuration` fit-to-width mapping. Clicks become hairline stems, typing becomes bars, taps become hollow heads, clusters merge <6 px, zoom labels never collide, waveform is a snapped min/max dot matrix with speech/silence/muted meaning. Data model, commands, and backend algorithms unchanged (visual + hit only).

## Non-goals
- No new commands (tap timeline-drag would need `moveTap`; deferred — taps stay seekable, hollow-headed, placed/deleted via existing preview/inspector paths).
- No timeline scroll/zoom/pan UI (fit-to-width kept).
- No full-app dark/inset/SF overhaul, recording flow, or crash-recovery in this pass (mapped in `ui-map.md`, sequenced next).
- No backend DSP/planner changes.

## Invariants (must always be true)
- Zoom select / edge-drag (7pt) / move / 0.3s min / clamp [0,dur] / origin→manual / delete / scrub / undo still work end-to-end (now via `dispatch(.moveZoom)`).
- One shared `x(t)=t/dur*w` from `tm.outputDuration` for every lane; playhead crosses every lane; clip slot stays empty above zoom.
- One Canvas per drawable lane (ruler, zoom, events, audio) + playhead overlay; visible range only; no per-marker SwiftUI views.
- Timeline contains no orange except manual zoom fill (accent violet for auto zoom; orange reserved for Export). Events/waveform are neutral.
- Reduced motion respected; hit targets ≥28pt at the strip level; events summary + next/prev keyboard nav exposed.

## Failure modes
- Empty zoom/clicks/taps/keys/waveform → empty states, no crash, ruler still drawn.
- Narrow blocks (<~34px) → label hidden, hover shows it; never overlaps/clips.
- Dense events (5000/hour) → 6px clustering collapses to counts; linear sweep, no O(n²).
- Hour-long project → per-column waveform window = dur/w; min/max over slice, no resampling blur.
- Seek/zoom drag during silent head / stale derive → same clamping as today.

## Approach
Split `TimelineStrip` into lane Canvases with fixed heights summing to 128 (ruler 20, clip 16 empty, zoom 28, events 32, audio 32). Shared `x(t)` helper. Zoom: inset 1px for 2px gap, 1px inner stroke, fill depth by scale, fit-checked labels, hover handles + cursor, snap zoom drags to marker x within 6px. Events: build marker list once per draw (clicks from `derived.clicks` OUTPUT, taps from `overlays.taps` SOURCE→OUTPUT, typing bursts grouped from `session.input.events` keyDown SOURCE→OUTPUT), cluster <6px with count, stem+head (hollow for taps), typing bars, trigger threads to owning zoom (click inside OUTPUT span) + dim non-triggers. Audio: per-column min/max over `session.waveform` window, device-grid snapped integer cells, mirrored stacks, speech/silence/ramp-muted colours, played bright neutral.

## Steps (each has a Verify command)
1. Oracle fixtures + screenshot harness: `Tests/LumenTests/TimelineFixtures.swift` (sparse 9, dense 200/60s, narrow zooms, hour-long) + before shots via `lumen-shot`. Verify: `swift test --filter Timeline` red on old geometry (label overlap count >0), `Tools/Verify/lumen-shot` before PNGs committed.
2. Tokens: rename roles per addendum (`action` orange only Record/Export, `accent` violet selection/zoom). Verify: `grep Color\( Sources/LumenUI` = Tok only.
3. Lanes: 4 Canvases, fixed heights, clip slot empty, playhead crosses. Verify: `swift build`.
4. Zoom lane + command-path drag + snap + hover handles + labels. Verify: `swift test --filter Timeline` green + manual drag through `dispatch(.moveZoom)`.
5. Events lane (stems/bars/clusters/threads/hover/seek/keyboard) + audio dot-matrix. Verify: after PNGs 1x/2x per fixture, density + waveform contrast checks.
6. Full suite + perf: 5000-event/hour scrub/drag timing log. Verify: `swift test` 148+ green, `Docs/Verification/timeline-after/` PNGs + `timeline-perf.log`.

## Files
- `Plans/timeline-redesign.md` (this file)
- `Sources/LumenUI/TimelineStrip.swift`
- `Sources/LumenUI/DesignSystem.swift` (role tokens only)
- `Tests/LumenTests/TimelineFixtures.swift`
- `Docs/Verification/timeline-today.md`, `ui-map.md`, `timeline-after/*`, `timeline-perf.log`
