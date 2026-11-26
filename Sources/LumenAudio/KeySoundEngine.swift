import Foundation
import AVFoundation
import LumenCore
import LumenProject

// Real recorded, CC0-licensed one-shots only. Every sample in this engine is a
// slice of a Freesound/Woven recording prepared by scripts/fetch_sounds.py;
// nothing is synthesised and nothing is generated at runtime.
//
// Design contract:
//  * every macOS keycode resolves to one of nine key CLASSES, each with its own
//    recorded down and up takes (5 and 4 variants);
//  * a deterministic router cycles variants round-robin and adds tiny pitch /
//    gain offsets so fast typing never machine-guns the same waveform;
//  * cues are placed at their recorded output timestamps, sample-accurately;
//  * a lookahead limiter sits on the shared bus so bursts cannot clip.

public enum KeyPhase: String, Sendable { case down, up }

public enum KeyClass: String, CaseIterable, Sendable {
    case alpha, number, space, enter, backspace, shift, modifier, nav, fn, click
}

public extension KeyClass {
    /// Canonical class for a macOS virtual keycode. Modifiers and navigation
    /// keep their own recordings instead of collapsing onto a letter sample.
    static func forCode(_ code: Int) -> KeyClass {
        switch code {
        case 49: return .space
        case 36, 76: return .enter
        case 51, 117: return .backspace
        case 56, 60, 57: return .shift
        case 54, 55, 58, 59, 61, 62, 63: return .modifier
        case 48, 53, 115, 116, 118, 119, 121, 123, 124, 125, 126: return .nav
        case 18...29, 30, 33, 39, 41, 42, 43, 44, 47, 50: return .number
        case 96...104, 120, 122: return .fn
        default: return .alpha
        }
    }
}

/// One mastered 48 kHz mono take.
public struct KeyTake: Sendable {
    public let id: String
    public let samples: [Float]
    public init(id: String, samples: [Float]) { self.id = id; self.samples = samples }
}

/// All recorded takes, loaded once and shared by the offline mixer and preview.
public struct KeySoundLibrary: Sendable {
    public var down: [KeyClass: [KeyTake]] = [:]
    public var up: [KeyClass: [KeyTake]] = [:]
    public var clicks: [KeyTake] = []

    public var isEmpty: Bool { down.isEmpty && clicks.isEmpty }

    public init() {}

    public static func load(root: URL? = nil) -> KeySoundLibrary {
        var lib = KeySoundLibrary()
        let resolver: (String) -> URL? = root.map { rootURL in
            { (name: String) -> URL? in
                let url = rootURL.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } ?? { (name: String) -> URL? in BundledAudioAssets.sound(named: name) }
        for keyClass in KeyClass.allCases where keyClass != .click {
            for phase in [KeyPhase.down, .up] {
                var takes: [KeyTake] = []
                for index in 1...8 {
                    let name = "typing/\(keyClass.rawValue)/\(keyClass.rawValue)-\(phase.rawValue)-\(index).wav"
                    guard let url = resolver(name), let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { break }
                    takes.append(KeyTake(id: name, samples: pcm))
                }
                if phase == .down { lib.down[keyClass] = takes } else { lib.up[keyClass] = takes }
            }
        }
        for name in ["mouse-click-1", "mouse-click-2", "tick", "snap", "analog"] {
            guard let url = resolver("clicks/\(name).wav"), let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { continue }
            lib.clicks.append(KeyTake(id: name, samples: pcm))
        }
        return lib
    }

    public func takes(_ keyClass: KeyClass, _ phase: KeyPhase) -> [KeyTake] {
        (phase == .down ? down[keyClass] : up[keyClass]) ?? []
    }
}

/// Deterministic variation: round-robin per class/phase plus bounded jitter.
/// The same cue sequence always produces the same rendered audio, which keeps
/// the mix cache and the tests honest.
public struct KeyVariation: Sendable, Equatable {
    public let variant: Int
    public let pitchCents: Double
    public let gainDb: Double
    public init(variant: Int, pitchCents: Double, gainDb: Double) {
        self.variant = variant; self.pitchCents = pitchCents; self.gainDb = gainDb
    }
}

public struct KeyVariationRouter: Sendable {
    /// Small by design: enough to break machine-gun repetition, never enough to
    /// sound like a different keyboard or to drift out of level.
    public static let pitchRangeCents = 28.0
    public static let gainRangeDb = 1.1

    private var seed: UInt64
    private var counters: [String: Int] = [:]

    public init(seed: UInt64 = 0x6C75_6D65_4B65_7901) { self.seed = seed }

    private mutating func random() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func unit() -> Double { Double(random() >> 11) / 9_007_199_254_740_992.0 }

    /// Cycle variants for this class/phase, then add ±pitch and ±gain jitter.
    public mutating func next(_ keyClass: KeyClass, phase: KeyPhase, key: Int,
                              variantCount: Int) -> KeyVariation? {
        guard variantCount > 0 else { return nil }
        let slot = "\(keyClass.rawValue)/\(phase.rawValue)"
        let index = (counters[slot] ?? 0) % variantCount
        counters[slot] = index + 1
        // Key-dependent decorrelation: two different keys of one class still
        // get different jitter even when their round-robin index coincides.
        var local = KeyVariationRouter(seed: seed ^ UInt64(bitPattern: Int64(key) &* 0x2545_F491_4F6C_DD1D))
        let pitch = (local.unit() * 2 - 1) * KeyVariationRouter.pitchRangeCents
        let gain = (local.unit() * 2 - 1) * KeyVariationRouter.gainRangeDb
        seed = local.seed
        return KeyVariation(variant: index, pitchCents: pitch, gainDb: gain)
    }

    /// Click down/up pair chosen together from the five clean click variants.
    /// `preferred` keeps the Inspector's click-tone choice meaningful while the
    /// router still cycles, so a rapid run of clicks is never identical.
    public mutating func clickPair(_ count: Int, preferred: Int? = nil) -> (down: Int, up: Int)? {
        guard count > 0 else { return nil }
        let base = max(0, min(count - 1, preferred ?? 0))
        let cursor = counters["click/down"] ?? 0
        let index = base == 0 ? cursor % count : (base - 1 + cursor) % count
        counters["click/down"] = cursor + 1
        let release = (index + 1 + Int(random() % UInt64(max(1, count - 1)))) % count
        return (index, release)
    }
}

/// Resampling by a pitch ratio. Cubic (Catmull-Rom) keeps the transient crisp;
/// linear interpolation would audibly low-pass a 1 ms key click.
public func pitchShift(_ x: [Float], cents: Double) -> [Float] {
    guard abs(cents) > 0.01, x.count > 2 else { return x }
    let ratio = pow(2.0, cents / 1200.0)
    let count = max(1, Int((Double(x.count) / ratio).rounded()))
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let pos = Double(i) * ratio
        let base = Int(pos.rounded(.down))
        let f = Float(pos - Double(base))
        guard base >= 1, base + 2 < x.count else { continue }
        let p0 = x[base - 1], p1 = x[base], p2 = x[base + 1], p3 = x[base + 2]
        out[i] = p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
    }
    return out
}

/// Lookahead peak limiter on the shared SFX bus. Fast attack, smooth release,
/// hard ceiling: 1000 keys 1 ms apart cannot push the master into clipping.
public struct BusLimiter: Sendable {
    public var ceiling: Float
    public var lookahead: Int
    public var release: Float

    public init(ceiling: Float = 0.89, lookahead: Int = Int(0.003 * AudioIO.fs), release: Float = 0.0009) {
        self.ceiling = max(0.05, min(1, ceiling))
        self.lookahead = max(1, lookahead)
        self.release = release
    }

    public func process(left: inout [Float], right: inout [Float]) {
        let n = min(left.count, right.count)
        guard n > 0 else { return }
        var peaks = [Float](repeating: 0, count: n + lookahead)
        for i in 0..<(n + lookahead) where i < n {
            peaks[i] = max(abs(left[i]), abs(right[i]))
        }
        var previousGain: Float = 1
        // Monotonic deque gives a sliding maximum in O(n).
        var deque: [Int] = []
        for i in 0..<peaks.count {
            while let last = deque.last, peaks[last] <= peaks[i] { deque.removeLast() }
            deque.append(i)
            if let first = deque.first, first <= i - lookahead { deque.removeFirst() }
            if i < lookahead { continue }
            let j = i - lookahead
            let env = peaks[deque.first ?? j]
            let target: Float = env > ceiling ? ceiling / env : 1
            // Instant attack, smooth release back to unity.
            let g: Float = target < previousGain ? target
                                                 : previousGain + (1 - previousGain) * release
            previousGain = g
            left[j] *= g
            right[j] *= g
            // Residual single-sample spikes are soft-clipped, never hard cut.
            if abs(left[j]) > ceiling { left[j] = ceiling * tanh(left[j] / ceiling) }
            if abs(right[j]) > ceiling { right[j] = ceiling * tanh(right[j] / ceiling) }
        }
    }
}

public struct KeyMixSettings: Sendable {
    public var keyLevelDb: Double = -9.0
    public var clickLevelDb: Double = -9.0
    public var includeReleases: Bool = true
    public var limiterCeiling: Float = 0.89
    public var clickTone: ClickSound = .fresh
    public init() {}

    /// Inspector tones map onto the five new CC0 click recordings. Legacy
    /// `.mouse/.subtle/.fresh` and `.click1...click5` all resolve to real files.
    public var preferredClickIndex: Int {
        switch clickTone {
        case .click1: return 0
        case .click2: return 1
        case .click3: return 2
        case .click4: return 3
        case .click5: return 4
        case .mouse: return 0
        case .subtle: return 2
        case .fresh: return 1
        default: return 4 // select*/switch* keep a clean, distinct click
        }
    }
}

public struct StereoBuffer: Sendable {
    public var l: [Float]
    public var r: [Float]
    public init(l: [Float], r: [Float]) { self.l = l; self.r = r }
}

/// Offline cue renderer. Placement is rounded to the exact 48 kHz sample of each
/// recorded event timestamp; no lookahead, swing or quantisation is applied.
/// Loaded once per process: 86 small WAVs, shared by preview and export.
public enum KeySoundLibraryCache {
    public static let shared = KeySoundLibrary.load()
}

public enum KeySoundEngine {
    public static func render(cues: [SFXCue], library: KeySoundLibrary,
                              router: inout KeyVariationRouter, settings: KeyMixSettings,
                              frames: Int, startFrame: Int64 = 0) -> StereoBuffer {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        guard !library.isEmpty else { return StereoBuffer(l: left, r: right) }
        let keyAmp = Float(pow(10, settings.keyLevelDb / 20))

        func add(_ take: [Float], at t: Double, amplitude: Float) {
            let start = Int((t * AudioIO.fs).rounded()) - Int(startFrame)
            guard start >= -take.count, start < frames else { return }
            for (k, sample) in take.enumerated() {
                let i = start + k
                guard i >= 0, i < frames else { continue }
                let v = sample * amplitude
                left[i] += v
                right[i] += v
            }
        }

        for cue in cues {
            let phase: KeyPhase
            switch cue.kind {
            case .key: phase = .down
            case .keyUp: phase = .up
            case .click: phase = .down
            case .whooshIn, .whooshOut: continue // removed feature: always silence
            }
            if cue.kind == .click {
                guard let pair = router.clickPair(library.clicks.count,
                                                  preferred: settings.preferredClickIndex) else { continue }
                let gain = Float(pow(10, (cue.gainDb + settings.clickLevelDb) / 20))
                if library.clicks.indices.contains(pair.down) {
                    add(library.clicks[pair.down].samples, at: cue.t, amplitude: gain)
                }
                // The release is a quieter, distinct clean click shortly after.
                if library.clicks.indices.contains(pair.up) {
                    add(library.clicks[pair.up].samples, at: cue.t + 0.018,
                        amplitude: gain * 0.55)
                }
                continue
            }
            if phase == .up && !settings.includeReleases { continue }
            let keyClass = KeyClass.forCode(Int(cue.keyCode))
            let takes = library.takes(keyClass, phase)
            guard let variation = router.next(keyClass, phase: phase, key: Int(cue.keyCode),
                                              variantCount: takes.count),
                  takes.indices.contains(variation.variant) else { continue }
            var take = takes[variation.variant].samples
            take = pitchShift(take, cents: variation.pitchCents)
            let level = cue.gainDb + settings.keyLevelDb + variation.gainDb
            add(take, at: cue.t, amplitude: Float(pow(10, level / 20)) * keyAmp)
        }

        // Sample-accurate ceiling, then a gentle lookahead limiter so a burst
        // is controlled rather than hard-clipped.
        var limiter = BusLimiter(ceiling: settings.limiterCeiling)
        limiter.process(left: &left, right: &right)
        return StereoBuffer(l: left, r: right)
    }
}
