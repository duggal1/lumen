# Issue completion

Implemented on main. Verification is limited to `make build`, as requested; no tests, captures, benchmarks, harnesses, packaging or launches were run.

| Item | Status | Decision and files |
| --- | --- | --- |
| A1 migrations | Done | Camera model 4 resets the old persisted camera values; typing model 2 enables the restored sounds for old projects. `LumenProject/Models.swift`; existing editor-open replan regenerates automatic zooms. |
| A2 caches | Done | OCR uses v6, typing v4, Medium transcription v2 and voice processing revision v7, so changed outputs do not reuse old results. `LumenAnalysis/Service.swift`, `LumenAudio/ProcessedVoice.swift`. |
| A4 asset paths | Done | A shared resolver checks bundled assets first, with checkout fallbacks for development. `LumenCore/AppAssets.swift`, `LumenAudio/{BundledAudioAssets,TypingPacks}.swift`, `LumenUI/Inspector.swift`. |
| B1/B4/B5 planner | Done | Context controls magnification; clicks cap at 1.7 and typing at 2.0, with one caret-anchored intent per burst and shorter holds. `LumenDirector/Planner.swift`. |
| B2 springs | Done | Spring frequencies use the camera settings directly, independently of anticipation. `LumenDirector/Camera.swift`. |
| LiveCamera | Done | Live camera uses the matching smaller scale, hold and spring defaults. `LumenDirector/LiveCamera.swift`. |
| C2/C3/C4 AX | Done | Launcher queries precede ordinary focus queries; insertion points probe the previous glyph, and Chromium accessibility is enabled for both focus and secure-field sampling. `LumenCapture/Input.swift`. |
| C5 tracer | Done | Requests carry AX frames; burst anchors use caret/field or recent clicks and motion compares adjacent frames. `LumenAnalysis/{Service,TypingAnalyzer,TypingTracer}.swift`, `LumenExport/ProjectSession.swift`. |
| C6 staged analysis | Done | Typing publishes before the remaining analysis; privacy publishes independently when OCR finishes, without waiting for person masks or speech. `LumenAnalysis/Service.swift`, `LumenExport/ProjectSession.swift`, `LumenUI/EditorModel.swift`. |
| D1–D4 typing sounds | Done | Restored the historical pack and recorded fallback, corrected key codes, normalized/resampled samples and removed the extra gain reduction. `App/public/assets/typing/mechvibes-default/*`, `LumenAudio/{TypingPacks,Mixer,SFX}.swift`, `LumenDirector/Director.swift`, `Tools/make-app.sh`. |
| E1 OCR | Done | OCR crops changed components, keeps unchanged detections, bounds concurrent Vision requests to three and retains partial detections on interruption/failure. Dirty crops expand to full-width text bands and include complete intersected secrets and context. `LumenAnalysis/{OCR,DirtyRects,TypingAnalyzer,Service}.swift`. |
| E2 privacy gate | Done | All OCR exits report terminal progress, and the editor has an analyzer deadline plus a ten-second application grace period. Partial/failure results keep an actionable export block. `LumenAnalysis/Service.swift`, `LumenUI/EditorModel.swift`. |
| E3 exact boxes | Done | Secret geometry comes from Vision substring bounds rather than character proportions. `LumenAnalysis/OCR.swift`. |
| E4 envelope | Done | Nearby tracked boxes form a conservative envelope with padding relative to text height. `LumenDirector/Emphasis.swift`. |
| E5/E6 renderer | Done | Frost, Pixelate and Redact share the source pass; masked textures have mips and upscaling keys include masks and pixel size. Frames exceeding the inline 128-mask limit fail closed rather than omit masks. `LumenRender/{Renderer.swift,Shaders/Shaders.metal}`, `LumenProject/Overlays.swift`, `LumenUI/Inspector.swift`. |
| E7 secure AX | Done | Secure fields use breadth-first traversal with Chromium enabled, a 1,500-node budget and one-second sampling. `LumenCapture/Input.swift`. |
| E8 classifiers | Done | Read the existing email, Luhn/card, key-prefix, JWT and bullet classifiers; they have no app or region gate. `LumenCore/Sensitive.swift` required no change. |
| F1 dereverb | Done | Voice processing invokes WPE and residual suppression under ten minutes, with late-reverb suppression for longer audio. `LumenAudio/ProcessedVoice.swift`. |
| F2 DeepFilterNet | Done | Finished enhanced audio is retained; the existing process timeout still bounds execution. `LumenAudio/DeepFilterNet.swift`. |
| F3 capture/UI | Done | Corrected the capture comment and exposed the requested system Voice Isolation controls in the audio inspector, without enabling AVAudioEngine processing in capture. `LumenCapture/Capture.swift`, `LumenUI/Inspector.swift`. |
| F4 transcription | Done | Replaced the analysis Apple Speech engine with Moonshine Medium. The sole editor caption path already supplies `cleanVoiceURL`; its parallel analysis request carries no raw microphone URL and disables duplicate speech work. `LumenAnalysis/{Speech,Service}.swift`, `Package.swift`, `LumenExport/ProjectSession.swift`; `LumenSpeech` already contained only Medium and no model picker. |
| F5 captions | Done | Vocabulary spelling and proper-name casing are preserved. Existing captions default off and only explicit user writes enable them. `LumenDirector/Captions.swift`; audited UI/project writers. |
| F6 wallpaper | Done | Gaussian wallpaper sampling uses wallpaper mips; zoom-dependent backdrop blur is removed. Existing macOS/Painting tabs remain, with bundle-first resolution and separate categories. `LumenRender/{Renderer.swift,Shaders/Shaders.metal}`, removed `LumenRender/BackdropBlur.swift`, `LumenUI/Inspector.swift`. |
| F7 lane/recovery | Done | The main lane draws recording segments and imported clips; finalize and recovery reject empty source/trim spans before saving. `LumenUI/TimelineStrip+Lanes.swift`, `LumenCapture/Session.swift`, `LumenProject/Composition.swift`. |
| F8 stop handoff | Done | Project open, waveform preparation, derive, mixing and thumbnails already execute in workers. Moved the remaining stop-time duration load off main and serialized project saves on a background queue. `LumenUI/AppModel.swift`, `LumenExport/ProjectSession.swift`; traced `LumenUI/{EditorModel,EditorView,ProjectThumb}.swift`. |

## Limits of this delivery

“Done” means implemented and source-reviewed, with compilation as the only executed verification. Runtime audio, launcher AX behavior, OCR throughput and rendering quality were not exercised. Existing tests were not updated or run; tests that reference the explicitly removed `BackdropBlur` API will need revision before a future test-suite build.

## Exact changed files

- `App/public/assets/typing/mechvibes-default/config.json`
- `App/public/assets/typing/mechvibes-default/fallback.mp3`
- `App/public/assets/typing/mechvibes-default/pack.wav`
- `Docs/issue-completion.md`
- `Package.swift`
- `Sources/LumenAnalysis/DirtyRects.swift`
- `Sources/LumenAnalysis/OCR.swift`
- `Sources/LumenAnalysis/Service.swift`
- `Sources/LumenAnalysis/Speech.swift`
- `Sources/LumenAnalysis/TypingAnalyzer.swift`
- `Sources/LumenAnalysis/TypingTracer.swift`
- `Sources/LumenAudio/BundledAudioAssets.swift`
- `Sources/LumenAudio/DeepFilterNet.swift`
- `Sources/LumenAudio/Mixer.swift`
- `Sources/LumenAudio/ProcessedVoice.swift`
- `Sources/LumenAudio/SFX.swift`
- `Sources/LumenAudio/TypingPacks.swift`
- `Sources/LumenCapture/Capture.swift`
- `Sources/LumenCapture/Input.swift`
- `Sources/LumenCapture/Session.swift`
- `Sources/LumenCore/AppAssets.swift`
- `Sources/LumenDirector/Camera.swift`
- `Sources/LumenDirector/Captions.swift`
- `Sources/LumenDirector/Director.swift`
- `Sources/LumenDirector/Emphasis.swift`
- `Sources/LumenDirector/LiveCamera.swift`
- `Sources/LumenDirector/Planner.swift`
- `Sources/LumenExport/ProjectSession.swift`
- `Sources/LumenProject/Composition.swift`
- `Sources/LumenProject/Models.swift`
- `Sources/LumenProject/Overlays.swift`
- `Sources/LumenRender/BackdropBlur.swift`
- `Sources/LumenRender/Renderer.swift`
- `Sources/LumenRender/Shaders/Shaders.metal`
- `Sources/LumenUI/AppModel.swift`
- `Sources/LumenUI/EditorModel.swift`
- `Sources/LumenUI/Inspector.swift`
- `Sources/LumenUI/TimelineStrip+Lanes.swift`
- `Tools/make-app.sh`
