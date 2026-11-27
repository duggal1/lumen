# Part 3 — Recorded interaction audio and automatic studio voice

Baseline: 5673f1d3fcdb99a53d500b7fd01494a4cf3c6f03, Parts 1 and 2 merged. Scope: native Swift audio backend only; preserve editor UI, persisted controls and existing project compatibility. No synthesized replacement sounds, no fake license/provenance, no deletion of the music library. Do not call Part 3 complete until the asset replacement and listening gates are actually passed.

## Evidence and priorities
- KeySoundEngine applies keyLevelDb twice; inspector preview adds clickGainDb independently of the offline mix; non-studio clicks cycle away from the selected tone and invent a second click at +18 ms even without a recorded release.
- TypingSampler has a separate click selection path and does not audition curated studio samples the same way as export. Legacy Mechvibes pack loader and old cursor assets remain present.
- BusLimiter excludes the current sample from its maximum window, allocates program-length peak storage, removes array fronts, and can release past the current required gain. Raw window preview also lacks prior limiter state.
- Current CC0 manifest labels 86 takes, some with identical hashes, and acquisition code substitutes down strikes for missing releases. Per-take -16 LUFS compression is not evidence of good transient quality. Existing unit tests and bundle assertions encode the old asset inventory; migrate them only with real replacement files and stronger provenance gates.
- VoiceStudio still uses old Standard/Optimized curves; prior project data and tests depend on them. Introduce input-adaptive automatic treatment without losing saved settings. Keep legacy decoding and explicit off behavior, and do not pretend a legacy mode is a new neural model.

## Implementation sequence
1. Establish one cue-to-recording selection API used by offline rendering, inspector and sampler. One real recorded click per recorded click cue; never synthesize a release. Preserve exact tone selection, finite gain bounds, deterministic per-key round robin, 48 kHz sample placement, cut handling. Remove duplicate gain staging; calibrate at the bus rather than each cue.
2. Repair limiter: stereo-linked, includes current sample, bounded sliding max, gain never exceeds required safe gain, finite samples, no hard/soft clipping as routine dynamics. Validate against a reference and overlapping bursts, and ensure ordinary non-limiting previews match exported SFX.
3. Source new real keyboard and mouse recordings; confirm author/license on original pages (CC0 preferred). Candidate sources: https://freesound.org/people/pbimal/sounds/534103/ (CC0 single mouse click), https://freesound.org/people/FOSSarts/sounds/740434/ (CC0 raw wired mouse), https://freesound.org/people/HunteR4708/sounds/256455/ (CC0 Logitech mouse), https://freesound.org/people/grcekh/sounds/546166/ (CC0 WhiteFox). Audition actual bytes, verify original source and processed SHA-256; capture discrete down/up metadata and trim attack with minimal fades; do not derive release from down. Prefer peak headroom and relative level matching over per-transient LUFS compression. Keep coherent keyboard family, stable low-gain variation. Download host cannot be resolved in current runtime; this remains blocked, not silently completed by repackaging current sounds.
4. Canonical manifest and package migration: replace old effect files only once new assets validated and recorded; preserve persisted IDs through explicit aliases, no fallback to old MP3s or invented noise. Validate paths, hash, uniqueness, license and actual WAV format. Keep music separate. Update CI resource contracts and remove obsolete bundles and runtime pack routes only when replacements cover all existing UI selections.
5. Automatic local voice: inspect VAD speech/noise separation, clean/quiet/noisy/short input, adaptive expansion, EQ, de-ess, compression, dereverb and final loudness. Preserve voice identity; don't boost silence, don't suppress consonants. Maintain legacy decoding and mute, use canonical processed voice cache and invalidate it when DSP changes. Do not turn off safety limits or silently replace failed neural output with corrupted PCM. Retain honest diagnostics.
6. Regression suite: exact selected click, single physical cue, gain slope, sample placement, missing sample silence, nonfinite hostile input, limiter ceiling/linkage/lookahead/release, consistent window selection, deterministic cache revision, voice continuity and duration. Full debug/Metal/unit+integration/release/signature CI. Real listening: keyboard bursts, mouse, quiet laptop mic, AirPods, fan, mixed music/system/mic; score naturalness, intelligibility, sync and absence of pumping. Measure M1 8 GB peak RSS, CPU and export. Part 4 remains untouched until this PR's code is green; full Part 3 signoff requires assets and listening evidence.

## Acceptance gates
- [ ] All current interaction routes use canonical recorded library, no fake release.
- [ ] No missing source data or synthetic production samples; authentic new assets actually committed and reviewed.
- [ ] Existing project IDs and audio controls remain usable.
- [ ] Click gain measured once; exact click selection across preview and offline.
- [ ] No clipped/nonfinite output, no unintended cue, p95 onset error <=20 ms on real recordings, stereo-linked dynamics.
- [ ] Adaptive voice clean/noisy corpus, original duration, no unacceptable speech loss, final -1 dBTP ceiling.
- [ ] All tests pass, package signature and assets verified, merged commit read back on main.
- [ ] Real listening and M1 resource measurements documented. CI alone is not sonic acceptance.

## Implemented in this PR

Canonical exact click selection, no invented click release, real release flag handling, silence for legacy releases lacking separate-recording provenance, single gain stage, stereo-linked bounded limiter, bounded preview warm-up, removal of offline UI notification side effects, denoiser sample-count/finite guard and input-adaptive expansion. Existing recordings remain; acquisition and listening blocked by network. Legacy UI/pack compatibility intentionally preserved until verified assets replace them.
