#if DEBUG
import SwiftUI
import AppKit
import LumenCore

/// DEBUG-only launch flags (compiled out of Release).
/// --debug-screen library|editor|hud
/// --debug-state <fixture> --debug-window WxH
/// --debug-autorecord <seconds> [--mic] [--camera] [--system-audio]
/// --debug-kill9-after <seconds>
public enum DebugFlags {
    public static var screen: String { value("--debug-screen") ?? "library" }
    public static var state: String { value("--debug-state") ?? "normal" }
    public static var windowSize: CGSize {
        let s = value("--debug-window") ?? "1440x900"
        let parts = s.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return CGSize(width: 1440, height: 900) }
        return CGSize(width: parts[0], height: parts[1])
    }
    public static var autorecord: Double { value("--debug-autorecord").flatMap(Double.init) ?? 0 }
    public static var kill9After: Double { value("--debug-kill9-after").flatMap(Double.init) ?? 0 }
    public static var isActive: Bool { CommandLine.arguments.contains(where: { $0.hasPrefix("--debug-") }) }

    private static func value(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
}

/// One tagged element's frame in window coordinates.
struct TaggedFrame: Codable, Equatable {
    var id: String
    var x: Double, y: Double, w: Double, h: Double
    var idealW: Double, idealH: Double
}

struct AuditViolation: Codable {
    var kind: String
    var element: String
    var detail: String
}

enum LayoutAudit {
    /// Fails on: (1) not contained, (2) primary overlap (unless allowed),
    /// (3) Text ideal > allocated, (4) value within 8pt of/beyond edge.
    static func check(_ frames: [TaggedFrame], window: CGRect, allowedOverlaps: Set<String> = []) -> [AuditViolation] {
        var out: [AuditViolation] = []
        let win = CGRect(x: 0, y: 0, width: window.width, height: window.height)
        for f in frames {
            let r = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            if !win.contains(r) {
                out.append(AuditViolation(kind: "containment", element: f.id, detail: "\(r) not in \(win)"))
            }
            if f.idealW > f.w + 0.5 || f.idealH > f.h + 0.5 {
                out.append(AuditViolation(kind: "truncation", element: f.id, detail: "ideal \(f.idealW)x\(f.idealH) > alloc \(f.w)x\(f.h)"))
            }
            if f.id.hasPrefix("value") || f.id.hasPrefix("toggle") || f.id.hasPrefix("trailing") {
                let right = win.maxX - r.maxX
                if right < 8 || r.minX < 8 {
                    out.append(AuditViolation(kind: "edge", element: f.id, detail: "right clearance \(right)pt"))
                }
            }
        }
        // Primary overlap: any two non-allowed elements intersect > 4pt².
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let a = frames[i], b = frames[j]
                if allowedOverlaps.contains(a.id) || allowedOverlaps.contains(b.id) { continue }
                let ra = CGRect(x: a.x, y: a.y, width: a.w, height: a.h)
                let rb = CGRect(x: b.x, y: b.y, width: b.w, height: b.h)
                let inter = ra.intersection(rb)
                if inter.width > 4 && inter.height > 0 && !inter.isNull {
                    out.append(AuditViolation(kind: "overlap", element: "\(a.id)x\(b.id)", detail: "overlap \(inter)"))
                }
            }
        }
        return out
    }

    static func writeJSON(frames: [TaggedFrame], violations: [AuditViolation], to url: URL) {
        struct Out: Codable {
            var frames: [TaggedFrame]
            var violations: [AuditViolation]
            var count: Int
        }
        let payload = Out(frames: frames, violations: violations, count: violations.count)
        if let data = try? JSONEncoder().encode(payload) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct FrameKey: PreferenceKey {
    static let defaultValue: [TaggedFrame] = []
    static func reduce(value: inout [TaggedFrame], nextValue: () -> [TaggedFrame]) { value += nextValue() }
}

private extension View {
    func tag(_ id: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: FrameKey.self, value: [
                        TaggedFrame(id: id,
                                    x: geo.frame(in: .global).origin.x,
                                    y: geo.frame(in: .global).origin.y,
                                    w: geo.frame(in: .global).width,
                                    h: geo.frame(in: .global).height,
                                    idealW: 0, idealH: 0)
                    ])
            }
        )
        .accessibilityIdentifier(id)
    }
}

/// DEBUG fixture window. Synthetic, deterministic states for the matrix.
public struct DebugFixtureView: View {
    public let screen: String
    public let state: String
    @State private var frames: [TaggedFrame] = []

    public init(screen: String, state: String) { self.screen = screen; self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            switch screen {
            case "library": libraryBody
            case "editor": editorBody
            case "hud": hudBody
            default: Text("unknown screen \(screen)").tag("fallback")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(FrameKey.self) { frames = $0 }
        .task {
            // Wait for idle (no animation, no pending analysis): 600 ms.
            try? await Task.sleep(for: .milliseconds(600))
            let win = NSApp.keyWindow?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let violations = LayoutAudit.check(frames, window: win)
            let outDir = ProcessInfo.processInfo.environment["LUMEN_VERIFY_OUT"] ?? "Docs/Verification/run-debug"
            let tag = "\(screen)_\(state)_\(Int(win.width))x\(Int(win.height))"
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(tag).audit.json")
            LayoutAudit.writeJSON(frames: frames, violations: violations, to: url)
            print("AUDIT \(tag) violations=\(violations.count)")
            if DebugFlags.autorecord > 0 {
                try? await Task.sleep(for: .seconds(DebugFlags.autorecord))
            }
            if DebugFlags.kill9After > 0 {
                try? await Task.sleep(for: .seconds(DebugFlags.kill9After))
                // Simulated kill-9: hard exit without cleanup.
                _exit(137)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(screen) · \(state)").font(.headline).tag("title")
            Spacer()
            Text("\(Int(DebugFlags.windowSize.width))×\(Int(DebugFlags.windowSize.height))").font(.caption.monospacedDigit()).tag("trailing-size")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .tag("titlebar")
    }

    private var libraryBody: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sidebar").font(.subheadline).tag("sidebar-label")
                ForEach(["All", "Recent", "Today"], id: \.self) { Text($0).tag("sidebar-\($0)") }
                Spacer()
            }
            .frame(width: 220)
            .tag("sidebar")
            VStack(alignment: .leading, spacing: 16) {
                activityGraph
                statsCard
                if state == "library-failed-item" || state.contains("failed") { failedRow }
                if state.contains("unfinished") { banner }
            }
            .padding(16)
        }
        .tag("library-root")
    }

    private var activityGraph: some View {
        VStack(alignment: .leading) {
            Text("Activity").font(.subheadline).tag("activity-title")
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<60, id: \.self) { i in
                    Color.accentColor.frame(height: CGFloat((i * 37) % 40 + 8))
                }
            }
            .frame(height: 80)
            .tag("activity-graph")
            HStack {
                Text("January").font(.caption).tag("month-January")
                Spacer()
                Text("Legend").font(.caption).tag("legend")
            }
            .tag("activity-legend")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .tag("activity-card")
    }

    private var statsCard: some View {
        HStack {
            VStack(alignment: .leading) { Text("Recorded").font(.caption); Text("12h 34m").font(.title2).tag("value-recorded") }
            Spacer()
            VStack(alignment: .trailing) { Text("Streak").font(.caption); Text("7 days").font(.title2).tag("value-streak") }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .tag("stats-card")
    }

    private var failedRow: some View {
        HStack { Text("⚠ Failed 0:00").tag("value-failed"); Spacer(); Text("Retry").tag("trailing-retry") }
            .padding(8).background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)).tag("failed-row")
    }

    private var banner: some View {
        Text("Unfinished recording — recover").font(.subheadline).tag("unfinished-banner")
            .padding(8).background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).tag("banner")
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Undo") {}.tag("value-undo")
                Button("Redo") {}.tag("value-redo")
                Button("Inspector") {}.tag("toggle-inspector")
                Spacer()
                Button("Export") {}.tag("value-export")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .tag("toolbar")
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("Timeline ruler 0 1 2 3 4 5 6 7 8 9 10").font(.caption.monospacedDigit()).tag("ruler")
                    HStack(spacing: 4) {
                        ForEach(0..<12, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.3)).frame(height: 28)
                                .tag("tap-\(i)")
                        }
                    }
                }
                .tag("timeline")
                inspector
            }
        }
        .tag("editor-root")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspector").font(.headline).tag("inspector-title")
            HStack { Text("Zoom").tag("inspector-zoom-label"); Spacer(); Text("2.2×").tag("value-zoom") }
            HStack { Text("Smoothness").tag("inspector-smooth-label"); Toggle("", isOn: .constant(true)).tag("toggle-smooth") }
            HStack { Text("Opacity").tag("inspector-opacity-label"); Spacer(); Text("80%").tag("value-opacity") }
            Spacer()
        }
        .padding(12)
        .frame(width: 320)
        .background(.thinMaterial)
        .tag("inspector")
    }

    private var hudBody: some View {
        VStack(spacing: 12) {
            Text(state == "hud-recording" ? "● Recording 01:23" : "Idle").font(.title).tag("hud-status")
            Text("Dropped 0 · Mic −12 dB").font(.caption).tag("value-hud-meters")
            if state == "hud-paused" { Text("Paused").tag("hud-paused") }
            if state.contains("mic-camera") { Text("Mic + Camera on").tag("trailing-hud-devices") }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .tag("hud-card")
    }
}
#endif
