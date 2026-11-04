import SwiftUI

/// One week of recorded activity, with navigation to other weeks.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Date?
    @State private var weekOffset = 0

    private static let calendar = Calendar.current
    private let rowHeight: CGFloat = 48

    private var days: [Date] {
        let cal = Self.calendar
        let start = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? cal.startOfDay(for: .now)
        guard let week = cal.date(byAdding: .weekOfYear, value: weekOffset, to: start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week) }
    }

    private var weekLabel: String {
        guard let first = days.first, let last = days.last else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s1) {
                Text(weekLabel).font(AppType.caption).foregroundStyle(Tok.text2)
                Spacer()
                LIconButton(icon: "chevron.left", label: "Previous week") { changeWeek(-1) }
                LIconButton(icon: "chevron.right", label: "Next week") { changeWeek(1) }
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    dayButton(day)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.control))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Weekly recording activity")
    }

    private func changeWeek(_ amount: Int) {
        weekOffset += amount
        selected = nil
        hovered = nil
    }

    private func dayButton(_ day: Date) -> some View {
        let future = day > Self.calendar.startOfDay(for: .now)
        let value = minutes[day] ?? 0
        let active = selected == day || hovered == day
        return Button {
            selected = selected == day ? nil : day
            hovered = selected
        } label: {
            VStack(spacing: Space.s1) {
                PixelDot(color: value > 0 && !future ? Tok.accent : .white, size: 10)
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: rowHeight)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(active ? Tok.controlHover : .clear))
            .contentShape(Rectangle())
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
