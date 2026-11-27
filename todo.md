# Lumen — Core overhaul: todo

Last audited: 2026-11-27 (IST).
Baseline main: `a32842f6109535338dd871c84822fb5b37ad4bc0`.
Part 1: [PR #42](https://github.com/duggal1/lumen/pull/42), verified head `dc462a0c0475e070e411077f3f843987caf81c74`; [macOS verification succeeded](https://github.com/duggal1/lumen/actions/runs/45894273304), merged into main as `f8327cd96d4a434e93cf992da28043ba79f65700`.
Part 2: [PR #43](https://github.com/duggal1/lumen/pull/43). Implementation in review; use latest head's checks, not superseded runs.

## Status and how to work

- [x] Code implemented or a specifically named verification gate completed. This does **not** mean verified, released, or flawless.
- [ ] Remaining work or verification not established.
- A part is complete only when implementation, regression tests, relevant real recordings, release build and merge are verified. Record evidence links and actual measurements before checking a verification box.
- Work on exactly one part at a time. Five implementation PRs total; keep documentation changes within those PRs. Do not start the next part while the previous part has failing or unverified release-critical checks.
- Preserve the approved SwiftUI frontend and timeline, existing project files, native Apple Silicon implementation and MCP contract. No unnecessary rebuilds, fake results, hidden fallbacks, bypassed tests or weakened assertions.

## Progress snapshot

| Part | Scope | State |
|---|---|---|
| 1 | Attention evidence, hover, typing | All macOS CI checks passed; merged PR #42; real-recording calibration pending |
| 2 | Camera motion, zoom, framing, cursor, blur | PR #43 merged; corrected PR CI passed; real-recording proof pending |
| 3 | SFX replacement and studio audio | Backend reconstruction in progress; new assets and listening blocked |
| 4 | Adaptive glass, layout, recording, editing | Not started |
| 5 | Preview/export performance and release proof | Not started |

Implementation progress: 2/5 parts have a code PR (40% by part count, **not effort-weighted**). CI-verified and merged: 1/5. Real-recording signoff: not yet established. No product-level accuracy or subjective camera quality claim follows solely from synthetic tests.

## Part 1 — Attention intelligence and typing (PR #42)

Relevant files: `Sources/LumenDirector/Activity/ActivityTypes.swift`, `ActivityShotBuilder.swift`, `VisualAutofocus.swift`, `VisualZoom.swift`, `TypingFocus.swift`, `Director.swift`, `Sources/LumenAnalysis/ActivityAnalyzer.swift`, `Shaders/ActivityGrid.metal`. See [technical notes](Docs/Verification/CORE-01-ATTENTION.md).

### Implemented on the PR branch (9 change groups)

- [x] Use the last causal pointer observation, never a future observation; sort input timestamps and reject nonfinite inputs.
- [x] Suppress stationary local hover, including delayed tooltip-like activity.
- [x] Track entire hover-associated components so continuous activity cannot re-enter merely because the initial suppression window expired.
- [x] Remove cursor-proximity reward from the legacy visual zoom path; preserve eligible autonomous remote results.
- [x] Abstain from prolonged spatially stationary activity; keep its busy interval for time editing.
- [x] Require corroborated high-confidence caret/change evidence for pixel-derived typing focus.
- [x] Respect distinct focus epochs, application/window/host context when merging typing fields.
- [x] Include chromatic differences in GPU activity detection; bump analyzer cache version and reject failed command buffers.
- [x] Hash activity payload and typing sample evidence for planning cache invalidation.

### Verification and residual issues

- [x] Swift debug build, complete unit/integration step, Metal compilation, release packaging and code-signature checks succeeded on PR #42's merged head. [Run 45894273304](https://github.com/duggal1/lumen/actions/runs/45894273304).
- [ ] Replay actual hover-only footage: delayed and remote tooltips, menus opening via hover, nested controls, pointer stops/leaves, hover effects near previously clicked controls.
- [ ] Test genuine autonomous AI responses, result cards, changing colors, loaders resolving, independent visual activity during pointer movement. Do not disable visual autozoom.
- [ ] Calibrate 2.5 s remote uncertainty guard, local suppression radius, confidence cutoff and prolonged-animation abstention against positive and negative footage. Energy-only observations cannot prove semantics: late remote hover, independent results inside guard windows, and meaningful prolonged changes remain ambiguous.
- [ ] Verify no zoom from cursor movement/dwell alone, including legacy entry point and live recording.
- [ ] Replay typing in Safari, Chrome, VS Code, Terminal, Notes, TextEdit and custom web inputs; pointer elsewhere, rapid typing, paste, wrapping, backspace, autocomplete, stale/denied AX.
- [ ] Check secure field behavior and avoid storing typed characters or exposing sensitive input.
- [ ] Validate long editor active-region framing and transitions; field geometry alone may be too broad. Carry remaining motion/framing work into Part 2.
- [ ] Audit live vs post-recording decision policy; align shared semantics without requiring live capture to predict the future.
- [ ] Measure cache hashing and RGB-analysis overhead on M1 8 GB.
- [ ] Record false positives, false negatives, typing target accuracy and regression videos in verification report.
- [x] Merged PR #42 after successful CI; confirmed main merge commit `f8327cd96d4a434e93cf992da28043ba79f65700`.

## Part 2 — Cinematic motion and precise framing

Part 1 is CI-green and merged. Part 2 PR #43 targets main. Real-recording signoff for both parts is still pending.

### Implemented in Part 2 branch

- [x] Distance/scale-aware anticipation for isolated, resolved automatic actions, preserving explicit easing/manual and dense action timing.
- [x] Smooth continuation of recorded follow paths after the opening optical leg, without a hard-coded horizontal bias.
- [x] Numerically stable fixed-pivot release that starts at the actual previous center and clamps to crop bounds.
- [x] Use capped scale for exact fixed pivot and avoid applying a full-source pivot in crop space.
- [x] Integrate live camera to the event timestamp; handle slow display callbacks without losing elapsed time.
- [x] Only explicit actions may reveal live smart crop; stale zoom targets cannot be reopened by navigation.
- [x] Reject delayed typing focus replies that arrive after a newer click, before they can change either crop or zoom.
- [ ] Confirm latest Part 2 macOS checks and inspect real motion footage.

Relevant files: `LumenDirector/Planner.swift`, `Camera.swift`, `LiveCamera.swift`, `Cursor.swift`, `TypingFocus.swift`, crop/layout planners, `LumenRender/ZoomTransform.swift`, `Renderer.swift`, Metal shaders.

- [ ] Reproduce excessively fast zoom-ins, forced scale jumps, unnatural hold/release, rapid retargeting and stale zoom-out using real footage.
- [ ] Establish one shot lifecycle and one camera subject at any instant. Do not open a new shot just because another event arrived.
- [ ] Make zoom duration depend on displacement, scale, action duration and available time; prefer smaller movement or no shot when insufficient time.
- [ ] Maintain position/velocity continuity during retargeting; bound acceleration and jerk, eliminate overshoot and reverse pumping. Evaluate minimum-jerk trajectories and damped motion.
- [ ] Use post-recording lookahead for natural lead-in; live uses causal evidence. Initial tuning: ordinary entry 0.55–0.85 s, major reframe 0.85–1.3 s, release 0.65–1.1 s. Tune from video, not blind constants.
- [ ] Stable typing hold, appropriate inactivity grace, active editor region and safe interior; do not chase each caret or overzoom entire documents.
- [ ] Respect actual max scale, source/output sharpness, subject margins, and exact resting scale/position at clip boundaries.
- [ ] Centralize coordinate transforms: global points, Retina pixels, capture regions, crop, viewport, layout and output. Validate mixed displays, negative origins and portrait sources.
- [ ] Validate classic and loupe zoom, manual region, duration, intensity, disable/remove, undo/redo, project reopen. Automatic replan must preserve manual edits.
- [ ] Keep cursor smoothing independent of camera decisions; preserve click coordinates/timing, hotspot, idle hide, reappearance, loop and Smooth/Medium/Rapid/None behavior.
- [ ] Implement/validate velocity-derived optical blur for camera zoom, pan and cursor independently. Static text, overlays and privacy masks stay sharp; no blur at rest.
- [ ] Verify 16:9, 1:1, 9:16 framing and webcam safe areas; impossible compositions reduce magnification.
- [ ] Add trajectory, crop, retargeting and real-render regression tests; inspect frame-by-frame traces and videos before merge.

## Part 3 — Replace all sound effects; studio voice

Relevant files: `LumenAudio/{BundledAudioAssets,KeySoundEngine,SFX,TypingPacks,TypingSampler,Mixer,Studio,ProcessedVoice,DeepFilterNet,Dereverb,DSP,Mastering,AudioIO}.swift`, sound assets, `scripts/fetch_sounds.py`, `Tools/make-app.sh`, CI and sound preview UI.

- [ ] Inventory all old effects and routes: Resources/Sounds, Resources/TypingPacks, App/public/assets/{typing,cursor-clicks,touches}, loose interaction MP3s. Preserve music.
- [ ] Fetch genuinely new, professional recorded keyboard and mouse sounds from verified redistribution-compatible sources; audition originals. No generated sounds, fake releases, reused fallback files or unlicensed sources.
- [ ] Record original URL, creator, license, original/processed hash and processing history; retain attribution. Check duplicate and near-duplicate recordings.
- [ ] Remove obsolete effects and routes after validating replacements. Do not map missing key release to key press: omit release if no authentic sample.
- [ ] One canonical asset library and resolver; preview and export must use the same asset and gain routing. Preserve old project settings through honest migrations.
- [ ] Avoid aggressive short-transient LUFS mastering; protect attack/decay, keep level restrained and natural. Validate sustained typing and click sequences by listening.
- [ ] Align sounds to actual recorded key and click events; handle repeat, cuts, pause/resume, speed changes; no hover sounds or duplicate cues.
- [ ] Update package and CI assertions to verify canonical manifest and absence of legacy assets; never retain obsolete sounds to satisfy old tests.
- [ ] One automatic local studio voice policy, no user-facing Standard/Podcast/Noise Reduction modes.
- [ ] Audit noise suppression, de-click, dereverb, EQ, dynamics, loudness, limiting and caching; adapt to input, preserve speech identity and articulation.
- [ ] Keep mic/system/music/SFX stems separate; music must not mask narration. Verify multichannel routing, AirPods, fan/keyboard noise, clipped/quiet/clean voice and sync.
- [ ] Listen to actual before/after audio on speakers/headphones; add regression tests, objective metrics and provenance report; run macOS verification before merge.

## Part 4 — Adaptive glass, layouts, capture and editing reliability

- [ ] Fix `FloatingGlass.swift`: appearance alone is not actual background luminance. Use authorized backdrop evidence/native adaptive material; light backgrounds get light glass, dark backgrounds dark glass, matching text/icon contrast.
- [ ] Mixed backgrounds, gradients, changes under stationary/moving panels, multiple displays; add hysteresis and smooth tint transitions. Honor Reduce Transparency and contrast settings. Never silently request extra screen permissions or claim sampling when unavailable.
- [ ] Validate all native floating panels without redesigning approved UI.
- [ ] Verify screen-only, camera-only, split, overlay and cutout layouts; webcam cannot obscure active subject. Stable face tracking, temporal mask, speech-aware visibility with debounce; prevent corner bouncing.
- [ ] Reframe zoom, camera, captions and shortcut overlay across 16:9, 1:1, 9:16.
- [ ] Audit ScreenCaptureKit display/window/region, webcam, mic and system audio capture; exact source selection, no substitution, pause/resume, monotonic timestamps, disconnect, low disk, sleep, cancel and finalization.
- [ ] Crash recovery target ~2 s: actual forced process termination and recovery, media container durability, recoverable projects. Report measured loss rather than guaranteed claims.
- [ ] Validate project persistence, undo/redo, trims, speed ramps, transcript sentence deletion, filler removal, silence cuts without deleting important silent actions, local captions and model-unavailable states.
- [ ] Device capture: current DeviceCapture.resolve explicitly throws screenCaptureUnsupported. Investigate supported Apple API/companion path and matching bezels. If unavailable, mark blocked; never pass off Continuity Camera as iPhone screen recording.
- [ ] Confirm recordings, voice, transcripts, masks and analysis remain local by default; optional upload only with explicit user choice.
- [ ] Validate legacy projects and MCP tools. Test real app across relevant OS/hardware; no fake pass for unsupported features.

## Part 5 — Performance, export and final signoff

- [ ] Baseline M1 8 GB: release build, representative projects, p50/p95/p99 frame time, dropped frames, peak RSS, CPU/GPU, thermal state, analysis latency and export wall time.
- [ ] Profile repeated decoding, cache invalidation, actor contention, main-thread stalls, GPU waits, allocations and texture pools; use bounded concurrency/backpressure rather than maximizing threads blindly.
- [ ] Use one immutable revisioned composition for preview/export; no mixed-revision state, stale results or divergent camera geometry/audio/caption timing.
- [ ] Target sustained 1080p60 with 16.67 ms frame budget; measure editor response and seek/scrub responsiveness, no full reanalysis for audio gain/style-only edits.
- [ ] Export stretch goals: 40 s 1080p60 ≤5 s and 4K60 ≥3× realtime on target hardware. Measure real results; never trade away frames, fidelity or correct timing just to claim throughput.
- [ ] Verify 1080p60/4K60 exports, H.264/hardware encoding, duration, frame count, audio stems, text sharpness, loupe, privacy masks, layouts and captions.
- [ ] Stress 30–60 minute recordings, memory pressure, repeated seek/edit/cancel, interrupted writes and device disconnection.
- [ ] Independent adversarial review on held-out actual recordings; each discovered defect gets a regression fixture and fix.
- [ ] Run Swift debug/release, complete tests, Metal build, packaging, resource checks, code signing, real export fixtures and Tools/prove.
- [ ] Publish before/after performance, audio, video and signoff reports; verify final merged main and all five PRs.

## Cross-part release gates (all initially unverified)

| Gate | Proposed target / evidence |
|---|---|
| Hover-only false shots | 0 on dedicated annotated fixtures and real clips |
| Typing subject resolution | ≥98% supported annotated cases |
| High-confidence caret visibility | ≥99% settled relevant frames |
| Unjustified zooms | ≤1 per 10 min representative footage |
| Overlap, invalid geometry, overwritten manual edits | 0 |
| Camera overshoot | ≤1% intended magnification change |
| SFX cue alignment | p95 absolute error ≤20 ms |
| Audio/video drift | ≤1 output frame over tested recordings |
| Unknown/legacy/synthesized shipped SFX | 0 |
| Crash recovery | Measured documented loss bounds |
| Privacy, project data loss | 0 unauthorized uploads or migration data loss |
| Preview/export mismatch | 0 beyond explicit documented tolerance |

These are targets, not results. Report denominator, fixture mix, device/OS, actual measurements and subjective quality review. A green CI run alone is not proof of natural camera motion or studio sound.

## Next action

Finish **Part 2 only**: inspect latest PR #43 CI, fix any failures without weakening tests, confirm merge on main once green, and record real-recording evidence for Parts 1 and 2. Do not begin Part 3 until this gate is addressed. Do not claim product-level resolution before verification.

### Part 2 CI correction

- [x] Identified three failures in [run 45898300325](https://github.com/duggal1/lumen/actions/runs/45898300325): two dense-click pan jerk tests and one click anticipation timing test; all eight new tests passed.
- [x] Bound ordinary click anticipation; preserve dense optical handoffs and restrict continuous follow to isolated actions. Existing assertions unchanged.
- [ ] Verify corrected head with all 882 tests and release packaging; merge only if green. Dense continuous-follow motion and real recording quality remain open.

### Part 3 implementation status

See [Part 3 plan](Docs/Part-03/plan.md). Fixed canonical click selection, duplicate key gain, release-flag routing, omission of unverified releases, stereo-linked limiter, preview window warm-up, offline UI side effects, and invalid denoiser output validation. Added conservative input-dependent voice expansion. Existing legacy packs and studio recordings remain for compatibility until authentic replacements are acquired. New assets and actual listening are not complete. Part 2 corrected CI [passed](https://github.com/duggal1/lumen/actions/runs/45954321659); both prior PRs merged.
