# Lumen Studio — DESIGN.md
## Precision Rail / Dieother instrument
Approved structure, rejected prototype styling. 2026-11-25. Native SwiftUI only. This is an implementation contract, not a screenshot or performance claim.

### 01. Scope
The recording is the primary surface. Rebuild the right-side Studio chrome, settings pages and export presentation; preserve actual project, capture, edit, renderer, audio, MCP and CLI contracts. Keep the existing five-lane pixel timeline, editing gestures and colors; remove detached particles and viewport-triggered thermal animation. Audio becomes a continuous, symmetric, multicolor dither waveform rather than a flat rectangle. Do not delete working controls simply to reduce line count. Do not import web UI, Electron, generic cards, blur or glass. Do not merge the existing backend compile failure into main.

### 02. Source audit
- Inspector.swift: nine categories behind a dropdown, nested card padding, mismatched row/control widths, eagerly enumerated wallpaper choices, full image loading in thumbnail tasks.
- EditorView.swift: central preview, 320pt inspector and full-width timeline. Keep this topology; rail is inside the right pane. Export request must open the pane even when hidden.
- TimelineDither.swift: viewport-relative cell ownership changes trigger random motes and heat. Remove the state, random simulation and time-dependent noise, not the timeline.
- TimelineDitherView.swift: main-thread display link kept alive by particles. Replace with coalesced invalidation, stable frame equality, no idle loop.
- Components.swift: global buttons, rows and sliders are used beyond Studio. Do not globally redesign unrelated screens. Create scoped components.
- ExportInspector.swift: nested groups, format controls exceed width, orange generic progress. Preserve settings and real exporter actions; use flat sections and a bright multicolor pixel progress instrument.
- CursorAtlas and project cursor model are the authority for actual skins and tint. Inspect before adding controls. Never advertise a color option which is not rendered.
- issue.md and Docs/Verification/design-audit.md are historical findings, not measurements of the current app.
- PR #31 run 464 failed compilation in ProjectSession (duplicate attribute, non-Sendable closure). Fix the specific compiler errors separately; backend behavior unchanged.

### 03. Color contract
Chrome base #090909, stage #0B0B0B, inspector #0C0C0C, rail #090909, wells #121212, hover #181818, selected #202020, pressed #262626. Primary ink #F5F5F5, secondary #A3A3A3, quiet #777777. No decorative borders, gradients, shadows, glass or outlines; keyboard focus is a visible accessibility exception. Color belongs to the instrument: canvas blue #599CFF, motion orange #FF8E3B, cursor violet #A373FF, voice cyan #55D3F1, music pink #F267B0, camera green #6FDB73, warning rose #F05448. Preserve existing timeline role colors and light appearance elsewhere. Bright dither accents in glyphs, sliders, selected indicators and real export progress; no colored full-pane backgrounds. Orange is the explicit export action, not a universal selected state.

### 04. Layout and typography
Native SF system 12–13pt labels, 15pt semibold section heading, 11–12pt monospaced numbers. Native SF Symbols 14–16pt, consistent optical alignment. Rail width 44pt, icon hit target 36×36, 4pt gap. Inspector total 344–360pt, internal padding 16, row minimum 32pt, control corner 6–8pt. Flexible content, no horizontal scrollbar, long labels wrap or move above controls. One independent vertical scroll; rail may scroll vertically at short window heights. No nested cards. Keep native accessible scroll behavior but hide generic always-visible bars; use native scrolling with keyboard and trackpad. Selected page heading stays fixed; export actions pinned below scroll when space permits. Never clip preview or change timeline geometry to make room for chrome.

### 05. Motion
Local hover 110ms, pressed 90ms, selected 170ms, curve (0.2,0.8,0.2,1); release 160ms, subtle 0.97 press scale. No bounce or overshoot, no animated full layout, no background blur. Values track drag directly; commit expensive edits at end of gesture; keyboard accessibility retains direct binding. No motion for Reduce Motion. No animation when idle. 60Hz target, not a guarantee. Actual native timing to be measured. Avoid re-decoding images on playhead changes.

### 06. Native shell
Precision Rail: Canvas, Motion, Cursor, Audio, Music, Camera, Captions, Privacy, Timeline, Export. Preserve existing Tab raw values for persistence and external routing; migrate labels only. Every rail button has tooltip, accessibility selection, keyboard focus, disabled state. Camera unavailable state when no recorded track. No fake Settings route: actual customization lives in each page. Optional search later, not a second navigation bar. A single active page; stable identity by route, per-page scroll restoration where feasible. Never reload assets on hover or playback. Use existing edit dispatch and binding, no parallel timeline model.

### 07. Pages
Canvas: aspect, video size, padding, radius, shadow, optional video frame, solid/gradient/dither/canvas/image/system wallpaper, real imported asset and presets. Video frame is content, not a chrome border. Asset grid lazy and downsampled off-main; no source-size image decode. Motion: import/title/highlight, auto zoom, preset/scale/approach/return, browser crop and reveal, optional 3D only where wired. Never show disabled legacy upscale knobs. Cursor: exactly three visible skin choices (system, pure pixel, distinct ring); selection previews use actual atlas. Expose real tint where supported, size, smoothing, click effect, actual loop/idle and motion options only where wired. Do not silently replace custom project assets. Audio: single Studio chain, denoise/voice level, real key/click controls, music on own route, no fictitious modes. Webcam: preserve layout, corner, size, shape, mirror, face/avoid-cursor/silence settings, backdrop and enhancement. Captions: retain font/size/enable/title and filler actions. Privacy: preserve detection/mask controls and honest status. Timeline: preserve split/duplicate/ripple/clipboard/snap. Export: real codec/container/resolution/fps/quality/audio settings, destination, alpha/stems/cursor sidecar/batch, cancellation and errors; show estimate and actual progress, not an animated fake percentage.

### 08. Timeline
Keep geometry, lanes, ruler, source/output mapping, playhead, selection, hit test, cuts, drag/trim/resize, scroll/pinch/zoom, snapping, click ticks, clip hues. Draw deterministic Bayer squares from current visible spans and actual audio peaks. No detached pixels on any change, no random spawning, heat history, drifting noise or glow pass. Voice waveform symmetric about its lane center; brightness follows amplitude, no unrelated animation. Keep empty grid quiet. Draw seams only when they express media boundaries, not chrome. Frame equality excludes wall-clock time. Coalesce actual snapshot updates to display refresh; no continuous raster while idle. No change to audio data or backend waveform semantics. Retain existing frame/output types if tests consume them.

### 09. Implementation order
1. Commit this specification before code.
2. Repair existing compiler diagnostics without changing backend policy.
3. Implement scoped instrument components: rail item, section, row, compact picker, neutral toggle, dither slider, progress.
4. Replace inspector composition and all page chrome; move music to its own route, preserve all existing bindings.
5. Rebuild cursor cards and bind only actual supported color/shape controls. Cache atlas/thumbnail work; no placeholder behavior.
6. Flatten export inspector, prevent format row overflow, wire multicolor dither progress to real fraction.
7. Remove timeline particle, heat, glow and drifting noise paths; make waveform bright and stable; keep geometry/gestures.
8. Fix hidden inspector export routing, verify native layout sizing.
9. Add regression coverage for deterministic timeline rendering, mapping and visual controls without deleting existing tests.
10. Audit diff, run macOS build/tests, package, check CI results. Review UI on physical Mac, record panning and slider motion; measure not assume 60fps.
11. Merge only if the exact revision is eligible and no known compile/test failure. If unavailable, report blocker and leave PR open. Never claim a merge based on a local commit.

### 10. Acceptance matrix
At 960×640, 1280×820, 1440×900 and Retina: no clipped control values, no horizontal overflow, no nested card stacks, no generic permanent scrollbar, all category routes accessible. Every control changes real state, undo/persistence intact. Pan/zoom/seek/delete: no particles or thermal afterglow. Repeated identical raster snapshot produces identical image. Audio waveform reflects actual peaks and remains aligned. Cursor skins/tint verified in preview and export; export progress reflects actual job. Reduce Motion and keyboard focus work. 60Hz target with no main-thread stalls >50ms, p95 interval ≤16.7ms under controlled workload; measure on M1 8GB. Native screen recording, Instruments trace and actual output inspection are required for performance and visual acceptance. No passing claim from HTML. Preserve source media and main until merge gate passes.

### 11. Evidence policy
Record exact commit and CI run. Distinguish implemented, compiled, tested, physically observed, and merged. Do not call UI pixel-perfect without native screenshots. No assertion that old backend reconstruction is complete. No fake assets or unsupported claims.

### 12. Implemented evidence and pending checks
- 9995b4d: deleted particle simulation and glow allocations, invalidation-based raster, fixed existing duplicate attribute and Sendable compiler diagnostics.
- e97ea24: scoped Precision Rail, flat native controls, static canvas thumbnails, lazy thumbnail cache, export progress.
- 9326203: persisted pointer ink with legacy default and shared atlas support; adapted old tests that explicitly required particles to assert deterministic cells instead.
- Follow-up: finer symmetric voice grid, migrated music page controls, routed cursor toolbar into the rail, live cheap visual slider bindings and updated display scheduling tests.
- Remaining: real macOS build, runtime inspection, frame timing, actual export, asset selection fidelity and full regression suite. Current CI must be read against exact HEAD. No claim of physical validation.

### 13. Cursor alignment correction (approved 2026-11-25)
Ring is rejected as a pointer skin. The three Studio options are Normal, Pixel, and Outline: a crisp hollow arrow with a precise tip, distinct from filled artwork. Preserve existing pixel artwork and color selection. Remove ring from the enum, visible menus, and artwork generation; decode old serialized "ring" as Outline (including MCP/preset Codable inputs). Click ripple effects are independent and stay. Keep legacy non-ring packs for existing projects, but the Studio picker has exactly three choices. Delete the obsolete alternate chooser if no callers remain.

Execution plan: (1) audit all skin declarations, pickers, atlas, renderer and tests; (2) centralize the three visible packs; (3) migrate old ring values without data loss and remove the circle raster; (4) give Outline a sharp, pointed silhouette and matching hotspot, and verify tint is applied in shared artwork; (5) test round-trip migration, distinct glyph bytes and hotspot, and source alignment; (6) inspect current Swift build diagnostics and fix proven blockers; (7) merge only through GitHub and read back main/PR state. Real-device timing, visual fidelity and export remain unverified until native evidence exists. Do not conflate merge with successful CI.

### 14. Blue pixel theme (user direction)
Keep the timeline geometry, colors, and interactions as they are. The rest of the interface uses bright blue and light blue accents on neutral surfaces. The logo uses a flat two-color pixel pattern; do not use a gradient or multicolor dither for the theme. Keep existing user-selectable canvas backgrounds available.
