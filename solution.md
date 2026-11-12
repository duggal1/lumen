# solution.md — reconciled fix plan for issue.md (execute against current tree)

## Non-negotiable rules
1. **READ FIRST, WRITE SECOND.** Read and trace every file named in issue.md/solution.md, especially unseen modules: `Sources/LumenCore/*` (`InputEvent`, `typingBursts()`, `SensitivePatterns`, `HostClock`, `EventCodec`, AX/types), `Sources/LumenUI/*` (lanes, privacy/zoom/caption/audio panels, export gate, editor/app state, progress), `App/`, `Sources/LumenExport/*`, `Sources/LumenSpeech/*`, `Package.swift`, `Tools/make-app.sh`. Map actual read/write/call sites before editing.
2. **NO TESTING / NO NEW TEST FILES.** Do not run tests/harnesses/benchmarks/captures. Do not create test files. Run **`make build` only** to prove it compiles.
3. **Delete replaced code outright** (no flags/shims/legacy branches), except required Codable migrations/compat needed to load existing projects safely.
4. **Persistence/cache correctness is mandatory:** changing saved fields requires migration/reset logic for old projects (A1). Changing OCR/typing/voice behavior requires bumping cache/version keys from **current** values (A2). Skip either and fixes won’t appear.
5. **Reconcile, don’t paste.** Adapt to current types/APIs/signatures and existing fixes. End with a checklist: done / not done / n/a (with reason) and files changed.

## Current baseline to preserve/reconcile
- `CameraParams.cameraModel == 4`, `AudioPlan.typingModel == 2` migrations already exist in `Sources/LumenProject/Models.swift`.
- Cache versions currently: `sensitive-text` v7, `typing` v5 (`Sources/LumenAnalysis/Service.swift`); voice revision `trained-voice-v8-wpe-residual-df-complete` (`Sources/LumenAudio/ProcessedVoice.swift`).
- `CameraSolver` already uses `p.omegaZoom`/`p.omegaPan` (not leadIn-derived). `ProcessedVoice` already prefers WPE+residual for short clips.
- Typing assets exist in `App/public/assets/typing/mechvibes-default` (config defines codes 14,15,28,30,36,42,57) and `Tools/make-app.sh` copies them to `Contents/Resources/Audio/typing`; loaders/mixer are bundle/checkout-aware.
- `Input` already includes launcher-focus and improved caret/AX sampling logic; `Service`/`TypingTracer` already include anchors and previous-frame diffing in current form. Verify completeness rather than reintroducing old behavior.

## A. Make fixes actually land

### A1. Models/migrations/state reset (reconcile, don’t blindly replace)
- **CameraParams (`Sources/LumenProject/Models.swift`):** ensure decoded legacy projects land on the intended behavior (scale bounds, leadIn/tail/hold/zoomOutGap/minHold/mergeGap/panThroughGap, omegaPan/omegaZoom, lookahead/deadZone/followDelay/safeZone/baseScale, `cameraModel` bumped as needed). Keep/add migration so existing saved values cannot pin old “whip/linger/huge zoom” behavior.
- **ZoomPreset/apply:** reconcile preset max scales and `apply(preset:)` parameters to the intended feel (smooth, bounded). Do not leave conflicting defaults vs presets.
- **AudioPlan:** keep `typingModel` migration effective for old projects (`keySounds`, `typingLevelDb`, default pack id as appropriate) and ensure defaults are sane for new projects.
- **PrivacyPlan/captions-related persisted fields:** if behavior/defaults change (e.g. padding/pixelSize/mode semantics, captions default-off), add decode migrations/default normalization so old projects don’t get stuck/broken.
- **Auto-zoom rederive on open:** trace project open/load paths (`LumenExport.ProjectSession.open`, `LumenUI` editor/app load, CLI/MCP as relevant). If zoom is `.auto`/derived-from-events and stored segments may be stale, re-run `Director.derive` (or equivalent) with current planner/camera logic on open so A1/B fixes apply. (`EditorModel.open` already triggers replan/derive; verify initial state/UX.)

### A2. Cache/output invalidation (bump from current)
- Bump `sensitive-text` version in `Service` from **v7** only if OCR/scan output/semantics change in this work (otherwise leave). Bump `typing` from **v5** if typing trace/analysis behavior changes further. Bump `ProcessedVoiceCache.revision` from current **v8** if processed-voice output changes.
- Rule: any edit affecting OCR/typing/voice results must bump the corresponding cache key/revision in the same change.

### A3. Stop-time vs editor-time zoom
- Keep stop-time `planRecordingZoom` cheap/safe (no heavy analysis). Ensure editor derives/refines zoom when typing/activity analysis becomes available. Do not regress startup/stop responsiveness.

### A4. No cwd asset paths in runtime
- Verify all runtime asset resolution (typing packs, wallpapers/backgrounds, audio/SFX, models) uses bundle/app resources or explicit known roots (never `currentDirectoryPath` inside shipped behavior). Reconcile `TypingPacks`, `AppAssets`, render/UI loaders, and bundling.

## B. Zoom: dynamic, small, short, smooth (reconcile current Planner/Camera/LiveCamera)

### B1/B4/B5 Planner (`Sources/LumenDirector/Planner.swift`)
- Audit and implement intent/rules (adapt names/structures to current code):
  - **Scale:** context-sized, bounded (no hard 3.2). Clicks: scale to comfortable context (not element-fit explosion), cap ~1.7 and return 1 when target already fills view. Typing: frame active line/field context, bounded ~1.6–2.0. Unknown/no-rect click: modest default within bounds. Apply hysteresis to avoid jitter.
  - **Typing bursts:** one stable scene/intent per burst (no per-keystroke pumping). Preserve/use caret samples/path for follow within the scene; do not let growing field text thrash scale.
  - **Focus:** clicks anchor to exact target pixel/context; typing focuses on caret biased to leave room for rightward text growth (not field/page midpoint).
  - **Hold/tail/continuation:** scene continues only within intended gap, ends shortly after last activity; cap trace-tail extension so zoom doesn’t linger excessively.
  - **Close/filter:** drop degenerate/near-1x/too-short shots; keep stable IDs where required.
- Remove/replace any logic that makes small UI elements produce maximal zoom or creates mid-sentence zoom splits.

### B2 Camera (`Sources/LumenDirector/Camera.swift`)
- Keep springs parameter-driven (`omegaZoom`/`omegaPan`), smooth arrival/exit (no leadIn-derived whip). Tune in/out response to match “arrives by event, not after it” within current timing model.

### B3 Live camera (`Sources/LumenDirector/LiveCamera.swift`)
- Reconcile constants/behavior (max scale, hold, omegas, keyDown/typing scaling/focus) with planner intent and bounded, smooth feel.

## C. Typing sync / AX / analysis ordering

### C1-C4 Input/AX (`Sources/LumenCapture/Input.swift`, related Core types)
- **Launchers:** ensure Spotlight/Launchpad(Dock)/Raycast/Alfred focused text/search elements are detected reliably (refresh PIDs, correct roles/attributes, ignore hidden/minimized/offscreen windows as appropriate). Keep checked before generic focus fallback.
- **Caret:** handle zero-length selections/insertion points by probing appropriate range; convert bounds to source coordinates correctly.
- **Chromium/Electron AX:** enable/manual accessibility where needed in focus and secure-field sampling paths.
- **Secure-field sampling (Layer A):** ensure traversal reaches relevant controls (adequate but bounded node/time budget, periodic refresh); no silent misses due to depth-first/caps/disabled AX.
- Verify `AXFrame`, event timing/throttling, and recorded indices remain consistent with analysis/planner expectations.

### C5 Typing traces (`Sources/LumenAnalysis/Service.swift`, `TypingTracer`/`TypingAnalyzer`, request types)
- Ensure `AnalysisRequest` carries needed AX/event context; build anchors per burst (caret/focused element center, fallback to recent click) instead of nil where possible.
- Diff against previous frame/state to avoid treating pre-burst UI (e.g. launcher panel) as typed content; filter/size constraints must remain correct.
- Confirm `typingBursts()`/`InputEvent` semantics in `LumenCore`.

### C6 Analysis order & publish (`Sources/LumenAnalysis/Service.swift`, UI/editor integration)
- Make typing analysis run/publish early (cheap path first) so zoom/derived state can update without waiting for slow OCR. Run OCR/privacy without blocking typing-derived UX; publish partial/progressive results safely.
- Expose/call internal `runTyping`/`runPrivacy` or equivalent if needed by current architecture, but preserve cancellation/error/progress semantics and thread safety.

## D. Typing sound (never silent)

### D1-D4 Assets, mapping, mixing (`LumenAudio/TypingPacks`, `Mixer`, `LumenDirector` cues, bundling)
- **Assets:** use existing `App/public/assets/typing/...` packs (and any required fallback sample) and ensure bundled into app (`Tools/make-app.sh` currently copies typing); packaged runtime must find them via bundle resources.
- **Resolver:** single source of truth for pack root/dir/list (bundle first, dev/checkout fallback) with no cwd dependence.
- **Key mapping:** cross-check against pack `config.json` `defines` (current default pack defines only 14,15,28,30,36,42,57). Map mac keycodes to pack codes/samples that exist; for unmapped keys choose a deterministic available fallback sample from the pack (never silence, never invalid code).
- **Mixing:** resample pack audio to engine/timeline rate as needed, normalize sensibly, apply consistent gain staging (`typingLevelDb`/cue gain) without double-stacking unintended SFX gain, add light velocity/gap gain shaping if appropriate, and ensure cues fire when enabled.

## E. Privacy: accurate, fast, clean, fail-closed

### E1 OCR (`Sources/LumenAnalysis/OCR.swift`, shared luma/rect helpers)
- OCR only changed/dirty regions when possible (with padding/merge/full-frame fallback as needed), tile large regions, limit concurrency appropriately, and keep tracking/sampling strategy efficient.
- On timeout/cancel/failure: return/publish **partial detections found so far** (do not discard to empty) with clear error state; do not cache invalid/empty-due-to-timeout results as successful scans.

### E2 Privacy/export gate (`Service`, `LumenUI`/`App` export gate)
- Gate/progress must always resolve on all terminal states (success, partial, error, timeout, cancel, disabled). UI must clear “Scanning…/Export disabled…” states accordingly (including defensive timeout/grace if needed). Never leak a stuck gate.

### E3 Exact secret boxes
- Use Vision’s range/bounding-box for the matched secret when available; fall back safely (mask more, not less) when exact bounds unavailable. Keep `OCRDetection` normalization correct.

### E4 Conservative mask envelope
- Track/interpolate with a conservative spatial/temporal envelope (and padding relative to text height/region) so motion/scroll/zoom doesn’t expose secrets. Tune for safety over tightness.

### E5/E6 Mask rendering & quality (`LumenRender` masks/emphasis/renderer/shaders, GPU structs)
- Reconcile mask data packing, shader, and renderer with current types (`rect`/height semantics, mode encoding, padding/cell sizing). Produce clean styles (e.g. frost/pixelate/redact) with rounded edges, in-rect sampling (no outside bleed), mipmapped textures/blits as needed, no unnecessary per-frame buffer churn, and no upscale/quality pop when masks appear/disappear. Update upscale/cache signatures if masked output affects reuse.
- Update UI labels/defaults and sensitivity→threshold/confidence mapping consistently with `PrivacyPlan`/`SensitivePatterns`.

### E7 Layer A secure fields
- Ensure secure/sensitive field sampling reaches password/secret inputs in browsers/apps (AX enablement, traversal strategy, budget). Coordinate with OCR/mask pipeline.

### E8 Sensitive patterns (`Sources/LumenCore/Sensitive.swift`)
- Confirm required detectors exist and are not app/region gated; fix gaps only if found (with cache/version bump implications if output changes).

## F. Audio, captions, UI/export, rest

### F1/F2 Processed voice & denoise
- Keep real dereverb path effective; bump voice cache revision if output changes. Remove/avoid discarding completed denoise results after the fact; rely on real cancellation/timeouts.

### F3 Mic controls/comments
- Fix misleading comments/config descriptions and surface relevant system mic voice-isolation controls in audio UI if applicable.

### F4 Transcription (`LumenAnalysis`/`LumenSpeech`/call sites)
- Ensure transcription receives cleaned voice audio (`cleanVoiceURL` or equivalent) at all relevant call sites. Wire/use the intended engine (Moonshine, per `LumenSpeech`) and remove stale engine/picker paths if product direction requires; adapt to actual available models/APIs.

### F5 Captions
- Preserve user/proper nouns and existing casing where possible (vocab-aware, minimal sentence-casing). Default captions off unless explicitly enabled; find and remove unexpected enablement in toggles/migrations/normalizers/load paths.

### F6 Wallpaper/background blur
- Implement smooth, mip-aware blur without ghosting/double blur; create/upload/generate mips correctly; keep slider bounds/defaults sane and remove redundant blur stages.

### F7 Lanes & recovery (`LumenUI`, `LumenProject`/editing, recovery/finalize paths)
- Main timeline/lane must render `recordingSegments` and `clips`; show empty state only when both empty. Ensure recovery/finalize maintain valid source duration/trim/time-map invariants.

### F8 Stop hang (static trace)
- Trace `session.stop()` and all post-stop/open work in `App`/`LumenUI`: project load, derive, analysis kickoff, thumbnails, waveform, UI refresh. Move heavy/blocking work off `@MainActor` (e.g. detached/background tasks) while keeping UI state/progress updates on main.

## Packaging/build integration
- Keep `Package.swift` resources/targets consistent with any moved/added assets or shaders. Keep `Tools/make-app.sh` bundling correct (typing packs, wallpapers, metallib, frameworks, signing). No cwd-dependent runtime assets.

## Final checklist (mark done / not done / n/a + reason; list files changed)
- [ ] A1 migrations/defaults + rederive-on-open reconciled for old projects
- [ ] A2 cache/revision bumps applied from current versions where outputs changed
- [ ] B1/B4/B5 planner: bounded context scale, stable typing scenes, caret focus, hold/tail
- [ ] B2/B3 camera/live: smooth param-driven springs and live behavior
- [ ] C1–C4 AX/input: launcher focus, insertion caret, Chromium AX, secure-field traversal
- [ ] C5 typing trace anchors + previous-frame diff verified/fixed
- [ ] C6 typing analysis publishes early; OCR/privacy non-blocking integration
- [ ] D1–D4 typing sound: bundled assets resolved, mapping vs config, resample/levels, never silent
- [ ] E1–E3 OCR: incremental/partial-safe/accurate boxes
- [ ] E2 privacy/export gate always resolves in UI and service
- [ ] E4–E7 masks: conservative envelope, clean rendering, no quality pop, Layer A reach
- [ ] E8 SensitivePatterns audited (no app/region gate)
- [ ] F1–F5 audio/voice/transcript/captions corrected and wired
- [ ] F6 wallpaper blur/mips corrected
- [ ] F7 lanes and recovery/finalize invariants correct
- [ ] F8 stop/open main-thread work traced and moved off main
- [ ] `make build` passes (only build run)
