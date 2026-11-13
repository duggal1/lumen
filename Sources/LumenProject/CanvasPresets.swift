// AGENT: Canvas presets keep Gradii's curated palettes available as native, deterministic Lumen backgrounds.
//
// Derived from Gradii, Copyright (c) 2025 Keshav Bagaade, under the MIT License.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

/// A deterministic canvas rendering family stored with the project style.
public enum CanvasStyle: String, Codable, CaseIterable, Sendable {
    case mesh, fluid, waves, orbs, linear, radial, conic
}

/// A named Gradii palette and the native rendering family used for it.
public struct CanvasPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var style: CanvasStyle
    public var colors: [RGBA]
    public var angle: Double
    public var points: [SIMD2<Double>]
    public var center: SIMD2<Double>
    public var groundColor: RGBA?

    public static let defaultPoints: [SIMD2<Double>] = [
        SIMD2(0.15, 0.20), SIMD2(0.85, 0.15), SIMD2(0.50, 0.50),
        SIMD2(0.20, 0.85), SIMD2(0.80, 0.80), SIMD2(0.50, 0.02),
    ]

    public init(id: String, name: String, style: CanvasStyle, colors: [RGBA], angle: Double = 35,
                points: [SIMD2<Double>] = CanvasPreset.defaultPoints,
                center: SIMD2<Double> = SIMD2(0.5, 0.5), groundColor: RGBA? = nil) {
        self.id = id
        self.name = name
        self.style = style
        self.colors = colors
        self.angle = angle
        self.points = points
        self.center = center
        self.groundColor = groundColor
    }
}

/// The curated mesh, fluid, wave, orb and gradient starting points from Gradii.
public enum CanvasPresets {
    public static let all: [CanvasPreset] = [
        .init(id: "ember", name: "Ember", style: .mesh, colors: [RGBA(0x1A0B2E), RGBA(0xFF5F1F), RGBA(0xFFB347), RGBA(0xD6246E), RGBA(0x3B0A45)], points: [SIMD2(0.12, 0.18), SIMD2(0.62, 0.38), SIMD2(0.86, 0.80), SIMD2(0.30, 0.74), SIMD2(0.90, 0.12)]),
        .init(id: "lagoon", name: "Lagoon", style: .mesh, colors: [RGBA(0x03203A), RGBA(0x0EA5A4), RGBA(0x7DD3C0), RGBA(0x1E5BB8), RGBA(0xE0F7F4)], points: [SIMD2(0.10, 0.85), SIMD2(0.45, 0.45), SIMD2(0.80, 0.20), SIMD2(0.15, 0.20), SIMD2(0.85, 0.75)]),
        .init(id: "peach", name: "Peach Fuzz", style: .mesh, colors: [RGBA(0xFFD6C2), RGBA(0xFF9A8B), RGBA(0xFFC3A0), RGBA(0xF6E3D4), RGBA(0xE8A0BF)]),
        .init(id: "midnight", name: "Midnight", style: .mesh, colors: [RGBA(0x05060F), RGBA(0x1B2A6B), RGBA(0x4F46E5), RGBA(0x0B1026), RGBA(0x7C3AED)], points: [SIMD2(0.20, 0.20), SIMD2(0.55, 0.55), SIMD2(0.80, 0.82), SIMD2(0.85, 0.20), SIMD2(0.25, 0.85)]),
        .init(id: "citrus", name: "Citrus", style: .mesh, colors: [RGBA(0xFFF4B8), RGBA(0xFFD23F), RGBA(0xFF8C42), RGBA(0xB5E655), RGBA(0xFFFBE8)]),
        .init(id: "orchid", name: "Orchid", style: .mesh, colors: [RGBA(0x2B0F3A), RGBA(0xC026D3), RGBA(0xF0ABFC), RGBA(0x6D28D9), RGBA(0xFB7185)]),
        .init(id: "graphite", name: "Graphite", style: .mesh, colors: [RGBA(0x0A0A0A), RGBA(0x2A2B30), RGBA(0x6B6B70), RGBA(0x1B1C1F), RGBA(0xB4B4BA)]),
        .init(id: "marble", name: "Marble", style: .fluid, colors: [RGBA(0x0E0E10), RGBA(0x3A3A40), RGBA(0xD9D4CC), RGBA(0x8A857C), RGBA(0xF4F1EA)]),
        .init(id: "lava", name: "Lava", style: .fluid, colors: [RGBA(0x1A0000), RGBA(0x7A0B0B), RGBA(0xFF4D00), RGBA(0xFFB000), RGBA(0xFFF1C1)]),
        .init(id: "abyss", name: "Abyss", style: .fluid, colors: [RGBA(0x000814), RGBA(0x001D3D), RGBA(0x003566), RGBA(0x00B4D8), RGBA(0x90E0EF)]),
        .init(id: "opal", name: "Opal", style: .fluid, colors: [RGBA(0xF8F0FF), RGBA(0xC3E8FF), RGBA(0xFFD6F0), RGBA(0xD7FFE6), RGBA(0xFFF6D1)]),
        .init(id: "toxic", name: "Toxic", style: .fluid, colors: [RGBA(0x0B0F0A), RGBA(0x1F3D0C), RGBA(0x7CFF4F), RGBA(0xE6FF94)]),
        .init(id: "aurora", name: "Aurora", style: .waves, colors: [RGBA(0x020617), RGBA(0x064E3B), RGBA(0x10B981), RGBA(0xA7F3D0), RGBA(0x1E1B4B)], angle: -14),
        .init(id: "dune", name: "Dune", style: .waves, colors: [RGBA(0x3D2314), RGBA(0xA0522D), RGBA(0xE9B384), RGBA(0xF6E2C8), RGBA(0xC97B4A)], angle: 8),
        .init(id: "sorbet", name: "Sorbet", style: .waves, colors: [RGBA(0xFF9ECF), RGBA(0xFFC8A2), RGBA(0xFFF1A8), RGBA(0xB8F2E6), RGBA(0xAED9FF)], angle: -30),
        .init(id: "velvet", name: "Velvet", style: .waves, colors: [RGBA(0x14010A), RGBA(0x5B0E2D), RGBA(0xA4133C), RGBA(0xFF4D6D), RGBA(0x2D0613)], angle: 20),
        .init(id: "classic", name: "Gradii Classic", style: .orbs, colors: [RGBA(0xFF6600), RGBA(0x0066CC), RGBA(0xFFB366), RGBA(0x002B50), RGBA(0x66A3FF)], points: [SIMD2(0.20, 0.30), SIMD2(0.75, 0.65), SIMD2(0.55, 0.15), SIMD2(0.35, 0.80), SIMD2(0.90, 0.30)], groundColor: RGBA(0x001220)),
        .init(id: "bloom", name: "Bloom", style: .orbs, colors: [RGBA(0xFF7A59), RGBA(0xFFC75F), RGBA(0xF9A8D4), RGBA(0x93C5FD)], groundColor: RGBA(0xFDF6EC)),
        .init(id: "neon", name: "Neon", style: .orbs, colors: [RGBA(0xFF00A8), RGBA(0x00E5FF), RGBA(0x7B2CFF), RGBA(0xFF6B00)], groundColor: RGBA(0x07030F)),
        .init(id: "matcha", name: "Matcha", style: .orbs, colors: [RGBA(0x5F7A3A), RGBA(0xA3B86C), RGBA(0xF2E8CF), RGBA(0x2F4A28)], groundColor: RGBA(0xE9EFE2)),
        .init(id: "horizon", name: "Horizon", style: .linear, colors: [RGBA(0x0F172A), RGBA(0x7C3AED), RGBA(0xF472B6), RGBA(0xFDBA74)], angle: 90),
        .init(id: "cobalt", name: "Cobalt", style: .radial, colors: [RGBA(0xE0F2FE), RGBA(0x38BDF8), RGBA(0x1D4ED8), RGBA(0x0B1238), RGBA(0x020414)], center: SIMD2(0.5, 0.62)),
        .init(id: "solar", name: "Solar", style: .radial, colors: [RGBA(0xFFF7D6), RGBA(0xFFD166), RGBA(0xFF7B00), RGBA(0x9D0208), RGBA(0x1B0000)], center: SIMD2(0.5, 0.82)),
        .init(id: "prism", name: "Prism", style: .conic, colors: [RGBA(0xFF6B6B), RGBA(0xFFD93D), RGBA(0x6BCB77), RGBA(0x4D96FF), RGBA(0xC77DFF)]),
        .init(id: "reeded", name: "Reeded", style: .mesh, colors: [RGBA(0xFF5E62), RGBA(0xFF9966), RGBA(0x5B86E5), RGBA(0x36D1DC), RGBA(0x1A1A2E)]),
        .init(id: "retro", name: "Arcade", style: .fluid, colors: [RGBA(0x1B1035), RGBA(0xFF5E78), RGBA(0xFFD166), RGBA(0x06D6A0)]),
        .init(id: "mosaic", name: "Mosaic", style: .waves, colors: [RGBA(0x0D1B2A), RGBA(0x415A77), RGBA(0xE0E1DD), RGBA(0xFF6B35)], angle: 30),
    ]
}
