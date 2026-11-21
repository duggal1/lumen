# Backend investigation — incomplete baseline

This is a partial investigation, not completion of the requested whole-backend review.

## Confirmed structure and flow

- `Package.swift`: Swift package targets for capture, project, Director, render, audio, analysis, export, UI and CLI.
- `Sources/LumenCapture/`: records media and interaction data.
- `Sources/LumenProject/`: project and timeline models; source media and edits are separate.
- `Sources/LumenDirector/Director.swift`: derives time map, automatic zoom, cursor, camera, layout and captions; retains manual zooms during re-derive.
- `Sources/LumenDirector/Planner.swift` and `Activity/ActivityShotBuilder.swift`: plan zooms from interaction and visual activity.
- `Sources/LumenDirector/Camera.swift`: bakes a camera track at 480 Hz with independently stepped scale and pan springs.
- `Sources/LumenRender/Renderer.swift`, `ZoomTransform.swift`, `Upscaler.swift`: shared composition, geometry and upscaling.
- `Sources/LumenAudio/Mixer.swift`, `Studio.swift`, `DeepFilterNet.swift`, `Mastering.swift`: offline voice and program mix, suppression and loudness processing.
- `Sources/LumenExport/`: export using rendering and audio components; `GoldenImage.swift` supplies image comparison.
- `Sources/LumenCLI/` and `Sources/LumenRender/PerformanceHarness.swift`: CLI and synthetic Metal benchmark.
- `Tests/LumenTests/`: extensive algorithm, media and regression coverage. Full review remains outstanding.

## Findings to investigate

- `Sources/LumenDirector/Camera.swift:448` independently steps scale and pan; its follow paths and clamping can also move the framing during zoom. Pivot-path behavior has not been measured.
- `Sources/LumenRender/PerformanceHarness.swift:73` measures synchronous synthetic rendering with GPU completion, not actual playback or click stalls; its existing gate allows deadline tolerance and missed frames.
- `Sources/LumenRender/Renderer.swift:646` has a semaphore wait path. Its role in an observed playback stall has not been established.
- The supplied RNNoise description is stale for this checkout. `Sources/LumenAudio/DeepFilterNet.swift:125` uses DeepFilterNet with a spectral fallback, whereas `readme.md` describes pass-through on failure. `Sources/LumenAudio/Studio.swift:224` conditions denoising on `micClean`. Verify the actual path before changing it.

## Baseline

- `make test`: timed out after 120 seconds; before timeout, `fiveHundredSeededMixedSessionsHoldEveryInvariant` reported multiple seeds ending zoomed and `sixtySecondDenseSessionHasNoShotOverFourSeconds` ended at 1.3432096×. Full results unavailable. Log: `/tmp/lumen-backend-baseline-test.log`.
- Rebuilt `.build/debug/lumen-cli bench --frames 120`: 1920×1080; average 1.48 ms, p95 2.07 ms, p99 2.65 ms, maximum 6.56 ms, 0/120 over the existing budget. This is not a click or playback benchmark.

## Active entry points and format boundaries

| File or module | Role |
| --- | --- |
| Capture/Capture.swift, Session.swift, Input.swift | ScreenCaptureKit and audio writers, recording lifecycle/clock/journal, event tap and asynchronously resolved AX targets. |
| Capture/FrameCropper.swift, ViewportRecorder.swift, WindowContent.swift | Area extraction, browser viewport sidecar and window geometry. |
| Project/Models.swift, Composition.swift, Editing.swift, Derived.swift | Portable project/timeline schema, imported clips and recovery, edit-time mapping and derived track frame evaluation. |
| Analysis/Service.swift, Activity.swift, ActivityAnalyzer.swift, TypingAnalyzer.swift | Derive activity and typing traces from source evidence and cache analysis. Other analysis files handle speech, face/matte and private OCR regions. |
| Director/Planner.swift, TypingFocus.swift, VisualAutofocus.swift | Source-time scene planning, typed-field evidence and non-input visual intent. |
| Director/Camera.swift, Cursor.swift, Crop/, Layout.swift, Placement.swift, Captions.swift | Output-time camera and pointer tracks, source viewport, layouts, webcam avoidance and caption placement. |
| Director/LiveCamera.swift | Capture-time camera preview driven by incoming events. Recorded playback uses CameraSolver. |
| Render/FrameSource.swift, LiveFrameSource.swift | AVAssetReader and live IOSurface frame delivery. |
| Render/ZoomTransform.swift, ContentPass.swift, Upscaler.swift, Shaders/ | Crop, canvas and camera geometry, ROI upscale preparation and Metal composition/sampling. |
| Render/Renderer.swift, TextOverlay.swift, ClickEffects.swift | Shared command encoding, subframe sampling, text and click graphics. |
| Export/ProjectSession.swift, Exporter.swift, GoldenImage.swift | Session media resolution and input derive, AVAssetWriter delivery, golden PNG helpers. |
| Audio/ProcessedVoice.swift, DeepFilterNet.swift, Studio.swift, Mixer.swift, Mastering.swift, AudioCheck.swift | Mic cache, existing model/fallback, EQ/dynamics, shared offline mix, master gain and metering. |
| Speech/ | On-device transcription, alignment and runtime model integration. |
| UI/AppModel.swift, EditorModel.swift, PreviewView.swift | Recording/editor lifecycle, replan and audio transport, display-link rendering. |
| Core, App, CLI, Seed, RecordDemo | Common clock/types, app entry point, command-line tools and development entry points. |
| Control, Actuator | Edit/record/export command and transport surfaces, approved desktop automation. |
| Tools, Tests | App packaging, scripted checks, focused real media tests, synthetic tests and fixture assets. |

Capture writes timestamped media and event/AX sidecars. Finalization seeds automatic scenes from captured evidence. Opening a project binds those sources in ProjectSession. Background analysis supplies more evidence for Director, which first builds the time map, preserves manual edits, then derives the cursor/clicks, camera, layout, captions and audio cues. Frame selection maps output time to source time. Both delivery paths use Renderer.encode and AudioMixer. Preview schedules against a host clock and presents CAMetalLayer drawables, occasionally using a bounded first audio window while the full mix prepares. Export requests each fixed output timestamp and waits for a bounded queue of rendered buffers before writing them.

## Additional hypotheses

- P4: Planner.swift:258–270 emits a full-run follow shot only for the explicit fixed preset. For the normal planner, visual detection, presence of event data and scope of follow must be measured independently. ActivityShotBuilder.swift:93 filters hover-local changes, scroll and large flashes. This does not prove every idle scene is filtered.
- P5: Planner.swift:421 closes a shot at the hold/cap/trim boundary. Camera.swift:265–283 chains shots in output time, and Camera.swift:464–508 advances the spring even when little time remains. The final scale failure was reproduced before changes.
- P2: FrameSource.swift:99–114 decodes its lookahead synchronously on an awaited actor call. PreviewView.swift:188–207 waits for it before draw; EditorModel.swift:485–495 sends seeks with missing audio into a waiting path. These are candidates for profiling. Renderer.swift:605 passes wait:false for preview, so its export semaphore path is not evidence of a preview stall.
- P3: Renderer.swift:1031 can prepare an upscaled intermediate in the shared pipeline before sampling it into the composition. Renderer.swift:673–685 conditionally makes a mip chain for minification.
- P6: ProcessedVoice.swift:93–134 gates suppression, dereverb and declick on plan fields. Mastering.swift:8–32 applies program-level normalization, which may cancel a mic gain change. The default program target and requested target need to be measured together.

The file inventory and these path reviews narrow the implementation scope. A line-by-line review of every file in the requested directories remains outstanding.

## Reproduction on this checkout

Apple M1, macOS 27.2 and Xcode 27.2. Metal rendered successfully. The branch `fix/backend-reliability` at `1a5ffe78` fast-forward checked against `origin/main`. The checkout already contained unrelated modifications and untracked files.

- A second run of `.build/debug/lumen-cli bench --frames 120` at 1920×1080 reported 1.43 ms mean, 2.39 ms p95, 4.45 ms p99, 11.27 ms max, 0/120 over its existing budget.
- The focused zoom-out run exited 1 with 15 issues across six selected tests. Late recorded click: 1.800× at 5.999 s and 6.0 s. Bridged and zero-slack examples: 2.000× at their final tick. Results in `.proof/backend-zoom-baseline.log`.
- The checked-in clean speech input measures -14.94 LUFS mono, -1.16 dBTP, -73.11 dBFS estimated noise floor and zero clipped samples. These are source measurements. Standard AudioPlan defaults to a normalized -14 LUFS stereo program, so -16 LUFS and a +1.6 dB gain cannot both describe an already-normalized -14 LUFS program. Measure each fixture at the actual master output before comparing the targets.
- The hardware encoder probe reports support for `1080p60-h264`, `1080p120-h264` and `4k60-h264`. Capability discovery alone provides no encoded frame or presentation counts.
- Repeated `make test` exited 124 at the repository's 120 s limit, after the same dense and seeded zoom-out tests reported failures. The command reached `BrutalSmartCropTests` before termination. Full log in `.proof/backend-full-baseline.log`.
- P5 mechanism confirmed in `Camera.swift:402–410, 432–461`: the last scene remains active through its inclusive end tick. When that tick is the final baked sample, target selection never reaches the release branch. Changing the final sample alone would introduce a visible jump.
- Five supporting tests passed in 32.40 s, including empty-event planning, early-click release, actual export frame counts at 60/120/240 fps and final program normalization. For the 1.7 s export cases, the assertions verified 102, 204 and 408 decoded frames. See `.proof/backend-supporting-baseline.log`.
- The pre-existing local audio measurement reported -35.17 → -66.51 dBFS across the denoising step for its seeded-noise speech example. The pre-master default voice chain measured -12.49 LUFS, -0.90 dBTP. Raising its boost to +6 dB measured -8.99 LUFS and +2.60 dBTP before final program limiting. The full-suite keyboard stress mix reached -14.00 LUFS and -2.33 dBTP under existing mastering.
- Repeated `make build` exited 0, reporting a 1.48 s incremental build. See `.proof/backend-build.log`.
