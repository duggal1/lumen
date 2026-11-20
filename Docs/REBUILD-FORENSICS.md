# REBUILD-FORENSICS — Lumen, Nov 16–19 2026 (audit of the last 3 days)

**Auditor:** cw-2839 (Forensics) · **Read-only audit**, no builds, no test runs, no git writes.
**Baseline:** `d3c41e4` (2026-11-15 20:01 +0530, "Update LUFS expectations to minus fourteen") — last commit before the window.
**HEAD / subject:** `0be9156` (2026-11-19 19:23 +0530, "Integrate video editing tools and fix protocol accuracy").
**Range:** `d3c41e4..0be9156` = **46 commits**, 243 files, **+35,523 / −2,276** (Sources +10,590/−1,816 · Tests +14,069/−68 · rest is promo/sandbox/docs/assets).
**Working tree during audit:** agents 1 (zoom-camera) and 2 (zoom-render) had **uncommitted edits** in `Sources/LumenDirector/Camera.swift` (20:21), `Sources/LumenRender/Renderer.swift` (20:22), `Sources/LumenCore/Motion.swift`, `Sources/LumenDirector/ZeroPhase.swift`, `Accuracy.swift`, `LiveCamera.swift`, and later agents 3 (audio: `Sources/LumenAudio/{DeepFilterNet,Mixer,ProcessedVoice}.swift`, `Sources/LumenExport/{Exporter,ProjectSession}.swift`) — the rebuild was landing while this report was written. **This report pins evidence to the committed state `0be9156`; every line number below is from `git show 0be9156:<path>` unless marked "worktree".** AGENTS_COMMS.md (untracked) untouched.

Honesty header: three reported symptoms ("shrinks", "stretches/compresses", "floats up and down") and the mic/voice story are all reproducible from the diffs. "Floats up and down" is the least pinned-down; rated medium at best. Everything else is high confidence, with file:line proof. UNVERIFIED items are marked.

---

## 1. Commit census, grouped by subsystem (one line each)

Window is 46 commits. Focus commits in **bold**. Author of almost everything: harshit duggal (agents acting for him).

### 1a. Zoom / camera / director (the core failure zone)
| sha | date | what it did |
|---|---|---|
| `23ba6c4`–`a9e5c0c` | 11-16 | TCC permission reads moved off main + cached (capture/UI, not camera) |
| `088db2a` | 11-16 | Throttle cursor sampling, bound stop drains (capture) |
| `9cbce19` | 11-16 | "music timeline tests and camera motion refinements" (313 LOC) |
| `1ed4e4b` | 11-16 | "Fix camera jerk at transition to moving hold" (handoff jerk) |
| `b3e0305` | 11-16 | Remove temporary camera jerk diagnostic test |
| `2f6664b` | 11-16 | Keep max zoom as a hard cap (1 line, planner) |
| `21103ea` | 11-16 | Update hover intent contract in zoom test |
| `0549d4b` | 11-16 | Feed marker beats into the auto zoom planner (+112) |
| `81cbc4e` | 11-16 | Test marker zoom and control framing |
| `2531110` | 11-16 | Record marker zoom architecture decision (docs) |
| `dd90bbe` | 11-16 | Frame the text field instead of chasing the caret (planner rewrite, ±145) |
| `59efd65` | 11-16 | Key the zoom plan cache on what the planner reads (+65 derive) |
| `da792f1` | 11-16 | Remove camera knobs nothing reads (−11) |
| `8260753` | 11-16 | Always return to full frame at the end (camera +21) |
| `050bb3c` | 11-16 | Sharpen pixel upscaler, headless quality tests (+Upscale.metal) |
| `ec28606` | 11-16 | Record zoom audit and its resolution (issue.md rewrite, +375) |
| `1699384` | 11-16 | **"Harden zoom camera and brutal headless accuracy suites"** — sort scenes by `event` not `on`, join bridged scenes onto the value on the track instead of recomputing, pin tail return to the furthest hold; Camera +37/−7, BrutalSweep +517 (new), BrutalZoomInvariants +314 (new) |
| `2470b47` | 11-17 | **"Add intelligent Area crop"** — `view = src/scale` → `view = cropSize/scale` in `contentFS`, crop-aware `toCanvas`, offline keyframed SmartCropPlanner+BrowserChrome detector (−/+144), BrutalSmartCropTests (11-17 00:54) |
| `8a49980` | 11-17 | **"Merge six agent streams"** (squash onto main) — CameraTilt.swift **new** (133 LOC: lean/float/reveal, homography warp), CinematicZoomStress/Motion tests, Camera 191→421, C-core-integration |
| `9983829` | 11-17 | **"Make auto zoom and audio studio accurately flawless"** — **DF3 Float32→PCM16 fix** (voice chain was silently degrading), voice/mix revision bumps, voiceBoost +2.5 dB, ZoomTimingAccuracy(Fuzz)Tests, VisualAutofocus +404, Camera 421→505, TypingFocus +127 |
| `09c01b1` | 11-18 | **"Make zoom and audio flawless with brutal headless verification"** — removes the `.float` Lissajous tilt wander; adds mechvibes typing pack, Camera 505→509, CameraAccuracy(Fuzz)Tests, Agent1BrutalZoomTests, UnifiedFocusPage +360 |
| `e341f74` | 11-19 | **"Integrate five brutal quality audits and fixes"** — VoiceProcessingDiagnostics, mixRevision v4→v5, Camera 509→519 (centerOffset applied once), toCanvas inverseHomography, BrutalZoomQ1Tests, TypingFocusQ1Tests |
| `1992ded` | 11-19 | Wire shared activity/crop settings into pipeline (schema 4→5, commands for crop/activity, planner activity shots) |
| `d6e1aae` | 11-19 | **Wire viewport crop + activity grids through director derive** — `DenseCropTrack` (480 Hz), F1 crop-normalised camera channels, `FrameState.crop` |
| `8852f0b` | 11-19 | **"Add AX viewport recording and crop-aware rendering"** — Renderer: `cropSize = visible.w * sc` (sampling stops tracking zoom), Layout crop-following `screenRect`, SmartCropPlanner 281→49 |
| `e181e0d` | 11-19 | Browser crop types + Remotion promo (+5,189; promo/ ≈4,340 of it) |
| `0be9156` | 11-19 | **"Integrate video editing tools and fix protocol accuracy"** — cropSize `*=` bug fixed via `baseView` (canvas-aspect, still mismatched), `st.crop` preferred over `cropRect`, MCP/Tools+VideoEdit +658, deleted ~19 crop-era tests, Camera 519→557, Decisions.md documents it |

### 1b. Audio chain
| sha | what |
|---|---|
| `2470b47` | SpectralGate noise-estimate capped at `gatePower` (was converging on sustained speech) — **no cache-revision bump** |
| `050bb3c` | (upscaler, not audio) |
| `9983829` | **DeepFilterNet Float32→PCM16** (the CLI panicked "TooWide" → era of silent SpectralGate); `VoiceDenoiseEngine`/`lastEngine`; voice `v15→v16`, mix `v3→v4`; `+2.5 dB voiceBoostDb` default (Studio.boosted); AudioStudioQualityTests |
| `09c01b1` | mechvibes typing pack + `TypingPacks` attack-trim; KeyboardAudioTests, BrutalAudioRenderAdversarial, TypingFocus*Tests; `Motion.peakJerk`; `Mixer` sfx drop |
| `e341f74` | `VoiceProcessingDiagnostics` fallback counters; mix `v4→v5`; whoosh SFX 0.4 multiplier removed; `TypingPacks` 110–114 keycodes + F4 |
| `0be9156` | `Mixer.swift` whoosh amp simplification; AudioStudioQualityTests reworked |

### 1c. Capture / activity / crop plumbing (11-19 afternoon, mostly one working session)
`1bde05a` viewport logs → recovery/CLI · `1c08516` restore ActivityAnalyzer + Metal ActivityGrid shader, VisualAutofocus 444→**76** (old detector deleted, replaced by activity-grid shots) · `9789176` Swift 6 concurrency fix in analyzer · `b543601` Metal analyzer over concurrent fallback · `c8fe561` CLI separators · `e181e0d` ViewportRecorder (AXWebArea → 480 Hz track).

### 1d. MCP / video-edit / protocol (today, 19:23)
`0be9156` — `Tools+VideoEdit.swift` (+658), `MusicBed.swift` (+183), `MCP.swift` (+61), `RawFootage`-era models, +5,000 lines of MCP/video-edit tests, deletes 131-line `BrutalSmartCropTests` crop reveals, 76-line `CoreZoomValidationSmartCrop`, 28 lines of `BrutalZoomQ1Tests`; Decisions.md documents the deletions.

### 1e. Other
`23ba6c4`–`d27c69c` (11-16 batch: permission caching, cursor sampling, recorder bar), `a7dea0d` (music title suffix), `c5fabe4`/`7dcde2f` (gitignore), `443d96a`/`daa95d9` (music name), `38f97df` (music lanes delete command), `050bb3c` (upscaler), `7754390` (icon), `131a28c` ("review gaps" = CinematicRender3DGPUTests stabilization only), `6a9a7c5` (true merge of PR #23; parents `2470b47 131a28c` — the agent-stream work reached main only here), `1c08516`/`9789176`/`b543601`/`c8fe561` (analyzer saga), `0be9156` Decisions/Docs.

---

## 2. Which files grew, and is the growth correctness or complexity

Endpoint counts (`git show d3c41e4:<f> | wc -l` → `wc -l` at 0be9156). **Two files peaked mid-window and were cut hard** (VisualAutofocus 444→76, SmartCropPlanner 281→49); nothing else shrank meaningfully.

| file | d3c41e4 | 0be9156 | Δ | verdict |
|---|---|---|---|---|
| Sources/LumenDirector/Camera.swift | 191 | 557 | **+366 (2.9×)** | **complexity** — quintic/Hermite/jerk-bridge/continuity-runway machinery; each fix needed the next |
| Sources/LumenDirector/Planner.swift | 339 | 660 | +321 | mixed — real correctness (field-framing, marker beats) wrapped in more passes |
| Sources/LumenRender/Renderer.swift | 1220 | 1419 | +199 | mixed — crop plumbing correct-intent, mis-implemented; reveal shrink |
| Sources/LumenDirector/Director.swift | 448 | 625 | +177 | mostly necessary (crop/activity wiring) |
| Sources/LumenDirector/Crop/CropPlanner.swift | 0 | 319 | +319 new | new machinery, honest goal, unproven at runtime |
| Sources/LumenDirector/Activity/ActivityShotBuilder.swift | 0 | 208 | +208 new | new machinery |
| Sources/LumenRender/CameraTilt.swift | 0 | 146 | +146 new | **complexity** — tilt/homography/reveal; "shrink" lived here |
| Sources/LumenUI/UnifiedFocusPage.swift | 0 | 360 | +360 new | UI surface, not core |
| Sources/LumenControl/Tools+VideoEdit.swift | 0 | 658 | +658 new | MCP surface; unrelated to reported breakage |
| Sources/LumenProject/MusicBed.swift | 0 | 183 | +183 new | feature |
| Sources/LumenCore/Motion.swift | 36 | 63 | +27 | `filmJerk`, `peakJerk` — solver apparatus |
| Sources/LumenDirector/ZeroPhase.swift | 34 | 34 | 0 | zeroPhaseSmooth survives |
| Sources/LumenDirector/VisualAutofocus.swift | 0 (new 11-17) | 76 | peaked 444 (1c08516 cut it) | replaced by activity-grid shots |
| Sources/LumenDirector/SmartCropPlanner.swift | 0 (new 11-17) | 49 | peaked 281 | offline planner deleted; AX path replaces |
| Sources/LumenAudio/** (Mixer, ProcessedVoice, Studio, DeepFilterNet, SpectralGate)** | 888/183/270/122/60 | 919/187/283/166/66 | +31/+4/+13/+44/+6 | small, mostly **correctness** (PCM16, caps, boost, diagnostics) |
| Sources/LumenRender/Upscaler.swift | 131 | 169 | +38 | sharpness tuning + honesty fixes |

Test suite: **+14,069 lines across 121 files**; tests grew ~2× faster than product code in this window. Bucket: (i) quintic-solver internals (deleted soon), (ii) crop/activity/crop-pipeline tests (mostly new coverage), (iii) MCP/video-edit E2E (≈+3,200 lines, orthogonal). Net deletion vs baseline: only `AutoZoomRegressionTests.swift` (−10) and `AudioAssetsTests.swift` (−1); in-window test churn deleted ~19 named crop-era tests (documented in Decisions.md).

---

## 3. Zoom path — evidence

### 3.1 The sampled view ≠ the drawn quad (introduces *stretch/compress*)
- **Before the window** (`contentFS`, pre-`2470b47`): `view = u.src / u.scale` (`git show 2470b47 -- Sources/LumenRender/Shaders/Shaders.metal`), drawn quad = source-aspect content rect ⇒ uniform sampling. Correct.
- **Introduced `2470b47`** (11-17 00:54):
  ```diff
  -    float2 view = u.src / u.scale;
  +    float2 view = u.cropSize / u.scale;
  ```
  and in `scene()`:
  ```swift
  let cropSize = SIMD2<Float>(Float(cropBounds.width), Float(cropBounds.height))   // crop #aspect, not source aspect
  ```
  and `toCanvas` gained `crop:` with `view = cropSrc / max(scale,1)` while the drawn quad stays **source-aspect** (`ZoomTransform` fits source aspect into the canvas; `Geometry.content` = `transform.videoRect`). ⇒ whenever the crop aspect ≠ source aspect (any browser AXWebArea) the zoom is anisotropic. **First commit that broke it.**
- **Broken worse `8852f0b`** (11-19 15:23):
  ```swift
  // No CropSpace: with a source-sized crop the visible rect is the crop.
  let visible = cropSrc
  let cropSize = SIMD2<Float>(Float(max(visible.w * sc, 1)), Float(max(visible.h * sc, 1)))
  ```
  shader divides by `u.scale` ⇒ **view == cropSrc regardless of `sc`** — zoom could no longer magnify; scale only moved a clamped centre. Shipped ~4 h before HEAD. Decisions.md documents: *"passing `cropSize = crop * scale` made the visible region independent of zoom … produced the 22.15M ghost step."*
- **"Fixed" `0be9156`** (11-19 19:23) — Renderer.swift:958–959 (`git show 0be9156`):
  ```swift
  let baseView = CropSpace.baseView(crop: cropSrc, aspect: tl.style.aspectRatio)   // aspect == CANVAS aspect
  let cropSize = SIMD2<Float>(Float(max(baseView.w, 1)), Float(max(baseView.h, 1)))
  ```
  Drawn quad (`contentRect`, from `ZoomTransform`) is **source-aspect**; sampled view (`baseView/scale`) is **canvas-aspect**. E.g. 16:10 capture into 16:9 canvas ⇒ x-scale 1728/1920 = 0.90 vs y-scale 1080/1080 = 1.0 ⇒ the picture is uniformly ~10 % narrower horizontally than it should be, at every zoom level, with no crop at all (`baseView` always runs because `tl.style.aspectRatio` = `customAspect ?? canvas.ratio`, never nil). The comment in-code ("matches visible in BOTH dimensions even when the crop and frame aspects differ", Director.swift:554–556 and Decisions.md "Prompt 3") is **false for the pixels that ship**: `CropSpace.visible` matches the *base view*, but the quad it is drawn into is not the base view.
- **Overlays disagree with the picture** (decided `2470b47`, never fixed): `toCanvas` (Renderer.swift:66-76 @0be9156) maps cursor/click/highlight points with `view = cropSrc / s` — the **raw crop**, not `baseView`. Under a browser crop, rings and the cursor land on different pixels than the content drawn by `contentFS`.
- **Fix in flight** (uncommitted, worktree, cw-3185): `drawAspect = g.content.z/g.content.w`, `baseView(crop: aspect: drawAspect)`, and a single `Geometry.containedCenter` clamp — that is the correct shape of the fix, but it is NOT on `main` at the time of writing. (Verified by reading the modified Renderer.swift at 20:22.)
- **Confidence: HIGH** that `2470b47/8852f0b/0be9156` are the stretch/compress class; **MEDIUM** on which one the user "feels" (8852f0b was live for ~4 h with zoom completely dead; 0be9156 is the current release).

### 3.2 The camera quintic/jerk solver — why zoom behaves like a floaty rig
`Sources/LumenDirector/Camera.swift` line counts (via `git log --follow` + `git show <sha>:… | wc -l`):

`430 f04ada7f` (11-08) → `461 0b002c99` (11-14) → **`191 519c0317`** (11-14, "Replace segmented camera moves with coherent filtered targets" — the file once *dropped* to 191) → `286 6975e74` (11-16) → `313 9cbce19` → `326 8260753` → **`356 1699384`** (11-16, "Harden zoom camera") → **`421 8a49980`** (11-17 merge, +129: maxScale hard cap in target, lead-in grows with magnification & jerk floor, bounded continuity slopes, Hermite bridge) → **`505 9983829`** (+124: return-room/minHold/bridgedRunLimit/forced return runway) → **`509 09c01b1`** (+32: tilt lean only) → **`519 e341f74`** (+20: centerOffset applied once) → **`557 0be9156`** (+126: crop-normalised channels, F1 clamp). Net **+366 vs d3c41e4**, nearly all jerk-runway/Hermite/continuity-bridge apparatus; the 430→356→509→557 arc in the brief is the post-11-16 slice of it.

Mechanism that produces float/stop-start, quantitatively: rest-to-rest quintic + Hermite bridge with continuity slopes bounded to `|Δ|/T*1.5 + 0.02` (Camera.swift:291-330 @0be9156) and camera `1e6` vs film `7e5` jerk budgets (`MotionLimits.cameraJerk`/`filmJerk`, Motion.swift:81/87). Every added bound spawns the next failure (44→129→124→32→20→126 LOC of whack-a-mole). Death by correctness fixes to a design that needs deleting, not tuning.

Float-specific suspect #1 (**removed 09c01b1**, live 11-17 17:46→11-18 02:47): `TiltMode.float` — a causeless Lissajous wander injected into yaw/pitch:
```swift
yawTarget = p.floatDeg * (0.6*sin(2π*0.11*t + φ0) + 0.4*sin(2π*0.07*t + φ1))   // 8a49980, Camera.swift
```
"*causeless left/right/top wander*" (their words, 09c01b1). Default `tilt = .off`, so only users on `cinematic`/manual float felt it. Not the current default.

Float-specific suspect #2 (**shipped, `9983829`, persists**): `.cinematic` preset ⇒ `tilt = .lean`; `pitchTarget = clamp(-track.vy * scale * 9, ±6°)` with a spring (omega 5) on cursor vertical velocity. Moving the mouse up/down literally rocks the content plane up/down — **this is the strongest match for "zoom floats up and down" as of HEAD**, plus reveal mode's `0.92→1.0` breathing (see 3.3). Default preset is `.balanced` (`.off`), so UNVERIFIED which preset the user ran.

Float-specific suspect #3 (**new in F1, 11-19, persists**): the dense **480 Hz viewport crop track follows AXWebArea every sample**; camera channels are normalised into the *current tick's* crop, and the sampled window moves with every crop jitter even at scale 1.0. AX delivers integer-frame rects at UI cadence; the 480 Hz bake lerps between them — a visible up/down bob at the element-update rate whenever the browser chrome/scroll/keyboard changes. Introduced `1bde05a`/`8852f0b`/`e181e0d`, wired in `d6e1aae`+`0be9156`. **Medium-high confidence this is the floating the user sees on 11-19 nightly.**
**Confidence: MEDIUM for #3 as the live cause, MEDIUM-LOW for #2; #1 is dead code.**

### 3.3 "Zoom shrinks" — CameraTilt reveal (the 0.92 content-rect shrink)
`CameraTilt.revealScale` (CameraTilt.swift:50-58): reveal mode draws `contentRect` at **0.92** of the fitted size and grows it to 1.0 as tilt settles (`revealScaleDrop = 0.08`, line 24). Applied in Renderer.swift:926-932 @0be9156 ("Reveal's 0.92 entrance scale shrinks the framed video inside the canvas"—their comment). Not the default (`tilt = .off`) but re-enabled whenever `.reveal` is chosen; `.cinematic` does NOT use it. Also ships in `CinematicRender3D*` tests. Secondary "shrink" contributor: `ZoomTransform.videoSize` caps `style.contentScale` at 2.0 (fine) — not causal. **The worktree Agent-2 edit removes the reveal scale from the renderer entirely** ("it was the reported 'shrink'") — confirms the mechanism at source. **Confidence: HIGH (when reveal is on); UNVERIFIED for `.balanced` users — then "shrinks" is the 8852f0b scale-dead sampling seen as zoom-not-working, or the 0be9156 0.90 x-axis squeeze.**

### 3.4 Motion blur under zoom
`sampleCount()` (Renderer.swift:806-830) counts sub-frames from `tl.camera.shutter * dt`, and `travelPx()` includes **tilt motion** in the blur budget — during `.lean` or `.reveal` every cursor move ≥ threshold accumulates sub-frames and the whole frame ghosts; `blurK` sticky hysteresis (render-only, preview) makes K lag behind in both directions. Combined with 3.3/3.2 this reads as smear/float. Export path stays pure (no hysteresis) — preview ghosts more than export. No "bug" hunk to quote; it is an emergent property of the design. **Low confidence as reported symptom class; flagged for the rebuild.**

### 3.5 Cursor / overlay drift under crop
3.1 covers rings/highlights (`toCanvas` raw-crop view vs `contentFS` base-view sampling). Additionally `toCanvas` got the inverse homography only in `e341f74` — before that, rings were drawn at the untilted position under a tilted frame (wrong pixels during any lean/reveal). Cursor *opacity* at crop edges is a documented no-op (`cropFade = 1.0`, Renderer.swift @8852f0b): the cursor never fades out at the browser-chrome boundary, so the pointer visibly floats over cropped-out chrome — cosmetic, annoying, intended-behaviour-as-shipped. **Confidence: HIGH for the ring/cursor mismatch mechanism (math, not feeling).**

### 3.6 Clamp-claim that doesn't hold
`Director.swift:551-556` @0be9156 and Decisions.md "Prompt 3" claim "baseView / scale … matches visible in BOTH dimensions even when the crop and frame aspects differ" — true for `CropSpace.visible` itself (verified), false for the **drawn quad**, which is always source-aspect. The claim encoded into code-review culture is why 8852f0b/0be9156 shipped. UNVERIFIED whether any runtime assert enforces it; the math disproves the claim unconditionally.

---

## 4. Audio path — evidence

### 4.1 Chain as shipped at 0be9156
`mic.caf → AudioIO.readMono → CleanVoiceURL/ProcessedVoiceCache (highpass 70 Hz → TrainedVoiceDenoiser → WPE dereverb → declick) → VoiceStudio.finish (VoiceExpander → tone → de-esser → VoiceCompressor → +2.5 dB voiceBoost) → Mixer.render (Self.mapped via TimeMap, micGainDb, silenceClips vs **imported** clips only) → AudioMaster.process (LUFS normalize if `plan.normalize && hasProgram && initial > -69`) → AudioIO.writeCAF → AVAssetReader→AAC → muxed in Exporter.run`. Preview, stems, export and transcription all share `ProcessedVoiceCache.process` — one shared chain, not export-specific; any break is everywhere, louder in export perception (no live monitoring to mask it).

### 4.2 "Neural-first" never flipped; the fallback *was* the path
DeepFilterNet-first landed before the window (`a5308e06` "Remove RNNoise fallback…", `ee4e3337`, etc.). In-window, `9983829` (11-17 21:47) is the load-bearing commit:
```diff
-        try AudioIO.writeMonoWAV(samples, paddingSamples: padding, to: input)
+        // The CLI only reads 16-bit integer PCM. Float32 made it panic
+        // ("TooWide") and silently downgrade the whole voice path.
+        try AudioIO.writeMonoPCM16WAV(samples, paddingSamples: padding, to: input)
```
Their own binary (`Sources/LumenAudio/Resources/DeepFilterNet/deep-filter`, Mach-O arm64, `deep_filter 0.5.6`, runs now) was being fed Float32 WAV ⇒ **every run before 9983829 fell back to SpectralGate** — silently (log line only, pre-`VoiceProcessingDiagnostics`). And pre-`2470b47` SpectralGate had this defect (2470b47, verbatim):
```swift
// A purely relative Wiener estimate converges on any stationary sound: its noise
// profile becomes the signal and it gates sustained speech… Cap the estimate at a
// small absolute floor…
-            return max(sorted[sorted.count / 5], 1e-12)
+            return min(max(sorted[sorted.count / 5], 1e-12), gatePower)
```
⇒ Before 2470b47 the "cleaned" voice had sustained speech gated; the "garbage voice" story. Both bugs are real, in the diff, attributed.

**The cache-poisoning half of the story:** `2470b47` changed the gate DSP but did **not** bump `ProcessedVoiceCache.revision` (`voice-v15-broadcast-chain`) or `mixRevision` (`mix-v3-broadcast-chain`). Voice/mix disk caches written before 2470b47 therefore kept serving gate-destroyed audio after the fix until `9983829` bumped **voice `v15→v16` / mix `v3→v4`** (voice carries the DF change; the bump also orphans pre-fix SpectralGate output) and `e341f74` bumped **mix `v4→v5-attack-aligned`**. 21 hours of poisoned default for anyone with a full-program cache on disk from the 16th. **This is the "falls back silently to spectral gate and the voice is destroyed" arc, with a date stamp.**

### 4.3 Per-item trace (what the window touched, and whether it can silence the mic)
- **`TrainedVoiceDenoiser` / `DeepFilterNet`** — edited `9983829` (PCM16 + `VoiceDenoiseEngine`/`lastEngine`), `e341f74` (`VoiceProcessingDiagnostics` counters). Can no longer panic-quietly; fallback is still silent-by-default in UI (only a counter + os_log). **Can it silence? No** — SpectralGate fallback passes signal (attenuated ≠ zeroed) post-2470b47. UNVERIFIED at runtime for the user's build.
- **`SpectralGate`** — `2470b47` only. Garbage → sane after the cap. Not silence.
- **`VoiceStudio.finish`** — `9983829` (boosted at the end, +2.5 dB; `boosted()` returns voice unchanged at db ≤ 0; default 2.5). `finish` itself runs VoiceExpander/VAD-guarded (no VAD ⇒ returns x untouched). **Not silencing.** Loudness can only improve.
- **`mapped()`** (AudioMapped.swift) — untouched in window. Maps source→output via TimeMap; mic silent only if `micOffset` path broken — and that path is fed `meta.mic.startHostSeconds − origin` (ProjectSession.swift:162, `:269`) — unchanged behaviour. UNVERIFIED for the user's project metadata.
- **`mixSignature` / `hasProgram` / `mixRevision`** — `Mixer.swift:736` (signature), `:564` (hasProgram). Signature covers `mixRevision` + sample count + `df3|custom` flag + full `tl.audio` JSON + `tl.timeMap` JSON + clip paths/starts/ends + cues (t/gain/key/isKey) + `duck` bytes + file identities of mic/system (path+size+mtime) + extra mics/sources + `musicPath`. **Miss:** the DeepFilterNet binary itself (env override or replaced checkout ⇒ identical key, stale voice & mix CAF), `keyTimes` (re-detected typing changes declick but the mix key does not), the music *file* (path string only, no mtime), and **any semantic change without a manual revision bump**. `hasProgram` is only used to (a) allow `mix()` normalization and (b) tell preview to wait for audio; a mic-present project always hasProgram=true. Not silencing.
- **Export CAF path** — Exporter.swift:117–122 (`includeAudio ? session.mixer.mix(tl) : nil`, then `AudioIO.writeCAF(m.l, m.r, to: caf)`), unchanged in window. If `mix()` returns nil (only if `tl.derived == nil`, guarded at top) → **no audio input added, video still exports, no error**. Silent success is possible only via (a) `includeAudio=false`, (b) `micMode == .off`, or (c) empty/failed decode of `mic.caf` — all three pre-existing, none delivery-breaking for a standard recording. `AudioMaster` cannot rescue a destroyed chain: `normalize` requires `initial > -69` LUFS; a gate-destroyed mix stays un-normalized and near-silent in the deliverable. **That is the quietest possible failure: a technically-valid export with your voice missing.**
- **`silenceClips`** — zeroes mix over **imported** clip spans (`tl.clips` only, Mixer.swift:730-ish, untouched). With an imported video over the timeline, recorded mic audio is deleted there by design. Worth knowing, not 3-day regression.
- **`mastering`/CAF round-trip** — writeCAF→AVAssetReader(Float32 PCM)→AAC, fine.
- **Voice boost +2.5 dB** (`voiceBoostDb`, default 2.5, `Models.swift:354`): raises voice before master; master still caps at −1 dBTP. Signalling, not silencing.

**Verdict (mic/voice):** the chain *cannot* express a hard-mute regression in this window — every silencing mechanism found is (1) DF-panic→fallback (fixed, plus flushes), (2) pre-2470b47 gate (fixed, only persisted via stale cache until v16/v4), (3) `-69 LUFS` no-normalize floor (by design). **Residual risk, unproven:** user's `micMode`/cache CAF on disk from before 11-17 21:47; or build predating `e341f74`. **Confidence: HIGH that the historical defect class is the voice-destroyed-by-fallback story; MEDIUM that it explains the current report; UNVERIFIED without the user's actual export + project bundle.**

---

## 5. Cache invalidation — can a stale/old-chain cache be served?

Three caches, one by one:

1. **Voice disk cache** `voice-<sha256>-{48000,16000}.wav` (`ProcessedVoiceCache.key`, ProcessedVoice.swift:38-47): key = `voice revision` + sample-count + samples bytes + keyTimes + Settings JSON(`noiseStrength, engine∈{df3,spectral,off}, declickDepth, dereverb, clarity, studio, studioMode, voiceBoost`). Serves full-program renders only. **Misses:** the DF3 binary identity (env `LUMEN_DEEPFILTER`, bundle, or `Vendor/` — a swapped/updated binary produces identical keys), and the *reason* a bump exists (manual bump discipline only). Note: `engine` encodes `"df3"` once `DeepFilterNet.isAvailable` is true — it does not distinguish DF 0.5.6 from a future binary.
2. **In-memory voice single-flight** (`voice` dict, Mixer.swift): process-lifetime only; `denoiser` setter calls `voice.removeAll()`. No staleness across chain edits inside one run.
3. **Full-program mix CAF** (`mix-<sig>.caf`, Mixer.swift:776-800): key = `mixRevision` + N + `df3|custom` + audio/timeMap JSON + clips + cues + duck + mic/system fileIdentity + extras + musicPath. Read requires exact `n == Int(duration*fs)+1`. **The entire cache is trustworthy only as far as the manual revision strings are.** Evidence the discipline held: `v15→v16` (9983829) with the DF fix; `v3→v4` (9983829); `v4→v5` (e341f74) with whoosh-amp semantics. Evidence it failed: `2470b47`'s DSP change with zero bumps — stale served for ~21 h.
4. **Derive caches** (`DeriveCache`, Director.swift): keys gained `activity`/`CropSettings` in d6e1aae/1992ded (`PlanKey`, `RampKey`, `cropKey`). Miss: nothing audio. Stale-plan tests exist (`BrutalZoomInvariantsTests.cacheNeverServesAStalePlan`).
5. **Reader-side guards that *do* work**: `ProcessedVoiceCache.read` rejects non-finite, wrong-count, wrong-rate, wrong-length files; `mixCacheRead` rejects wrong-`n`, unreadable CAF. Wrong-content-right-length survives — i.e. exactly the pre-fix voice.
**Answer to the question:** yes, any of the three can serve old output for a chain change that forgets the revision bump — proven once (`2470b47`), contained since `9983829`. What they miss: binary identity, keyTimes, music-file mtime, and *project-level* "the user ran the same file through the old app" the day *after* a semantic change. One-line fix direction: hash the resolved DF3 executable's identity (path+mtime+size) and the full `VoiceStudio` finish constants into both revisions automatically; delete the manual-bump protocol or assert it in CI.

---

## 6. Tests — added/changed in the window; which encode the quintic to be deleted

**Added (56 files, +13,988 net lines; endpoint +14,069/−68 incl. rewrites):**
`BrutalZoomQ1Tests` (e341f74), `CameraAccuracyTests`+Fuzz (09c01b1), `CinematicRender3D(GPU)Tests`, `CinematicZoomStressTests`+`CinematicZoomMotionTests` (8a49980), `ZoomTimingAccuracyTests`+Fuzz, `ZoomFramingAccuracyTests`, `ZoomArrivalAccuracyTests` (59efd65), `ZoomOutCompletionTests` (8260753), `BrutalZoomSweepTests`+`BrutalZoomInvariantsTests` (1699384), `TypingFocus*Tests`×3 (09c01b1/e341f74), `VisualAutofocus(Composition)Tests` (9983829, rewritten 0be9156), `RenderVisualAccuracy` (9983829), `AudioStudioQualityTests` (9983829), `BrutalAudioRenderAdversarial`, `KeyboardAudioTests` (09c01b1), `Video*E2E/Pipeline/Model/Frame/Performance/Caption/DesignCompliance`×7, `MCPContract/Core/Fuzz/VideoEditTools`×4 (0be9156, MCP/video-edit, orthogonal), `RealVideoEditE2ETests` (0be9156), `DialogIntentCapture*`×2, `TypingStabilityTests` (dd90bbe), `CoreCaptureValidation`, `CoreZoomValidation{Loupe,Planner}`, `CoreFeatureValidationTests`, `CinematicControlsUIStateTests`, `StudioStageUI*`×3, `UnifiedFocusUIStateTests` (09c01b1), `Upscaler{Honesty,Sharpness,SharpnessField}Tests`, `MusicTimeline/MusicDeleteTests`, `PlayInstantTests`, `PerformanceTests`, `ViewportCropTests`-adjacent (rewritten `TypingFocusBrowserCropTests`), `FrontendVisualTests`.

**Changed/rewritten:** `Agent1BrutalZoomTests` (09c01b1 create; **0be9156 rewrite 501→~350** to drive the dense-crop derive), `TypingFocusBrowserCropTests` (09c01b1 +232, 0be9156 ±122), `VisualAutofocusTests` (−217 net), `ZoomReportTests`, `Agent1BehaviorTests`, `Agent2/3Tests`, `BrutalZoomQ1Tests` (−28 net, 1 test remains), `CinematicControlsUIStateTests`, `ZoomArrivalAccuracyTests`, `AudioStudioQualityTests` (+30 in 0be9156).

**Deleted (in-window, body removed; files remain):** `BrutalSmartCropTests` → 3 of ~10 `@Test` survive (0be9156); `CoreZoomValidationSmartCrop` → 2 survive; `BrutalZoomQ1Tests` partially; `AutoZoomRegressionTests` (−10, `autonomousVisualZoomWorksWithMouseEventsButNoClick` removed); `RenderVisualAccuracy.dialogCropContainsSubjectAndNeverSamplesOutside`. Decisions.md documents 19 deletions explicitly (e.g. `BrutalSmartCropTests.chromeClickRevealsThenRecrops`, `changingOnlyAXLabelOrAppNameInvalidatesCachedCrop`, `mergedRevealsKeepSourceAspect`).

**Files that ENCODE THE QUINTIC SOLVER and will break/be deleted with it (name them exactly):**
1. `Tests/LumenTests/ZoomTimingAccuracyTests.swift` (+318, 9983829) — contains `enum ZoomTiming` helper + `jerkIsBoundedAtTheBakeRate`, `bridgedRunIsCapped`, `peakJerk` vs `MotionLimits.cameraJerk`.
2. `Tests/LumenTests/ZoomTimingAccuracyFuzzTests.swift` (+166, 9983829) — seeded fuzz of the same solver internals.
3. `Tests/LumenTests/CinematicZoomStressTests.swift` (+401, 8a49980) — "the quintic primitive", `bridgedShotsNeverPumpThroughFullFrame`, continuity-slope jerk bounds.
4. `Tests/LumenTests/CinematicZoomMotionTests.swift` (+299, 8a49980) — bridged scenes, quintic baked-tick reconstruction.
5. `Tests/LumenTests/CameraAccuracyTests.swift` (+334, 09c01b1; header: *"the filmed quintic stays"*).
6. `Tests/LumenTests/CameraAccuracyFuzzTests.swift` (+255, 09c01b1) — jerk/derivative assertions at bake rate.
7. `Tests/LumenTests/ZoomArrivalAccuracyTests.swift` (+226, 59efd65) — quintic Hermite endpoint derivatives exactly.
8. `Tests/LumenTests/ZoomPrecisionTests.swift` (pre-window) — asserts `CameraSolver.centredPlay` directly.
9. `Tests/LumenTests/MotionTraceTests.swift` — references `MotionLimits`/quintic bake.
10. `Tests/LumenTests/BrutalZoomQ1Tests.swift` — black-box (`Timeline.evaluate`), only word-level mentions of quintic; survives by rewrite, not by text.
**Black-box survivors** (correctness via public API, keep): `BrutalZoomSweepTests`, `BrutalZoomInvariantsTests`, `BrutalSmartCropTests` (3 left), `TypingFocus*Tests`, `ZoomFramingAccuracyTests`, `CoreZoomValidation*` (2 left), `PerformanceTests`.

---

## 7. Ranked symptom → commit(s) table

| # | symptom | most likely commit(s) | confidence | one-line fix direction |
|---|---|---|---|---|
| 1 | Zoom **stretches/compresses** the picture | `2470b47` (view=cropSize/scale), compounded `0be9156` (baseView canvas-aspect into source-aspect quad), visible class since 11-17; current release HEAD is this bug | **high** | Sampled view aspect must equal **drawn** content-rect aspect (draw-aspect baseView); delete canvas-aspect baseView on the zoom path |
| 2 | Zoom **"shrinks"** / does nothing / weak magnification | `8852f0b` (`cropSize *= scale` ⇒ view==crop, zoom dead for ~4 h); reveal-mode `0.92` shrink `8a49980` (`CameraTilt.revealScale`) — narrow case; `0be9156` residual 0.90 x-squeeze | high (8852f0b); medium (which the user ran) | Draw-aspect base view + drop the reveal content-rect shrink |
| 3 | Zoom **floats up and down** | Dense 480 Hz AXWebArea crop following chrome/scroll (`1bde05a/8852f0b/d6e1aae/0be9156`, F1 crop track) + `.cinematic.lean` pitch spring (`9983829/8a49980`) + (historical) `.float` Lissajous wander (`8a49980`, deleted `09c01b1`) | **medium** (F1 track) / medium-low (lean) | View crop smoothing/quantization at 480 Hz bake; default tilt `.off`; if F1 jitter confirms, crop changes must not re-aim a settled camera |
| 4 | Zoom **stop-start / floaty rig feel** | Quintic/jerk/Hermite-bridge solver `9cbce19…557` (whole `Camera.swift` arc, §3.2) | high (the feel), zero uncertainty it must go | Replace with critically-damped (logScale, centre) springs toward segment targets; keep `CameraTrack` API |
| 5 | **Frame stretches under browser crop** (cursor/rings misplaced) | `2470b47` `toCanvas(crop:)` — raw-crop view ≠ `contentFS` base-view sampling; never reconciled | high | Map overlays through the **same** view as `contentFS` (draw-aspect baseView) |
| 6 | **Own voice missing / silent in export** | Pre-`9983829` DF-panic→SpectralGate fallback (default path), persisted by cache until voice `v16`/mix `v4` (≈11-17→11-19); `−69 LUFS` no-normalize floor masks it in master — current HEAD technically fixed | medium-high for history; **UNVERIFIED** for user's current bundle/build | Measure RMS end-to-end through `mix(tl)` for the user's project; confirm `VoiceProcessingDiagnostics.fallbackCount == 0` and which `mix-*.caf` served |
| 7 | **Voice processing garbage / underwater** | SpectralGate relative-Wiener convergence on sustained speech (pre-`2470b47`), persisted via un-bumped cache (~21 h) | high (historical) | Chain verified post-`9983829`; keep PCM16 input + flat gate |
| 8 | **Motion blur smears during zoom** | Shutter budget includes tilt motion; preview sticky `blurK` (`e341f74`/`Renderer.swift:806+`) | low-medium | Exclude tilt from blur budget or gate to `.off`; preview K hysteresis is fine to keep |
| 9 | **Cursor floats over cropped-out chrome** | `cropFade = 1.0` hard-coded (`8852f0b`) | high (cosmetic) | Multiply by `CropSpace.cursorVisibility(...)` (already exists) |
| 10 | **Export enqueued, mic absent, no error** | Exporter `:117-122` skips audio input silently when `mix` nil/`includeAudio=false`/`micMode=.off` | high (mechanism, defaults false) | Fail loud: surface "no audio bed" in export summary |
| 11 | **Stale/old-chain mix served after a DSP change** | Manual `revision`/`mixRevision` protocol; missed for `2470b47`; caches miss DF3 binary identity/keyTimes/music mtime | high (proven once) | Auto-hash resolved binary + finish-constants into keys; CI assert on bump |
| 12 | Merge/review gaps: GPU tests flaky post-merge | `131a28c` (only fix), `8a49980` squashed six agent streams with no green gate | high | (Process) agent-stream squash must pass focused suites before landing |

---

## 8. Delete list — added in the 3 days whose existence only serves the failing design
(`file:line` at 0be9156 unless noted; deletion is for the rebuilder to schedule, NOT performed here.)

**Camera/motion (the "brutal" layer):**
1. `Sources/LumenDirector/Camera.swift` — `centredPlay` (:19), `leadFor` jerk floor (:108-122), `holdVelocity` (:275), the Hermite quintic `fill`/`bounded` (:291-330), `bridgedRunLimit`/`returnRoom`/`distinctGap`/`minHold` bridge apparatus (:361-420), `clampCenter` tick-clamp twin (:202) — i.e. the entire rest-to-rest quintic/jerk/runway/bridge solver (§3.2). Replace with critically-damped springs; keep `CameraSolver.solve(...) -> CameraTrack` + `Camera.cameraRate` as the ABI.
2. `Sources/LumenCore/Motion.swift` — `MotionLimits.filmJerk` (:87), `MotionLimits.peakJerk` (used only by solver tests), `cameraJerk` (:81) if unreferenced post-rewrite.
3. `Sources/LumenDirector/ZeroPhase.swift` — `zeroPhaseSmooth` (used at Camera.swift:196-240 and Planner.swift:224) — keep or fold into the spring; delete after call-site removal.
4. `Sources/LumenProject/Models.swift` — `cameraModel = 5` apparatus (:240) and `ZoomPreset.cinematic` tilt defaults (tilt=.lean piggyback) **only if** cinematic is formally retired; else keep. UNVERIFIED product intent — flag, don't assume.
5. `Tests/LumenTests/ZoomTimingAccuracyTests.swift` (incl. `enum ZoomTiming` helper, +318) · `ZoomTimingAccuracyFuzzTests.swift` (+166) · `CinematicZoomStressTests.swift` (+401) · `CinematicZoomMotionTests.swift` (+299) · `CameraAccuracyTests.swift` (+334) · `CameraAccuracyFuzzTests.swift` (+255) · `ZoomArrivalAccuracyTests.swift` (+226) · `ZoomPrecisionTests.swift` — the quintic-internal suite (§6). Rewrite or delete with the solver; black-box suites stay.

**Render/content (the stretch):**
6. `Sources/LumenRender/CameraTilt.swift` — `revealScale`/`revealScaleDrop` (:24, :50-58) and the `.reveal` mode entirely (0.92 entrance shrink; "shrink" symptom). Keep lean/off or delete whole file per rebuild call. Also `maxFloat`/`floatDeg` vestiges if any survive (already deleted 09c01b1).
7. `Renderer.swift` — the reveal `contentRect` shrink block (:926-932 @0be9156) and `Reveal` shutter/`travelPx` tilt term.
8. `Sources/LumenDirector/Crop/CropSpace.swift` — `baseView(crop:aspect:)` canvas-aspect call-sites only (:12): the function may stay for `Layout`/`.fillFollow`, but must not feed `contentFS`/`toCanvas`. Delete the `tl.style.aspectRatio` (canvas-aspect) argument on the zoom path; use drawn-quad aspect (`drawAspect`).
9. `Layout.swift` `fitScreenRect` / `ResolvedLayout.screenRect` machinery added in `8852f0b` — **dead code**: no consumer in LumenRender/LumenUI computes or reads `st.layout.screenRect` (grep-verified, 5 hits, all Definitions). Shipped in 3 days, used nowhere.
10. `Renderer.swift` `cropFade = 1.0` no-op (8852f0b) — replace with a real crop-edge fade or delete.

**Audio (dead weight, not bugs):**
11. `Sources/LumenAudio/Mixer.swift` — `mixSignature`'s `"df3"|"custom"` literal (mixSignature, Mixer.swift:736) must die with the binary-identity fix (§5). `VoiceProcessingDiagnostics` itself is read by `AudioStudioQualityTests` — keep it (it is the only observable of silent degradation).
12. `Sources/LumenAudio/TypingPacks.swift` — `trimmedToAttack` is fine; the mechvibes **sound.aiff is 4.56 MB ×2** (`App/public/assets/typing/...` and `Resources/TypingPacks/...`, duplicated) — one copy should go.

**Repo/hygiene (flagged for orchestrator, not product):**
13. `Tools/perfprobe-debug` (4.95 MB) and `Tools/perfprobe-release` (3.74 MB) — **committed binaries** (8a49980). Git-lfs or invert.
14. `promo/` (5,189 insertions incl. ~3,900 package-lock lines, e181e0d) — Remotion promo in the app repo; questionable, not core.
15. `sandbox/tasks.json` (673 lines), `issue.md`/`solution.md` churn (+1,055 in ec28606/8a49980) — harness artifacts in-tree.
16. `Tests/LumenTests/BrutalSmartCropTests.swift` — remainder is 3 live tests on a deleted planner plus ~110 LOC of CropProbe scaffolding feeding removed assertions; fold into crop-pipeline tests.
17. `Sources/LumenDirector/Layout.swift` per-tick `fit` outside the spring (8852f0b) — if `.fillFollow` is cut, the whole per-tick re-fit dies.

---

## 9. Honest limits of this audit
- **No build, no tests, no runtime render** — every claim above derives from diffs and static reads; UNVERIFIED unless quoted. The one thing that would settle §4 completely: run `lumen-cli` (or the E2E suite) on the user's failing project and RMS-meter each stage; capture `VoiceProcessingDiagnostics.fallbackCount`.
- The user's project bundle, settings, and which build they ran are unknown ⇒ §7 #2/#3/#6 carry that uncertainty openly.
- The F1 browser-crop track (`CropPlanner`, 319 LOC new 11-19) received a **code review only** — its failure modes under AX noise are untested by this audit.
- Working tree was being modified live by Agents 1/2 throughout; quotes from the worktree (fix-in-flight) are labelled.
- Line references are `@0be9156`; they will drift as the rebuild lands. Commit shas won't.
- Not audited (no evidence of regression seen, sampled only): captions, transcript editing, MCP tool correctness, device/web-capture extras, music-bed scheduling, speed-ramp planner (dd90bbe/59efd65 were healthy lookalikes), AppModel/UnifiedFocusPage (UI-only).

*Evidence index:* every sha cited resolves in `d3c41e4..0be9156`; file:line pairs were produced by `git show 0be9156:<path> | grep -n`; LOC by `git show <sha>:<path> | wc -l`; the 46-commit census by `git log d3c41e4..HEAD --reverse`; deletions by `git diff d3c41e4 HEAD --numstat` and by per-commit `--stat`.
