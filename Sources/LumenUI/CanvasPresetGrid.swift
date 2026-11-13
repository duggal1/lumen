import SwiftUI
import LumenProject

// AGENT: Canvas styles are discoverable and selectable from the rendered previews without a menu.
struct CanvasPresetGrid: View {
    let model: EditorModel

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(CanvasPresets.all) { preset in
                let selected = model.timeline.style.background == .canvas
                    && model.timeline.style.canvasPresetID == preset.id
                Button {
                    var style = model.timeline.style
                    style.background = .canvas
                    style.canvasPresetID = preset.id
                    style.colors = preset.colors
                    style.gradientAngle = preset.angle
                    model.dispatch(.setStyle(style))
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            CanvasPresetPreview(preset: preset)
                                .padding(4)
                            if selected {
                                CornerBrackets(color: Tok.accent)
                            }
                        }
                        .aspectRatio(1.6, contentMode: .fit)
                        Text(preset.name)
                            .font(AppType.caption)
                            .foregroundStyle(selected ? Tok.text : Tok.text2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel(preset.name)
                .accessibilityValue(selected ? "Selected" : "")
                .accessibilityHint("Select this canvas background")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CanvasPresetPreview: View {
    let preset: CanvasPreset

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let cell: CGFloat = 2
            let columns = max(Int(ceil(size.width / cell)), 1)
            let rows = max(Int(ceil(size.height / cell)), 1)
            for y in 0..<rows {
                for x in 0..<columns {
                    let u = (Double(x) + 0.5) / Double(columns)
                    let v = (Double(y) + 0.5) / Double(rows)
                    let color = Self.color(Self.sample(preset, u: u, v: v, aspect: Double(size.width / size.height)))
                    context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                             width: cell, height: cell)),
                                    with: .color(color), style: FillStyle(antialiased: false))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.field))
        .accessibilityHidden(true)
    }

    private static func sample(_ preset: CanvasPreset, u: Double, v: Double, aspect: Double) -> RGBA {
        let p = SIMD2((u - 0.5) * aspect, v - 0.5)
        switch preset.style {
        case .mesh:
            return weighted(preset, u: u, v: v, aspect: aspect, factor: 7)
        case .fluid:
            let warp = fbm(p.x * 1.7 + 1.4, p.y * 1.7 - 0.8)
            let field = fbm(p.x * 2.5 + (warp - 0.5) * 1.8,
                            p.y * 2.5 + (warp - 0.5) * 1.8)
            return ramp(preset.colors, at: smoothstep(0.08, 0.92, field))
        case .waves:
            let angle = preset.angle * .pi / 180
            let along = p.x * cos(angle) + p.y * sin(angle)
            let across = -p.x * sin(angle) + p.y * cos(angle)
            let wave = sin(across * 12 + sin(along * 5) * 2 + noise(p.x * 2, p.y * 2) * 1.2)
            return ramp(preset.colors, at: smoothstep(-0.95, 0.95, wave))
        case .orbs:
            return weighted(preset, u: u, v: v, aspect: aspect, factor: 22, ground: true)
        case .linear:
            let angle = preset.angle * .pi / 180
            let directionX = cos(angle), directionY = sin(angle)
            let t = ((u - 0.5) * directionX + (v - 0.5) * directionY)
                / (abs(directionX) + abs(directionY)) + 0.5
            return ramp(preset.colors, at: t)
        case .radial:
            let dx = (u - preset.center.x) * aspect, dy = v - preset.center.y
            return ramp(preset.colors, at: 1 - min(hypot(dx, dy) / 1.05, 1))
        case .conic:
            let phase = atan2(p.y, p.x) / (2 * .pi) + 0.5
            return wheel(preset.colors, at: phase)
        }
    }

    private static func weighted(_ preset: CanvasPreset, u: Double, v: Double, aspect: Double,
                                 factor: Double, ground: Bool = false) -> RGBA {
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        guard !preset.colors.isEmpty, !preset.points.isEmpty else { return RGBA(0x000000) }
        for index in 0..<6 {
            let point = preset.points[index % preset.points.count]
            let dx = (u - point.x) * aspect, dy = v - point.y
            let weight = exp(-(dx * dx + dy * dy) * factor)
            let color = preset.colors[index % preset.colors.count]
            red += Double(color.r) * weight
            green += Double(color.g) * weight
            blue += Double(color.b) * weight
            total += weight
        }
        guard total > 0 else { return preset.colors[0] }
        let blend = ground ? min(total * 0.55, 1) : 1
        let background = ground ? preset.groundColor ?? preset.colors[0] : preset.colors[0]
        return mix(background, RGBA(r: Float(red / total), g: Float(green / total), b: Float(blue / total)), blend)
    }

    private static func ramp(_ colors: [RGBA], at value: Double) -> RGBA {
        guard colors.count > 1 else { return colors[0] }
        let scaled = min(max(value, 0), 1) * Double(colors.count - 1)
        let index = min(Int(scaled), colors.count - 2)
        let t = scaled - Double(index)
        return mix(colors[index], colors[index + 1], t * t * (3 - 2 * t))
    }

    private static func wheel(_ colors: [RGBA], at value: Double) -> RGBA {
        guard !colors.isEmpty else { return RGBA(0x000000) }
        let scaled = (value - floor(value)) * Double(colors.count)
        let index = min(Int(scaled), colors.count - 1)
        let next = (index + 1) % colors.count
        return mix(colors[index], colors[next], scaled - Double(index))
    }

    private static func mix(_ first: RGBA, _ second: RGBA, _ t: Double) -> RGBA {
        let amount = Float(min(max(t, 0), 1))
        return RGBA(r: first.r + (second.r - first.r) * amount,
                    g: first.g + (second.g - first.g) * amount,
                    b: first.b + (second.b - first.b) * amount)
    }

    private static func color(_ value: RGBA) -> Color {
        Color(.sRGB, red: Double(value.r), green: Double(value.g), blue: Double(value.b), opacity: Double(value.a))
    }

    private static func fbm(_ x: Double, _ y: Double) -> Double {
        var px = x, py = y, amplitude = 1.0, value = 0.0, weight = 0.0
        for _ in 0..<4 {
            value += amplitude * noise(px, py)
            weight += amplitude
            px *= 3; py *= 3; amplitude *= 0.3
        }
        return value / weight
    }

    private static func noise(_ x: Double, _ y: Double) -> Double {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * sx, bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    private static func hash(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 127.1 + y * 311.7) * 43_758.5453
        return value - floor(value)
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
