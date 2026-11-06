import Foundation
import LumenCore
import LumenProject

public struct MaskFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var mode: MaskMode
    public var rect: SIMD4<Float>
    public var padding: Float
    public var category: String?
    public init(id: UUID, mode: MaskMode, rect: SIMD4<Float>, padding: Float, category: String?) {
        self.id = id; self.mode = mode; self.rect = rect; self.padding = padding; self.category = category
    }
}

public struct HighlightFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var rect: SIMD4<Float>
    public var style: HighlightStyle
    public var dim: Float
    public var opacity: Float
}

public struct LoupeFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// SOURCE pixel the glass looks at (follows the cursor when the loupe does).
    public var target: SIMD2<Float>
    /// Canvas-normalized centre where the glass itself sits.
    public var glass: SIMD2<Float>
    public var radius: Float
    public var border: Float
    public var magnification: Float
    public var round: Bool
    public var opacity: Float
}

public struct TextFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var center: SIMD2<Float>
    public var size: Float
    public var color: RGBA
    public var opacity: Float
}

public struct EmphasisFrame: Sendable, Equatable {
    public var masks: [MaskFrame]
    public var highlights: [HighlightFrame]
    public var loupes: [LoupeFrame]
    public var texts: [TextFrame]
    public init(masks: [MaskFrame] = [], highlights: [HighlightFrame] = [], loupes: [LoupeFrame] = [], texts: [TextFrame] = []) {
        self.masks = masks; self.highlights = highlights; self.loupes = loupes; self.texts = texts
    }
}

enum Emphasis {
    static func evaluate(overlays: Overlays, autoMasks: [Mask], sourceTime t: Double,
                         cursor: SIMD2<Float>, sourceSize: SIMD2<Double>) -> EmphasisFrame {
        let masks = (overlays.masks + autoMasks).compactMap { maskFrame($0, t: t, size: sourceSize) }
        let highlights = overlays.highlights.compactMap { highlightFrame($0, t: t, size: sourceSize) }
        let loupes = overlays.loupes.compactMap { loupeFrame($0, t: t, cursor: cursor) }
        let texts = overlays.texts.compactMap { textFrame($0, t: t) }
        return EmphasisFrame(masks: masks, highlights: highlights, loupes: loupes, texts: texts)
    }

    private static func maskFrame(_ mask: Mask, t: Double, size: SIMD2<Double>) -> MaskFrame? {
        guard mask.approved, t >= mask.start, t < mask.end, let key = rect(mask.keys, at: t) else { return nil }
        let pad = max(mask.padding, 0)
        let x = max(key.x - pad, 0), y = max(key.y - pad, 0)
        let right = min(key.x + key.w + pad, size.x), bottom = min(key.y + key.h + pad, size.y)
        return MaskFrame(id: mask.id, mode: mask.mode, rect: SIMD4(Float(x), Float(y), Float(max(right - x, 0)), Float(max(bottom - y, 0))),
                         padding: Float(pad), category: mask.category)
    }

    private static func rect(_ keys: [MaskKey], at t: Double) -> MaskKey? {
        let sorted = keys.sorted { $0.t < $1.t }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        if t <= first.t { return first }
        for pair in zip(sorted, sorted.dropFirst()) where t <= pair.1.t {
            let span = pair.1.t - pair.0.t
            let u = span > 0 ? (t - pair.0.t) / span : 1
            return MaskKey(t: t, x: lerp(pair.0.x, pair.1.x, u), y: lerp(pair.0.y, pair.1.y, u),
                           w: lerp(pair.0.w, pair.1.w, u), h: lerp(pair.0.h, pair.1.h, u))
        }
        return sorted.last
    }

    private static func highlightFrame(_ highlight: Highlight, t: Double, size: SIMD2<Double>) -> HighlightFrame? {
        guard t >= highlight.start, t < highlight.end else { return nil }
        let rect = clampedRect(x: highlight.x, y: highlight.y, w: highlight.w, h: highlight.h, size: size)
        return HighlightFrame(id: highlight.id, rect: rect, style: highlight.style, dim: Float(clamp(highlight.dim, 0, 0.7)),
                             opacity: envelope(t, start: highlight.start, end: highlight.end))
    }

    private static func loupeFrame(_ loupe: Loupe, t: Double, cursor: SIMD2<Float>) -> LoupeFrame? {
        guard t >= loupe.start, t < loupe.end else { return nil }
        let target = loupe.follow ? cursor : SIMD2(Float(loupe.x), Float(loupe.y))
        return LoupeFrame(id: loupe.id, target: target,
                          glass: SIMD2(Float(clamp(loupe.cx, 0.05, 0.95)), Float(clamp(loupe.cy, 0.05, 0.95))),
                          radius: Float(max(loupe.radius, 0.02)), border: Float(max(loupe.border, 0.001)),
                          magnification: Float(clamp(loupe.magnification, 1.2, 6)), round: loupe.round,
                          opacity: envelope(t, start: loupe.start, end: loupe.end))
    }

    private static func textFrame(_ block: TextBlock, t: Double) -> TextFrame? {
        guard t >= block.start, t < block.end else { return nil }
        return TextFrame(id: block.id, text: block.text, center: SIMD2(Float(clamp(block.x, 0, 1)), Float(clamp(block.y, 0, 1))),
                         size: Float(max(block.size, 0)), color: block.color, opacity: envelope(t, start: block.start, end: block.end))
    }

    private static func clampedRect(x: Double, y: Double, w: Double, h: Double, size: SIMD2<Double>) -> SIMD4<Float> {
        let left = clamp(x, 0, size.x), top = clamp(y, 0, size.y)
        let right = clamp(x + max(w, 0), left, size.x), bottom = clamp(y + max(h, 0), top, size.y)
        return SIMD4(Float(left), Float(top), Float(right - left), Float(bottom - top))
    }

    private static func envelope(_ t: Double, start: Double, end: Double) -> Float {
        let fade = min(0.15, max((end - start) / 2, 0.001))
        return Float(min(clamp((t - start) / fade, 0, 1), clamp((end - t) / fade, 0, 1)))
    }
}
