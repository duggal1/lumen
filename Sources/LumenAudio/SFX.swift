import Foundation
import LumenProject

/// Inspector audition and offline export share the same selected recording.
public struct SFXBank: Sendable {
    public init() {}

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        let library = KeySoundLibraryCache.shared
        switch kind {
        case .key:
            return (library.takes(.alpha, .down).first?.samples ?? [], 0)
        case .keyUp:
            return (library.takes(.alpha, .up).first?.samples ?? [], 0)
        case .click:
            return (library.clickTake(clickTone)?.samples ?? [], 0)
        case .whooshIn, .whooshOut:
            return ([], 0)
        }
    }
}
