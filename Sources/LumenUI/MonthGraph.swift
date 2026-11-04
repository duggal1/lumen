import SwiftUI

/// Recording activity arranged in calendar weeks, from this month through the 15th of next month.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Date?

    private static let calendar = Calendar.current
    private let pitch: CGFloat = 24

    private var days: [Date] { Self.window() }
    private var offset: Int {
        guard let first = days.first else { return 0 }
        return (Self.calendar.component(.weekday, from: first) - Self.calendar.firstWeekday + 7) % 7
    }
    private var weekCount: Int { (offset + days.count + 6) / 7 }
    private var ceiling: Double {
        let values = minutes.values.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return 10 }
        return max(values[Int((Double(values.count - 1) * 0.9).rounded(.up))], 10)
    }

    var body: some View {
        let dates = days
        HStack(alignment: .top, spacing: Space.s2) {
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(height: Space.s5)
                ForEach(0..<7, id: \.self) { row in
                    Text(weekdayLabel(row))
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(width: 24, height: pitch, alignment: .trailing)
                }
            }.accessibilityHidden(true)

            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<weekCount, id: \.self) { week in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(monthLabel(week, days: dates))
                            .font(AppType.caption).foregroundStyle(Tok.text2)
                            .fixedSize().frame(width: pitch, height: Space.s5, alignment: .leading)
                            .accessibilityHidden(true)
                        ForEach(0..<7, id: \.self) { row in
                            let index = week * 7 + row - offset
                            if dates.indices.contains(index) {
                                dayButton(dates[index])
                            } else {
                                Color.clear.frame(width: pitch, height: pitch).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording activity, this month and next")
    }

    private func dayButton(_ day: Date) -> some View {
        let today = Self.calendar.startOfDay(for: .now)
        let future = day > today
        let value = minutes[day] ?? 0
        let active = selected == day || hovered == day
        let color: Color = future ? Tok.controlPressed : value > 0 ? Ramp.heat[level(value)] : Tok.controlPressed
        return Button {
            selected = selected == day ? nil : day
            hovered = selected
        } label: {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: Radius.field).fill(Tok.control)
                        .frame(width: pitch, height: pitch)
                }
                PixelDot(color: color, size: value > 0 && !future ? 8 : future ? 2 : 4)
                if Self.calendar.isDateInToday(day) {
                    Rectangle().fill(Tok.text).frame(width: 2, height: 2).offset(x: 0, y: 0)
                }
            }
            .frame(width: pitch, height: pitch).contentShape(Rectangle())
        }
        .buttonStyle(ActivityPressStyle())
        .pointerStyle(.link)
        .onHover { inside in hovered = inside ? day : selected }
        .animation(reduceMotion ? nil : Motion.hoverIn, value: active)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(future ? "Upcoming" : "\(Int(value.rounded())) minutes recorded")
        .accessibilityAddTraits(selected == day ? .isSelected : [])
    }

    private func level(_ value: Double) -> Int {
        let fraction = value / ceiling
        if fraction <= 0.25 { return 0 }
        if fraction <= 0.5 { return 1 }
        if fraction <= 0.8 { return 2 }
        return 3
    }

    private func weekdayLabel(_ row: Int) -> String {
        guard row == 1 || row == 3 || row == 5 else { return "" }
        let weekday = (Self.calendar.firstWeekday - 1 + row) % 7
        return Self.calendar.shortWeekdaySymbols[weekday]
    }

    private func monthLabel(_ week: Int, days: [Date]) -> String {
        let start = max(0, week * 7 - offset), end = min(days.count, (week + 1) * 7 - offset)
        guard start < end else { return "" }
        if week == 0 { return days[start].formatted(.dateTime.month(.abbreviated)) }
        guard let first = days[start..<end].first(where: { Self.calendar.component(.day, from: $0) == 1 }) else { return "" }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    static func window() -> [Date] {
        let cal = calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? cal.startOfDay(for: .now)
        let next = cal.date(byAdding: .month, value: 1, to: first) ?? first
        let last = cal.date(byAdding: .day, value: 14, to: next) ?? next
        var out: [Date] = [], d = first
        while d <= last { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d) ?? last.addingTimeInterval(86_400) }
        return out
    }
}

/// A circular mark drawn on a whole-point lattice, without antialiased edges.
private struct PixelDot: View {
    let color: Color
    let size: Int
    var body: some View {
        Canvas { context, _ in
            let center = Double(size - 1) / 2
            for y in 0..<size {
                for x in 0..<size where hypot(Double(x) - center, Double(y) - center) <= Double(size) / 2 {
                    context.fill(Path(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)), with: .color(color),
                                 style: FillStyle(antialiased: false))
                }
            }
        }
        .frame(width: CGFloat(size), height: CGFloat(size))
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
