import SwiftUI
import AppKit
import LumenCapture

// MARK: Routes

enum Route: String, CaseIterable, Identifiable {
    case library, studio, backgrounds, cursors, audio, export, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .studio: "Studio"
        case .backgrounds: "Backgrounds"
        case .cursors: "Cursors"
        case .audio: "Audio"
        case .export: "Export"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library: "film.stack"
        case .studio: "slider.horizontal.below.rectangle"
        case .backgrounds: "photo"
        case .cursors: "cursorarrow"
        case .audio: "waveform"
        case .export: "square.and.arrow.up"
        case .settings: "switch.2"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .library: "1"
        case .studio: "2"
        case .backgrounds: "3"
        case .cursors: "4"
        case .audio: "5"
        case .export: "6"
        case .settings: "7"
        }
    }
}

@MainActor @Observable final class ShellModel {
    var route: Route = .library
    var sidebarShown = false
    func go(_ route: Route) { self.route = route }
}

// MARK: Shell

/// One window: an optional sidebar and detail on `bg`. The sidebar is a transient navigator, hidden until asked for.
public struct LumenShell: View {
    let app: AppModel
    @State private var shell = ShellModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ app: AppModel) { self.app = app }

    public var body: some View {
        HStack(spacing: 0) {
            if shell.sidebarShown {
                ShellSidebar(app: app, route: shell.route, go: shell.go)
                    .frame(width: Metrics.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                routeContent
                    .id(shell.route)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tok.bg)
        }
        .animation(reduceMotion ? nil : Motion.slide, value: shell.sidebarShown)
        .animation(reduceMotion ? nil : Motion.route, value: shell.route)
        .frame(minWidth: Metrics.minW, minHeight: Metrics.minH)
        .onAppear { shell.sidebarShown = false }
        .overlay(alignment: .topLeading) {
            SidebarToggle(shows: shell.sidebarShown) { shell.sidebarShown.toggle() }
                .padding(.leading, 82)
                .offset(y: -26)
        }
    }

    @ViewBuilder private var routeContent: some View {
        switch shell.route {
        case .library: LibrarySurface(app: app)
        case .settings: SettingsSurface(app: app)
        case .studio: OpenProjectSurface(route: .studio, app: app)
        case .backgrounds: OpenProjectSurface(route: .backgrounds, app: app)
        case .cursors: OpenProjectSurface(route: .cursors, app: app)
        case .audio: OpenProjectSurface(route: .audio, app: app)
        case .export: OpenProjectSurface(route: .export, app: app)
        }
    }
}

// MARK: Sidebar

private struct ShellSidebar: View {
    let app: AppModel
    let route: Route
    let go: (Route) -> Void
    @Namespace private var pill
    @State private var hovered: Route?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarMaterial().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Route.allCases) { r in
                    row(r)
                }
                Spacer(minLength: Space.s4)
            }
            .padding(.horizontal, Space.s2)
            .padding(.top, Metrics.pageBar)
            .padding(.bottom, Space.s2)
            .ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ r: Route) -> some View {
        Button { go(r) } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: r.icon).font(.system(size: 14)).frame(width: 20)
                Text(r.title).font(AppType.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(route == r ? Tok.text : Tok.text2)
            .padding(.horizontal, Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background {
                if route == r {
                    Capsule().fill(Tok.washStrong).matchedGeometryEffect(id: "pill", in: pill)
                } else if hovered == r {
                    Capsule().fill(Tok.wash)
                }
            }
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : Motion.menuHighlight, value: route)
            .animation(reduceMotion ? nil : (hovered == r ? Motion.hoverIn : Motion.hoverOut), value: hovered)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .keyboardShortcut(r.key, modifiers: .command)
        .onHover { hovered = $0 ? r : (hovered == r ? nil : hovered) }
        .accessibilityLabel(r.title)
        .accessibilityAddTraits(route == r ? .isSelected : [])
    }
}

/// The one control in the titlebar band: 82 pt from the left, just clear of the traffic lights. Quiet until hovered.
private struct SidebarToggle: View {
    let shows: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hover ? Tok.text : Tok.text2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.field).fill(hover ? Tok.washStrong : .clear))
                .contentShape(RoundedRectangle(cornerRadius: Radius.field))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hover = $0 }
        .animation(reduceMotion ? nil : (hover ? Motion.hoverIn : Motion.hoverOut), value: hover)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .accessibilityLabel(shows ? "Hide sidebar" : "Show sidebar")
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
    }
}

// MARK: Route surfaces that need an open project

private struct OpenProjectSurface: View {
    let route: Route
    let app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: route.title) { EmptyView() }
            VStack {
                Spacer()
                HStack(spacing: Space.s4) {
                    PixelLens(cell: 4)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text("Open a recording.").font(AppType.label).foregroundStyle(Tok.text)
                        Text("Choose one in Library.").font(AppType.body).foregroundStyle(Tok.text2)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
