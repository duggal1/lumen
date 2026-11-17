import Foundation
import LumenProject

/// Real recorded effects only. No synthetic noise, oscillators or procedural sound generation.
/// Click sfx: new-click.mp3 is the fresh default; mouse-click.mp3 and Subtle-ui-tap-interactions.mp3
/// are kept for backward projects. Per-key typing uses the bundled Mechvibes pack; the recorded
/// tap is only a fallback for a missing pack sample.
/// Zoom whooshes are gone: there is no whoosh asset to load and no whoosh is ever rendered.
public struct SFXBank: Sendable {
    private let mouse: [Float], subtle: [Float], key: [Float]

    private static let touches: [ClickSound: [Float]] = {
        var sounds: [ClickSound: [Float]] = [:]
        for tone in ClickSound.allCases where tone != .mouse && tone != .subtle && tone != .fresh {
            guard let url = BundledAudioAssets.effect(named: "touches/\(tone.rawValue).wav"),
                  let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { continue }
            let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
            if peak > 0.0001 { sounds[tone] = pcm.map { $0 / peak } }
        }
        return sounds
    }()

    public init() {
        func load(_ name: String) -> [Float] {
            guard let url = BundledAudioAssets.effect(named: name),
                  let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { return [] }
            let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
            return peak > 0.0001 ? pcm.map { $0 * (1.0 / peak) } : []
        }
        key = load("typing/mechvibes-default/fallback.mp3")
        mouse = load("mouse-click.mp3")
        subtle = load("Subtle-ui-tap-interactions.mp3")
    }

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        switch kind {
        case .click:
            switch clickTone {
            case .fresh: (BundledAudioAssets.freshClick, 0)
            case .subtle: (subtle, 0)
            case .mouse: (mouse, 0)
            default: (Self.touches[clickTone] ?? [], 0)
            }
        case .key: (key, 0)
        // Zoom whooshes were deleted. A stale cue from an old project renders silence,
        // so no whoosh can ever reach the mix even if the source data still mentions one.
        case .whooshIn, .whooshOut: ([], 0)
        }
    }
}
