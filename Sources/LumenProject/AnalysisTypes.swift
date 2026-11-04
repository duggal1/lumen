import Foundation
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