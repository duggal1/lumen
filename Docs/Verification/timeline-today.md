# Timeline today — code truth (Sources/LumenUI/TimelineStrip.swift, 183 lines)

Read line by line. No data model, command, or backend algorithm changes in the redesign. Only drawing + hit layout changes, edits still through `model.edit`/`model.dispatch`.

## Layout container (lines 6-22)

- One `GeometryReader` + one `Canvas { draw }` (size = strip size) + `.contentShape(Rectangle)` + `DragGesture(minimumDistance: 0)` on the whole strip. `change()`/`hit()` use `g.size.width` — fit-to-width, no scroll, no timeline zoom/pan.
- Frame height fixed `128`. Background `RoundedRectangle(12).fill(Tok.surface)`. Playhead is a separate overlay `PlayheadLine` (separate `TimelineView(.animation)` canvas, so the heavy strip doesn't redraw at display rate — heavy redraws only on `model` read at ~12 Hz via `tick` in EditorModel).
- Time mapping: `x(t) = CGFloat(t / dur) * w` where `dur = tm.outputDuration` (TimeMap output time). All drawing converts SOURCE → OUTPUT via `tm.output(atSource:)`, reading `model.playhead` in OUTPUT. Shared for every lane already, but lanes are not laid out — they are absolute `y` ranges inside one canvas.

## Lanes as drawn today (absolute y, not fixed lanes)

Single canvas, top→bottom by `y`:

| Band | y | What |
|---|---|---|
| Ruler | 8 label, 14 tick | ticks 1pt `Tok.text2` at `y:14 h:5`, label 10pt monospaced `Tok.text2` at `y:8`, last label trailing `tx-4`, others leading `tx+4` |
| Zoom | `zoomLane 26...58` (32 tall) | open space 19-25 (gap) |
| Ramps + cuts | `rampLane 62...80` (14 tall), cuts `y:62 h:18` | overlaps at 62 |
| Events (chips) | `y:82 h:18` | floats between ramp (ends 80) and waveform (~90-118) |
| Waveform | center `y:104`, rows ±`k*4-2`, `h:3` | vertical stack around 104 |

Nothing floats *by design* — chips at y82 are literally between the ramp band and the waveform stack, with no lane separators, no fixed lane container, no clip slot. "Nothing floats between lanes" requires real lanes.

## Zoom lane (lines 47-61 + hit 146-182)

- Source: `tl.zoom: [ZoomSegment]` (id, start/end SOURCE sec, scale, focus, origin auto/manual). Drawn OUTPUT via `tm.output`.
- Block: `CGRect(x: x(zs), y:26, w: max(x(ze)-x(zs),4), h:32)`. No min gap, no stroke, corners square (`Path(r)`).
- Fill: auto `Tok.zoomSoft` (violet 0.30 alpha), manual `Tok.accent` (full orange). Handles: 6pt opaque `Tok.zoom` / `Tok.accentPressed`. Selected: 3pt `Tok.text` bottom bar.
- Label: `%.1f×` 10pt medium monospaced at `r.minX+10, midY` leading. Always drawn, even when `w < ~30` — hence screenshot collisions `2.2 ×2.2 ×2.0×` when blocks are ~12px wide. No fit-check, no glyph, no fill depth by scale.
- Edits: `hit()` — `zoomLane.contains(p.y)` + 7pt edge tolerance → `.left`/`.right`, interior → `.move`, else `.seek`. `change()` — `.seek` calls `model.seek(t)`; move/edge call `model.edit(coalesce:true)` mutating `tl.zoom[i].start/end` directly (bypasses `reduce(.moveZoom)` — end semantics same: clamp `[0, dur]`, min 0.3s, `origin=.manual`). Selection set on `onChanged` from `drag?.id`. Delete via `model.deleteSelected()` dispatching `.deleteZoom`. Undo via model stack. No hover, no cursor, no

 snap, no focus-box drag on the timeline (focus box lives in `FocusOverlay` on the preview, not here).

## Ramps / cuts (lines 62-69)

- Ramps (`tm.ramps`, SOURCE): `y:62 h:14` `Tok.controlPressed` rect `w max(b-a,3)`, label `%.0f×` at `a+4`. Cuts (`tm.cuts`): 2pt `Tok.statusBad` ticks `y:62 h:18`. Share the ramp band; no lane of their own.

## Audio lane / waveform (lines 70-80)

- Source: `model.session.waveform` — `[Float]` 100 Hz SOURCE peaks 0...1 (one envelope/max per 10ms, from `ProjectSession.envelope`). Not a min/max pyramid, no VAD, no mute info.
- Draw: step `cx += 6` across `w`, one sample `wave[Int(src*100)]` per 6pt column, `rows = Int(sqrt(peak)*3.99)` (±3) mirrored around 104, cell `4x3` at `y:104+k*4-2`, played `Ramp.o[3]` (orange) else `Tok.controlPressed`. So: single-sample aliasing (reads as noise at 37 s, unreadable at 60 min), fixed 4pt cells with no backing-scale snap, played is orange (contradicts "played bright neutral, never orange"), no speech/silence/muted/ramps distinction, no per-column min/max window, no interpolation.

## Events lane (lines 81-125)

- Sources: `tl.derived?.clicks: [ClickFX]` (t OUTPUT, x/y) + `tl.overlays.taps: [TapIndicator]` (t SOURCE → OUTPUT). No keyDown/typing data drawn at all today, despite `session.input.events` holding it.
- `badge(center,label,soft,ink)`: rounded rect `40x18 r5` (44 if `×N`), label `Click`/`Tap`/`×N` 10pt semibold. Clicks orange `accentSoft/accentText`, taps fuchsia `tapSoft/tapText`. Tap-wins cluster colour.
- Dedupe: sort by t, 44pt min gap, `flushPending` merges if `center-lastBadgeX<44 && center-pendingCenter<44`, else drops if `<44`. Fixed 44pt chip width, not 6px density, no split on zoom-in (timeline has no zoom), no stem/head, no hollow head, no typing bars, no hover, no click-seek, no snap targets, no draggable taps (taps placed via preview `placeSelectedTool`, removed via inspector; timeline hit-test ignores taps entirely), no cause/effect thread, no dimmer for non-triggering clicks, no keyboard nav, no summary element. Accessibility is whole-strip `"Timeline"` + hint only.

## Hit / selection / snapping (lines 146-182)

- One `DragGesture` for the whole strip. `hit()` only distinguishes seek vs zoom edge/move. No marker hit-test, no tap drag, no snap (only 0.3s min-length clamp), no hover state, no cursor. Selection is zoom id only.

## What must be preserved verbatim in behaviour

zoom select/move/edge-drag/0.3s clamp/origin→manual, deleteSelected, seek via ruler/waveform/any non-zoom y, space/left/right in EditorView, undo/redo stacks, coalesced edits, `tm.output/source` conversion, playhead crossing. All edits through `model.edit` (current) — redesign routes through `model.dispatch(.moveZoom)` (same end state via `reduce`, adds Effects), taps deleted only via inspector `.deleteTap` (no new commands).
