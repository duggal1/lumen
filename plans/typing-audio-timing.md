# Plan: Restore typing zoom and synchronize enhanced audio
## Goal
Keep typing zoom anchored to the last clicked field, eliminate preview start races, reduce anticipatory camera motion, and expose output gain with backward-compatible storage.
## Non-goals
New dependencies, neural noise-cancellation claims, capture timestamp changes without evidence.
## Invariants
Shortcuts do not zoom. Unanchored keys do not zoom. Audio and video use the same future host start after audio preparation. Latest mix wins. Legacy project audio settings decode. Output remains peak limited.
## Approach
Regression tests first for delayed typing, legacy audio settings, gain and background attenuation. Retain click context for typing; use current cursor for camera follow. Await current mix and schedule the shared playback clock after buffer preparation. Add output gain after loudness normalization and before limiting. Improve conservative background attenuation without shifting samples.
## Verify
swift test; swift build -c release; signed packaging if no application is running. Real microphone listening and visual timing require a recording check; report that limit.
## Files
Sources/LumenDirector/Planner.swift, Sources/LumenDirector/Camera.swift, Sources/LumenProject/Models.swift, Sources/LumenAudio/Mixer.swift, Sources/LumenAudio/DSP.swift, Sources/LumenUI/EditorModel.swift, Sources/LumenUI/Inspector.swift, Tests/LumenTests/TypingAudioTests.swift.
