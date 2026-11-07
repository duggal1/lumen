import SwiftUI
import AppKit

public struct ActivityDay: Equatable, Sendable {
    public let date: Date
    public let minutes: Double
    public let level: Int
    public init(date: Date, minutes: Double, level: Int) {
        self.date = date; self.minutes = minutes; self.level = level
    }
}

public enum ActivityLevel {
    /// Absolute minutes buckets (predictable, ultra-clean):
    /// 0 = neutral, 1 = light orange (one short video),
    /// 2 = medium, 3 = bright, 4 = brightest (heavy day).
    /// Decision: absolute thresholds override the old quantile rule so
    /// a lone 2-minute day stays light instead of saturating to level 4.
    public static func assign(_ values: [Double]) -> [Int] {
        values.map { v in
            if v <= 0 { return 0 }
            if v < 5 { return 1 }
            if v < 15 { return 2 }
            if v < 45 { return 3 }
            return 4
        }
    }
}

public struct ActivityBlock {
    public struct Cell: Sendable { public let col: Int; public let row: Int; public let day: ActivityDay }
    public let month: Date
    public let cols: Int
    public let cells: [Cell]
    public init(month: Date, cols: Int, cells: [Cell]) { self.month = month; self.cols = cols; self.cells = cells }
    public static func make(_ days: [ActivityDay], calendar: Calendar = .current) -> [ActivityBlock] {
        var byMonth: [Date: [ActivityDay]] = [:]
        for d in days {
            let m = calendar.dateInterval(of: .month, for: d.date)?.start ?? d.date
            byMonth[m, default: []].append(d)
        }
        return byMonth.keys.sorted().map { m in
            let offset = (calendar.component(.weekday, from: m) - calendar.firstWeekday + 7) % 7
            let raw = byMonth[m, default: []].sorted { $0.date < $1.date }.map { d -> (Int, Int, ActivityDay) in
                let i = offset + calendar.component(.day, from: d.date) - 1
                return (i / 7, i % 7, d)
            }
            let minCol = raw.map(\.0).min() ?? 0
            let maxCol = raw.map(\.0).max() ?? 0
            return ActivityBlock(month: m, cols: maxCol - minCol + 1,
                                 cells: raw.map { Cell(col: $0.0 - minCol, row: $0.1, day: $0.2) })
        }
    }
}

struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.displayScale) private var scale
    @State private var width: CGFloat = 0
    @State var reveal: CGFloat = 1

    static let gap: CGFloat = 2
    static let monthGap: CGFloat = 8
    static let minCell: CGFloat = 6
    static let maxCell: CGFloat = 8
    static let rows = 7

    private var calendar: Calendar { .current }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? calendar.startOfDay(for: .now)
    }

    var days: [ActivityDay] {
        let cal = calendar
        let today = cal.startOfDay(for: .now)
        var out: [Date] = []
        var d = monthStart
        while d <= today {
            out.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        let raw = out.map { minutes[$0] ?? 0 }
        let levels = ActivityLevel.assign(raw)
        return zip(out, zip(raw, levels)).map { ActivityDay(date: $0.0, minutes: $0.1.0, level: $0.1.1) }
    }

    struct Layout {
        let cell: CGFloat
        let pitch: CGFloat
        let height: CGFloat
        let originX: [CGFloat]
        let blocks: [ActivityBlock]
        let totalWidth: CGFloat
        init(width: CGFloat, allBlocks: [ActivityBlock], scale: CGFloat) {
            var blocks = allBlocks
            let totalCols = blocks.reduce(0) { $0 + $1.cols }
            let gapCount = max(blocks.count - 1, 0)
            let fixed = CGFloat(max(totalCols - max(blocks.count, 1), 0)) * MonthGraph.gap + CGFloat(gapCount) * MonthGraph.monthGap
            var cell = max(floor(((width - fixed) / CGFloat(max(totalCols, 1))) * scale) / scale, 1)
            cell = max(MonthGraph.minCell, min(MonthGraph.maxCell, cell))
            while blocks.count > 1 {
                let cols = blocks.reduce(0) { $0 + $1.cols }
                let need = CGFloat(cols) * MonthGraph.minCell + CGFloat(max(cols - blocks.count, 0)) * MonthGraph.gap + CGFloat(max(blocks.count - 1, 0)) * MonthGraph.monthGap
                if need <= width + 1 { break }
                blocks.removeFirst()
            }
            let cols = max(blocks.reduce(0) { $0 + $1.cols }, 1)
            let fixed2 = CGFloat(max(cols - max(blocks.count, 1), 0)) * MonthGraph.gap + CGFloat(max(blocks.count - 1, 0)) * MonthGraph.monthGap
            var c2 = max(floor(((width - fixed2) / CGFloat(cols)) * scale) / scale, 1)
            c2 = max(MonthGraph.minCell, min(MonthGraph.maxCell, c2))
            // Spread extra into month gaps so grid spans edge to edge.
            let natural = CGFloat(cols) * c2 + CGFloat(max(cols - max(blocks.count, 1), 0)) * MonthGraph.gap + CGFloat(max(blocks.count - 1, 0)) * MonthGraph.monthGap
            let extra = max(0, width - natural)
            let effectiveMonthGap = blocks.count > 1 ? MonthGraph.monthGap + extra / CGFloat(blocks.count - 1) : MonthGraph.monthGap
            cell = c2
            self.blocks = blocks
            self.cell = cell
            self.pitch = cell + MonthGraph.gap
            self.height = CGFloat(MonthGraph.rows) * cell + CGFloat(MonthGraph.rows - 1) * MonthGraph.gap
            var x: CGFloat = 0
            var xs: [CGFloat] = []
            for b in blocks {
                xs.append(x)
                x += CGFloat(b.cols) * cell + CGFloat(b.cols - 1) * MonthGraph.gap
                x += effectiveMonthGap
            }
            originX = xs
            totalWidth = blocks.isEmpty ? width : (natural + extra)
        }
    }

    private var blocks: [ActivityBlock] { ActivityBlock.make(days, calendar: calendar) }

    private func ramp(_ level: Int) -> Color {
        // Dot intensity ramp (Ramp.heat tokens, mixed — never opacity stacks).
        // 0 = neutral dust, 1 = light orange, 4 = brightest signal orange.
        switch level {
        case 1: return Ramp.heat[0]
        case 2: return Ramp.heat[1]
        case 3: return Ramp.heat[2]
        case 4: return Ramp.heat[3]
        default: return Tok.controlPressed
        }
    }

    var body: some View {
        let allBlocks = blocks
        VStack(alignment: .leading, spacing: Space.s2) {
            header(width: width, month: monthStart)
            VStack(alignment: .leading, spacing: Space.s1) {
                GeometryReader { g in
                    let m = Layout(width: g.size.width, allBlocks: allBlocks, scale: scale)
                    Canvas { ctx, _ in draw(&ctx, m) }
                        .frame(width: g.size.width, height: m.height)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hovered = day(at: p, m)
                            case .ended: hovered = nil
                            }
                        }
                        .onAppear { width = g.size.width }
                }
                .frame(height: layoutHeight(width: width, blocks: allBlocks))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .opacity(width > 0 ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes recorded per day in \(monthStart.formatted(.dateTime.month().year()))")
    }

    private func layoutHeight(width: CGFloat, blocks: [ActivityBlock]) -> CGFloat {
        let m = Layout(width: max(width, 1), allBlocks: blocks, scale: scale)
        return m.height
    }

    @ViewBuilder private func header(width: CGFloat, month: Date) -> some View {
        HStack(spacing: Space.s2) {
            Text(month.formatted(.dateTime.month().year())).font(AppType.title).foregroundStyle(Tok.text)
            Spacer(minLength: Space.s4)
            if width >= 420 { legend }
        }
        VStack(alignment: .leading, spacing: 2) {
            readout.frame(height: 16, alignment: .leading)
        }
    }

    @ViewBuilder private var readout: some View {
        if let d = hovered {
            let v = Int((minutes[calendar.startOfDay(for: d)] ?? 0).rounded())
            Text(v > 0 ? "\(d.formatted(.dateTime.month(.abbreviated).day())) · \(v) min" : "\(d.formatted(.dateTime.month(.abbreviated).day())) · No recording")
                .font(AppType.caption).foregroundStyle(Tok.text2)
        } else {
            Text("Minutes recorded per day").font(AppType.caption).foregroundStyle(Tok.text2)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(ramp(i)).frame(width: 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func draw(_ ctx: inout GraphicsContext, _ m: Layout) {
        for (bi, b) in m.blocks.enumerated() {
            for c in b.cells {
                let cx = m.originX[bi] + CGFloat(c.col) * m.pitch + m.cell / 2
                let cy = CGFloat(c.row) * m.pitch + m.cell / 2
                // Minimal dot: fixed 4pt even-snapped circle, sharp and light.
                let d: CGFloat = 4
                let rect = CGRect(x: snap(cx - d / 2), y: snap(cy - d / 2), width: d, height: d)
                let dot = Path(ellipseIn: rect)
                let isHover = hovered.map { calendar.isDate($0, inSameDayAs: c.day.date) } ?? false
                ctx.fill(dot, with: .color(ramp(max(0, min(c.day.level, 4)))))
                if isHover {
                    ctx.stroke(dot, with: .color(Tok.text2), lineWidth: 1)
                }
            }
        }
    }

    private func day(at p: CGPoint, _ m: Layout) -> Date? {
        for (bi, b) in m.blocks.enumerated() {
            for c in b.cells {
                let r = CGRect(x: m.originX[bi] + CGFloat(c.col) * m.pitch - Self.gap / 2,
                               y: CGFloat(c.row) * m.pitch - Self.gap / 2,
                               width: m.pitch, height: m.pitch)
                if r.contains(p) { return c.day.date }
            }
        }
        return nil
    }
}
