import SwiftUI
import AppKit
import LumenControl

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
    enum Tab: String, CaseIterable { case general = "General", capture = "Capture", privacy = "Privacy", agents = "Agents" }
    @State private var tab = Tab.general
    @AppStorage("LumenAppearance") private var appearance = "system"
    @AppStorage("Lumen24Hour") private var use24Hour = false
    @AppStorage("LumenEmailEnabled") private var emailEnabled = false
    @AppStorage("LumenEmailRecipient") private var emailRecipient = ""
    @AppStorage("LumenEmailOnRecording") private var emailRecording = true
    @AppStorage("LumenEmailOnExport") private var emailExport = true
    // AGENT: capability, folder and bundle grants belong to the human-facing settings surface.
    @State private var agentPolicy = Policy()
    @State private var agentAudit = AuditLog()
    @State private var agentClients: [Policy.ManagedClient] = []
    @State private var selectedAgentKey: String?
    @State private var bundleDraft = ""
    @State private var auditLines: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: "Settings") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    LSegmented(sel: $tab, items: Tab.allCases.map { ($0, $0.rawValue) },
                               track: Tok.surface, thumb: Tok.control)
                        .frame(width: 300)
                    switch tab {
                    case .general: general
                    case .capture: capture
                    case .privacy: privacy
                    case .agents: agents
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
        .onAppear { refreshAgentState() }
        // AGENT: keep the audit tail current while the Agents tab is open without a separate server or polling CLI.
        .task {
            while !Task.isCancelled {
                if tab == .agents { refreshAgentState() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
            ToggleRow(label: "Email notifications", on: $emailEnabled)
            if emailEnabled {
                Row(label: "Send to") {
                    TextField("you@example.com", text: $emailRecipient)
                        .textFieldStyle(.plain)
                        .font(AppType.body)
                        .padding(.horizontal, 10)
                        .frame(width: 220, height: 28)
                        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
                }
                ToggleRow(label: "After recording", on: $emailRecording)
                ToggleRow(label: "After export", on: $emailExport)
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
        }
        .card()
    }

    private var privacy: some View {
        VStack(spacing: 0) {
        }
        .card()
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            VStack(spacing: 0) {
                HStack {
                    Text("Clients").font(AppType.title).foregroundStyle(Tok.text)
                    Spacer()
                    Button("Revoke all") { agentPolicy.revokeAll(); refreshAgentState() }
                        .buttonStyle(.plain)
                        .font(AppType.body)
                        .foregroundStyle(Tok.textAction)
                        .disabled(agentClients.isEmpty)
                }
                .padding(.bottom, 12)
                if agentClients.isEmpty {
                    Row(label: "Status") { Text("No agent clients have connected.").foregroundStyle(Tok.text2) }
                } else {
                    Menu(selectedAgentTitle) {
                        ForEach(agentClients) { client in
                            Button(client.signingID ?? client.path ?? client.key) { selectedAgentKey = client.key }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                    if let client = selectedAgent {
                        Row(label: "Signing id") { Text(client.signingID ?? "Unsigned").foregroundStyle(Tok.text2).textSelection(.enabled) }
                        Row(label: "Path") { Text(client.path ?? client.key).foregroundStyle(Tok.text2).textSelection(.enabled).lineLimit(1) }
                        Row(label: "Last seen") {
                            Text(client.lastSeen.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                                .foregroundStyle(Tok.text2)
                        }
                        ForEach(Capability.allCases, id: \.self) { capability in
                            ToggleRow(label: capability.rawValue,
                                      on: capabilityBinding(capability, client: client.key))
                        }
                    }
                }
            }
            .card()

            if let client = selectedAgent {
                VStack(spacing: 0) {
                    Row(label: "Allowed apps") {
                        HStack(spacing: 8) {
                            TextField("com.example.app", text: $bundleDraft)
                                .textFieldStyle(.plain).font(AppType.body)
                                .padding(.horizontal, 10).frame(width: 210, height: 28)
                                .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
                            Button("Add") { addBundle(client.key) }
                                .buttonStyle(.plain).foregroundStyle(Tok.textAction)
                                .disabled(bundleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    ForEach(client.bundleIDs, id: \.self) { bundleID in
                        Row(label: bundleID) {
                            Button("Remove") { removeBundle(bundleID, client: client.key) }
                                .buttonStyle(.plain).foregroundStyle(Tok.textAction)
                        }
                    }
                    Row(label: "Allowed folders") {
                        Button("Add folder") { addFolder(client.key) }
                            .buttonStyle(.plain).foregroundStyle(Tok.textAction)
                    }
                    ForEach(client.paths, id: \.self) { path in
                        Row(label: path) {
                            Button("Remove") { removePath(path, client: client.key) }
                                .buttonStyle(.plain).foregroundStyle(Tok.textAction)
                        }
                    }
                }
                .card()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Agent audit").font(AppType.title).foregroundStyle(Tok.text)
                if auditLines.isEmpty {
                    Text("No agent calls recorded.").font(AppType.body).foregroundStyle(Tok.text2)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(auditLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Tok.text2).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
        }
    }

    private var selectedAgent: Policy.ManagedClient? {
        guard let selectedAgentKey else { return agentClients.first }
        return agentClients.first { $0.key == selectedAgentKey }
    }

    private var selectedAgentTitle: String {
        selectedAgent?.signingID ?? selectedAgent?.path ?? selectedAgent?.key ?? "Select client"
    }

    private func refreshAgentState() {
        agentClients = agentPolicy.knownClients()
        if let selectedAgentKey, !agentClients.contains(where: { $0.key == selectedAgentKey }) {
            self.selectedAgentKey = agentClients.first?.key
        } else if selectedAgentKey == nil {
            selectedAgentKey = agentClients.first?.key
        }
        auditLines = agentAudit.recentLines(limit: 80)
    }

    private func capabilityBinding(_ capability: Capability, client: String) -> Binding<Bool> {
        Binding(get: { agentPolicy.grantedCapabilities(for: client).contains(capability.rawValue) },
                set: { enabled in
                    var grants = Set(agentPolicy.grantedCapabilities(for: client))
                    if enabled { grants.insert(capability.rawValue) } else { grants.remove(capability.rawValue) }
                    agentPolicy.grant(client: client, capabilities: grants.sorted())
                    refreshAgentState()
                })
    }

    private func addBundle(_ client: String) {
        let value = bundleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let bundles = Set(agentPolicy.grantedBundleIDs(for: client)).union([value])
        agentPolicy.grant(client: client, bundleIDs: bundles.sorted())
        bundleDraft = ""
        refreshAgentState()
    }

    private func removeBundle(_ value: String, client: String) {
        agentPolicy.grant(client: client, bundleIDs: agentPolicy.grantedBundleIDs(for: client).filter { $0 != value })
        refreshAgentState()
    }

    private func addFolder(_ client: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folders = Set(agentPolicy.grantedPaths(for: client)).union([url.resolvingSymlinksInPath().path])
        agentPolicy.grant(client: client, paths: folders.sorted())
        refreshAgentState()
    }

    private func removePath(_ value: String, client: String) {
        agentPolicy.grant(client: client, paths: agentPolicy.grantedPaths(for: client).filter { $0 != value })
        refreshAgentState()
    }

    private func label(_ kind: AppModel.SourceKind) -> String {
        switch kind { case .display: "Display"; case .window: "Window"; case .region: "Area" }
    }
}
