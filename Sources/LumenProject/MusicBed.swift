import Foundation
import LumenCore

/// A music bed is an OUTPUT-time audio item on its own lane. It is value data:
/// no decoding, no clock, no thread. All time fields are seconds; `placement`
/// is output time, `trimStart` / `trimDuration` are time inside the source track.
///
/// Ownership: persisted as part of the project intent. Threading: immutable
/// `Sendable` value, safe to render on any queue.
public struct MusicBed: Codable, Equatable, Sendable, Identifiable {
    /// Decoded at 48 kHz by the audio layer. A bed never fabricates samples.
    public struct PCM: Sendable, Equatable {
        public var left: [Float], right: [Float]
        public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    }

    /// Resolved, sample-exact schedule for one bed. A non-nil `reason` means the
    /// bed cannot render and `count` is zero — never a silent substitute.
    public struct Plan: Sendable, Equatable {
        public var bedID: UUID
        public var start: Int
        public var count: Int
        public var sourceStart: Int
        public var sourceSpan: Int
        public var loops: Bool
        public var crossfade: Int
        public var gain: Float
        public var fadeIn: Int
        public var fadeOut: Int
        public var reason: String?
        public var isRenderable: Bool { reason == nil && count > 0 }
    }

    /// An unmastered stereo stem in the same output timeline as the movie.
    public struct Stem: Sendable, Equatable {
        public var name: String
        public var left: [Float], right: [Float]
        public init(name: String, left: [Float], right: [Float]) {
            self.name = name; self.left = left; self.right = right
        }
    }

    public var id: UUID
    public var assetPath: String
    public var placement: Double
    public var trimStart: Double
    public var trimDuration: Double?
    public var gainDb: Double
    public var duckDepthDb: Double
    public var loops: Bool
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: UUID = UUID(), assetPath: String, placement: Double = 0,
                trimStart: Double = 0, trimDuration: Double? = nil,
                gainDb: Double = -18, duckDepthDb: Double = -14,
                loops: Bool = true, fadeIn: Double = 0.3, fadeOut: Double = 1.5) {
        self.id = id; self.assetPath = assetPath; self.placement = placement
        self.trimStart = trimStart; self.trimDuration = trimDuration
        self.gainDb = gainDb; self.duckDepthDb = duckDepthDb
        self.loops = loops; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    /// The modern `.music` lane is the persisted form; convert without losing
    /// its output-time anchor, trim, gain or identity.
    public init(lane: AudioLane) {
        self.init(id: lane.id, assetPath: lane.path ?? "", placement: lane.placement,
                  trimStart: lane.trimStart ?? 0, trimDuration: lane.trimDuration,
                  gainDb: lane.gainDb, loops: true)
    }

    // MARK: Plan

    /// Resolve a bed into whole sample indices. Deterministic and total: hostile
    /// values (NaN, negative, past-end) produce an explicit reason, never a crash.
    public static func plan(_ bed: MusicBed, track: PCM, outputSamples: Int, fs: Double) -> Plan {
        var p = Plan(bedID: bed.id, start: 0, count: 0, sourceStart: 0, sourceSpan: 0,
                     loops: bed.loops, crossfade: 0, gain: 1, fadeIn: 0, fadeOut: 0, reason: nil)
        guard outputSamples > 0, fs.isFinite, fs > 0 else { p.reason = "invalid output"; return p }
        let sourceCount = min(track.left.count, track.right.count)
        guard sourceCount > 0 else { p.reason = "empty track"; return p }
        guard bed.placement.isFinite, bed.placement >= 0 else { p.reason = "invalid placement"; return p }

        let start = Int((bed.placement * fs).rounded(.down))
        guard start < outputSamples else { p.reason = "placement past end"; return p }

        let trim = bed.trimStart.isFinite ? max(0, bed.trimStart) : 0
        let sourceStart = min(Int((trim * fs).rounded(.down)), sourceCount)
        let available = sourceCount - sourceStart
        var span = available
        if let duration = bed.trimDuration, duration.isFinite {
            span = min(max(0, Int((duration * fs).rounded(.down))), available)
        }
        guard span > 0 else { p.reason = "empty trim"; return p }

        let room = outputSamples - start
        p.start = start
        p.count = bed.loops ? room : min(room, span)
        p.sourceStart = sourceStart
        p.sourceSpan = span
        p.crossfade = bed.loops && span > 1 ? min(Int((0.5 * fs).rounded(.down)), span / 2) : 0
        p.gain = Float(pow(10, clamp(bed.gainDb, -60, 24) / 20))
        p.fadeIn = bed.fadeIn.isFinite ? max(0, Int((bed.fadeIn * fs).rounded(.down))) : 0
        p.fadeOut = bed.fadeOut.isFinite ? max(0, Int((bed.fadeOut * fs).rounded(.down))) : 0
        return p
    }

    // MARK: Render

    /// Linear interpolation of the 100 Hz voice/duck envelope at output sample
    /// `i`. A missing or short envelope is unity — music must never go silent
    /// because derived data was truncated.
    public static func duckGain(_ duck: [Float]?, atSample i: Int, fs: Double) -> Float {
        guard let d = duck, !d.isEmpty, fs > 0, i >= 0 else { return 1 }
        let p = Double(i) / fs * 100
        let i0 = min(Int(p), d.count - 1)
        let i1 = min(i0 + 1, d.count - 1)
        return d[i0] + (d[i1] - d[i0]) * Float(p - Double(i0))
    }

    /// Loop a source excerpt with a half-second equal-gain crossfade at each
    /// seam, then apply placement, trim, edge fades, gain and ducking. Returns a
    /// full output-length buffer so beds can be summed without re-indexing.
    public static func render(_ plan: Plan, track: PCM, duck: [Float]?,
                              outputSamples: Int, fs: Double) -> PCM {
        var L = [Float](repeating: 0, count: outputSamples)
        var R = L
        guard plan.isRenderable, plan.start + plan.count <= outputSamples else {
            return PCM(left: L, right: R)
        }
        let span = plan.sourceSpan, xf = plan.crossfade
        var i = 0
        while i < plan.count {
            let c = min(span, plan.count - i)
            for k in 0..<c {
                var a: Float = 1
                if xf > 0 && i > 0 && k < xf { a = Float(k) / Float(xf) }
                if xf > 0 && c == span && k >= span - xf && i + span < plan.count {
                    a = min(a, Float(span - k) / Float(xf))
                }
                let src = plan.sourceStart + k
                let dst = plan.start + i + k
                L[dst] += track.left[src] * a
                R[dst] += track.right[src] * a
            }
            i += max(span - xf, 1)
        }
        for j in 0..<plan.count {
            let fin = plan.fadeIn > 0 ? min(1, Float(j) / Float(plan.fadeIn)) : 1
            let fout = plan.fadeOut > 0 ? min(1, Float(plan.count - j) / Float(plan.fadeOut)) : 1
            let g = plan.gain * fin * fout * duckGain(duck, atSample: plan.start + j, fs: fs)
            let idx = plan.start + j
            L[idx] *= g; R[idx] *= g
        }
        return PCM(left: L, right: R)
    }

    /// Sum several beds. Tracks must already be decoded by the throwing audio
    /// loader; a bed whose track is absent is skipped rather than faked.
    public static func render(beds: [MusicBed], tracks: [UUID: PCM], duck: [Float]?,
                              outputSamples: Int, fs: Double) -> PCM {
        var L = [Float](repeating: 0, count: outputSamples)
        var R = L
        for bed in beds {
            guard let track = tracks[bed.id] else { continue }
            let one = render(plan(bed, track: track, outputSamples: outputSamples, fs: fs),
                             track: track, duck: duck, outputSamples: outputSamples, fs: fs)
            for i in 0..<outputSamples { L[i] += one.left[i]; R[i] += one.right[i] }
        }
        return PCM(left: L, right: R)
    }

    /// One unmastered stem per bed, in the same output timeline as the movie.
    public static func stems(_ beds: [MusicBed], tracks: [UUID: PCM], duck: [Float]?,
                             outputSamples: Int, fs: Double) -> [Stem] {
        beds.compactMap { bed in
            guard let track = tracks[bed.id] else { return nil }
            let p = render(plan(bed, track: track, outputSamples: outputSamples, fs: fs),
                           track: track, duck: duck, outputSamples: outputSamples, fs: fs)
            return Stem(name: "music", left: p.left, right: p.right)
        }
    }
}
