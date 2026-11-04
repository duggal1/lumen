import SwiftUI

/// The month graph: 1st of this month through the 15th of next month, one cell per day.
/// Recorded days use the activity colour. Zero is a gap, never a recorded day.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private static let calendar = Calendar.current
    private static let cellGap: CGFloat = 4
    private static let monthGap: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            let days = Self.window()
            let lay = layout(days, width: g.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (i, day) in days.enumerated() where i < shown {
                        let value = minutes[Self.calendar.startOfDay(for: day)] ?? 0
                        let future = day > Self.calendar.startOfDay(for: .now)
                        let r = CGRect(x: lay.xs[i], y: 20, width: lay.cell, height: lay.cell)
                        if future {
                            cell(&ctx, CGRect(x: r.minX + 2, y: r.minY + (lay.cell - 2) / 2, width: 2, height: 2), Tok.activity)
                        } else if Self.calendar.isDateInToday(day) {
                            cell(&ctx, r, value > 0 ? Tok.activity : Tok.control)
                            cell(&ctx, CGRect(x: r.midX - 1, y: r.midY - 1, width: 2, height: 2), Tok.text)
                        } else if value > 0 {
                            cell(&ctx, r, Tok.activity)
                        }
                        // zero minutes on a past day stays a gap
                    }
                }
                .accessibilityHidden(true)
                ForEach(Array(days.enumerated()), id: \.element) { i, day in
                    if Self.calendar.component(.day, from: day) == 1 {
                        Text(day.formatted(.dateTime.month(.abbreviated)))
                            .font(AppType.caption).foregroundStyle(Tok.text2)
                            .offset(x: lay.xs[i], y: 0)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let next = day(at: p, days: days, layout: lay)
                    if hovered != next { hovered = next }
                case .ended: hovered = nil
                }
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded time, last 46 days")
        .task {
            shown = reduceMotion ? Self.window().count : 0
            guard !reduceMotion, shown == 0 else { return }
            let n = Self.window().count
            for step in 1...14 {
                try? await Task.sleep(for: .milliseconds(43))
                guard !Task.isCancelled else { return }
                shown = max(1, n * step / 14)
            }
            shown = n
        }
    }

    // MARK: Layout

    private struct Layout {
        var cell: CGFloat
        var xs: [CGFloat]
    }

    private func layout(_ days: [Date], width: CGFloat) -> Layout {
        guard !days.isEmpty else { return Layout(cell: 1, xs: []) }
        var gaps: CGFloat = 0
        for i in 1..<days.count {
            gaps += Self.calendar.component(.month, from: days[i]) == Self.calendar.component(.month, from: days[i - 1])
                ? Self.cellGap : Self.monthGap
        }
        let raw = (width - gaps) / CGFloat(days.count)
        let cell = max(1, min(20, raw.rounded(.down)))
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for i in days.indices {
            xs.append(x)
            if i < days.count - 1 {
                x += cell + (Self.calendar.component(.month, from: days[i + 1]) == Self.calendar.component(.month, from: days[i])
                    ? Self.cellGap : Self.monthGap)
            }
        }
        return Layout(cell: cell, xs: xs)
    }

    private func day(at p: CGPoint, days: [Date], layout: Layout) -> Date? {
        guard p.y >= 18, p.y <= 20 + layout.cell else { return nil }
        for (i, x) in layout.xs.enumerated() where p.x >= x && p.x <= x + layout.cell { return days[i] }
        return nil
    }

    private func cell(_ c: inout GraphicsContext, _ r: CGRect, _ color: Color) {
        c.fill(Path(r), with: .color(color), style: FillStyle(antialiased: false))
    }

    static func window() -> [Date] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: .now)
        let first = cal.date(from: comps) ?? cal.startOfDay(for: .now)
        let next = cal.date(byAdding: .month, value: 1, to: first) ?? first
        let last = cal.date(byAdding: .day, value: 14, to: next) ?? next
        var out: [Date] = [], d = first
        while d <= last { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d) ?? last.addingTimeInterval(86_400) }
        return out
    }
}
