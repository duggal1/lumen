import SwiftUI

enum Bitmap {
    static let check = ["......#", ".....#.", "#...#..", ".#.#...", "..#...."]
    static let disc = ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
    static let arrowRight = ["....#..", ".....#.", "#######", ".....#.", "....#.."]
    static let failed = ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
    static let bang = ["..#..", "..#..", "..#..", ".....", "..#.."]
    /// The lens is the aperture at dialog scale: rim in accent, head in white.
    static let lens = ["..###..", ".#...#.", "#.....#", "#..W..#", "#.....#", ".#...#.", "..###.."]
}

private func cellFill(_ c: inout GraphicsContext, _ r: CGRect, _ color: Color) {
    c.fill(Path(r), with: .color(color), style: FillStyle(antialiased: false))
}
struct PixelBitmap: View {
    let rows: [String]; var cell: CGFloat = 2; var color: Color = Tok.text
    var body: some View {
        Canvas { c, _ in
            for (y, r) in rows.enumerated() { for (x, ch) in r.enumerated() where ch == "#" || ch == "W" {
                cellFill(&c, CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell), ch == "W" ? Tok.text : color)
            } }
        }.frame(width: CGFloat(rows[0].count) * cell, height: CGFloat(rows.count) * cell)
    }
}

/// 7 x 7 lens: dialog headers and pixels badges.
struct PixelLens: View {
    var cell: CGFloat = 2
    var body: some View { PixelBitmap(rows: Bitmap.lens, cell: cell, color: Tok.accent) }
}

/// 11 x 11 frame lock: empty states. Corners are brackets, centre is the head, edge midpoints are dust.
struct FrameLock: View {
    var cell: CGFloat = 4
    private let rows = [
        "###.......###",
        "#...........#",
        "#...........#",
        ".............",
        "......:......",
        ".....:W:.....",
        "......:......",
        ".............",
        "#...........#",
        "#...........#",
        "###.......###",
    ]
    var body: some View {
        Canvas { c, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let color = ch == "W" ? Tok.text : ch == ":" ? Tok.controlPressed : Tok.accent
                    cellFill(&c, CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell), color)
                }
            }
        }
        .frame(width: 11 * cell, height: 11 * cell)
        .accessibilityHidden(true)
    }
}

/// Selection is four corner brackets built from 2 pt cells, never an outline.
struct CornerBrackets: View {
    var cell: CGFloat = 2
    var arm: Int = 4
    var color: Color = Tok.accent
    var body: some View {
        Canvas { c, size in
            let t = cell
            func block(_ x: CGFloat, _ y: CGFloat) {
                cellFill(&c, CGRect(x: x, y: y, width: t, height: t), color)
            }
            let maxX = size.width - t, maxY = size.height - t
            for i in 0..<arm {
                let d = CGFloat(i) * t
                block(d, 0); block(0, d)                       // top left
                block(maxX - d, 0); block(maxX, d)             // top right
                block(d, maxY); block(0, maxY - d)             // bottom left
                block(maxX - d, maxY); block(maxX, maxY - d)   // bottom right
            }
        }
        .accessibilityHidden(true)
    }
}

/// Silence is a dotted line, never a dead slab.
struct DustLine: View {
    var body: some View {
        Canvas { c, size in
            var x: CGFloat = 0
            while x < size.width {
                cellFill(&c, CGRect(x: x, y: (size.height - 1) / 2, width: 1, height: 1), Tok.controlPressed)
                x += 4
            }
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

/// Three 2 pt cells stepping every 160 ms. Indeterminate waits only.

/// The title aperture: eight orange cells surrounding the head.
struct PixelStop: View {
    var cell: CGFloat = 2
    var body: some View {
        Canvas { c, _ in
            for j in 0..<3 { for i in 0..<3 {
                cellFill(&c, CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell), i == 1 && j == 1 ? Tok.text : Tok.accent)
            } }
        }.frame(width: cell * 3, height: cell * 3)
    }
}

struct PageTitle: View {
    let text: String
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(text).font(AppType.page).tracking(-1.4).foregroundStyle(Tok.text)
            PixelStop().alignmentGuide(.lastTextBaseline) { $0[.bottom] }
        }.accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

struct NotchedRect: Shape {
    var step: CGFloat = 2
    func path(in r: CGRect) -> Path {
        let s = step; var p = Path()
        p.move(to: CGPoint(x: r.minX + s, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - s)); p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - s)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + s)); p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.closeSubpath(); return p
    }
}

enum BadgeKind { case active, ok, failed, caution }
struct PixelBadge: View {
    let kind: BadgeKind, text: String
    var body: some View {
        let (bg, fg, bm): (Color, Color, [String]) = switch kind {
        case .active: (Tok.accentSoft, Tok.accentText, Bitmap.disc)
        case .ok: (Tok.control, Tok.text2, Bitmap.check)
        case .failed: (Tok.control, Tok.statusBad, Bitmap.failed)
        case .caution: (Tok.control, Tok.text2, Bitmap.bang)
        }
        HStack(spacing: 6) { PixelBitmap(rows: bm, cell: 1, color: fg); Text(text).font(AppType.caption).foregroundStyle(fg) }
            .padding(.horizontal, 8).frame(height: 20).background(NotchedRect().fill(bg))
    }
}

/// Mic level: 12 cells, lit cells orange, newest lit cell white. Silence is dust.
struct PixelMeter: View {
    let level: Float
    var body: some View {
        Canvas { c, _ in
            let lit = Int((min(max(level * 4, 0), 1)).squareRoot() * 12)
            for i in 0..<12 {
                let on = i < lit, head = on && i == lit - 1
                let h: CGFloat = on ? 8 : 2
                cellFill(&c, CGRect(x: CGFloat(i) * 4, y: (8 - h) / 2, width: 3, height: h), head ? Tok.text : on ? Ramp.o[3] : Tok.controlPressed)
            }
        }.frame(width: 48, height: 8)
    }
}

/// Three 2 pt cells stepping every 160 ms. Indeterminate waits only.
struct PixelWait: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.16)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.16) % 3
            Canvas { c, _ in for i in 0..<3 { cellFill(&c, CGRect(x: CGFloat(i) * 6, y: 0, width: 2, height: 2), i == step ? Ramp.o[3] : Tok.controlPressed) } }
                .frame(width: 14, height: 2)
        }.accessibilityLabel("Loading")
    }
}
