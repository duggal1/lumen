import Foundation
import LumenProject

/// The renderer, waveform and audition use one immutable decoded sample bank.
/// No network access, generated tones or per-click decoding.
public struct SFXBank: Sendable {
    private static func load(_ name: String) -> [Float] {
        guard let url = BundledAudioAssets.effect(named: name),
              let pcm = try? AudioIO.readMono(url), !pcm.isEmpty,
              pcm.allSatisfy(\.isFinite) else { return [] }
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0.0001 ? pcm.map { $0 / peak } : []
    }

    private static let clicks: [ClickSound: [Float]] = {
        Dictionary(uniqueKeysWithValues: ClickSound.allCases.map { ($0, load($0.assetPath)) })
    }()
    private static let key = load("typing/mechvibes-default/fallback.mp3")

    public init() {}

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        switch kind {
        case .click: (Self.clicks[clickTone] ?? [], 0)
        case .key: (Self.key, 0)
        case .whooshIn, .whooshOut: ([], 0)
        }
    }
}
