# Plan: Instant Play (catastrophic transport gate)

## Goal
In Studio, the first Play click starts video-motion within <150 ms on a fresh open, every time. Audio joins from the same offline mixed buffer as soon as it is ready without restarting video. Preview==export is preserved (both play `AudioMixer.mix(tl)`).

## Non-goals
- No new DSP, no new deps, no UI redesign, no export speed work (export is a separate benchmark-first task).

## Invariants (must always be true)
- `clock.playing` is true synchronously inside `play()` before any `mixer.mix` returns.
- Video never waits on CPU work: no `await mixTask` on the transport path.
- The audible buffer is always `mixer.mix(timeline)`; a silent head before join is the only divergence, never a different mix.
- Pausing cancels a pending late-join (no stray audio after Pause).
- Rapid Play/Pause/Seek never leaves clock and audio at different positions (late join seeks to the *current* clock time).

## Failure modes
- Empty/silent project: `mix()` returns nil → video still plays silent, no hang.
- Mix takes 0.1 s (cached WPE) vs 5 s (cold): both must show motion <150 ms.
- Edit during playback: old buffer keeps playing until new mix arrives, then re-seeks to current clock time; no freeze.
- Seek during silent head: join uses the seeked position, not the original playhead.
- Second click during mix: idempotent, no double clock start, no cancelled-becomes-dead transport.

## Approach
`play()` starts `PlaybackClock` immediately from the current playhead. If `PreviewAudioPlayer` already has a buffer, audio starts locked to video. Otherwise a background `remix()` runs the offline studio mix off-main and `player.play(from: clock.time(now))` joins audio under the running video. `remix()` no longer pauses transport.

## Steps (each has a Verify command)
1. Oracle: `Tests/LumenTests/PlayInstantTests.swift` — real open, call `play()`, poll `clock.playing` ≤150 ms. Verify: `swift test --filter PlayInstant` shows RED before the fix.
2. Add `PreviewAudioPlayer.isLoaded` + `warm()` (engine pre-start). Verify: `swift build`.
3. Rewrite `play()` / `remix()` / `seek()` / `pause()` in `Sources/LumenUI/EditorModel.swift` to the instant-transport contract. Verify: `swift build`.
4. Oracle green + full suite. Verify: `swift test` (147+ green) and `swift test --filter PlayInstant` 5× (`for i in 1..5`).
5. Manual 5× proof on the user's real 45 s project: fresh open, time Play-click → motion, Play-click → sound; log to `Docs/Verification/play-times.log`. Verify: all 5 <150 ms motion, sound within 500 ms of join, single click suffices.
6. Export baseline (Release): `LUMEN_BENCHMARK=1` export of the same project, capture decode/GPU/encode splits. Verify: numbers in `Docs/Verification/export-baseline.log` decide the export plan, no guessing.

## Files
- `Plans/play-instant.md` (this file)
- `Tests/LumenTests/PlayInstantTests.swift`
- `Sources/LumenUI/EditorModel.swift`
- `Sources/LumenAudio/Mixer.swift` (`isLoaded`/`warm`; mix DSP untouched)
- `Docs/Verification/play-times.log`, `Docs/Verification/export-baseline.log`

## Completion (one logged deviation)
- Deviation: added background warm (`needsInitialMix` in `replan`) so the
  preview buffer is mixed after derive publishes, before a typical Play.
  Reason: Release silent head for an impatient click is 713–746 ms
  (mix-dominated), above the 500 ms T2 target. With the warm, a typical
  Play (user locates the button) already has `isLoaded == true` and sound
  starts with motion. The impatient-click path (instant video, audio joins
  at current position) is unchanged. No DSP, no preview/export divergence.
- Evidence: motion 0.01–3 ms over 5× fresh opens in both Debug and Release
  (`play-times.log`); oracle `PlayInstant` green 5× in Debug and Release;
  full suite 148 green. Shipped `.build/Lumen.app` is Release (10 MB).
- Export: baseline in `export-baseline.log` — 12.48 s for 2229 frames,
  GPU/encoder wait 9.69 s (78%). Single-stream VideoToolbox bound; no
  export code changed this pass.
