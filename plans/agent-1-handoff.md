# Agent 1 handoff — incomplete acceptance, implemented core changes

## Current state
Core implementation is committed on agent-1-core. Do not claim complete acceptance. Audio has already merged into main and been merged into this branch. The user requests this PR merged to main now, with local main synchronized and existing local edits preserved.

## Implemented
- Stop: AX sidecar serialization off main; concurrent engine shutdown; bounded latest-frame writer slot and SCK depth 3; existing fragmented MOV retained; finalization progress; duplicate UI Stop guard; watchdog captures an actual process stack during stalls.
- Typing: system-wide background AX field/caret snapshots linked to host-clock key events, <=30Hz with one pending query; permission request and permission-change handling; short bursts recognized; stale-click fallback removed; existing pixel-change fallback accepts two frames. Live and offline field-fit scales are continuous.
- Motion: single critically damped pan/log-scale springs, offline 240Hz tracks with rate-aware interpolation. Existing display-link preview and fixed output-clock export retain sample-and-hold decoding.
- Privacy: timed AX secure-field sampling, full-resolution tiled accurate OCR, email/bullet detection, label-neighbor detection, tracking between OCR samples, held-frame mask extension, scan deadline/progress, source-space Metal pixelation before camera/composite, shared thumbnail rendering, pixel-size control, style picker removed. Legacy mask enum values remain readable; all rendering uses pixelation.
- Recovery checked: primary recording is represented by TimeMap/screen.mov; clips stores imported footage. Empty clips is not missing media. Lane wording remains misleading; not changed.

## Validation performed
- make build passed for Agent 1 committed HEAD 1c03ea9 in /tmp/lumen-agent1-check, isolated from unrelated dirty caption edits.
- Four existing targeted checks passed in one run: eventWriterTimerRunsOffMainActor, tracerFollowsGrowingLine, maskRecallOnKnownSecrets, shotArrivesAndFaceCropFollowsZoom.
- Temporary typing repro: no click, AX field widths 400/800 produced 3.0x/1.5x; camera 240Hz; maximum adjacent 60fps log-scale step 0.04712. /tmp/lumen-agent1-typing-repro.swift.
- Real 60-second 60fps native-display capture stopped and saved, recovery journal removed, no watchdog stalls. Display was 2880x1800, NOT 4K. /tmp/lumen-agent1-capture.log and /tmp/lumen-agent1-capture/Recording 2026-11-10T155450.lumen.
- Temporary 3840x2160 known-email video repro: full-resolution OCR found email; actual Metal pixelation executed and same-cell output samples matched within dither tolerance. /tmp/lumen-agent1-privacy-repro.swift and .log. Run binary inside build output directory so SwiftPM shader bundle resolves.
- Focused reviewer found tracker lifecycle and static-source mask expiry issues; both fixed; reviewer approved those corrections.
- Integrated make build after audio/main sync also passed at 4161f27 (22.48s); /tmp/lumen-agent1-integrated-build.log.
- No make verify, full suite, or new repository test files.

## Required next work
1. Live Spotlight/Launchpad typing capture with Accessibility granted: inspect recorded key AX indices and focus positions; confirm caret/field motion matches camera in preview and exported playback. Current synthetic proof is not end-to-end AX acceptance.
2. Actual 4K60 minute capture with active input: measure Stop latency/memory; read a watchdog stack only if a stall occurs. Native-display proof above does not establish 4K acceptance.
3. Gmail and password-reveal/zoom-transition acceptance; inspect masks on intermediate frames, preview/export/thumbnails, sensitivity and padding. Known-email OCR/Metal proof does not certify Gmail or every label layout.
4. Validate tracking loss, cancellation/retry, scan deadline, and long-clip throughput. Hard timeout fails closed, but repeated canceled Vision jobs and busy pages need operational validation. OCR runs at sampled source frames plus intermediate tracking, not a separate immediate OCR trigger on every visual change.
5. Correct main-lane representation/wording for the TimeMap-backed recording with UI owner; do not insert a synthetic imported clip that would bypass camera/cursor/time-map semantics.
6. Confirm fragmentation recovery after forced termination; existing fragmentation was retained, not newly proven crash-safe.
7. Continue preserving unrelated uncommitted edits; the integrated build has now passed.

## Local edits to preserve
At handoff, unrelated uncommitted work exists in Captions.swift, Overlays.swift, TextOverlay.swift, EditorModel.swift and Inspector.swift. Its owner is unknown; Agent 3 explicitly said it is not theirs. Do not commit it into Agent 1, reset/restore it, or overwrite it. Shared working tree can fail to build due to these partial caption changes; use an isolated committed checkout to assess shipped code.

## Files changed
Capture: Input, Capture, Session, Watchdog. Core: Core, Sensitive. Director: Planner, Camera, LiveCamera, Director, MaskTracks, Placement, WebcamFraming. Analysis: OCR, Service, TypingAnalyzer, TypingTracer. Project: Models, Derived, Overlays (privacy only). Export: ProjectSession. Render: Renderer, Shaders/Shaders.metal. UI integration: AppModel, EditorModel (privacy), Inspector (privacy), LibraryView (saving progress), LivePreview, ProjectThumb. Plan: plans/agent-1-core.md.
