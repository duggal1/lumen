import Foundation
import LumenProject

/// Real recorded effects only. No synthetic noise, oscillators or procedural sound generation.
public struct SFXBank: Sendable {
    private let mouse: [Float], subtle: [Float], key: [Float], zoomIn: [Float], zoomOut: [Float]

    public init() {
        func load(_ name: String) -> [Float] {
            guard let url = BundledAudioAssets.effect(named: name),
                  let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { return [] }
            // Peak leveling is applied once, never synthesized on each cue.
            let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
            return peak > 0.0001 ? pcm.map { $0 * (0.9 / peak) } : []
        }
        mouse = load("mouse-click.mp3")
        subtle = load("Subtle-ui-tap-interactions.mp3")
        key = load("single-keyboard-tap.mp3")
        zoomIn = load("zoom-in-whoosh.mp3")
        zoomOut = load("zoom-out-whoosh.mp3")
    }

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        switch kind {
        case .click: (clickTone == .subtle ? subtle : mouse, 0)
        case .key: (key, 0)
        case .whooshIn: (zoomIn, 0)
        case .whooshOut: (zoomOut, 0)
        }
    }
}
