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

## Prompt 3 — camera/crop contract + render-path repair
- The 480 Hz camera channels are now crop-normalised (u,v in the crop, logZ relative to `CropSpace.baseView` with the frame aspect). Empty crop tracks fall back to source-normalised space, so existing solver callers/tests are unchanged.
- The feasible-centre clamp is evaluated per dense tick against `crop(t)` at that tick's OWN output time, mirroring `CropSpace.visible`; `CropSpace.baseView` supplies the aspect-trimmed viewport so zoom stays correct for non-16:9 exports.
- Every target is normalised with `CropSpace.normalise` at its own time: click/typing/element intents at the segment's event time, follow waypoints at their sample time, the global caret at each tick, and the mandatory tail returns to crop-centre (u,v)=(0.5,0.5).
- `FrameState.evaluate` reconstructs the visible rect with `CropSpace.visible`; `cameraScale` stays relative to the crop base view and the renderer derives the view as `baseView / scale` so width and height agree.
- The renderer no longer applies the derived-frame camera clamp (the solver owns feasibility). A single clamp remains ONLY for Studio-supplied `live` states, which may carry arbitrary focus.
- Crossfade: `Timeline.effectiveCrossfade` is consumed in `Renderer.encode` by blending the held outgoing scene with the incoming scene (premultiplied, via `pAccum`) before the backdrop resolve. A join is an output-adjacent clip pair; the cache is sequential-frame validated so scrubbing/seeks cannot dissolve against a stale frame. Transparent/cursor-only deliveries skip it.
- Smoothness: `contentFS` maps `view = cropSize / scale`; passing `cropSize = crop * scale` made the visible region independent of zoom and produced the 22.15M ghost step when the synthetic live crop moved. `cropSize` is now the crop base view, so the visible region tracks `CropSpace.visible` and camera steps are bounded.

## Build environment
- After a server restart the macOS Metal toolchain cryptex mount changed (…2C1QSU → …XMpyMH); SwiftPM cached the old path and metal compilation failed with "unable to spawn process …/ metal". Fix: `swift package clean` then rebuild. No source change required.

## Deleted legacy tests (F1/F2 port)
// Deleted animationLoopIsRejectedEvenWhenEachPulseLooksStable: F2 has no animation-loop classifier; repeated pulses now chain into one shot with in-shot waypoints.
// Deleted heldTimeIsShortAndScalesWithSubjectSize: hold duration is now a fixed `minHold`; subject-size-scaled reading time was removed with the old Beat detector.
// Deleted trimAndCutsSuppressBeats: the F2 adapter only clamps to trim bounds; cut-aware beat rejection was removed from `VisualAutofocus.intents`.
// Deleted BrutalSmartCropTests.livePreviewConvergesToThePlannedCrop: compared LiveCamera against SmartCropPlanner.plan/SmartCropIntent, the keyframed Area-crop offline planner intentionally replaced by the 480 Hz ViewportCrop track (F1); live crop convergence is now covered by TypingFocusBrowserCropTests.
// Deleted CoreZoomValidationSmartCropTests.mergedRevealsKeepSourceAspect: asserted the removed offline keyframed Area-crop track's merged keyframes; aspect is now enforced by CropSpace.fit/baseView in the 480 Hz viewport crop.
// Deleted CoreZoomValidationSmartCropTests.everyKeyframeCarriesSourceAspect: keyframed SmartCropTrack was intentionally replaced by DenseCropTrack; no keyframe array remains to assert on.
// Deleted CoreZoomValidationSmartCropTests.outputTimeConversionSurvivesTrimAndRamp: offline SmartCropPlanner.plan/SmartCropIntent removed; viewport crop is derived at source time and mapped by the existing TimeMap, covered by TypingFocusBrowserCropTests.
// Deleted BrutalSmartCropTests.defaultIsTheContentCropAndEndsThere: asserted the removed offline keyframed Area-crop track's default content ROI; default browser crop is now produced from ViewportSamples by CropPlanner and covered in TypingFocusBrowserCropTests.
// Deleted BrutalSmartCropTests.contentClickDoesNotReveal: keyframed SmartCropTrack reveal behaviour intentionally removed with the offline planner.
// Deleted BrutalSmartCropTests.trimAndRampKeepTheRevealOnItsFrame: offline SmartCropPlanner.plan/SmartCropIntent removed; viewport crop is source-time anchored and TimeMap-mapped.
// Deleted BrutalSmartCropTests.overlappingRevealsMergeIntoOneWindow: offline keyframe merge removed; CropPlanner merges uncrop spans in CropSettings.
// Deleted BrutalSmartCropTests.cacheNeverServesAStaleCrop: cached legacy CropTrack no longer exists; the derive cache now keys viewportCrop by CropSettings + viewport digest.
// Deleted BrutalZoomQ1Tests.changingOnlyAXLabelOrAppNameInvalidatesCachedCrop: cached keyframed Area-crop track removed; the derive cache now keys viewportCrop by CropSettings + viewport-sample digest, not AX labels.
// Deleted RenderVisualAccuracy.dialogCropContainsSubjectAndNeverSamplesOutside: asserted offline SmartCropPlanner keyframes; dialog framing is now covered by the planner's dialog-priority intents.
// Deleted AutoZoomRegressionTests.autonomousVisualZoomWorksWithMouseEventsButNoClick: fed the removed ActivityPoint detector directly; equivalent no-click visual-shot coverage is in the ported VisualAutofocusTests (resultAppearingCreatesOneHeldBeat, hoverOnlyHighlightNeverTriggers).
// Deleted BrutalSmartCropTests.chromeClickRevealsThenRecrops: asserted offline SmartCropPlanner.revealRect keyframes for the old Area-crop planner; browser chrome reveal/recrop is now covered by the ported TypingFocusBrowserCropTests viewport-sample suites.
