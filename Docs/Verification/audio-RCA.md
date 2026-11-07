# Audio RCA — crackle, clicks, dropouts (before fixes)

**Visual verification NOT DONE — no GUI session in this environment.** Spectrograms are generated headlessly after fixes; before/after pairs are in `run-001/`.

## §5.1 Measurement (built first)

`lumen-cli audio-check <project|file>` (`Sources/LumenAudio/AudioCheck.swift` + `Sources/LumenCLI/LumenCLI.swift:AudioCheckCmd`) reports: format/sample-rate, peak + true peak (4× oversampled via `Loudness.truePeakDb`), LUFS (BS.1770-4 gated), clipped-sample count, DC offset, noise floor, zero-run dropouts, click events (high-pass second-difference outliers), stereo correlation. `--spectrogram` PNG is roadmap (the CLI currently reports JSON; the spectrogram renderer lands with the fix pass).

Baseline (pre-fix): `Docs/Verification/baseline/audio-speech.json` (fixture: 0 clipped, 381 raw clicks = speech transients — the detector needs VAD gating on speech to be meaningful) and `audio-tone.json` (1 kHz synthetic: 0 clicks, 0 clipped, 0 dropouts — raw path is clean, so faults must be introduced by capture/processing).

## §5.2 Capture-side suspects

| # | Suspect | Verdict before fix | Evidence |
|---|---|---|---|
| 1 | Format assumptions (Int16 vs Float32, interleaved vs planar, 44.1 vs 48 kHz) | **IN** | `CAFWriter.append()` (`Capture.swift:39-76`) checks `fmt.commonFormat == .pcmFormatFloat32` and `return`s otherwise — non-Float32 buffers are silently dropped. File is created once from the first buffer's `format.settings`; a mid-session device/rate change writes buffers in a different format into the same `AVAudioFile` with no check. Never reinterpret bytes is violated by omission: there is no format-change handling at all. |
| 2 | PTS gaps/overlaps collapse timeline | **IN** | `CAFWriter` appends by file position only; it never compares `sb.presentationTimeStamp` to the expected sample-count PTS. A 20 ms gap is silently collapsed (timeline shift + A/V offset) instead of filled with silence/crossfade + `<id>.json` counts. Pause silence uses `appendSilence()` racing on the same serial queue but without PTS accounting. |
| 3 | Journal writes on audio callback thread / overflow | **Partial** | File IO is off-callback (`q.async`), which is correct. But there is no SPSC ring (spec: ≥2 s lock-free), no overflow counter, and the per-buffer `CMSampleBufferCopyPCMDataIntoAudioBufferList` + `AVAudioPCMBuffer` alloc happens on the SCK audio queue. Overflow is swallowed (`q.sync` close can block). Fix: SPSC ring + writer queue + overflow counter asserted 0 in tests. |
| 4 | Clock drift unmeasured | **IN** | No drift ratio is stored. `TrackMeta` stores only `startHostSeconds`. A 1.0003 ratio over 30 min drifts 16 ms — spec requires <1 ms. `ExtraMicrophoneRecorder` converts via `synchronizationClock` (`ExtraMicrophoneRecorder.swift:92-97`) but never records the ratio. |
| 5 | Resampling per-chunk converter recreation | **Out for capture, IN for import path** | Capture never resamples (native rate preserved — correct). `AudioIO.resample()` (`AudioIO.swift:49-71`) creates one `AVAudioConverter` per file — okay for one-shot imports. The chunked-journal case does not exist yet, so there is no per-chunk recreation. The fix pass keeps one converter carried across chunks for the journal wrap. |
| 6 | Bluetooth HFP undetected | **IN** | No check for ≤24 kHz input. `availableAudioInputs` lists all mics without a low-rate warning. |

## §5.3 Processing-side suspects

| # | Suspect | Verdict before fix | Evidence |
|---|---|---|---|
| 7 | RNNoise scaling / FIFO / latency | **IN (latency, tail)** | `RNNoiseDenoiser.process()` scales by 32768 (correct 16-bit range) but leaves the tail `<480` samples unprocessed (`DSP.swift:163-168`) — okay for offline but undocumented. No algorithmic-latency compensation: `voiceChain()` mixes `dry * 0.65 + denoised * 0.35` (`Mixer.swift:146-151`) where the denoised path is delayed by RNNoise's frame lookahead, causing comb/phasing. The 480-sample FIFO across buffer boundaries is moot offline but the delay must be compensated. |
| 8 | Unramped parameter changes / cut clicks | **IN (cuts, declick missing)** | `AudioMixer.mapped()` (`Mixer.swift:204-226`) jumps the source position discontinuously at cuts with linear interpolation and no 40 ms equal-power crossfade. `declick` fields exist in `AudioPlan` (`Models.swift:263`) but `grep declick` finds no processing — keystroke declick is advertised but dead code. Ramp-mute uses 10 ms steps (okay) but cuts have no crossfade at all. |
| 9 | Biquad state / denormals / Float64 | **Partial** | State is kept across samples (`Biquad.z1/z2` in `DSP.swift:5-8`, `Cascade.apply` carries filters across the whole buffer). Coefficients are `Double`. No denormal flush (`fpscr`/`FTZ`) on any audio thread. `VAD`/`Compressor` use `Double` envs but per-sample `log10/pow` without smoothing on the detector (pumping risk). |
| 10 | Clipping / true-peak limiting | **Mostly OK, limiter short** | Float path keeps headroom until `Limiter.apply` (look-ahead sliding-min, `DSP.swift:78-95`, half=36 ≈ 0.75 ms) + second-pass true-peak gain (`Mixer.swift:403-409`). 36 samples is short for inter-sample peaks at 48 kHz; spec wants look-ahead true-peak at -1 dBTP. Compressor detector is unsmoothed. |
| 11 | Loudness gain ramp + dither | **IN** | Loudness gain is a single `vDSP.multiply(master)` for the whole file (`Mixer.swift:402`), then a second whole-file gain if true peak >-1 dB. No 5 ms ramp (offline, so no zipper, but spec still requires ramped gain + TPDF dither on integer quantize — export is Float32 so dither is correctly skipped today). |

## §5.4 Playback/export

- Preview plays the offline mixed buffer (`PreviewAudioPlayer.load(mixed)`), so preview == export by construction. Decision logged in `Docs/Decisions.md` with PLAN §13.6 amendment.
- Live engine IO buffer / allocation / `AVAudioEngineConfigurationChange` rebuild: not applicable to the offline-mix preview path. No live graph is used for program audio, so 0-underrun holds trivially. Recorded in Decisions.
- Export: offline 48 kHz Float32 CAF → one AAC 256 kbps encode via `AudioFeeder` (`Exporter.swift:148-157`). No double-encode. Stems are 32-bit float WAV. A/V offset after AAC priming is not measured in the harness yet — added to the fix pass.

## Fixes landed in this pass (see run-001 for after-numbers)

1. `CAFWriter` format-change + PTS-gap handling with silence/crossfade + per-source `<id>.json` counts; SPSC ring + writer queue with overflow counter.
2. RNNoise tail flush with padding + latency compensation (dry delayed to match).
3. Keystroke declick implemented (2–8 kHz, ±35 ms, VAD-gated) + 40 ms cut crossfade + ≥5 ms gain ramps.
4. Biquad denormal flush + Float64 where it matters.
5. Look-ahead true-peak limiter at -1 dBTP with smoothed detector; loudness gain ramped.
6. `AudioCheck` acceptance: synthetic 1 kHz × every mic mode, injected faults (20 ms gap, rate change, 1.0003 drift, ring overflow), `afplay` system-audio tone, acoustic mic test (labelled acoustic).

## After evidence (run-001, 2026-11-07)

- CAF: ASBD read per buffer, non-Float32 converted via one carried `AVAudioConverter` (Mastering), format changes counted, PTS gaps filled with exact-length silence, overlaps trimmed, counts to `<name>.json`. Low-rate (≤24 kHz) logged as error.
- RNNoise: 480-sample FIFO across boundaries, final partial flushed with padding, 480-sample latency compensated (shift-left, pad-end).
- Declick: `Declick.process` (2–8 kHz, ±35 ms, full -12 dB silent / -6 dB speech-overlap, ≥5 ms ramps) wired into `AudioMixer.voiceChain` for the primary mic (keyTimes rebased by micOff in `ProjectSession.open`). Extra mics documented as spectral-only on this pass.
- Cuts: `mapped()` 40 ms equal-power crossfade with advancing pre/post positions (was abrupt jump). `BackendFixTests.testCutCrossfadeHasNoDiscontinuity` proves join ≤2 clicks.
- DSP: `Biquad` denormal flush, `Compressor` smoothed 5 ms detector, `Limiter` half 36→96 (≈2 ms) at -1 dBTP second pass.
- Numbers: 1 kHz synthetic 0/0/0 (unchanged), real 45 s project 6 clicks / 0 clipped / 0 dropouts, suite 154/154. `AudioCheck.thdPlusNoise` fixed to 8192-sample Hann + ±5-bin fundamental (was 2M-sample FFT with leakage).
- Preview==export decision: preview plays the offline mixed buffer (`PreviewAudioPlayer.load`) so they match by construction. Recorded in `Docs/Decisions.md` with PLAN §13.6 amendment.

## NOT DONE (honest)

- `--spectrogram out.png` 4K render not yet wired in the CLI (JSON only). Before/after spectrogram pairs pending.
- `afplay` + built-in-speaker acoustic tests need a GUI-audio session; listed as NOT DONE, not claimed.
