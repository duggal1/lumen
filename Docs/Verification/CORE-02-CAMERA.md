# Core overhaul: Part 2 — cinematic camera

This patch addresses the automatic motion policy and live/offline timing seam without replacing the 480 Hz camera solver or the native renderer.

- Isolated automatic actions with real planner provenance receive scale- and distance-dependent anticipation. Existing manual easing and dense-shot timing are retained. The target is still settled by the action, not after it.
- A recorded follow path continues to influence the lens after arrival. The transition uses a quintic gate and a critically damped response; stationary fixed/typing targets are not converted into follow shots. Removed the implicit horizontal path bias.
- The automatic tail uses an optical ratio rather than an arbitrarily clamped pivot. It starts at the existing center, handles near-1x and aspect/crop constraints, and lands at neutral.
- The full-source exact pivot uses the actual capped magnification and is not imposed on crop-space trajectories.
- The causal live camera integrates the previous target to each event time and preserves elapsed time between ordinary display callbacks. Only explicit primary clicks/typing can reveal a crop; scroll and secondary clicks cannot reopen a stale shot.

Added eight focused regression cases, including a delayed focus reply after a newer click and fixed-focus crop-space release geometry. The entire existing suite remains required, including fixed-pivot, timing, crop, loupe and motion blur tests. No timing assertions were weakened.

Limitations: the longer anticipation is deliberately restricted to isolated automatic actions; dense handoffs and existing manual controls retain their previous timing. Real macOS recordings and frame-by-frame motion metrics are necessary to determine whether the resulting feel meets the product bar. Cursor skins, loupe rendering, webcam-aware composition and optical-blur quality have not been comprehensively reworked in this patch. See todo.md for remaining validation.

## CI regression correction

Run 45898300325 compiled successfully and reported three issues across 882 tests. Two scripted dense-click jerk checks measured 596,902,500 against the existing 10,000,000 bound; the click anticipation harness measured 0.55 s against the existing 0.50 s upper bound. All eight newly added regression tests passed. Keep those tests and the old assertions intact. Restrict continuous follow to isolated action intervals, preserve the established dense optical-handoff composition, avoid pan snaps during continuous following, and bound ordinary click anticipation to the established timing contract. The dense moving-target trajectory remains an explicit follow-up; do not claim full cinematic signoff. Verify the replacement head through the complete existing workflow.
