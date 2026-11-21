# Current handoff baseline — 2026-11-21

**Not signed off.** On the current checkout, `make build` passed and six focused zoom-out and idle tests passed. The full `make test` completed with 739 tests and 22 issues in 1,163.7 seconds; the log is `.proof/handoff-full.log`. This run included pre-existing uncommitted changes to render and UI files, which are not part of the pushed WIP commit.

The one-minute offscreen click test reported p99 36.69 ms, worst 192.59 ms and 277 frames over the deadline. Camera failures include teleport, retired controls affecting the bake, long chained zooms, arrival timing, jerk and acceleration continuity. The suite also reports failures in 3D reveal, voice controls, browser crop, typing focus, caption edits and zoom timing. The 60/120/240 fps export frame-count test passed. Six Studio Audio fixtures measured -12.12 to -12.16 LUFS and -1.05 dBTP; one comparison measured +1.84 dB against the -14 LUFS program, and one noise-floor check measured -33.9 to -62.7 dB. These results do not establish real display performance, full scaler quality, natural voice quality or all six problem acceptances.

The existing WIP and the earlier handoff notes were pushed to `origin/wip/backend-fixes-handoff`. Its pre-push hook was bypassed for preservation only because the work is known to be unverified; the separately run full suite is red. No product code was changed during this baseline investigation. The following older sign-off records the earlier baseline and is retained for history.

---

# Backend reliability sign-off

**Blocked at the baseline.** The existing test suite records zoom-out failures. The QA package and production fixes are incomplete. The detailed source audit is also incomplete. Evidence below is from the unchanged implementation on `fix/backend-reliability` at `1a5ffe78`.

| Criterion | Status | Evidence |
| --- | --- | --- |
| Baseline build | Pass | `make build` exited 0 with a 1.48 s incremental build. Apple M1 Metal is functional. |
| Baseline offscreen Metal bench | Pass | 120 frames, 1080p at 60 fps nominal. p99 4.45 ms, max 11.27 ms, 0/120 over the existing gate. |
| QA click scenario and strict gate | Fail | Existing `bench` has no click workload, presentation samples or strict gate. |
| QA camera, auto-zoom, audio and scaling fixtures | Fail | Existing targeted tests cover parts of the request. The new fixture set and comparison tooling are incomplete. |
| P1 pivot math, monotonicity and endpoint continuity over 1,000+ points | Fail | No pivot implementation or requested sampling result. |
| P1 idle stillness and bit-identical repeats | Fail | No measurement across repeated evaluated tracks. |
| P1 rendered pivot residual ≤0.5 px | Fail | No golden sequence comparison. |
| P2 60 s click gate, p99 <16.6 ms, max ≤33 ms, zero drops | Fail | Existing synthetic timings do not cover click, decode, display or transport. |
| P2 traced root cause | Fail | Awaited decode-ahead, drawable acquisition and audio readiness remain hypotheses. |
| P2 real 60/120 Hz presentation | Needs-hardware | Requires an interactive display run with recorded clicks and seeks. |
| P3 2×, 3×, 4× comparison and frame-time cost | Fail | No matched supersampled reference, improvement or performance delta measured. |
| P4 and P5 eight automated scenarios and two regression checks | Fail | Existing default empty-event planning and early-click release passed. Late release reproduced at final scales of 1.800× and 2.000×. No additional regression tests were added. |
| P6 six audio cases, noise floor, presence, loudness, true peak, no clip, determinism | Fail | Raw speech measured -14.94 LUFS and -1.16 dBTP with zero clips. The existing noisy-speech run measured a 31.34 dB fall in estimated quiet-window RMS at the denoiser. Fixed chain and mastered fixture comparisons remain incomplete. |
| P6 listening and real microphone capture | Needs-hardware | No before/after listening pair exists yet. |
| Integrated suite, verify and golden comparisons | Fail | Baseline make test recorded zoom-out failures and exited 124 at the 120 s limit. make verify and combined golden comparison remain pending. |
| Actual exported frame count and rate after fixes | Fail | No combined export was produced. Baseline count assertions passed for 102, 204 and 408 decoded frames at the requested 60/120/240 FPS settings. |
| Legacy and manual edit parity, Classic/Loupe, re-aim, blur, cursor, layouts and captions | Fail | No combined regression run. No implementation changes were applied. |
| Source media immutability and shared render/audio entry points | Pass | Code inspection confirmed the existing separation and shared paths. This session made no source media or product code edits. |
| Dependencies, modes, abstraction and deletion checklist | Pass | No dependency, mode, setting, abstraction or production code was added. |

## Reproduce the test gate

```sh
make build
swift test --no-parallel --filter 'Agent1FiveHundredSeedTests|Agent1HoverAndLongTests|clickNearEndOfRecordingStillGetsCompleteZoomOut|consecutiveBridgedScenesReturnToFullFrameAtEnd|zeroSlackTailStillArrivesInBoundedTime'
.build/debug/lumen-cli bench --frames 120
```

The focused gate must exit 0. Zoom must return to 1.0× and the neutral center at the end. The full package gate also requires a green `make test`.

## Owner hardware and later verification

Build the app and open a disposable copy of a recording with at least 60 s of content. Repeat the same click/seek cadence during each capture. At 60 Hz and on a 120 Hz display, record the presentation cadence and misses. At 60 Hz, use the specified p99 and worst-frame limits with zero missed presentations. At 120 Hz, also report the measured 8.33 ms cadence against display refresh.

```sh
make app
system_profiler SPDisplaysDataType
open .build/Lumen.app
xcrun xctrace record --template 'Time Profiler' --attach Lumen --time-limit 70s --output .proof/lumen-click-cpu.trace
xcrun xctrace record --template 'Metal System Trace' --attach Lumen --time-limit 70s --output .proof/lumen-click-metal.trace
```

Capture a disposable project through the app with Screen Recording, Input Monitoring, Accessibility and Microphone enabled. Verify video, clicks/keys and microphone audio independently. Use the same recording and timeline for before/after exports and listening.

```sh
.build/debug/lumen-cli sync-check /absolute/path/to/disposable.lumen
.build/debug/lumen-cli render /absolute/path/to/disposable.lumen --preset 1080p60-h264 --out .proof/candidate-60.mp4
ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=avg_frame_rate,r_frame_rate,nb_read_frames,duration .proof/candidate-60.mp4
.build/debug/lumen-cli audio-check .proof/candidate-60.mp4 --report .proof/candidate-audio.json
ffmpeg -i .proof/baseline-60.mp4 -vn -c:a pcm_f32le .proof/baseline-listen.wav
ffmpeg -i .proof/candidate-60.mp4 -vn -c:a pcm_f32le .proof/candidate-listen.wav
afplay .proof/baseline-listen.wav
afplay .proof/candidate-listen.wav
```

The export should report 60/1 and a decoded count of `ceil(outputDuration × 60)`, allowing for floating-point error at an exact boundary. Compare the same media and app playback volume for A/B notes. Recheck at matched loudness for suppression artifacts and voice identity. The baseline file must be generated from the pre-fix build before comparing.

## Test handoff

Use the commands above to pin the red tests and capture a baseline. Reuse `RecordingPipelineTests`, `ZoomOutCompletionTests`, `VideoFrameAccuracyTests`, `SyncHarness` and `GoldenHarness`. Treat a generated golden as reference evidence only if created independently of the candidate scaler. Keep synthetic frame compute measurements separate from real presentation drops. Measure output of the shared AudioMixer path for six speech variants. Log LUFS, true peak, per-noise SNR or quiet-window RMS and band energy. The current -14 LUFS default can be louder than the requested -16 LUFS program. Report that conflict per fixture.
