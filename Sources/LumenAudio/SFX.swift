import Foundation
import LumenProject

/// Real recorded effects only. No synthetic noise, oscillators or procedural sound generation.
/// Click sfx: new-click.mp3 is the fresh default; mouse-click.mp3 and Subtle-ui-tap-interactions.mp3 kept for backward projects.
/// Per-key typing uses Mechvibes; the recorded tap remains a fallback for missing pack samples.
public struct SFXBank: Sendable {
    private let mouse: [Float], subtle: [Float], zoomIn: [Float], zoomOut: [Float], key: [Float]

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
        zoomIn = load("zoom-in-whoosh.mp3")
        zoomOut = load("zoom-out-whoosh.mp3")
    }

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        switch kind {
        case .click:
            switch clickTone {
            case .fresh: (BundledAudioAssets.freshClick, 0)
            case .subtle: (subtle, 0)
            case .mouse: (mouse, 0)
            }
        case .key: (key, 0)
        case .whooshIn: (zoomIn, 0)
        case .whooshOut: (zoomOut, 0)
        }
    }
}
