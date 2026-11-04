import SwiftUI

/// One week of recorded activity, with navigation to other weeks.
struct MonthGraph: View {
    let minutes: [Date: Double]
    @Binding var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Date?
    @State private var weekOffset = 0

    private static let calendar = Calendar.current
    private let rowHeight: CGFloat = 28

    private var days: [Date] {
        let cal = Self.calendar
        let start = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? cal.startOfDay(for: .now)
        guard let week = cal.date(byAdding: .weekOfYear, value: weekOffset, to: start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week) }
    }

    var body: some View {
        HStack(spacing: 0) {
            LIconButton(icon: "chevron.left", label: "Previous week") { changeWeek(-1) }
            ForEach(days, id: \.self) { day in
                dayButton(day)
            }
            LIconButton(icon: "chevron.right", label: "Next week") { changeWeek(1) }
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
            ZStack {
                if value > 0 && !future {
                    ActivityDot(color: Tok.accent, size: 10)
                } else {
                    ActivityDot(color: Tok.controlPressed, size: 10)
                    ActivityDot(color: .white, size: 6)
                }
            }
            .frame(maxWidth: .infinity).frame(height: rowHeight)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(active ? Tok.control : .clear))
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
