# Studio precision interaction plan

Baseline 39d43046b4638768ef38e6b0f72cd774daf85575. Preserve the approved native Studio layout, dark surfaces, dither timeline, cursor skins, capture/director/export pipeline and retro mouse clicks.

## Interaction implementation
- Whole-program seek bar and click-to-seek on ruler; drag ruler to pan, timeline gestures remain exact.
- Pause audio once at scrub start, latest clock position per pointer delta, resume once at release. Never tween the time coordinate or queue audio windows per drag event.
- One AppKit pinch route (remove overlapping SwiftUI route), positive exponential command-wheel zoom and consistent pointer anchor. Native trackpad momentum remains direct.
- Shared non-bouncy animation for hover/press/selection/toggle; decorative slider hover/drag only. Native reduce-motion preference honored. Never globally animate canvas layout or video clock.
- Keep existing display-link, mailbox, bounded decode, renderer and async waveform architecture. Profile rather than claim 60 fps.

## Audio
- Import only the CC0 Classic recordings in Sound-Library pinned commit da2d497cb0a734b642c4b7635793f5300d1f24e2; no Modern sprite (undeclared license), no procedural replacements, no mouse changes. Preserve per-key routing and release honesty, explicit private-pack preference and unsupported key fallback. Offline bundled assets; no network playback.

## Verification
- Unit regressions for exact seeks, resume once, no autoplay on paused drag, pinch single path, wheel anchoring and slider limits; retain all existing Swift verification.
- Real Mac: 30-second and 30-minute videos, 1080p60/4K60, seek forward/backward rapidly, drag while playing, page/trackpad/mouse scroll, rapid volume slider, keyboard navigation, reduced motion, window close mid-gesture.
- Measure presented frame intervals (p95/p99), dropped frames, main-thread work, peak memory and audio start delay on M1 8 GB. Target 60 fps; do not certify from CI alone. Listen to recorded keys at varied typing rates against old pack, compare click waveform identity and export/preview parity.
- No merge until exact head CI passes and overlap with other PRs is checked.
