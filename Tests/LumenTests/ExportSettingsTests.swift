import Foundation
import Testing
import LumenProject
import LumenExport
@testable import LumenUI

@Test func exportOptionsApplyToRealEncoderPreset() {
    let source = SourceInfo(width: 2560, height: 1440, fps: 60, duration: 10,
                            backingScale: 2, originX: -1440, originY: 0)
    var options = ExportSettings()
    options.container = .mov
    options.codec = .h264
    options.quality = .max
    options.resolution = .custom
    options.customWidth = 1280
    options.customHeight = 720
    options.frameRate = .f24
    options.includeAudio = false
    options.filename = "Screen demo"
    options.folder = "/tmp"

    let preset = options.preset(source: source, aspect: 16.0 / 9)
    #expect(preset.width(aspect: 16.0 / 9) == 1280)
    #expect(preset.height == 720)
    #expect(preset.fps == 24)
    #expect(preset.codec == .h264)
    #expect(preset.bpp == 0.12)
    #expect(options.destinationURL()?.path == "/tmp/Screen demo.mov")
    #expect(options.estimatedBytes(source: source, aspect: 16.0 / 9, outputDuration: 10) > 0)
}

@Test func exportResolutionPresetsPreserveSourceAndCustomDimensions() {
    let src = SourceInfo(width: 3024, height: 1964, fps: 59.94, duration: 10,
                         backingScale: 2, originX: 0, originY: 0)
    var options = ExportSettings()
    options.resolution = .source
    #expect(options.dimensions(source: src, aspect: 16.0 / 9).1 == 1964)
    #expect(options.frameRate.fps(source: src.fps) == 60)
    options.resolution = .ultraHD
    #expect(options.dimensions(source: src, aspect: 16.0 / 9) == (3840, 2160))
    options.filename = "sample.mp4"
    options.container = .mov
    #expect(options.destinationURL()?.lastPathComponent == "sample.mov")
}

@Test func exportNameRejectsInvalidFilesystemEntries() {
    var options = ExportSettings()
    for value in ["", ".", "..", "unsafe/name", "foo:bar"] {
        options.filename = value
        #expect(options.destinationURL() == nil)
    }
}
