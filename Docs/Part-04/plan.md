# Part 4 — Reliability, composition and fast post-processing

Approved scope: preserve native SwiftUI, timeline, source files, MCP and Parts 1–3. Prefer small independent PRs; no broad rewrite. Baseline 0dbae056116d562331f49af9fa3b2becf1c31def (main CI passed). Audio refinement #45 is separate.

## 4A — Durable capture and recovery
Use existing fragmented MOV, PCM audio and atomic journal. Shorten fragment target to 1 s; retain last valid checkpoint alongside current, snapshot clock origins atomically, capture individual track origins and event units, and retain old journal decode behavior. Single-flight stop and finalization; drain pending queues; validate actual video duration; no silent webcam substitution. Keep source media untouched and preserve journal on failure. Explicitly test true SIGKILL recovery, media parsing and A/V sync on Mac; a fragment target is not a measured recovery bound. Sleep/disconnect, CAF durability, active-pause checkpoints and disk exhaustion require real-device proof.

## 4B — Composition and adaptive surfaces
Audit existing layout solver, focus bounds, face masks and caption safe areas, keep user placement authoritative; native adaptive surface, avoid forced dark appearance or sampling permissions. Add tests for invalid inputs and portrait, cutout, screen/camera layouts. No UI redesign.

## 4C — Editing integrity and fast post-processing
Single source/output time map and revision identity. Preserve source recordings, manual edits, undo/redo and crash-safe project save. Inspect duplicated analysis in stop/editor path; avoid work that is immediately repeated, launch independent bounded tasks off main, reuse immutable artifacts and cache by input identity. Do not bypass initial zoom planning until all consumers are proven to handle an unplanned project. Measure time-to-edit separately from background analysis. Validate transcript cuts, silence protection and pause/resume. Investigate genuine iPhone screen capture only through supported APIs; unsupported stays explicit.

## Merge gates
Full macOS CI and packaging on exact head, real recordings and crash tests, privacy and compatibility, then verify merged main. Part 5 owns measured M1 optimization, render/export benchmarks and long stress. Do not call Part 4 complete from partial PRs or unit tests alone.
