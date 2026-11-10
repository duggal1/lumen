# Plan: trained microphone cleanup and shared voice cache

## Goal
Use pretrained RNNoise with aligned tail flushing and probability-driven gap ducking. Share settings-keyed 48 kHz processed voice between the offline mixer and 16 kHz caption handoff.

## Non-goals
Capture graph, system audio, UI, captions, camera and privacy changes. No training, Python, new tests or full verification suite.

## Invariants
Preserve source duration and timing, finite samples, immutable raw media, independent microphone processing, settings-sensitive cache keys, atomic cache publication, and the -1 dBTP ceiling.

## Failure modes
Missing source throws for captions. Corrupt or stale caches recompute. Unavailable high-quality engine keeps RNNoise as the default. Native voice processing is skipped if the existing capture architecture cannot safely use it.

## Approach
Read all audio source and its capture/export consumers. Remove dry-signal reinjection and the fallback gate. Correct RNNoise latency and use its VAD. Evaluate native DeepFilterNet3 on Apple Silicon and retain spectral dereverb only with supporting evidence. Replace the studio chain with the requested restrained podcast processing.

## Steps
1. Inspect capture API compatibility and pretrained engines; verify with one native probe.
2. Implement denoise, podcast chain and settings-keyed cache; verify with make build.
3. Expose cleanVoiceURL(for:), document Agent 3 integration; verify with one focused audio repro.
4. Review diff, commit changes separately and push agent-2-audio.

## Files
Sources/LumenAudio/**; Sources/CRNNoise/**; audio-only fields in Sources/LumenProject/Models.swift if required; Package.swift only for audio resources; plans/agent-2-audio.md; Docs/agent-2-audio.md.
