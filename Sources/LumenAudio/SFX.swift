import Foundation
import LumenProject

/// Inspector audition and offline export share the same selected effect.
public struct SFXBank: Sendable {
    public init() {}

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        let library = KeySoundLibraryCache.shared
        switch kind {
        case .key:
            return (library.takes(keyCode: 0, phase: .down).first?.samples ?? [], 0)
        case .keyUp:
            return (library.takes(keyCode: 0, phase: .up).first?.samples ?? [], 0)
        case .click:
            return (library.clickTake(clickTone)?.samples ?? [], 0)
        case .whooshIn, .whooshOut:
            return ([], 0)
        }
    }
}
