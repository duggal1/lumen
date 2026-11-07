import SwiftUI
import AppKit

// MARK: Ledger

struct LedgerCard: View {
    let app: AppModel

    private struct Metric {
        let icon: String, label: String, value: String, note: String
    }

    private var metrics: [Metric] {
        let minutes = Int(app.totalRecorded / 60)
        let recorded = minutes >= 600 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min"
        return [
            Metric(icon: "timer", label: "Recorded", value: recorded, note: "all time"),
            Metric(icon: "film.stack", label: "Projects", value: "\(app.projects.count)", note: "in this library"),
            Metric(icon: "square.and.arrow.up", label: "Exported", value: "\(app.exportedCount)", note: "this Mac"),
            Metric(icon: "calendar", label: "Streak", value: "\(app.streak)", note: app.streak == 1 ? "day" : "days"),
        ]
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Space.s4) {
            ForEach(metrics, id: \.label) { m in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.s2) {
                        Image(systemName: m.icon).font(.system(size: 14)).frame(width: 16)
                        Text(m.label).font(AppType.caption).tracking(0)
                    }.foregroundStyle(Tok.text2)
                    Text(m.value).font(AppType.metric).tracking(-0.6).foregroundStyle(Tok.text)
                        .frame(height: 34, alignment: .top)
                    Text(m.note).font(AppType.caption).foregroundStyle(Tok.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

// MARK: Activity

struct ActivityCard: View {
    let app: AppModel
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Activity").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
            MonthGraph(minutes: app.minutesByDay, hovered: $hovered)
        }
        .card(padding: Space.s4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Recent recordings

struct RecentRecordings: View {
    let app: AppModel
    let open: (URL) -> Void
    let reveal: (URL) -> Void
    let delete: (AppModel.ProjectRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Recent recordings").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
            if app.recent.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    ForEach(app.recent) { p in
                        RecordingRow(row: p, open: { open(p.url) }, reveal: { reveal(p.url) },
                                     duplicate: { app.duplicate(p) }, delete: { delete(p) })
                    }
                }
                .padding(Space.s2)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
            }
        }
    }

    private var empty: some View {
        HStack(spacing: Space.s4) {
            PixelLens(cell: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Nothing here yet.").font(AppType.label).foregroundStyle(Tok.text)
                Text("Press ⌥⌘R to record.").font(AppType.body).foregroundStyle(Tok.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingRow: View {
    let row: AppModel.ProjectRow
    let open: () -> Void
    let reveal: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var day: String {
        let cal = Calendar.current
        if cal.isDateInToday(row.date) { return "Today" }
        if cal.isDateInYesterday(row.date) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now)), row.date >= week {
            return row.date.formatted(.dateTime.weekday(.abbreviated))
        }
        if cal.component(.year, from: row.date) == cal.component(.year, from: .now) {
            return row.date.formatted(.dateTime.month(.abbreviated).day())
        }
        return row.date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var time: String { ClockFormat.time(row.date) }

    private var duration: String {
        let total = Int(row.duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var menuItems: [MenuHost.Item] {
        [
            .init(title: "Open in Studio", icon: "slider.horizontal.below.rectangle", action: open),
            .init(title: "Reveal in Finder", icon: "folder", action: reveal),
            .init(title: "Duplicate project", icon: "plus.square.on.square", action: duplicate),
            .init(title: "Delete recording", icon: "trash", destructive: true, gapBefore: true, action: delete),
        ]
    }

    var body: some View {
        if row.unreadable {
            HStack(spacing: Space.s3) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(Tok.statusBad)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(AppType.label).tracking(-0.1).foregroundStyle(Tok.text)
                    Text("Recording didn’t finish").font(AppType.caption).foregroundStyle(Tok.text2)
                }
                Spacer(minLength: Space.s4)
                LButton(title: "Reveal in Finder", kind: .quiet, height: 28) { reveal() }
                LButton(title: "Remove", kind: .quiet, height: 28) { delete() }
            }
            .padding(.horizontal, Space.s3)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.surface))
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
        } else {
            normalRow
        }
    }

    private var normalRow: some View {
        HStack(spacing: Space.s3) {
            Button(action: open) {
                HStack(spacing: Space.s3) {
                    ProjectThumb(url: row.url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(AppType.label).tracking(-0.1).foregroundStyle(Tok.text).lineLimit(1)
                        HStack(spacing: Space.s1) {
                            Text(time).font(AppType.caption).monospacedDigit().foregroundStyle(Tok.text2)
                            Text(day).font(AppType.caption).foregroundStyle(Tok.text2.opacity(0.72))
                        }
                    }
                    Spacer(minLength: Space.s3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            if row.dropped > 0 {
                PixelBadge(kind: .caution, text: "\(row.dropped) dropped")
            }
            Text(duration).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                .frame(width: 44, alignment: .trailing)
            Text(row.output).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                .frame(width: 64, alignment: .trailing)

            HStack(spacing: 0) {
                LIconButton(icon: "slider.horizontal.below.rectangle", label: "Open in Studio", action: open)
                LIconButton(icon: "folder", label: "Reveal in Finder", action: reveal)
                LActionMenuButton(label: "Recording actions", items: menuItems)
            }
            .opacity(hover || focused ? 1 : 0)
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: Radius.field).fill(hover || focused ? Tok.control : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(reduceMotion ? nil : (hover ? Motion.hoverIn : Motion.hoverOut), value: hover)
        .animation(reduceMotion ? nil : Motion.hoverIn, value: focused)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { open(); return .handled }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Where you record

struct WhereYouRecord: View {
    // Usage is honest: a library with projects but no window data says so,
    // instead of a stub that pretends nothing was recorded.
    private var rows: [(app: String, minutes: Double)] { [] }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Where you record").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
            if rows.isEmpty {
                Text("No app usage detected yet.").font(AppType.caption).foregroundStyle(Tok.text2)
                DustLine()
            } else {
                ForEach(rows, id: \.app) { row in
                    HStack(spacing: Space.s3) {
                        Text(row.app).font(AppType.label).foregroundStyle(Tok.text)
                        Spacer(minLength: Space.s3)
                        Text(String(format: "%.0f min", row.minutes))
                            .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
