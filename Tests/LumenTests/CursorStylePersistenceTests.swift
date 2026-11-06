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
