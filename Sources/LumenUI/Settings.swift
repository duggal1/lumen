import SwiftUI
import AppKit

/// Appearance is a window-level override, applied at launch and when Settings changes.
@MainActor enum Appearance {
    static func apply() {
        switch UserDefaults.standard.string(forKey: "LumenAppearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

struct SettingsSurface: View {
    let app: AppModel
    enum Tab: String, CaseIterable { case general = "General", capture = "Capture" }
    @State private var tab = Tab.general
    @AppStorage("LumenAppearance") private var appearance = "system"
    @AppStorage("Lumen24Hour") private var use24Hour = false

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: "Settings") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    LSegmented(sel: $tab, items: Tab.allCases.map { ($0, $0.rawValue) },
                               track: Tok.surface, thumb: Tok.control)
                        .frame(width: 240)
                    switch tab {
                    case .general: general
                    case .capture: capture
                    }
                }
                .padding(.horizontal, Metrics.pagePad)
                .padding(.bottom, Metrics.pagePad)
                .frame(maxWidth: Metrics.settings, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { Appearance.apply() }
        .onChange(of: appearance) { Appearance.apply() }
    }

    private var general: some View {
        VStack(spacing: 0) {
            Row(label: "Appearance") {
                LSegmented(sel: $appearance, items: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
                           track: Tok.well, thumb: Tok.control)
                    .frame(width: 240)
            }
            Row(label: "Time format") {
                LSegmented(sel: Binding(get: { use24Hour ? "24" : "12" },
                                        set: { use24Hour = $0 == "24" }),
                           items: [("12", "12-hour"), ("24", "24-hour")],
                           track: Tok.well, thumb: Tok.control)
                    .frame(width: 240)
            }
        }
        .card()
    }

    private var capture: some View {
        VStack(spacing: 0) {
            Row(label: "Default source") {
                LSegmented(sel: Bindable(app).kind,
                           items: AppModel.SourceKind.allCases.map { ($0, label($0)) },
                           track: Tok.well, thumb: Tok.control)
                    .frame(width: 240)
            }
            Row(label: "Frame rate") {
                LSegmented(sel: Bindable(app).fps, items: [(30, "30"), (60, "60"), (120, "120")],
                           track: Tok.well, thumb: Tok.control)
                    .frame(width: 240)
            }
            ForEach(app.availableAudioInputs, id: \.id) { device in
                Row(label: device.name) {
                    LToggle(on: Binding(get: { app.micInputIDs.contains(device.id) },
                                        set: { app.selectAudioInput(device.id, enabled: $0) }),
                            label: device.name)
                }
            }
            Text("Audio inputs: Select multiple devices for independent recording. Leave all off for the macOS default microphone.")
                .font(AppType.caption).foregroundStyle(Tok.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private func label(_ kind: AppModel.SourceKind) -> String {
        switch kind { case .display: "Display"; case .window: "Window"; case .region: "Area" }
    }
}
