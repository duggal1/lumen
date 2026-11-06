import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import os

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc, hevc10, prores, prores4444
    var cm: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc, .hevc10: kCMVideoCodecType_HEVC
        case .prores: kCMVideoCodecType_AppleProRes422HQ
        case .prores4444: kCMVideoCodecType_AppleProRes4444
        }
    }
    /// 10-bit HEVC needs 10-bit input or the extra bits are wasted. (Verify with the probe on your hardware: spike 5.)
    public var pixelFormat: OSType { self == .hevc10 ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA }
    /// Only ProRes 4444 can carry a real alpha channel.
    public var supportsAlpha: Bool { self == .prores4444 }
    public var isProRes: Bool { self == .prores || self == .prores4444 }
    public var title: String {
        switch self {
        case .h264: "H.264"; case .hevc: "8-bit HEVC"; case .hevc10: "10-bit HEVC"
        case .prores: "ProRes 422 HQ"; case .prores4444: "ProRes 4444"
        }
    }
}

public struct ExportPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var codec: VideoCodec
    public var height: Int                 // output height at 16:9 (4K = 2160)
    public var fps: Int
    public var bpp: Double = 0.06
    /// Overrides the aspect-derived width for a user-selected custom resolution.
    public var customWidth: Int?
    /// Deliver a premultiplied alpha channel. ProRes 4444 only.
    public var alpha: Bool = false

    public init(name: String, codec: VideoCodec, height: Int, fps: Int, bpp: Double = 0.06, customWidth: Int? = nil,
                alpha: Bool = false) {
        self.name = name; self.codec = codec; self.height = height; self.fps = fps
        self.bpp = bpp; self.customWidth = customWidth; self.alpha = alpha
    }

    public func width(aspect: Double) -> Int { customWidth ?? ((Int((Double(height) * aspect).rounded()) + 1) & ~1) }

    static func label(forHeight h: Int) -> String {
        switch h { case 1080: "1080p"; case 1440: "1440p"; case 1620: "3k"; case 2160: "4k"; case 4320: "8k"; default: "\(h)p" }
    }
    static func makeName(height: Int, fps: Int, codec: VideoCodec) -> String { "\(label(forHeight: height))\(fps)-\(codec.rawValue)" }

    static func make(height: Int, fps: Int, codec: VideoCodec) -> ExportPreset {
        ExportPreset(name: makeName(height: height, fps: fps, codec: codec), codec: codec, height: height, fps: fps,
                     bpp: codec.isProRes ? 0 : 0.06)
    }

    /// Same preset with other codec/height/fps; the name follows the parameters.
    func adjusted(codec: VideoCodec, height: Int, fps: Int) -> ExportPreset {
        var q = self
        q.codec = codec; q.height = height; q.fps = fps
        q.alpha = q.alpha && codec.supportsAlpha
        q.name = Self.makeName(height: height, fps: fps, codec: codec)
        return q
    }
}

public enum ExportPresets {
    static let heights = [1080, 1440, 1620, 2160, 4320]
    static let rates = [24, 30, 60, 120, 144, 240]

    public static let all: [ExportPreset] = {
        var out: [ExportPreset] = []
        for h in heights {
            for fps in rates {
                for c in [VideoCodec.h264, .hevc, .hevc10] { out.append(.make(height: h, fps: fps, codec: c)) }
                if fps <= 60 {
                    out.append(.make(height: h, fps: fps, codec: .prores))
                    out.append(.make(height: h, fps: fps, codec: .prores4444))
                }
            }
        }
        return out
    }()

    /// "4k120-hevc", "1080p60-h264"
    public static func parse(_ s: String) -> ExportPreset? { all.first { $0.name == s.lowercased() } }
}

/// Which (codec, resolution, fps) combos actually encode on THIS machine.
/// 1) static level limits, 2) hardware-only VTCompressionSession probe, cached in memory and persisted per machine + OS.
public final class ExportCapabilityMatrix: @unchecked Sendable {
    public static let shared = ExportCapabilityMatrix()
    private let cache: OSAllocatedUnfairLock<[String: Bool]>
    private let key: String

    private init() {
        let k = Self.persistKey()
        key = k
        cache = OSAllocatedUnfairLock(initialState: (UserDefaults.standard.dictionary(forKey: k) as? [String: Bool]) ?? [:])
    }

    private static func persistKey() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "lumen.exportProbe.v1.\(model).\(v.majorVersion).\(v.minorVersion)"
    }

    /// Drops all cached probe results (in memory and on disk).
    public func reset() {
        cache.withLock { $0.removeAll() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: Queries

    public func supports(_ c: VideoCodec, _ w: Int, _ h: Int, _ fps: Int) -> Bool {
        guard Self.withinLevelLimits(c, w, h, fps) else { return false }
        let k = "\(c.rawValue)-\(w)x\(h)@\(fps)"
        if let v = cache.withLock({ $0[k] }) { return v }
        let v = Self.probe(c, w, h, fps)
        let snapshot = cache.withLock { st -> [String: Bool] in st[k] = v; return st }
        UserDefaults.standard.set(snapshot, forKey: key)
        return v
    }

    public func supports(_ p: ExportPreset, aspect: Double = 16.0 / 9) -> Bool {
        // An alpha delivery that silently lost its alpha channel would be worse
        // than a refusal, so unsupported codec/alpha pairs never validate.
        if p.alpha && !p.codec.supportsAlpha { return false }
        return supports(p.codec, p.width(aspect: aspect), p.height, p.fps)
    }
    public func valid(_ ps: [ExportPreset]) -> [ExportPreset] { ps.filter { supports($0) } }

    /// One step at a time: same resolution first (8-bit HEVC for 10-bit, then lower fps), then drop resolution and retry.
    /// Returns a user-visible notice when it falls back.
    public func resolve(_ p: ExportPreset, aspect: Double = 16.0 / 9) -> (ExportPreset, String?) {
        if supports(p, aspect: aspect) { return (p, nil) }
        let fpsSteps = [p.fps] + [240, 144, 120, 60, 30, 24].filter { $0 < p.fps }
        let heights = [p.height] + [4320, 2160, 1620, 1440, 1080].filter { $0 < p.height }
        // Alpha is a delivery promise: never fall back to a codec that cannot
        // carry it. Resolution and frame rate may still come down.
        let codecs: [VideoCodec] = p.alpha ? [.prores4444] : (p.codec == .hevc10 ? [.hevc10, .hevc] : [p.codec])
        for h in heights {
            for fps in fpsSteps {
                for c in codecs {
                    if h == p.height && fps == p.fps && c == p.codec { continue }
                    let q = p.adjusted(codec: c, height: h, fps: fps)
                    guard supports(q, aspect: aspect) else { continue }
                    var changes: [String] = []
                    if c != p.codec { changes.append(c.title) }
                    if h != p.height { changes.append("\(h)p") }
                    if fps != p.fps { changes.append("\(fps) fps") }
                    return (q, "\(p.name) isn't supported on this Mac. Using \(changes.joined(separator: ", ")).")
                }
            }
        }
        return (p, "No supported combination found.")
    }

    // MARK: Static level limits (first filter)

    /// H.264 level 5.2 (MaxFS 36864 MBs, MaxMBPS 2,073,600); HEVC level 6.2 (MaxLumaPs 35,651,584, MaxLumaSr 4,278,190,080).
    static func withinLevelLimits(_ c: VideoCodec, _ w: Int, _ h: Int, _ fps: Int) -> Bool {
        guard w > 0, h > 0, fps > 0, w % 2 == 0, h % 2 == 0, w <= 8192, h <= 8192 else { return false }
        switch c {
        case .h264:
            let mbs = Double((w + 15) / 16 * ((h + 15) / 16))
            return mbs <= 36_864 && mbs * Double(fps) <= 2_073_600
        case .hevc, .hevc10:
            let px = Double(w) * Double(h)
            return px <= 35_651_584 && px * Double(fps) <= 4_278_190_080
        case .prores, .prores4444:
            return true
        }
    }

    // MARK: Real probe

    static func probe(_ c: VideoCodec, _ w: Int, _ h: Int, _ fps: Int) -> Bool {
        let spec: [CFString: Any] = c.isProRes ? [:] : [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: c.cm,
                                         encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &session) == noErr, let s = session else { return false }
        defer { VTCompressionSessionInvalidate(s) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        if c == .hevc10 { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel) }
        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else { return false }

        var pbo: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, c.pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pbo)
        guard let pb = pbo else { return false }

        let ok = OSAllocatedUnfairLock(initialState: false)
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: .zero,
                                                 duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                                 frameProperties: nil, infoFlagsOut: nil) { status, _, buf in
            let succeeded = status == noErr && buf != nil
            ok.withLock { $0 = succeeded }
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        return st == noErr && ok.withLock { $0 }
    }
}