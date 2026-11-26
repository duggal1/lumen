import Foundation

/// Partial edit on the output-time audio lane. nil means unchanged, not zero.
public struct AudioClipPatch: Codable, Sendable {
    public var placement: Double?
    public var trimStart: Double?
    public var trimDuration: Double?
    public var gainDb: Double?
    public var mute: Bool?
    public var loops: Bool?
    public init(placement: Double? = nil, trimStart: Double? = nil, trimDuration: Double? = nil,
                gainDb: Double? = nil, mute: Bool? = nil, loops: Bool? = nil) {
        self.placement = placement; self.trimStart = trimStart; self.trimDuration = trimDuration
        self.gainDb = gainDb; self.mute = mute; self.loops = loops
    }
    public func apply(to lane: inout AudioLane) {
        if let placement { lane.placement = placement }
        if let trimStart { lane.trimStart = trimStart }
        if let trimDuration { lane.trimDuration = trimDuration }
        if let gainDb { lane.gainDb = gainDb }
        if let mute { lane.mute = mute }
        if let loops { lane.loops = loops }
    }
}

public enum AudioClipEditing {
    public static func validate(_ lane: AudioLane, duration: Double) throws {
        guard lane.placement.isFinite, lane.placement >= 0, duration.isFinite,
              lane.placement <= duration, lane.gainDb.isFinite, (-60...12).contains(lane.gainDb),
              lane.trimStart.map({ $0.isFinite && $0 >= 0 }) ?? true,
              lane.trimDuration.map({ $0.isFinite && $0 >= 0.01 }) ?? true else {
            throw CommandError.invalid("invalid audio placement, gain or trim")
        }
        if lane.loops == true && lane.role != .music {
            throw CommandError.invalid("only music beds can loop")
        }
        if let start = lane.trimStart, let length = lane.trimDuration, !(start + length).isFinite {
            throw CommandError.invalid("audio trim overflow")
        }
    }

    /// A split partitions the actual source interval; raw audio is immutable.
    /// Looping beds need explicit conversion to a finite clip before splitting.
    public static func split(_ lane: AudioLane, at: Double, newID: UUID, projectDuration: Double) throws -> (AudioLane, AudioLane) {
        try validate(lane, duration: projectDuration)
        guard lane.path != nil, lane.role != .music || lane.loops == false,
              let length = lane.trimDuration, at.isFinite else {
            throw CommandError.invalid("split requires a finite imported audio clip")
        }
        let offset = at - lane.placement
        guard offset >= 0.01, length - offset >= 0.01, at <= projectDuration else {
            throw CommandError.invalid("split must be inside the audio clip")
        }
        var left = lane, right = lane
        left.trimDuration = offset
        right.id = newID; right.placement = at
        right.trimStart = (lane.trimStart ?? 0) + offset
        right.trimDuration = length - offset
        try validate(right, duration: projectDuration)
        return (left, right)
    }
}
