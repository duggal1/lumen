# Plan: Magnetic main-lane editing layer

## Goal
Add a minimal Final Cut-style magnetic main lane (split, ripple delete, join, copy/paste/duplicate, trim, drag reorder, undo/redo) on top of existing Timeline accounting. The recording is a single SOURCE span (trimmed plus TimeMap cuts) — splits are logical boundaries inside contiguous source, so camera/cursor are never reset.

## Non-goals
Copy/paste/duplicate for zooms/masks/etc. Mirroring app keyboard shortcuts for menu items. Secondary tracks, storylines, or transitions beyond cut/dissolve.

## Invariants
- A split changes nothing in output (identical frames and samples, including camera). Splits inside contiguous source never reset camera.
- Anything anchored to clip content (masks, zooms, loupes, taps, layouts, cuts, ramps, captions) travels with its clip, partitions on split, survives copy/paste/duplicate.
- Soundtrack lanes (music, voiceover, trimStart/trimEnd) are NOT copied/trimmed by split/trim; only ripple-shifted by ripple-delete.
- No gaps after ripple delete: trailing clips ripple to close the hole.
- Playhead is the only time source for split and paste; it is captured at dispatch via ReduceContext.playhead, never pointer state.
- Join merges adjacent clips from contiguous source ranges of one recording into a single clip.

## Failure modes
- Empty timeline: commands return `.invalid` without state change.
- Paste at boundary: paste inserts at playhead; clips that overlap the playhead shift to make room (ripple insert).
- Trim: inPoint+duration clamped to source range; trimmed-off portion becomes a cut if inside trimStart/trimEnd.
- Duplicate: pastes immediately after the original clip's end.

## Approach
Represent the main lane as `Timeline.clips: [TimelineClip]` with OUTPUT `start`/`duration`/`inPoint` plus a special `.recording` clip covering the trimmed recording (`sourceDuration`, inPoint=trimStart). Split/trim/join/duplicate/paste/ripple all operate on this same clip array so anchored overlays (source-anchored) stay valid without re-anchoring: they are checked against their source time, and trim/cut still clamps them. The recording clip's `inPoint+duration` must stay within `[trimStart, trimEnd]` (its end is clamped).

Implementation in Commands.swift only for state mutation. Overlay partitioning on split: masks/zooms/etc. that span the split get partitioned by the existing `CutRange` machinery (overlapping time-clipped, not duplicated). Partition uses new UUIDs for the post-split half; kept simple (end-clamped clones).

Undo/redo is snapshot-based; no separate stack required for this layer.

## Steps
1. Add `TimelineClip.ordering` helpers: `sortedClips`, `recordingClip()`, `normalize()` (clamp + no gaps). Verify: `swift test --filter Editing`.
2. Add Commands: `splitClip(atOutput:)`, `rippleDeleteClip(id:)`, `joinClips(ids:)`, `duplicateClip(id:)`, `pasteClip(clip:atOutput:)`, `moveClip` steady, plus `snapClips`. Verify: unit tests.
3. Partition overlays on split/trim (new UUIDs, clamped). Verify: mask remains inside its clip's source range after split.
4. Wire frontend: TimelineStrip header buttons + drag reorder + snap toggle in Inspector Timeline tab. Shortcut list in UI. Verify: manual drag check.
5. Full suite + fuzz test. Verify: `swift test`.
6. Commit per task.

## Files
- Sources/LumenProject/Commands.swift
- Sources/LumenProject/Composition.swift
- Sources/LumenUI/TimelineStrip.swift
- Sources/LumenUI/EditorView.swift
- Tests/LumenTests/EditingTests.swift (oracle, frozen)
- Sources/LumenUI/MusicPicker.swift (already exists; minimal touch only)
