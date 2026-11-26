import Foundation
import Testing
@testable import LumenProject

@Test func defaultStyleUsesBundledMonetWallpaper() {
    let s = Style()
    #expect(s.background == .image)
    #expect(s.backgroundImagePath == "paintings/claude-monet/claude-monet_water-lilies-agapanthus_cma-136510.webp")
    #expect(s.wallpaperBlur == 0, "a wallpaper ships sharp")
}
