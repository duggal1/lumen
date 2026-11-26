# Plan: Zero-lag: 60 FPS video, no freeze on click

## Goal (2-3 lines)
Make the preview render path run at 60 FPS with per-frame CPU+GPU well inside a
16.7 ms budget, kill the per-click stall the user reports (video freezes for
seconds then resumes), and keep upscaling crystal clear (Upscaler chain,
engagement factor, lookahead quantization) while cutting per-frame lag.

## Non-goals
- Export path (Exporter), webcam/ matte visuals, captions, click ripple,
  privacy masks shader changes, Director quality/accuracy changes.
- Anything outside Renderer.swift / ContentPass.swift / Upscaler.swift /
  LiveFrameSource.swift / LivePreview.swift / Director call sites.

## Where it changes (files)
- Sources/LumenRender/LiveFrameSource.swift — move `CVMetalTextureCacheCreateTextureFromImage`
  out of the lock; snapshot under lock, build texture outside, store when still current.
- Sources/LumenRender/PersonMatteSequence.swift — matte frame reads are
  synchronous on the render thread; make them non-blocking (drop on staleness
  already handled by `indices()`).
- Sources/LumenRender/Renderer.swift — audit per-frame path (`encode`/`scene`):
  per-subframe hashers, `maskedSource`, `screenMip` blits, mip chain; trim what
  is not measured-needed; measure with the harness first.
- Sources/LumenRender/ContentPass.swift + Upscaler.swift — verify the cache
  contract keeps upscale hits while region/factor change slowly; the
  `Last`-cache is per frame-id — check whether preview's frame id changes per
  tick (it shouldn't; ReaderFrameSource is sample-and-hold).
- Sources/LumenUI/LivePreview.swift — main-thread texture creation per tick.
- Sources/LumenUI/EditorModel.swift — verify replan (Director.derive) stays
  off the render thread during clicks; measure its cost.

## How (approach)
1. Baseline: `swift build`; run `RenderBenchmark` (1920x1080, 120 frames) via a
   temporary test to get per-frame avg/p95/worst before changes.
2. Instrument the render path minimally (existing PresentStats + a temporary
   per-frame CPU timer around `encode`) — no behavior change.
3. Apply the fixes in order of measured weight: LiveFrameSource restructure
   first (explicitly reported by the user), then the per-frame hot spots, then
   click-path verification + any cancelable-work fix.
4. Keep Upscaler quality: factors/quantization untouched unless measurements show
   churn (then raise quantize grid / check `Last`-cache keys).

## Verification (aggressive real checks)
- `swift build` — green.
- `swift test --filter CameraAccuracyTests` and `swift test --filter BrutalZoom` — pass, no regressions.
- Temporary RenderPerf test: 1080p 120-frame run, avg < 16.7 ms/frame (target
  <= ~8 ms), p99 within budget, worst not exploding.
- Measure director derive per click path (synthetic event stream through
  Director.deriveCancellable) — report before/after.
- Report what was run and actual numbers; anything not measurable is named.
