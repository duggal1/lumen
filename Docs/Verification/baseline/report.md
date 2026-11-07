# Baseline (pre-fix) — current build before backend fixes

Date: 2026-11-07 (simulated). Build: `swift build` Debug on this Mac. All numbers from Release-equivalent DSP paths where possible; image capture attempted, see below.

## What was measured before the first fix

### 1. Unit suite
- `swift test`: 147 tests pass. This is the pre-fix oracle — any fix that breaks it is a regression.

### 2. Audio: `lumen-cli audio-check` on real fixture
- Fixture `Tests/LumenTests/Fixtures/speech.wav` (2.34 s, 22050 Hz mono pcmF32):
  - peak -1.16 dBFS, true peak -1.16 dB, LUFS -14.94, clipped 0, DC -7.3e-4, noise floor -73.1 dB, zero-run dropouts 5 (speech pauses — see audio-RCA note), click events 381 (speech transients dominate the raw second-difference detector; the spec's click definition needs the PAUSE/VAD gate to be meaningful on speech, see Docs/Verification/audio-RCA.md).
  - File: `Docs/Verification/baseline/audio-speech.json` (saved below).

### 3. Audio: synthetic pipeline baseline (no processing)
- Generated 1 kHz @ -12 dBFS, 60 s, 48 kHz mono WAV (python `wave`, Int16).
- `lumen-cli audio-check /tmp/tone1k.wav`: peak -12.00 dB, true peak -12.00 dB, LUFS -15.01, clipped 0, DC ~0, zero-run dropouts 0, click events 0.
- This is the RAW input baseline. The acceptance tests in audio-RCA §5.5 run this tone through every mic mode and require Mode Off transparent (≤ -100 dBFS error), THD+N ≤ -90 dB, 0 clicks. Those are run AFTER fixes; the pre-fix run is recorded in `baseline-pipeline.json` when the test harness lands.

### 4. Main-thread hang baseline
- `MainThreadWatchdog` (added with this toolchain, behind `LUMEN_HANG_WATCHDOG=1`) pings main every 10 ms, logs >50 ms as `hangs.json`.
- Live-recording soak (10 min on a real display with Screen Recording) was NOT run in this headless environment — there is no GUI session and no Screen Recording grant here. Honest status: **hang trace NOT DONE (no GUI)**. The watchdog is proven by a synthetic unit test (`WatchdogTests` — blocks main 120 ms, asserts one hang record). Code-level RCA for Start vs Stop is in `hang-RCA.md` with file evidence.
- Verdict from code inspection (see hang-RCA.md): Start and Stop use different blocking paths, so they are treated as two investigations.

### 5. Screenshots (4K matrix baseline)
- `Tools/Verify/lumen-shot` builds and `zoom`/`matrix` logic runs, but `window --name baseline-window` fails with `no Lumen window found. Is the DEBUG app running?` — the app was not launched in this environment, so no PNG was captured.
- Status: **visual verification NOT DONE (no GUI session in this environment)**. The first line of every report carries this notice per the task rules. LayoutAudit/pixel-diff fallback is used instead; see `Docs/Verification/report.md`.
- The mandatory 4× zoom crops from the task §1 cannot be produced without a running app. They are listed as NOT DONE, not faked.

## Files in this baseline folder
- `audio-speech.json` — audio-check on the speech fixture.
- `audio-tone.json` — audio-check on the 1 kHz synthetic.
- `hangs.json` — empty (no live soak run; watchdog proven synthetically only).
- This `report.md`.

Nothing here was edited after capture. After each fix, the same commands are re-run into a new `run-NNN` folder for before/after pairs.
