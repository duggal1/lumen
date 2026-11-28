# Studio interaction and performance, phase 2

Patch the approved Studio, not a redesign. Prior PR #70 head 2eef23e729ed54092719bf292d0939d823a5e3a3 passed Swift verification before this change. Keep existing keyboard assets, Director, Metal renderer and audio pipeline.

## Motion architecture
- Use a single native no-bounce spring vocabulary: press 100 ms, hover 130/200 ms, release/selection 200 ms, toggle 220 ms, sliding 280 ms. Use spring on emphasis, not time, gain or drag coordinates.
- Use offset-based toggle marker, press feedback on transport icon buttons, slider thumb height/hover/press independent from position. Accessibility Reduce Motion disables decorative motion.
- Native trackpad and pinch remain direct. Discrete mouse wheel alone uses an analytic critically damped spring: one state, one display link, finite bounded displacement, direction reversal without overshoot, stop when settled or interrupted. No extra timers, tasks or dependency.
- UI-only display links negotiate up to 90 Hz, bounded by physical panel; 60 Hz remains 60. Actual macOS cadence is negotiated, not guaranteed. Do not change export fps or force video decode to match chrome animation.

## Performance architecture
- Reuse event mapping and typing bursts per immutable timeline-box revision; finite input filtering, stable sorted snapshot, binary-search viewport and hover candidates. Full sort and time-map scan no longer occur on every scroll, hover or playhead publication.
- Keep exact seek, latest-wins render mailbox, independent display-link preview and bounded audio preparation from phase 1. No render/GPU/audio state updates from decorative spring callbacks.
- Next measured bottlenecks: static dither raster rebuild on playhead highlight (separate static base and dynamic column only if profiling supports it); source waveform peak queries for long fit-to-view projects (exact range-max pyramid, bounded cache with audio revision); seek decode/keyframe cache and texture allocations (measure miss rate and memory); live slider derive and persistence frequency (coalesce model edits only where undo/save semantics permit); inspector tab mount cost. No speculative rewrite of these paths.
- Native Instruments profiling: Time Profiler, Core Animation, Allocations, Metal System Trace. Use existing LUMEN_CADENCE_REPORT and LUMEN_CADENCE_COMMIT playback probe. Compare same recording, settings and display with prior head; 1080p60 and 4K60, 30 s and 30 min, rapid scrub, trackpad/wheel, slider, toggle, window occlusion, reduced motion. Record p50/p95/p99 frame interval, skipped frames, main-thread frame work, peak RSS, GPU time, audio resume latency. Targets: 16.67 ms at 60 Hz, 11.11 ms at 90 Hz; p95 within refresh budget, no unbounded queue, no sustained dropped frames. Report actual measured results; M1 8GB required, no inferred FPS.
- Regression tests for exact spring travel, reversal, finite input, panel limits, cache invalidation and query parity. Full macOS CI and package signature required before merge.
