import Foundation
import Testing
import LumenProject
import LumenExport

private func caption(_ start: Double, _ end: Double, _ text: String) -> CaptionChunk {
    CaptionChunk(start: start, end: end,
                 lines: [[CaptionWord(text: text, start: start, end: end)]], y: 0.8)
}

@Test func captionSidecarsPreserveOutputTimingAndUnicode() throws {
    let chunks = [caption(1.2345, 2.5, "नमस्ते world"), caption(4.0, 5.0, "Edited caption.")]
    let srt = try CaptionSidecars.serialize(chunks: chunks, duration: 5, format: .srt)
    let vtt = try CaptionSidecars.serialize(chunks: chunks, duration: 5, format: .vtt)
    #expect(srt.cueCount == 2)
    #expect(srt.text == "1\n00:00:01,235 --> 00:00:02,500\nनमस्ते world\n\n2\n00:00:04,000 --> 00:00:05,000\nEdited caption.\n")
    #expect(vtt.text == "WEBVTT\n\n00:00:01.235 --> 00:00:02.500\nनमस्ते world\n\n00:00:04.000 --> 00:00:05.000\nEdited caption.\n")
}

@Test func captionSidecarsClampDiscardAndPreventCueInjection() throws {
    let chunks = [caption(1, 2.5, "A\n\n00:00:00.000 --> <tag>&"),
                  caption(-1, 0.5, "Before"), caption(1, 2.5, "Duplicate"),
                  caption(2.4, 9, "After"), caption(.nan, 3, "Invalid"),
                  caption(4, 4, "Zero")]
    let delivery = try CaptionSidecars.serialize(chunks: chunks, duration: 4, format: .vtt)
    #expect(delivery.cueCount == 3)
    #expect(delivery.text.contains("00:00:00.000 --> 00:00:00.500\nBefore"))
    #expect(delivery.text.contains("A 00:00:00.000 --&gt; &lt;tag&gt;&amp;"))
    #expect(delivery.text.contains("00:00:02.500 --> 00:00:04.000\nAfter"))
    #expect(!delivery.text.contains("Duplicate"))
    #expect(!delivery.text.contains("Invalid"))
    #expect(!delivery.text.contains("Zero"))
}

@Test func captionSidecarRequiresEnabledAndDerivedCaptions() {
    let timeline = Timeline(duration: 1)
    #expect(throws: CaptionSidecarError.self) {
        _ = try CaptionSidecars.serialize(timeline: timeline, format: .srt)
    }
    #expect(throws: CaptionSidecarError.self) {
        _ = try CaptionSidecars.serialize(chunks: [], duration: 1, format: .srt)
    }
}

@Test func captionSidecarPublicationPreservesPriorFileWithoutOverwrite() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("captions.srt")
    let prior = Data("original".utf8)
    try prior.write(to: url)
    let delivery = try CaptionSidecars.serialize(chunks: [caption(0, 1, "Hello")], duration: 1, format: .srt)
    #expect(throws: CaptionSidecarError.self) { try CaptionSidecars.write(delivery, format: .srt, to: url) }
    #expect(try Data(contentsOf: url) == prior)
    try CaptionSidecars.write(delivery, format: .srt, to: url, overwrite: true)
    #expect(try String(contentsOf: url, encoding: .utf8) == delivery.text)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["captions.srt"])
}
