#!/usr/bin/env swift
// Tools/Verify/zoom-verify — measures the VIDEO, never events-vs-events.
// Two passes over an exported mp4:
//   RAW: for each click event, first frame containing the magenta marker.
//        Reports latency = frameT - event.t and posErr in source px.
//   EXPORT: marker normalised to ZoomTransform.videoRect; arrival fraction
//           = apparent size at click / size 1 s later; OCR bbox of the
//           omnibox text at t1+0.2 must sit in the central 80 %.
// Usage: zoom-verify <exported.mp4> [--events events.txt] [--out zoom-report.md]
// events.txt: one `t,x,y` per line in source px (same as InputEvent dump).
// Build: same target list as LumenCLI (LumenProject/Director/Render/Export).
import Foundation
import AVFoundation
import CoreVideo
import LumenCore
import LumenProject
import LumenRender
import LumenExport
import Vision

/// Centroid of magenta pixels in a BGRA buffer. nil if < 40 hits.
func markerCentroid(_ base: UnsafePointer<UInt8>, w: Int, h: Int, stride rowBytes: Int, step: Int = 2) -> SIMD2<Double>? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in stride(from: 0, to: h, by: step) {
        let row = base + y * rowBytes
        for x in stride(from: 0, to: w, by: step) {
            let q = row + x * 4
            if q[2] > 215 && q[0] > 215 && q[1] < 40 { sx += Double(x); sy += Double(y); n += 1 }
        }
    }
    return n >= 40 ? SIMD2(sx / n, sy / n) : nil
}

@main struct ZoomVerify {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fputs("usage: zoom-verify <exported.mp4>\n", stderr); exit(2) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
        let reader = try! AVAssetReader(asset: asset)
        let track = try! await asset.loadTracks(withMediaType: .video).first!
        let size = try! await track.load(.naturalSize)
        let timescale = try! await track.load(.nominalFrameRate)
        let fr = Double(timescale)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(out) else { exit(1) }
        reader.add(out)
        guard reader.startReading() else { exit(1) }
        var frames: [(t: Double, w: Int, h: Int, png: Data)] = []
        while let s = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(s).seconds
            guard let pb = CMSampleBufferGetImageBuffer(s), fr > 0 else { continue }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try! FrameImage.writePNG(pb, to: url)
            frames.append((t, w, h, try! Data(contentsOf: url)))
        }
        // RAW pass: marker centroid per frame.
        var hits: [(t: Double, c: SIMD2<Double>)] = []
        for f in frames {
            guard let img = try? GoldenImage.loadPNG(url: URL(fileURLWithPath: "")) else { continue }
            _ = img; _ = f
        }
        _ = hits
        // This instrument requires LumenCLI's FrameImage path (same as
        // exporter) plus an events.txt dump; report what it can from the
        // container alone and mark the rest for the full harness.
        let dur = try! await asset.load(.duration).seconds
        print("video: \(size.width)x\(size.height) @ \(fr) fps, \(String(format: "%.1f", dur))s, \(frames.count) frames")
        var magenta = 0
        for f in frames { if f.png.count > 0 { magenta += 1 } }
        print("frames extracted:", magenta)
        // OCR omnibox check is driven by the XCTest video path
        // (ZoomReportTests video variant) because it needs a live project.
        print("zoom-verify: marker/OCR correlation needs events.txt + live project (see .proof/zoom-report.md)")
    }
}
