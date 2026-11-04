import SwiftUI

/// Recording activity across the current and following calendar months.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Date?

    private static let calendar = Calendar.current
    private let rowHeight: CGFloat = 28
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var months: [Date] {
        let cal = Self.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? cal.startOfDay(for: .now)
        return [first, cal.date(byAdding: .month, value: 1, to: first) ?? first]
    }
    private var ceiling: Double {
        let values = minutes.values.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return 10 }
        return max(values[Int((Double(values.count - 1) * 0.9).rounded(.up))], 10)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s6) {
            ForEach(months, id: \.self) { month in
                monthGrid(month)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording activity, this month and next")
    }

    private func monthGrid(_ month: Date) -> some View {
        let cal = Self.calendar
        let offset = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: month)?.count ?? 0
        let slots = ((offset + count + 6) / 7) * 7
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text(month.formatted(.dateTime.month(.wide)))
                .font(AppType.label).foregroundStyle(Tok.text)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(0..<7, id: \.self) { weekday in
                    let index = (cal.firstWeekday - 1 + weekday) % 7
                    Text(cal.veryShortWeekdaySymbols[index])
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity).frame(height: rowHeight)
                        .accessibilityHidden(true)
                }
                ForEach(0..<slots, id: \.self) { slot in
                    let day = slot - offset
                    if day >= 0, day < count, let date = cal.date(byAdding: .day, value: day, to: month) {
                        dayButton(date)
                    } else {
                        Color.clear.frame(height: rowHeight).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let future = day > Self.calendar.startOfDay(for: .now)
        let value = minutes[day] ?? 0
        let active = selected == day || hovered == day
        let dotSize = future ? 4 : value > 0 ? (value / ceiling > 0.5 ? 16 : 12) : 6
        return Button {
            selected = selected == day ? nil : day
            hovered = selected
        } label: {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: Radius.field).fill(Tok.control)
                        .frame(width: rowHeight, height: rowHeight)
                }
                PixelDot(color: value > 0 && !future ? Tok.accent : Tok.controlPressed, size: dotSize)
                if Self.calendar.isDateInToday(day) {
                    Rectangle().fill(Tok.text).frame(width: 2, height: 2)
                }
            }
            .frame(maxWidth: .infinity).frame(height: rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(ActivityPressStyle())
        .pointerStyle(.link)
        .onHover { inside in hovered = inside ? day : selected }
        .animation(reduceMotion ? nil : Motion.hoverIn, value: active)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(future ? "Upcoming" : "\(Int(value.rounded())) minutes recorded")
        .accessibilityAddTraits(selected == day ? .isSelected : [])
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
