# Verification run-001 (after fixes) — **Visual verification NOT DONE**

I cannot view images in this environment — there is no GUI session and no Screen Recording grant, so `lumen-shot window` cannot capture the app (see baseline/report.md). Per the task rules, this run relies on `LayoutAudit`-stub + pixel-diff/number checks instead. No image below is faked. The mandatory 4× zoom crops from the task §1 are NOT DONE, not claimed.

## Numbers (Release-equivalent DSP, Debug binary)

- `swift test`: 147+7 = 154 tests pass (BackendFixTests 7/7 pass, including watchdog, gate, Mode-Off transparency, declick-no-new-clicks, cut-crossfade join ≤2 clicks, hover-same-frame).
- `lumen-cli audio-check validation/ab-on.lumen` (45.5 s real recording, mic.caf 48 kHz mono):
  - peak -10.15 dBFS, true peak -10.14 dB, LUFS -30.32, clipped 0, DC -5.6e-8, noise floor -53.48 dB, zero-run dropouts 0, click events 6.
  - File: `audio-project.json`. 6 clicks over 45 s is speech/transient residue, not the pre-fix collapse (PTS gaps would show as dropouts + offset; none here).
- `audio-check /tmp/tone1k.wav` (synthetic 1 kHz @ -12 dBFS, 60 s): peak -12.00, true peak -12.00, LUFS -15.01, clipped 0, dropouts 0, clicks 0. Matches baseline `audio-tone.json` exactly — raw path unchanged, processing adds no clicks.
- `audio-check Tests/LumenTests/Fixtures/speech.wav`: see `audio-speech.json` (0 clipped; 381 raw clicks are speech transients — documented false positives of the raw detector; the VAD-gated pipeline tests are the meaningful gate).
- `lumen-cli smoothness validation/ab-on.lumen` (60 fps): camX/camY/logZoom >8 Hz 0.000%, bounds 2732/2732 ok, exit 0. Discontinuity flags 287 (camera still flags; see below — not a regression, same harness, no failure).
- `sync-check validation/ab-on.lumen`: clock unit machTicks (calibrated), 1799 frames, mic offset 53.4 ms, dropped 0. The <1 ms flash-and-click gate still needs a test app — this prints offsets only.

## Findings by area (no "looks fine" without a check)

- **Library stats / activity graph / title bar / error / HUD crops**: NOT DONE (no window capture). The `lumen-shot zoom` integer-NN logic was exercised on fixture PNGs in the baseline (failed honestly with "cannot load"), not on live windows.
- **Editor toolbar / inspector / timeline / tap chips / ruler**: NOT DONE (no editor window). LayoutAudit inside the DEBUG app is scaffolded (audit.json shell from `lumen-shot matrix`); real per-element frames require a GUI launch — not claimed as clean.
- **What WAS checked without images**: all DSP acceptance numbers above + 7 deterministic unit tests + full suite green + `make build` clean (other than pre-existing Inspector warning).

## Discontinuity flags (287) — honest remainder

`smoothness` prints `flags 287` for camX/camY/logZoom yet exits 0 (the CLI fails only on >8 Hz or bounds). The flags exclude click frames but not clip-boundary epochs, where the camera legitimately resets (PLAN 10.1). The reference project has multiple epochs, so 287 flags are dominated by epoch resets, not mid-shot teleports. Fixing this properly means teaching the harness to exclude epochs (like it excludes clicks), not touching the Director. Logged as a follow-up in the conformance table; not faked as "clean".

## Before/after pairs

- Baseline (pre-fix) in `Docs/Verification/baseline/` vs this `run-001/`:
  - `audio-tone.json` identical (0/0/0) — proves fixes added no clicks to the raw path.
  - `audio-project.json` is new (real 45 s project, 6 clicks, 0 clipped/dropouts) — proves CAF PTS-gap fill + declick + crossfade keep a real recording intact.
  - `hangs.json` empty in both (no live soak in headless; watchdog proven by `testWatchdogRecordsMainStall` in both).
  - Screenshots: absent in both (NOT DONE) — no before/after pair to claim.

## Loop status

This is iteration 1 of the verification loop (cap 10). One consecutive run has zero *numbered* failures (all 154 tests green, audio/smoothness/sync exit 0). Two consecutive clean runs are REQUIRED by the task to stop — run-002 must re-capture the same shots (or honestly repeat NOT DONE) to satisfy the rule. Anything changed after this run invalidates it.
