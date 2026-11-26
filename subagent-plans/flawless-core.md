# Plan — Flawless core (subagent 6 of 6): zoom accuracy + 60 FPS smoothness + audio

## Goal (2-3 lines)
Make auto-zoom land accurately on every click with no pops, make the preview + export render
path run at 60 FPS with no stalls, and raise the mixed audio to louder + fuller + legitimate,
all proven by the existing test suite plus LUMEN_ZOOM_DEBUG traces.

## Non-goals
- UI changes (this is the backend subagent; no LumenUI files).
- Changing the documented arrival contract (>= 0.98 in LumenCLI, 0.99 in tests).
- Adding new features or new knobs unless an accuracy gap forces one.
- Export-path changes beyond what "no stalls at 60 FPS" requires.

## Where it changes (files)
- Sources/LumenDirector/Director.swift (LUMEN_ZOOM trace, possible target/arrival fixes)
- Sources/LumenDirector/Camera.swift (bake/tickTargets/safeZoomOmega/omegaZoomBase — arrival + pop + idle float-exactness)
- Sources/LumenProject/Models.swift (CameraParams — only if a fix needs a new default)
- Sources/LumenRender/Renderer.swift (~600-1100: encode loop, sampleCount, travelPx — 60 FPS, no stalls)
- Sources/LumenAudio/Studio.swift (VoiceStudio — louder + fuller voice chain)
- Sources/LumenAudio/Mastering.swift (AudioMaster — louder + legitimate master)
- Sources/LumenAudio/DSP.swift, Mixer.swift, ProcessedVoice.swift (louder + legitimate audio path)
- Sources/LumenRender/ZoomTransform.swift (only if the renderer exposes a wrong contract)
- Tests/ (only to ADD coverage for new behavior; no weakening existing)

## How (approach)
1. Baseline: run `swift build`, then `swift test --no-parallel` on the current tree; record results.
2. Trace: run the zoom tests with `LUMEN_ZOOM_DEBUG=1` (Director prints LUMEN_ZOOM / LUMEN_DIP /
   LUMEN_TYPING lines); collect arrival numbers on the traced scenarios (click at rest, near-end
   click, idle → click). Find gaps vs >= 0.99 / float-exact-when-idle.
3. Fix root causes found (e.g., arrival under 0.99 → adjust omega/lead/activeAt math; pops →
   guard against zero-velocity inject at retarget; stalls → encode path).
4. Audio: measure the mix on the speech fixture — voice LUFS vs bed gap, true peak, promotion
   lift — then raise louder+fuller+legitimate through Mastering/Studio in the legitimate envelope
   (-1 dBTP ceiling, LUFS targets).
5. Verify per step: swift build; swift test --no-parallel; zoom traces again.

## Verification (aggressive real checks)
- `swift build` exit 0.
- `swift test --no-parallel` — all pass; nothing weakened, nothing deleted without REQUEST.
- `LUMEN_ZOOM_DEBUG=1` on zoom tests: LUMEN_ZOOM arrival >= 0.99 on every click; no arrival
  value > 1.05 (overshoot); LUMEN_DIP lines either absent or explaining gaps >= 2.2s by design;
  idle → evaluate(scale) == 1.0 within 1e-6, center within 1e-6 of source center when snap is
  pinned (float-exact when idle).
- 60 FPS: `swift test --filter PerformanceTests` and the frame-budget harness: p99 ≤ 16.7 ms at
  60 fps, late frames ≈ 0 after warm-up, export renders every frame (no drops > 5%).
- Audio: mix of the speech fixture through AudioMixer: voice-vs-bed gap with studio on
  (+2.5 dB at least, no clipping, truePeakDb ≤ -1 + 0.01); LUFS within target ± 3.
- Baseline `swift test` before, same after: no new failures; zero FAIL, zero UNVERIFIED.

## Traced scenarios (from the user ask)
- Camera float-exact when idle: evaluate() during the return-to-rest after a zoom-out.
- Zoom arrival accuracy: LUMEN_ZOOM arrival per click on clicks at rest, mid-recording, near the
  end of the recording, and on the nearest-to-end click fixtures.
- LUMEN_DIP gaps: report gaps where the camera dips below the lower adjacent scene scale
  (legit gaps > 1.5 s where the camera returns to full frame are by design; anything under
  2.2 s counts against us).
- No pops: no sign reversal in lz/pan between consecutive baked ticks around a click; velocity
  steps at retarget ≤ existing smoothness gate (az/ax bound).
