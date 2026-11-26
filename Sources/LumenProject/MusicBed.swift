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
                  gainDb: lane.gainDb, loops: lane.loops ?? true,
                  fadeIn: lane.loops == false ? 0.01 : 0.3, fadeOut: lane.loops == false ? 0.01 : 1.5)
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

        // Bound in floating point before conversion: huge but finite saved
        // times (or their product with fs) must not trap Int conversion.
        func index(_ seconds: Double, limit: Int) -> Int {
            let samples = seconds * fs
            if samples >= Double(limit) { return limit }
            if !samples.isFinite || samples <= 0 { return 0 }
            return Int(samples.rounded(.down))
        }
        let start = index(bed.placement, limit: outputSamples)
        guard start < outputSamples else { p.reason = "placement past end"; return p }

        let trim = bed.trimStart.isFinite ? max(0, bed.trimStart) : 0
        let sourceStart = index(trim, limit: sourceCount)
        let available = sourceCount - sourceStart
        var span = available
        if let duration = bed.trimDuration, duration.isFinite {
            span = index(duration, limit: available)
        }
        guard span > 0 else { p.reason = "empty trim"; return p }

        let room = outputSamples - start
        p.start = start
        p.count = bed.loops ? room : min(room, span)
        p.sourceStart = sourceStart
        p.sourceSpan = span
        p.crossfade = bed.loops && span > 1 ? index(0.5, limit: span / 2) : 0
        p.gain = Float(pow(10, clamp(bed.gainDb.isFinite ? bed.gainDb : -18, -60, 24) / 20))
        p.fadeIn = bed.fadeIn.isFinite ? index(bed.fadeIn, limit: Int.max / 2) : 0
        p.fadeOut = bed.fadeOut.isFinite ? index(bed.fadeOut, limit: Int.max / 2) : 0
        return p
    }

    // MARK: Render

    /// Linear interpolation of the 100 Hz voice/duck envelope at output sample
    /// `i`. A missing or short envelope is unity — music must never go silent
    /// because derived data was truncated.
    public static func duckGain(_ duck: [Float]?, atSample i: Int, fs: Double) -> Float {
        guard let d = duck, !d.isEmpty, fs.isFinite, fs > 0, i >= 0 else { return 1 }
        let p = min(Double(i) / fs * 100, Double(d.count - 1))
        let i0 = Int(p)
        let i1 = min(i0 + 1, d.count - 1)
        let a = d[i0].isFinite ? d[i0] : 1
        let b = d[i1].isFinite ? d[i1] : 1
        return a + (b - a) * Float(p - Double(i0))
    }

    /// Shared sample evaluator for whole export and bounded preview windows.
    /// Both paths must agree at loop seams, the final partial repeat and short
    /// clips whose entrance and exit fades overlap.
    public static func sample(_ plan: Plan, track: PCM, duck: [Float]?,
                              at output: Int, fs: Double) -> (left: Float, right: Float) {
        guard plan.isRenderable, plan.start >= 0, output >= plan.start,
              plan.sourceStart >= 0, plan.sourceSpan > 0,
              plan.sourceStart <= min(track.left.count, track.right.count),
              plan.sourceSpan <= min(track.left.count, track.right.count) - plan.sourceStart,
              plan.crossfade >= 0, plan.crossfade <= plan.sourceSpan / 2 else { return (0, 0) }
        let local = output - plan.start
        guard local < plan.count else { return (0, 0) }
        let period = plan.loops ? plan.sourceSpan - plan.crossfade : plan.sourceSpan
        let phase = plan.loops ? local % period : local
        guard phase < plan.sourceSpan else { return (0, 0) }
        let index = plan.sourceStart + phase
        var l = track.left[index], r = track.right[index]
        if plan.loops, local >= period, phase < plan.crossfade {
            let old = index + period
            let t = Float(phase) / Float(plan.crossfade)
            l = l * t + track.left[old] * (1 - t)
            r = r * t + track.right[old] * (1 - t)
        }
        let fin = plan.fadeIn > 0 ? min(1, Float(local) / Float(plan.fadeIn)) : 1
        let fout = plan.fadeOut > 0 ? min(1, Float(plan.count - local) / Float(plan.fadeOut)) : 1
        let gain = plan.gain * fin * fout * duckGain(duck, atSample: output, fs: fs)
        return (l * gain, r * gain)
    }

    public static func render(_ plan: Plan, track: PCM, duck: [Float]?,
                              outputSamples: Int, fs: Double) -> PCM {
        let count = max(outputSamples, 0)
        var L = [Float](repeating: 0, count: count)
        var R = L
        guard plan.isRenderable, plan.start >= 0, plan.start <= count,
              plan.count <= count - plan.start else { return PCM(left: L, right: R) }
        for output in plan.start..<(plan.start + plan.count) {
            let value = sample(plan, track: track, duck: duck, at: output, fs: fs)
            L[output] = value.left; R[output] = value.right
        }
        return PCM(left: L, right: R)
    }

    /// Sum several beds. Tracks must already be decoded by the throwing audio
    /// loader; a bed whose track is absent is skipped rather than faked.
    public static func render(beds: [MusicBed], tracks: [UUID: PCM], duck: [Float]?,
                              outputSamples: Int, fs: Double) -> PCM {
        guard outputSamples > 0 else { return PCM(left: [], right: []) }
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
