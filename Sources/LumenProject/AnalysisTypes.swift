import Foundation
import CoreGraphics
import LumenCore

/// One recognized word. Source seconds.
public struct WordToken: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double, end: Double
    public var confidence: Float
    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}
public struct Transcript: Codable, Sendable, Equatable {
    public var words: [WordToken]
    public var locale: String
    public init(words: [WordToken], locale: String) { self.words = words; self.locale = locale }
}
/// Sensitive-text detection. Rect is normalized to the source frame (top-left origin). Raw text is never stored, only a salted hash.
public struct OCRDetection: Codable, Sendable, Equatable {
    public var t: Double, x: Double, y: Double, w: Double, h: Double
    public var category: SensitiveCategory
    public var hash: UInt64
    public var confidence: Float
    public init(t: Double, x: Double, y: Double, w: Double, h: Double, category: SensitiveCategory, hash: UInt64, confidence: Float) {
        self.t = t; self.x = x; self.y = y; self.w = w; self.h = h; self.category = category; self.hash = hash; self.confidence = confidence
    }
}
/// Face rect center/height normalized to the webcam image. Source seconds.
public struct FaceSample: Codable, Sendable {
    public var t: Double, cx: Float, cy: Float, h: Float
    public init(t: Double, cx: Float, cy: Float, h: Float) { self.t = t; self.cx = cx; self.cy = cy; self.h = h }
}
/// Pixel-activity centroid (device / imported clips with no input events). Source seconds, source px.
public struct ActivityPoint: Codable, Sendable {
    public var t: Double, x: Double, y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}
/// Typed-text line located by pixel change (see TypingTracer). Rect/caret in
/// source px; samples are the caret approach found per keystroke frame.
public struct TypingTrace: Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var t: Double, x: Double, y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }
    public var t0: Double, t1: Double
    public var rect: CGRect?
    public var samples: [Sample]
    public init(t0: Double, t1: Double, rect: CGRect? = nil, samples: [Sample] = []) {
        self.t0 = t0; self.t1 = t1; self.rect = rect; self.samples = samples
    }
    enum CodingKeys: String, CodingKey { case t0, t1, rect, samples }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t0 = try c.decode(Double.self, forKey: .t0); t1 = try c.decode(Double.self, forKey: .t1)
        if let r = try c.decodeIfPresent([Double].self, forKey: .rect), r.count == 4 {
            rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else { rect = nil }
        samples = try c.decode([Sample].self, forKey: .samples)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t0, forKey: .t0); try c.encode(t1, forKey: .t1)
        if let r = rect { try c.encode([r.origin.x, r.origin.y, r.size.width, r.size.height], forKey: .rect) }
        try c.encode(samples, forKey: .samples)
    }
}
/// Per-tile mean-luma grid over a frame (for TypingTracer).
public struct LumaTiles: Sendable, Equatable {
    public var cols: Int, rows: Int, tile: Int, mean: [UInt8]
    public init(cols: Int, rows: Int, tile: Int, mean: [UInt8]) {
        self.cols = cols; self.rows = rows; self.tile = tile; self.mean = mean
    }
}

/// Location and sampling details for a cached person-mask plane sequence.
public struct PersonMaskInfo: Codable, Sendable, Equatable {
    public var file: String
    public var width: Int, height: Int, fps: Double, frames: Int
    public init(file: String, width: Int, height: Int, fps: Double, frames: Int) {
        self.file = file; self.width = width; self.height = height; self.fps = fps; self.frames = frames
    }
}
