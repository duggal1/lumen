import Foundation
import LumenCore

// MARK: - Hostile-input boundary

/// Converts a non-finite time into a finite fallback. Swift's `max`/`min`
/// propagate NaN (verified: `max(.nan, 0) == .nan`), so clamping alone is not a
/// hostile-input defence — every external time must pass through this first.
@inline(__always)
public func finiteTime(_ x: Double, default fallback: Double = 0) -> Double {
    x.isFinite ? x : fallback
}

// MARK: - Undoable commands

/// Pure, value-type undo/redo around the single `reduce` mutation entry point.
///
/// The timeline is an immutable value: a successful edit snapshots it before
/// applying the command to a draft, and only commits the draft on success. A
/// refused command therefore leaves the history byte-identical — there is no
/// half-applied edit to undo. Undo/redo swap snapshots and are no-ops on an
/// empty stack. This mirrors the snapshot stacks in EditorModel/Engine without
/// owning a window, a timer or a file.
public struct VideoEditHistory: Equatable, Sendable {
    public private(set) var timeline: Timeline
    public private(set) var undoStack: [Timeline] = []
    public private(set) var redoStack: [Timeline] = []
    /// Maximum snapshots kept on either stack. Oldest entries are dropped first.
    public let limit: Int

    public init(_ timeline: Timeline, limit: Int = 100) {
        self.timeline = timeline
        self.limit = max(limit, 0)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Apply one command at a captured playhead. On success the previous
    /// timeline becomes one undo step and the redo stack is cleared. On failure
    /// nothing changes — including the invalidation effects, which are only
    /// returned for a committed edit.
    @discardableResult
    public mutating func apply(_ command: Command, playhead: Double, selection: UUID? = nil) throws -> Effects {
        let ctx = ReduceContext(playhead: playhead, selection: selection,
                                duration: timeline.compositionDuration)
        let previous = timeline
        var draft = timeline
        let effects = try reduce(&draft, command, ctx: ctx)
        timeline = draft
        undoStack.append(previous)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        return effects
    }

    /// Restore the previous snapshot. Returns false (a no-op) when nothing is
    /// undoable, so rapid repeated undo is safe and idempotent.
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(timeline)
        if redoStack.count > limit { redoStack.removeFirst(redoStack.count - limit) }
        timeline = previous
        return true
    }

    /// Re-apply the most recently undone snapshot. No-op on an empty stack.
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(timeline)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        timeline = next
        return true
    }
}
