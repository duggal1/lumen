import SwiftUI
import AVFoundation
import CoreGraphics
import LumenProject
import LumenDirector
import LumenRender
import LumenAnalysis
import LumenExport

/// A 64 x 40 thumbnail cut from the recording's first frame. Content, never chrome.
struct ProjectThumb: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                DustLine().frame(width: 32)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: Radius.field))
        .accessibilityHidden(true)
        .task(id: url) { image = await ThumbnailLoader.load(url) }
    }
}

private struct ImageBox: @unchecked Sendable { let image: CGImage? }

private enum ThumbnailLoader {
    static func load(_ bundle: URL) async -> CGImage? {
        let box = await Task.detached(priority: .utility) { () -> ImageBox in
            do {
                let project = ProjectBundle(url: bundle), file = try project.load()
                let renderer = try Renderer()
                let frames = try await ReaderFrameSource(url: project.screenURL, device: SendableMetalDevice(renderer.device))
                let frame = try await frames.frame(atSource: 0)
                var timeline = file.timeline, source = file.meta.source
                source.duration = min(source.duration, 0.1)
                timeline.timeMap = TimeMap(sourceDuration: source.duration)
                let detections = timeline.overlays.privacy.enabled && timeline.overlays.privacy.autoDetect
                    ? try await OCRAnalyzer.analyze(url: project.screenURL, projectSalt: file.meta.analysisSalt,
                        customPatterns: timeline.overlays.privacy.customPatterns,
                        entropyThreshold: timeline.overlays.privacy.entropyThreshold, firstFrameOnly: true) : []
                let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: project.axURL))) ?? []
                let events = (try? project.events(origin: file.meta.clock.originHostSeconds)) ?? []
                timeline = Director.derive(timeline, input: DirectorInput(events: events.filter { $0.t <= 0.1 },
                    source: source, ax: ax, ocr: detections), revision: 1)
                let width = 128, height = max(Int(128 / timeline.style.aspectRatio), 1)
                guard let pixels = FrameImage.makeBuffer(width, height) else { return ImageBox(image: nil) }
                let request = RenderRequest(timeline: timeline, t: 0, screen: frame, canvas: SIMD2(width, height))
                let completed = await withCheckedContinuation { continuation in
                    if !renderer.render(request, into: pixels, completion: { continuation.resume(returning: true) }) {
                        continuation.resume(returning: false)
                    }
                }
                return ImageBox(image: completed ? FrameImage.cgImage(pixels) : nil)
            } catch { return ImageBox(image: nil) }
        }.value
        return box.image
    }
}
