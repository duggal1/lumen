# Combined backend audit — Parts 1–5

Audited main `07b4c745b0488d2460ad4a77b5f153a622b53b0e`. PRs #42–54 all merged; zero open PRs at audit. [Combined CI 46047181739](https://github.com/duggal1/lumen/actions/runs/46047181739) at `a1a600573945998f80170c9ab27956519e651a66` passed debug, Metal, unit/integration, release packaging, resource and code-signature checks. Reported 911-test suite passed, opt-in real-project proof skipped. The difference from that head to audited main consists of eight README/asset/generator changes, no backend changes. [Main CI 46053710708](https://github.com/duggal1/lumen/actions/runs/46053710708) was in progress at audit.

| Part | Implemented and covered by combined CI | Outstanding product acceptance |
|---|---|---|
| 1 | Causal attention, hover abstention, typing focus and RGB evidence/cache | Held-out actual recordings; accuracy, false-positive and secure-field validation |
| 2 | Optical pivot, causal live framing, isolated anticipation, retargeting regression coverage | Natural motion and dense actions on real clips, mixed-display geometry and perceptual signoff |
| 3 | Exact keyboard routing, approved Fresh + three original retro mouse tones, shared mixer, studio policy | Actual listening, Orange Deluxe private install, real audio timing and voice corpus; original no-synthesis rule superseded for three mouse tones only |
| 4 | Fragmented recording/journal recovery, exact track clocks, layout bounds, semantic material, cancellation and edits | Forced process termination recovery bound, CAF durability, actual backdrop luminance, caption collision/masks, device disconnect/low disk, genuine iPhone screen capture unsupported |
| 5 | Isolated decoders, bounded frame LRU, lazy Metal accumulators, checked GPU completion, direct audio accumulation, editor invalidation, actual compressed frame verification | Prefetch and writer readiness, whole-program audio streaming, latest scrub scheduling, full physical-footprint and 60-minute stress, real M1 speed and hardware encoder evidence |

## Measured CI fixtures

- 1080p60 GPU harness: 120 frames, avg 1.93 ms, p50 1.88, p95 2.32, p99 2.59, worst 2.79; zero over budget.
- 4K60 render p99 trials 6.03/7.68/10.53 ms; median 7.68.
- 1080p60 export median 2.21x realtime; 4K60 median 1.14x; existing faster-than-realtime gate passed. Neither demonstrates the 8x/3x stretch goal on target M1.
- Process-lifetime peak RSS reported 709456 KiB and 1748944 KiB respectively; not per-export physical footprint.
- Cadence fixture: 30 actual frames, expected 30.

## Final narrow corrective change

Imported audio and legacy music previously keyed decoded caches by path alone, and mastered mix signature omitted backing media revisions. Use file metadata identity for both layers; avoid publishing under a changed signature. Preserve all existing source media, UI, controls, tests and compatibility. New regression replaces a file at its original path and checks live and reopened mix against an uncached reference. Filesystem identity is not a content hash; deliberate same-size/same-timestamp in-place writes are outside this narrow fix. CI for the correction is separate from the previous green run.

## Release boundary

All five parts contain integrated backend work and the combined automated suite passed. This is not certification of every original to-do item. Do not invent forced-crash, listening, real footage or M1 results. Run the existing real-project proof on target Mac, preserve outstanding checklist items and require final merged CI before full release signoff.
