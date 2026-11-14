# Lumen: PLAN (for coding agents)

> Codename `Lumen`.
> A macOS-native recorder that outputs finished, Screen Studio-grade product demos with almost no editing. It covers the full Screen Studio feature set plus the highest-demand community requests (hub.screen.studio).
> **$0 stack:** Apple frameworks, Swift, Metal, one tiny C library (RNNoise). Optional behind a flag: whisper.cpp.
> **What changed from v1:** product thinking, scope discipline ("what NOT to build"), a hardened architecture (analysis cache, command bus, layout interpolation, source-time anchoring), and every feature from both feature lists mapped to modules and phases. Section numbers changed. v1's `Timeline` is now split into `Project` (persisted intent) and `Timeline` (derived snapshot).

---

## 0. Agent operating rules (strict)

1. Read this whole file before writing code. Build strictly in phase order (section 20). A phase is done only when its acceptance checks pass under `make verify`.
2. Swift 6 language mode, strict concurrency `complete`, zero warnings (`-warnings-as-errors` in CI).
3. Value types and pure functions by default. Classes only for owned resources (devices, queues, writers, Metal objects).
4. Per-frame hot paths never cross an actor boundary, never allocate, and never wait on a lock the UI can hold.
5. Module boundaries (section 6) are enforced by SwiftPM target dependencies. Never import upward.
6. Every algorithm in sections 10 to 13 gets unit tests on synthetic input **before** any UI wiring.
7. If a verification spike (section 19) contradicts this document, fix the document in the same commit.
8. Commit per milestone. Message format: `phaseN: what changed`.
9. **Zero network in the core app.** Only the `LumenShare` target may import `Network`/`URLSession`, and only behind `LUMEN_CLOUD`. No analytics, no telemetry, no phoning crash reporter. CI greps for violations.
10. Document every public type with a one-line doc comment stating its ownership and threading rule.
11. **One command bus.** Every user-visible action is a `Command` (section 4.5). Views, hotkeys, CLI, MCP, and App Intents all dispatch commands. Views never mutate models directly. A feature without a command does not exist.
12. **Source-time anchoring.** Anything bound to content (zoom, masks, captions, loupes, taps, layout segments) is stored in **source time of its clip**. Anything bound to the soundtrack (music, voice-over, SFX lanes) is stored in **output time**. Output time appears in derived data and the UI only (section 7.6).
13. **Non-destructive.** Media files are immutable. The only irreversible operations are export and the explicit "share-safe project" bake (section 14.6).
14. **Determinism.** No `Date()`, no unseeded randomness, no wall clock, no thread-dependent results inside Director, Analysis post-processing, or Render. Seed any RNG from the project id.
15. **Budgets:** file <= 500 lines, function <= 60 lines, type <= 400 lines. Module LOC budgets are in section 2.4.
16. **No placeholders in merged code.** No `fatalError("TODO")`, no stubbed implementations, no fake data paths. An unfinished feature is absent, not faked.
17. **Ambiguity protocol.** Pick the simplest option consistent with this document, write a one-line entry in `Docs/Decisions.md`, and continue. Do not invent features. Do not stall on questions you can decide.
18. **Accessibility and native feel.** Every control has an accessibility label, the whole editor is keyboard operable, and the UI respects Reduce Motion (the exported video does not).
19. Use `os_signpost` on every stage and pass. Use `Logger` with one category per module.
20. If a task requires violating any rule here, stop and amend this document first.

### 0.1 Feature-complete checklist (applies to every feature, no exceptions)

A feature is merged only when it has all of:

1. Data model fields (versioned, with migration if existing fields changed).
2. A `Command` (and its reducer case).
3. The Director / Analysis / Render implementation.
4. Tuning parameters with defaults and ranges in section 21.
5. Unit tests on synthetic input.
6. CLI or ControlAPI exposure.
7. A perf-budget check if it runs per frame.
8. A signpost.
9. Its row in section 3 marked done.

---

## 1. Product thinking

### 1.1 North star

**Press record, do the demo, press stop, export. The result is publishable without opening an editor.** Every automatic decision is overridable. Nothing automatic is ever destructive.

### 1.2 Who it is for

| Persona | Job to be done | Must-haves |
|---|---|---|
| **AI product founder** (primary) | Ship a 60 to 120 s demo for a landing page / X / investors. The model is slow, API keys are on screen, and it needs a vertical cut too. | Auto zoom, auto speed ramps for waiting, auto-masks, multi-aspect batch export, agent-driven recording. |
| **Developer / educator** | 10 to 30 min tutorials with lots of typing and a clean voice. | Typing-aware zoom, noise reduction with keyboard declick, captions, filler removal, crash safety. |
| **Designer / marketer** | Brand-consistent output, then finishing in Premiere/After Effects. | Presets, per-side padding, alpha export, separate cursor layer, stems. |
| **Agent (Claude / Cursor / AMP)** | Record a scripted demo end to end without a human clicking. | MCP tools, consent model, deterministic export. |

### 1.3 Pain points to features

| # | Pain | Lumen answer | Section |
|---|---|---|---|
| 1 | "My demo looks amateur." | Auto zoom, smooth cursor, motion blur, backgrounds, one-click export. | 10, 12 |
| 2 | "The AI is slow and the demo drags." | Auto speed ramps over idle spans, mic muted in ramps, pause shortening. | 10.1, 10.9 |
| 3 | "I leaked an API key on screen." | Auto-detect masks in source space, burned before zoom, OCR-negative test. | 9, 10.8, 12.6 |
| 4 | "Zoomed text is soft." | Native-pixel master, Catmull-Rom plus mip resampling, spike-gated upscaler. | 12.4, 12.5 |
| 5 | "I need it vertical for socials." | Any aspect ratio, automatic re-aim, one-click multi-aspect batch. | 10.3, 10.5, 14.5 |
| 6 | "Keyboard clatter ruins my voice." | RNNoise plus keystroke-aware declick using the event log. | 13.1 |
| 7 | "I need captions and to trim the ums." | Local transcription, caption styles, transcript editing. | 9, 10.9, 10.10 |
| 8 | "I finish in Premiere." | Layered export: no-cursor master + alpha cursor layer, stems. | 14.4 |
| 9 | "I lost a take to a crash." | Fragmented MOV, PCM journals, append-only events. | 8.2, 4.7 |
| 10 | "Zoom reacts to every mouse wiggle." | Click-vs-wiggle sensitivity, follow delay, dead-zone. | 10.3, 10.4 |
| 11 | "The webcam covers what I'm showing." | Placement solver with cursor avoidance and hysteresis. | 10.6 |
| 12 | "I want my agent to record." | ControlAPI plus MCP bridge with a consent gate. | 15 |

### 1.4 Product principles

1. **Defaults are the product.** The first export must be good with zero settings touched.
2. **Suggest, then one click, for anything semantic.** Zoom, ramps, and masks apply automatically. Cuts to speech (fillers, pauses) are *suggested* and applied with one click.
3. **Preview equals export.** Same renderer, same timeline, golden-tested.
4. **Never destroy source.** Everything is undoable. Media is immutable.
5. **Local first.** The core works with Wi-Fi off, forever.
6. **Few visible knobs.** Each inspector tab shows at most 6 controls. Everything else lives under "Advanced".
7. **Motion is a spec, not a vibe.** Smoothness has measurable gates (section 11).
8. **Native.** Menu bar, system fonts, system hotkeys, system share sheet, Shortcuts.

### 1.5 Success metrics (measured by benchmark suite and dogfooding, not telemetry)

| Metric | Target |
|---|---|
| Stop to first export, 2-min 1080p demo | <= 3 clicks, <= 60 s on M-series Pro |
| Auto-zoom acceptance on 3 reference demos | >= 80% of auto segments kept by a rubric reviewer |
| Smoothness report | Clean at 60 / 120 / 240 fps (section 11.1) |
| Capture/event sync error | < 1 ms, no drift over 30 min |
| Auto-mask recall, high-confidence categories (synthetic corpus) | >= 99% |
| Kill -9 recovery trials | 100% recover everything except the last <= 2 s |
| Export consistency | SSIM >= 0.995 vs the golden render for the same recipe |
| Recording overhead | Recorded in spike 2; regression-gated in `make bench` |

### 1.6 Feature tiers (ship order)

| Tier | Meaning | Ships in |
|---|---|---|
| **T0 Zero-edit core** | Record, auto look, auto zoom, smooth cursor, audio cleanup, export. | M2 |
| **T1 Production polish** | Layouts, captions, masks, clips/cuts, presets, fine controls, multi-aspect. | M3 |
| **T2 Differentiators** | Cutout, transcript editing, loupe, alpha/layer export, MCP, devices, 3D moves. | M4 |
| **T3 Stretch** | Upscaler (spike-gated), 8K (probe-gated), share links, view notifications. | After M5, gated |

---

## 2. Scope discipline: what NOT to build

### 2.1 Hard NOs

| Do NOT build | Why | Do instead |
|---|---|---|
| Accounts, login, servers we operate | Cost, liability, and it breaks "offline-first". | `ShareProvider` seam; self-hosted worker (section 16). |
| Custom ML model training | Months of work for no edge. | Apple Vision / Speech; spike MetalFX for upscaling. |
| A general NLE (arbitrary tracks, effect stacks, keyframe curve editor) | Infinite scope. | One main video lane, fixed overlay types, named audio lanes. |
| Plugin system, scripting language, node editor | Never pays back. | Presets plus the ControlAPI. |
| Custom video codec, muxer, or container code | Solved by AVFoundation. | `AVAssetWriter`, `AVAssetReader`. |
| Custom text shaping or font engine | Solved. | CoreText into a texture. |
| Custom UI toolkit; AppKit timeline drawing | Not needed. | SwiftUI `Canvas` with virtualized drawing. |
| CoreData / SwiftData / SQLite | Project is a tree of values plus binary logs. | `Codable` JSON plus append-only binary files. |
| Combine, RxSwift, DI containers, Redux frameworks | Ceremony. | `@Observable` plus plain `init` injection plus the `Command` reducer. |
| Windows / Linux / iOS app | Dilutes Metal and ScreenCaptureKit focus. | macOS only. (Recording an iPhone from the Mac is a feature, not an iOS app.) |
| Real-time collaboration, team workspaces | Needs servers. | Share-safe project bundle. |
| AI-generated content (voice cloning, avatars, b-roll, LLM scripts) | Off-mission. | None. |
| Social posting integrations | API churn. | System share sheet. |
| Generic 3D engine, glTF, 3D device models | Overkill. | One perspective homography with three presets (section 10.4). |
| Filter / LUT / chroma-key / transitions libraries | Scope creep. | Only what section 3 lists (cut and dissolve). |
| Live streaming, RTMP, multi-cam switching | A different product. | None. |
| Applying effects live during recording | Violates "record raw". | HUD only. |
| An LLM "AI director" at runtime | Non-deterministic. | Deterministic rules in `LumenDirector`. |
| Unsplash / stock browser in v1 | Needs network, keys, and licensing. | 30 bundled procedural wallpapers plus image import and drag-drop. |
| Abstract renderer backends | Pointless. | Metal only. |
| Settings explosion | Cognitive load. | Presets, 6 knobs per tab, Advanced collapsed. |
| Advertising 8K by default | Many Macs cannot do it. | Show only what the capability probe passed. |

### 2.2 Looks heavy, is required (do build it, in this minimal form)

| Component | Why it is required | Minimal form (the cap) |
|---|---|---|
| 1440 Hz dense derived tracks | One grid hits every export fps exactly. | Float32 chunks, memory-mapped from `cache/` in 60 s pages. Never fully resident. |
| Analysis cache | ASR / OCR / segmentation take minutes. Re-running them on every edit is unusable. | Files keyed by content hash in one directory. No database. |
| Command bus | UI, CLI, MCP, undo, and tests must share one mutation path. | One `enum Command` plus one pure reducer `reduce(&Project, Command)`. |
| `ResolvedLayout` interpolation | Five layouts, any aspect, smooth transitions, without N-squared transition code. | One struct, one spring (section 10.5). |
| Person-mask cache | Cutout needs per-frame masks that are too slow live. | Offline Vision pass to an 8-bit mask video at <= 720p. |
| Source-space masks burned before mips | Masks must survive zoom and never leak. | Rect tracks in source px plus one compute pass. |
| Per-source audio journals | Multi-input recording plus crash safety. | Raw f32 PCM append-only files wrapped to CAF at stop. |
| Local control socket plus MCP bridge | Agent automation. | About 400 lines, zero dependencies, consent-gated. |
| Layer export | NLE workflows and cursor preservation. | Same renderer with a `LayerSet` option and an alpha pixel format. |
| SSIM quality gate | Fixes "export quality differs between versions". | `lumen-cli quality-check` in `make verify`. |
| Capability probe | High-fps combos vary per Mac. | Cached matrix from real encode attempts. |
| Single `Transcript` type | Captions, transcript editing, and filler removal share word times. | One struct, one analyzer. |

### 2.3 Allowed protocol seams (everything else is a concrete type)

`FrameSource`, `TranscriptionEngine`, `MusicProvider`, `ShareProvider`, `ExportSink` (file / clipboard). Any new protocol needs two real conformers, or a justified test seam recorded in `Docs/Decisions.md`.

### 2.4 Complexity budgets (non-test Swift LOC; shaders counted separately)

| Module | Budget | Module | Budget |
|---|---|---|---|
| LumenCore | 2k | LumenAudio | 4k |
| LumenProject | 2.5k | LumenExport | 3.5k |
| LumenCapture | 6k | LumenControl | 2k |
| LumenAnalysis | 3.5k | LumenMCP | 0.8k |
| LumenDirector | 9k | LumenShare | 1.5k |
| LumenRender | 9k (+2.5k MSL) | LumenUI | 12k |
| LumenCLI | 2k | **Total** | ~58k |

Exceeding a budget by more than 25% requires a `Docs/Decisions.md` entry.

### 2.5 Tripwires (if you catch yourself doing this, stop)

- Adding a protocol with one conformer.
- Adding a setting the Director cannot explain in one sentence.
- Writing a "manager", "coordinator", or "service locator".
- Making the renderer depend on UI types, or the Director on Apple media types.
- Caching something that is cheaper to recompute than to invalidate.
- Writing a second code path for preview and export.
- Introducing a dependency (only `swift-argument-parser` is allowed, plus RNNoise vendored, plus optional whisper.cpp).
- Building UI for a feature that has no command.

---

## 3. Product definition

### 3.1 Feature matrix and traceability

Origin: **SS** = Screen Studio core, **CR** = community request, **LU** = Lumen original. Tier is section 1.6. Phase is section 20.

| # | Feature | Origin | Modules | Phase | Tier |
|---|---|---|---|---|---|
| | **Capture and sources** | | | | |
| 1 | Full display / single window / custom region | SS | Capture | 1 | T0 |
| 2 | Screen + webcam + mic + system audio as separate tracks | SS | Capture | 1 | T0 |
| 3 | Multiple simultaneous audio inputs (e.g. BlackHole + mic) | CR | Capture | 1 | T1 |
| 4 | Crash recovery (fragmented MOV, journals, append-only logs) | SS | Capture, Project | 1 | T0 |
| 5 | Pause and resume inside one recording | SS | Capture | 1 | T0 |
| 6 | Countdown and global hotkeys | SS | UI | 1 | T0 |
| 7 | Native performance (SCK, hardware encode) | SS | Capture | 1 | T0 |
| 8 | iPhone/iPad over USB with generic device frames | SS | Capture, Render | 12 | T2 |
| 9 | Import external video, edit like a recording | SS | Project, Render | 6 | T1 |
| 10 | Import extra clips (intro, outro, logos) | CR | Project | 6 | T1 |
| | **Zoom and camera** | | | | |
| 11 | Automatic zoom | SS | Director | 4 | T0 |
| 12 | Manual zoom, precisely placed on the timeline | SS | Director, UI | 4, 6 | T0 |
| 13 | Zoom depth / duration / easing / focus | SS | Director | 4 | T0 |
| 14 | Fine auto-zoom: min/max scale, follow delay and speed, centering offset, click-vs-wiggle sensitivity | CR | Director | 4 | T1 |
| 15 | Toggle background blur during zooms (default off) | CR | Render | 4 | T1 |
| 16 | Cinematic zoom preset | CR | Director, Render | 4 | T1 |
| 17 | 3D camera moves (Lean, Float, Reveal) | CR | Director, Render | 10 | T2 |
| 18 | Glass loupe | SS | Director, Render | 9 | T2 |
| 19 | Real-time upscaler for zoomed text | SS | Render | 10 | T3 |
| 20 | Motion blur | SS | Render | 4 | T0 |
| | **Cursor** | | | | |
| 21 | Smooth cursor | SS | Director | 3 | T0 |
| 22 | Click effects (press, ripple) | SS | Director, Render | 3 | T0 |
| 23 | Cursor style, size, packs | SS | Render | 3 | T0 |
| 24 | Hide when idle | SS | Director | 3 | T0 |
| 25 | Loop cursor position (seamless loops) | SS | Director | 3 | T2 |
| 26 | Constant cursor size during zoom | CR | Director | 3 | T0 |
| 27 | Custom and holiday cursor packs | CR | Render, Project | 3 | T2 |
| 28 | Manual click/tap indicators | CR | Director, UI | 3, 6 | T1 |
| 29 | Independent cursor layer export with alpha | CR | Export | 10 | T2 |
| | **Layout and framing** | | | | |
| 30 | Any aspect ratio incl. 5:4, 4:3, 21:9, custom | SS, CR | Director, Render | 2 | T0 |
| 31 | Automatic re-aim of zooms, layouts, captions | SS | Director | 4, 7, 8 | T1 |
| 32 | Backgrounds (solid, gradient, mesh, image, blurred), padding, shadow | SS | Render | 2 | T0 |
| 33 | Independent per-side padding and per-corner radii | CR | Render | 2 | T1 |
| 34 | Presets (full looks) | SS | Project, UI | 6 | T1 |
| 35 | Layouts: camera fullscreen, split, overlay, screen only, cutout | SS | Director, Render | 7 | T1 |
| 36 | Smooth layout transitions | SS | Director | 7 | T1 |
| 37 | Independent per-layout camera settings | CR | Project | 7 | T1 |
| 38 | Camera cutout, no green screen | SS | Analysis, Render | 7 | T2 |
| 39 | Face tracking and auto-framing | SS | Analysis, Director | 7 | T1 |
| 40 | Smart framing: camera never covers the cursor | SS | Director | 7 | T1 |
| 41 | Auto-hide/move camera when the mouse is behind the face | CR | Director | 7 | T1 |
| 42 | Hide camera during silence | SS | Director | 7 | T1 |
| | **Editing** | | | | |
| 43 | Trim, split, delete, multi-clip | SS | Project, UI | 6 | T0 |
| 44 | Cut/split always at the playhead, never the last click | CR | Project, UI | 6 | T0 |
| 45 | Speed ramps (manual plus auto idle) | SS, LU | Director | 6 | T0 |
| 46 | Transcript-based editing | SS | Analysis, Director | 8 | T2 |
| 47 | Filler-word and pause removal | SS | Director | 8 | T2 |
| 48 | Manual subtitles / text blocks | CR | Project, Render | 8 | T1 |
| | **Audio** | | | | |
| 49 | On-device noise reduction (RNNoise plus keystroke declick) | SS, LU | Audio | 5 | T0 |
| 50 | Mic modes: Standard, Loud, Podcast, Off | SS | Audio | 5 | T1 |
| 51 | Independent mic and system levels | SS | Audio | 5 | T0 |
| 52 | Separate audio-track export plus stems | CR | Export | 5, 10 | T1 |
| 53 | Import external audio on extra lanes (voice-over, music) | CR | Audio | 5 | T1 |
| 54 | Multilingual voice-over variants | CR | Audio, Export | 10 | T2 |
| 55 | Music library plus import, auto-duck | CR, LU | Audio | 5 | T1 |
| 56 | SFX (soft click, whoosh) | LU | Audio | 5 | T1 |
| 57 | Loudness normalization | LU | Audio | 5 | T0 |
| | **Captions** | | | | |
| 58 | On-device transcription | SS | Analysis | 8 | T1 |
| 59 | Caption styles and animations | SS | Render | 8 | T1 |
| 60 | Readable positioning per aspect and content | SS | Director | 8 | T1 |
| 61 | Toggle word highlighting (accessibility) | CR | Render | 8 | T1 |
| 62 | SRT / VTT sidecar export | LU | Export | 8 | T1 |
| | **Privacy** | | | | |
| 63 | Multiple independent sensitive-data masks | SS, CR | Render, Project | 9 | T1 |
| 64 | Auto-detect sensitive data, adapts under zoom | CR | Analysis, Director | 9 | T1 |
| 65 | Highlight tool | SS | Render | 9 | T2 |
| | **Export and sharing** | | | | |
| 66 | MP4/MOV up to 4K60, HEVC / H.264 / ProRes | SS | Export | 6 | T0 |
| 67 | GIF | SS | Export | 6 | T1 |
| 68 | 120 / 144 / 240 fps; 8K only if the probe passes | CR | Export | 6, 10 | T1, T3 |
| 69 | Alpha / transparent render (ProRes 4444, HEVC alpha) | CR | Export, Render | 10 | T2 |
| 70 | Export quality consistency (recipe versions, SSIM gate) | CR | Export | 10 | T1 |
| 71 | One-click multi-aspect batch export | SS, LU | Export | 6 | T1 |
| 72 | Clipboard export | SS | Export, UI | 6 | T1 |
| 73 | Project sharing (share-safe bundle) | SS | Export, Project | 10 | T2 |
| 74 | Shareable links with comments | SS | Share | 15 | T3 |
| 75 | Email on link creation / view | CR | Share | 15 | T3 |
| | **Automation and platform** | | | | |
| 76 | MCP server, ControlAPI, App Intents | CR | Control, MCP | 11 | T2 |
| 77 | Headless CLI | LU | CLI | 0 onward | T0 |
| 78 | Preview equals export (same renderer, golden-tested) | LU | Render | 2 | T0 |
| 79 | Offline-first, zero network in core | SS | all | all | T0 |

### 3.2 Targets

- **Platform:** macOS 15+, Apple Silicon. Features that need macOS 26 APIs (for example `SpeechAnalyzer`) are runtime-gated with a fallback.
- **Capture resolution:** native display pixels (Retina). 1080p is never the master.
- **Output resolutions:** 1080p, 1440p, 3K (2880x1620), 4K, plus custom. 8K appears only if the probe passes.
- **Frame rates:** capture = min(requested, display refresh). Output = 24 / 30 / 60 / 120 / 144 / 240.
- **Canvas aspects:** 16:9, 16:10, 4:3, 5:4, 3:2, 1:1, 4:5, 9:16, 21:9, custom `w:h`.

### 3.3 Frame-rate truth table (build the UI around this)

| Item | Rule |
|---|---|
| Capture 60 | Any supported Mac. |
| Capture 120 | ProMotion or 120 Hz display. |
| Capture 144 | Only with a 144 Hz external display. |
| Capture 200+ | Not capturable: the display never draws those frames. |
| Output 120 / 144 / 240 | Allowed. Camera, cursor, zoom, 3D, layout, and motion blur render at the true output rate. Source screen content repeats between source frames (sample-and-hold). |
| Output 8K | Only if the probe passes; at most 60 fps; motion-blur samples capped. |
| Valid combos | Resolution x fps x codec x alpha combos are validated by the encoder probe (section 14.2). Only valid combos are selectable. |
| Non-Retina displays | Zoom beyond 1x interpolates. The UI recommends a scaled HiDPI mode and, when the upscaler ships, offers it (section 12.5). |

---

## 4. System architecture: "Record Raw, Derive, Render Pure"

### 4.1 The five rules

1. **Record raw.** Capture never applies effects. It writes screen video (native res), per-source audio journals, webcam, and a timestamped input-event log. Capture stays cheap and cannot drop frames because of effects.
2. **Analyze once, cache by hash.** Heavy sensors (speech, face, person mask, OCR, pixel activity) run in the background and write plain value data to `cache/analysis/`, keyed by `hash(media fingerprint, analyzerID, analyzerVersion, params)`. They never re-run unless the key changes.
3. **Derive.** A pure, deterministic `Director` turns `(Project intent + analysis results + events)` into an immutable `Timeline` snapshot: time map, zoom plan, camera path (with tilt), cursor track, layout track, webcam placement, mask tracks, caption frames, audio plan. Same input, same output.
4. **Render pure.** `render(outputTime t, Timeline, sources, options) -> frame` is a pure function. Preview and export call the **same** renderer.
5. **One command bus.** All mutation flows through `Command -> reduce(&Project) -> Effects`. Effects name which derived tracks to invalidate (section 4.6).

### 4.2 System diagram

```
RECORD (real time, raw only, minimal CPU)
  CaptureEngine (SCK | iOS device) ──► screen.mov + frames.meta
  InputRecorder (event tap + AX)   ──► events.bin, cursors.json, ax.json
  AudioJournals (N sources)        ──► *.pcm ──► *.caf (wrapped at stop / recovery)
  WebcamRecorder (AVCapture)       ──► webcam.mov (fragmented)
          │
          ▼
PROJECT BUNDLE  (.lumen: immutable media + project.json = user intent only)
          │
          ▼
ANALYZE (background, QoS .utility, cancellable, cached by content hash)
  VAD+levels · Transcript · FaceTrack · PersonMask · SensitiveText(OCR) · PixelActivity
          │   plain value results (no Apple types cross this line)
          ▼
DIRECTOR (pure, deterministic, off-main, versioned)
  TimeMap · Cursor · ZoomPlan · Camera(+tilt) · Layout · WebcamPlacement
  Masks · Emphasis · Captions · AudioPlan
          │   immutable Timeline snapshot (atomic reference swap)
          ▼
  ┌──────────────────────┬──────────────────────────┬──────────────────────────┐
  ▼                      ▼                          ▼
Preview (CAMetalLayer)  Export (offline loop)     AudioMixer (live | offline)
  └──── same Renderer ───┘                          │
          ▼                                          ▼
  AVAssetWriter: H.264 / HEVC / ProRes (+alpha)      AAC tracks · stems · WAV
```

### 4.3 Command bus

```
 SwiftUI views ──┐
 Global hotkeys ─┤
 lumen-cli ──────┼──► Command ──► reduce(&Project) ──► Effects ──► invalidate ──► Director ──► Timeline
 MCP bridge ─────┤                     │
 App Intents ────┘                     └──► undo stack (Project snapshots)
```

```swift
public enum Command: Codable, Sendable {
    case split(clip: UUID?, at: Double?)         // nil = playhead, resolved at dispatch
    case addZoom(clip: UUID, ZoomSegment), moveZoom(UUID, start: Double, end: Double), deleteZoom(UUID)
    case setStyle(StylePatch), setCursor(CursorPatch), setCamera(CameraPatch)
    case addMask(clip: UUID, Mask), approveMasks([UUID]), applyAutoTidy(AutoTidyScope)
    case setLayout(clip: UUID, LayoutSegment), setCaptionStyle(CaptionStyle)
    case importAsset(URL), addClip(asset: UUID, at: Double?)
    case startRecording(RecordingConfig), stopRecording, pauseRecording, resumeRecording
    case export(ExportRequest)
    // ...one case per user-visible action
}
public func reduce(_ p: inout Project, _ c: Command, ctx: ReduceContext) throws -> Effects
```

Rules: the reducer is pure; `ReduceContext` carries the playhead time and selection **captured at dispatch** (so "cut at playhead" can never read stale pointer state); `Effects` is an `OptionSet` of invalidations.

### 4.4 Ownership and concurrency model

| Component | Isolation | Notes |
|---|---|---|
| `AppModel` (recorder state, project list) | `@MainActor @Observable` | UI source of truth for app state. |
| `EditorModel` (open project, playhead, undo) | `@MainActor @Observable` | Holds the `Project` **value** plus an undo stack of snapshots. Dispatches commands. |
| `RecordingSession` | `actor` | Orchestrates start/pause/resume/stop. Never touches frames. |
| `CaptureEngine` | final class + private serial queue | Receives SCK buffers on that queue and appends straight to `AVAssetWriterInput`. No actor hop per frame. Reports via `AsyncStream`. |
| `AudioJournal` (one per source) | final class + serial queue | Appends raw PCM; never blocks capture. |
| `InputRecorder` | dedicated high-QoS thread with `CFRunLoop` | Single-producer ring buffer; writer queue flushes to disk. |
| `AnalysisService` | `actor` | Schedules cancellable analyzer jobs; results are values. |
| `Director` | `actor` (compute on detached tasks) | Debounced, cancellable, versioned (`TimelineRevision`). |
| `ControlServer` | `actor` | Local socket; translates RPC to `Command`; enforces consent policy. |
| `Renderer` | final class owned by one render queue | Metal objects built once. Triple-buffered in-flight frames. |
| `AudioMixer` | `AVAudioEngine` live graph; separate offline engine for export | Schedules from `Timeline.audio`. |

**Snapshot handoff:** the editor publishes an immutable `Timeline` to the renderer through a single atomic reference swap (`OSAllocatedUnfairLock` guarding a reference). The render thread reads it once per frame. The UI never mutates what the renderer reads.

**Undo:** `Project` is a value type, so undo/redo is a stack of snapshots. Commands that only change derived data (none should) do not enter the stack.

### 4.5 Time and coordinate domains (convert only at boundaries)

| Domain | Unit | Used by |
|---|---|---|
| Host time | mach ticks | Capture only. Converted once to source time. |
| Source time | seconds, clip-local media time | Events, masks, zoom, captions, loupes, taps, layout segments. |
| Output time | seconds, composition time | Camera springs, layout springs, soundtrack lanes, export frame times. |
| Source space | source pixels, top-left origin | Cursor, masks, AX frames, loupe/highlight regions. |
| View space | normalized within the camera view | Camera dead-zone, pan solver. |
| Canvas space | normalized 0..1 of the output canvas, top-left | Layout rects, webcam, captions. |

### 4.6 Invalidation matrix (what recomputes when something changes)

| Change | TimeMap | Cursor | Zoom plan | Camera | Layout | Webcam | Masks | Captions | Audio plan | Backdrop |
|---|---|---|---|---|---|---|---|---|---|---|
| Style: bg / shadow / border | | | | | | | | | | ● |
| Style: padding / radii | | | ● (viewport aspect) | ● | ● | ● | | ● | | ● |
| Canvas aspect | | | ● | ● | ● | ● | | ● | | ● |
| Cursor params | | ● | | ● (lookahead target) | | ● | | | ● (click SFX) | |
| Zoom params / preset | | | ● | ● | | | | | ● (whoosh) | |
| Camera params | | | | ● | | | | | | |
| Cuts / ramps / clips / transcript edits | ● | | ● (map) | ● | ● | ● | | ● | ● | |
| Layout segments / settings | | | ● | ● | ● | ● | | ● | | |
| Mask edit / approve | | | | | | | ● | | | |
| Caption style / text | | | | | | | | ● | | |
| Audio params / lanes | | | | | | | | | ● | |

The matrix is a test: `InvalidationTests` assert that each `Effects` flag recomputes exactly its row and nothing else.

### 4.7 Failure model

| Failure | Guarantee | Mechanism |
|---|---|---|
| App crash or kill -9 mid-record | Everything except the last <= 2 s is recoverable | `movieFragmentInterval` 2 s on video/webcam writers, PCM journals, append-only events, `bundle.state != finalized` triggers recovery on next launch |
| Disk fills | Stop cleanly, finalize what exists, surface the error | Free-space watchdog every 2 s; stop at < 1 GB |
| Display disconnected | Stop or switch per user setting; no corrupt output | SCK stream error handler, finalize writers |
| Permission revoked mid-record | Finalize and warn | Stream error, bundle marked `partial` |
| Audio device unplugged | Other tracks continue; gap flagged | Per-journal failure isolation |
| Thermal critical | Warn at serious; reduce preview quality; never reduce capture quality silently | `thermalState` observer |
| Export interrupted | Resume-safe temp, no half-written final file | Write `*.partial`, atomic rename on success |
| Analyzer fails or is cancelled | Feature degrades with a visible state, never blocks editing | Result optional; UI shows "analyzing" / "unavailable" |
| Project written by a newer app | Open read-only with a notice | `schemaVersion` check |
| Corrupt cache | Self-heal | Verify header and hash; rebuild |
| Sleep / wake during record | Gap marked as a pause | `NSWorkspace` notifications; treated as an implicit pause |

---

## 5. Tech stack (all free, all Apple-native)

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 6, strict concurrency | Safety and speed. |
| UI | SwiftUI + AppKit interop (`NSViewRepresentable` for Metal, `NSPanel` for HUD) | Native feel, menu bar, floating panels. |
| State | Observation (`@Observable`) on `@MainActor`, plus the `Command` reducer | One source of truth, no Combine. |
| Capture | ScreenCaptureKit | Native-res, high-fps, IOSurface frames, system audio. |
| Mobile capture | CoreMediaIO + `AVCaptureSession` external muxed devices | QuickTime-style iPhone/iPad capture over USB (spike 12). |
| Input events | `CGEventTap` (listen-only) + Accessibility (`AXUIElement`) | High-rate cursor, clicks, keys; AX frames. |
| Video IO | AVFoundation, VideoToolbox (probing) | Hardware encode and decode. |
| Rendering | Metal + MetalKit; MetalFX spatial scaler (spike-gated) | GPU compositing, blur, resampling. |
| Zero-copy | `CVMetalTextureCache`, IOSurface-backed pixel buffers | No CPU copies. |
| Audio | `AVAudioEngine` (live and manual offline rendering), `Accelerate`, RNNoise (C, BSD) | Mixing, DSP, denoise. |
| Vision | face rectangles, person segmentation, text recognition | Face tracking, cutout, sensitive-data detection. |
| Speech | Apple Speech (on-device) + `SpeechAnalyzer` on macOS 26; optional whisper.cpp (MIT) behind `LUMEN_WHISPER` | Transcripts with word timings. |
| Control | Unix domain socket + JSON-RPC 2.0; MCP over stdio via `lumen-mcp` | Agent automation, no dependency. |
| Shortcuts | App Intents (thin adapter over `Command`) | Shortcuts and Spotlight. |
| CLI | `swift-argument-parser` (the only Swift dependency) | Headless verification and render. |
| Shaders | `.metal` in the SwiftPM target, `makeDefaultLibrary(bundle: .module)` | One build system. |
| Build | SwiftPM workspace + thin Xcode app target | Agent-friendly. |

---

## 6. Repository layout and module graph

```
Lumen/
├─ Package.swift
├─ Makefile                         # build, test, verify, bench, demo, quality, recover-test, mcp-test
├─ App/                             # thin Xcode app target: entry, Info.plist, entitlements
├─ Sources/
│  ├─ LumenCore/                    # types, clock, math, springs, DenseTrack, filters. Foundation only.
│  ├─ LumenProject/                 # bundle format, Project/Clip/Command models, schema + migrations, reducer
│  ├─ LumenCapture/                 # SCK, device capture, event tap, audio journals, webcam, writers, permissions
│  ├─ LumenAnalysis/                # Apple-framework sensors → plain values: VAD, speech, face, person mask, OCR, pixel activity
│  ├─ LumenDirector/                # PURE: time map, cursor, zoom, camera, layout, placement, masks, captions, audio plan
│  ├─ LumenRender/                  # Metal renderer, shaders, resamplers, FrameSource
│  ├─ LumenAudio/                   # mixer, DSP chain, SFX synth, music, loudness
│  ├─ LumenExport/                  # export jobs, recipes, capability probe, layers, alpha, GIF, share-safe bundle
│  ├─ LumenControl/                 # ControlAPI: command bus server, consent policy, App Intents adapter
│  ├─ LumenShare/                   # OPTIONAL cloud (LUMEN_CLOUD only): ShareProvider implementations
│  ├─ LumenUI/                      # SwiftUI views, editor, timeline, inspector, recorder HUD
│  ├─ LumenCLI/                     # headless: render, analyze, smoothness, sync-check, quality-check, probe
│  └─ LumenMCP/                     # tiny stdio↔socket MCP bridge executable
├─ Tests/                           # per-module unit tests, golden images, synthetic traces
├─ Resources/
│  ├─ Shaders/                      # *.metal
│  ├─ Cursors/                      # vector cursor packs (+ manifest.json format)
│  ├─ Gradients/                    # curated presets, 30 procedural wallpapers
│  ├─ DeviceFrames/                 # our own generic phone/tablet vector frames (no Apple artwork)
│  ├─ Music/                        # CC0 only + licenses.json
│  └─ Fixtures/                     # sample recordings, event traces, OCR/PII synthetic corpus
├─ Docs/                            # Spikes.md, Decisions.md, Benchmarks.md
└─ Tools/                           # SFX synth, license check, golden update, share-worker/ (reference)
```

### 6.1 Dependency rules (enforced in `Package.swift`)

```
LumenCore      ← (nothing)
LumenProject   ← Core
LumenDirector  ← Core, Project            # NO Apple media frameworks. Pure.
LumenCapture   ← Core, Project
LumenAnalysis  ← Core, Project            # Vision/Speech/AVFoundation live here, emit plain values
LumenRender    ← Core, Project, Director (types only)
LumenAudio     ← Core, Project, Director (types only)
LumenExport    ← Core, Project, Director, Render, Audio
LumenControl   ← Core, Project, Director, Export   (no UI, no Capture types in its API)
LumenShare     ← Core, Project, Export    # only target allowed to import networking
LumenUI        ← all of the above except LumenMCP
LumenCLI       ← Project, Director, Analysis, Render, Audio, Export
LumenMCP       ← Core                     # speaks only JSON over a socket
```

`LumenDirector` imports no AVFoundation, Metal, Vision, Speech, or AppKit. Analysis results cross into it as plain structs (`[WordToken]`, `[OCRBox]`, `[FaceSample]`, `[Interval]`).

---

## 7. Core data model

### 7.1 Clock

All timestamps are `Double` seconds from the **host-time clock**, so screen frames, events, and every audio source share one timeline.

```swift
public struct RecordingClock: Sendable {
    public let originHostTime: UInt64            // mach host time at first video frame
    public var pausedTotal: Double               // seconds excluded by pauses
    public func seconds(fromHostTime t: UInt64) -> Double      // subtracts pausedTotal
    public func seconds(fromPTS pts: CMTime) -> Double         // SCK/AVCapture PTS on host clock
}
```

Calibration: do **not** assume `CGEvent.timestamp` units. At startup, sample `CGEvent.timestamp`, `mach_absolute_time()`, and `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` together and derive the conversion. Test: event/frame alignment within 1 ms.

### 7.2 Input event record (`events.bin`)

Fixed-size binary records, versioned header, append-only (crash-safe; count derived from file size).

```swift
public struct InputEvent: Sendable {          // 32 bytes, little-endian
    public var t: Double                      // source seconds
    public var kind: Kind                     // move, down, up, drag, scroll, keyDown, keyUp, flagsChanged, pause, resume
    public var x: Float, y: Float             // source pixels, top-left origin, already converted
    public var button: UInt8
    public var keyCode: UInt16
    public var flags: UInt16
    public var cursorShape: UInt16            // index into cursor catalog
    public var axFrameIndex: UInt32           // 0 = none; index into ax.json
}
```

Coordinates are converted **once at capture** (AppKit bottom-left to top-left; points to pixels by backing scale). Key events store key codes and modifiers only, never characters.

### 7.3 `frames.meta` (per source frame)

`pts`, SCK `status`, `contentRect` (window/region modes), `dirtyUnion` (bounding rect of SCK dirty rects, used to drive OCR and pixel activity cheaply), and pause markers. Compact binary, append-only.

### 7.4 Project bundle (`.lumen` package directory)

```
MyDemo.lumen/
├─ project.json        # schemaVersion, bundle.state, assets, USER INTENT only
├─ screen.mov          # HEVC master, native res, fragmented, keyframe <= 0.5 s
├─ frames.meta
├─ events.bin
├─ cursors.json        # catalog + captured custom cursor bitmaps/hotspots
├─ ax.json             # optional focused-element frames
├─ audio/
│   ├─ <sourceId>.caf  # Float32 PCM; native sample rate recorded, resampled to 48 kHz at wrap
│   └─ <sourceId>.json # role (mic|system|virtual), device name, latency offset, gain trim
├─ webcam.mov          # fragmented
├─ imports/            # imported video / audio / image assets (copied, immutable)
├─ cache/
│   ├─ analysis/       # <analyzerID>-<hash>.bin  (never raw OCR text; see 9.2)
│   └─ derived/        # memory-mappable 1440 Hz track pages, safe to delete
└─ thumbs/
```

**Rule:** media is immutable. `project.json` holds only user intent. Everything derived is recomputed or cached.

### 7.5 `Project` (persisted intent, value type, undo unit)

```swift
public struct Project: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var assets: [Asset]                  // recordings + imports; immutable media refs
    public var clips: [Clip]                    // main video lane, ordered, gapless
    public var style: Style
    public var cursor: CursorStyle
    public var camera: CameraParams             // preset + spring/dead-zone/lookahead/tilt params
    public var zoomParams: ZoomParams           // planner knobs (section 10.3)
    public var layoutSettings: [LayoutKind: LayoutSettings]   // per-layout camera size/pos/shape
    public var captions: CaptionPlan
    public var audio: AudioPlan                 // lanes, modes, music, SFX, targets
    public var loop: LoopMode                   // off | cursorAndCamera(duration)
    public var exportIntent: ExportIntent
}

public struct Clip: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var asset: AssetID
    public var srcRange: ClosedRange<Double>    // trim, source seconds
    public var cuts: [CutRange]                 // removed spans: manual | autoTidy, source seconds
    public var ramps: [SpeedRamp]               // source-time spans: auto | manual
    public var zoom: [ZoomSegment]              // source time
    public var layouts: [LayoutSegment]         // source time; default = one segment
    public var overlays: Overlays               // source time + source space
    public var transitionIn: Transition        // .cut | .dissolve(0.3)
}

public struct Overlays: Codable, Sendable, Equatable {
    public var masks: [Mask]                    // blur | pixelate | solid | blend; keyed rect tracks in source px
    public var highlights: [Highlight]
    public var loupes: [Loupe]
    public var taps: [TapIndicator]             // manual click/tap circles
    public var texts: [TextBlock]               // manual subtitles / titles
}

public enum Provenance: Codable, Sendable, Equatable { case auto, manual }   // replan replaces .auto only

public struct ZoomSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var start: Double, end: Double       // SOURCE seconds (clip-local)
    public var scale: Double                    // >= 1
    public var focus: Focus                     // .follow | .fixed(source-normalized point) | .element(Rect)
    public var easing: ZoomEasing?              // nil = project camera preset
    public var origin: Provenance
}

public struct Style: Codable, Sendable, Equatable {
    public var canvas: CanvasSpec               // aspect preset or custom w:h, size policy
    public var background: Background           // gradient | mesh | solid | image | blurredContent, + grain
    public var padding: EdgeInsets              // per-side, fraction of canvas short side
    public var cornerRadii: CornerRadii         // per-corner (tl, tr, br, bl), points
    public var shadow: ShadowStyle              // two-layer
    public var border: BorderStyle?
    public var zoomBackgroundBlur: Bool         // default false
}
```

### 7.6 Time anchoring rules

| Object | Time anchor | Space anchor |
|---|---|---|
| Zoom, layout segments, loupes, highlights, taps, masks, caption/text blocks | source time (clip-local) | source space (masks, loupes, highlights, taps) or canvas (text) |
| Cuts, ramps, trims | source time | n/a |
| Music, voice-over lanes, SFX overrides | output time | n/a |
| Camera, layout spring state, webcam placement | output time (derived only) | view / canvas |

Why: a cut earlier in the video must never desync a mask or zoom. Split commands partition anchored objects between the two resulting clips and clamp them.

### 7.7 `Timeline` (derived, immutable snapshot) and `FrameState`

```swift
public struct Timeline: Sendable {
    public let revision: TimelineRevision
    public let timeMap: TimeMap
    public let tracks: DerivedTracks            // DenseTrack<V> pages @ 1440 Hz (mmap) + sparse event tracks
    public let project: Project                 // the intent it was derived from
    public func evaluate(at outputTime: Double) -> FrameState    // pure, ~microseconds
}

public struct FrameState: Sendable {
    public var clip: ClipIndex
    public var sourceTime: Double
    public var camera: CameraPose               // center (source px), scale, tilt (pitch, yaw, roll)
    public var layout: ResolvedLayout           // interpolated (section 10.5)
    public var cursor: CursorSample             // position, velocity, opacity, press, shape
    public var clickFX: [ClickFX]
    public var taps: [TapFX]
    public var webcam: WebcamState?
    public var masks: [MaskRect]                // source px, current frame
    public var highlights: [HighlightState]
    public var loupes: [LoupeState]
    public var caption: CaptionFrame?
    public var crossfade: Crossfade?            // from/to clip + alpha during dissolve
}

public struct DenseTrack<V: Interpolatable>: Sendable { /* fixed-rate pages, Hermite or linear, mmap-backed */ }
```

Internal sample grid: **1440 Hz**, an exact multiple of 24, 30, 48, 60, 120, 144, 240. Pages of 60 s are memory-mapped, so a 60-minute project never holds the full track resident.

### 7.8 Schema versioning

- `schemaVersion` is bumped on any change to persisted fields. Each bump ships a pure migration function with a fixture test (`MigrationTests`).
- Unknown fields are preserved on round trip (decode into a side dictionary), so older apps do not destroy newer data.

---

## 8. Capture subsystem (`LumenCapture`)

### 8.1 Video

- `SCStream` with an `SCContentFilter` for display, window, or region (`sourceRect`). Exclude the app's own windows via `excludingWindows`.
- Configuration: `width/height` = display points x `backingScaleFactor`; `captureResolution = .best`; `pixelFormat = 32BGRA`; `colorSpaceName = displayP3`; `minimumFrameInterval = 1 / min(requestedFPS, NSScreen.maximumFramesPerSecond)`; `queueDepth = 6...8`; `showsCursor = false`; `scalesToFit = false`.
- Frame handling on the SCK sample queue: validate `SCStreamFrameInfo.status == .complete`, append the IOSurface-backed `CVPixelBuffer` through `AVAssetWriterInputPixelBufferAdaptor`. If the input is not ready, drop and count. Never block.
- Persist per-frame `pts`, `status`, `contentRect`, and `dirtyUnion` into `frames.meta`.

### 8.2 Master encode and crash safety

- HEVC hardware, B-frames off, keyframe interval <= 0.5 s, bitrate about `pixels x fps x 0.12` bps (capped), Main profile, Display P3 tags.
- **Fragmented MOV:** set `AVAssetWriter.movieFragmentInterval` (about 2 s) so a crash leaves a playable file up to the last fragment. Same for `webcam.mov`.
- **Audio journals:** each source appends raw Float32 PCM to `audio/<id>.pcm` (native sample rate recorded in `<id>.json`). At stop (or recovery) the journal is resampled to 48 kHz and wrapped into CAF. This avoids relying on a writer finalizing its header after a crash.
- **Events:** append-only fixed records; flush every 250 ms; `fsync` every 2 s.
- **Recovery:** on launch, any bundle with `state != finalized` runs `BundleRecovery`: rebuild `frames.meta` from fragment PTS, truncate `events.bin` to the last whole record, wrap journals, mark `recovered`. Phase 13 includes a kill -9 test.

> Fast-path spike: `SCRecordingOutput` (macOS 15+) records straight to file with zero per-frame code. Use it for the very first prototype. `AVAssetWriter` stays the production path for bitrate, keyframe, and fragment control.

### 8.3 Pause and resume

- One writer per source stays open. On pause: stop appending, record a pause marker in `frames.meta` and `events.bin`, accumulate `pausedTotal`.
- On resume: PTS is shifted by the paused duration so media is contiguous. Events during the pause are dropped.
- **Invariant:** cursor smoothing, resampling, click pinning, and camera springs never cross a pause marker or a clip boundary. The cursor jumping at a join makes the camera glide; it never produces a warped cursor path.

### 8.4 Input recording

- `CGEventTap` in listen-only mode for move, drag, button, scroll, key.
- Dedicated `.userInteractive` thread with `CFRunLoop`; preallocated single-producer ring; writer queue appends every 250 ms.
- **Cursor shape:** on movement and at 30 Hz read `NSCursor.currentSystem`; classify by bitmap hash against the stock catalog. Unknown cursor: store bitmap and hotspot in `cursors.json` as a custom cursor.
- **AX probe (optional):** on mouse-down and focus change, query the clicked/focused `AXUIElement` frame; store in `ax.json`.

### 8.5 Audio: multiple independent inputs

```swift
public struct AudioSourceSpec: Codable, Sendable {
    public var deviceID: String
    public var role: Role                  // .mic | .system | .virtual(name)  (e.g. BlackHole)
    public var label: String
    public var latencyOffset: Double       // seconds, calibrated by clap test
}
```

- **System audio:** SCK `capturesAudio = true`, `excludesCurrentProcessAudio = true`.
- **Every microphone and virtual device** (including BlackHole): its own `AVCaptureSession` + `AVCaptureAudioDataOutput` → its own journal, stamped on the host clock. This allows any number of simultaneous inputs. SCK's single-mic path (`captureMicrophone`) is the fallback only if spike 1 shows it is better synchronized.
- Each source is its own track end to end (separate levels, chains, export stems).

### 8.6 Webcam

`AVCaptureSession` → its own fragmented HEVC/H.264 file, 1080p30 default, PTS normalized to the shared clock. Raw only: face tracking, cutout, and framing are analysis plus render concerns.

### 8.7 iPhone / iPad over USB

- Enable screen-capture devices through CoreMediaIO (`kCMIOHardwarePropertyAllowScreenCaptureDevices`), then discover external muxed devices via `AVCaptureDevice.DiscoverySession`.
- `DeviceCaptureEngine` writes the same bundle shape (`screen.mov`, device audio as a source) with `source.kind = .device`, native device resolution, and **no events**.
- No events means no auto zoom from input. Section 9 `PixelActivity` supplies activity points; manual tap indicators supply the click visuals (feature 28). Generic vector device frames are bundled (own artwork, no Apple assets).

### 8.8 Session lifecycle

```swift
actor RecordingSession {
    func prepare(config: RecordingConfig) async throws      // permissions, devices, writers, clock origin
    func start() async throws                               // countdown handled by UI; all engines start together
    func pause() async;  func resume() async
    func stop() async throws -> ProjectBundle               // finalize writers, wrap journals, flush events
}
```

During recording: `ProcessInfo.beginActivity(options: [.userInitiated, .latencyCritical])`, disable idle/display sleep, observe `thermalState`, surface dropped-frame counters in the HUD, run the free-space watchdog.

### 8.9 Permissions (onboarding with live status and deep links)

| Permission | Check |
|---|---|
| Screen Recording | `CGPreflightScreenCaptureAccess` (+ SCK prompt). May need an app relaunch. |
| Microphone / Camera | `AVCaptureDevice.authorizationStatus` / `requestAccess`. |
| Input Monitoring | `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`. |
| Accessibility (optional) | `AXIsProcessTrustedWithOptions`. |
| Speech Recognition (only if the engine requires it) | `SFSpeechRecognizer.requestAuthorization`. |

Evaluate `SCContentSharingPicker` for source selection; it may reduce recurring prompts (spike 6).

---

## 9. Analysis layer (`LumenAnalysis`)

Apple-framework sensors. Each reads media, writes a plain value result to `cache/analysis/`, and never calls back into the UI.

### 9.1 Analyzers

| Analyzer | Input | Output | Engine | Cost target | Runs |
|---|---|---|---|---|---|
| **VAD + levels** | audio sources | speech regions, RMS envelope @ 100 Hz, waveform peak pyramid | Accelerate, own energy + hysteresis VAD | >= 100x realtime | at stop |
| **Transcript** | denoised mic | `Transcript` (words with start/end, confidence) | `TranscriptionEngine` | >= 1x realtime, background | after stop if captions/transcript enabled, or on demand |
| **Face track** | `webcam.mov` | face rect @ 15 Hz | Vision face rectangles | >= 4x realtime | at stop if webcam exists |
| **Person mask** | `webcam.mov` | `cutout.mov`: 8-bit mask <= 720p at webcam fps, temporally smoothed | Vision person segmentation (`.accurate`) | >= 1x realtime at 30 fps (spike 10) | first time a cutout layout is used |
| **Sensitive text** | `screen.mov` + `dirtyUnion` | detections: category, rect, time, salted hash | Vision text recognition + `SensitivePatterns` | >= 1x realtime on a typical demo | after stop, background |
| **Pixel activity** | `screen.mov` (device/imported) | activity points @ 10 Hz (centroid of changed pixels) | Metal frame diff on a downsampled copy | >= 20x realtime | on import / device capture |

### 9.2 Cache design

- `AnalysisKey = hash(mediaFingerprint, analyzerID, analyzerVersion, canonicalParams)`. A key hit means no work.
- Jobs are cancellable, resumable (chunked by time), and run at `.utility`. An edit never waits on an analyzer; the UI shows "analyzing" until the result lands, then the Director replans.
- **Privacy rule:** the sensitive-text cache stores category, rect, time, and a salted hash of the normalized string. It never stores raw OCR text. `cache/` is excluded from project sharing by default.
- Per-analyzer `analyzerVersion` bumps invalidate automatically.

### 9.3 Transcription seam

```swift
public protocol TranscriptionEngine: Sendable {
    func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript
}
```

- `AppleSpeechEngine`: on-device only (`requiresOnDeviceRecognition`), `SpeechAnalyzer` on macOS 26 when available. Pass **custom vocabulary** (product names, API names) from the project; this matters for AI-product demos.
- `WhisperEngine`: optional (`LUMEN_WHISPER`), model supplied by bundle or user import, never downloaded by the app.
- Selection is by measured accuracy on `Resources/Fixtures` (spike 11), not by preference.

---

## 10. Director: the "smart" layer (`LumenDirector`, pure)

Inputs: events, `frames.meta`, AX, analysis results, `Project`. Output: `Timeline`. No Apple media frameworks.

### 10.1 Time map and composition (build first)

Operations, applied in this order: **clips (concatenate) → trims → cuts → speed ramps**.

```swift
public struct TimeMap: Sendable {
    public func source(atOutput t: Double) -> (clip: Int, t: Double)
    public func output(atSource t: Double, clip: Int) -> Double?     // nil if inside a cut
    public var epochs: [Range<Double>]                               // camera reset boundaries = clip boundaries
}
```

- Piecewise-linear with smooth speed ramps (smoothstep over 0.5 s; time map is the numerical integral). Cuts remove source spans; clip boundaries concatenate.
- **Auto speed ramps:** propose where there is no input event for >= 2.0 s **and** no speech (VAD inactive). Speed is `min(8x, spanDuration / 0.8 s)`. Mic is muted in ramps by default. Editable and deletable.
- **Order of operations (critical):** apply the time map before camera solving. Camera and layout springs run in **output time**, so a sped-up span never makes a camera move jarringly fast. Cursor smoothing runs in source time and resamples into output time.
- **Epochs:** camera and layout state **reset at clip boundaries** (a new clip may be unrelated content). Cuts *inside* a clip do not reset, so the camera glides across a jump cut instead of snapping.
- Dissolve transitions overlap the two clips' output ranges by the dissolve duration; the renderer receives two sources for those frames.
- Every cut edge snaps to the nearest low-energy point within +/-40 ms and is crossfaded 40 ms in audio (no clicks).

### 10.2 Cursor pipeline

1. Ingest raw samples `(t, x, y)`; enforce monotonic `t`, dedupe equal timestamps. **Segment at pause markers and clip boundaries.**
2. Classify movements vs dwells (dwell = speed < 25 pt/s for >= 120 ms).
3. Resample onto the uniform 1440 Hz grid with monotone cubic (PCHIP): no overshoot.
4. De-spike with a 5-sample median filter.
5. **Non-causal Gaussian smoothing** (`sigma = cursor.smoothingSigma`, default 35 ms, range 0 to 120). Zero lag.
6. **Click pinning:** at every click/drag event force the smoothed position to equal the true position within 0.5 px via a short-decay correction spline.
7. **Glide retiming (`glide` default 0.35):** per movement, reparametrize arc length with the minimum-jerk profile `s(tau) = L * (10 tau^3 - 15 tau^4 + 6 tau^5)`, keep start/end timestamps, blend `lerp(humanSmoothed, minJerk, glide)`.
8. **Idle hide:** opacity track. Fade out after 2.0 s idle over 0.4 s; fade in at next movement over 0.15 s.
9. **Click FX:** press scale `1 -> 0.86` (critically damped spring back), ring ripple 0.45 s, timed to down/up events.
10. **Manual taps:** `TapIndicator` entries (time, source position, style) produce the same press/ripple FX. They exist for iPhone/iPad and UIs that cannot be instrumented.
11. **Loop mode (`LoopMode.cursorAndCamera(d)`):** over the final `d` seconds (default 1.2) retime the cursor with a minimum-jerk blend back to its first-frame position, and bias the camera target back to the first-frame camera state. Content does not loop; cursor and camera converge so a short clip repeats seamlessly (GIF).
12. **Size:** `size = base x zoom^(1 - k)`. `k = 1` means constant on-screen size (the "Constant size" toggle). The sprite is vector, rasterized per size bucket, so it is never pixelated.
13. Output: dense `CursorTrack` at 1440 Hz (position, velocity, opacity, press, shape id).

### 10.3 Zoom planner

Works in source time per clip, outputs `[ZoomSegment]` (source time) tagged `.auto`.

1. **Activity points:** clicks (weight `clickWeight`, default 3), drags (3), typing bursts (2, located at the last click or AX focused element), scroll (1). Pixel-activity points (weight 1) for clips without events (device/import). Cursor travel counts **only** if it is purposeful: path length > `wiggleRadius` within 400 ms **and** it ends in a dwell >= 200 ms. `zoom.sensitivity` (0..1) maps `wiggleRadius = lerp(120 px, 12 px, sensitivity)`. Idle wiggle creates nothing.
2. **Cluster:** merge points within `mergeGap` (2.5 s) and within 35% of the viewport diagonal.
3. **Focus box:** union of point locations (or AX element frames) + 12% padding.
4. **Viewport-aware scale:** `viewport` is the content rect's aspect inside the **current layout and canvas** (not just the source aspect). `scale = clamp(0.8 * min(viewW/boxW, viewH/boxH), minScale, maxScale)`, quantized to 0.1. If the raw scale < `minTrigger`, skip the cluster.
5. **Focus mode:** if the whole cluster fits inside the zoomed view with margin, use `.fixed(box center)` (stable, no wander). Otherwise `.follow`.
6. **Lead-in:** start `leadIn` (0.45 s) before the first event.
7. **Hold and tail:** hold while the next activity is within 2.0 s; end `tail` (0.7 s) after the last event.
8. **Pan-through:** if the next cluster starts within `panThroughGap` (1.5 s), do not zoom out; pan directly (rescale if needed).
9. **Rate limits:** minimum hold 1.0 s; minimum gap between zoom-out and next zoom-in 0.6 s; otherwise merge.
10. **Presets:** Subtle (max 1.6), Balanced (2.2), Dramatic (3.0), **Cinematic** (max 2.6, leadIn 0.9, tail 1.1, `omegaPan` 4.5, `omegaZoom` 4.0, shutter 0.6, 3D Lean on), Fixed (always N x).
11. **Re-aim:** changing canvas aspect, padding, or layout replans `.auto` segments automatically with the new viewport. `.manual` segments are preserved.
12. **Centering offset:** `camera.centerOffset` (view-normalized) biases where the cursor sits in the zoomed view (for example, leave room for a webcam or captions).

### 10.4 Camera solver (the smoothness engine)

Implemented in `Sources/LumenDirector/Camera.swift` (`CameraSolver.solve`). State: `pan` in view-normalized space, zoom solved in **log space** (equal perceived zoom speed), plus tilt `(pitch, yaw)` (section 10.4.1). Output centre is `0.5 + pan · margin(z)` with `margin(z) = 0.5 - 0.5·exp(-log z)`, so pan is uniform on screen at every zoom.

**Target signal:**
- `z*(t)` from zoom segments (1.0 outside), converted to output time through the `TimeMap`.
- `.fixed` / `.element` focus give a point target. `.element` centres the AX rect.
- `.follow` (typing scenes) uses the caret path: cursor samples pass through a **two-pass dead-zone** (`centredPlay`, half-zone `deadZone/2`) and then a **zero-phase Gaussian** (`zeroPhaseSmooth`, `omega = 1/followDelay`). Zero phase means it neither lags nor overshoots, so there is no lookahead term and no follow delay to hide wiggles with.
- `centerOffset` is applied last, in log scale. The target is clamped so the view stays inside the source.

**Filter: one quintic move per segment, per channel** (log zoom, pan x, pan y). `QuinticMove` is a degree-5 Hermite with position, velocity and acceleration at both ends, so C2 holds across a handoff:

- Entrance start = the displayed trajectory at the handoff, not a stale channel value.
- A follow path hands over with its own velocity and acceleration (`v/margin`, `a/margin`), so the pan never stops between the entrance move and the caret path.
- Durations: **zoom-in 550 ms, zoom-out 750 ms, same-scale reframe 350 ms**, divided by the segment's easing and multiplied by a modest distance term (`1 + 0.18·panDistance`, capped at 1.5), clamped to 220–950 ms. Auto shots start `leadIn` earlier so the camera arrives *on* the click. Moves never overlap (one grid step apart).
- One zoom-out per scene, skipped when the next scene already begins at or before this scene ends: staying zoomed across a related action beats a flash to full frame.

**Published derivatives.** The track stores `nx, ny, lz` plus `vx, vy, vz` and `ax, ay, az` at 240 Hz, differentiated through the `centre = 0.5 + pan·margin(z)` product (including the `dv = pan·margin'(z)·ż` cross terms) and zeroed on a clamped axis. `Timeline.evaluate` interpolates with the same quintic Hermite (`qhm`), so acceleration is continuous across sample boundaries — the old zero-acceleration reconstruction stepped the acceleration 240 times a second and read as robotic.

The smoothness suite (`MotionTraceTests`) is the gate: no position step, hi-frequency energy above 8 Hz in log-zoom < 1 %, bounded pan jerk, published acceleration non-zero on an axis that moves, and no tick-boundary acceleration step when sampled at 4× the grid.

#### 10.4.1 3D camera moves (T2, deterministic, no 3D engine)

The content quad is drawn through one perspective homography with pivot at the content-rect center. Three presets, all driven from the camera solver:

| Preset | Behavior | Limits |
|---|---|---|
| **Lean** | `yaw ∝ horizontal camera velocity`, `pitch ∝ vertical camera velocity`; the frame leans into moves, then settles | <= 8 deg yaw, <= 6 deg pitch |
| **Float** | Slow idle drift from summed low-frequency sinusoids, phases seeded by project id | <= 1.5 deg |
| **Reveal** | Entrance: starts at yaw 12 deg, scale 0.92, settles over 0.9 s | once per clip start |

Tilt passes through its own critically damped spring (`omegaTilt` 5). Perspective distance is fixed (3 canvas heights). All limits are verified by the smoothness suite.

### 10.5 Layout solver and transitions

```swift
public enum LayoutKind: Codable, Hashable, Sendable { case screenOnly, cameraOverlay, split, cameraFullscreen, cameraCutout }

public struct ResolvedLayout: Sendable, Interpolatable {      // canvas-normalized
    var screenRect: Rect;  var screenOpacity: Float
    var cameraRect: Rect;  var cameraCornerRadius: Float      // circle = radius 0.5
    var cameraOpacity: Float
    var cutoutBlend: Float                                    // 0 = framed video, 1 = person cutout
    var cameraCrop: Rect                                      // face-aware crop within the webcam frame
}
```

- Each `LayoutKind` plus its `LayoutSettings` and the canvas aspect resolves to a `ResolvedLayout` target. **Transitions are one critically damped spring** (`layout.omega` 9) on the `ResolvedLayout` fields. No per-pair transition code. This is how five layouts and any aspect stay O(1).
- **Per-layout settings:** camera size, anchor, shape, mirror, border, shadow are stored per `LayoutKind` (feature 37), not globally.
- **Auto re-aim by aspect:** `LayoutResolver(aspect)` rules: 16:9 overlay uses corner bubbles; 9:16 `split` stacks screen over camera; 1:1 shrinks bubble; etc. Content fit mode is `.fit` (letterbox inside padding) or `.fillFollow` (content fills the canvas rect and the camera crops by following the cursor; default for 9:16).
- Layout segments are per clip, source-time anchored; default is one `screenOnly` or `cameraOverlay` segment.

### 10.6 Webcam placement solver (smart framing and auto-hide)

One solver covers smart framing, "mouse behind the face", and hide-during-silence.

- **Anchors:** four corners (and edge midpoints when `cameraOverlay` allows). Cost per anchor over a look-ahead window: overlap with the cursor (plus `avoidMargin` 48 px), overlap with the current zoom focus box, overlap with caption rect, switching penalty.
- **Hysteresis:** switch only when the best anchor beats the current by a margin and the current has been bad for >= `snapDwell` (1.5 s). Moves are spring-animated through `ResolvedLayout`.
- **Behind-the-face mode (`.move | .hide | .fade`):** if the cursor enters the bubble rect (or the tracked face rect inflated by `avoidMargin`), apply the selected mode with 0.25 s attack and 0.6 s release.
- **Hide during silence:** a visibility track from VAD (`webcam.hideOnSilence`): hide after 0.6 s of silence, show on speech with 0.2 s attack. Never fully hidden while the cursor is idle but the voice is active.
- **Face-aware crop:** face center/size from the face track runs through the same spring solver (`omegaFace` 3.5) so the crop never jitters.

### 10.7 Emphasis tracks (loupe, highlight)

- `Loupe`: center (source px or follow-cursor with its own spring), canvas radius, magnification 1.5x to 4x, shape (circle / rounded), appear/disappear envelope. Anchored in source time.
- `Highlight`: source-space rect, style (`dim` outside 0 to 70%, `outline`, `glow`), animated in/out. Stays locked to content because it is source-space.
- Both are sampled into `FrameState` as `LoupeState` / `HighlightState` with eased envelopes.

### 10.8 Privacy mask track builder (pure)

Input: `[OCRDetection]` (category, rect, time, salted hash), plus manual masks. Output: `[Mask]` tracks.

1. **Pattern classification** (`SensitivePatterns`, pure and unit-tested): email; phone (E.164 and common national formats); card numbers with Luhn; API keys and tokens (prefix families such as `sk-`, `sk-ant-`, `AKIA[0-9A-Z]{16}`, `ghp_`, `xox[bap]-`, `AIza`); JWT (three base64url parts); `-----BEGIN` blocks; `KEY=value` env lines; any token >= 20 chars with Shannon entropy > 3.5 bits/char. Locale and custom regex list are project settings.
2. **Track building:** group detections by salted hash and spatial continuity into tracks; interpolate rects linearly between detections; bridge gaps <= 0.5 s; extend each track by +/-0.25 s and pad the rect by `mask.padding` (6 px, source space). When content scrolls, detections follow it because OCR is change-driven (`dirtyUnion`), at 1 Hz minimum and up to 4 Hz while content changes.
3. **Defaults:** high-confidence categories (API keys, tokens, private keys) are auto-applied (`.auto`, `approved = true`); lower-confidence categories (phone, generic entropy) are proposed (`approved = false`) and shown in a Privacy review panel before first export.
4. **Modes:** blur (radius >= 0.6 x box height so text is unrecoverable), pixelate, solid, blend (blur plus sampled surrounding color for a natural look).
5. **Space:** masks live in **source space and source time**, so zoom, pan, 3D, aspect, and layout changes never expose them.

### 10.9 Transcript operations, filler and pause removal (pure)

- `Transcript { words: [Word{text, start, end, confidence}] }`. Edits are non-destructive: `deletedWordRanges` in the project, mapped to `CutRange` (source time) with +/-40 ms silence-snap.
- **Text corrections** change caption text only; they never change timing or audio.
- **Filler detection:** per-locale lexicon (default: um, uh, er, erm, hmm; ambiguous words like "like" are opt-in). Produces *suggested* cuts.
- **Pause shortening:** between words, a gap > `pause.max` (0.6 s) is shortened to `pause.keep` (0.25 s) by cutting its middle, but **only** if the span has no input activity (otherwise silence during an action is meaningful). Idle spans >= 2 s with no speech belong to speed ramps (10.1), not cuts; the two rules never overlap.
- One-click **Auto-tidy** applies all suggestions as `.auto` cuts (reversible). Cuts are crossfaded 40 ms.

### 10.10 Caption planner (pure)

- **Chunking:** greedy fill by `maxCharsPerLine` (aspect-adaptive: about 42 at 16:9, about 24 at 9:16) and `maxLines` (2); break at punctuation and pauses > 0.3 s; chunk duration clamped to 0.9 to 4.0 s; no overlaps.
- **Positioning:** default bottom safe area; in 9:16 reserve the bottom 14% for platform UI; if the webcam occupies the bottom, flip to the opposite edge; avoid the loupe and the active zoom focus box.
- **Word highlight:** per-word timings drive a karaoke reveal; `captions.wordHighlight` toggles it off for accessibility.
- **Manual text blocks** (`TextBlock`) share the same renderer and positioning with explicit canvas position and style.
- Captions follow the TimeMap: a cut removes the words it covers, and chunks re-time deterministically.

### 10.11 Audio plan

Derived from the final timeline: click SFX cues, zoom whoosh cues, optional keystroke cues, voice-activity regions per mic, music placement and fades, duck envelope, ramp-mute spans, lane placements, and the **keystroke declick windows** (section 13.1). Voice-over variants (alternate lane sets) are separate plans selected at export.

---

## 11. Hyper-smooth motion specification

This is a hard requirement. Every rule has a test.

1. **Time-based evaluation only.** Everything is a function of continuous time. Never advance state per frame.
2. **Native-resolution master** plus high-quality resampling (section 12.4). Soft zoom looks cheap no matter how smooth the motion.
3. **C2-continuous camera** via cascaded critically damped springs.
4. **Log-space zoom, view-space pan.**
5. **Offline lookahead:** zoom lead-in, cursor-lookahead camera target.
6. **Dead-zone hysteresis plus follow delay** on pan.
7. **Non-causal cursor smoothing, minimum-jerk glide, pinned clicks.**
8. **Sub-frame motion blur** at a 180-degree shutter for camera, cursor, tilt, and layout moves (section 12.9).
9. **Sub-pixel placement:** float math end to end, no pixel snapping, premultiplied alpha, `rgba16Float` intermediates, dither at the final 8/10-bit conversion.
10. **Preview frame pacing:** drive from the display link's `targetTimestamp`, triple buffering, `displaySyncEnabled = true`, never block main. Dropped frames are skipped by time, not delayed.
11. **Output rate independent of capture rate:** tracks are dense at 1440 Hz.
12. **Hard caps:** max camera velocity, acceleration, jerk (from omega and zoom change); max tilt; max layout speed; all test-verified.
13. **Layout, webcam, loupe, and tilt** use the same spring family and the same continuity tests.

### 11.1 Measurable smoothness (`lumen-cli smoothness <project>`)

Sample camera center, log-zoom, tilt, layout rects, webcam position, and cursor (in output pixels) at the output fps and report:

- Max |velocity|, |acceleration|, |jerk| for each.
- **Discontinuity scan:** flag any step in position, velocity, or acceleration larger than 6x the local median absolute deviation (cursor click pins and clip-boundary epochs excluded).
- **Spectral check:** fraction of camera-trajectory energy above 8 Hz must be below 1%.
- Cursor second-difference variance outside dwell/click regions below a tuned threshold.
- **Bounds:** view rect inside source rect for 100% of samples.
- **No-overshoot:** webcam placement and layout springs never exceed their target by more than 1%.

CI fails if any metric regresses against stored baselines.

---

## 12. Render subsystem (`LumenRender`)

### 12.1 Principles

- One `MTLDevice`, one render `MTLCommandQueue`, pipeline states built once at launch.
- Triple-buffered in-flight frames (semaphore = 3). Transient textures from an `MTLHeap`. **No allocations in the frame loop.**
- Working color space Display P3, intermediates `rgba16Float`.
- Source frames arrive as IOSurface-backed `CVPixelBuffer`s mapped through `CVMetalTextureCache` (zero copy).
- `render(t, Timeline, sources, RenderOptions)` is pure. Preview and export differ only in `RenderOptions` (size, quality, layers, alpha).

```swift
public struct RenderOptions: Sendable {
    public var layers: LayerSet            // backdrop, content, overlays, cursor, clickFX, webcam, captions
    public var alpha: AlphaMode            // .opaque | .premultiplied
    public var motionBlurSamples: ClosedRange<Int>
    public var quality: Quality            // .preview | .export
}
```

### 12.2 FrameSource

```swift
public protocol FrameSource: Sendable {
    /// Sample-and-hold: newest frame with pts <= t. IOSurface-backed texture.
    func frame(atSource t: Double) async throws -> SourceFrame
}
```

- **Sequential reader** (playback / export): `AVAssetReader` with Metal-compatible IOSurface output; read-ahead ring of 8 frames.
- **Scrub reader:** seek to the nearest keyframe, decode forward, LRU cache.
- **Implementations:** `ScreenSource`, `WebcamSource` (plus the cached person-mask sample), `ImportedVideoSource`, `StillImageSource`. A dissolve requests two sources.
- Mipmaps are generated **per new source frame, after mask burn** (section 12.6). Duplicate frames reuse the cached chain.

### 12.3 Render passes

```
source ─► [P0 MaskBurn] ─► [mips] ─┐
                                   ├─► [P2 Content: camera+tilt, resample, rounded mask]
backdrop cache ─► [P1 Backdrop] ───┘          │
                                              ▼
   [P2b Loupe] ─► [P3 Highlight] ─► [P4 Cursor] ─► [P5 ClickFX+Taps] ─► [P6 Webcam/Cutout]
                                              ─► [P7 Captions+Text] ─► [P8 Resolve: blur accumulate, dither, alpha]
```

| # | Pass | Rate | Content |
|---|---|---|---|
| 0 | **Mask burn** | Per new source frame, only if masks are active | Compute pass over mask rects on a scratch copy of the source. Mips are generated from the masked copy. |
| 1 | **Backdrop** | On style change; per frame when 3D tilt is active | Background + dither + shadow + border into a canvas-sized texture. With tilt, the shadow is a pre-blurred sprite warped by the homography. Alpha-clear when transparent export is on. |
| 2 | **Content** | Every frame | Source through the camera transform (affine, or homography when tilting) inside a per-corner superellipse SDF mask, over the backdrop. |
| 2b | **Loupe** | When active | Lens SDF, magnified bicubic sampling of the masked source, rim refraction offset from the SDF normal, specular and inner shadow. |
| 3 | **Highlight** | When active | Dim-outside, outline, or glow in source space projected through the camera. |
| 4 | **Cursor** | Every frame | Mip-mapped vector sprite after the camera transform; crisp at any zoom. |
| 5 | **Effects** | Every frame | Click rings, press feedback, manual taps. |
| 6 | **Webcam** | Every frame | Framed bubble or full/split layout, or person cutout; border, shadow, face-aware crop. |
| 7 | **Captions / text** | Every frame | Cached CoreText textures composited with animation and optional word highlight. |
| 8 | **Resolve** | Every frame | Motion-blur accumulation, tone/dither, conversion to the output pixel format. |

### 12.4 High-quality resampling (the "no soft zoom" rule)

- **Magnify:** Catmull-Rom bicubic using the 5-fetch bilinear optimization (corner taps dropped). *(v1 said "4 taps"; that is the B-spline trick, not Catmull-Rom.)*
- **Minify:** choose mip LOD from screen-space derivatives (`dfdx/dfdy`, which also handles perspective); bicubic on `L` and `L+1`, lerp between them.
- Always float UVs; no integer snapping.

### 12.5 Upscaler (T3, spike-gated, no custom training)

Zoom is sharp by construction when the master is native Retina pixels. The upscaler matters when zoom exceeds the source's native sharpness (1x displays, deep zooms).

- **Candidates (spike 9):** (a) Catmull-Rom plus our own contrast-adaptive sharpen; (b) `MTLFXSpatialScaler`; (c) a Core ML super-resolution model.
- **Adoption gate:** only adopt a candidate that beats (a) on the text-crop fixture set (SSIM and OCR accuracy) at <= 4 ms per frame on M-series, with a license that allows bundling. Otherwise ship (a) only.
- Never advertise a magnification number the gate did not verify.

### 12.6 Masks and privacy guarantees

- Masks are burned into the source copy **before** mip generation and **before** any pass samples it. After burn, no pass may sample the unmasked texture while masks are active (assert in debug).
- Because masks are in source space, zoom, pan, tilt, aspect changes, loupe, and layered export all inherit them.
- **`PrivacyTests`** render a synthetic frame containing known secrets at extreme zoom and run Vision OCR on the result: the secret string must not be recognized. Layered exports are tested too (the cursor layer carries no content).

### 12.7 Backgrounds, frame, and background blur

- **Gradient:** linear/radial, about 24 curated presets. **Mesh gradient:** 4 to 6 control points blended in-shader, optional slow drift. **Blurred content:** blurred saturated copy of the source (compute blur on a downsampled texture). **Solid / image / 30 bundled procedural wallpapers.** Optional film grain.
- **Frame:** per-side padding, per-corner continuous radii, two-layer shadow (tight ambient + soft key), optional 1 px inner border at 8% white.
- **Zoom background blur:** `style.zoomBackgroundBlur` (default off) blurs the backdrop only while zoomed. Off keeps the background sharp.

### 12.8 Cursor rendering

- Art authored as vector (CGPath / PDF), rasterized at 4x into a mip-mapped texture per cursor/size bucket. Imported PNG/PDF cursors supported; SVG where the OS supports it, otherwise converted offline.
- Hotspot-aligned position; size per section 10.2 step 12.
- **Packs:** `Resources/Cursors/<pack>/manifest.json` (name, cursor shapes, hotspots, license). Built-ins: System (re-rendered high-res), Minimal Arrow, Dot, Ring, Pro Arrow. Users can import packs; holiday and themed packs use the same format. Captured custom app cursors render faithfully.

### 12.9 Motion blur

- `K` sub-frames at times `t + (i/K - 0.5) * shutter * dt`, averaged in `rgba16Float` (premultiplied, so alpha export stays correct).
- Adaptive `K = clamp(ceil(maxScreenSpaceSpeedPxPerFrame / 2), 1, maxSamples)`. Static scenes cost nothing.
- Preview `K <= 2`. Export full quality. Covers camera, cursor, tilt, and layout motion together.
- Mask burn, mips, and caption textures are per source frame / per chunk and are reused across sub-frames.

### 12.10 Webcam cutout

- Mask comes from the cached `cutout.mov` sampled by time; refine with a slight blur plus smoothstep threshold (`cutout.edgeFeather`, 1.5 px). No Vision call at render time.
- If the cache is not ready, preview shows the framed bubble with a progress badge; export waits for the analyzer.

### 12.11 Captions rendering

CoreText → `CGContext` → texture per chunk (LRU of 32). Base and highlight textures plus a per-word reveal mask (uniform array of word rects) give karaoke highlight without re-rendering per frame. Styles are data (font, size as a fraction of canvas height, weight, color, pill background, outline, animation: none / fade / pop / slide).

### 12.12 Layers and alpha

- `LayerSet` selects passes; `AlphaMode.premultiplied` clears the backdrop to transparent and keeps shadow alpha.
- **Layer identity test:** compositing the exported `cursor` layer over the exported `no-cursor` master with a reference compositor must reproduce the full render within tolerance (`LayerExportTests`).
- 8-bit BGRA is the baseline alpha format; preferred ProRes 4444 input formats are chosen by spike 13.

### 12.13 Preview presentation loop

- `CAMetalLayer` in an `NSView`; `NSView.displayLink` for display-synchronized callbacks.
- Per tick: `t = playbackClock.time(at: link.targetTimestamp)`, evaluate `FrameState`, encode, present.
- Preview renders at the **view's pixel size** through the same code path.
- `PlaybackClock` is host-time based; audio starts with `AVAudioPlayerNode.play(at: AVAudioTime(hostTime:))` for lock-step.

### 12.14 Performance budgets (verified under Metal System Trace)

| Scenario | Budget |
|---|---|
| Preview @ 120 Hz, display-sized canvas | GPU < 4.0 ms/frame |
| Preview @ 60 Hz | GPU < 8.0 ms/frame |
| Preview with masks + loupe + captions + cutout | GPU < 6.0 ms @ 60 Hz |
| Export 4K, offline | >= 1x realtime at 60 fps with motion blur on Pro-class; target 2x without blur |
| Export 8K (probe-gated) | >= 0.25x realtime, <= 60 fps |
| Mask burn | < 0.5 ms per new source frame at typical mask area |
| Memory (60-min recording) | Bounded frame pools; mmap'd tracks; no growth over time |

Ship a debug performance HUD (frame time, GPU time, dropped frames).

---

## 13. Audio subsystem (`LumenAudio`)

Everything audio is scheduled from `Timeline.audio`, so preview and export match.

### 13.1 Voice chain (per mic source)

1. High-pass at 80 Hz.
2. **RNNoise** denoise (480-sample frames at 48 kHz, vendored C target).
3. **Keystroke-aware declick:** `events.bin` gives exact `keyDown` times. In a +/-35 ms window around each key (shifted by the source's latency offset), when VAD says no speech overlaps, attenuate the 2 to 8 kHz band by `declick.depth` (default -12 dB). If speech overlaps, apply a milder reduction. Spike 14 validates against recorded keyboards.
4. Gentle presence EQ; optional de-esser in Podcast mode.
5. Compressor, then limiter at -1 dBTP.
6. **Loudness normalization:** two-pass; integrated loudness per BS.1770-4 K-weighting with gating (about 150 lines on Accelerate, validated against reference tones); gain to the mode's target.

### 13.2 Mic modes

| Mode | Chain | Target |
|---|---|---|
| Standard | full chain | -14 LUFS |
| Loud | stronger compression, higher gain ceiling | -12 LUFS (limiter still -1 dBTP) |
| Podcast | stronger HPF (100 Hz), de-ess, tighter gate, light compression | -16 LUFS |
| Off | raw, untouched | none |

Each source (mic 1, mic 2, virtual, system) has its own mode and level.

### 13.3 Lanes and external audio

```swift
public struct AudioLane: Codable, Sendable {
    public var id: UUID
    public var role: Role                   // .mic | .system | .voiceover | .music | .sfx
    public var source: AudioSourceRef       // recorded source or imported asset
    public var placement: Double            // OUTPUT seconds
    public var gain: Double, mute: Bool
    public var exportMode: ExportMode       // .mixed | .separate
    public var variant: String?             // e.g. "EN", "ES"
}
```

- Import MP3/WAV/M4A, decode and resample to 48 kHz, place on a lane. Voice-over lanes and variants support multilingual versions: one project exports once per variant.
- Imported lanes pass through the same normalization and optional ducking as music.

### 13.4 SFX (zero licensing risk)

Synthesized in `Tools/` at build time: soft click (filtered-noise burst plus low sine thump, 4 to 6 variants), whoosh (band-swept filtered noise, separate in/out). Randomization: pitch +/-3%, gain +/-1.5 dB, never repeat a variant twice in a row (seeded). Whoosh gain scales with zoom magnitude. Cues come from click events and zoom segments.

### 13.5 Music

- `MusicProvider` protocol: bundled CC0 library (<= 12 tracks, <= 40 MB) plus user import. Every bundled track has a `licenses.json` entry; CI fails if any asset lacks one.
- Auto-fit to timeline length: loop/trim at beat-safe points, 1.5 s fade-out.
- **Auto-ducking:** voice-activity envelope drives music gain. Duck depth -14 dB, attack 50 ms, release 400 ms; the bed sits about 12 dB under the voice at rest.
- Speed-ramped spans: mic muted, music continues.

### 13.6 Mixing and stems

- **Live:** `AVAudioEngine` graph with `AVAudioPlayerNode`s synced to the playback clock.
- **Offline:** `enableManualRenderingMode(.offline)` mixes the timeline at export speed.
- **Export modes:** one mixed AAC track (256 kbps), **or multiple AAC tracks** (mic, system, music, voice-over as separate `AVAssetWriterInput`s in one file), **or WAV stems** beside the video. Final mixed output: true peak <= -1 dBTP at the mode's LUFS target.

---

## 14. Export subsystem (`LumenExport`)

### 14.1 Presets

| Preset | Notes |
|---|---|
| Shareable | H.264 8-bit, up to 4K60, maximum compatibility. |
| Max quality | HEVC Main10, best for gradients, up to the verified 4K / fps limit. |
| High-FPS | HEVC at 120 / 144 / 240 where the probe passes. |
| Pro | ProRes 422 HQ (software fallback if no ProRes engine). |
| Pro + alpha | ProRes 4444 with alpha; or HEVC with alpha for lightweight transparent clips. |
| Layered | Folder: `main-nocursor.mov`, `cursor.mov` (alpha), optional `webcam.mov` (alpha), `captions` (alpha or SRT), stems. |
| GIF | ImageIO palette quantization, size/fps limits, loop mode friendly. |
| Clipboard | Shareable 1080p, short clips, placed on the pasteboard as a file. |

### 14.2 Capability probe

`ExportCapabilityMatrix` decides selectable `(codec, resolution, fps, alpha)`:

1. Static level limits as a first filter.
2. **Real probe:** a hardware-only `VTCompressionSession` (`RequireHardwareAcceleratedVideoEncoder`) encodes one frame per candidate, lazily, cached per machine.
3. The UI shows only valid combos. If a runtime combo fails, fall back one step (for example 4K120 → 4K60) with a visible notice. 8K appears only when probed.

### 14.3 Offline export loop

```
for each output frame i in [0, N):
    t = i / fps
    state  = timeline.evaluate(at: t)                              // CPU, microseconds
    srcs   = await frameSources(for: state)                        // 1 source, or 2 during dissolve
    cb     = renderer.encode(outputTime: t, srcs, options, into: pooledPixelBuffer)   // GPU
    adaptor.append(pooledPixelBuffer, pts: i/fps)                  // hardware encode
```

- Pipelined: GPU renders `i+1` while the encoder consumes `i`. Pixel buffers come from the adaptor's IOSurface pool.
- Audio: offline mix, then the audio `AVAssetWriterInput`(s).
- `shouldOptimizeForNetworkUse = true`. Tag color primaries, transfer, matrix correctly.
- Progress, cancellation, `*.partial` temp files, atomic rename on success.

### 14.4 Layered and alpha export

- Layered export runs the same loop once per layer with a different `LayerSet`, always at the same canvas, fps, and camera so layers register perfectly in the NLE.
- **Cursor layer:** `cursor + clickFX + taps` on a transparent canvas, camera transform applied (aligned with the master), ProRes 4444.
- Also write `cursor.json` (position, opacity, press, shape per output frame) for NLE-side re-rendering.
- **Transparent background render:** backdrop alpha 0, shadow keeps alpha, content opaque, premultiplied end to end.

### 14.5 Batch, aspect, and variants

`ExportBatch` shares the Director output and analysis across jobs: **one click renders 16:9, 1:1, 9:16** (each re-aimed by the Director), and one job per audio variant. Aspect jobs replan `.auto` zoom and layout per canvas; they never mutate the project.

### 14.6 Sharing artifacts

- **Clipboard:** render the Clipboard preset to a temp file and place it on `NSPasteboard` as a file URL (and GIF as image data).
- **Share-safe project:** `NSFileCoordinator` read with `.forUploading` yields a zip of the bundle (spike 15). Options: full media / 1080p proxy; without `cache/`; **bake privacy** (re-encode `screen.mov` with masks burned in, irreversible, because masks are otherwise removable intent).
- **SRT/VTT** sidecar export from the caption plan.

### 14.7 Quality consistency

- Every export stamps an `ExportRecipe` version and writes it into container metadata.
- Recipes (bitrate formula, profile, GOP, rate-control, tags) are frozen per release; any change bumps the recipe version and is noted in release notes.
- `lumen-cli quality-check` renders a fixture and asserts SSIM against stored goldens; part of `make verify`.
- Bitrate: `pixels x fps x bpp`; default bpp 0.06 (screen content), High 0.10; `DataRateLimits` set to avoid spikes.

---

## 15. Automation and control plane (`LumenControl`, `LumenMCP`)

### 15.1 Architecture

```
Agent (Claude / Cursor / AMP)
   │ MCP (stdio JSON-RPC 2.0)
   ▼
lumen-mcp  (≈400 lines, no dependencies)
   │ Unix domain socket  ~/Library/Application Support/Lumen/control.sock  (mode 0600, same-user peer check)
   ▼
ControlServer (in app)  ──► consent gate ──► Command ──► reduce / RecordingSession / Export
```

Recording requires the app because the screen-recording permission belongs to it. Offline operations (analyze, render, export) also work headless through `lumen-cli`.

### 15.2 Tool surface (one `Command`, three adapters)

| Group | MCP tool | CLI verb | Notes |
|---|---|---|---|
| Status | `lumen.status`, `lumen.list_sources` | `status` | read-only |
| Record | `lumen.start_recording`, `stop`, `pause`, `resume` | (app only) | consent-gated |
| Projects | `lumen.list_projects`, `lumen.open_project` | `projects` | read-only |
| Look | `lumen.apply_preset`, `lumen.set_style` | `style` | |
| Zoom | `lumen.set_zoom_preset`, `lumen.add_zoom` | `zoom` | |
| Privacy | `lumen.add_mask`, `lumen.review_masks` | `mask` | |
| Edit | `lumen.auto_tidy`, `lumen.split` (playhead or explicit time) | `tidy` | |
| Export | `lumen.export`, `lumen.export_status` | `render` | output restricted to approved directories |

MCP resources: `lumen://projects`, `lumen://project/{id}/timeline` (read-only JSON). One prompt: `record-demo` (scripted checklist).

### 15.3 Consent and safety

- **Policy:** Off / Ask each time (default) / Allow for N minutes. `start_recording` always raises a visible approval unless Allow-for-N is active.
- While an agent session is active, the menu bar shows an unmistakable indicator and the HUD shows "Controlled by <client>".
- File paths are restricted to the project directory and approved export folders. No arbitrary reads or writes.
- Local-only (no TCP listener). Every call is written to a local audit log. Rate limit per client.
- `McpTests`: protocol conformance, consent gating, path allowlist.

### 15.4 App Intents

A thin adapter (Start/Stop recording, Export last project with preset) over the same commands, giving Shortcuts and Spotlight support. No separate logic.

---

## 16. Sharing and cloud (optional, isolated: `LumenShare`)

Compiled only with `LUMEN_CLOUD`; off by default; explicit consent UI per provider.

```swift
public protocol ShareProvider: Sendable {
    func publish(file: URL, options: ShareOptions) async throws -> ShareLink
}
```

| Provider | Phase | Notes |
|---|---|---|
| `FileShare` (Reveal, AirDrop via `NSSharingService`, clipboard) | 6 (core, no network) | ships in the main app |
| `S3CompatibleShare` (user-supplied bucket, for example Cloudflare R2 free tier) | 15 | presigned PUT of MP4 plus a static player page with an unguessable id |
| Reference worker `Tools/share-worker/` | 15 | single Cloudflare Worker script adding comments, view notifications, and email via the user's own provider; app side only stores `notifyOnView` and a webhook URL |

Not built: our own hosting, accounts, billing, or email infrastructure. CI check: `URLSession` / `Network` imports appear only in `LumenShare`.

---

## 17. App and UI layer (`LumenUI`)

### 17.1 Flow (the zero-edit path)

`Menu bar icon / hotkey` → `Source picker (display / window / region / device)` → `Options (mic(s), system audio, webcam, fps, quality)` → `3-2-1 countdown` → **record** (pause/resume available) → `Stop` → editor opens with auto-plan applied (zoom, ramps, look; masks proposed; captions generating) → **Export** (one click, last-used preset or "all aspects").

### 17.2 Components

- **Menu bar:** `MenuBarExtra`; global start/stop/pause hotkeys via Carbon `RegisterEventHotKey` (small wrapper).
- **Recorder HUD:** non-activating floating `NSPanel` (excluded from capture), shows time, dropped frames, per-source meters, agent-control indicator.
- **Region selector:** borderless overlay with live size readout.
- **Editor window:**
  - Preview: Metal view, transport, scrubbing.
  - **Timeline** (SwiftUI `Canvas`, virtualized drawing): lanes for Clips, Zoom, Layout, Overlays (masks / highlights / loupes / taps / text), Captions, and Audio lanes with waveform peaks from the pyramid; playhead; click markers; pause markers.
  - **Transcript panel:** words with filler highlights; delete-to-cut; Auto-tidy button.
  - **Zoom focus editor:** drag a rectangle on the preview to set a segment's focus box.
  - **Privacy review panel:** list of auto/proposed masks with approve/reject and jump-to.
  - **Inspector tabs** (<= 6 controls each, Advanced collapsed): Look, Cursor, Camera, Layout, Audio, Captions, Privacy, Export.
- **Presets:** save/load full looks (style + cursor + camera + layout settings + audio + caption style).
- **State:** `EditorModel` holds `Project` plus the undo stack. Edits dispatch commands; the debounced (100 ms) Director replan swaps the `Timeline` atomically; the UI shows the previous result until the new one is ready.

### 17.3 Editing rules

- **Playhead is the only time source** for split / cut / add-here commands. `ReduceContext` captures `playhead` at dispatch. Pointer position, last-clicked timeline position, and selection never supply a cut time (feature 44, `CommandBusTests`).
- Shortcuts: `S` split at playhead, `⌫` delete selection (ripple), `Z` add zoom at playhead, `M` add mask at playhead, `⌘Z / ⇧⌘Z` undo/redo, `Space` play, `J/K/L` shuttle.
- Imports by drag-drop onto the timeline: video, image, audio, cursor pack, wallpaper.

### 17.4 Webcam and layout UI

- Layout segments on the timeline with a layout picker; per-layout camera settings in the Layout tab.
- Toggles: Hide during silence, Avoid cursor, Behind-face mode (move / hide / fade), Cutout, Mirror.

---

## 18. Quality engineering

### 18.1 Test suites

| Suite | What it proves |
|---|---|
| `DirectorTests` | Zoom planner and camera solver on synthetic scripts (click grid, typing burst, long pan, idle gap, wiggle noise). Continuity C2, no overshoot, bounds, cursor inside view with margin, click pins exact, sensitivity thresholds. |
| `CursorTests` | Zero-lag (cross-correlation peak at 0), pins within 0.5 px, glide preserves start/end times, loop mode converges to the first frame, no smoothing across pause markers. |
| `TimeMapTests` | Monotonic, invertible outside cuts, ramps smooth, camera runs in output time, epoch resets only at clip boundaries. |
| `InvalidationTests` | Each `Effects` flag recomputes exactly its row of the section 4.6 matrix. |
| `CommandBusTests` | Every UI action has a command; reducer purity; cut/split uses the playhead captured at dispatch; undo restores exactly. |
| `LayoutTests` | Spring continuity of `ResolvedLayout`; no overshoot; placement hysteresis (no oscillation); behind-face behavior; hide-on-silence timing. |
| `TranscriptEditTests` | Word deletion maps to cuts; silence snap; no audio click at joins (discontinuity < threshold); camera continuity across cuts; pause rule never overlaps ramps. |
| `CaptionTests` | Chunk invariants (max lines/chars, duration, no overlap), aspect-adaptive positioning, webcam avoidance, highlight toggle. |
| `PrivacyTests` | Pattern classification corpus; track coverage >= 99% on scrolling fixtures; **OCR-negative on rendered frames at extreme zoom**; masks survive layered export. |
| `RenderGoldenTests` | Fixed `t` values compared against goldens within tolerance (backdrop, cursor, zoom, blur, tilt, loupe, captions, cutout). |
| `AlphaTests` | Premultiplied correctness: composite over a checkerboard equals in-render composite. |
| `LayerExportTests` | Cursor layer over no-cursor master reproduces the full render within tolerance. |
| `SyncTests` | A test app flashes the screen at a known `t` and posts a synthetic click; event time vs first changed frame within 1 ms; also per-audio-source alignment. |
| `RecoveryTests` | kill -9 mid-record (video, audio journals, events) recovers all but the last <= 2 s. |
| `ColorRoundTrip` | Known P3 patches survive capture, render, and encode within tolerance. |
| `AudioTests` | Loudness lands at the mode target +/-0.5 LU, true peak <= -1 dBTP, ducking matches VAD, SFX variant rule, declick reduces keystroke energy without touching speech. |
| `ExportProbeTests` | The matrix contains only combos that actually encode (including alpha). |
| `QualityGate` | SSIM >= 0.995 vs goldens per recipe. |
| `McpTests` | Protocol conformance, consent gating, path allowlist, audit log. |
| `MigrationTests` | Each schema bump migrates fixtures; unknown fields survive. |
| `PerfTests` | Frame-time budgets; memory plateau over a 60-minute synthetic project. |

### 18.2 CLI (the agent's eyes; headless)

```
lumen-cli analyze      <project> --report out.json
lumen-cli render       <project> --preset 4k120-hevc --out out.mov
lumen-cli render       <project> --layered --out outdir/
lumen-cli frame        <project> --t 12.5 --out frame.png          # single-frame golden
lumen-cli smoothness   <project>                                   # section 11.1 report
lumen-cli sync-check   <project>                                   # clock alignment report
lumen-cli quality-check <project> --recipe max-quality             # SSIM gate
lumen-cli probe                                                    # export capability matrix
lumen-cli privacy-scan <project>                                   # list auto-detected masks
```

### 18.3 Makefile targets

`make build` | `make test` | `make verify` (tests + goldens + smoothness + sync + quality + license check + network-import check + file-size budget) | `make bench` | `make demo` (render fixtures to `out/`) | `make recover-test` | `make mcp-test`.

### 18.4 Observability

`os_signpost` per stage; `Logger` category per module; performance HUD in debug builds; drop counters in the recorder HUD and stored in the project.

---

## 19. Day-1 verification spikes (answer before building on them)

Record results in `Docs/Spikes.md`; update this plan where reality differs.

1. **Clock alignment:** SCK PTS vs `CGEvent` timestamps vs AVCapture audio (several devices) vs webcam. Target < 1 ms, no drift over 30 min. Decide SCK-mic vs AVCapture-mic.
2. **Capture rate and overhead:** SCK delivered fps at 60 / 120; effect of `queueDepth`; CPU/GPU overhead (becomes the regression baseline).
3. **Master encode:** HEVC bitrate vs visible quality at 3x zoom; keyframe-0.5 s scrub latency.
4. **Cursor shape mapping:** hash classification coverage for common apps; custom cursor fidelity.
5. **4K120 / 4K144 / 1440p240 / 8K encode:** run the probe on target hardware; record what passes (including alpha).
6. **Permissions:** Screen Recording grant behavior, relaunch need, `SCContentSharingPicker` effect on prompts.
7. **SVG cursor import:** whether `NSImage` handles SVG on the target OS; otherwise PDF/CGPath.
8. **Display link:** `NSView.displayLink` stability at 120 Hz with the Metal layer.
9. **Upscaler:** Catmull-Rom + CAS vs `MTLFXSpatialScaler` vs a Core ML model on the text-crop fixture set (SSIM, OCR accuracy, ms).
10. **Person segmentation:** quality, temporal stability, and fps at `.accurate` on 1080p30 webcam; mask cache size.
11. **Transcription:** Apple Speech vs `SpeechAnalyzer` vs whisper.cpp: word-timestamp accuracy, custom-vocabulary effect, speed.
12. **iOS device capture:** CoreMediaIO enablement, resolutions, audio, latency, device-disconnect behavior.
13. **Alpha formats:** ProRes 4444 and HEVC-alpha input pixel formats, 8-bit BGRA baseline, color tags, NLE round trip.
14. **Keystroke declick:** effect on real keyboards (mechanical and laptop); false-positive rate on speech.
15. **Zip packaging:** `NSFileCoordinator` `.forUploading` on large bundles; fall back to a minimal in-app archiver if it fails.
16. **OCR throughput:** Vision text recognition on 4K change-driven frames; false-negative rate on code/terminal fonts.
17. **Crash safety:** fragmented MOV recovery behavior across macOS versions; journal wrap time for 60-minute audio.
18. **Perspective LOD:** derivative-based mip selection quality under 3D tilt at 4x zoom.

---

## 20. Phased roadmap with acceptance criteria

Milestones: **M1** "Better than QuickTime" (phases 0 to 3) · **M2** "Screen Studio core" (4 to 6, public alpha gate) · **M3** "Parity" (7 to 9) · **M4** "Beyond" (10 to 12) · **M5** "Hardened release" (13 to 14) · optional cloud (15).

### Phase 0: Foundation
- SwiftPM workspace, module graph, Makefile, CLI skeleton, CI script, lint/format, Swift 6 strict mode, network-import and file-size checks, `Command` enum and reducer skeleton.
- **Accept:** `make verify` runs green on an empty-but-wired project.

### Phase 1: Capture and project bundle
- `RecordingSession`, `CaptureEngine`, `InputRecorder`, **multi-source audio journals**, webcam, **fragmented MOV and crash recovery**, **pause/resume**, bundle writer, permissions onboarding, menu bar and hotkeys, countdown.
- **Accept:** 5-minute 60 fps native-res recording with 0 dropped frames; `events.bin` density correct; sync < 1 ms for every audio source; two simultaneous audio inputs (for example BlackHole + mic) stay in sync; kill -9 recovery passes; bundle reloads.

### Phase 2: Render core
- `FrameSource`, Metal renderer, backdrop cache, content pass with Catmull-Rom + mip resampling, **per-side padding and per-corner radii**, **all aspect ratios**, `RenderOptions`, preview view, `lumen-cli render/frame`.
- **Accept:** gradient + rounded frame + shadow at any canvas size and aspect; preview >= display refresh without drops; golden frame tests pass.

### Phase 3: Cursor
- Cursor pipeline, sprite renderer, packs (including import format), click FX, idle hide, **constant-size toggle**, **loop mode**, **manual tap indicators**.
- **Accept:** `CursorTests` pass; clicks within 0.5 px; zero-lag cross-correlation; loop converges; smoothness report clean for cursor.

### Phase 4: Camera and zoom
- Zoom planner (**fine controls, sensitivity, follow delay, centering offset, viewport-aware scale, Cinematic preset**), camera solver, dead-zone, lookahead, editor segments, motion blur, **zoom background-blur toggle**, auto re-aim on aspect change.
- **Accept:** `DirectorTests` pass; discontinuity scan clean; spectral check < 1% above 8 Hz; wiggle fixture creates no zoom; cinematic on three reference demos (login flow, chat typing, dashboard click-through).

### Phase 5: Audio core
- Voice chain, RNNoise, **keystroke declick**, mic modes, per-source levels, **audio lanes and external audio import**, SFX synth, music provider, ducking, loudness, live + offline mix, **separate-track and stem export**.
- **Accept:** `AudioTests` pass; preview and export audio match; loudness at target +/-0.5 LU; separate tracks verified in QuickTime and a browser.

### Phase 6: Editor and export core
- Timeline UI, **clips, trims, cuts, split at playhead, import video/clips, dissolve**, speed ramps (manual plus auto), zoom focus editor, inspector, presets, export panel, capability probe, GIF, **clipboard export**, **multi-aspect batch**, `FileShare`.
- **Accept:** zero-edit path works end to end; edits update preview in < 150 ms; cut/split uses the playhead only (`CommandBusTests`); exports valid in QuickTime and a browser; probe-selectable combos all encode; imported video edits like a recording.

### Phase 7: Webcam and layouts
- Webcam bubble, five layouts, **`ResolvedLayout` spring transitions**, per-layout settings, face track and framing, **person-mask cutout**, hide-on-silence, **placement solver (avoid cursor, behind-face)**.
- **Accept:** `LayoutTests` pass; webcam framing jitter-free (same smoothness metrics); camera never covers the cursor on the reference demos; cutout stable over 5 minutes.

### Phase 8: Transcript, captions, and tidy
- `AppleSpeechEngine` (+ vocabulary), transcript model, caption planner and renderer, styles, **word-highlight toggle**, **manual text blocks**, SRT/VTT, **transcript editing**, filler and pause removal, Auto-tidy.
- **Accept:** `CaptionTests` and `TranscriptEditTests` pass; speech never cut mid-word; joins have no audible click; captions reposition correctly across 16:9 / 1:1 / 9:16.

### Phase 9: Privacy and emphasis
- `SensitivePatterns`, OCR analyzer (change-driven), mask track builder, manual multi-mask UI, review panel, mask burn pass, **loupe**, **highlight**.
- **Accept:** `PrivacyTests` pass including OCR-negative at 6x zoom; recall >= 99% on the synthetic corpus; masks persist through layered export.

### Phase 10: Cinematic and pro output
- **3D moves (Lean, Float, Reveal)**, upscaler decision (spike 9, ship only if the gate passes), **alpha / transparent render**, **layered export with cursor layer**, 120/144/240 and probe-gated 8K, **voice-over variants**, **share-safe project (with bake privacy)**, recipe versioning, `quality-check`.
- **Accept:** `AlphaTests` and `LayerExportTests` pass; SSIM gate green; tilt/layout smoothness clean; layered export opens correctly in Premiere or After Effects.

### Phase 11: Automation
- `ControlServer`, consent policy, `lumen-mcp`, tool surface, audit log, App Intents adapter.
- **Accept:** `McpTests` pass; an MCP client records, edits, and exports a demo end to end with the consent gate exercised.

### Phase 12: Devices and pixel activity
- iPhone/iPad capture, generic device frames, pixel-activity analyzer feeding the zoom planner for device/imported clips.
- **Accept:** a device recording auto-zooms plausibly using pixel activity plus manual taps; disconnect handling is clean.

### Phase 13: Performance hardening
- 4K120 export, 60-minute recordings, thermal handling, memory plateau, full recovery matrix.
- **Accept:** `PerfTests` green; no memory growth; `make recover-test` passes.

### Phase 14: Release
- Onboarding polish, icons, docs, license manifest, notarization (optional, section 22).
- **Accept:** clean-machine install and first recording in under 2 minutes.

### Phase 15 (optional): Cloud sharing
- `S3CompatibleShare`, reference worker, comments, view notifications, email via the user's provider.
- **Accept:** link playable in a browser; nothing leaves the machine unless the user enabled a provider; CI network-import check still green for every other module.

---

## 21. Default tuning table (all exposed as parameters; presets set these)

| Parameter | Default | Range |
|---|---|---|
| **Cursor** | | |
| `cursor.smoothingSigma` | 35 ms | 0 to 120 |
| `cursor.glide` | 0.35 | 0 to 1 |
| `cursor.idleHide` | 2.0 s | off to 10 |
| `cursor.pressScale` | 0.86 | 0.7 to 1 |
| `cursor.clickRing` | 0.45 s | off to 1 |
| `cursor.zoomCompensation k` (1 = constant size) | 0.5 | 0 to 1 |
| `loop.duration` | off | 0.6 to 3 s |
| **Zoom planner** | | |
| `zoom.minScale` | 1.3 | 1.1 to 2.0 |
| `zoom.maxScale` | 2.2 | 1.2 to 4.0 |
| `zoom.minTrigger` | 1.25 | 1.1 to 2.0 |
| `zoom.leadIn` | 0.45 s | 0 to 1.2 |
| `zoom.tail` | 0.7 s | 0.2 to 2 |
| `zoom.mergeGap` | 2.5 s | 1 to 6 |
| `zoom.panThroughGap` | 1.5 s | 0.5 to 4 |
| `zoom.minHold` | 1.0 s | 0.5 to 3 |
| `zoom.clickWeight` | 3 | 1 to 5 |
| `zoom.sensitivity` | 0.5 | 0 to 1 |
| `zoom.backgroundBlur` | off | on / off |
| **Camera** | | |
| `camera.omegaPan` | 7.0 rad/s | 3 to 14 |
| `camera.omegaZoom` | 6.0 rad/s | 3 to 12 |
| `camera.lookahead` | 0.20 s | 0 to 0.6 |
| `camera.followDelay` | 0.12 s | 0 to 1.0 |
| `camera.deadZone` | 0.28 | 0.1 to 0.45 |
| `camera.centerOffset` | (0, 0) | +/-0.3 view-normalized |
| `tilt.mode` | off | off / Lean / Float / Reveal |
| `tilt.maxYaw / maxPitch` | 8 / 6 deg | 0 to 12 |
| `tilt.float` | 1.2 deg | 0 to 2 |
| `tilt.omega` | 5.0 | 2 to 10 |
| `motionBlur.shutter` | 0.5 | 0 to 1 |
| `motionBlur.maxSamples` | 8 | 1 to 16 |
| **Frame and look** | | |
| `frame.padding` (per side) | 6% | 0 to 20% |
| `frame.cornerRadius` (per corner) | 14 pt | 0 to 40 |
| **Layout and webcam** | | |
| `layout.omega` | 9.0 | 4 to 16 |
| `webcam.avoidCursor` | on | on / off |
| `webcam.avoidMargin` | 48 px | 0 to 160 |
| `webcam.snapDwell` | 1.5 s | 0.5 to 4 |
| `webcam.behindFace` | move | move / hide / fade |
| `webcam.hideOnSilence` | off | on / off |
| `webcam.silenceHold` | 0.6 s | 0.2 to 2 |
| `webcam.omegaFace` | 3.5 | 2 to 8 |
| `cutout.edgeFeather` | 1.5 px | 0 to 6 |
| **Captions** | | |
| `captions.maxLines` | 2 | 1 to 3 |
| `captions.maxCharsPerLine` | 42 (16:9) / 24 (9:16) | 16 to 60 |
| `captions.minDuration / maxDuration` | 0.9 / 4.0 s | |
| `captions.wordHighlight` | on | on / off |
| `captions.size` | 4.2% canvas height | 2 to 8% |
| `captions.safeBottom` | 9% (14% in 9:16) | 0 to 25% |
| **Transcript tidy** | | |
| `pause.max / pause.keep` | 0.6 / 0.25 s | |
| `cut.crossfade` | 40 ms | 10 to 120 |
| `cut.snapWindow` | 40 ms | 0 to 100 |
| **Privacy** | | |
| `mask.padding` | 6 px source | 0 to 24 |
| `mask.blurRadius` | >= 0.6 x box height | |
| `ocr.cadence` | 1 Hz min, up to 4 Hz on change | |
| `ocr.minConfidence` | 0.5 | 0.3 to 0.9 |
| `entropy.threshold` | 3.5 bits/char | 3.0 to 4.5 |
| **Audio** | | |
| `audio.targetLUFS` | -14 (Podcast -16, Loud -12) | -23 to -10 |
| `declick.depth / window` | -12 dB / 35 ms | 0 to -24 / 15 to 60 |
| `audio.duckDepth` | -14 dB | -6 to -24 |
| `audio.duckAttack / release` | 50 ms / 400 ms | |
| **Speed ramps** | | |
| `speedRamp.minIdle` | 2.0 s | 1 to 6 |
| `speedRamp.maxSpeed` | 8x | 2 to 16 |

---

## 22. Distribution at $0

- Xcode, Swift, Metal, RNNoise, Vision, Speech, and all Apple frameworks are free.
- Develop with a free Apple ID. Use a **stable local signing identity** so macOS does not reset the Screen Recording permission on every rebuild.
- Notarized distribution requires the Apple Developer Program ($99/yr). At $0, publish source on GitHub and let users build with `make app`, or approve manually in System Settings > Privacy & Security.
- CI at $0: GitHub Actions macOS runners on a public repo, or run `make verify` locally.
- Whisper models and music are bundled or user-imported; the app never downloads assets.

---

## 23. Definition of Done

- All phase acceptance criteria green under `make verify`.
- Smoothness report clean on three reference demos at 60, 120, and 240 fps output, for 16:9 and 9:16.
- A first-time user records, stops, and exports a polished 4K demo in under 3 clicks after setup.
- A demo with an API key on screen exports with the key unreadable (OCR-negative), with no manual masking.
- No dropped frames in a 30-minute 60 fps native-resolution recording; kill -9 recovery passes.
- Preview and export are pixel-identical for the same timeline and time (golden test).
- Every row in section 3.1 is either done or explicitly marked gated (T3) with its spike result recorded.
- Layered export composites back to the master within tolerance.
- The core app imports no networking code; `make verify` proves it.

----