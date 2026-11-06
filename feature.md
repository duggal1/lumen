# Lumen — Requested features: what actually works (brutal audit, 2026-11-07)

Status key: **WIRED** = implemented + tested. **PARTIAL** = exists but limited/off-by-default. **MISSING** = not implemented or dead code.

| Feature | Status | Evidence |
|---|---|---|
| Automatic zoom (clicks) | WIRED | `LumenDirector/Planner.swift`, click-wins focus, `ZoomPrecisionTests` |
| Manual zoom (add/position) | WIRED | `Commands.addZoom*`, `TimelineStrip` drag, Inspector Camera |
| Smart framing (webcam vs cursor) | WIRED | `Placement.swift` predictive click avoidance |
| 6.5× upscaler | PARTIAL | Training-free Lanczos2/shock upscaler (`Upscaler.swift`), not a trained AI model |
| Glass loupe | WIRED | `Loupe`, `loupeFS`, placement by preview click |
| Zoom depth/duration/easing/focus | WIRED | `CameraParams` + Inspector Camera tab + per-segment easing |
| Multiple layouts | WIRED | `LayoutKind` (5), `LayoutSolver` 120Hz spring |
| Camera cutout (on-device) | PARTIAL | Vision person matte `.lmask`, renderer integration exists; needs webcam on |
| Face tracking | WIRED | `FaceAnalyzer` + `WebcamFraming` |
| Hide during silence | WIRED | `LayoutSettings.hideOnSilence` + VAD placement |
| Smooth layout transitions | WIRED | Single 12-float spring over all layouts |
| Smooth cursor | WIRED | PCHIP + median + Gaussian + min-jerk glide, click pinning |
| Motion blur | WIRED | Adaptive subframe accumulation in `Renderer` (preview ≤2, export up to maxSamples) |
| Click effects (ripple/pulse/burst) | WIRED | `ClickEffect`, `ringFS`, color/duration persisted + tested |
| Cursor styling (pack/size) | WIRED | `CursorAtlas` vector art + captured custom cursors (id ≥1000) |
| Hide when idle | WIRED | `CursorStyle.idleHide` |
| Loop cursor position | WIRED | `CursorStyle.loop` min-jerk tail glide |
| Any aspect ratio export | WIRED | `CanvasAspect` + `customAspect`, batch 1:1/9:16 |
| Automatic re-aim on aspect change | WIRED | Layout/caption/zoom re-derive on style change |
| Backgrounds/padding/shadow | WIRED | solid/gradient/dither/wave/field/canvas/wallpaper, insets, radii, shadow |
| Presets (Looks) | WIRED | `LookPreset` save/apply in Application Support |
| Flexible capture (display/window/region) | WIRED | `RecordingConfig.Source`, region selector |
| Multi-source (screen+webcam+mic+system) | WIRED | `CaptureEngine` + extra mics + webcam recorder |
| Crash recovery | WIRED | 1s `RecordingJournal`, `recoverFromJournal`, RecoveryScanner |
| Pause & resume | WIRED | Pause spans become cuts; audio silence inserted |
| Countdown & hotkeys | WIRED | 3-2-1 HUD, Cmd+Opt+R global hotkey |
| iPhone/iPad USB recording | MISSING | No device capture path in codebase |
| Transcript editing (delete text = cut) | WIRED | Word delete/edit + filler removal; `TranscriptOps.sentences/sentenceCut` (sentence = one cut); `sentenceDeleteProducesCutForWholeSentence` |
| Cursor relink for external edit | WIRED | `CursorRelink` sidecar (`<name>.cursor-relink.json`) next to cursor layer; validation + instructions; `cursorRelinkSidecarRoundTripsAndValidatesReplacement` |
| Filler/pause removal | WIRED | `TranscriptOps` filler + pause cuts, suggestions merged |
| Timeline trim/speed ramps/multi-clip | WIRED | `TimeMap` trims/cuts/ramps, `TimelineClip` import |
| Import video | WIRED | `importClips`, appended in output time, share package copies clips |
| On-device noise reduction | PARTIAL | SpectralGate fallback; RNNoise not vendored (`#if canImport(CRNNoise)` never true in this build) |
| Podcast mode | WIRED | `MicMode.podcast` EQ preset in `VoiceStudio` |
| Mic modes (standard/loud/off) | WIRED | `MicMode` + LUFS targets |
| Separate mic/system levels | WIRED | `micGainDb`/`systemGainDb`, stems per source |
| On-device transcription | WIRED | Moonshine streaming (local model files/download via `ModelDownloader`); editor falls back to Apple Speech when model missing; `fileTranscriberHandlesRealSilentAudioWithoutCrashing` |
| Caption styles/positioning | WIRED | `CaptionPlan/Style`, aspect/layout-aware Y |
| Sensitive masks (blend) | WIRED | OCR hash-only, `MaskTracks`, blend samples outside rect |
| Highlight tool | WIRED | `Highlight` dim/outline/glow, placement by click |
| Offline-first | WIRED | No networking in core app; model import is local folder |
| Export MP4 4K60/8K120/GIF/ProRes | WIRED | `ExportPresets`, capability probe, never silently changes preset; `eightK120ExportPresetIsRealAndH264StaysGated` |
| Shareable browser links | PARTIAL | `lumen://` deep link + `.lumenshare` package; share round-trip tested; no hosted web player/comments (explicitly documented) |
| Project sharing | WIRED | `exportSharePackage`/`installSharePackage` via ditto zip |
| Clipboard export | WIRED | 1080p H.264 to pasteboard as file URL |
| Native Apple Silicon / HW encode | WIRED | VideoToolbox hardware-only probe + encode |
