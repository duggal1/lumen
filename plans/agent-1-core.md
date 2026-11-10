# Plan: recording, camera and privacy correctness

## Goal
Keep Stop responsive, frame typing from actual focus, and redact source pixels before all camera/composite sampling.

## Non-goals
Audio, wallpapers and captions remain owned by Agents 2 and 3. No new tests or broad verification suite.

## Invariants
Capture queues remain bounded; disk serialization never runs on main. Input and video share host time. Camera evaluation uses output time, independent of source cadence. Privacy failure blocks export with an error, never an endless spinner. Recovery preserves the recording's TimeMap semantics.

## Failure modes
Writer backpressure drops frames rather than retaining a backlog. AX timeouts yield no focus and defer to offline frame differences. OCR cancellation/deadline must terminate with an actionable error. Failed finalization retains the recovery journal.

## Approach
Trace existing lifecycle and remove the blocking work, retaining existing fragmentation. Attach background system-wide AX focus snapshots to key events; consume them ahead of pixel-difference traces. Replace camera cascade with deterministic critically damped pan/log-scale springs. Replace projected privacy quads with a full-resolution source pixelation pass and invalidate OCR caches.

## Steps
1. Capture: move stop serialization off main; bound writer input and retain fragmentation. Verify: build and one available recording repro.
2. Camera: key-focused AX, continuous fit scale, 240 Hz springs; retain verified display-link/fixed export clocks. Verify: one existing camera repro.
3. Privacy: accurate full-resolution OCR, labels/bullets, deadline/progress, source Metal mask; minimal privacy controls. Verify: one existing privacy repro.
4. Check recovered clip-lane semantics, inspect diff, build, commit and push agent-1-core.

## Files
Sources/LumenCapture/{Input,Capture,Session,Watchdog}.swift; Sources/LumenDirector/{Planner,Camera,MaskTracks}.swift; Sources/LumenAnalysis/{OCR,Service}.swift; Sources/LumenCore/Sensitive.swift; Sources/LumenRender/Renderer.swift; Sources/LumenRender/Shaders/Shaders.metal; Sources/LumenProject/Overlays.swift; privacy sections of Sources/LumenUI/{Inspector,EditorModel}.swift. Recovery UI wording only if confirmed misleading.
