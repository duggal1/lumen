import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import os

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc, hevc10, prores
    var cm: CMVideoCodecType {
        switch self { case .h264: kCMVideoCodecType_H264; case .hevc, .hevc10: kCMVideoCodecType_HEVC; case .prores: kCMVideoCodecType_AppleProRes422HQ }
    }
    /// 10-bit HEVC needs 10-bit input or the extra bits are wasted. (Verify with the probe on your hardware: spike 5.)
    public var pixelFormat: OSType { self == .hevc10 ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA }
}

public struct ExportPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var codec: VideoCodec
    public var height: Int                 // output height at 16:9 (4K = 2160)
    public var fps: Int
    public var bpp: Double = 0.06
    public func width(aspect: Double) -> Int { (Int((Double(height) * aspect).rounded()) + 1) & ~1 }
}

public enum ExportPresets {
    static let heights: [(String, Int)] = [("1080p", 1080), ("1440p", 1440), ("3k", 1620), ("4k", 2160)]
    public static let all: [ExportPreset] = {
        var out: [ExportPreset] = []
        for (n, h) in heights { for fps in [24, 30, 60, 120, 144, 240] {
            for c in [VideoCodec.h264, .hevc, .hevc10] { out.append(ExportPreset(name: "\(n)\(fps)-\(c.rawValue)", codec: c, height: h, fps: fps)) }
            if fps <= 60 { out.append(ExportPreset(name: "\(n)\(fps)-prores", codec: .prores, height: h, fps: fps, bpp: 0)) }
        } }
        return out
    }()
    /// "4k120-hevc", "1080p60-h264"
    public static func parse(_ s: String) -> ExportPreset? { all.first { $0.name == s.lowercased() } }
}

/// Which (codec, resolution, fps) combos actually encode on THIS machine. Hardware-only VTCompressionSession probe, cached.
public final class ExportCapabilityMatrix: @unchecked Sendable {
    public static let shared = ExportCapabilityMatrix()
    private let cache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    public func supports(_ c: VideoCodec, _ w: Int, _ h: Int, _ fps: Int) -> Bool {
        let k = "\(c.rawValue)-\(w)x\(h)@\(fps)"
        if let v = cache.withLock({ $0[k] }) { return v }
        let v = Self.probe(c, w, h, fps)
        cache.withLock { $0[k] = v }; return v
    }
    public func supports(_ p: ExportPreset, aspect: Double = 16.0 / 9) -> Bool { supports(p.codec, p.width(aspect: aspect), p.height, p.fps) }
    public func valid(_ ps: [ExportPreset]) -> [ExportPreset] { ps.filter { supports($0) } }

    /// One step down at a time: halve fps first, then drop resolution. Returns a user-visible notice when it falls back.
    public func resolve(_ p: ExportPreset, aspect: Double = 16.0 / 9) -> (ExportPreset, String?) {
        if supports(p, aspect: aspect) { return (p, nil) }
        var q = p
        for fps in [240, 144, 120, 60, 30, 24] where fps < p.fps {
            q.fps = fps
            if supports(q, aspect: aspect) { return (q, "\(p.name) isn't supported on this Mac. Using \(fps) fps.") }
        }
        q.fps = p.fps
        for h in [2160, 1620, 1440, 1080] where h < p.height {
            q.height = h
            if supports(q, aspect: aspect) { return (q, "\(p.name) isn't supported on this Mac. Using \(h)p.") }
        }
        return (p, "No supported combination found.")
    }

    static func probe(_ c: VideoCodec, _ w: Int, _ h: Int, _ fps: Int) -> Bool {
        if w > 8192 || h > 8192 { return false }
        let spec: [CFString: Any] = c == .prores ? [:] : [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: c.cm,
                                         encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return false }
        defer { VTCompressionSessionInvalidate(s) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        if c == .hevc10 { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel) }
        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else { return false }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, c.pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        guard let pb else { return false }
        let ok = OSAllocatedUnfairLock(initialState: false)
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: .zero,
                                                 duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil,
                                                 infoFlagsOut: nil) { status, _, buf in ok.withLock { $0 = status == noErr && buf != nil } }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        return st == noErr && ok.withLock { $0 }
    }
}