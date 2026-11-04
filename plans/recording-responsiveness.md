# Plan: Keep recording completion responsive
## Goal
Remove synchronous UI-thread waits during recording stop and first editor initialization.
## Non-goals
Change effects, export quality, capture settings, or UI design.
## Invariants
Event writer and accessibility queues drain before project finalization. AppKit cursor serialization stays on MainActor. Renderer has one owner after initialization.
## Failure modes
Accessibility can wait on the app UI: await queue completion without blocking MainActor. First Metal pipeline compilation and timeline derivation can be expensive: initialize on a detached task.
## Steps
1. Run existing tests as baseline.
2. Make InputRecorder.stop asynchronous; migrate session and regression test callers.
3. Move editor initialization and derivation off MainActor.
4. Run tests, release build, package using stable signing identity when app is not running.
## Files
Sources/LumenCapture/Input.swift, Sources/LumenCapture/Session.swift, Sources/LumenUI/EditorModel.swift, Tests/LumenTests/InputRecorderTests.swift.
