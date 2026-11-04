import Foundation
import AVFoundation
import CoreVideo
import Metal
import os

/// One decoded source frame. IOSurface-backed texture, level 0 only. `id` identifies the decoded frame for mip caching.
public struct SourceFrame: @unchecked Sendable {
    public let id: UInt64
    public let pts: Double
    public let pixelBuffer: CVPixelBuffer
    public let texture: MTLTexture
    let cv: CVMetalTexture
}

public protocol FrameSource: Sendable {
    /// Sample-and-hold: newest frame with pts <= t.
    func frame(atSource t: Double) async throws -> SourceFrame
}

public enum FrameSourceError: Error { case noTrack, read(String) }

/// Shifts a source clock (used for the webcam track, which starts after the screen track).
public struct OffsetFrameSource: FrameSource {
    let base: any FrameSource
    let offset: Double
    public init(_ base: any FrameSource, offset: Double) { self.base = base; self.offset = offset }
    public func frame(atSource t: Double) async throws -> SourceFrame { try await base.frame(atSource: t - offset) }
}

private let idCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

/// Sequential reader with a small LRU. Forward playback never seeks; backward or far jumps restart the reader 0.5 s early
/// (master keyframe interval <= 0.5 s). Blocking decode calls run on the actor's executor, never on the main thread.
public actor ReaderFrameSource: FrameSource {
    private final class Entry {
        let id: UInt64, pts: Double, pb: CVPixelBuffer
        var end = Double.infinity
        init(pts: Double, pb: CVPixelBuffer) { id = idCounter.withLock { $0 += 1; return $0 }; self.pts = pts; self.pb = pb }
    }
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let cache: CVMetalTextureCache
    private let frameDur: Double
    private var reader: AVAssetReader?
    private var out: AVAssetReaderTrackOutput?
    private var cur: Entry?, peek: Entry?
    private var lru: [Entry] = []

    public init(url: URL, device: MTLDevice) async throws {
        let a = AVURLAsset(url: url)
        guard let tr = try await a.loadTracks(withMediaType: .video).first else { throw FrameSourceError.noTrack }
        let fr = try await tr.load(.nominalFrameRate)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        guard let c else { throw FrameSourceError.read("texture cache") }
        asset = a; track = tr; cache = c; frameDur = 1 / Double(max(fr, 1))
    }

    public func frame(atSource t0: Double) async throws -> SourceFrame {
        let t = max(t0, 0)
        if let e = lru.last(where: { $0.pts <= t && t < $0.end }) { return try make(e) }
        if reader == nil || cur == nil || t < cur!.pts || t > cur!.pts + 2.0 { try restart(at: t) }
        while true {
            if peek == nil { peek = readNext() }
            guard let p = peek, p.pts <= t else { break }
            cur?.end = p.pts
            cur = p; peek = nil
            lru.append(p); if lru.count > 8 { lru.removeFirst() }
        }
        guard let c = cur ?? peek else { throw FrameSourceError.read("no frames") }
        c.end = peek.map { $0 === c ? .infinity : $0.pts } ?? .infinity
        return try make(c)
    }

    private func restart(at t: Double) throws {
        reader?.cancelReading()
        for e in lru where e.end == .infinity { e.end = e.pts + frameDur * 1.5 }
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        o.alwaysCopiesSampleData = false
        r.add(o)
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - 0.5), preferredTimescale: 600), duration: .positiveInfinity)
        guard r.startReading() else { throw FrameSourceError.read(r.error?.localizedDescription ?? "startReading failed") }
        reader = r; out = o; cur = nil; peek = nil
    }

    private func readNext() -> Entry? {
        guard let sb = out?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return Entry(pts: sb.presentationTimeStamp.seconds, pb: pb)
    }

    private func make(_ e: Entry) throws -> SourceFrame {
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(e.pb), h = CVPixelBufferGetHeight(e.pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, e.pb, nil, .bgra8Unorm, w, h, 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { throw FrameSourceError.read("texture") }
        return SourceFrame(id: e.id, pts: e.pts, pixelBuffer: e.pb, texture: tex, cv: cv)
    }
}