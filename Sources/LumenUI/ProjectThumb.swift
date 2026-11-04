import SwiftUI
import AVFoundation
import CoreGraphics

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
        let box = await withCheckedContinuation { (cont: CheckedContinuation<ImageBox, Never>) in
            let asset = AVURLAsset(url: bundle.appendingPathComponent("screen.mov"))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 128, height: 80)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                cont.resume(returning: ImageBox(image: image))
            }
        }
        return box.image
    }
}
