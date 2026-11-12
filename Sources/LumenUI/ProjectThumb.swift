import SwiftUI
import AVFoundation
import CoreGraphics
import LumenProject

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
            let project = ProjectBundle(url: bundle)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: project.screenURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 160)
            do {
                let result = try await generator.image(at: .zero)
                return ImageBox(image: result.image)
            } catch {
                return ImageBox(image: nil)
            }
        }.value
        return box.image
    }
}
