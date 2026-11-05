# Lumen Master Build Plan v2: Gap Audit and Execution Plan

**Audit date:** 2026-11-06  
**Repository:** https://github.com/duggal1/lumen  
**Immutable audit baseline:** `dde98a1f97fa7c2b242b57e9ca6625dacb009ec2` (main)  
**Reference:** User-provided *Lumen: Master Build Plan v2* (79-feature section 3.1; phases 0–15; section 23 Definition of Done), and both Screen Studio core/community feature lists.

## Verdict and rules of evidence

**NOT 100% aligned; do not advertise feature parity.** The latest main CI workflow passed (https://github.com/duggal1/lumen/actions/runs/42066271735), and PRs #9 and #10 were merged, but the README explicitly disclaims required hardware/performance/recovery acceptance checks. The existing code has real useful work. Do **not** rewrite working implementations merely to conform to class names.

Status means **S** = source-backed path visibly implemented (NOT hardware-certified); **P** = partial or only partly wired, user-facing acceptance not established; **M** = required implementation missing; **G** = explicitly gated T3 stretch/optional cloud, not delivered. This is a static-source audit, not a runtime certification. 34 S / 30 P / 12 M / 3 G. **These are NOT product-completion percentages.** On an untested device, an S feature may still fail.

### Blocking architectural and functional mismatches

1. **Persisted intent is not separate from derived timeline.** `Sources/LumenProject/Models.swift` persists `ProjectFile.timeline: Timeline`; `DerivedTracks` lives on that same type. `Commands.reduce(inout Timeline,...)` violates the requested `Project -> derived Timeline` split. `Docs/Decisions.md` expressly defers the split. UI often uses `EditorModel.edit { $0... }` directly instead of the single command bus. Fix via versioned migration and deterministic reducer, not a risky one-shot rewrite.
2. **A feature model is not a rendered feature.** `Director/Emphasis.swift` derives loupe/highlight/text state, and caption chunks exist, but `Render/Renderer.swift` `scene(...)` currently draws screen, privacy masks, clicks/cursor, and webcam, not captions, loupes, highlights, or manual text. 3D yaw/pitch are derived but not used in a perspective renderer. Draw them in the shared preview/export path before claiming parity.
3. **No multi-clip editing path.** `Project/Models.swift` has a single-source `TimeMap` instead of editable Clip/Asset lanes. There is no external video import, clip split/epochs or multi-clip composition. `cutAtPlayhead` currently cuts a span; it does not split media into two clips. Transcript word deletion currently affects caption state, not a full media edit.
4. **Recording resilience missing.** `RecordingSession` says pause/resume is intentionally unimplemented. `CaptureEngine` omits `movieFragmentInterval`, and audio writes CAF directly rather than crash-safe append-only raw PCM journals; recovery code is absent. A green synthetic test does not prove crash recovery.
5. **No independent control surface.** No `LumenControl`, `LumenMCP`, or `LumenShare` targets in `Package.swift`. CLI has analyze/render/frame/smoothness/sync-check/probe but lacks quality-check, privacy-scan, layered-export command and a comprehensive command/control bridge.
6. **Export gaps.** Current codecs are H.264, HEVC 8/10 bit and ProRes 422 HQ. No ProRes 4444, HEVC alpha, separate alpha cursor export, SSIM gate, 8K exposed through a passed probe, or share-safe bundles. High-fps settings and a single-frame VideoToolbox probe exist; validate full-duration exports on the requested Mac.
7. **Privacy remains un-certified.** OCR/pattern analysis, automatic mask tracks, the source-space Metal mask pass, and manual multiple-mask UI are real. But the specified 99% recall and OCR-negative **encoded** 6x zoom checks are not present. Blur/pixelate are not secure redaction. A false negative is a leaked secret, so export must fail closed when scanning is expected but unavailable.
8. **Audio is not RNNoise by default.** `LumenAudio/DSP.swift` activates RNNoise only with `canImport(CRNNoise)`; `Package.swift` has no RNNoise C target, so the compiled fallback is `SpectralGate`. WAV stems and multi-device paths exist but require hardware drift and NLE tests.
9. **Plan invariants are not enforced.** `Makefile` verify runs tests, packaging and launch, not golden/SSIM, recovery, perf, privacy, license or network guards. Several non-test files exceed 500 lines; `Renderer.swift` alone is 581. Dense 1440 Hz tracks use resident arrays, not specified mmap 60-second pages.
10. **Licensing conflict.** `App/public/assets/music/credits.csv` marks music as Creative Commons **Attribution**, whereas plan section 6 specifies **CC0 only**. Audit original licenses and attribution obligations, replace if strict CC0 is retained, and keep a machine-verified manifest. “No copyright” in a filename is not a license.

## Per-feature source-status matrix

`S` is implementation evidence, **not** feature-complete. A feature only becomes DONE after all plan §0.1 gates: model+migration, Command, Director/Analysis/Render path, tunables, synthetic tests, CLI/ControlAPI, per-frame budget, signpost, and documentation.

| # | Master v2 feature | Static status | Primary inspection path (under `Sources/Lumen`) | Required completion proof |
|---|---|---|---|---|
| 1 | Full-display/window/region recording | S | `Capture/Capture.swift` | 5-minute real capture |
| 2 | Screen, webcam, mic, system audio | S | `Capture/Session.swift` | A/V sync on hardware |
| 3 | Multiple simultaneous audio inputs | P | `Capture/ExtraMicrophoneRecorder.swift` | 2 devices 30-minute drift test |
| 4 | Fragmented MOV and crash recovery | M | `Capture/Capture.swift` | kill -9 loss <=2 seconds |
| 5 | Pause/resume same recording | M | `Capture/Session.swift` | PTS joins/no drift |
| 6 | Countdown and global shortcuts | S | `UI/AppModel.swift` | keyboard and permission tests |
| 7 | Native SCK/hardware capture performance | P | `Capture/Capture.swift` | 0 dropped frames under target load |
| 8 | iPhone/iPad USB capture and frames | M | `Capture/` | USB connect/disconnect tests |
| 9 | Import external video for editing | M | `Project/Models.swift` | full import/edit/export fixture |
| 10 | Add intro/outro video clips | M | `Project/Models.swift` | multi-clip export |
| 11 | Automatic zoom | S | `Director/Planner.swift` | reference-video review >=80% |
| 12 | Manual timeline zoom | S | `UI/TimelineStrip.swift` | move/resize/focus test |
| 13 | Zoom scale/duration/easing/focus | S | `Project/Commands.swift` | frame-level goldens |
| 14 | Auto-zoom min/max/follow/sensitivity/offset | S | `Project/Models.swift` | wiggle-vs-click cases |
| 15 | Toggle zoom background blur | S | `Render/BackdropBlur.swift` | pixel sharpness regression |
| 16 | Cinematic zoom preset | S | `Project/Models.swift` | 3 reference demos |
| 17 | 3D Lean/Float/Reveal camera moves | P | `Director/Camera.swift` | perspective in actual pixels; motion gate |
| 18 | Glass loupe | P | `Director/Emphasis.swift` | rendered loupe preview+export |
| 19 | AI/upscaler for deep zoom | G | `Render/` | spike 9; OCR/quality/perf superiority |
| 20 | Motion blur | S | `Render/Renderer.swift` | 60/120/240 fps quality test |
| 21 | Smooth cursor | S | `Director/Cursor.swift` | 0-lag/click pin tests |
| 22 | Click effects | S | `Render/Renderer.swift` | visible ripple golden |
| 23 | Cursor style/size/pack | P | `Render/CursorAtlas.swift` | custom pack import end-to-end |
| 24 | Hide idle cursor | S | `Director/Cursor.swift` | timeline fade tests |
| 25 | Loop cursor position | S | `Director/Cursor.swift` | seamlessly looping fixture |
| 26 | Constant cursor size across zoom | S | `Render/Renderer.swift` | size-vs-zoom frame tests |
| 27 | Custom/holiday cursor packs | M | `Render/CursorAtlas.swift` | signed local pack import |
| 28 | Manual tap indicators | P | `Project/Commands.swift` | editor placement + exported ring |
| 29 | Independent alpha cursor-layer export | M | `Export/Exporter.swift` | composite matches full master |
| 30 | Arbitrary aspect ratios including 5:4/custom | P | `Project/Models.swift` | custom UI + export fidelity |
| 31 | Auto re-aim zoom/layout/captions | P | `Director/Director.swift` | all 16:9/1:1/9:16 goldens |
| 32 | Backgrounds/image/padding/shadow | P | `Render/Renderer.swift` | image import and all backdrop options |
| 33 | Per-side padding and per-corner radii | P | `Project/Models.swift` | all four radii visible in render |
| 34 | Saved looks/presets | S | `UI/EditorModel.swift` | persist/reload/undo tests |
| 35 | Five camera layouts | S | `Director/Layout.swift` | all layouts on real webcam |
| 36 | Smooth layout transitions | S | `Director/Layout.swift` | continuity/overshoot goldens |
| 37 | Independent per-layout camera settings | S | `Project/Overlays.swift` | switching retains settings |
| 38 | Camera cutout/person segmentation | P | `Analysis/PersonMask.swift` | 5-minute jitter/quality test |
| 39 | Face tracking and framing | S | `Analysis/Face.swift` | moving-face fixture |
| 40 | Webcam cursor avoidance | S | `Director/Placement.swift` | no covered click in reference demos |
| 41 | Move/hide/fade camera behind cursor | S | `Director/Placement.swift` | hysteresis/opacity tests |
| 42 | Hide webcam on silence | S | `Director/Placement.swift` | VAD/return timing tests |
| 43 | Trim, split, delete, multi-clip | P | `Project/Commands.swift` | real split/multi-clip UI |
| 44 | Cut/split at playhead | P | `Project/Commands.swift` | dispatch-time playhead and split action |
| 45 | Manual/automatic speed ramps | P | `Director/Planner.swift` | UI and protected-speech checks |
| 46 | Transcript-based video editing | P | `Project/Commands.swift` | word deletion cuts video/audio |
| 47 | Filler and pause removal | P | `Director/TranscriptOps.swift` | user-applied suggestions with smooth joins |
| 48 | Manual subtitles/text blocks | P | `Project/Overlays.swift` | visible in Metal preview/export |
| 49 | RNNoise and keystroke declick | P | `Audio/DSP.swift` | vendored RNNoise + real keyboard A/B |
| 50 | Mic Standard/Loud/Podcast/Off | S | `Project/Models.swift` | LUFS and voice fixtures |
| 51 | Independent mic/system levels | S | `Audio/Mixer.swift` | mix/stem measurement |
| 52 | Audio stems/separate tracks | P | `Audio/Mixer.swift` | QuickTime track + individual WAV audit |
| 53 | Import external audio/voice-over/music | S | `UI/EditorModel.swift` | reopen and resync |
| 54 | Multilingual voice-over variants | P | `Project/Models.swift` | variant-specific batch export |
| 55 | Music library/import/autoduck | P | `Audio/BundledAudioAssets.swift` | CC0-only licensing proof + ducking |
| 56 | Click/whoosh/key SFX | S | `Audio/Mixer.swift` | SFX render fixtures |
| 57 | Loudness normalization | S | `Audio/DSP.swift` | target +/-0.5 LU and <=-1 dBTP |
| 58 | On-device transcription | S | `Analysis/Speech.swift` | real-device word-time/accuracy fixtures |
| 59 | Caption styles and animation | P | `Director/Captions.swift` | Metal text rendering goldens |
| 60 | Captions reposition by aspect | P | `Director/Captions.swift` | visible overlap-free renders |
| 61 | Toggle caption word highlighting | P | `Project/Overlays.swift` | rendered on/off fixture |
| 62 | SRT/VTT sidecars | M | `Export/` | timestamp round-trip |
| 63 | Multiple independent privacy masks | S | `Render/Renderer.swift` | multi-region/6x zoom golden |
| 64 | Auto-detect moving sensitive text | P | `Analysis/OCR.swift` | 99% recall; OCR-negative encoded frame |
| 65 | Highlight tool | P | `Director/Emphasis.swift` | Metal render + editor controls |
| 66 | MP4/MOV 4K60 H264/HEVC/ProRes | S | `Export/Exporter.swift` | playback+color audit |
| 67 | GIF export | S | `Export/Exporter.swift` | loop/frame count tests |
| 68 | 120/144/240fps; probe-gated 8K | P | `Export/Capability.swift` | each supported hardware encode |
| 69 | ProRes4444/HEVC alpha export | M | `Export/Exporter.swift` | NLE transparent alpha fixture |
| 70 | Versioned SSIM export quality gate | M | `CLI/LumenCLI.swift` | SSIM >=0.995 golden |
| 71 | Multi-aspect batch export | S | `UI/EditorModel.swift` | 16:9/1:1/9:16 fixtures |
| 72 | Clipboard export | S | `UI/EditorModel.swift` | pasteboard file validity |
| 73 | Share-safe editable project bundle | M | `Project/Models.swift` | redacted immutable bundle test |
| 74 | Shareable links/comments | G | `Share/` | optional T3: explicit opt-in provider |
| 75 | Email on share/view | G | `Share/` | optional T3: consent/provider tests |
| 76 | MCP/ControlAPI/App Intents | M | `Package.swift` | consented headless E2E |
| 77 | Headless CLI parity surface | P | `CLI/LumenCLI.swift` | all nine specified subcommands |
| 78 | Preview equals export | P | `Render/Renderer.swift` | pixel-identical same-timestamp goldens |
| 79 | Offline-first and network-import guard | P | `Package.swift` | CI rejects core network imports |

## Ordered implementation plan (preserve the master phase order)

### Gate A — Stabilize baseline before edits (phase 0)
- Keep `main` untouched until PR acceptance; branch from current main and rebase before merge. Keep PRs small, one feature group per PR.
- Create `Docs/Spikes.md`, `Docs/Benchmarks.md`, maintained 79-row traceability, and a test-fixture manifest with stable media hashes.
- Upgrade `make verify` to include `swift test` with warnings-as-errors, clean app packaging, Core/Director import dependency audit, source-file/function budgets, network-import guard, license manifest, frame goldens, QA harnesses and deterministic CLI checks. Add `make bench`, `make recover-test`, `make mcp-test`.
- Reject a PR if it adds UI settings without commands, fallback stubs, state-model drift, or untested exported pixels.
- **Gate:** clean CI executes real checks and fails on intentionally broken golden/mask/network fixtures.

### Gate B — Architecture and migrations (phase 0 prerequisite to further features)
- Introduce persisted versioned `Project` (`Asset`, `Clip`, overlays, source-time annotations, output-time soundtrack lanes), while keeping old `.lumen` files readable through an explicit `Timeline v2 -> Project v3` migration.
- Derive immutable `Timeline` snapshots with revision numbers. Enforce command-only model mutation from all views, hotkeys and CLI. Invalidate only relevant derived stages.
- Write migration/unknown-field preservation, `CommandBusTests`, `InvalidationTests`, and deterministic replay tests; protect manual zoom and mask timestamps.
- Replace fully resident dense track arrays with capped 60-second mmap-backed pages or prove an equivalent bounded-memory solution.
- **Gate:** old projects export pixel-identically; time-map cuts/ramps/clip epochs stay monotonic, source objects remain anchored.

### Gate C — Recording correctness and recovery (phase 1)
- Add fragmented MOV capture writers, append-only per-source PCM journals and event fsync; bundle state machine and startup recovery.
- Implement pause/resume with PTS rebase and epoch markers; isolate device dropouts, disk-full, sleep/wake, thermal, and screen disconnect.
- Calibrate SCK, CGEvent, webcam and every audio input against one host clock; use two-device recordings including BlackHole.
- **Gate:** 5/30-minute real-device records, loss <=2 seconds after kill -9, sync <1ms per spec, 0 dropped video frames at reference load; log measured hardware.

### Gate D — Render and Director parity (phases 2–4, 7–9, 10)
- Implement four distinct corner radii in Metal, custom aspect UI and imported image backdrop.
- Render caption text, word highlighting, manual text, highlights and a glass loupe in the *same* Metal scene used for preview/export; SRT/VTT sidecars.
- Apply perspective yaw/pitch homography + LOD for Lean/Float/Reveal; verify 3D does not expose off-source pixels. Add click/tap placement UI and custom cursor pack loader.
- Keep existing zoom, placement solver, cutout and multi-mask paths; add synthetic + real-capture golden tests at 16:9, 1:1, 9:16 and 6x zoom.
- **Gate:** preview/export identical for fixed input/time; all four overlays visible and masks still obscure protected text through every effect.

### Gate E — Editing, time map and transcription (phases 6 and 8)
- Add immutable external asset import, arbitrary clips, splits at the **dispatch-captured playhead**, transitions, source-time overlay partition on splits and per-clip epochs.
- Make transcript word deletion generate undoable cuts in both video/audio. Expose filler/pause suggestions and verify no mid-word cuts or audio clicks.
- Add manual subtitles and user-editable speed-ramp controls. Keep external voice-over/music in output-time lanes.
- **Gate:** imported intro + main capture + outro, transcript edits, 16:9 and 9:16 exports all stay synchronized after cuts and speed changes.

### Gate F — Audio and professional export (phases 5–6 and 10)
- Vendor reviewed BSD RNNoise as a real conditional build target, implement keystroke declick and calibrated mic modes, do voice A/B listening tests and validate stems/sync.
- Resolve audio-file licensing mismatch. Support separate video audio tracks where required, in addition to already present WAV stems.
- Add ProRes 4444/HEVC-alpha, cursor-only alpha layer and no-cursor master, output-layer composite regression, share-safe project packaging and privacy bake.
- Add full encoder throughput, color and quality probes; support only validated fps/resolution/codec/alpha combinations; T3 upscaler and 8K remain gated by measured spike results.
- **Gate:** Premiere/After Effects alpha and NLE round-trip, 4K60 and target 4K120, frame count/color, LUFS/true peak, SSIM >=0.995.

### Gate G — Automation, devices and optional sharing (phases 11, 12, optional 15)
- Add local JSON-RPC `LumenControl`, stdio `lumen-mcp`, consent policy, path allowlist, explicit audit log and App Intents wrappers over shared commands.
- Add CoreMediaIO iPhone/iPad capture, device framing, disconnect tests and activity-based zoom + manual taps.
- Only **after** offline full parity, optionally add isolated opt-in `LumenShare` providers, browser playback, comments and notifications. No networking in the core targets.
- **Gate:** agent records/edits/exports with explicit permission; device workflow works offline; sharing opt-in is revocable.

### Gate H — Release certification (phases 13–14; section 23)
- Build 3 realistic 60–120s demos and one 30–60 minute recording with distinct input rates, typing, webcam, secrets, speech, masks and subtitles.
- Run real kill -9 recovery, 60/120/240-fps smoothness, 4K export, GPU/CPU/memory plateau, P3 and alpha checks.
- Prove <=3 clicks from stop-to-publishable export, <=60s export of reference 2-minute demo on target M-series Pro **only if actually measured**.
- Do clean-machine install, permissions, accessibility, no-network and license checks. Record versions, hardware, command lines, logs and artifact hashes.
- **Gate:** all non-gated matrix rows DONE, every phase acceptance passing, plus independent watch-and-listen review. Never mark a feature DONE solely because a class exists or GitHub CI is green.

## PR order (independent, merge-safe)
1. `test/parity-oracles` — make verify, goldens, privacy/quality/perf guards, license check.
2. `fix/caption-overlay-metal` — captions/text/loupe/highlights/word highlight end-to-end.
3. `feat/project-clip-model` — persisted Project migration, command-only edits and source-time rules.
4. `feat/capture-resilience` — pause/resume, journals, fragment recovery, sync harness.
5. `feat/editor-multi-clip` — import/split/transcript/fillers.
6. `feat/pro-alpha-export` — layers, alpha and NLE interchange.
7. `feat/rnnoise-audio-cert` — C vendoring, voice and licensing proof.
8. `feat/control-mcp` — local consented automation.
9. `feat/ios-device-capture` — device capture and activity zoom.
10. `test/release-certification` — sustained hardware matrix; optional T3 only if spikes pass.

**Non-goal:** rewriting functional zoom/cursor/audio/code just to imitate master file names. **Definition of done:** no feature is “both added” until user-facing UI/CLI, actual rendered/exported pixels, tests, hardware evidence and the master §0.1 checklist are satisfied. This branch contains an audit/plan only, not implementation.
