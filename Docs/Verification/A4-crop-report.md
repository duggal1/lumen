# A4 — Smart auto-crop + typing-synced zoom (report)

Agent cw-8479. No commit (supervisor integrates). No branch switch.

## Files changed

- `Sources/LumenDirector/Crop/ChromeDetector.swift` (NEW) — vision fallback:
  `contentRect(edges:...)` from a downsampled edge grid and
  `contentRect(pixels:...)` from raw 8-bit luminance (Sobel magnitude). Longest
  contiguous low-edge row/column bands define the true content rect. `edgeGrid(...)`
  is the single grid builder shared with live capture. Emits `chrome.detect.grid`.
- `Sources/LumenCapture/Capture.swift` (follow-up) — `CaptureVisionFallback` pure
  gate + pipeline; the SCK sample loop now detects chrome from pixels when
  AX/AXWebArea resolution returns no usable rect and feeds the result through
  `CropPlanner.contentRect(fromEdges:)`, publishing it via the existing
  `chromeFraction` → `FrameCropper` path. Emits `capture.vision.detect`.
- `Sources/LumenDirector/Crop/CropPlanner.swift` — added PxRect
  `SmartCropPlanner.aspectFit` (grow-to-source-aspect, clamp into source,
  0.5% near-aspect passthrough so a stable AXWebArea does not breathe), applied
  to the `.content` rect; added `CropPlanner.contentRect(fromEdges:...)` that
  maps the vision result into the same source-pixel crop shape.
- `Sources/LumenDirector/TypingFocus.swift` — per-keystroke `Caret` samples on
  `Shot`; named `idleTimeout` (0.9 s) / `sameFieldIdleTimeout` (1.5 s) burst
  debounce; `exitDebounce` constant.
- `Sources/LumenCapture/WindowContent.swift` — `ContentSource` /
  `ResolvedContent`, bounded AXWebArea BFS (Chrome, Safari, Arc, generic),
  `resolveContent(...manualOverride:)`. Kept `resolve()`'s historical
  chrome-band inset intentionally (see limits).
- Tests: `Tests/LumenTests/AutoCropFixtureTests.swift`,
  `Tests/LumenTests/TypingZoomFixtureTests.swift` (14 tests; added
  `visionFallbackIsTrueSourcePixelCropNotZoom`).

## Measurements

- `swift build --target LumenCapture`: OK. Full `swift build`: OK.
- A4 fixtures: **14/14 pass**, 0.23 s total.
- Capture/viewport filter: **36/36 pass**, 5.6 s total.
- Crop bake benchmark: 5 × (30 s @ 480 Hz) = **82.2 ms** (~16 ms per
  14,401-tick plan). Signposts: `crop.plan`, `chrome.detect.grid`,
  `capture.vision.detect`.
- Crop + typing filter: 85/86 pass (sole failure unrelated — see limits).
- Existing `TypingFocusTests`, `TypingFocusQ1Tests`, typing/audio,
  `ZoomFramingAccuracyTests`: all pass.

## Design notes

- This is a **true source-pixel crop**: the AXWebArea (or detected vision)
  band is inset, aspect-fitted to the output, and handed to the existing
  compositor as a crop rect. No camera zoom factor was added.
- Stability: Gaussian rect tracking (20 Hz), quintic rest-to-rest mode blends,
  `minDwell` run merging; `jitterySamplesProduceStableTrack` pins max jump.
- Typing: one shot per burst, caret path carried on the shot; the camera keeps
  a stable field target (per existing `typingCentreIsSteadyAcrossACaretWrap`)
  rather than chasing the caret, so there is no zoom-bounce between keys.

## Known limits (honest)

1. The live fallback re-detects at most ~1 Hz (and on window resize/AX change),
   so a toolbar that appears between probes is cropped one beat late. The AX
   path remains first choice and is unchanged. Detection samples a 96×64
   luminance grid by strided pixel reads (no pixel-buffer copy).
2. `TypingFocus.exitDebounce == 0`: the critically damped camera release owns
   the zoom-out. A baked tail would break two existing `TypingFocusTests`
   assertions that pin `Shot.t1 == last keystroke`. Burst splitting still uses
   the named idle timeouts, and the camera returns to full frame after the
   burst (verified by `directorTypingZoomsInAndBackOut`).
3. `WindowContent.resolve()` deliberately keeps its chrome-band inset rather
   than switching to the AXWebArea top edge: capturing the physical frame only
   down to the web area would remove the pixels needed by the typing/chrome
   uncrop reveal. `resolveContent()` exposes the full AXWebArea result.
4. One unrelated red test remains: `TypingFocusBrowserCropTests.swift:118`
   ("non-browser got a crop"). A recent edit to that file replaced the correct
   empty-track/`ZoomTransform` product assertion with
   `crop() == bounds`; an empty crop track yields a zero rect. My changes only
   touch `CropPlanner.plan` when `samples.count >= 2`, so this is independent.
   Reported to cw-7936 and the supervisor; I did not edit another agent's file.
5. `Camera.swift` was not edited — it is actively claimed by cw-1900 (A1);
   its existing `Baker.rawCenter` typing branch already holds a stable
   source-space target.
