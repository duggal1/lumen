import Foundation
import AVFoundation
import CoreVideo
import LumenProject

/// CPU fallback activity analyzer.
///
/// The Metal grid pass (formerly `ActivityGrid.metal`) produced a 48×27
/// occupancy grid per 10 Hz sample. This implementation keeps the same
/// public surface (`ActivityCache` with the grid payloads, `ActivityAnalyzer.analyze`)
/// and derives an occupancy grid by decoding the screen track and counting
/// non-black pixels per cell, so `Analysis` and the Director stay usable.
public enum ActivityAnalyzer {
    public static let analyzerID = "activity"
    public static let analyzerVersion = 1

    /// 48×27 grid lattice, 10 Hz samples.
    public static let gridW = 48, gridH = 27, cells = gridW * gridH
    public static let defaultHZ: Double = 10

    /// Cached pass: returns the cached grid payloads, or produces them via `produce`.
    public static func analyze(url: URL, offset: Double = 0, fps: Double = 10) async throws -> [ActivityPoint] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        guard let track else { return [] }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var pts: [Double] = []
        var grids: [[UInt8]] = []
        while let sb = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) {
            let t = sb.presentationTimeStamp.seconds
            guard t >= offset else { continue }
            guard pts.count < Int(duration * fps) + 1 else { break }
            pts.append(t)
            grids.append(occupancy(of: pb, W: gridW, H: gridH))
        }
        return pts.enumerated().map { ActivityPoint(t: $0.element.0 - offset,
                                                    x: 0, y: 0,
                                                    region: .zero,
                                                    coverage: Double(occupancySum(grids[$0.offset])) / 255.0) }
    }

    /// Fractional activity per cell: fraction of the cell whose pixels are non-black.
    static func occupancySum(_ g: [UInt8]) -> Int { g.reduce(0, +) }

    static func occupancy(of pb: CVPixelBuffer, W: Int, H: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let cw = max(width, 1) / CGFloat(W), ch = max(height, 1) / CGFloat(H)
        var out = [UInt8](repeating: 0, count: W * H)
        let ptr = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for cy in 0..<H {
            for cx in 0..<W {
                let x0 = Int(CGFloat(cx) * cw), x1 = Int(CGFloat(cx + 1) * cw)
                let y0 = Int(CGFloat(cy) * ch), y1 = Int(CGFloat(cy + 1) * ch)
                var sum: Int = 0, n = 0
                for y in max(y0, 0)..<min(y1, height) {
                    let row = ptr.advanced(by: y * stride)
                    for x in max(x0, 0)..<min(x1, width) {
                        let b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2]
                        sum += max(Int(r), max(Int(g), Int(b)))
                        n += 1
                    }
                }
                guard n > 0 else { continue }
                out[cy * W + cx] = UInt8(min(255, (sum / n) * 6))
            }
        }
        return out
    }
}
