# 4B — Composition bounds and native surfaces

Independent of 4A and audio refinement. Preserve approved UI. Normalize malformed aspect and inset input; keep all layout rectangles inside canvas; guard partial track arrays and nonfinite input; never apply camera-overlay placement to a different explicitly configured layout. Use shared native popover material in floating panels and live preview instead of a forced dark HUD and hardcoded opaque wash; respect accessibility preferences and dynamic text color. No new capture permission or private API.

This is a first composition and material hardening slice. Actual per-pixel backdrop classification, temporal face-mask quality, caption collision solver and real-recording visual acceptance are still pending. System material adapts to effective appearance and compositor context; no claim that it automatically classifies the luminance behind every panel. Three new regression tests; macOS CI pending.
