# Lanes — file globs per lane. Magnetic-lane edits go through `reduce()` only.
# A cross-lane edit requires the owner lane's tests green in the same push.

lane=timeline
globs=Sources/LumenUI/TimelineStrip.swift,Tests/LumenTests/Timeline*

lane=editor
globs=Sources/LumenUI/EditorView.swift,Tests/LumenTests/EditingTests.swift,Tests/LumenTests/EditingFuzzTests.swift

lane=audio
globs=Sources/LumenAudio/**,Tests/LumenTests/StudioGradeTests.swift,Tests/LumenTests/Audio*

lane=capture
globs=Sources/LumenCapture/**,Tests/LumenTests/RecordingPipelineTests.swift

lane=project (commands/migrations)
globs=Sources/LumenProject/**,Tests/LumenTests/MigrationTests.swift,Tests/LumenTests/EditingTests.swift
