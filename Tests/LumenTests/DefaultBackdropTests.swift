import Foundation
import Testing
@testable import LumenProject

@Test func defaultStyleIsSereneLake() {
    let s = Style()
    #expect(s.background == .image)
    #expect(s.backgroundImagePath == "serene-lake.jpg")
    #expect(s.wallpaperBlur == 0, "a wallpaper ships sharp")
}
