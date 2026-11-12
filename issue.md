# issue.md — Lumen: broken behavior and why fixes don’t stick (reconciled to current tree)

## Scope read
- Covered by this dump/context: LumenDirector, LumenCapture, LumenAnalysis, LumenProject, LumenRender, LumenAudio (+ partial Core/Export/UI/Speech/make-app.sh inspection).
- MUST READ BEFORE TOUCHING: `Sources/LumenCore/*` (`InputEvent`, `typingBursts()`, `SensitivePatterns`, `HostClock`, `EventCodec`, AX/types), `Sources/LumenUI/*` (lanes, privacy/zoom/caption/audio panels, export gate, editor/app flows), `App/`, `Sources/LumenExport/*`, `Sources/LumenSpeech/*`, `Package.swift`, `Tools/make-app.sh`. Trace every read/write/call site first.

## A. Why earlier “fixes” never showed up (still the root class)
- **A1. Saved projects override defaults.** `CameraParams`/`AudioPlan` decode persisted fields and migrate by model (`cameraModel < 4`, `typingModel < 2` in current code). Changing struct defaults or logic is ineffective for existing projects unless decode/migration/state-reset covers the affected fields. **Reconcile with current migrations in `Sources/LumenProject/Models.swift` (do not regress to `< 3`).**
- **A2. Analysis/processing is cache-keyed/versioned.** Current versions: `sensitive-text` v7, `typing` v5 (`Sources/LumenAnalysis/Service.swift`), voice cache revision `trained-voice-v8-wpe-residual-df-complete` (`Sources/LumenAudio/ProcessedVoice.swift`). Edits to OCR/typing/voice without bumping from these serve stale results.
- **A3. Auto zoom is persisted/planned at stop.** `Director.planRecordingZoom` runs in `Sources/LumenCapture/Session.swift` finalize (cheap). Editor must (re)derive with current planner/camera logic on open/after analysis so stored/stale segments don’t win. Verify `Director.derive`/replan call sites (`ProjectSession`, `EditorModel`, `App`/UI, export).
- **A4. Asset paths must not depend on cwd inside the app.** Current code uses bundle/checkout resolvers (`AppAssets`, `TypingPacks`) and `Tools/make-app.sh` copies typing/wallpapers/audio; verify no remaining cwd-based runtime asset resolution in shipped paths.

## B. Zoom (planner/camera/live) — verify current behavior vs intent
- **B1.** Scale must be context-sized (not “small element => huge zoom”), capped appropriately for clicks/typing, with hysteresis and no unnecessary zoom when target already fills view. Audit `Planner.chooseScale`/`focusCenter`/scene logic for hard caps, click rect sizing, fallback scale, and pumping.
- **B2.** Spring speed must come from camera/zoom params (not `leadIn`). `CameraSolver` currently uses `p.omegaZoom`/`p.omegaPan`; confirm no remaining leadIn-derived settle paths and that feel matches intent.
- **B3.** Scene linger/hold/tail must be bounded (hold/zoomOutGap/trace tail) and not over-persist via old projects; confirm effective values after migration and planner use.
- **B4.** Typing should produce stable scenes (not per-keystroke pumping). Planner currently aggregates typing bursts/intents in specific ways; verify one coherent scene per burst and stable scale/focus.
- **B5.** Typing focus should follow caret/text context (not field/page center) where available.
- **B6.** Retargeting should avoid lurches and keep caret/read position comfortably in view.

## C. Typing sync / Spotlight / Launchpad / AX — verify current behavior vs intent
- **C1.** Stop-time zoom planning is cheap; reliable typing zoom comes from analysis-derived traces/derive in editor. Verify AX/trace fallbacks and empty typing/activity cases.
- **C2.** Launcher focus (Spotlight/Dock Launchpad/Raycast/Alfred) must resolve focused text/search element; `Input` already tries launchers first — verify coverage/roles/window visibility.
- **C3.** Zero-length selection/caret bounds must be handled (insertion point). `Input.frame` probes glyph-before/edge; verify Chromium/Electron/custom views.
- **C4.** Chromium/Electron AX enablement must apply where needed (focus + secure-field sampling). `enableAccessibility` exists; verify all sampling paths.
- **C5.** Typing traces need good anchors and previous-frame diffing to avoid “whole panel changed”. `Service` computes anchors and `TypingTracer.changed(k)` diffs vs previous; verify request fields/callers and cache invalidation.
- **C6.** Typing analysis should publish early so derive/UX isn’t blocked by slow OCR; `Service.run`/`runTyping`+`runPrivacy` and callbacks exist — verify actual ordering/publish/derive integration in UI/editor flows.
- **C7.** AX timing is best-effort (minor).

## D. Typing sound — verify current behavior vs intent
- **D1.** Defaults/migrations should enable sensible typing sound for projects; current `typingModel` migration forces it — verify legacy edge cases.
- **D2.** Packs must resolve from bundled/known asset locations, never cwd. Assets exist at `App/public/assets/typing/mechvibes-default`; `make-app.sh` bundles them; loaders are bundle/checkout-aware — verify runtime in packaged app and fallback.
- **D3.** Key mapping must match the pack’s actual defines (`config.json` currently defines codes **14,15,28,30,36,42,57**). Full uiohook map is fine only if mapped to available samples with deterministic non-silent fallback.
- **D4.** Samples must be resampled/normalized/leveled correctly (48k timeline, no unintended gain stacking, no silence).

## E. Privacy (OCR/masks/gate) — verify current behavior vs intent
- **E1.** OCR must be fast enough and incremental (dirty/changed regions), respect cancellation/timeouts, and never discard found detections into “no sensitive text”. Current code has region/dirty logic and `PartialScan` handling — audit correctness/perf.
- **E2.** Privacy/export gate must always clear on terminal states (success, partial, error, timeout, cancel, disabled). `Service.ocr`/`run` defer progress; UI has scanning/error handling — audit all UI states/timeouts.
- **E3.** Mask boxes must tightly cover the secret (exact glyph/range bounds when available), not proportional guesses.
- **E4.** Masks must be conservative in motion (envelope/padding relative to text height) to avoid leaks.
- **E5.** Mask rendering must be clean/legible (rounded, no bleed, correct blur/pixelate/redact behavior) and match UI controls.
- **E6.** No quality pop/allocation issues (mips, upscaler interaction, no per-frame unnecessary buffers).
- **E7.** Layer A secure-field sampling must reach relevant fields (Chromium AX enabled, sufficient traversal/budget/strategy).
- **E8.** `SensitivePatterns` must cover required categories and not be gated by app/region. Current implementation appears comprehensive — confirm.

## F. Audio, captions, UI, misc — verify current behavior vs intent
- **F1.** Voice dereverb pipeline: `ProcessedVoice` already uses `WPE`/`ResidualSuppressor` (<600s) else `LateReverb`; confirm quality/path and bump revision on any change.
- **F2.** `DeepFilterNet` must not discard completed work after timeout logic; audit implementation (current path returns on success, throws on timeout/failure).
- **F3.** Mic/voice-processing comments and controls must reflect reality; surface isolation controls if supported.
- **F4.** Transcription must use cleaned voice URL and correct engine/wiring (Moonshine in `LumenSpeech`); remove unsupported pickers/engines per product intent. `EditorModel` transcribe path uses `cleanVoiceURL`; audit all call sites.
- **F5.** Captions must preserve proper nouns/casing as appropriate and not be force-enabled unexpectedly (trace all enable/normalize/migrate paths; default off where intended). `CaptionPlan.enabled` defaults false; `setTranscript` does not enable captions.
- **F6.** Wallpaper/background blur must be artifact-free, mip-correct, slider-bounded, and not double-applied.
- **F7.** Timeline lane must represent both `recordingSegments` and `clips`; empty only when both empty. Recovery/finalize must preserve valid duration/trim invariants.
- **F8.** Stop/finalize/open must not do heavy work on main thread; `Session` offloads parts — statically trace UI/App call sites (`session.stop()`, load, derive, analysis start, thumbnails/waveform) and move blocking work off `@MainActor`.

## Valid uncertainties
- OCR timing is unmeasured.
- Spotlight/Launchpad AX behavior is environment-dependent; verify on macOS with current implementation.
- Key mapping must be validated against the actual pack `config.json`/samples (pack currently defines only 7 codes).
- Stop-hang and “no clips” root causes may live in unseen `App`/`LumenUI`/recovery paths; trace statically.
