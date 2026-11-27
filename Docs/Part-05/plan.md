# Part 5 — Performance and final release verification

Baseline b613104a11eb1a41471e62a4c1c0d01e1ca68663. Preserve all approved UI, Swift/Metal/AVFoundation, existing project and MCP contracts. Seven small reviewable phases; split further if needed. Do not lower performance or correctness assertions. Current merged Part 4 CI failed two existing webcam hide/fade assertions; restore before claiming a green baseline.

1. 5A: instrument actual delivered frames, timestamps, GPU/CPU/writer waits, monotonic stage and end-to-end time, correct process peak RSS units and target-device physical footprint. Separate synthetic, real and hardware-specific reports.
2. 5B: independent preview/export reader state, bounded byte-budget frame caches, cancellation and ordered prefetch, retain VFR/held-frame semantics.
3. 5C: resource lifetime, GPU failure propagation, bounded Metal target reuse and equivalent render passes. No visual quality reductions.
4. 5D: bounded ordered export with event-driven backpressure where proven, cancellation/join, atomic output; hardware encoder evidence.
5. 5E: bounded PCM windows and disk-backed caches preserving stateful DSP, loudness and preview/export parity.
6. 5F: revision-safe editor invalidation and latest-request scheduling; no redundant analysis.
7. 5G: complete real footage, audio, fault-injection, privacy, compatibility, target-device stress and release gates.

M1 8 GB targets (not measurements): 1080p60 p99 <=16.67 ms, 40s 1080p60 <=5s and 4K60 >=3x realtime as stretch goals. No missing frames, silently changed presets or fake quality evidence. Measure cold/warm, actual encoding and finalization, verification overhead, physical footprint, thermal state. Idle <=200 MiB, 1080p active <=1 GiB, 4K <=2 GiB are proposed budgets subject to profiling. Keep existing stricter test assertions. Close outstanding Parts 1–4 validation; unsupported device capture remains explicit.

### Final combined CI evidence

[Run 46047181739](https://github.com/duggal1/lumen/actions/runs/46047181739) passed its reported 911-test suite; targetHardwareRealProjectProof was skipped by design. 1080p60 render p99 2.59 ms; 4K60 median trial p99 7.68 ms; export medians 2.21x and 1.14x realtime. These are CI synthetic fixture results, not M1 or full real-project benchmarks. All implementation PRs #49–54 merged. Ordered prefetch, event-driven video writer readiness, full streaming audio and target-device release gates remain open; see final audit.
