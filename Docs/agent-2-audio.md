# Agent 2 audio handoff

Branch: `agent-2-audio`. Worktree: `/Users/harshitduggal/workspace/Lumen/lumen-agent-2-audio`.
Merge this branch before Agents 1 and 3. Capture and UI files were not edited.

## Decisions

- The original checkout already included RNNoise, but the mixer reinjected 65% raw microphone audio. That alone limits perfect noise cancellation to 3.7 dB; the new default uses the trained output at full strength.
- The old pretrained model measured 10.6 dB noise reduction on the focused fixture; a second pass reached only 15.0 dB and increasingly misclassified hum as speech. It was replaced with the current upstream pretrained RNNoise model and inference sources rather than adding more gates.
- RNNoise remains the default. Its 48 kHz mono, 480-sample processing uses int16-range input, its actual 960-sample algorithmic delay is flushed/aligned, and its voice probability controls soft gap attenuation with 5 ms speech attack and 80 ms gap release.
- DeepFilterNet3 is shipped for `audio.studioMode == .optimized`. The native ARM64 v0.5.6 executable contains the pretrained weights and runs without Python, Rust installation, network access or model downloads; failures or bounded timeouts log and fall back to RNNoise.
- DeepFilterNet's CLI drops 30 ms when compensating delay and ignores partial input frames. The wrapper writes padding through the existing chunked WAV writer, flushes that delay, then takes exactly the original sample count.
- The spectral dereverb stage is retained conservatively after denoise. It suppresses decaying spectral bins while preserving new attacks and sustained bins; the measured synthetic tail improvement is 5.0 dB with a sustained-tone change of -0.006 dB. This is an objective result, not a listening verdict; perceptual quality is still unverified.
- The voice chain then applies 80 Hz HPF, -2 dB at 250 Hz, +2.5 dB at 3.5 kHz, +1.5 dB air at 10 kHz, light de-essing, gentle level riding, and a 3:1 compressor (-20 dB threshold, 8 ms attack, 120 ms release). Voice clarity controls the EQ/de-ess/level/compressor stage; legacy zero studio strength remains respected.
- Processed voice is normalized to -16 LUFS and peak-limited. The default standard master now also targets -16 LUFS; explicit target overrides and the legacy loud mode retain their requested values. The peak meter includes clip edges and short buffers, with a final correction keeping measured true peak below -1 dBTP.
- The full processed mono 48 kHz Float32 WAV is cached in the project bundle. Its SHA256 key covers every source sample, key-event times, effective voice settings and pipeline revision; volume, system/music/SFX settings and other downstream mix controls do not invalidate it. Preview, export and stems all consume the same mixer voice path.
- Apple voice processing was initialized successfully on this machine at 48 kHz (the engine exposed five input channels). The recorder uses ScreenCaptureKit microphone buffers, so this engine cannot process its existing input node; replacing that graph would require Agent 1 ownership and hardware sync/ducking verification. Capture-side AVAudioEngine processing was deliberately skipped.

## Agent 3 API and UI

```swift
import LumenAudio
let voiceURL = try await cleanVoiceURL(for: session.bundle, settings: timeline.audio)
```

This global async function returns a mono 16 kHz Float32 WAV in microphone-file time, generated off the main actor from the same cached 48 kHz processed voice. Add the existing `session.micOffset` when converting transcript times into source time. Passing `settings` includes unsaved editor choices. Without it the saved project settings are used. Missing microphone audio throws `CleanVoiceError.missingMicrophone`; cancellation propagates and cache files publish atomically.

Caption audio always enables denoise even if microphone playback is muted or noise reduction was disabled. With ordinary enabled settings it reuses the exact mixer 48 kHz WAV. Raw microphone media is never overwritten.

Two added persisted `AudioPlan` fields:

- `noiseReductionStrength: Double = 1.0` (0...1). Bind the Noise reduction slider to it; set `micClean = value > 0` when changing it, and display zero when `micClean` is false.
- `voiceClarity: Bool = true`. Bind the Voice clarity toggle to it.

Those are the only requested audio panel controls. UI belongs to Agent 3 and was not edited here. `await MicrophoneModes.showVoiceIsolationControls()` opens Apple's microphone-mode UI from the UI actor; the selection remains Apple's, not an app-controlled forced setting. Native capture was not changed.

## Pretrained provenance

RNNoise source: https://github.com/xiph/rnnoise/tree/70f1d256acd4b34a572f999a05c87bf00b67730d

Model archive: https://media.xiph.org/rnnoise/models/rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz

The archive SHA256 was checked against that upstream model version. The compiled generated `rnnoise_data.c` SHA256 is `d6021b7697677c4d2274c912975e143765552b0e6f25500aa660fdb4a9849be5`. Runtime sources are upstream with trailing whitespace removed from two files. No training or weight generation was performed. Old inference/model files were removed, not retained as an alternate runtime path. Native inference is compiled with `-O3` in debug and release so the default build also runs the pretrained engine efficiently. Both the source license and packaged notice are included.

DeepFilterNet artifact source, SHA256 and MIT license are bundled at `Sources/LumenAudio/Resources/DeepFilterNet/`. The helper depends only on macOS libSystem and libiconv. Its CLI emits PCM16 internally; the shared cache/handoff is Float32. It ships only for Apple Silicon; other architectures use RNNoise.

## Verification

`make build` passed. One temporary focused native audio repro was compiled outside the source tree; no test files were added and `make verify` was not run. The repro exposed and verified fixes for the old model's inadequate suppression, DeepFilterNet tail truncation, and the old -14 LUFS default.

Final measurements used the existing 2.34 s speech fixture inside a 4.34 s signal with deterministic white noise and 120 Hz hum:

| Check | Result |
| --- | --- |
| RNNoise noise-only segment attenuation | 34.217 dB |
| RNNoise speech-region level change | -0.192 dB |
| Bundled DeepFilterNet total runtime | 0.441 s for 4.341 s audio |
| Spectral synthetic late-tail attenuation | 5.022 dB |
| Spectral sustained-tone level change | -0.006 dB |
| Final shared mix loudness | -16.000 LUFS |
| Final shared mix measured true peak | -4.354 dBTP (below -1 ceiling) |
| RNNoise partial-frame and DF3 duration | Exact original sample count |
| 48 kHz mixer / 16 kHz captions cache reuse | Passed |
| Changed-strength invalidation | Passed |
| Corrupt caption WAV recovery | Passed |
| Independent system audio | Passed |
| Short-buffer true-peak edge | Passed |

These measurements do not establish 25 dB reduction during speech, for all room noise, or for nearby competing speakers. Babble, hardware AEC/ducking, subjective listening, and a real room recording are not verified. Reviewable audio samples are local at `/tmp/lumen-audio-proof-82296606-8D2F-44BA-8395-E7FED0097642/`; they are not committed.

Fresh read-only code review approved the settings cache correction. Vendor source/model replacement was then verified by the targeted repro and build.

## Checklist

- [x] RNNoise vendored, current pretrained weights compiled in, building.
- [x] DeepFilterNet3 evaluated and shipped: faster than realtime on this Apple Silicon machine.
- [x] Dereverb implementation and retention decision made from measured tail/sustain behavior.
- [x] Podcast chain, integrated loudness and peak limiting implemented after denoise.
- [x] Preview/export/stems use the same settings-keyed processed-voice path.
- [x] `cleanVoiceURL(for:)` exposed and validated as mono 16 kHz.
- [x] Apple voice-processing compatibility probed; skipped for the existing ScreenCaptureKit graph.
- [ ] Subjective dereverb/voice listening and real-room/babble acceptance measurements.
- [ ] Agent 3 UI/caption wiring and Voice Isolation UI entry point (handoff provided; UI ownership preserved).
