# Voice processing contract

One shared microphone processor feeds preview, stems, export and clean-voice
caches. The final stereo master is also shared by preview and export. No new
AudioPlan fields or UI controls are introduced.

## Signal flow

Mono source → gentle 70 Hz high-pass → one trained noise-reduction pass → one
WPE room predictor → optional event-aware de-click → mild tone EQ → one soft-knee
compressor → microphone gain → timeline mix → integrated loudness gain → linked
lookahead limiter → bounded loudness correction → measured true-peak safety.

The old studio finisher was not called by the mixer. Its three compressors,
parallel density bus, gain rider, aggressive expander and saturation are removed.
The active finisher has three mild tone filters and one compressor. No hidden
+2 dB microphone gain remains.

## Existing controls

| AudioPlan field | Processing |
|---|---|
| `micClean` | Enables trained DeepFilterNet3 noise reduction. Failure/unavailability uses bounded spectral Wiener suppression, rather than raw passthrough. |
| `noiseReductionStrength` | Zero bypasses denoising; 0–1 sets neural attenuation and the fallback's attenuation limit (up to 18 dB). Frequency/time smoothing avoids hard gates. |
| `dereverb` | Zero bypasses room prediction. 0–1 blends up to 65% predicted direct signal, preserving dry voice. One WPE pass, four taps, prediction through 4 kHz; no stacked tail suppressor. |
| `voiceClarity` | Independently enables +0.8 dB low shelf at 130 Hz, −1.2 dB broad mud cut at 300 Hz, +1.5 dB broad presence at 3 kHz. No air boost or saturation. |
| `studio` | Continuous compressor strength; zero bypasses. Speech-relative threshold, 8 dB soft knee, 20 ms attack, 200 ms release, up to 2 dB makeup. No automatic input gain riding. |
| `studioMode` | Same compressor; maximum ratio 2.5:1 standard, 3:1 optimized. No alternate processing chain. |
| `declick`, `declickDepthDb` | Optional 2–8 kHz attenuation around recorded keys, with gentler treatment during speech. No added audio delay. |
| `micGainDb` | Explicit post-processing source gain, including independent microphone stems. Zero means unity. |
| `systemGainDb` | Explicit system-audio source gain; voice cleanup never processes the system track. |
| `normalize` | Enables gated BS.1770 integrated-loudness matching and one bounded post-limiter correction. Off leaves outputGainDb as the sole master gain before peak protection. |
| `targetLUFSOverride`, `micMode` | Override or mode target: standard/podcast −16 LUFS, loud −12 LUFS; off mutes microphones. |
| `outputGainDb` | Explicit master offset, including when normalization is enabled. With normalization, requested loudness is targetLUFS + outputGainDb. |

Peak safety is always active: −1.5 dB sample-limiter headroom, an 80 ms release,
and measured 4× true-peak trimming when required to stay below −1 dBTP. Peak
protection takes precedence if a target cannot be met without excess limiting.
Source gains set the mix balance; normalization can counteract a whole-program
level change. Stems omit the combined master as before.

## Cache and timing

Voice revision `voice-v14-short-chain` and mix revision `mix-v2-short-chain`
invalidate old renders. Voice keys include clarity, studio strength and mode as
well as cleanup settings. The transcription cache uses this same voice render,
so it cannot populate a playback cache with a different signal chain.

All processing preserves source sample count and timestamps. First-window preview
uses the same algorithms on a prefix; its estimated noise profile, dynamics and
loudness can differ from full-program analysis. The completed mix is the shared
preview/export result. This change does not promise identical provisional levels
before the full recording has been measured.

## Verification boundary

Use `make build` and the focused audio regressions only. No full suite, stress
runs, benchmark, or exhaustive render matrix. Synthetic checks cover parameter
wiring/cache invalidation, noise bypass/bounds, room-tail energy, echo fidelity,
pure source/master gains, measured LUFS and true-peak safety. Real fan/keyboard
recordings and reverberant speech still require listening before claiming
artifact-free or studio-quality output. Spectral tail reduction alone failed the
existing echo-fidelity case and is not used in the microphone chain.
