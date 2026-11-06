<p align="center">
  <img src="App/public/assets/brand/logo/lumen.svg" alt="" width="320" />
</p>

# Screen work, shaped into a clear story

Lumen is a macOS screen recording product for demos, walkthroughs, and product stories. It captures the work as it happens, then uses cursor movement and interaction timing to guide focus and pace.

## Made for clear communication

A useful recording keeps the viewer oriented. Lumen captures a display, window, or selected region, along with the timing and input events that explain what happened on screen. Optional microphone, system audio, and webcam tracks keep the full session together.

From that source, Lumen can derive cursor motion, zoom focus, pacing changes, click cues, and webcam framing. You can keep automatic direction or preserve manual edits in the timeline.

## One source of truth

Each recording lives in a `.lumen` project bundle. The bundle keeps the original media, event data, and project timeline together. The timeline stores creative choices separately from the captured source, so those choices can be adjusted without losing the recording they came from.

The architecture follows that boundary:

- **Capture** records screen media and session signals.
- **Project** stores source details, timeline settings, and derived tracks.
- **Director** turns interaction events into cursor, camera, and pacing guidance.
- **Render and export** are separate stages for composing and delivering the finished recording.

## Product principles

- Keep the original session intact.
- Make automatic direction predictable and editable.
- Keep camera movement, cursor treatment, and pacing in service of the story.
- Preserve a clear path from captured source to finished video.

## Build and run

Requires Apple Silicon, macOS 15+, and Xcode with the Metal toolchain installed.
If Metal is unavailable, run `xcodebuild -downloadComponent MetalToolchain`.

```sh
make build       # Debug app and CLI
make test        # Synthetic media integration and algorithm checks
make app         # Release bundle at .build/Lumen.app
make verify      # Tests, release packaging, signature and launch checks
open .build/Lumen.app
make probe       # Encoder capabilities on this Mac
```

The app icon is generated from `App/public/assets/brand/logo/lumen.svg`.
Local builds use ad hoc signing by default. Set `CODE_SIGN_IDENTITY` to a stable
local signing identity to preserve permission identity across rebuilds.

## Implementation and verification

Capture, project storage, Director, Metal rendering, offline audio mixing,
export, CLI, and SwiftUI app targets are connected. Preview and export use the
same renderer and offline audio mix. Frame placement preserves source aspect
inside the padded canvas. RNNoise is optional; the Swift gate is the fallback.

Tests cover event encoding, time-map inversion and speech protection, manual
zoom preservation, click positioning, camera bounds, repeatable audio and
loudness, repeated frame rendering, and actual exported video frame count.

Validation harnesses are now in the tree and runnable:

- `lumen-cli bench --frames 120` renders a real Metal loop and exits non-zero
  when the p99/over-budget gate is missed (`LumenRender/PerformanceHarness.swift`).
- `lumen-cli golden <project> --update` establishes reference PNGs;
  later runs compare and fail on drift (`LumenExport/GoldenImage.swift`).
- `LumenDirector/SyncHarness.swift` checks flash-and-click drift, cue drift and
  early/late rings across cuts (`flashAndClickStayOnTheSameFrameAcrossCuts`).
- Long-capture derive is covered by a synthetic 10-minute, 60 fps session with
  a resident-memory ceiling (`longCaptureStaysWithinTimeAndMemoryBudget`).

`make verify` still does not certify every acceptance criterion in the parent
build plan. Clean-machine permission checks need hardware verification. The CLI
`sync` command reports offsets only (it does not run the render-level sync
harness); music uses loop/trim crossfades without beat detection; mesh
backgrounds are static; RNNoise is not vendored. Photo backgrounds need an
Unsplash access key and are cached under Application Support. Email
notifications open a mailto draft, not SMTP. MCP control is localhost-only,
opt-in, and has no authentication. The packaged build is not notarized.
