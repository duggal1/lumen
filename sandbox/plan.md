# Intelligent crop for Area mode — plan

## Objective
Area capture today writes a dead `sc.sourceRect` into ScreenCaptureKit at
prepare time. Replace it with a time-varying crop: capture the full display,
keep the user's chosen rectangle as the default tight framing, smoothly widen
the crop when the user clicks or types outside that rectangle (browser chrome),
and smoothly return afterwards. The result must be deterministic and smooth at
60/120/240 fps.

## End state
- Selecting Area + Record produces a video framed on the chosen region.
- Typing in the address bar / clicking a tab widens the frame to include it;
  when the interaction ends the frame returns to the tight crop.
- **Studio replay and export are frame-identical.** The live floating preview is
  causal (no lead-in) and converges to the same crop after the reveal settles.
- The crop is derived from recorded signals, editable and headlessly testable.

## Non-goals
- Semantic/AI classification of page content.
- Changing `SCStream.sourceRect` mid-capture (no such API is used in this repo).
- Replacing auto-zoom for non-Area recordings.
- Reducing raw footage size: raw `screen.mov` becomes the full display. This is
  surfaced as a notice in the Area panel (T1.6) and documented (T7.3).

## Environment (ground truth)
Swift 6.4 / macOS 27.2 / Metal / SwiftPM. Modules: LumenCapture, LumenProject,
LumenCore, LumenDirector, LumenRender, LumenExport, LumenUI. `CameraTrack` bakes
at 480 Hz; `gridRate` is 1440 Hz. `DerivedTracks` and `Timeline.derived` are
in-memory only, rebuilt by `Director.derive`; only Timeline fields in
`CodingKeys` are serialized.

Reused machinery:
- `FrameCropper` (`Sources/LumenCapture/FrameCropper.swift`) proves capture-time
  GPU cropping with a parameterised rect; its caller varies `topFraction`.
- `contentFS` (`Shaders.metal:282-291`) and `Geometry.toCanvas` are the real
  render crop path, changing per shutter sub-frame. `ZoomTransform.viewport` is
  only consumed by the debug overlay and CLI verifier.
- `QuinticMove` and `CameraSolver` — motion primitive and 480 Hz bake.
- `CaptureMarker` → `Director.directorMarkers` → `DirectorInput.markers` — the
  host-clock-to-source-time replay pattern.
- `DeriveCache` needs a NEW `CropKey`; `PlanKey` is the zoom-planner cache and
  must not be repurposed.

## Architecture
1. **Capture**: Area with smart crop on uses `Source.display(displayID)`. The
   chosen rect is normalized like `Director.directorMarkers` and stored in
   `AppModel.smartCrop` and `Timeline.smartCrop.roi`.
2. **Signals**: AXFrame has rect/caret/`label` but no structured role, so chrome
   is defined geometrically: a resolved click or typing field rect that does not
   intersect the ROI is a reveal trigger. A nil/empty ROI disables smart crop.
3. **Crop director**: `SmartCropPlanner` builds a `CropTrack` of quintic
   keyframes in **output seconds**, converting source-time intents with
   `tm.output(atSource:)`. Lead-in 0.18 s and `returnSeconds` are output seconds.
   Baked in `DerivedTracks.crop`, never persisted. Cached by `DeriveCache.CropKey`.
4. **Render**: `FrameState.cropRect` (source px, `.zero` = no crop) is set at all
   four construction sites. The main path samples it in `contentFS`, `loupeFS`,
   `ringFS`, `Geometry.toCanvas` and the upscaler — NOT via `ZoomTransform.viewport`.
   Camera zoom stays layered on top. Export needs no change: it evaluates the
   timeline per frame.
5. **Live**: `LiveCamera` runs a causal crop controller on raw events + AXFrame
   only (`resolvedField`/`typingBursts` are offline-only), using one shared
   `revealRect(for:)` on the resolved field rect. It has no lead-in and settles
   to the offline rect; pre-settle frames may differ by design.

## Components
| id | name | role |
|---|---|---|
| capture | Full-display capture + persisted ROI | reads the display, stores the ROI |
| signals | Reveal intents | geometry-based outside-ROI triggers |
| crop-director | Deterministic crop planner | keyframes → CropTrack (output time) |
| render | Evaluation + Metal crop | FrameState → compositor |
| live | Causal preview crop | no future events |
| config-ui | Floating bar controls | toggle + two sliders |
| verification | Brutal headless tests | accuracy and cost |
| docs | Docs and feature matrix | remove stale static-crop claims |

## Tasks (execution order)
| id | title | serves | depends_on | est. LOC |
|---|---|---|---|---|
| T1 | Persist smart-crop config; capture full display for Area | capture, config-ui | — | 180 |
| T2 | Deterministic crop director + CropTrack + CropKey | signals, crop-director | T1 | 340 |
| T3 | Carry the crop through evaluation and the real Metal path | render | T2 | 380 |
| T4 | Causal live preview crop | live | T3 | 220 |
| T5 | Floating bar controls (config home: AppModel) | config-ui | T1 | 150 |
| T6 | Brutal headless crop verification | verification, crop-director, render | T2, T3 | 360 |
| T7 | Documentation and feature matrix | docs | T3, T4 | 120 |

Exact files, atomic subtasks, tests and acceptance criteria are in
`sandbox/tasks.json` — the source of truth for an executor.

## Risks and open questions
- **Privacy**: raw footage for smart-crop Area recordings is the full display.
  T1.6 surfaces this in the UI; T7.3 documents it.
- Area presets recorded on one display may need validation on another.
- Whether scrolling in the address bar should also trigger a reveal.
- AX cannot classify chrome; the geometric outside-ROI rule is deliberate.
- The stop-time seed `Director.planRecordingZoom` does not produce a crop: the
  live path covers recording and the editor re-derives from full evidence.

## How to execute
Work in `order` from `sandbox/tasks.json`. After each task run its named tests
headlessly (`swift test --filter ... > /tmp/x.log 2>&1`) before proceeding.
