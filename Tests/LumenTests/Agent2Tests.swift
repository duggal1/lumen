import Foundation
import Testing
import LumenCore
import LumenAudio
import LumenSpeech
@testable import LumenProject
@testable import LumenDirector
@testable import LumenExport
@testable import LumenUI

// MARK: - helpers

private func tmpDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func srcInfo(duration: Double = 12) -> SourceInfo {
    SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration, backingScale: 1, originX: 0, originY: 0)
}

// MARK: - 1. Crash recovery

@Test func crashRecoveryRebuildsUsableCompositionFromKilledJournal() throws {
    let lib = try tmpDir(); defer { try? FileManager.default.removeItem(at: lib) }
    let bundle = try ProjectBundle.create(named: "Crashed", in: lib)
    try Data().write(to: bundle.micURL)
    let journal = RecordingJournal(source: srcInfo(), fps: 60, mic: true, system: false, webcam: false,
                                   pauseIntervals: [PauseInterval(start: 14, end: 16)],
                                   lastFramePTS: 22, firstFramePTS: 10)
    bundle.writeJournal(journal)
    #expect(bundle.isUnfinished)

    let recovered = try bundle.recoverFromJournal()
    let file = try #require(recovered)
    #expect(abs(file.timeline.compositionDuration - 10) < 0.01, "output shrinks by the 2s paused span")
    #expect(file.meta.source.duration == 12)
    #expect(file.meta.mic != nil)
    // Paused span replays as a cut in project time (host 14..16 - origin 10).
    #expect(file.timeline.timeMap.cuts.contains { $0.start == 4 && $0.end == 6 })
    #expect(!bundle.isUnfinished, "journal is consumed by a successful recovery")
    #expect(try bundle.recoverFromJournal() == nil)
    #expect(abs(try bundle.load().timeline.compositionDuration - 10) < 0.01)
}

@Test func recoveryScannerFindsOnlyUnfinishedBundles() throws {
    let lib = try tmpDir(); defer { try? FileManager.default.removeItem(at: lib) }
    let unfinished = try ProjectBundle.create(named: "Unfinished", in: lib)
    unfinished.writeJournal(RecordingJournal(source: srcInfo(), fps: 60, mic: false, system: false, webcam: false,
                                             lastFramePTS: 5))
    _ = try ProjectBundle.create(named: "Finished", in: lib)
    let found = RecoveryScanner.scan(library: lib)
    #expect(found.map(\.url.lastPathComponent) == ["Unfinished.lumen"])
}

// MARK: - 2. Imported clips (multi-clip timeline)

@Test func importedClipsStackInOutputTimeAndTrim() throws {
    var tl = Timeline(duration: 5)
    let ctx = ReduceContext(playhead: 0, duration: 5)
    let first = TimelineClip(path: "/tmp/first.mov", name: "First", inPoint: 1, duration: 3, start: 5)
    let second = TimelineClip(path: "/tmp/second.mov", name: "Second", inPoint: 0, duration: 2, start: 8)
    _ = try reduce(&tl, .addClip(second), ctx: ctx)
    _ = try reduce(&tl, .addClip(first), ctx: ctx)
    #expect(tl.clips.map(\.name) == ["First", "Second"], "clips sort by output start")
    #expect(tl.compositionDuration == 10)
    #expect(tl.clip(atOutput: 6)?.id == first.id)
    #expect(tl.clipSource(atOutput: 6)?.time == 2)
    #expect(tl.clip(atOutput: 9.5)?.id == second.id)
    #expect(tl.clip(atOutput: 2) == nil, "before the first clip is still the recording")

    _ = try reduce(&tl, .trimClip(second.id, inPoint: 0.5, duration: 1.5), ctx: ctx)
    #expect(tl.clips[1].inPoint == 0.5 && tl.clips[1].duration == 1.5)
    _ = try reduce(&tl, .moveClip(first.id, start: 20), ctx: ctx)
    #expect(tl.clips.first?.id == second.id)

    var threw = false
    do { try reduce(&tl, .addClip(TimelineClip(path: "", duration: 1, start: 0)), ctx: ctx) } catch { threw = true }
    #expect(threw, "a clip with no file path is rejected")
}

// MARK: - 3. Transcript: sentence delete to cut + caption word highlight

@Test func sentenceDeleteProducesCutForWholeSentence() {
    let words = [
        WordToken(text: "Hello", start: 0, end: 0.3), WordToken(text: "world.", start: 0.35, end: 0.8),
        WordToken(text: "Second", start: 1, end: 1.3), WordToken(text: "sentence.", start: 1.35, end: 1.8),
        WordToken(text: "Third", start: 2, end: 2.2), WordToken(text: "one!", start: 2.25, end: 2.5),
    ]
    let transcript = Transcript(words: words, locale: "en-US")
    let sentences = TranscriptOps.sentences(transcript)
    #expect(sentences.count == 3)
    #expect(sentences[1].text == "Second sentence.")
    #expect(sentences[1].wordRange == 2..<4)
    let cut = TranscriptOps.sentenceCut(transcript, index: 1)
    #expect(cut?.start == 0.96 && cut?.end == 1.84 && cut?.origin == .transcript)
    #expect(TranscriptOps.sentenceCut(transcript, index: 3) == nil)
    #expect(TranscriptOps.sentenceCut(Transcript(words: [], locale: "en-US"), index: 0) == nil)
}

@Test func fileTranscriberFailsCleanlyOnMissingFile() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-no-such-mic-\(UUID().uuidString).caf")
    let result = await FileTranscriber.run(url: missing, size: .tiny)
    guard case .failure = result else { Issue.record("missing mic file must fail, not crash"); return }
}

@Test func fileTranscriberHandlesRealSilentAudioWithoutCrashing() async throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("mic.caf")
    let zeros = [Float](repeating: 0, count: 48_000)
    try AudioIO.writeCAF(zeros, zeros, to: url)
    // With no model installed this is a clean .failure; with a model it is a
    // silent transcript. Either way the streaming path runs without crashing
    // and any words it returns are well-formed.
    switch await FileTranscriber.run(url: url, size: .tiny) {
    case .success(let transcript):
        #expect(transcript.words.allSatisfy { $0.end >= $0.start && $0.confidence >= 0 && $0.confidence <= 1 })
    case .failure:
        break
    }
}

@Test func captionsCarryWordsAndWordHighlightToggleDoesNotRewriteText() {
    var timeline = Timeline(duration: 10)
    timeline.captions.enabled = true
    let words = [WordToken(text: "Hello", start: 1, end: 1.3), WordToken(text: "world.", start: 1.35, end: 1.8)]
    func plan() -> [CaptionChunk] {
        CaptionPlanner.plan(words: words, tm: timeline.timeMap, p: timeline.captions,
                            aspect: 16.0 / 9, kindAt: { _ in .screenOnly }, cornerAt: { _ in nil })
    }
    let highlighted = plan()
    #expect(highlighted.count == 1)
    #expect(highlighted[0].text.contains("Hello") && highlighted[0].text.contains("world."))
    timeline.captions.style.wordHighlight = false
    #expect(plan().map(\.text) == highlighted.map(\.text), "the toggle changes rendering, not caption content")
}

// MARK: - 4. Noise reduction (Swift gate is the vendored fallback; RNNoise optional)

private func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }

@Test func spectralGateKeepsVoiceAndQuietsQuietTail() {
    let fs = 48_000
    let phrase = (0..<fs).map { i -> Float in
        let amp: Double = i < fs / 2 ? 0.1 : 0.001
        return Float(amp * sin(Double(i) * 2 * .pi * 440 / Double(fs)))
    }
    let cleaned = SpectralGate().process(phrase)
    let firstHalf = Array(cleaned[0..<(fs / 2)])
    let secondHalf = Array(cleaned[(fs / 2)...])
    #expect(energy(firstHalf) > energy(Array(phrase[0..<(fs / 2)])) * 0.8, "voice is preserved")
    #expect(energy(secondHalf) < energy(Array(phrase[(fs / 2)...])) * 0.2, "quiet tail is gated down")
    let quiet = (0..<fs).map { Float(0.001 * sin(Double($0) * 2 * .pi * 440 / Double(fs))) }
    #expect(energy(defaultDenoiser.process(quiet)) < energy(quiet) * 0.2)
}

// MARK: - 5. 8K / 120 fps honesty

@Test func eightK120ExportPresetIsRealAndH264StaysGated() throws {
    let source = SourceInfo(width: 3840, height: 2160, fps: 60, duration: 5, backingScale: 2, originX: 0, originY: 0)
    var options = ExportSettings()
    options.resolution = .ultraHD8K
    options.frameRate = .f120
    options.codec = .hevc
    let (w, h) = options.dimensions(source: source, aspect: 16.0 / 9)
    #expect((w, h) == (7680, 4320))
    let preset = options.preset(source: source, aspect: 16.0 / 9)
    #expect(preset.fps == 120 && preset.height == 4320 && preset.width(aspect: 16.0 / 9) == 7680)
    #expect(preset.name == "7680x4320@120-hevc")
    // The hardware-level gate proves the combination is plausible, and proves
    // H.264 8K120 is honestly refused instead of silently downscaled.
    #expect(ExportCapabilityMatrix.withinLevelLimits(.hevc, 7680, 4320, 120))
    #expect(!ExportCapabilityMatrix.withinLevelLimits(.h264, 7680, 4320, 120))
    #expect(ExportPresets.parse("8k120-hevc")?.height == 4320)
    #expect(ExportPresets.parse("8k120-hevc")?.fps == 120)
    #expect(ExportPresets.parse("4k60-hevc") != nil)
}

// MARK: - 6. Shareable package (local artifact; no hosted web player claims)

@Test func sharePackageRoundTripsAndNeverOverwrites() throws {
    let lib = try tmpDir(); defer { try? FileManager.default.removeItem(at: lib) }
    let dest = try tmpDir(); defer { try? FileManager.default.removeItem(at: dest) }
    let bundle = try ProjectBundle.create(named: "Demo", in: lib)
    let file = ProjectFile(meta: ProjectMeta(name: "Demo", source: srcInfo(duration: 2), clock: RecordingClock()),
                           timeline: Timeline(duration: 2))
    try bundle.save(file)
    try Data("fake-media".utf8).write(to: bundle.screenURL)
    let package = try bundle.exportSharePackage(to: dest.appendingPathComponent("Demo.lumenshare"))
    #expect(FileManager.default.fileExists(atPath: package.path))
    #expect(bundle.shareLink.hasPrefix("lumen://open?path="))

    let installed = try ProjectBundle.installSharePackage(package, into: dest)
    do {
        let loaded = try installed.load()
        #expect(abs(loaded.timeline.compositionDuration - 2) < 0.01)
    } catch {
        #expect(false, "installed bundle must load: \(error)")
    }
    #expect(FileManager.default.fileExists(atPath: installed.screenURL.path))
    let again = try ProjectBundle.installSharePackage(package, into: dest)
    #expect(again.url != installed.url, "installing twice uniques the bundle name")
}

// MARK: - 7. Cursor relink sidecar

@Test func cursorRelinkSidecarRoundTripsAndValidatesReplacement() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let main = dir.appendingPathComponent("Demo.mp4")
    let cursor = dir.appendingPathComponent("Demo.cursor.mov")
    #expect(CursorRelink.sidecarURL(mainExport: main).lastPathComponent == "Demo.cursor-relink.json")
    let url = try CursorRelink.writeSidecar(mainExport: main, cursorFile: cursor,
                                            duration: 12.5, fps: 60, width: 1920, height: 1080)
    let sidecar = try CursorRelink.read(from: url)
    #expect(sidecar.screenFile == "Demo.mp4" && sidecar.cursorFile == "Demo.cursor.mov")
    #expect(sidecar.duration == 12.5 && sidecar.fps == 60 && sidecar.width == 1920 && sidecar.height == 1080)
    #expect(CursorRelink.validate(sidecar, screenDuration: 12.5, screenFPS: 60).isEmpty)
    #expect(!CursorRelink.validate(sidecar, screenDuration: 12.5, screenFPS: 30).isEmpty)
    #expect(!CursorRelink.validate(sidecar, screenDuration: 13, screenFPS: 60).isEmpty)
    let steps = CursorRelink.instructions(sidecar).lowercased()
    #expect(steps.contains("cursor") && steps.contains("screen"))
}

// MARK: - 8. Clipboard preset contract

@Test func clipboardPresetIs1080pH264ReadyForPasteboard() {
    var quick = ExportSettings()
    quick.kind = .video; quick.resolution = .p1080; quick.codec = .h264
    quick.container = .mp4; quick.quality = .high; quick.filename = "Lumen clip"
    let source = SourceInfo(width: 3024, height: 1964, fps: 60, duration: 10, backingScale: 2, originX: 0, originY: 0)
    let preset = quick.preset(source: source, aspect: 16.0 / 9)
    #expect(preset.height == 1080 && preset.width(aspect: 16.0 / 9) == 1920 && preset.fps == 60)
    #expect(preset.codec == .h264 && quick.fileExtension == "mp4")
    #expect(quick.destinationURL()?.lastPathComponent == "Lumen clip.mp4")
    #expect(ExportCapabilityMatrix.withinLevelLimits(.h264, 1920, 1080, 60), "pasteboard preset must actually encode")
}

// MARK: - 9. Highlight tool + manual text (TextBlocks)

@Test func highlightWindowIsActiveOnlyInRangeAndRestylable() throws {
    var tl = Timeline(duration: 5)
    let highlight = Highlight(start: 1, end: 2, x: 100, y: 100, w: 200, h: 100, style: .dim)
    tl.overlays.highlights = [highlight]
    func frames(at t: Double) -> [HighlightFrame] {
        Emphasis.evaluate(overlays: tl.overlays, autoMasks: [], sourceTime: t,
                          cursor: SIMD2<Float>(960, 540), sourceSize: SIMD2<Double>(1920, 1080)).highlights
    }
    #expect(frames(at: 0.5).isEmpty)
    #expect(frames(at: 1.5).count == 1)
    #expect(frames(at: 2.5).isEmpty)
    _ = try reduce(&tl, .setHighlightStyle(highlight.id, .glow), ctx: ReduceContext(playhead: 0, duration: 5))
    #expect(frames(at: 1.5).first?.style == .glow)
}

@Test func textBlocksBecomeTitleFramesWithWindow() {
    var tl = Timeline(duration: 5)
    tl.overlays.texts = [TextBlock(start: 1, end: 2, text: "TITLE", x: 0.5, y: 0.5, size: 0.14)]
    func texts(at t: Double) -> [TextFrame] {
        Emphasis.evaluate(overlays: tl.overlays, autoMasks: [], sourceTime: t,
                          cursor: SIMD2<Float>(960, 540), sourceSize: SIMD2<Double>(1920, 1080)).texts
    }
    #expect(texts(at: 0.5).isEmpty)
    #expect(texts(at: 1.5).first?.text == "TITLE")
}
