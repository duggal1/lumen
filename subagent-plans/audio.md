# Plan: Audio — louder, fuller, crisper, working noise reduction

## Goal (2-3 lines)
Raise the delivered voice ~+25% LUFS over today (the `voiceBoostDb` default is
calibrated by measurement), sharpen the Studio tone curve (chest, presence,
air) and the compressor so the voice is fuller and crisper, verify the on-device
DeepFilterNet denoise and the expander actually cut background noise in pauses
(the user's "not really there" complaint), and delete the one production-dead
stage (LateReverb).

## Non-goals
- No UI changes; Inspector controls unchanged.
- Keep MicMode.podcast/loud/standard (shipped product feature + migrations).
- Keep DeepFilterNet + SpectralGate (quality tests assert both run) and
  ResidualSuppressor (AudioStudioTests references it directly).

## Where it changes (files)
- `Sources/LumenProject/Models.swift` — `voiceBoostDb` default 2.5 → calibrated
  value (~5, clamped 0...6); update the doc comment.
- `Sources/LumenAudio/Studio.swift` — `tone()`: standard lowShelf 0.5→0.9,
  presence 3000 Hz 2.5→3.5, air 9500 Hz 1.5→2.5; optimized lowShelf 0.9→1.2,
  presence 3.4→4.3, air 2.0→2.8. Compressor in `finish`: threshold
  `level-2-2a` → `level-3-2.5a`, ratio `1+density*a` → `1+density*(0.8+0.6a)`.
- `Sources/LumenAudio/ProcessedVoice.swift` — `Settings.voiceBoost` fallback
  default → new default; bump `revision`/`mixRevision` (tone/compressor/default
  changes alter outputs, so stale caches must not be served).
- `Sources/LumenAudio/LateReverb.swift` — delete (unreferenced anywhere).
- `Tests/LumenTests/AudioStudioQualityTests.swift` — update the expected default
  in `voiceBoostRoundTripsAndInvalidatesCaches` (2.5 → new default; consequence
  of the default change, not a weakened test).
- `Tests/LumenTests/AudioAmpMeasurement.swift` — temporary measurement script,
  deleted after the before/after numbers are taken.

## How (approach)
1. Measure (temp test `AudioAmpMeasurement`, deleted after): on the speech
   fixture + 0.03 white noise print raw LUFS/peak, denoise-only noise floor,
   and `ProcessedVoiceCache.process` LUFS/peak for voiceBoostDb = 0, 2.5, 6
   (slope mode: studio=0, dereverb=0, declick=false, voiceClarity=false) plus
   the default-plan chain at 2.5 ("now"). Calibrate the new default so
   chain(new) − chain(2.5) lands +2.0..+2.6 LUFS.
2. Implement the constants above.

## Verification (real, aggressive)
- `swift build` (cw claim build 900 first).
- Re-run the same measurement script: report chain(2.5) vs chain(new); ratio
  target 1.2–1.35, noise floor in pauses down.
- `swift test --filter AudioStudioTests`
- `swift test --filter AudioStudioQualityTests`
- `swift test --filter BrutalAudioRenderAdversarial`
- `swift test --filter AudioAssetsTests`
- Fix anything the change breaks (e.g., the default-expectation test).
- `cw release` claims; commit only my files to main; no push.
