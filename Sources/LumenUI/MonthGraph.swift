import SwiftUI

/// Month heat map: 1st of this month through the 15th of next month.
/// Squares ≤20 pt, 4 pt gaps, 12 between months, month labels at each
/// month's first cell. Empty days are gaps, future days dust, today a
/// white pixel on a control cell. Hover turns the subtitle into a readout.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Date?
    private static let calendar = Calendar.current

    private var days: [Date] {
        let cal = Self.calendar
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? cal.startOfDay(for: .now)
        let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let last = cal.date(byAdding: .day, value: 15, to: nextMonth) ?? nextMonth
        var out: [Date] = []
        var d = monthStart
        while d <= last {
            out.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let cell = max(6, min(20, floor((g.size.width - 12 * 2) / Double(days.count + 2))))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    dayCell(day: day, cell: cell)
                        .padding(.trailing, Self.calendar.component(.day, from: day) == 1 && index > 0 ? 12 : 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording activity by day")
    }

    private func dayCell(day: Date, cell: CGFloat) -> some View {
        let cal = Self.calendar
        let today = cal.startOfDay(for: .now)
        let future = day > today
        let value = minutes[day] ?? 0
        let isToday = day == today
        let level = heatLevel(value: value)
        let firstOfMonth = cal.component(.day, from: day) == 1
        return Button {
            selected = selected == day ? nil : day
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(firstOfMonth ? day.formatted(.dateTime.month(.abbreviated)) : " ")
                    .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                ZStack {
                    if future {
                        ActivityDot(color: Tok.controlPressed, size: Int(cell))
                    } else if value > 0 {
                        ActivityDot(color: Ramp.heat[level], size: Int(cell))
                    } else {
                        ActivityDot(color: .clear, size: Int(cell))
                    }
                    if isToday { ActivityDot(color: Tok.text, size: 4) }
                }
                .frame(width: cell, height: cell)
                .background(RoundedRectangle(cornerRadius: 2).fill(selected == day ? Tok.control : .clear))
            }
            .frame(width: cell, height: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActivityPressStyle())
        .pointerStyle(.link)
        .onHover { inside in if inside { hovered = day } }
        .animation(reduceMotion ? nil : Motion.hoverIn, value: selected == day)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(future ? "Upcoming" : "\(Int(value.rounded())) minutes recorded")
        .accessibilityAddTraits(selected == day ? .isSelected : [])
    }

    private func heatLevel(value: Double) -> Int {
        let days = minutes.values.sorted()
        let peak = max(days.last ?? 10, 10)
        if value <= peak * 0.25 { return 0 }
        if value <= peak * 0.5 { return 1 }
        if value <= peak * 0.8 { return 2 }
        return 3
    }
}

/// A clean, fully rounded activity marker.
private struct ActivityDot: View {
    let color: Color
    let size: Int
    var body: some View {
        Circle().fill(color).frame(width: CGFloat(size), height: CGFloat(size))
        .accessibilityHidden(true)
    }
}

private struct ActivityPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(reduceMotion ? nil : Motion.hoverIn, value: configuration.isPressed)
    }
}
