# Plan: Studio audio — Standard / Optimized podcast grade

## Goal
`VoiceStudio.finish` differentiates by `AudioPlan.studioMode` with measured gaps: Standard speech-floor gap ≥40dB, Optimized ≥50dB, loudness -14 LUFS (user-adjustable) ≤-1dBTP, clean clip not worse, soft expander (no chopped tails). Classic DSP first; no new NN in default path. Order: denoise/dereverb → expander/level → EQ/de-ess → compressor → normalize → limiter (existing `Mixer` order, keep).

## Non-goals
- No new DSP libraries, no network, no ML toggle (only if classic fails targets — report from oracle).
- No `Commands`/`Composition` magnetic-lane changes (cloud WIP in tree, do not touch).
- No LUFS default change -16→-14 without frozen-test migration (report conflict).

## Invariants
- Mode off / `studioMode` default Standard: mixer still seamless (preview==export).
- Expander soft: word tails never chopped (length preserved, no new `zeroRunDropouts`).
- Limiter ≤-1.0dBTP, integrated LUFS at `targetLUFS` ±0.5 when `normalize` on.
- Clean control (steady tone) SNR not worse than input (no pumping/sibilance regression).

## Failure modes
- Empty voice / all-silence → gap undefined, LUFS stays -70, no crash.
- Optimizer over-processing (parallel/2nd expander) → blend guard 10-20% Standard.
- HF already present → no bandwidth extension added (measure HF energy first).

## Approach
Differentiate inside `VoiceStudio.finish`: (S) current tone/level/comp. (O) stronger return: dereverb preset via plan (caller), deeper soft expander pre-EQ, low-shelf 150Hz + mud 350Hz, HF presence check → soft-saturate 3-6kHz only if HF sparse, split-band de-ess (HP split), multiband (low/high split comp) + 20-30% post-expander parallel, light post-comp expander, 15% blend to S when `optimized` delta >12dB (anti-over-processed). Keep gains frozen on silence (leveler already does). Add `AudioCheck` gap oracle.

## Steps
1. Oracle `Tests/LumenTests/StudioGradeTests.swift`: synthetic echo+fan (reverb tail + 120Hz hum + speech bursts), typing (key bursts), clean tone. Assert S gap ≥40, O gap ≥50, TP ≤-1, length preserved, clean not worse. Verify RED before (O gap <50, O==S).
2. Tokens/shape: no UI change for oracle. Verify `swift test --filter StudioGrade` RED.
3. Implement `VoiceStudio.finish` mode split + order kept. Verify GREEN + full `AudioStudio/StudioVoice/TypingAudio` green.
4. A/B harness doc + LUFS/default conflict report. Step 6 front-end minimal (music/mode/loudness/zoom-range/blur/click/upscale controls already exist — verify, add Advanced rows only if missing).

## Files
- `Plans/studio-audio.md` (this file)
- `Tests/LumenTests/StudioGradeTests.swift`
- `Sources/LumenAudio/Studio.swift`
- `Sources/LumenProject/Models.swift` (only if LUFS default settled)
- `Docs/Verification/audio-studiograde.log`
