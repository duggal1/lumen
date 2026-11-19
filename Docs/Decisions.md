# Decisions

- Timeline remains the persisted-intent and derived container; the Project split is deferred.
- ZoomSegment uses source time; the UI converts through TimeMap.
- Reveal tilt does not scale below 1×, avoiding outside-source pixels.
- The default minimum zoom scale is 1.5; 1.3 is barely visible.
- The default speed-ramp minimum idle is 4 seconds.
- Multi-clip, epochs, and pause markers are deferred to Part 6.
- SensitivePatterns, fnv1a64, and stableUUID live in LumenCore; LumenAnalysis does not import LumenDirector.
- FaceSample and ActivityPoint are shared plain values in LumenProject.
- Layout data is sampled at 120 Hz; webcam placement is sampled at 60 Hz and linearly interpolated.
- Reveal tilt never scales below 1×, avoiding pixels outside the source.
- OCR samples at 2 Hz with change detection and never stores raw recognized text. Mask tracks use 0.6 s lead/tail and bridge detections across 1.6 s.
- Automatically approved privacy categories are apiKey, jwt, privateKey, envSecret, card, email, and custom; phone and entropy detections remain proposed.
- Speech recognition is on-device only; SpeechAnalyzer and whisper are deferred.
- Transcription reads the raw microphone track; VAD remains in LumenAudio.
- Set LUMEN_NO_OCR=1 to disable sensitive-text OCR analysis.
- Person segmentation is cached as a compact grayscale .lmask sequence; renderer integration is deferred to Part 5.

- Transcription is Moonshine streaming through its C API behind `#if canImport(CMoonshine)`. Apple Speech is not used.
- LUFS v4 (schemaVersion 4): persisted `targetLUFS` becomes `targetLUFSOverride` (nil = mode table Standard −14 / Loud −12 / Podcast −16); v3 fixtures migrate pure/idempotent, unknown fields preserved.
- moveTap is the one authorized new command: moves a manual tap without changing its id, `moveZoom` parity.
- Captions need only the mic, so system audio is not transcribed.
- The model is imported from a folder. There is no in-app download, because plan rule 9 forbids networking in the core app.
- Word times come from the line span plus energy-dip snapping, because I couldn't confirm the runtime exposes per-word times.
- The live worker polls at an adaptive 0.12–0.5 s interval with a 20% duty target, and skips polls during silence.
- The stream restarts after 30 final lines plus 1 s of quiet, to bound per-poll cost and library memory.
- Live results are marked incomplete if the 8 s ring overflows. The editor then re-transcribes from the file.
- `transcript.json` stores mic-file time. `ProjectSession.micOffset` shifts it to source time.
- The editor caption monitor is preview-only until the Part 5 caption render pass lands.
- Preview plays the offline mixed buffer (`AudioMixer` → `PreviewAudioPlayer`), not a live graph, so preview equals export by construction (PLAN §13.6 amended: live-graph path is not used for program audio).
- Recording stop is split: `stopCapture()` (fast) then `finalize()` at `.utility`; HUD dismisses before finalize so Stop never spins.
- Declick applies to the primary mic only this pass (extra-mic key times need per-mic rebase; spectral path covers them).
- `MainThreadWatchdog` hashes stall stage names, not stack bytes, so `hangs.json` stays stable across builds.
- Activity uses absolute minute buckets (1 video light, 5+ brightest) and dot cells, not squares or quantiles.
- Activity dots use Ramp.heat mixed tokens with neutral controlPressed for zero.
- Studio Canvas keeps Gradii's 27 named palettes and seven families as fixed, deterministic Metal presets; its web editor's effect controls and loop animation are omitted so the picker stays click-first.
- Activity empty days are neutral dust dots, never white or BG.
- Auto zoom treats markers as explicit intent: a marker rect frames its control through `Focus.element`, a bare marker borrows the nearest click within 1.2 s, and a marker with no location creates no zoom.
- A click centred on its verified AX control frames the whole control; an off-centre click keeps the exact clicked pixel, because the click is the more precise evidence there.
- Recordful's GPL-3.0 source was studied for architecture only and then removed from the checkout; its auto-zoom engine is not in that repository. Its signal ideas (click plus clicked-control box, downsampled pointer path, labelled markers) were reimplemented clean-room in Swift — no source was copied.

## NEW_FEATURES_WITH_CODE.md — F2 (activity-driven auto-zoom)
- B2: reused the repo's `AnalysisCache`/`ReaderHandle` cancellation instead of a second `CVMetalTextureCache` cache scheme; the "LACT" binary cache was dropped.
- B2: `ActivityGrid` is named `ActivityGridPayload` in LumenAnalysis (one-way dependency); the Director-side `ActivityGrid` is mapped in `ProjectSession`.
- B2: `analyze` is `async` on a detached `.utility` task with `os_signpost("activity.analyze")` and a Logger category `activity`.
- B3: `ActivitySettings` lives in LumenProject because persisted settings must not be owned by LumenDirector; `ActivitySettingsPatch` routes edits through `Command.setActivitySettings`.
- B3: `build` was split into `mask`/`assign`/`shots`/`target`/`chain` to keep functions under 60 lines; thresholds are unchanged.
- B3: overlapping activity shots chain into one `VisualShot` with in-shot waypoints, so the camera pans inside a single segment instead of emitting overlapping segments.
- B4: `ZoomPlanner.plan` receives precomputed `VisualShot`s (one pure pass in `Director.deriveCancellable` feeds both zoom and speed ramps); click/typing intents keep priority via the existing `.visual` rank.
- F2: `busy` spans are added to the speed-ramp candidate boundaries and any ramp crossing them is skipped, so idle ramps never cross visibly changing content.
- F2: `DirectorInput.activityGrids` affects the derive cache digest by count and end times only, avoiding a ~1300-byte hash per grid on every interactive replan.
- F2: activity analysis runs for all desktop recordings; `includeActivity` is kept for API compatibility but no longer gates the analyzer stage.

## NEW_FEATURES_WITH_CODE.md — F1 (browser-content crop)
- A1/A4 types were renamed to ViewportCropTrack/ViewportCropPlan to avoid the existing keyframed LumenProject.CropTrack; a LumenProject-native DenseCropTrack carries the 480 Hz track in derived data.
- CropSettings was moved to LumenProject because LumenDirector depends on LumenProject, never the reverse.
- Viewport sampling is gated by a Sendable lock mirror of the recording pause state (actor state cannot be read from the recorder's @Sendable clock closure).
- SmartCropPlanner's browser-chrome detector was removed; WindowContent and FrameCropper were retained because they still serve window capture, not browser chrome.
- FrameState gained `crop: PxRect` alongside the legacy `cropRect`; the renderer prefers it and falls back to the legacy rect.
- The old offline ActivityPoint detector and the old browser-chrome crop planner were replaced by the supplied superior implementations as instructed.
