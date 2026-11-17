import Foundation

/// Persisted visibility of the floating recorder.
///
/// The bar is opt-in: a fresh install starts with it hidden and the user brings
/// it back with the menu-bar toggle (or the Library's Record button). Keeping
/// this as pure state makes the behaviour testable without opening a window.
enum FloatingBarVisibility {
    static let defaultsKey = "Lumen.floatingBarHidden"
    static let defaultHidden = true

    static func isHidden(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultHidden }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setHidden(_ hidden: Bool, defaults: UserDefaults = .standard) {
        defaults.set(hidden, forKey: defaultsKey)
    }

    @discardableResult
    static func toggle(defaults: UserDefaults = .standard) -> Bool {
        let next = !isHidden(defaults: defaults)
        setHidden(next, defaults: defaults)
        return next
    }

    static func show(defaults: UserDefaults = .standard) { setHidden(false, defaults: defaults) }
    static func hide(defaults: UserDefaults = .standard) { setHidden(true, defaults: defaults) }
}
