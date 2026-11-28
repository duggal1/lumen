import Foundation
import LumenProject
import LumenRender

/// One consumer's mutable decoder state. Both consumers use exactly the same
/// source/output mapping, but never share an AVAssetReader or seek history.
final class ProjectFrameReader: @unchecked Sendable {
    let screen: ReaderFrameSource
    let webcam: (any FrameSource)?
    private let device: SendableMetalDevice
    private let cacheBudget: Int
    private let maxCachedFrames: Int
    private let clipSources: ClipReaderCache<ReaderFrameSource>

    init(screen: ReaderFrameSource, webcam: (any FrameSource)?, device: SendableMetalDevice,
         cacheBudget: Int = 32 * 1024 * 1024, maxCachedFrames: Int = 4, maxClipReaders: Int = 2) {
        self.screen = screen; self.webcam = webcam; self.device = device
        self.cacheBudget = cacheBudget; self.maxCachedFrames = maxCachedFrames
        self.clipSources = ClipReaderCache(capacity: maxClipReaders)
    }

    /// One frame for an OUTPUT time. Recording times read the screen track at
    /// the source time the TimeMap resolves; imported clips read their own file.
    /// Preview and export both go through here so a clip and the recording
    /// cannot disagree about what is on screen at a given moment.
    func frames(atOutput t: Double, timeline tl: Timeline) async throws -> (screen: SourceFrame, webcam: SourceFrame?) {
        if let (clip, time) = tl.clipSource(atOutput: t) {
            let source = try await clipSource(for: clip.url)
            return (try await source.frame(atSource: time), nil)
        }
        let s = tl.timeMap.source(atOutput: t)
        // SMOOTHNESS: the webcam and the screen are two independent readers.
        // Awaiting the webcam first delayed the screen decode by a full frame.
        async let web: SourceFrame? = {
            guard tl.webcam != nil, let w = webcam else { return nil }
            return try? await w.frame(atSource: s)
        }()
        let screenFrame = try await screen.frame(atSource: s)
        return (screenFrame, await web)
    }

    private func clipSource(for url: URL) async throws -> ReaderFrameSource {
        let key = url.standardizedFileURL.path
        let device = device, budget = cacheBudget, frames = maxCachedFrames
        return try await clipSources.value(for: key) {
            try await ReaderFrameSource(url: url, device: device, cacheBudget: budget, maxCachedFrames: frames)
        }
    }

}
