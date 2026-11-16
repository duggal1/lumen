import Foundation
import CoreGraphics

/// A saved capture area, stored in display-relative points with a top-left
/// origin — the same numbers ScreenCaptureKit records and the HUD shows.
struct AreaPreset: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var displayID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var sizeLabel: String { "\(Int(width.rounded())) × \(Int(height.rounded()))" }

    static func make(display: CGDirectDisplayID, rect: CGRect) -> AreaPreset {
        let width = max(rect.width.rounded(), 16)
        let height = max(rect.height.rounded(), 16)
        return AreaPreset(name: "Area \(Int(width)) × \(Int(height))",
                          displayID: display,
                          x: rect.minX.rounded(), y: rect.minY.rounded(),
                          width: width, height: height)
    }

    private static let key = "LumenAreaPresets"

    static func load() -> [AreaPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([AreaPreset].self, from: data) else { return [] }
        return presets
    }

    func save(_ presets: [AreaPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: AreaPreset.key)
    }
}
