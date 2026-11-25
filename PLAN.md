# Lumen 2.0 — Core backend reconstruction

## Mission
Replace the Studio audio, playback, Director, camera, planner, crop, analysis, compositor and export implementations with a single coherent native Swift backend. Preserve the existing timeline and recording UI, MCP/agent/actuator contracts and raw media. Restore wallpapers, canvas, webcam, keyboard and mouse sounds; support browser content crop/reveal, accurate typing focus, Classic/Loupe, shortcuts, captions, transcript edits, device recording and local privacy. No UI redesign, no merge. Real Mac evidence is mandatory.

## Assumptions and evidence rules
- Base: ba23409789904df4d6db2ddb33567ad6439d6cf9; branch: rebuild/lumen-2-core. Existing uppercase PLAN.MD is archived verbatim as Docs/LEGACY-BUILD-PLAN.md to avoid case collisions on macOS. This file is the new execution ledger.
- Preserve project schema compatibility; incremental replacement rather than deleting working code before its replacement is validated. Existing MCP names, policy and permission checks remain.
- Audio default: one studio chain at 48 kHz; −14 LUFS ±1 LU for eligible speech, true peak ≤ −1 dBTP; synchronized raw audio until enhanced windows are available. Verify asset-specific licensing before distributing Mechvibes.
- Target on M1 8 GB: 1080p60 controlled 60-second run with zero drops; p99 interval ≤18 ms; warm seek p95 ≤100 ms, cold ≤250 ms, first visible frame ≤1 s; hold drift ≤0.1 source px, feasible target ≤0.5 source px, no zoom overshoot; generated cue error ≤1 ms, A/V within one frame; memory target <700 MB, baseline export ≥3x real time. These are acceptance targets, not current results.
- Environment: local tool host is Linux x86_64 with Swift 6.2.1, no Xcode or macOS GUI; GitHub network DNS unavailable locally. GitHub connector can read/write; existing PR workflow runs macos-15. CI is not a substitute for a real interactive Mac session. No fake screenshots, synthetic footage presented as real, or unchecked evidence marked complete.
- Each checkbox requires a one-line evidence note; run affected build/typecheck/runtime checks after code changes. If a gate fails, fix and rerun before marking it. Additional discovered work is recorded as nested substeps without renumbering the original 201. Keep main unchanged, use draft PR until proof complete. No merge.
- Current audit is targeted, not a full line-by-line review. Prior source inspection: EditorModel playback waits for full mix beyond initial window; PreviewView awaits FrameSource decode; Director has distinct stop/editor planning paths; camera/crop baked at 480 Hz; keyboard cues only keyDown and pack only downSlice; artwork and resource packaging remain tracked. These are code findings, not measured runtime root causes.

## 1. Understand and map the repository

1. [x] Pin main SHA and create isolated reconstruction branch. — Pinned main ba23409789904df4d6db2ddb33567ad6439d6cf9; isolated rebuild/lumen-2-core created.
2. [x] Inventory tracked sources, tests, resources and CI; map package targets. — Recursive Git tree inspected; 200 Swift source files, 127 Swift test files, macos-15 PR CI, package targets mapped.
3. [ ] Read every first-party Swift source file, including control and CLI callers; record coverage.
4. [ ] Read all tests and classify independent behavior assertions versus implementation-specific assertions.
5. [ ] Read repository policies, architecture documents and prior incident reports; reconcile contradictions.
6. [ ] Trace LumenCapture/Capture.swift and Session.swift from prepare through finalize.
7. [ ] Trace Input.swift, ViewportRecorder.swift and clock conversion; identify key-up and secure-input evidence.
8. [ ] Trace audio capture formats, offsets, gaps and pause handling.
9. [ ] Map LumenAudio/DSP.swift, Studio.swift, DeepFilterNet.swift and ProcessedVoice.swift.
10. [ ] Map Mixer.swift, AudioMapped.swift, TypingPacks.swift, TypingSampler.swift and SFX.swift.
11. [ ] Inspect both copies of Mechvibes configuration, timings, assets and upstream licensing.
12. [ ] Trace ProjectSession.swift open, audio readiness, revision watcher and save lifecycle.
13. [ ] Trace EditorModel.swift transport, derive, analysis, undo and background tasks.
14. [ ] Trace PreviewView.swift, FrameSource.swift and renderer presentation deadlines.
15. [ ] Trace Director.swift, Planner.swift, Camera.swift, Cursor.swift and crop/focus paths.
16. [ ] Map LumenAnalysis, LumenSpeech, captions, transcript cuts and privacy evidence.
17. [ ] Trace Renderer.swift, shaders, upscaling, webcam and canvas transforms.
18. [ ] Inventory wallpaper manifests, canvas presets, sounds, model binaries and make-app packaging.
19. [ ] Map LumenProject persisted schema, migrations, timeline commands and all MCP/CLI consumers.
20. [ ] Capture baseline build/test/profile/recording evidence or explicitly record unavailable evidence; finalize dependency map.

## 2A. Implement audio foundation

21. [ ] Define audio source descriptor with sample rate, channels, PTS and host offset.
22. [ ] Implement bounded PCM reader and persistent sample-rate conversion.
23. [ ] Handle timestamp gaps and overlaps without silently shifting media.
24. [ ] Implement disk-backed chunked enhanced-voice writer with atomic completion.
25. [ ] Verify DeepFilterNet3 format, model availability, state continuity and latency compensation.
26. [ ] Implement one studio voice chain with high-pass, denoise and conservative adaptive dynamics.
27. [ ] Implement EQ/de-essing with bypass for inappropriate speech spectra.
28. [ ] Implement chunk-boundary continuity and end-of-stream flush.
29. [ ] Implement loudness measurement and true-peak limiting with −14 LUFS default.
30. [ ] Implement explicit raw-audio fallback and honest processing status.

## 2B. Implement sound engine

31. [ ] Define typed sound cue with press/release, event ID and source timestamp.
32. [ ] Decode Mechvibes v2 key-down and key-up ranges independently.
33. [ ] Map physical macOS virtual keycodes and left/right modifiers correctly.
34. [ ] Align sample attacks, normalize format and cache immutable sample data.
35. [ ] Define explicit class-based fallback for unsupported physical keys.
36. [ ] Capture physical key-up and modifier transitions; ignore OS repeats as new physical presses.
37. [ ] Suppress sensitive key identities and shortcut cues during secure input.
38. [ ] Generate deterministic per-event variation, gain and light panning.
39. [ ] Schedule overlapping key sounds and click sounds at exact mapped sample indices.
40. [ ] Restore licensed mouse/touch assets; preserve attribution and voice-aware SFX level.

## 2C. Implement audio mixer and transport

41. [ ] Define immutable audio edit snapshot with independent revision and cache key.
42. [ ] Implement arbitrary-position windowed mix of source mic, system, music and SFX.
43. [ ] Implement bounded output PCM cache and seek-driven prefetch.
44. [ ] Apply non-destructive cut and speed mappings to audio and cues.
45. [ ] Implement click-free splice and music-bed looping with short crossfades.
46. [ ] Implement speech-aware music/SFX ducking without changing source tracks.
47. [ ] Implement AVAudioEngine playback with bounded preloaded windows.
48. [ ] Implement shared host-clock transport and output-latency compensation.
49. [ ] Implement aligned raw-to-enhanced crossfade, rejecting stale results.
50. [ ] Connect audio mixer to preview and export without blocking on full-program mixing.

## 2D. Implement video decode and Studio playback

51. [ ] Define timestamped decoded frame and explicit ownership lifetime.
52. [ ] Implement serial video decoder worker decoupled from display ticks.
53. [ ] Implement bounded video frame queue with latest-seek generation cancellation.
54. [ ] Use hardware-assisted decode where supported; log fallback and failures.
55. [ ] Implement PTS-aware frame selection for variable-frame-rate and held source frames.
56. [ ] Handle reverse seek, far-forward seek, cuts and clip changes without unbounded decoding.
57. [ ] Implement independent webcam decoder with bounded resource budget.
58. [ ] Implement display-linked scheduler consuming only ready frames.
59. [ ] Publish lightweight playhead UI state without rebuilding the timeline view per frame.
60. [ ] Integrate transport start/pause/seek with synchronized audio and visible buffering state.

## 2E. Implement authoritative project and intent

61. [ ] Define source-time edit model and deterministic source/output mapping.
62. [ ] Separate user intent, source metadata and derived-track snapshots.
63. [ ] Define stable IDs and suppression rules for automatic edits.
64. [ ] Implement transactional timeline mutations and targeted invalidation.
65. [ ] Implement ordered event normalization and focus evidence provenance.
66. [ ] Build one click/typing/scroll/application-switch intent analyzer.
67. [ ] Group nearby interactions into stable focus events without cursor wandering zooms.
68. [ ] Resolve typed field focus from verified AX/visual evidence; never invent a field.
69. [ ] Implement asynchronous analysis enrichment with bounded work and stale-result rejection.
70. [ ] Publish one authoritative derived plan and preserve manual overrides.

## 2F. Implement camera, zoom and crop

71. [ ] Define analytic motion segments with position, log scale and boundary derivatives.
72. [ ] Implement quintic stationary transitions and boundary-matched interrupted motion.
73. [ ] Implement bounded target framing with explicit feasible anchor and scale constraints.
74. [ ] Implement automatic zoom anticipation, stable typing holds and exact exit.
75. [ ] Implement manual Classic and Loupe zoom with stable timeline IDs and edit commands.
76. [ ] Implement crop state machine using verified browser viewport geometry.
77. [ ] Reveal chrome before address-bar/control interaction and focus actual typing target.
78. [ ] Restore content-only crop after release; handle unknown viewport with full frame.
79. [ ] Implement unified crop/zoom/source/canvas transform and inverse mapping.
80. [ ] Ensure aspect ratio changes reframe without stretching or camera drift.

## 2G. Implement cursor, effects and shortcuts

81. [ ] Implement timestamped cursor position and shape track.
82. [ ] Implement one configurable cursor smoother with Smooth, Medium, Rapid and None.
83. [ ] Preserve click position and timing through smoothing and coordinate conversion.
84. [ ] Implement idle hide/reappear with deterministic fade and optional loop closure.
85. [ ] Implement cursor skin resolution, size and hotspot mapping.
86. [ ] Implement localized click ripple with continuous expansion and fade.
87. [ ] Implement bounded motion blur based on actual camera/cursor velocity.
88. [ ] Build keyboard shortcut event classifier for supported modifier combinations.
89. [ ] Implement cached native-symbol overlay, 180 ms entry, 3.22 s hold and 600 ms exit.
90. [ ] Integrate overlays with safe margins, crop, cuts, export and secure-input suppression.

## 2H. Implement shared rendering and visual restoration

91. [ ] Implement immutable render snapshot and one pure frame evaluation contract.
92. [ ] Build Metal compositor for background, content, cursor and overlays.
93. [ ] Implement pooled textures and pixel buffers with bounded in-flight ownership.
94. [ ] Implement correct color conversion, orientation and aspect-preserving sampling.
95. [ ] Restore system wallpaper and bundled painting resource resolution.
96. [ ] Restore gradients, custom image import, opacity and blur.
97. [ ] Restore canvas presets, frame, corner radius, padding, shadow and insets.
98. [ ] Persist imported assets into project bundles and restore after reopen.
99. [ ] Implement separate preview and export resource ownership with shared semantics.
100. [ ] Replace old upscaler with optional measured high-quality scaling outside critical playback.

## 2I. Implement camera layouts and local intelligence

101. [ ] Implement screen-only, overlay, split, fullscreen-camera and cutout layouts.
102. [ ] Implement stable focus-aware webcam placement with feasible-target avoidance.
103. [ ] Implement local face tracking and timestamped framing without per-frame inference.
104. [ ] Implement speech-aware webcam visibility with stable transitions.
105. [ ] Implement on-device person segmentation and cached mask retrieval.
106. [ ] Integrate local speech recognition adapter with explicit readiness/errors.
107. [ ] Implement source-aligned words, captions and cached animated text.
108. [ ] Implement reviewable filler/silence suggestions and transcript-to-cut commands.
109. [ ] Implement privacy mask track with verified sensitive evidence and manual override.
110. [ ] Map all layouts, captions, masks and shortcuts for 16:9, 1:1 and 9:16.

## 2J. Implement capture recovery and export

111. [ ] Preserve display/window/area capture and existing permission flow.
112. [ ] Align microphone, screen, system audio, webcam and input clocks.
113. [ ] Implement consistent pause/resume mapping across tracks.
114. [ ] Implement recoverable media checkpoints around two-second intervals.
115. [ ] Recover interrupted projects without modifying originals or inventing missing media.
116. [ ] Preserve USB device capture and verified device mockup metadata.
117. [ ] Implement hardware-assisted export with shared frame evaluator and bounded writer.
118. [ ] Mux finalized audio and video with exact timestamps, frame count and duration.
119. [ ] Support 1080p/4K 30/60 FPS H.264/HEVC and supported transparency formats.
120. [ ] Implement cancellation, progress, failure cleanup and atomic successful export.

## 2K. Integrate compatibility and controls

121. [ ] Implement schema migration for prior projects and preserve raw media.
122. [ ] Preserve manual zoom IDs, cuts, settings, backgrounds and sound selections.
123. [ ] Reconnect existing TimelineStrip and related lanes to new backend without visual redesign.
124. [ ] Reconnect existing inspector bindings for restored functionality; defer visual redesign.
125. [ ] Preserve recording bar, waveform and reversible hide behavior.
126. [ ] Adapt existing LumenControl tools to authoritative edit commands.
127. [ ] Preserve MCP schema, permission gates, audit logs and revision conflict protection.
128. [ ] Preserve LumenActuator and CLI behavior through shared services.
129. [ ] Implement one resource resolver for installed app, checkout and project assets.
130. [ ] Add deterministic backend instrumentation for timing, queue depth, drops and analysis work.

## 3. Edit and refactor

131. [ ] Remove old voice-mode branching from active DSP while decoding legacy settings.
132. [ ] Remove obsolete full-recording mixer and condition-variable waits from playback.
133. [ ] Remove old arbitrary typing-sample fallback and key-down-only cue generation.
134. [ ] Remove old duplicate recording-stop and editor zoom planners.
135. [ ] Remove redundant 480 Hz baked camera and crop tracks where analytic replacement covers behavior.
136. [ ] Remove duplicate smoothing and legacy floating camera path.
137. [ ] Remove old crop transforms and inverse mappings from active renderer.
138. [ ] Remove old decoder-on-display-tick path and obsolete seek polling.
139. [ ] Remove obsolete render caches and upscaling path from active compositor.
140. [ ] Remove unnecessary whole-recording analysis jobs from open and playback.
141. [ ] Consolidate timeline invalidation by affected track and revision.
142. [ ] Consolidate save and external MCP edit conflict handling.
143. [ ] Consolidate source time and output time conversions.
144. [ ] Consolidate sound pack directories and ensure license files ship with assets.
145. [ ] Consolidate wallpaper and canvas resource lookup and fallback handling.
146. [ ] Remove unused imports, dependencies, dead settings and unreferenced old code.
147. [ ] Reconcile Package.swift target graph and tool dependencies.
148. [ ] Update architecture documentation and migration notes to match actual code.
149. [ ] Review source diff for unrelated UI changes and accidental feature removal.
150. [ ] Confirm exactly one active implementation for each replaced subsystem.

## 4. Validate build and static correctness

151. [ ] Validate plan numbering and retain original plan history.
152. [ ] Run swift package dump-package and verify target graph.
153. [ ] Run swift build on macOS 15 Apple Silicon; capture full output.
154. [ ] Run Swift 6 typechecking for all active targets.
155. [ ] Run configured lint or documented repository static checks; capture output.
156. [ ] Build and link Metal shaders with Xcode toolchain.
157. [ ] Run swift test --no-parallel and capture output.
158. [ ] Build release via Tools/make-app.sh and capture output.
159. [ ] Verify packaged code signature and bundle identity.
160. [ ] Audit packaged wallpapers, cursor assets, audio files, licenses, models and shaders.
161. [ ] Launch actual release app with required permissions and capture launch evidence.
162. [ ] Resolve all build, typecheck, lint and packaging failures; rerun affected checks.

## 5. Test unit, integration and real runtime

163. [ ] Test PCM format conversion, timestamp gap repair and chunk continuity.
164. [ ] Test neural latency compensation, loudness, true peak and speech preservation.
165. [ ] Test key-down/up sample mapping, modifiers, repeat handling and secure suppression.
166. [ ] Test sample-accurate cue scheduling, overlaps and cut/speed mapping.
167. [ ] Test arbitrary-position audio window, seek, cancellation and crossfade.
168. [ ] Test video frame selection, decoder cancellation and queue bounds.
169. [ ] Test deterministic intent and stable manual edit preservation.
170. [ ] Test camera monotonicity, endpoint accuracy, zero hold drift and retarget continuity.
171. [ ] Test browser crop/reveal with real Chrome recordings and verified AX geometry.
172. [ ] Test field focus during real VS Code and Terminal typing.
173. [ ] Test cursor hotspots, all styles, motion blur and ripple alignment.
174. [ ] Test shortcut overlays for Command-Z, Command-C and multi-modifier combinations.
175. [ ] Test all restored wallpaper/canvas controls in packaged app and exported frames.
176. [ ] Test all webcam layouts, local cutout, face tracking and silence visibility.
177. [ ] Test aspect ratio changes and manual zoom edits via existing timeline UI.
178. [ ] Test captions, transcript sentence cuts, silence and filler edits with real speech.
179. [ ] Test capture pause/resume and crash recovery through actual forced termination.
180. [ ] Test USB recording with supported real device and mockup accuracy.
181. [ ] Test preview/export frame equivalence, audio mux, 1080p/4K outputs.
182. [ ] Test MCP permissions, schema, concurrent edits, record/edit/export and old projects.

## 6. Edge cases, errors and performance

183. [ ] Exercise zero-length, silent, missing-audio and audio-only source cases.
184. [ ] Exercise corrupted media, absent models, missing assets and permission denial.
185. [ ] Exercise rapid seek, play/pause, undo/redo and cancellation under concurrent analysis.
186. [ ] Exercise browser full screen, address bar, webpage input and unavailable AX evidence.
187. [ ] Exercise high-speed typing, held modifiers, repeated keys, overlapping sounds and secure fields.
188. [ ] Exercise near-edge targets, short clips, overlapping manual zoom and late interactions.
189. [ ] Exercise variable frame rate, imported clips, multiple displays and Retina scale changes.
190. [ ] Exercise low storage, interrupted export, interrupted recording and recovery.
191. [ ] Measure actual 60 Hz presentation for controlled 60-second 1080p workload; require zero drops.
192. [ ] Measure p99 presentation interval, warm/cold seek and first-frame latency.
193. [ ] Measure 30–60 minute memory stability and A/V drift on Apple Silicon.
194. [ ] Measure 1080p60 export throughput and compare output quality on defined fixtures.
195. [ ] Listen to real recordings with whisper, normal speech, fans and keyboard; document residual limitations.

## 7. Final audit and proof

196. [ ] Re-read mission and inspect final implementation against each original core feature.
197. [ ] Re-read all 201 steps and match each checked item to independently reproducible evidence.
198. [ ] Attach complete passing build, typecheck/lint and test logs for exact PR head.
199. [ ] Capture real running Studio screenshots and a short real screen recording of interaction and export.
200. [ ] Review final diff, PR CI status, migrations and MCP preservation; document all remaining risks.
201. [ ] Open or update unmerged PR with final evidence and mark complete only if every step is proven.

## Implementation log — 2026-11-25

User explicitly deferred testing and requested direct reconstruction. The 201 original evidence gates remain unchanged; code existence is not proof of successful build or runtime behavior.

- `1c2e38e`: independent physical keyboard down/up cues, deterministic fallback and modifier capture.
- `91cbfc0`: replacement finite-shot camera solver; removed 541 net lines of old camera implementation; browser reveal during typing enabled by default.
- `6dd49ba`: restored existing inspector canvas/wallpaper/webcam controls, project-local imported background, removed old upscale passes from active compositor. Standalone legacy upscale interfaces retained for compatibility.
- `c373516`: independent preview decode/presentation loops, latest-frame bounded queues, seek generations and capped 60 Hz scheduling.
- `0047d2d`: output-time shortcut events and native-symbol fading/blur overlay shared by renderer.
- `07a0be9`: bounded arbitrary-position raw audio windows, shared SFX scheduling, key bank cache, conservative voice-chain adjustments.
- `ea48c7a`: replaced full-mix transport wait and whole-tail PCM allocation with four-second audio queue, cancellable seek windows, generation checks and noninterrupting final-mix takeover.
- This commit: legacy music compatibility in provisional playback, trimmed keyboard cue filtering, clip/crop replan invalidation and undo/redo handling.

The larger planner/analysis/crop/export rebuild, standalone legacy code retirement, full asset-specific licensing audit, and physical Mac validation are incomplete. The existing offline final mastering path still operates on the whole program; only the preview scheduling and seek path are bounded. Preview raw audio may differ from mastered export until the final program becomes available. No build or tests were executed in this implementation pass, per user request. Main remains unchanged; PR #31 remains draft and unmerged.

## Validation re-opened — 2026-11-25

The user requested validation of the entire backend, not another camera-only rewrite. The preceding implementation is partial, and prior evidence requirements are active again. For commit `9bdfce3`, Swift verification run [462](https://github.com/duggal1/lumen/actions/runs/45569056429) reported successful Metal compiler check and debug build; unit/integration tests were still running when inspected. These results do not apply to the subsequent commit.

### Cross-subsystem findings and repair evidence

- Auto-zoom: stop-time planning did not apply suppression; disabling auto zoom retained generated shots. Both entry points now respect suppression and manual-only mode. Added regressions; existing motion/accuracy tests remain authoritative.
- Editor: a visual edit could be overwritten by an in-flight complete timeline derive; cancelled audio invalidation could be lost. Restart pending derives on changed intent and carry pending audio invalidation across cancellation.
- Export: primary export could consume stale preview derivations; aspect variants ran synchronously on the UI actor. Export now derives all variants against one frozen input snapshot on a cancellable worker.
- Privacy: shortcut labels previously accepted unresolved AX slots; now require resolved nonsecure evidence. Known secure key presses and paired releases no longer produce per-key sounds. Raw key metadata and unknown-context privacy still require an explicit audit.
- Robustness: validate malformed sample slices and time-map input before numeric conversions; dense map remains memory-intensive and the 24-hour safety bound is not a supported performance claim.

### Remaining release gates (in execution order)

1. Run the existing full macOS suite without deleting or weakening failures. Resolve compiler, test, and packaging failures on the exact final SHA.
2. Auto zoom and crop: validate every existing timing, retarget, focus, manual override, browser typing and crop test. Measure real Chrome/Terminal/VS Code captures. Retain manual edits and deterministic IDs.
3. Audio: verify exact sample onset and physical edges, mute/gain/duck, cut/ramp and music-loop seams, seek/refill, processed takeover, missing devices, denoiser and whisper quality. Replace whole-program enhanced PCM with disk-backed bounded processing only after parity evidence.
4. Preview/renderer: verify source frame selection, latest-seek generation, drawable rejection, privacy masks, effects, captions, all canvas/layout controls and preview/export equivalence. Measure 60 Hz/drop/memory on M1 8 GB.
5. Capture/recovery: prove display/window/area, pause/resume, device clocks, USB and forced-kill recovery using real media; verify originals are intact.
6. Export: prove cancellation, destination preservation, output frame/audio timestamps, H.264/HEVC/GIF/alpha support, aspect variants and throughput. Inspect real outputs, not only headless tests.
7. Project/MCP/CLI: test migrations, external revisions, concurrent edits, undo/redo, permissions, all tool contracts and packaged assets/licenses. Delete legacy paths only after equivalent behavior is proven.
8. Record exact SHA, logs, measurements, real runtime evidence and residual limitations. Keep draft and unmerged until the evidence passes.

No claim of flawless behavior or completion is made. The original 201-step checklist is retained; implementation-only steps are not marked verified.

Additional audit repairs: Exporter now propagates cancellation into its mixer, reports reader/encoder failures rather than silently dropping audio, and stages GIF files before replacing the destination. ProjectSession now publishes analysis evidence only while holding the matching generation lock, including the final result. These code changes are not yet validated by the new CI run. Multi-file export sidecar atomicity, real hardware capture/recovery, and long-recording mastering remain open.
