# Lumen — Requested features: what actually works (brutal audit, 2026-11-07)

Status key: **WIRED** = implemented + tested. **PARTIAL** = exists but limited/off-by-default. **MISSING** = not implemented or dead code.

| Feature | Status | Evidence |
|---|---|---|
| Automatic zoom (clicks) | WIRED | `LumenDirector/Planner.swift`, click-wins focus, `ZoomPrecisionTests` |
| Manual zoom (add/position) | WIRED | `Commands.addZoom*`, `TimelineStrip` drag, Inspector Camera |
| Smart framing (webcam vs cursor) | WIRED | `Placement.swift` predictive click avoidance |
| 6.5× upscaler | PARTIAL | Measured: ladder {2,3,4,6,8}, mag 6.5→8×; `upscalerProducesMeasuredResolution` proves 256px@6×→1536px. Training-free, not a trained AI model |
| Glass loupe | WIRED | `Loupe`, `loupeFS`, placement by preview click; `glassLoupeMagnifiesAndFollowsCursor` |
| Zoom depth/duration/easing/focus | WIRED | `CameraParams` + Inspector Camera tab + per-segment easing |
| Multiple layouts | WIRED | `LayoutKind` (5), `LayoutSolver` 120Hz spring |
| Camera cutout (on-device) | PARTIAL | Vision person matte `.lmask`, renderer integration exists; needs webcam on |
| Face tracking | WIRED | `FaceAnalyzer` + `WebcamFraming` |
| Hide during silence | WIRED | `LayoutSettings.hideOnSilence` + VAD placement; `webcamHidesDuringSilence` |
| Smooth layout transitions | WIRED | Single 12-float spring over all layouts |
| Smooth cursor | WIRED | PCHIP + median + Gaussian + min-jerk glide, click pinning |
| Motion blur | WIRED | Adaptive subframe accumulation in `Renderer`; `motionBlurAccumulatesSubframesUnderMotionOnly` (dead `MotionBlurParams` removed) |
| Click effects (ripple/pulse/burst) | WIRED | `ClickEffect`, `ringFS`, color/duration persisted + tested |
| Cursor styling (pack/size) | WIRED | `CursorAtlas` vector art + captured custom cursors (id ≥1000) |
| Hide when idle | WIRED | `CursorStyle.idleHide`; `cursorHidesWhenIdleAndReturnsOnMove` |
| Loop cursor position | WIRED | `CursorStyle.loop` min-jerk tail glide; `loopCursorGlidesBackToStart` |
| Any aspect ratio export | WIRED | `CanvasAspect` + `customAspect`, batch 1:1/9:16 |
| Automatic re-aim on aspect change | WIRED | Layout/caption/zoom re-derive on style change |
| Backgrounds/padding/shadow | WIRED | solid/gradient/dither/wave/field/canvas/wallpaper, insets, radii, shadow |
| Photo backgrounds (Unsplash) | WIRED | `Style.backgroundImagePath` + `BackgroundKind.image`, cover-fit backdrop shader; `LumenUI/PhotoBackground.swift` key from `LUMEN_UNSPLASH_ACCESS_KEY`/`LumenUnsplashAccessKey`, on-disk `PhotoCache`; `unsplashSearchDownloadsOnceAndCachesTheFile`, `downloadedPhotoBecomesTheCanvasBackground`, `unsplashMissingKeyFailsLoudly` |
| Independent insets / corner radii / shadow | WIRED | `EdgeInsetsN`, `CornerRadii(tl,tr,br,bl)`, decoder back-compat; `independentPaddingRadiiAndShadowSurviveRoundTrip` |
| MCP server control | WIRED | `LumenUI/MCPService.swift`: opt-in JSON-RPC 2.0 / MCP 2025-06-18 on `127.0.0.1:8765`, tools status/start/stop/pause/open/export; `MCPPreferences` port clamp, `MCPRouter`, loopback `MCPTCPServer`; `mcpInitializeListsToolsAndCallsStatus`, `mcpPreferencesAreOptInAndClampThePort`, `mcpHostStaysOffUntilEnabled`, `mcpListenerAnswersOnALoopbackSocket` |
| Auto-email notifications | PARTIAL | `LumenUI/EmailNotifications.swift`: opt-in mailto draft on recording/export via `NSWorkspace`; no SMTP/credentials, so the user still clicks Send; `emailTriggerRespectsOptInAndSendsOneDraftPerEvent`, `emailExportNotificationSendsOnlyWhenExportIsEnabled`, `mailtoDraftEncodesSubjectAndBody` |
| Flash-and-click sync harness | WIRED | `LumenDirector/SyncHarness.swift` measures click→output→first-frame drift, cue drift, early/late rings across cuts; `flashAndClickStayOnTheSameFrameAcrossCuts`, `syncHarnessCatchesAShiftedClickCue` |
| GPU frame-budget benchmark | WIRED | `LumenRender/PerformanceHarness.swift` real Metal loop + p99/over-budget gate; `lumen-cli bench` exits 1 on miss; `renderBenchmarkRunsRealMetalFrames`, `frameBudgetPassesSixtyFPSAndFailsHalfRate`, `renderBenchmarkEnforcesTheFrameBudgetPolicy` |
| Golden-image suite | WIRED | `LumenExport/GoldenImage.swift` RGBA8 compare/PNG/BGRA capture; `lumen-cli golden <project> --update` then fail on drift; `goldenComparisonDetectsChangedPixelsAndSizeMismatch`, `goldenPNGRoundTripsAndCapturesFromPixelBuffer` |
| Long capture / memory gate | WIRED | synthetic 10-minute 60 fps derive (12k moves, 100 clicks) under a resident-memory ceiling; `longCaptureStaysWithinTimeAndMemoryBudget` |
| Presets (Looks) | WIRED | `LookPreset` save/apply in Application Support |
| Flexible capture (display/window/region) | WIRED | `RecordingConfig.Source`, region selector |
| Multi-source (screen+webcam+mic+system) | WIRED | `CaptureEngine` + extra mics + webcam recorder |
| Crash recovery | WIRED | 1s `RecordingJournal`, `recoverFromJournal`, RecoveryScanner |
| Pause & resume | WIRED | Pause spans become cuts; audio silence inserted |
| Countdown & hotkeys | WIRED | 3-2-1 HUD, Cmd+Opt+R start/stop, Cmd+Opt+P pause; `appModelHotkeyStateMachineStartsIdle`, `countdownPhaseReportsSeconds` |
| iPhone/iPad USB recording | PARTIAL | `DeviceCapture` Continuity discovery + loud failure; screen needs companion app (documented). `deviceDiscoveryNeverCrashesAndUnknownDeviceFailsLoudly` |
| Transcript editing (delete text = cut) | WIRED | Word delete/edit + filler removal; `TranscriptOps.sentences/sentenceCut` (sentence = one cut); `sentenceDeleteProducesCutForWholeSentence` |
| Cursor relink for external edit | WIRED | `CursorRelink` sidecar (`<name>.cursor-relink.json`) next to cursor layer; validation + instructions; `cursorRelinkSidecarRoundTripsAndValidatesReplacement` |
| Filler/pause removal | WIRED | `TranscriptOps` filler + pause cuts, suggestions merged |
| Timeline trim/speed ramps/multi-clip | WIRED | `TimeMap` trims/cuts/ramps, `TimelineClip` import |
| Import video | WIRED | `importClips`, appended in output time, share package copies clips |
| On-device noise reduction | WIRED | RNNoise vendored (`Sources/CRNNoise`, `CRNNoise` target); `defaultDenoiser` is `RNNoiseDenoiser`; `rnnoiseVendoredAndDefaultDenoiserActive` |
| Podcast mode | WIRED | `MicMode.podcast` EQ preset in `VoiceStudio` |
| Mic modes (standard/loud/off) | WIRED | `MicMode` + LUFS targets |
| Separate mic/system levels | WIRED | `micGainDb`/`systemGainDb`, stems per source |
| On-device transcription | WIRED | Moonshine streaming (local model files/download via `ModelDownloader`); editor falls back to Apple Speech when model missing; `fileTranscriberHandlesRealSilentAudioWithoutCrashing` |
| Caption styles/positioning | WIRED | `CaptionPlan/Style`, aspect/layout-aware Y |
| Sensitive masks (blend) | WIRED | OCR hash-only, `MaskTracks`, blend samples outside rect |
| Highlight tool | WIRED | `Highlight` dim/outline/glow, placement by click |
| Offline-first | PARTIAL | Capture/edit/export and transcription models stay local; the only network path is opt-in Unsplash photo download (`LUMEN_UNSPLASH_ACCESS_KEY`), and the only listener is the opt-in MCP server on `127.0.0.1` |
| Export MP4 4K60/8K120/GIF/ProRes | WIRED | `ExportPresets`, capability probe, never silently changes preset; `eightK120ExportPresetIsRealAndH264StaysGated` |
| Shareable browser links | PARTIAL | `lumen://` deep link + `.lumenshare` package; share round-trip tested; no hosted web player/comments (external hosting is out of scope for the on-device build — the package itself is the shareable artifact) |
| Project sharing | WIRED | `exportSharePackage`/`installSharePackage` via ditto zip |
| Clipboard export | WIRED | 1080p H.264 to pasteboard as file URL; real `NSPasteboard` write verified; `clipboardWritesRealFileURLToPasteboard` |
| Native Apple Silicon / HW encode | WIRED | VideoToolbox hardware-only probe + encode |
