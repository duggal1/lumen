import Foundation
import Testing
import LumenProject

@Test func cursorClickArtworkSettingsSurviveProjectRoundTrip() throws {
    var style = CursorStyle()
    style.pack = .pro
    style.clickEffect = .burst
    style.clickDuration = 0.72
    style.clickColor = RGBA(0x12ABEF)
    let restored = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
    #expect(restored.pack == .pro)
    #expect(restored.clickEffect == .burst)
    #expect(abs(restored.clickDuration - 0.72) < 0.00001)
    #expect(restored.clickColor == RGBA(0x12ABEF))
}

@Test func canvasColorsAndCellSurviveProjectRoundTrip() throws {
    var style = Style()
    style.background = .solid
    style.colors = [RGBA(0x0A0A0A), RGBA(0xFF6A00)]
    style.ditherCell = 7
    style.ditherDensity = 0.42
    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
    #expect(restored.colors == style.colors)
    #expect(restored.ditherCell == 7)
    #expect(restored.ditherDensity == 0.42)
    // Legacy JSON without ditherCell must decode to the current default (4),
    // not silently change the saved look on reload.
    let legacy = try JSONSerialization.data(withJSONObject: ["background": "solid", "colors": [["r": 0, "g": 0, "b": 0, "a": 1]]])
    let decoded = try JSONDecoder().decode(Style.self, from: legacy)
    #expect(decoded.ditherCell == Style().ditherCell)
}
