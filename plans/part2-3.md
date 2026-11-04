# Plan: Complete Director and local analysis parts 2 and 3

## Goal
Complete the partial Part 2/3 implementation using the v2 plan while preserving existing recording, editing, render, and audio behavior. Add the pure Director tracks and local analyzers with project-specific caches.

## Non-goals
Do not change Capture, Audio, Renderer, shaders, or redesign the frontend. Do not store OCR text or add network services/dependencies.

## Invariants
- OCR results persist only category, source-space rectangle/time, confidence, and a project-salted hash.
- Content-bound edits and analyzer results use source time; playback tracks use output time.
- Analysis runs off the UI path, is cancellable, and uses a media/content key for cache reuse.
- Existing projects without new fields continue decoding with safe defaults.
- Analyzer failure cannot prevent a project from opening.

## Failure modes
- Missing/corrupt cache: recompute, then atomically replace the cache file.
- Unsupported speech recognition or unavailable on-device model: return a typed analyzer error; never use a server fallback.
- Invalid media or cancellation: surface the analyzer failure without blocking project open or corrupting project state.
- OCR disabled by `LUMEN_NO_OCR=1`: skip OCR and preserve existing masks.
- Malformed timeline values: clamp geometry/times or omit invalid derived spans.

## Approach
Add focused tests first. Move shared plain value types into LumenProject, add backward-compatible privacy/layout settings, and complete the pure layout, placement, mask, transcript, caption, and emphasis algorithms. Add a LumenAnalysis target with cancellable Vision/Speech/AVFoundation readers and atomic content-keyed caches. Wire optional background analysis and the CLI flag without changing renderer behavior.

## Steps
1. Add synthetic regression tests for secret classification, mask identity/approval, transcript tidy, caption timing, and layout geometry. Verify they fail or cannot build against the partial tree.
2. Fix model ownership and backward-compatible privacy/layout decoding. Verify `swift test`.
3. Complete Director algorithms and analysis value wiring. Verify pure unit tests.
4. Add LumenAnalysis target, cache, and local analyzers. Verify release build and analyzer tests.
5. Wire project background analysis and `lumen-cli analyze --run-analyzers`; verify cache privacy and CLI JSON.
6. Run full tests and release build; attempt the requested real recording checks and report any environment limitation precisely.

## Files
`Sources/LumenCore/Sensitive.swift`; `Sources/LumenProject/{AnalysisTypes,Derived,Models,Overlays,Commands}.swift`; `Sources/LumenDirector/{Director,Layout,Placement,MaskTracks,Captions,TranscriptOps,Emphasis}.swift`; `Sources/LumenAnalysis/*.swift`; `Sources/LumenExport/ProjectSession.swift`; `Sources/LumenUI/{EditorModel,EditorView}.swift`; `Sources/LumenCLI/LumenCLI.swift`; `Sources/LumenRender/FaceAnalyzer.swift`; `Package.swift`; `Sources/LumenApp/Info.plist`; `Docs/Decisions.md`; `Tests/LumenTests/Part23Tests.swift`.
