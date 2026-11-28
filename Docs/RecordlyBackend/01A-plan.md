# Backend phase 1A — bounded export waits and common delivery proof

Parent plan: RECORDLY_BACKEND_PLAN.md, Part 1. Base 39d43046b4638768ef38e6b0f72cd774daf85575; Recordly reference e17a6f7 (architectural concepts only, independent Swift implementation).
- Preserve exact codec, resolution, fps, audio mix, privacy, renderer and 3-frame queue.
- Cancellation-aware single-result latch; bounded GPU, encoder readiness, actual audio sample progress and writer finalization waits; no false signal to GPU resource pool.
- Move existing compressed sample and representative decode validation into LumenExport; Studio/CLI/agent all validate before publication. Agent consumes same receipt rather than running a second scan.
- Regression tests for callback absence/late completion, cancellation and advancing/duplicate progress.
- Conservative initial deadlines (30s GPU/encoder, 60s audio, duration-based finalization) are not calibrated hardware measurements.
- Remaining Part 1 work: uncooperative OS cancel/decode/DSP calls, ownership of deferred cleanup, stage-wide recovery policy with proven alternate route, transactional sidecar set, typed NSError classification, codec/color proof and full hardware fault injection. No automatic retry until supported route is proven. Do not call Part 1 complete yet.
- Merge only on exact-head full CI and green current main; M1 actual throughput and visual privacy evidence remain separate.
