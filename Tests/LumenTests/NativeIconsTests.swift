import Foundation
import Testing
@testable import LumenUI

/// Every inspector dropdown icon must be a real macOS SF Symbol (no circle fallback).
@Test func inspectorIconsAreNativeSF() {
    let symbols = [
        "rectangle", "square", "display", "photo", "sparkles", "minus", "eye",
        "mic", "mic.fill", "waveform.and.mic", "eye.slash", "square.grid.3x3",
        "rectangle.fill", "circle.lefthalf.filled", "aspectratio", "rectangle.portrait",
        "rectangle.righthalf.inset.filled", "chevron.down", "rectangle.split.2x1",
        "rectangle.3.group", "video", "person", "highlighter", "captions.bubble",
        "arrow.down", "arrow.up", "arrow.right",
    ]
    for s in symbols {
        #expect(IconSymbols.exists(s), "\(s) must exist as native SF Symbol")
    }
}

/// New-recording and export menus use native macOS marks for every prefix
/// slot: no `signal.*`, no glyph in a circle, no solid square standing in for
/// a resolution.
@Test func recordingIconsAreNativeSF() {
    let symbols = [
        "rectangle.ratio.16.to.9", "4k.tv", "tv", "tv.fill", "display", "macwindow",
        "dial.low", "dial.medium", "dial.high", "dial.high.fill",
        "waveform.path", "waveform.path.ecg", "opticaldisc",
        "airpods.gen3", "headphones", "iphone", "laptopcomputer", "waveform",
        "cable.connector", "record.circle", "speedometer", "camera.aperture",
        "timeline.selection", "photo.stack", "slider.horizontal.3", "checkmark",
    ]
    for s in symbols {
        #expect(IconSymbols.exists(s), "\(s) must exist as native SF Symbol")
    }
}
