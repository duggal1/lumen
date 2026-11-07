# Play-not-starting plan

Defect: in Studio, first Play click appears to do nothing (no motion/no sound for seconds).
Suspected root: `EditorModel.play()` awaits the offline `mixTask` before starting the clock/player (`EditorModel.swift:250-268`), so preview is frozen until WPE+studio mix completes.

## Test (repeatable)
1. Fresh open of a 30–60 s recording at 0:00, clean Derived cache.
2. Click Play, timestamp T0. Measure: T1 first `clock.start` / frame advance, T2 first audible buffer.
3. Repeat N=5 opens. Pass = T1 < 150 ms every run, T2 within 500 ms of T1, no second click needed.
4. Log `wantsPlayback/hasMixed/mix duration` on each run (os_log).

## Fix
- Start the clock + player immediately from the current playhead.
- If no mixed buffer yet: run `remix()` in background (`.utility`), and when ready seek audio to the live playhead and start at `now+latency+0.03` without restarting video.
- Keep preview==export: both still play the same offline buffer once loaded; the silent head is bounded and invisible.

## Evidence
- 5× timed runs in `Docs/Verification/play-times.log` + screenshot (playhead moves).
- `swift test` green.
