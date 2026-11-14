# Lumen validation checklist

Status: every **WIRED** row below has a source file and at least one named test
that runs in `swift test`. **PARTIAL** rows work but have a stated limit.
**MANUAL** rows need a real project/device and are not covered by CI.

Run everything with:

```sh
swift test
swift build --build-tests
```

## Agent 3 surface

| Feature | Source | Proof (named test) | Status |
|---|---|---|---|
| Photo background model + round-trip | `Sources/LumenProject/Models.swift` (`BackgroundKind.image`, `Style.setPhotoBackground/clearPhotoBackground`) | `downloadedPhotoBecomesTheCanvasBackground` | WIRED |
| Unsplash search/download/cache | `Sources/LumenUI/PhotoBackground.swift` (`UnsplashClient`, `PhotoCache`, `PhotoBackgroundService`) | `unsplashSearchDownloadsOnceAndCachesTheFile` | WIRED |
| Missing Unsplash key fails loudly | `Sources/LumenUI/PhotoBackground.swift` (`UnsplashCredentials.resolve`) | `unsplashMissingKeyFailsLoudly` | WIRED |
| Image rendered as canvas backdrop | `Sources/LumenRender/Renderer.swift`, `Sources/LumenRender/Shaders/Shaders.metal` (shader kind 8, cover fit) | `downloadedPhotoBecomesTheCanvasBackground` (model/round-trip) + `rendererAndExportRoundTrip` (real renderer) | WIRED |
| Independent padding insets + per-corner radii + shadow | `Sources/LumenProject/Models.swift` (`EdgeInsetsN`, `CornerRadii`), `Sources/LumenRender/Renderer.swift` (`Geometry`) | `independentPaddingRadiiAndShadowSurviveRoundTrip` | WIRED |
| MCP preferences (opt-in, port clamp) | `Sources/LumenUI/MCPService.swift` (`MCPPreferences`) | `mcpPreferencesAreOptInAndClampThePort` | WIRED |
| MCP disabled opens no listener | `Sources/LumenUI/MCPService.swift` (`MCPHost.configure`) | `mcpHostStaysOffUntilEnabled` | WIRED |
| MCP JSON-RPC routing / 6 tools | `Sources/LumenUI/MCPService.swift` (`MCPRouter`) | `mcpInitializeListsToolsAndCallsStatus`, `mcpRoutesRecordingAndExportActions`, `mcpErrorsAreJSONRPCShapedAndNotificationsStaySilent` | WIRED |
| MCP loopback socket | `Sources/LumenUI/MCPService.swift` (`MCPTCPServer`) | `mcpListenerAnswersOnALoopbackSocket` | WIRED (localhost only, no auth) |
| Email opt-in + per-event trigger | `Sources/LumenUI/EmailNotifications.swift` | `emailTriggerRespectsOptInAndSendsOneDraftPerEvent`, `emailExportNotificationSendsOnlyWhenExportIsEnabled` | PARTIAL (mailto draft, no SMTP) |
| mailto encoding | `Sources/LumenUI/EmailNotifications.swift` (`EmailMessage.mailtoURL`) | `mailtoDraftEncodesSubjectAndBody` | WIRED |
| Flash-and-click sync across cuts | `Sources/LumenDirector/SyncHarness.swift` | `flashAndClickStayOnTheSameFrameAcrossCuts`, `syncHarnessCatchesAShiftedClickCue` | WIRED |
| Frame-budget policy | `Sources/LumenRender/PerformanceHarness.swift` (`FrameBudget`) | `frameBudgetPassesSixtyFPSAndFailsHalfRate`, `renderBenchmarkEnforcesTheFrameBudgetPolicy` | WIRED |
| Real Metal benchmark | `Sources/LumenRender/PerformanceHarness.swift` (`RenderBenchmark`), `Sources/LumenCLI/Agent3Commands.swift` (`bench`) | `renderBenchmarkRunsRealMetalFrames` | WIRED (skips when no Metal device) |
| Golden image compare | `Sources/LumenExport/GoldenImage.swift` (`GoldenComparison`) | `goldenComparisonDetectsChangedPixelsAndSizeMismatch` | WIRED |
| Golden PNG + BGRA capture | `Sources/LumenExport/GoldenImage.swift` (`loadPNG`, `writePNG`, `init(pixelBuffer:)`) | `goldenPNGRoundTripsAndCapturesFromPixelBuffer` | WIRED |
| Golden CLI | `Sources/LumenCLI/Agent3Commands.swift` (`golden`) | shares the tested harness; needs a real project bundle | MANUAL |
| 10-minute derive time/memory | `Tests/LumenTests/LongCaptureTests.swift` | `longCaptureStaysWithinTimeAndMemoryBudget` | WIRED (synthetic 60 fps session) |

## Studio reliability lanes

These rows cover the work described in `Docs/STUDIO-RELIABILITY-HANDOFF.md` and
`Docs/ZOOM-MOTION-PLAN.md`. Each named test runs in `swift test`.

| Lane | Feature | Source | Proof (named test) | Status |
|---|---|---|---|---|
| Typing | A keystroke without a mouse click still produces a real caret target | `Sources/LumenCapture/Input.swift` (`FocusState.lastGood`) | `burstWithoutMouseClickProducesValidCaretTarget` | WIRED |
| Typing | A stale pointer in another corner cannot steal typing focus | `Sources/LumenCapture/Input.swift` (`reserveFocus`, `lastFocusIndex`) | `pointerInOppositeCornerDoesNotStealTypingFocus` | WIRED |
| Typing | Each key is delivered once, with its own resolved sample | `Sources/LumenCapture/Input.swift`, `Sources/LumenDirector/LiveCamera.swift` | `failingFocusQueryStillDeliversKeyExactlyOnce`, `lateFocusEnrichmentUpdatesSameEventWithoutDuplicate` | WIRED |
| Typing | A new focus surface never publishes the previous surface's frame | `Sources/LumenCapture/Input.swift` (`epoch`) | `differentFocusContextsNeverPublishFirstFrameForSecond`, `focusEpochChangesWhenFocusContextChanges` | WIRED |
| Typing | Verified host comes only from browser AX evidence | `Sources/LumenCapture/Input.swift` | `verifiedHostIsDerivedOnlyFromBrowserAXEvidence` | WIRED |
| Typing | Typing keeps the caret framed with no trailing | `Sources/LumenDirector/Planner.swift`, `Sources/LumenDirector/Camera.swift` | `typingKeepsCaretFramedWithoutTrailing` | WIRED |
| Playback | Play starts video and audio on the same frame | `Sources/LumenUI/EditorModel.swift` (`TransportTiming`) | `playStartsVideoAndAudioTogether` | WIRED |
| Playback | The first audible window carries mic and cue audio | `Sources/LumenAudio/Mixer.swift` (`mixFirstWindow`) | `firstAudibleWindowCarriesMicAndCueAudio` | WIRED |
| Playback | A silent project is never blocked waiting for audio | `Sources/LumenUI/EditorModel.swift` (`audioReady`) | `silentProjectIsNotBlockedOnAudio` | WIRED |
| Playback | Cancelling preparation leaves no detached work behind | `Sources/LumenAudio/Mixer.swift`, `Sources/LumenAudio/ProcessedVoice.swift` | `cancelledPreparationLeavesNoDetachedWork` | WIRED |
| Playback | Opening the editor returns before heavy audio preparation finishes | `Sources/LumenExport/ProjectSession.swift` (`openEditor`) | `editorOpenReturnsBeforeHeavyPreparationFinishes` | WIRED |
| Playback | A warm reopen reuses the prepared mix | `Sources/LumenExport/ProjectSession.swift`, `Sources/LumenAudio/ProcessedVoice.swift` | `warmReopenReusesPreparedAudio` | WIRED |
| Zoom | Camera trace is smooth: no position steps, < 1 % energy above 8 Hz | `Sources/LumenDirector/Camera.swift` | `motionTracesAreSmooth` | WIRED |
| Zoom | The track publishes the derivatives it generated | `Sources/LumenDirector/Camera.swift` | `cameraTrackPublishesAcceleration` | WIRED |
| Zoom | No acceleration step at a stored sample boundary (C2 between ticks) | `Sources/LumenDirector/Camera.swift` (`qhm`) | `evaluatedAccelerationHasNoTickBoundaryStep` | WIRED |
| Zoom | Shot handoffs keep acceleration continuous | `Sources/LumenDirector/Camera.swift` (`pathContinues`) | `handoffsKeepAccelerationContinuous` | WIRED |
| Zoom | One zoom-out per scene reaches full frame and stays | `Sources/LumenDirector/Planner.swift` | `zoomOutReachesFullFrameAndStays` | WIRED |
| Zoom | Click targets land within two source pixels at nine positions | `Sources/LumenDirector/Planner.swift` | `verifiedButtonCentersLandWithinTwoSourcePixelsAtNinePositions`, `clickOffsetInsideAXElementMustTargetExactClickedPixel` | WIRED |
| Zoom | Shortcuts, scroll and jitter never invent zoom | `Sources/LumenDirector/Planner.swift` | `keyboardShortcutsAndSingleKeysNeverInventZoom`, `scrollAndJitterNeverZoom` | WIRED |
| Zoom | The camera arrives on the click, not early | `Sources/LumenDirector/Planner.swift` | `cameraArrivesByClickAndNotEarly`, `automaticZoomAnticipatesClickAndArrivesOnTime` | WIRED |
| Zoom | Follow smoothing neither trails constant motion nor chases wiggles | `Sources/LumenDirector/Camera.swift` (`zeroPhaseSmooth`) | `followSmoothingDoesNotTrailConstantMovementOrChaseTinyWiggles` | WIRED |
| Privacy | A new page resets the masking context, never bridges across pages | `Sources/LumenProject/Overlays.swift` (`surfaceStart`), `Sources/LumenDirector/MaskTracks.swift` | `navigationResetsTheContextAndNeverBridgesAcrossPages` | WIRED |
| Privacy | Context track is run-length encoded and answers by source time | `Sources/LumenProject/Overlays.swift` (`context(at:)`) | `contextTrackIsRunLengthEncodedAndAnswersBySourceTime` | WIRED |
| Privacy | Corpus: zero false masks on public pages, every in-policy secret covered | `Sources/LumenAnalysis/OCR.swift`, `Sources/LumenDirector/MaskTracks.swift` | `privacyCorpusHasNoFalseMasksAndCoversEveryTrueSecret` | WIRED |
| Privacy | A mask back-extends but stores no raw OCR text | `Sources/LumenDirector/MaskTracks.swift` | `maskBackExtendsAndStoresNoRawText` | WIRED |
| Cursor | Every stock shape gets its own artwork and ink under its hotspot | `Sources/LumenRender/CursorAtlas.swift` | `everyStockShapeGetsItsOwnArtwork`, `everyStockShapeHasInkUnderItsHotspot` | WIRED |
| Cursor | A capture strip is written for every stock shape | `Sources/LumenRender/CursorAtlas.swift` | `cursorStateStripIsWrittenForEveryStockShape` | WIRED (skips when no Metal device) |
| Cursor | Hotspot stays on the click point under zoom and size compensation | `Sources/LumenRender/Renderer.swift`, `Sources/LumenRender/CursorAtlas.swift` | `hotspotStaysOnTheClickPointUnderZoomAndSizeCompensation` | WIRED (skips when no Metal device) |
| Click | The ripple envelope starts and ends at nothing, one hump, no overshoot | `Sources/LumenRender/ClickEffects.swift` (`ClickEnvelope`) | `rippleEnvelopeStartsAndEndsAtNothing`, `rippleEnvelopeIsContinuousWithOneHumpAndNoOvershoot` | WIRED |
| Click | A tap keeps its exact position as the ripple hotspot | `Sources/LumenDirector/Cursor.swift` (tap pinning), `Sources/LumenDirector/Director.swift` | `aTapKeepsItsExactPositionAsTheRippleHotspot`, `aTapRippleIsCentredOnTheTapHotspot` | WIRED |
| Click | Overlapping clicks keep their own hotspot and envelope | `Sources/LumenRender/ClickEffects.swift` (`ClickPulses.active`) | `overlappingClicksKeepTheirOwnHotspotAndEnvelope` | WIRED |

### Not covered by `swift test`

- Real screen capture, hardware audio/video skew and 30-minute drift: needs a
  physical recording and a loopback measurement.
- The `zoom-verify` fixtures and before/after motion clips: they consume a real
  project bundle.
- p95 Studio-entry and playback-startup budgets, and the export throughput
  numbers: measured on the 2-minute 4K60 reference recording with
  `lumen-cli bench`, not in CI.

## Manual smoke checks

```sh
# Real Metal loop; exits non-zero if the frame budget is missed.
.build/debug/lumen-cli bench --frames 6 --width 320 --height 180 --fps 60

# Needs a project bundle/recording; first run writes references, next run diffs.
.build/debug/lumen-cli golden /path/to/Project.lumen --reference /tmp/golden --update
.build/debug/lumen-cli golden /path/to/Project.lumen --reference /tmp/golden
```

## Explicitly unsupported / limited

- **Email**: opens a `mailto:` draft through the default mail client. There is
  no SMTP sender, credential storage, or server-side delivery.
- **MCP**: bound to `127.0.0.1` only, opt-in from Settings, JSON-RPC over raw
  TCP with newline-delimited messages. No authentication, TLS, or remote access.
- **Unsplash**: requires `LUMEN_UNSPLASH_ACCESS_KEY` (env) or
  `LumenUnsplashAccessKey` (UserDefaults). Downloads are cached on disk; there
  is no offline bundled photo library.
- **Sync harness**: validates the Director's frame model, not a live capture
  device. The CLI `sync` subcommand still reports offsets only.
- **Golden suite**: not wired into `make verify`; reference PNGs must be
  established per project with `--update`.
- **Long capture**: the CI test uses a synthetic 10-minute / 60 fps stream, not
  a real hour-long recording; the real-device run still needs hardware time.
- **Clean-machine permissions**: Screen Recording / microphone / camera prompts
  and notarization are verified manually, not in CI.
