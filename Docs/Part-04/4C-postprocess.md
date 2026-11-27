# 4C — Post-processing cancellation and edit integrity

- Stop admitting stale analysis jobs immediately upon cancellation. Existing workers drain cooperatively; explicit privacy completion preserves partial evidence.
- Avoid building Metal activity analyzer on cache hit. Check cancellation before computing/caching artifacts and at every 1 MiB media digest chunk; reject media identity that changes mid-hash.
- Index AX key events and causal clicks once, replacing repeated whole-log scans per typing burst with sorted lookups. Exact frame/anchor semantics are preserved for time-ordered source input.
- Coalesce nearby typing and activity replans, without delaying initial privacy masks.
- Protect automatically detected silent visual changes from pause removal; editor skips automatic pause removal until activity grids are present. Explicit filler selection remains separate.
- Validate edit scalars; fix reversed cut expansion trimming and lane ripple seam clamping. Avoid allocating a user-supplied sentence range before validating it.
- Four regression tests. These are engineering improvements, not a measured M1 latency claim. Existing planner caches, source media and UI remain. Full export benchmarks belong to Part 5.
- Outstanding: full transcript failure-state/undo and save stress matrix, device capture, broader composition/face-mask/caption validation, actual process termination and recovery measurements. No unsupported iPhone screen claim.
