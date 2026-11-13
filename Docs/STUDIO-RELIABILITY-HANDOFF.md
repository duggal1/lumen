# Agent handoff: Studio zoom, typing, playback, privacy, and cursor fixes

## Assignment

Fix the regressions below in this native macOS Swift application. **Typing-synchronized zoom is the highest priority.** Deliver accurate focus, continuous camera motion, fast Studio entry, audio from the start of playback, context-aware privacy masking, faithful cursor states, and a natural click ripple.

This document is the implementation prompt and ordered plan. The task that produced it changes documentation only; no application fixes or runtime verification have been performed. Inspection baseline: `main` at `045d1ea`, November 14, 2026. Recheck source locations against HEAD before implementing.

Read `AGENTS.md`, `RULES.md`, `GIT-SKILLS.md`, and the whole `PLAN.md` first. Follow the current code where the architecture document is stale, and update affected specification sections alongside implementation. Work on `main` under the repository's Git instructions; do not introduce branches or PRs without authorization. Preserve unrelated working-tree changes. Do not blindly stage pre-existing untracked content.

## User-reported failures and required outcomes

| Priority | Failure | Required outcome |
|---|---|---|
| P0 | Clicking can trigger zoom, but typing does not reliably trigger or aim it. | Typing independently triggers zoom at the actual focused field/caret, including keyboard-only focus changes. Pointer position cannot steal typing focus. |
| P0 | Audio and click sounds arrive late while background processing runs. | The first played frame has its corresponding enabled audio and SFX. Processing must never make a running preview silently skip its initial audio. |
| P1 | Zoom targets and zoom-out transitions are inaccurate or insufficiently smooth. | Clicks land correctly; the caret stays visible; zoom-in, retargeting, holds, and zoom-out remain continuous and deliberate. |
| P1 | Entering Studio takes approximately 5–10 seconds and used to be fast. | Restore fast first paint and playable preview; heavy analysis must leave the opening critical path. |
| P1 | Processing is too slow. | Measure and shorten the actual critical path with bounded parallelism, caching, GPU work where beneficial, and cancellation. |
| P1 | Public landing-page emails and already-concealed password fields get blurred. | Pixelate real exposed email addresses only in verified private Google email/account contexts; preserve public page content and already-masked password glyphs. |
| P1 | Grab/select cursor states are missing. | Preserve distinct arrow, text-selection I-beam, pointing hand, open hand, and closed hand through capture, preview, and export. |
| P2 | Click ripples look abrupt or unnatural. | Use continuous expansion/fade with exact click timing and position, without a startup pop, hard cutoff, or expensive full-frame work. |

Interpret “extreme” and “ultra-smooth” as stronger precision, continuity, and responsiveness, with intentional close framing where useful. Do not replace this request with indiscriminately deeper zoom, slower transitions, extra blur, or unlimited worker counts.

## Scope and invariants

- Repair the existing capture → analysis → Director → renderer/audio path. No UI redesign, new editor mode, cloud analysis, browser extension, or unrelated refactor.
- Keep immutable source media, manual zooms/masks, saved preferences, undo/redo, and existing high-confidence secret protection intact.
- Core processing remains local. Never persist typed characters, password values, raw OCR text, or full browsing URLs in new metadata, logs, fixtures, or reports.
- Record input, focus, and context in source time/source pixels; convert host time once at the boundary. Derived camera and audio scheduling use the established output timeline.
- Preview and export share decisions, transforms, effects, and audio semantics. Progressive processing must not create two permanently different results.
- Swift 6 concurrency rules remain enforced. Keep per-frame work free of blocking AX/Vision calls, avoidable allocation, and UI-held locks.
- Version new persisted metadata and cache contracts. Old projects must still open; missing context must remain explicitly unknown.
- Do not weaken tests to bless incorrect focus, missing audio, or broader masks. New regression oracles should fail before the corresponding fix, then remain frozen per `RULES.md`.

## What source inspection established

These are code observations, not runtime reproductions or measured root causes. Confirm their contribution with fixtures and traces before choosing a fix.

1. **A typing pipeline already exists.** `Sources/LumenCapture/Input.swift:293–337` reserves AX focus on key-down, queries after a 40 ms delay, throttles/reuses reservations, and forwards key-down to live hooks through that AX-success path. `handle` skips the ordinary live-event hook for key-down. Without AX permission or a successful query, live typing delivery needs investigation; persisted keys still enter the event ring. Inspect this separately from offline Studio planning.
2. **Typing anchors can be incomplete or stale.** `Sources/LumenDirector/Planner.swift:106–142` prefers AX caret samples, then pixel traces, then a single-line-field estimate, then a click up to 20 seconds old. Any nonempty AX result wins over pixel traces for the whole burst. `plan:188–215` excludes activity near clip edges and drops typing intents with no resolved fixes. Verify sparse AX coverage, first/last-second typing, and keyboard-only focus changes.
3. **The visual fallback is coarse.** `Sources/LumenAnalysis/TypingAnalyzer.swift` processes bursts sequentially with one video reader per burst, sampling approximately 10 Hz. `TypingTracer.swift` finds a line-height change component, then tracks a fixed vertical band and rightmost changed column. Newlines, scrolling, backspace, caret blinking, unrelated animations, and multiple fields need explicit coverage.
4. **Typing analysis precedes other analysis.** `Sources/LumenAnalysis/Service.swift:102–114` awaits typing before launching OCR/face/activity/transcript work, with person masking afterward. The comment about “at most 2” analyzers does not itself enforce a scheduler limit. Determine actual CPU, decoder, and GPU contention rather than trusting comments.
5. **Opening still waits on recording-length audio work.** `Sources/LumenExport/ProjectSession.swift:191–244` reads complete mic/system/additional-mic tracks, computes VAD and the waveform envelope, and opens video sources before returning. `EditorModel.open` awaits this session even though it runs off-main. Moving work off-main alone does not reduce time to a usable Studio.
6. **Late audio is intentional in current transport code.** `Sources/LumenUI/EditorModel.swift:383–459` starts the video clock if the player is unloaded, mixes the entire timeline, then joins audio at the current video position. The initial audio is therefore skipped. The late-join path also schedules a future host start from an earlier sampled video position; measure that offset as a separate synchronization concern.
7. **Voice preparation can serialize expensive work.** `Sources/LumenAudio/Mixer.swift:77–115` holds one lock through cache-key generation, disk cache reads, and voice processing. Background `prepareVoice` and timeline mixing can contend here. Trace lock wait, duplicate work, denoiser cost, memory, and mix duration before restructuring ownership.
8. **Privacy decisions are broad and context-free at these boundaries.** `Sources/LumenProject/Overlays.swift:232` auto-applies categories including email/entropy. `Input.swift:480` marks fields secure from labels containing `secure|email|password|…`. `Sources/LumenDirector/MaskTracks.swift:54–86` masks whole secure fields. `Sources/LumenAnalysis/OCR.swift:288–303` can turn a password-like label plus a nearby or invented region into a confident secret detection. Those paths do not establish whether readable sensitive content is actually exposed.
9. **Mask tracking can associate across large movements.** `MaskTracks.swift` bridges 1.6 seconds, accepts movement within 40% of the source diagonal for the same hash, and adds 0.6-second lead/tail. Test navigation, scroll, repeated addresses, and unrelated replacement content before changing those constants.
10. **Cursor identity is lost in rendering.** `Sources/LumenRender/CursorAtlas.swift:296–303` renders pointing/open/closed hands with the same glyph and defaults other stock shapes, including the I-beam in this switch, to an arrow. Capture already defines distinct stock IDs. Fix both capture fidelity and rasterization where demonstrated.
11. **Motion systems already exist.** `Sources/LumenDirector/Camera.swift` uses quintic channels and continuous follow paths at a 240 Hz solve rate; it is not the exact spring implementation described in `PLAN.md`. `Sources/LumenRender/ClickEffects.swift`, `Renderer.swift:887–946`, and `Shaders/Shaders.metal:395+` already implement timed/refraction ripples. Tune and repair the existing paths rather than replacing them based on an old spec.

## Ordered implementation plan

### 0. Reproduce, instrument, and freeze acceptance cases

**Dependencies:** none. **Files:** existing tests and verification tools, plus narrowly scoped synthetic fixtures under `Tests/LumenTests/Fixtures/` and evidence under `Docs/Verification/`.

1. Record one controlled repro that clicks field A, moves the pointer away, types, tabs into B, types, wraps a line, backspaces, scrolls, drags, and pauses/resumes. Include typing at the recording start/end and a keyboard-focused omnibox/editor. Never use real private data.
2. Reproduce immediate Play on cold/warm open with mic, system audio, click SFX, and typing SFX where enabled. Record separate first-paint, first-video-frame, first-audible-sample, and full-processing times.
3. Create public landing-page and private mail/account fixtures with synthetic addresses, dates, ordinary copy, concealed password dots, and reveal/hide transitions. Include scrolling and navigation between those pages.
4. Add signposts for open stages, full-track reads, VAD/waveform, cache lookup, typing decode/trace, derive, voice processing, mix, audio readiness/scheduling, and first presentation. Log timings and reason codes without sensitive strings.
5. Add failing behavior tests before fixes. Reuse `InputRecorderTests`, `ZoomPrecisionTests`, `AutoZoomRegressionTests`, `ZoomTypingVerifyTests`, `TypingAudioTests`, `ClickEffectTests`, `PrivacyMaskGeometryTests`, and `PerformanceTests`; create missing integration/privacy/cursor coverage rather than forcing unrelated files to own it.

**Verify:** focused tests demonstrate each reproduction; save baseline traces and the recording fixture manifest. A passing synthetic planner test does not prove capture or actual exported-video synchronization.

### 1. Repair typing delivery, focus provenance, and tracking — P0

**Dependencies:** 0. **Primary files:** `LumenCapture/Input.swift`, `LumenCore/Core.swift` (`typingBursts`), `LumenProject/Models.swift`, `LumenProject/AnalysisTypes.swift`, `LumenAnalysis/{Service,TypingAnalyzer,TypingTracer}.swift`, `LumenDirector/{Planner,Director,Camera,LiveCamera}.swift`, and relevant session wiring.

1. Trace a key from event tap to persisted event, AX reservation, live hooks, burst detection, analysis callback, derived snapshot, and rendered camera. Fix the first broken boundary. Ensure key activity reaches consumers even when optional AX enrichment fails, without duplicate zoom triggers when enrichment arrives.
2. Model anchor provenance/freshness explicitly: event time, sample time, focus identity/epoch, coordinate space, and confidence. Rebase once, reject stale/out-of-bounds evidence, and prevent a pending query for field A from being reused as field B's caret. Keep AX work off the input and render hot paths.
3. Prefer fresh caret/selection evidence. Fill gaps with validated visual tracking in the focused region; do not let one AX fix suppress the rest of a burst's good pixel evidence. Use a recent click only when it still belongs to that focus context. Unknown focus must not become a guessed screen-center zoom.
4. Make typing independently trigger and sustain zoom through keyboard-only focus, pointer-away typing, pauses, line wraps, selection replacement, backspace, IME composition, terminal/editor input, and scrolling. Separate text activity from shortcuts/navigation keys using key codes/modifiers and available focus evidence; never store characters.
5. Restrict visual tracking to plausible text regions, reject unrelated page animation, and recover when the line/field changes. Merge overlapping decode windows and avoid decoding the same video repeatedly. Keep temporal sampling error separate from camera easing delay in diagnostics.
6. Publish typing-derived zoom promptly with revision/focus checks. Older analysis must not overwrite later edits, manual segments, or the active project's snapshot. Apply the same anchors offline and live where those paths exist.

**Verify:** real recorded browser/editor fixtures and synthetic tests. At least one test must remove all mouse clicks and retain valid focus/caret data; another must move the pointer to the opposite corner while typing. No missed typing intent with valid evidence; no shortcut-only zoom; no focus jump to an unrelated click.

### 2. Repair zoom accuracy and continuity — P1, immediately after typing

**Dependencies:** 1. **Primary files:** `LumenDirector/{Planner,Camera,Accuracy}.swift`, `LumenRender/ZoomTransform.swift`, and existing zoom tests/CLI verifier.

1. Audit Quartz global points → captured-region pixels → normalized focus → layout viewport → output pixels. Cover Retina, nonzero/negative display origins, region/window capture, padding, portrait output, and aspect changes. Use one transform contract.
2. Keep exact click coordinates as the target; AX element bounds may size the scene but must not silently replace the clicked location. For typing, reserve forward reading room while keeping the caret and active line inside the viewport.
3. Remove unjustified trigger/scale/edge exclusions exposed by fixtures. Respect supported saved scale limits; investigate the planner's internal 2.6 cap rather than simply increasing defaults. Preserve target visibility and text legibility when framing more closely.
4. Preserve position, velocity, and acceleration through click→typing transitions, moving-caret targets, interrupted zooms, nearby scenes, and zoom-out. Keep log-space scale and time-based evaluation; inspect the current quintic solution before changing algorithms.
5. Balance lead-in with arrival at the actual interaction. Do not obtain smoothness by making the camera trail typing, endlessly follow mouse noise, crop the target, or mask discontinuity with more motion blur.

**Verify:** existing zoom precision/easing/crop/transform regressions plus actual rendered trajectories. Run at 60/120/240 fps and 16:9/9:16. Preserve manual zooms and deterministic results after cuts, ramps, seeks, and reopening.

### 3. Remove silent playback and reduce Studio latency — P0/P1

**Dependencies:** 0; audio cue publication also consumes corrected events from 1. **Primary files:** `LumenUI/{EditorModel,AppModel,PreviewView}.swift`, `LumenExport/ProjectSession.swift`, `LumenAudio/{Mixer,AudioIO,AudioMapped,ProcessedVoice}.swift`, `LumenAnalysis/{Service,Cache,DirtyRects,TypingAnalyzer}.swift`, `LumenRender/FrameSource.swift`.

1. Split minimal project opening from heavy preparation. Show the persisted project and first frame without complete audio reads, waveform/VAD generation, neural cleanup, transcription, or privacy scanning. Load cached waveform/VAD and incrementally prepare missing data. Preserve export privacy gating independently of editor interactivity.
2. Replace full-timeline-mix dependency for first playback with a bounded, ready audio prefix/read-ahead path, or reuse an exact valid mix cache. Include enabled click/typing cues in that first audible window. Use one output time map and shared DSP semantics so final preview/export agree.
3. Start video and ready audio against the same future host instant after measured device latency compensation. Never silently start video while mandatory audio is unavailable. If preparation genuinely cannot meet the startup budget, show a brief truthful preparing state with the clock stopped; do not call that success or join several seconds late.
4. Define readiness for silent, audio-disabled, missing-source, and analysis-failure cases. Do not block silent projects on nonexistent audio. Enhanced audio can replace provisional audio only at a synchronized boundary with a short crossfade and no time/level discontinuity; identify provisional processing in existing status UI if used.
5. Replace the whole-pipeline voice lock with explicit ownership and single-flight work keyed by immutable source/settings. Keep locks around cache publication only. Cancel obsolete jobs cooperatively inside DSP/decode chunks; merely cancelling an awaiting wrapper must not leave detached work consuming resources.
6. Use a measured resource budget for concurrent decode, typing, OCR, waveform, and voice jobs. Prioritize first frame + initial audible window + typing focus. Cache independent chunks, deduplicate jobs, publish partial results by revision, and prevent heavy background work from starving playback/capture.
7. Profile `DirtyRects.lumaTiles` and existing Metal/Accelerate paths. Move demonstrated large pixel reductions/diffs to zero-copy GPU work when faster end to end; reuse buffers/pipelines. Keep stateful denoising and ordered DSP sequential within a stream unless boundary-state equivalence is proven. Parallelize independent streams/windows, not arbitrary adjacent samples.
8. Key caches with media identity, algorithm version, relevant settings/events, time map where applicable, and context policy. Write atomically; invalidate only affected work. Warm reopening must reuse valid analysis instead of just rescheduling it.

**Verify:** cold/warm immediate Play, seek, pause/resume, cuts/speed ramps, rapid edits, open A→B during processing, cancellation, corrupt/missing caches, and a long recording. Measure audible output against a synthetic visual marker/click, not just cue timestamps or waveform visibility. Compare before/after CPU/GPU/decoder time, queue wait, memory, and total preparation throughput with the same enabled features.

### 4. Make privacy depend on context and visible exposure — P1

**Dependencies:** 0; build on the scheduler/context contracts rather than adding a second pipeline. **Primary files:** `LumenCapture/Input.swift`, `LumenCore/Sensitive.swift`, `LumenProject/{Models,AnalysisTypes,Overlays}.swift`, `LumenAnalysis/{OCR,Service,Cache}.swift`, `LumenDirector/MaskTracks.swift`, `LumenRender/PrivacyMaskGeometry.swift` and mask-burn code.

Use this policy for automatic email/password decisions:

| Context/content | Automatic behavior |
|---|---|
| Verified Gmail/private Google account surface with a visible address | Pixelate the address substring/region only. |
| Public landing page, footer/contact address, date, or ordinary page text | Leave it visible; email syntax alone is insufficient. |
| Unknown host or old/imported footage without reliable context | Do not invent a private context. Keep email masking manual/proposed through existing review controls. |
| Password field displaying only concealment glyphs such as `••••••` | No extra pixelation solely from the password role/label. |
| Password revealed as readable text | Mask the exposed value and track reveal/hide transitions. |
| Existing high-confidence API/private keys, tokens, or explicit manual mask | Preserve existing protection; the email exception must not disable it. |

1. Separate detection from policy: category, geometry, confidence, context, and visible exposure are different facts. A nearby “Password” label or a field named “email” is not proof of exposed secret pixels. Remove guessed neighboring-region masking where it cannot establish exposure.
2. Add the smallest source-time context record needed: captured application/window association, verified browser host when available, and navigation/focus boundaries. Derive only the host from legitimate available AX/browser evidence and discard full URLs. Start with exact approved private hosts such as `mail.google.com` and `accounts.google.com`; do not treat every Google-branded page, title, logo, or substring match as private. Reject deceptive hosts such as `mail.google.com.example.test`.
3. Treat context as unavailable when permission/evidence is missing; do not add a browser integration just to fill that gap. Make legacy decoding and policy/cache versioning explicit. Honor stored manual decisions when policy-generated masks are regenerated.
4. Determine whether a password value is visually readable without collecting its plaintext. Secure-role metadata alone cannot distinguish concealed from revealed content. Avoid duplicate masks over dots while maintaining coverage through reveal/hide and partial-character exposure.
5. Track mask identity and geometry through scroll and animation. Reset at navigation, cuts, focus/window/context changes, or incompatible geometry. Do not bridge the same address across unrelated pages or slide a mask over intervening public content.
6. Keep masks in source pixels/source time, burned before mips and zoom/loupe sampling. Preserve manual masks and layered-export coverage. A cancelled/failed scan is incomplete, not a successful clean scan.

**Verify:** positive and negative synthetic corpus, unknown-context legacy project, spoofed host/title, public→Gmail→public navigation, repeated same address in two places, scroll, zoom, and password reveal/hide. Assert zero false masks in the curated public/dot-only negative fixtures and coverage/OCR-negative rendered output for in-policy exposed secrets. Track precision and recall separately; broad masks are not evidence of intelligence.

### 5. Restore cursor states and refine the ripple — P1/P2

**Dependencies:** 0; use corrected transforms from 2. **Primary files:** `LumenCapture/Input.swift`, `LumenDirector/Cursor.swift`, `LumenRender/{CursorAtlas,ClickEffects,Renderer}.swift`, `LumenRender/Shaders/Shaders.metal`.

1. Verify stock/custom shape sampling and timestamps during hover, text selection, mouse-down, drag, and release, including stationary shape changes. Preserve stock IDs through smoothing/serialization and retain custom bitmaps/hotspots.
2. Render distinct I-beam, pointing-hand, open-hand, and closed-hand art for shape-preserving cursor packs. Keep explicit stylized dot/ring overrides as user choices. Align hotspots under zoom and size compensation; do not turn a closed hand into a pointing hand or text selection into an arrow.
3. Treat “grab/select” primarily as recorded cursor fidelity. Inspect existing Studio drag/selection cursor affordances for the same defect, but do not add unrelated selection tools.
4. Keep ripple onset at the source click after time mapping and its center at the true hotspot. Tune existing expansion, refraction, opacity, and end envelopes for continuous onset/settle; no bounce, fixed-step animation, hard ring pop, or residual distortion after completion.
5. Reuse the existing bounded capture-region approach and buffers. Test overlapping clicks and preview/export parity. Keep visual treatment inside recorded content; honor reduced motion in application chrome.

**Verify:** a captured cursor-state strip and rendered golden frames, click hotspot error checks, overlapping-ripple tests, and motion clips at multiple output rates. If UI changes, follow the mandatory structure/tokens/state notes and two screenshot/review passes in `AGENTS.md`; static screenshots alone cannot validate ripple or camera smoothness.

## Acceptance gates

The following new numeric budgets are proposed implementation targets, not measured results. Record hardware, macOS/build, recording dimensions/duration, settings, cache state, and thermal state. Establish baselines before tuning; report blockers honestly rather than changing fixtures or excluding slow stages.

| Area | Gate |
|---|---|
| Studio entry | On a fixed 2-minute 4K60 reference recording: p95 first usable frame ≤1 second warm, ≤2 seconds with project caches absent; measure from Open action, not after session creation. Run at least 10 repetitions per condition. |
| Playback startup | On that fixture, p95 Play→synchronized A/V start ≤250 ms when prepared, ≤500 ms on immediate cold Play. No silent prefix or late missing click/typing cues. |
| Audio synchronization | Event-to-SFX placement within one output frame; measure physical/audio-loopback A/V skew separately, target ≤20 ms after output-latency compensation with no accumulating drift over 30 minutes. Retain the plan's <1 ms capture-clock alignment gate separately. |
| Focus correctness | Exact target classification on every curated typing fixture; steady AX-resolved caret geometry within 2 source pixels of fixture ground truth. Visual-fallback error and temporal sampling delay reported separately; caret remains in the safe viewport during active typing. |
| Click precision | Preserve the existing ≤0.5 source-pixel cursor pinning invariant; rendered focus must match the feasible clamped click target, accounting for source bounds and layout. |
| Zoom arrival | For the isolated click/typing fixture, reach ≥95% of planned log-scale by the first interaction within one output frame; sustained caret visibility must also pass, so earlier arrival cannot conceal a wrong target. |
| Motion | No unexplained position/velocity/acceleration discontinuities; camera trajectory energy above 8 Hz <1% per `PLAN.md`; bounded source viewport at every sampled time. Review zoom-out and target handoff, not only zoom-in. |
| Processing | On the same uncached fixture/settings, target ≥2× faster total required preparation versus measured baseline; report stage throughput and memory as well. Warm cache hits must skip equivalent analysis. Do not claim GPU acceleration from utilization alone. |
| Render | Preserve existing GPU budgets: <8 ms/frame at 60 Hz and <4 ms/frame at 120 Hz on the reference supported machine. Report missed deadlines under concurrent analysis. |
| Privacy | No automatic public-page/dot-only masks in the negative fixture corpus; retain ≥99% recall for the existing high-confidence secret corpus and rendered OCR-negative checks. Report any unsupported-context cases explicitly. |
| Lifecycle | Old projects decode, manual work survives, stale jobs cannot publish after project switches, and long-recording memory remains bounded by documented pools/windows. |

## Verification commands and limits

Use the actual repository commands, and inspect CLI help for fixture-specific options:

```sh
swift build
swift test --no-parallel --filter 'typing|Typing|caret|Caret|zoom|Zoom|click|Click'
swift test --no-parallel --filter 'privacy|Privacy|mask|Mask|cursor|Cursor'
make test
make verify
swift run --skip-build lumen-cli --help
swift run --skip-build lumen-cli smoothness "$PROJECT"
swift run --skip-build lumen-cli sync-check "$PROJECT"
swift run --skip-build lumen-cli zoom-verify "$PROJECT" --video "$EXPORTED_VIDEO" --out "$REPORT"
```

Set the three path variables to synthetic fixture artifacts. Confirm filtered tests actually execute; extend filters for new names. `zoom-verify` expects its visual marker/caret fixture, not arbitrary footage; unmatched markers cannot silently count as passes. Inspect `Tools/Verify/zoom-verify.swift` and `Sources/LumenCLI/ZoomVerify.swift` when preparing that fixture.

Current `make verify` runs tests, packages the app, and performs a short launch check. Its own output explicitly leaves hardware capture/sync/performance separate. It does **not** prove every verification gate listed in `PLAN.md`. `make bench` is not currently a Makefile target; inspect the existing `lumen-cli bench` command instead. Do not report checks that were not run.

## Completion report required from the implementing agent

Provide the root cause and fix for each reported issue; exact changed files/commits; failing→passing regression evidence; baseline/after startup, synchronization, throughput, and memory results; short before/after zoom/typing/ripple clips; cursor-state frames; positive/negative privacy render results; and any remaining limitations. Mark each issue fixed only after checking the actual capture, playable preview, and exported result where applicable.

Finish typing synchronization and first-play audio before spending time polishing ripple appearance. Deliver the complete requested repair without expanding scope.
