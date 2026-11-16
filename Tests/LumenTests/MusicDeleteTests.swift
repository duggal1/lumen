import Testing
import Foundation
import AVFoundation
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenExport
@testable import LumenUI

// MARK: Music lane deletion
//
// A music lane is a timeline element like any zoom/clip/caption: selecting it
// and pressing Delete must route through the one command bus, remove exactly
// that lane, and be undoable. These tests cover the reducer and the real
// EditorModel selection -> delete -> undo path.

@Test func deleteAudioLaneCommandRemovesOnlyTargetLane() throws {
    let a = AudioLane(id: UUID(), role: .music, placement: 0, gainDb: -18)
    let b = AudioLane(id: UUID(), role: .music, placement: 4, gainDb: -18)
    let vo = AudioLane(id: UUID(), role: .voiceover, placement: 2)

    var tl = Timeline(duration: 20)
    tl.audio.lanes = [a, b, vo]
    let ctx = ReduceContext(playhead: 0, selection: a.id, duration: 20)

    let fx = try reduce(&tl, .deleteAudioLane(a.id), ctx: ctx)
    #expect(fx.contains(.audio), "deleting a lane must invalidate the audio plan")
    #expect(tl.audio.lanes.count == 2)
    #expect(tl.audio.lanes.map(\.id) == [b.id, vo.id], "only the selected lane may be removed")

    // Unknown ids are a no-op, matching every other delete command.
    let untouched = tl.audio.lanes
    _ = try reduce(&tl, .deleteAudioLane(UUID()), ctx: ctx)
    #expect(tl.audio.lanes == untouched)
}

@MainActor
@Test func deleteSelectedMusicLaneRemovesItAndUndoRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try ProjectBundle.create(named: "MusicDelete", in: root)
    try writeMusicDeleteScreen(bundle.screenURL, seconds: 1)

    let a = AudioLane(id: UUID(), role: .music, placement: 0, gainDb: -18)
    let b = AudioLane(id: UUID(), role: .music, placement: 0.3, gainDb: -18)
    let vo = AudioLane(id: UUID(), role: .voiceover, placement: 0.2)

    var tl = Timeline(duration: 1)
    tl.audio.speedRampsAuto = false
    tl.audio.lanes = [a, b, vo]
    var meta = ProjectMeta(
        name: "MusicDelete",
        source: SourceInfo(width: 320, height: 180, fps: 30, duration: 1,
                           backingScale: 1, originX: 0, originY: 0),
        clock: RecordingClock())
    try bundle.save(ProjectFile(meta: meta, timeline: tl))
    try EventCodec.header().write(to: bundle.eventsURL)

    let renderer = try Renderer()
    let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
    let model = EditorModel(session: session, renderer: renderer, timeline: loaded,
                            exportSettings: ExportSettings(), transcript: nil)

    #expect(model.timeline.audio.lanes.map(\.id) == [a.id, b.id, vo.id])

    // Selecting the first music lane and dispatching Delete removes only it.
    model.selection = a.id
    model.deleteSelected()
    #expect(model.timeline.audio.lanes.map(\.id) == [b.id, vo.id])
    #expect(model.selection == nil)
    #expect(model.canUndo)

    // The same undo stack as every other delete restores the lane.
    model.undo()
    #expect(model.timeline.audio.lanes.map(\.id) == [a.id, b.id, vo.id])
}

/// Minimal 1s grey screen track so `ProjectSession.open` can build a frame reader.
private func writeMusicDeleteScreen(_ url: URL, seconds: Double) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let total = Int(seconds * 30)
    for i in 0..<total {
        guard let buffer = FrameImage.makeBuffer(320, 180) else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 150, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        if !adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}
