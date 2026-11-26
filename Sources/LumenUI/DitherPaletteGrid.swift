import SwiftUI
import LumenProject

struct DitherPaletteGrid: View {
    let model: EditorModel
    let kind: BackgroundKind

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(DitherPalettes.all.enumerated()), id: \.offset) { entry in
                let palette = entry.element
                let selected = model.timeline.style.background == kind && model.timeline.style.colors == palette.1
                Button {
                    model.edit { timeline in
                        timeline.style.background = kind
                        timeline.style.colors = palette.1
                    }
                } label: {
                    VStack(spacing: 6) {
                        PalettePreview(colors: palette.1,
                                       dither: kind == .dither,
                                       saturation: model.timeline.style.ditherSaturation)
                            .aspectRatio(1.6, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.field))
                            .overlay(alignment: .topTrailing) { if selected { PixelSymbol("checkmark.circle.fill", size: 14).foregroundStyle(.white).padding(5) } }
                        Text(palette.0)
                            .font(AppType.caption)
                            .foregroundStyle(TileSelection.ink(selected))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .focusRing()
                .accessibilityLabel(palette.0)
                .accessibilityValue(selected ? "Selected" : "")
            }
        }
    }
}

private struct PalettePreview: View {
    let colors: [RGBA]
    let dither: Bool
    let saturation: Bool

    private static let bayer = [
        0, 48, 12, 60, 3, 51, 15, 63,
        32, 16, 44, 28, 35, 19, 47, 31,
        8, 56, 4, 52, 11, 59, 7, 55,
        40, 24, 36, 20, 43, 27, 39, 23,
        2, 50, 14, 62, 1, 49, 13, 61,
        34, 18, 46, 30, 33, 17, 45, 29,
        10, 58, 6, 54, 9, 57, 5, 53,
        42, 26, 38, 22, 41, 25, 37, 21
    ]

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            guard colors.count >= 2 else { return }
            let cell: CGFloat = 5
            let columns = max(Int(ceil(size.width / cell)), 1)
            let rows = max(Int(ceil(size.height / cell)), 1)
            let base = Self.color(colors[0], saturated: saturation)
            let weave = Self.blend(colors[0], colors[1], amount: 0.14, saturated: saturation)
            for y in 0..<rows {
                for x in 0..<columns {
                    let color: Color
                    if dither {
                        let u = (Double(x) / Double(columns) - 0.5) * Double(size.width / size.height)
                        let v = Double(y) / Double(rows) - 0.5
                        let warp = Self.field(u, v)
                        let field = Self.field(u + warp, v + warp)
                        let value = min(max(0.5 + (field - 0.45) * 2.4, 0), 1)
                        let threshold = Double(Self.bayer[(y & 7) * 8 + (x & 7)]) / 64
                        let scaled = value * Double(colors.count - 1)
                        let lower = min(Int(scaled), colors.count - 2)
                        let fraction = scaled - Double(lower)
                        let index = fraction > threshold ? lower + 1 : lower
                        color = Self.color(colors[index], saturated: saturation)
                    } else {
                        color = (x + y).isMultiple(of: 2) ? base : weave
                    }
                    context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                             width: cell, height: cell)), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func color(_ value: RGBA, saturated: Bool) -> Color {
        var r = Double(value.r), g = Double(value.g), b = Double(value.b)
        if !saturated {
            let gray = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = gray; g = gray; b = gray
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: Double(value.a))
    }

    private static func blend(_ first: RGBA, _ second: RGBA, amount: Double, saturated: Bool) -> Color {
        let r = Double(first.r) * (1 - amount) + Double(second.r) * amount
        let g = Double(first.g) * (1 - amount) + Double(second.g) * amount
        let b = Double(first.b) * (1 - amount) + Double(second.b) * amount
        return color(RGBA(r: Float(r), g: Float(g), b: Float(b)), saturated: saturated)
    }

    private static func field(_ x: Double, _ y: Double) -> Double {
        var px = x, py = y, amplitude = 1.0, total = 0.0, weight = 0.0
        for _ in 0..<4 {
            total += amplitude * noise(px, py)
            weight += amplitude
            px *= 3; py *= 3; amplitude *= 0.3
        }
        return total / weight
    }

    private static func noise(_ x: Double, _ y: Double) -> Double {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * sx
        let bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    private static func hash(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 127.1 + y * 311.7) * 43_758.5453
        return value - floor(value)
    }
}
