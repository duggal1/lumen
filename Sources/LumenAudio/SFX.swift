import Foundation
import LumenProject

/// Real recorded effects only. The old mp3 click set and the Mechvibes fallback
/// are gone: all sfx now come from the CC0 one-shot library built by
/// `scripts/fetch_sounds.py`. Zoom whooshes remain removed (stale cues render
/// silence). Key-down and key-up each resolve to their own recorded sample.
public struct SFXBank: Sendable {
    public init() {}

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        let library = KeySoundLibraryCache.shared
        switch kind {
        case .key:
            return (library.down[.alpha]?.first?.samples ?? [], 0)
        case .keyUp:
            return (library.up[.alpha]?.first?.samples ?? [], 0)
        case .click:
            if ClickSound.studioCollection.contains(clickTone) {
                return (library.studioClicks[clickTone]?.samples ?? [], 0)
            }
            var settings = KeyMixSettings()
            settings.clickTone = clickTone
            let index = settings.preferredClickIndex
            return (library.clicks.indices.contains(index) ? library.clicks[index].samples : [], 0)
        case .whooshIn, .whooshOut:
            return ([], 0)
        }
    }
}
