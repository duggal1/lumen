import Foundation
import AVFoundation
import CryptoKit
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
    public var studioClicks: [ClickSound: KeyTake] = [:]
    /// Old catalogs may label a down strike as a release. Keep their inventory
    /// readable for migration, but do not play an unverified release.
    public var unverifiedReleaseIDs: Set<String> = []
    private var usesNamedClickSlots = false
    private static let clickNames = ["mouse-click-2"]
    /// Production uses an actual Mechvibes timing map, not a guessed key class.
    public var exactDown: [Int: KeyTake] = [:]
    public var exactUp: [Int: KeyTake] = [:]
    public var usesExactKeys = false

    public func takes(keyCode: Int, phase: KeyPhase) -> [KeyTake] {
        if usesExactKeys {
            let take = (phase == .down ? exactDown : exactUp)[keyCode]
            return take.map { [$0] } ?? []
        }
        return takes(KeyClass.forCode(keyCode), phase)
    }

    /// Optional personal pack is outside the checkout and never redistributed.
    /// Missing/invalid private packs leave the licensed bundled pack in use.
    public static func loadProduction() -> KeySoundLibrary {
        var library = load()
        let fm = FileManager.default
        let user = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lumen/TypingPacks/orange-deluxe", isDirectory: true)
        let candidates = [user, TypingPackLoader.dir(for: TypingPackLoader.defaultPackID)].compactMap { $0 }
        for dir in candidates {
            let down = TypingPackLoader.buffers(in: dir)
            guard !down.isEmpty else { continue }
            func convert(_ source: [Int: AVAudioPCMBuffer], phase: KeyPhase) -> [Int: KeyTake] {
                var result: [Int: KeyTake] = [:]
                for (code, buffer) in source {
                    guard let channels = buffer.floatChannelData, buffer.format.channelCount > 0,
                          buffer.frameLength > 0 else { continue }
                    let count = Int(buffer.frameLength)
                    var mono = [Float](repeating: 0, count: count)
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for i in 0..<count { mono[i] += channels[channel][i] / Float(buffer.format.channelCount) }
                    }
                    guard let pcm = try? AudioIO.resampleMono(mono, from: buffer.format.sampleRate, to: AudioIO.fs),
                          !pcm.isEmpty, pcm.allSatisfy(\.isFinite) else { continue }
                    result[code] = KeyTake(id: "\(dir.lastPathComponent)/\(code)/\(phase.rawValue)", samples: pcm)
                }
                return result
            }
            let exactDown = convert(down, phase: .down)
            // A corrupt or partial local pack must not replace a usable
            // keyboard. Require the actual letter keys and basic editing keys.
            let required = Set(TypingPackLoader.macToMechvibes.compactMap { code, name in
                name.hasPrefix("Key") || ["Space", "Enter", "Backspace"].contains(name) ? code : nil
            })
            guard required.isSubset(of: Set(exactDown.keys)) else { continue }
            library.exactDown = exactDown
            library.exactUp = convert(TypingPackLoader.releaseBuffers(in: dir), phase: .up)
            // Keep an explicit private pack. Replace mapped default presses
            // only; unrecorded extended keys retain the licensed legacy sounds.
            // Classic contains no independently verified key-up recordings.
            if dir.lastPathComponent == TypingPackLoader.defaultPackID {
                let classic = convert(TypingPackLoader.classicPressBuffers(), phase: .down)
                if classic.count == 61, required.isSubset(of: Set(classic.keys)) {
                    for (code, take) in classic {
                        library.exactDown[code] = KeyTake(id: "sound-library-classic/\(code)/down", samples: take.samples)
                        library.exactUp.removeValue(forKey: code)
                    }
                }
            }
            break
        }
        // Missing key or phase is silence, never a random recording or synth.
        library.usesExactKeys = true
        return library
    }

    public var identity: String {
        var hash = SHA256()
        for (phase, entries) in [("down", exactDown), ("up", exactUp)] {
            for code in entries.keys.sorted() {
                guard let take = entries[code] else { continue }
                hash.update(data: Data("\(phase)|\(code)|\(take.id)|\(take.samples.count)".utf8))
                take.samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
            }
        }
        for tone in ClickSound.activeCollection {
            if let take = clickTake(tone) {
                hash.update(data: Data("\(tone.rawValue)|\(take.id)|\(take.samples.count)".utf8))
                take.samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var isEmpty: Bool {
        let noKeys = usesExactKeys ? exactDown.isEmpty && exactUp.isEmpty : down.isEmpty && up.isEmpty
        return noKeys && clicks.isEmpty && studioClicks.isEmpty
    }

    public init() {}

    public static func load(root: URL? = nil) -> KeySoundLibrary {
        var lib = KeySoundLibrary()
        lib.usesNamedClickSlots = true
        let resolver: (String) -> URL? = root.map { rootURL in
            { (name: String) -> URL? in
                let url = rootURL.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } ?? { (name: String) -> URL? in BundledAudioAssets.sound(named: name) }
        struct Catalog: Decodable {
            struct Entry: Decodable {
                let path: String
                let phase: String?
                let releaseEvidence: String?
                let sha256: String?
            }
            let files: [Entry]
        }
        let catalog = resolver("manifest.json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
        // A release is playable only when the catalog records where its separate
        // transient came from. `separate-recorded-release` is a reviewed human
        // assertion; `detected-secondary-transient` is the measured detector
        // evidence written by scripts/rebuild_recorded_sounds.py. A bare `up`
        // label with no evidence is a down stroke in disguise and stays silent.
        let releaseEvidenceTokens: Set<String> = [
            "separate-recorded-release", "detected-secondary-transient",
        ]
        var verifiedReleases: [String: String] = [:]
        for entry in catalog?.files ?? [] where entry.phase == "up" &&
            entry.releaseEvidence.map(releaseEvidenceTokens.contains) == true {
            if let hash = entry.sha256, hash.count == 64 { verifiedReleases[entry.path] = hash }
        }
        func releaseVerified(_ name: String, _ url: URL) -> Bool {
            guard let expected = verifiedReleases[name],
                  let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return actual == expected.lowercased()
        }
        for keyClass in KeyClass.allCases where keyClass != .click {
            for phase in [KeyPhase.down, .up] {
                var takes: [KeyTake] = []
                for index in 1...8 {
                    let name = "typing/\(keyClass.rawValue)/\(keyClass.rawValue)-\(phase.rawValue)-\(index).wav"
                    guard let url = resolver(name), let pcm = try? AudioIO.readMono(url),
                          !pcm.isEmpty, pcm.allSatisfy(\.isFinite) else { continue }
                    takes.append(KeyTake(id: name, samples: pcm))
                    if phase == .up, !releaseVerified(name, url) {
                        lib.unverifiedReleaseIDs.insert(name)
                    }
                }
                if phase == .down { lib.down[keyClass] = takes } else { lib.up[keyClass] = takes }
            }
        }
        for name in clickNames {
            guard let url = resolver("clicks/\(name).wav"), let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { continue }
            lib.clicks.append(KeyTake(id: name, samples: pcm))
        }
        for sound in ClickSound.studioCollection {
            guard let url = BundledAudioAssets.effect(named: sound.assetPath),
                  let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { continue }
            guard pcm.allSatisfy(\.isFinite), pcm.contains(where: { abs($0) > 0.0001 }) else { continue }
            // Explicitly authored retro UI tones: preserve their baked gain.
            lib.studioClicks[sound] = KeyTake(id: sound.rawValue, samples: pcm)
        }
        return lib
    }

    public func takes(_ keyClass: KeyClass, _ phase: KeyPhase) -> [KeyTake] {
        if phase == .down { return down[keyClass] ?? [] }
        return (up[keyClass] ?? []).filter { !unverifiedReleaseIDs.contains($0.id) }
    }

    /// The selected tone is the recording, not a hint to a random router.
    /// Curated legacy tones remain available until a verified replacement
    /// catalog can migrate their persisted IDs.
    public func clickTake(_ tone: ClickSound) -> KeyTake? {
        if usesNamedClickSlots {
            let active = tone.activeTone
            if active != .fresh { return studioClicks[active] }
            return clicks.first { $0.id == "mouse-click-2" }
        }
        if let take = studioClicks[tone] { return take }
        var settings = KeyMixSettings()
        settings.clickTone = tone
        let index = settings.preferredClickIndex
        return clicks.indices.contains(index) ? clicks[index] : nil
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
    guard cents.isFinite, abs(cents) > 0.01, x.count > 2 else { return x }
    // Bound the public helper as well as the production variation router.
    let ratio = pow(2.0, min(max(cents, -1200), 1200) / 1200.0)
    let count = max(1, Int((Double(x.count) / ratio).rounded()))
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let pos = Double(i) * ratio
        let base = Int(pos.rounded(.down))
        guard base < x.count else { continue }
        let f = Float(pos - Double(base))
        // The former interior-only guard erased the first sample and the
        // last two samples on every shifted recording. That is especially
        // destructive to short clicks and can introduce a delayed attack.
        // Replicate the leading boundary and zero-extend the recorded tail.
        let p0 = x[max(base - 1, 0)], p1 = x[base]
        let p2 = base + 1 < x.count ? x[base + 1] : 0
        let p3 = base + 2 < x.count ? x[base + 2] : 0
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
        self.ceiling = max(0.05, min(1, ceiling.isFinite ? ceiling : 0.89))
        self.lookahead = max(0, min(lookahead, 48_000))
        self.release = release.isFinite ? min(max(release, 0), 1) : 0.0009
    }

    public func process(left: inout [Float], right: inout [Float]) {
        let n = min(left.count, right.count)
        guard n > 0 else { return }
        let cap = ceiling.isFinite ? min(max(ceiling, 0.05), 1) : 0.89
        let span = min(max(lookahead, 0), min(n - 1, 48_000))
        let recovery = release.isFinite ? min(max(release, 0), 1) : 0.0009
        // Circular monotonic deque. O(n) work, O(lookahead) scratch. Each
        // window includes the current sample and exactly span future samples.
        let capacity = span + 2
        var indices = [Int](repeating: 0, count: capacity)
        var peaks = [Float](repeating: 0, count: capacity)
        var head = 0, count = 0, inserted = 0
        var previousGain: Float = 1
        for j in 0..<n {
            while count > 0, indices[head] < j {
                head = (head + 1) % capacity; count -= 1
            }
            let end = min(n - 1, j + span)
            while inserted <= end {
                if !left[inserted].isFinite { left[inserted] = 0 }
                if !right[inserted].isFinite { right[inserted] = 0 }
                let peak = max(abs(left[inserted]), abs(right[inserted]))
                while count > 0, peaks[(head + count - 1) % capacity] <= peak { count -= 1 }
                let tail = (head + count) % capacity
                indices[tail] = inserted; peaks[tail] = peak
                count += 1; inserted += 1
            }
            let env = count > 0 ? peaks[head] : 0
            let required: Float = env > cap ? cap / env : 1
            // Never release above the safe gain while a loud sample remains
            // in the window. The two channels share the same gain envelope.
            let gain = min(required, previousGain + (1 - previousGain) * recovery)
            previousGain = gain
            left[j] *= gain; right[j] *= gain
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
    public static let shared = KeySoundLibrary.loadProduction()
    public static let identity = shared.identity
}

public enum KeySoundEngine {
    public static func render(cues: [SFXCue], library: KeySoundLibrary,
                              router: inout KeyVariationRouter, settings: KeyMixSettings,
                              frames: Int, startFrame: Int64 = 0) -> StereoBuffer {
        guard frames > 0 else { return StereoBuffer(l: [], r: []) }
        // A preview window gets a small limiter warm-up and lookahead. It
        // selects from the entire cue sequence to preserve variant identity.
        // The normal export starts at zero and needs no extra allocation.
        let prefix = Int(min(max(startFrame, 0), 48_000))
        let suffix = prefix > 0 ? 144 : 0
        let renderStart = startFrame - Int64(prefix)
        guard frames <= Int.max - prefix - suffix else { return StereoBuffer(l: [], r: []) }
        let total = frames + prefix + suffix
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        guard !library.isEmpty else {
            return StereoBuffer(l: [Float](repeating: 0, count: frames), r: [Float](repeating: 0, count: frames))
        }

        func gain(_ db: Double) -> Float {
            guard db.isFinite else { return 0 }
            return Float(pow(10, min(max(db, -96), 24) / 20))
        }
        func add(_ take: [Float], at t: Double, amplitude: Float) {
            let relative = t * AudioIO.fs - Double(renderStart)
            guard relative.isFinite, relative >= -Double(take.count), relative < Double(total),
                  amplitude.isFinite, amplitude > 0 else { return }
            let start = Int(relative.rounded())
            let first = max(0, -start), end = min(take.count, total - start)
            guard first < end else { return }
            for k in first..<end where take[k].isFinite {
                let v = take[k] * amplitude
                left[start + k] += v
                right[start + k] += v
            }
        }

        for cue in cues {
            guard cue.t.isFinite, cue.gainDb.isFinite else { continue }
            let phase: KeyPhase
            switch cue.kind {
            case .key: phase = cue.isKeyRelease ? .up : .down
            case .keyUp: phase = .up
            case .click: phase = .down
            case .whooshIn, .whooshOut: continue // removed feature: always silence
            }
            if cue.kind == .click {
                guard let take = library.clickTake(settings.clickTone) else { continue }
                add(take.samples, at: cue.t, amplitude: gain(cue.gainDb + settings.clickLevelDb))
                continue
            }
            if phase == .up && !settings.includeReleases { continue }
            let keyClass = KeyClass.forCode(Int(cue.keyCode))
            let takes = library.takes(keyCode: Int(cue.keyCode), phase: phase)
            if library.usesExactKeys {
                if let take = takes.first {
                    add(take.samples, at: cue.t, amplitude: gain(cue.gainDb + settings.keyLevelDb))
                }
                continue
            }
            guard let variation = router.next(keyClass, phase: phase, key: Int(cue.keyCode),
                                              variantCount: takes.count),
                  takes.indices.contains(variation.variant) else { continue }
            let take = takes[variation.variant].samples
            // Advance the deterministic router for out-of-window events, but
            // don't pitch-resample their audio just to throw it away.
            let relative = cue.t * AudioIO.fs - Double(renderStart)
            guard relative >= -Double(take.count) * 1.03, relative < Double(total) else { continue }
            let shifted = pitchShift(take, cents: variation.pitchCents)
            let level = cue.gainDb + settings.keyLevelDb + variation.gainDb
            add(shifted, at: cue.t, amplitude: gain(level))
        }

        // Sample-accurate ceiling, then a gentle lookahead limiter so a burst
        // is controlled rather than hard-clipped.
        let limiter = BusLimiter(ceiling: settings.limiterCeiling)
        limiter.process(left: &left, right: &right)
        if prefix > 0 {
            return StereoBuffer(l: Array(left[prefix..<(prefix + frames)]),
                                r: Array(right[prefix..<(prefix + frames)]))
        }
        return StereoBuffer(l: left, r: right)
    }
}
