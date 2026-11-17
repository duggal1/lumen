import Foundation
import Observation
import SwiftUI
import AppKit
import LumenProject
import LumenRender

// MARK: - Minimal control set

/// The entire Focus page, as data. Anything not in these three lists is a knob
/// the user asked us to delete; tests pin the lists so the bloat cannot return.
enum FocusControlSet {
    static let zoom = ["Auto zoom", "Zoom amount", "Smoothness"]
    static let cursor = ["Cursor style", "Size", "Smoothing", "Click effect"]
    static let layout = ["Layout"]
    static let all = zoom + cursor + layout

    /// Renderer parameters that used to have their own control and must never
    /// appear in this page again.
    static let removed = [
        "Constant size", "Loop position", "Press scale", "Zoom comp.", "Glide",
        "Idle hide", "Click ring", "Click size", "Click intensity", "Click color",
        "Click duration", "Click sound", "Fine tuning", "3D motion", "Max zoom",
        "Focus X", "Focus Y", "Motion blur", "Avoid cursor", "Behind face",
    ]

    static func isAllowed(_ label: String) -> Bool { all.contains(label) }
}

/// Cursor "skins" are shape themes, not colors. Only packs whose artwork is a
/// genuinely different pointer are offered; every color-only ink pack is gone.
enum FocusCursorStyle: Identifiable, Sendable {
    case system, minimal, dot, ring, outline

    static let all: [FocusCursorStyle] = [.system, .minimal, .dot, .ring, .outline]

    var pack: CursorPack {
        switch self {
        case .system: .system
        case .minimal: .minimal
        case .dot: .dot
        case .ring: .ring
        case .outline: .outline
        }
    }

    var id: CursorPack { pack }

    var title: String {
        switch self {
        case .system: "Default"
        case .minimal: "Minimal"
        case .dot: "Dot"
        case .ring: "Ring"
        case .outline: "Outline"
        }
    }

    var accessibilityLabel: String { "\(title) cursor style" }
}

/// One dropdown for the whole layout system. The per-layout cosmetic knobs are
/// deliberately not part of this page.
enum FocusLayoutStyle: Sendable {
    static let all: [(LayoutKind, String)] = [
        (.screenOnly, "Screen only"),
        (.cameraOverlay, "Camera overlay"),
        (.split, "Split"),
        (.cameraFullscreen, "Camera fullscreen"),
        (.cameraCutout, "Cutout"),
    ]
}

/// Tabs that existed before the unification all resolve to Focus. Keeping the
/// mapping pure makes the migration testable without a window.
enum FocusTabMigration: Sendable {
    static func normalize(_ saved: String) -> String {
        switch saved {
        case "Camera", "Cursor", "Layout", "Focus": "Focus"
        case "Transcript": "Captions"
        case "Background": "Studio"
        default: saved
        }
    }
}

// MARK: - Live feedback meter

/// A small, deterministic state machine behind the live waveform. A tap shifts
/// one peak into the newest column; time decays every column back to zero, so
/// silence is a gap (dust), never a colored slab. No audio object lives here:
/// the capture/audio layer posts `tapNotification` when a click/key sound plays.
@MainActor @Observable
final class FocusFeedbackMeter {
    enum Feedback: String, Sendable {
        case click, key

        var peak: Float {
            switch self {
            case .click: 1.0
            case .key: 0.72
            }
        }
    }

    nonisolated static let columns = 48
    nonisolated static let decaySeconds = 0.42
    nonisolated static let tapNotification = Notification.Name("lumen.focus.feedback.tap")
    nonisolated static let kindKey = "kind"

    private(set) var levels = [Float](repeating: 0, count: FocusFeedbackMeter.columns)
    private var lastUpdate = Date()

    var headIndex: Int? { levels.lastIndex(where: { $0 > 0 }) }
    var isSilent: Bool { headIndex == nil }

    /// A tap scrolls the tape left and writes the new peak at the head.
    func register(_ feedback: Feedback, at date: Date = Date()) {
        advance(to: date)
        levels.removeFirst()
        levels.append(feedback.peak)
        lastUpdate = date
    }

    /// Exponential decay toward zero, with a small floor so old taps become
    /// true gaps. Deterministic for a given elapsed time.
    func advance(to date: Date = Date()) {
        let dt = max(0, date.timeIntervalSince(lastUpdate))
        guard dt > 0 else { return }
        let factor = Float(exp(-dt / Self.decaySeconds))
        for i in levels.indices {
            levels[i] *= factor
            if levels[i] < 0.02 { levels[i] = 0 }
        }
        lastUpdate = date
    }

    /// Copy for drawing. Called from the view body (main actor) so the canvas
    /// closure only ever sees a value, never isolated state.
    func snapshot(at date: Date = Date()) -> [Float] {
        advance(to: date)
        return levels
    }

    func handle(_ note: Notification) {
        guard let raw = note.userInfo?[Self.kindKey] as? String,
              let feedback = Feedback(rawValue: raw) else { return }
        register(feedback)
    }

    nonisolated static func post(_ feedback: Feedback) {
        NotificationCenter.default.post(name: tapNotification, object: nil,
                                        userInfo: [kindKey: feedback.rawValue])
    }

    /// Peak → four heat steps; zero is a gap, never a color.
    nonisolated static func cellLevel(_ peak: Float) -> Int {
        guard peak.isFinite, peak > 0 else { return 0 }
        if peak >= 0.8 { return 4 }
        if peak >= 0.55 { return 3 }
        if peak >= 0.3 { return 2 }
        if peak >= 0.08 { return 1 }
        return 0
    }
}

// MARK: - Live waveform

/// The page's one colored element: a scrolling heat tape with a white head and
/// dotted silence. Redraws on the display while active, rests when silent.
struct FeedbackWaveform: View {
    let meter: FocusFeedbackMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The frame loop runs only while feedback is audible; at rest it stops.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: meter.isSilent || reduceMotion)) { context in
            let peaks = reduceMotion
                ? [Float](repeating: 0, count: FocusFeedbackMeter.columns)
                : meter.snapshot(at: context.date)
            let silent = peaks.allSatisfy { $0 <= 0 }

            Canvas { canvas, size in
                let pitch: CGFloat = 4, cell: CGFloat = 3
                let columns = max(1, min(FocusFeedbackMeter.columns, Int(size.width / pitch)))
                let shown = Array(peaks.suffix(columns))
                let pad = columns - shown.count
                let mid = (size.height / 2).rounded(.down)

                func block(_ x: CGFloat, _ y: CGFloat, _ color: Color) {
                    canvas.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                with: .color(color), style: FillStyle(antialiased: false))
                }

                for i in 0..<pad { block(CGFloat(i) * pitch + 1, mid, Tok.controlPressed) }

                for (i, peak) in shown.enumerated() {
                    let x = CGFloat(i + pad) * pitch
                    let level = FocusFeedbackMeter.cellLevel(peak)
                    guard level > 0 else { block(x + 1, mid, Tok.controlPressed); continue }
                    let head = i == shown.count - 1
                    let ink = head ? Tok.text : Ramp.heat[min(3, level - 1)]
                    for k in 1...level {
                        block(x, mid - 1 - CGFloat(k) * pitch, ink)
                        block(x, mid + 1 + CGFloat(k - 1) * pitch, ink)
                    }
                }
            }
            .accessibilityLabel("Sound feedback")
            .accessibilityValue(silent ? "Silent" : "Active")
        }
    }
}

// MARK: - Page

/// Camera + Cursor + Layout, collapsed into one quiet page. Chrome is flat and
/// 1-bit; the only accent is the selected theme's fill and the feedback tape.
struct UnifiedFocusPage: View {
    let model: EditorModel
    var width: CGFloat = Metrics.inspector

    @State private var meter = FocusFeedbackMeter()

    private static let previews: [CursorPack: NSImage] = Dictionary(
        uniqueKeysWithValues: FocusCursorStyle.all.compactMap { style in
            guard let image = CursorAtlas.previewImage(pack: style.pack) else { return nil }
            return (style.pack, image)
        })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                framingCard
                cursorCard
                feedbackCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Tok.bg)
        .onReceive(NotificationCenter.default.publisher(for: FocusFeedbackMeter.tapNotification)) { note in
            meter.handle(note)
        }
    }

    /// Framing is one idea: where the camera looks and how the shot is laid out.
    private var framingCard: some View {
        let m = model
        return VStack(spacing: 0) {
            ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
            SliderRow(label: "Zoom amount",
                      v: Binding(get: { m.timeline.camera.baseScale },
                                 set: { v in m.edit(coalesce: true) { $0.camera.baseScale = v } }),
                      range: 1.3...3.0, fmt: { String(format: "%.1f×", $0) })
            SliderRow(label: "Smoothness", v: m.bind(\.camera.leadIn), range: 0.3...1.0,
                      fmt: { "\(Int($0 * 1000)) ms" })
            Row(label: "Layout") {
                LDropdown(sel: layoutKind,
                          options: FocusLayoutStyle.all.map { ($0.0, $0.1, "rectangle.3.group") })
                    .frame(width: 150)
            }
        }.card(padding: 16)
    }

    private var cursorCard: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Cursor style").font(AppType.label).foregroundStyle(Tok.text)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(FocusCursorStyle.all) { style in
                    styleTile(style, selected: m.timeline.cursor.pack == style.pack) {
                        m.edit { $0.cursor.pack = style.pack }
                        FocusFeedbackMeter.post(.click)
                    }
                }
            }
            SliderRow(label: "Size", v: m.bind(\.cursor.size), range: 0.5...2.0,
                      fmt: { String(format: "%.1f×", $0) })
            SliderRow(label: "Smoothing", v: m.bind(\.cursor.smoothingSigma), range: 0...0.12,
                      fmt: { "\(Int($0 * 1000)) ms" })
            Row(label: "Click effect") {
                LDropdown(sel: m.bind(\.cursor.clickEffect),
                          options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") })
                    .frame(width: 130)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    /// Selection is a flat accent surface and an accent label, never a square
    /// bracket or a stroke. The trait carries the state to VoiceOver.
    private func styleTile(_ style: FocusCursorStyle, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.field)
                        .fill(selected ? Tok.accentSoft : Tok.well)
                    if let image = Self.previews[style.pack] {
                        Image(nsImage: image).resizable().frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "cursorarrow").font(.system(size: 14)).foregroundStyle(Tok.text)
                    }
                }
                .frame(height: 44)
                Text(style.title)
                    .font(AppType.caption)
                    .foregroundStyle(selected ? Tok.accentText : Tok.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .focusRing()
        .accessibilityLabel(style.accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Sound feedback").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: 8)
                LButton(title: "Preview", kind: .quiet, height: 24) {
                    FocusFeedbackMeter.post(.click)
                }
                .focusRing()
            }
            FeedbackWaveform(meter: meter)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(meter.isSilent ? "Waiting for a click or key." : "Sound playing.")
                .font(AppType.caption).foregroundStyle(Tok.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    static func currentLayout(in timeline: Timeline, at playhead: Double) -> LayoutKind {
        let source = timeline.timeMap.source(atOutput: playhead)
        return timeline.layouts.first { source >= $0.start && source < $0.end }?.kind
            ?? (timeline.webcam != nil ? .cameraOverlay : .screenOnly)
    }

    private var layoutKind: Binding<LayoutKind> {
        Binding(get: { Self.currentLayout(in: model.timeline, at: model.playhead) },
                set: { kind in
                    model.edit { timeline in
                        timeline.layouts = [LayoutSegment(start: 0, end: timeline.timeMap.sourceDuration, kind: kind)]
                    }
                })
    }
}
