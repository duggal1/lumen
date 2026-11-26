# Core overhaul: PR 1 of 5 — attention provenance

Scope: causal pointer lookup, track-level hover rejection, confidence-gated typing fallback, focus context isolation, content-aware activity cache invalidation, and color-aware activity analysis. No UI or audio changes.

The hover policy deliberately abstains from remote changes for 2.5 seconds after a move without a newer explicit interaction; stationary local hover remains suppressed. A rejected track cannot resurrect during the same continuous activity. This is a conservative heuristic, not semantic certainty: remote hover changes starting much later and autonomous changes inside the uncertainty window cannot always be distinguished from energy grids alone. Real recordings are required for calibration. Existing automatic result framing remains enabled.

Tests add delayed hover, remote persistent hover, independent remote result, future pointer, click causality, low-confidence typing fallback, and different focus epochs. The Metal analyzer cache version is bumped because energy now includes chromatic changes. Verification on real macOS recordings is required before claiming product-level accuracy.

Remaining PRs: 2 camera motion/framing; 3 recorded sound effects and studio audio; 4 adaptive glass, layouts and capture/editing reliability; 5 preview/export performance and end-to-end release verification.
