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
