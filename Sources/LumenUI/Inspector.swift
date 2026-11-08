import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenExport
import LumenAudio
import LumenCapture

struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case background = "Background", tools = "Tools", cursor = "Cursor", camera = "Camera", layout = "Layout", webcam = "Webcam", captions = "Captions", timeline = "Timeline", privacy = "Privacy", audio = "Audio", export = "Export" }


    static func visibleFor(model: EditorModel) -> [Inspector.Tab] {
        Inspector.Tab.allCases.filter { $0 != Inspector.Tab.webcam || model.timeline.webcam != nil }
    }
    @Binding var tab: Inspector.Tab
    var width: CGFloat = Metrics.inspector
    @State private var presets = EditorModel.loadPresets()
    @State private var newName = ""

    // Per-option Apple icons for inspector menus.
    private static func canvasIcon(_ c: CanvasAspect) -> String {
        switch c { case .r16x9: "rectangle"; case .r16x10: "rectangle"; case .r4x3: "rectangle.righthalf.inset.filled"; case .r5x4: "rectangle"; case .r3x2: "rectangle"; case .r1x1: "square"; case .r4x5: "rectangle.portrait"; case .r9x16: "rectangle.portrait"; case .r21x9: "aspectratio" }
    }
    private static func layoutIcon(_ k: LayoutKind) -> String {
        switch k { case .screenOnly: "display"; case .cameraOverlay: "rectangle.3.group"; case .split: "rectangle.split.2x1"; case .cameraFullscreen: "video"; case .cameraCutout: "person" }
    }
    private static func captionPositionIcon(_ p: CaptionPosition) -> String {
        switch p { case .auto: "sparkles"; case .bottom: "arrow.down"; case .top: "arrow.up" }
    }
    private static func captionAnimationIcon(_ a: CaptionAnimation) -> String {
        switch a { case .none: "minus"; case .fade: "eye"; case .blur: "wind"; case .pop: "sparkles"; case .slide: "arrow.right" }
    }
    private static func micModeIcon(_ m: MicMode) -> String {
        switch m { case .standard: "mic"; case .loud: "mic.fill"; case .podcast: "waveform.and.mic"; case .off: "mic.slash" }
    }
    private static func maskModeIcon(_ m: MaskMode) -> String {
        switch m { case .blur: "eye.slash"; case .pixelate: "square.grid.3x3"; case .solid: "rectangle.fill"; case .blend: "circle.lefthalf.filled" }
    }

    var body: some View {
        content
            .onChange(of: model.exportPanelRequest) { _, _ in tab = .export }
            .onChange(of: tab) { _, selected in
                model.exportPanelActive = selected == .export
                UserDefaults.standard.set(selected.rawValue, forKey: "lumen.inspector.tab")
            }
            .onAppear {
                if let saved = UserDefaults.standard.string(forKey: "lumen.inspector.tab") {
                    if saved == "Transcript" { tab = .captions }
                    else if let t = Inspector.Tab(rawValue: saved) { tab = t }
                } else {
                    tab = .background
                }
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            tabSelector
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            ScrollView {
                tabBody
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width).frame(maxHeight: .infinity).background(Tok.bg)
    }

    /// One full-width section dropdown at the top of the inspector.
    /// Full names always; nothing truncated. The sixth empty pill is gone:
    /// secondary sections are labelled rows in this same menu.
    private var tabSelector: some View {
        LDropdown(sel: $tab, options: Inspector.Tab.visibleFor(model: model).map { ($0, $0.rawValue, icon($0)) })
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Inspector section: \(tab.rawValue)")
    }

    @ViewBuilder private var tabBody: some View {
        switch tab {
        case .background: backgroundPage
        case .tools: tools
        case .cursor: cursor
        case .camera: camera
        case .layout: layout
        case .audio: audio
        case .webcam: webcam
        case .captions: captions
        case .timeline: timelineTab
        case .privacy: privacy
        case .export: export
        }
    }

    /// Secondary editor actions live in the inspector, not the preview transport.
    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            LButton(title: "Add loupe", icon: "magnifyingglass.circle") { model.addLoupe() }
            LButton(title: "Add tap", icon: "cursorarrow.click") { model.addTapAtPlayhead() }
            LButton(title: "Import clip", icon: "film") { model.importClips() }
            LButton(title: "Frame selection", icon: "viewfinder") { model.focusEditing.toggle() }
                .disabled(model.selection == nil)
            LButton(title: "Add title", icon: "textformat") { model.addManualTitle() }
            LButton(title: "Add highlight", icon: "highlighter") { model.addManualHighlight() }
            LButton(title: "Delete selection", icon: "trash") { model.deleteSelected() }
                .disabled(model.selection == nil)
            LButton(title: "Share project", icon: "person.2.badge.plus") { model.shareProject() }
            if let tool = model.placingTool {
                HStack(spacing: Space.s2) {
                    Text("Click the preview to place the \(tool.rawValue).")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                    Spacer()
                    LButton(title: "Cancel", kind: .quiet) { model.placingTool = nil }
                }
            }
#if DEBUG
            let stats = model.renderer.presentStats.snapshot
            Text("Preview: \(stats.late) late frames / \(stats.frames), worst \(Int(stats.worstMs)) ms")
                .font(AppType.caption.monospacedDigit())
                .foregroundStyle(Tok.text2)
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func icon(_ t: Inspector.Tab) -> String {
        switch t {
        case .background: "photo.stack"
        case .tools: "slider.horizontal.3"; case .cursor: "cursorarrow"; case .camera: "video"
        case .layout: "rectangle.3.group"; case .audio: "waveform"; case .webcam: "person.crop.circle"
        case .captions: "captions.bubble"; case .timeline: "timeline.selection"; case .privacy: "lock"; case .export: "square.and.arrow.up"
        }
    }

    private struct WallpaperChoice: Identifiable {
        var id: String { url.path }
        var displayName: String
        var url: URL
        var isPainting: Bool
    }

    private static let wallpaperExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    private static func isJunkToken(_ token: String) -> Bool {
        let t = token.lowercased()
        if ["download", "light", "dark", "web", "4k", "iclarified", "cma", "the", "a", "an"].contains(t) { return true }
        if t.isEmpty { return true }
        if Int(t) != nil { return true }
        if t.range(of: #"^[0-9a-f]{6,}$"#, options: .regularExpression) != nil && t.range(of: #"[a-f]"#, options: .regularExpression) != nil { return true }
        if t.hasPrefix("cma-") || t.hasPrefix("download") { return true }
        return false
    }

    private static func titleWord(_ w: String) -> String {
        let l = w.lowercased()
        switch l {
        case "macos": return "macOS"
        case "imac": return "iMac"
        case "mac": return "Mac"
        case "of": return "of"
        case "in": return "in"
        case "the": return "the"
        case "a": return "a"
        case "an": return "an"
        default: return l.capitalized
        }
    }

    private static func humanizedTokens(_ raw: String) -> [String] {
        var parts: [String] = []
        for chunk in raw.split(separator: "_", omittingEmptySubsequences: true) {
            for w in chunk.split(separator: "-", omittingEmptySubsequences: true) {
                let s = String(w)
                if !isJunkToken(s) { parts.append(s) }
            }
        }
        // "of / in / the" inside paintings are junk noise; keep only for empty fallback
        return parts
    }

    /// Humanized tooltip/VoiceOver name: strip folder prefixes, hashes,
    /// extensions, "download-light_web" junk, Title Case, macOS-style.
    static func humanizedName(for url: URL) -> String {
        var raw = (url.lastPathComponent as NSString).deletingPathExtension
        // System wallpapers already humanized ("iMac Blue.heic").
        if raw.contains(" ") && !raw.contains("_") && !raw.contains("download") {
            return raw
        }
        // Painting file is artist_subject_cma-id: use the subject.
        if raw.contains("_") {
            let comps = raw.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            if comps.count >= 3 {
                let last = comps.last!
                if last.lowercased().hasPrefix("cma-") || last.lowercased() == "cma" {
                    raw = comps.dropLast().joined(separator: "_")
                    // Drop the artist prefix token before the first "_".
                    let afterFirst = raw.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
                    if afterFirst.count == 2 { raw = String(afterFirst[1]) } else { raw = comps[1] }
                } else {
                    raw = comps.last ?? raw
                }
            } else if comps.count == 2 {
                raw = comps[1]
            }
        }
        var tokens = humanizedTokens(raw)
        if tokens.isEmpty {
            // Fall back to the parent folder ("14-sonoma" -> "Sonoma").
            let parent = url.deletingLastPathComponent().lastPathComponent
            tokens = humanizedTokens(parent)
        }
        if tokens.isEmpty { return "Wallpaper" }
        return tokens.map(titleWord).joined(separator: " ")
    }

    private static func wallpaperChoices() -> [WallpaperChoice] {
        var out: [WallpaperChoice] = []
        var seen = Set<String>()
        func add(_ url: URL, isPainting: Bool) {
            let name = humanizedName(for: url)
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(WallpaperChoice(displayName: name, url: url, isPainting: isPainting))
        }
        func collect(_ root: URL) {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard wallpaperExtensions.contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
                add(f, isPainting: rel.contains("paintings"))
            }
        }
        // Bundled gallery (packaged app + source assets for `swift run`).
        let roots: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Wallpapers"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/public/assets/wallpapers"),
            URL(fileURLWithPath: "/Users/harshitduggal/workspace/Lumen/studio/wallpapers/paintings"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("wallpapers/paintings"),
        ]
        for r in roots.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: r.path) { collect(r) }
        }
        // Every macOS wallpaper on this Mac (14/15/26 incl. Dynamic).
        let sysDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        if FileManager.default.fileExists(atPath: sysDir.path),
           let en = FileManager.default.enumerator(at: sysDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "png", "tiff", "webp"].contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                add(f, isPainting: false)
            }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @State private var wallpaperSelectTask: Task<Void, Never>?

    private var wallpaperList: some View {
        WallpaperGrid(model: model, choices: Self.wallpaperChoices()) { choice in
            wallpaperSelectTask?.cancel()
            wallpaperSelectTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                model.edit { $0.style.setPhotoBackground(choice.url.path) }
                model.edit { $0.style.background = .image }
            }
        }
        .padding(.top, 8)
    }

    private var backgroundPage: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                if m.session.webcam != nil {
                    ToggleRow(label: "Show face cam", on: Binding(get: { m.timeline.webcam != nil }, set: { m.setWebcam($0) }))
                }
                Row(label: "Background") {
                    LDropdown(sel: m.bind(\.style.background),
                              options: (BackgroundKind.offered + (m.timeline.style.background == .dither ? [.dither] : []))
                                .map { ($0, $0 == .dither ? "Legacy" : $0.rawValue.capitalized, backgroundIcon($0)) })
                        .frame(width: 130)
                }
                if m.timeline.style.background != .wallpaper && m.timeline.style.background != .image {
                    Row(label: "Palette") {
                        LDropdown(sel: paletteName(m),
                                  options: (DitherPalettes.all.map { ($0.0, $0.0, "circle.lefthalf.filled") }
                                    + (DitherPalettes.all.contains { $0.1 == m.timeline.style.colors } ? [] : [("Custom", "Custom", "paintpalette")])) )
                            .frame(width: 130)
                    }
                    Row(label: "Canvas color") {
                        ColorPicker("Canvas color", selection: canvasColor(m, index: 0), supportsOpacity: false).labelsHidden()
                    }
                    if m.timeline.style.background != .solid {
                        Row(label: "Pattern color") {
                            ColorPicker("Pattern color", selection: canvasColor(m, index: 1), supportsOpacity: false).labelsHidden()
                        }
                    }
                }
                if m.timeline.style.background == .dither || m.timeline.style.background == .wave || m.timeline.style.background == .field {
                    SliderRow(label: "Cell", v: m.bind(\.style.ditherCell), range: 2...24, fmt: { "\(Int($0)) pt" })
                }
                if m.timeline.style.background == .dither || m.timeline.style.background == .wave {
                    SliderRow(label: "Ink", v: m.bind(\.style.ditherDensity), range: 0.15...0.9, fmt: { "\(Int($0 * 100))%" })
                }
                if m.timeline.style.background == .image || m.timeline.style.background == .wallpaper {
                    wallpaperList
                        .padding(.top, 8)
                    if m.timeline.style.background == .image {
                        PhotoBackgroundRow(model: m)
                    }
                }
                ToggleRow(label: "Blur behind zoom", on: m.bind(\.style.zoomBackgroundBlur))
            }.card(padding: 16)

            VStack(spacing: 0) {
                Row(label: "Canvas") {
                    LDropdown(sel: m.bind(\.style.canvas), options: CanvasAspect.allCases.map { ($0, $0.title, Self.canvasIcon($0)) }).frame(width: 130)
                }
                SliderRow(label: "Video size", v: m.bind(\.style.contentScale), range: 0.5...2.0, fmt: { "\(Int($0 * 100))%" })
                ToggleRow(label: "Independent padding",
                          on: Binding(get: { m.timeline.style.paddingInsets != nil },
                                      set: { enabled in
                                          m.edit { $0.style.paddingInsets = enabled ? EdgeInsetsN(all: $0.style.padding) : nil }
                                      }))
                if m.timeline.style.paddingInsets == nil {
                    SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                } else {
                    SliderRow(label: "Top", v: paddingEdge(\.top), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Right", v: paddingEdge(\.right), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Bottom", v: paddingEdge(\.bottom), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Left", v: paddingEdge(\.left), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                }
            }.card(padding: 16)

            VStack(spacing: 0) {
                SliderRow(label: "Blur", v: m.bind(\.style.imageBlur), range: 0...4, fmt: { "\(Int($0))" })
                SliderRow(label: "Opacity", v: m.bind(\.style.imageOpacity), range: 0...1, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Contrast", v: m.bind(\.style.imageContrast), range: 0...2, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Brightness", v: m.bind(\.style.imageBrightness), range: 0...2, fmt: { "\(Int($0 * 100))%" })
            }.card(padding: 16)

            VStack(spacing: 0) {
                SliderRow(label: "Radius", v: m.bind(\.style.cornerRadius), range: 0...40, fmt: { "\(Int($0))" })
                ToggleRow(label: "Independent corners",
                          on: Binding(get: { m.timeline.style.cornerRadii != nil },
                                      set: { enabled in
                                          m.edit { $0.style.cornerRadii = enabled
                                              ? CornerRadii(all: $0.style.cornerRadius) : nil }
                                      }))
                if m.timeline.style.cornerRadii != nil {
                    SliderRow(label: "Top left", v: radiusCorner(\.tl), range: 0...40, fmt: { "\(Int($0))" })
                    SliderRow(label: "Top right", v: radiusCorner(\.tr), range: 0...40, fmt: { "\(Int($0))" })
                    SliderRow(label: "Bottom right", v: radiusCorner(\.br), range: 0...40, fmt: { "\(Int($0))" })
                    SliderRow(label: "Bottom left", v: radiusCorner(\.bl), range: 0...40, fmt: { "\(Int($0))" })
                }
                ToggleRow(label: "Frame", on: m.bind(\.style.innerBorder))
                if m.timeline.style.innerBorder {
                    SliderRow(label: "Weight", v: m.bind(\.style.frameWeight), range: 0...4, fmt: { "\(Int($0)) pt" })
                }
                SliderRow(label: "Shadow", v: m.bind(\.style.shadow), range: 0...1)
            }.card(padding: 16)

            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Looks").font(AppType.title); Spacer() }
                ForEach(presets) { p in LButton(title: p.name, kind: .quiet) { m.apply(p) } }
                HStack(spacing: 8) {
                    TextField("Name", text: $newName).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Tok.well))
                    LButton(title: "Save", kind: .secondary, height: 32) { if !newName.isEmpty { m.savePreset(newName); presets = EditorModel.loadPresets(); newName = "" } }
                }
            }.card(padding: 16)
        }
    }

    private func paddingEdge(_ key: WritableKeyPath<EdgeInsetsN, Double>) -> Binding<Double> {
        Binding(get: { model.timeline.style.insets[keyPath: key] },
                set: { value in
                    model.edit(coalesce: true) { timeline in
                        var insets = timeline.style.insets
                        insets[keyPath: key] = value
                        timeline.style.paddingInsets = insets
                    }
                })
    }

    private func radiusCorner(_ key: WritableKeyPath<CornerRadii, Double>) -> Binding<Double> {
        Binding(get: { model.timeline.style.radii[keyPath: key] },
                set: { value in
                    model.edit(coalesce: true) { timeline in
                        var radii = timeline.style.radii
                        radii[keyPath: key] = value
                        timeline.style.cornerRadii = radii
                    }
                })
    }

    private func loupeBinding(_ loupe: Loupe, _ key: WritableKeyPath<Loupe, Double>) -> Binding<Double> {
        Binding(get: { (model.timeline.overlays.loupes.first { $0.id == loupe.id } ?? loupe)[keyPath: key] },
                set: { value in
                    guard var l = model.timeline.overlays.loupes.first(where: { $0.id == loupe.id }) else { return }
                    l[keyPath: key] = value
                    model.updateLoupe(l)
                })
    }

    /// Cuts, imported clips and manual taps share one tab because they are the
    /// three things that change the shape of the deliverable itself.
    /// Clips are magnetic: gaps ripple closed. Soundtrack lanes shift on
    /// ripple delete to stay aligned with picture; they clamp at the end.
    private var timelineTab: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                Row(label: "Main lane") {
                    HStack(spacing: 8) {
                        LButton(title: "Split at playhead", icon: "scissors", kind: .quiet) { m.splitAtPlayhead() }
                        LButton(title: "Duplicate", icon: "doc.on.doc", kind: .quiet) { m.duplicateSelected() }
                            .disabled(m.selection == nil)
                        LButton(title: "Join", icon: "link", kind: .quiet) { m.joinSelectedClips() }
                            .disabled(m.selection == nil)
                    }
                }
                Row(label: "Ripple") {
                    HStack(spacing: 8) {
                        LButton(title: "Ripple delete", icon: "trash", kind: .quiet) { m.rippleDeleteSelected() }
                            .disabled(m.selection == nil)
                        LButton(title: "Split recording", icon: "scissors", kind: .quiet) { m.splitRecordingAtPlayhead() }
                    }
                }
                Row(label: "Clipboard") {
                    HStack(spacing: 8) {
                        LButton(title: "Copy", icon: "doc.on.doc", kind: .quiet) { m.copySelectedClip() }
                            .disabled(m.selection == nil)
                        LButton(title: "Cut", icon: "scissors", kind: .quiet) { m.cutSelectedClip() }
                            .disabled(m.selection == nil)
                        LButton(title: "Paste", icon: "doc.on.clipboard", kind: .quiet) { m.pasteClipAtPlayhead() }
                            .disabled(m.copiedClip == nil)
                    }
                }
                Row(label: "Snap") {
                    ToggleRow(label: "Snap on", on: Binding(
                        get: { m.snapEnabled },
                        set: { m.snapEnabled = $0 }))
                }
                Text("B split · C cut · Cmd-C/X/V clipboard · N snap · F fit. Snap targets: playhead, clip edges, cuts, clicks.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Cuts") {
                    LButton(title: "Cut 1s at playhead", icon: "scissors", kind: .quiet) { m.cutAtPlayhead() }
                }
                if m.timeline.timeMap.cuts.isEmpty {
                    Text("No cuts. Use the Cut button in the transport to remove a second.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(m.timeline.timeMap.cuts) { cut in
                    Row(label: String(format: "%.1f – %.1f s", cut.start, cut.end)) {
                        HStack(spacing: Space.s2) {
                            Text(cut.origin.rawValue).font(AppType.caption).foregroundStyle(Tok.text2)
                            LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.deleteCut(cut.id)) }
                        }
                    }
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Video clips") {
                    LButton(title: "Import…", icon: "film", kind: .quiet) { m.importClips() }
                }
                if m.timeline.clips.isEmpty {
                    Text("Imported movies are appended after the recording on the same timeline.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(m.timeline.clips) { clip in
                    Row(label: clip.name.isEmpty ? URL(fileURLWithPath: clip.path).lastPathComponent : clip.name) {
                        HStack(spacing: Space.s2) {
                            Text(String(format: "%.1f s", clip.duration))
                                .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                            LButton(title: "Jump", kind: .quiet) { m.seek(clip.start) }
                            LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.rippleDeleteClip(id: clip.id)) }
                        }
                    }
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Manual taps") {
                    LButton(title: "Tap at playhead", icon: "cursorarrow.click", kind: .quiet) { m.addTapAtPlayhead() }
                }
                if m.timeline.overlays.taps.isEmpty {
                    Text("Device recordings have no pointer events; taps add a click at the playhead position.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(m.timeline.overlays.taps) { tap in
                    Row(label: String(format: "%.1f s", tap.t)) {
                        HStack(spacing: 4) {
                            LIconButton(icon: "chevron.left", label: "Nudge tap left 1 px") { m.moveTap(id: tap.id, x: tap.x - 1, y: tap.y, atSource: nil) }
                                .help("Nudge tap 1 px left")
                                .accessibilityLabel("Nudge tap at \(String(format: "%.1f", tap.t)) seconds left")
                            LIconButton(icon: "chevron.right", label: "Nudge tap right 1 px") { m.moveTap(id: tap.id, x: tap.x + 1, y: tap.y, atSource: nil) }
                                .help("Nudge tap 1 px right (Shift for 10 px)")
                                .accessibilityLabel("Nudge tap at \(String(format: "%.1f", tap.t)) seconds right")
                            LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.deleteTap(tap.id)) }
                        }
                    }
                }
            }.card(padding: 16)
        }
    }

    private func backgroundIcon(_ kind: BackgroundKind) -> String {
        switch kind {
        case .dither: "square.grid.3x3.fill"
        case .wave: "waveform.path"
        case .field: "square.grid.3x3"
        case .canvas: "rectangle.fill"
        case .wallpaper: "photo"
        case .image: "photo.on.rectangle"
        case .solid: "square.fill"
        case .gradient, .mesh: "square.fill.on.square"
        case .image: "photo.stack"
        }
    }

    private func paletteName(_ m: EditorModel) -> Binding<String> {
        Binding(get: { DitherPalettes.all.first { $0.1 == m.timeline.style.colors }?.0 ?? "Custom" },
                set: { name in if name != "Custom" { m.edit { $0.style.colors = DitherPalettes.colors(named: name) } } })
    }

    private func canvasColor(_ m: EditorModel, index: Int) -> Binding<Color> {
        Binding(get: {
            let colors = m.timeline.style.colors
            let c = colors.indices.contains(index) ? colors[index] : RGBA(0xF4F4F4)
            return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
        }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            m.edit(coalesce: true) { timeline in
                while timeline.style.colors.count <= index { timeline.style.colors.append(RGBA(0xF4F4F4)) }
                timeline.style.colors[index] = RGBA(r: Float(c.redComponent), g: Float(c.greenComponent), b: Float(c.blueComponent))
            }
        })
    }

    private func clickColor(_ m: EditorModel) -> Binding<Color> {
        Binding(get: {
            let c = m.timeline.cursor.clickColor
            return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
        }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            m.edit(coalesce: true) { timeline in
                // Preserve alpha so tint-off (transparent) survives the picker.
                timeline.cursor.clickColor = RGBA(r: Float(c.redComponent), g: Float(c.greenComponent), b: Float(c.blueComponent), a: Float(c.alphaComponent))
            }
        })
    }

    private var cursor: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 24) {
            if m.session.input.events.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Tok.accentText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No pointer events saved.").font(AppType.caption).foregroundStyle(Tok.text)
                        HStack(spacing: 8) {
                            LButton(title: "Open Input Monitoring", kind: .quiet, height: 24) { LumenCapture.Permissions.requestInput() }
                            LButton(title: "Add tap manually", kind: .quiet, height: 24) { model.addTapAtPlayhead() }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Radius.nested).fill(Tok.control))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                Row(label: "Pack") { LDropdown(sel: m.bind(\.cursor.pack), options: CursorPack.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") }).frame(width: 130) }
                SliderRow(label: "Size", v: m.bind(\.cursor.size), range: 0.5...2.5)
                SliderRow(label: "Smoothing", v: m.bind(\.cursor.smoothingSigma), range: 0...0.12, fmt: { "\(Int($0 * 1000)) ms" })
                SliderRow(label: "Glide", v: m.bind(\.cursor.glide), range: 0...1)
            }.card(padding: 16)
            VStack(spacing: 0) {
                ToggleRow(label: "Hide when idle", on: Binding(get: { m.timeline.cursor.idleHide != nil }, set: { v in m.edit { $0.cursor.idleHide = v ? 2.0 : nil } }))
                ToggleRow(label: "Click ring", on: Binding(get: { m.timeline.cursor.clickRing != nil }, set: { v in m.edit { $0.cursor.clickRing = v ? 0.45 : nil } }))
                Row(label: "Click effect") {
                    LDropdown(sel: m.bind(\.cursor.clickEffect),
                              options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow.click") })
                        .frame(width: 130)
                }
                SliderRow(label: "Click size", v: m.bind(\.cursor.clickSize), range: 0.5...2.0, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Click intensity", v: m.bind(\.cursor.clickIntensity), range: 0...1.5, fmt: { String(format: "%.1f×", $0) })
                Row(label: "Click color") {
                    ColorPicker("", selection: clickColor(m), supportsOpacity: true).labelsHidden()
                }
                SliderRow(label: "Click duration", v: m.bind(\.cursor.clickDuration), range: 0.2...0.9, fmt: { String(format: "%.2f s", $0) })
                Text("Glass bloom is baked into the Metal renderer. SwiftUI Liquid Glass macOS 26 APIs cannot run inside that renderer, so editor UI only uses the material fallback.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ToggleRow(label: "Constant size", on: m.bind(\.cursor.constantSize))
                ToggleRow(label: "Loop position", on: Binding(get: { m.timeline.cursor.loop != nil }, set: { v in m.edit { $0.cursor.loop = v ? 1.2 : nil } }))
                SliderRow(label: "Press scale", v: m.bind(\.cursor.pressScale), range: 0.7...1)
                SliderRow(label: "Zoom comp.", v: m.bind(\.cursor.zoomCompensation), range: 0...1)
            }.card(padding: 16)
        }
    }

    private var camera: some View {
        let m = model
        // "Smoothness" 0...1 maps onto the spring omegas (lower omega = floatier)
        let smooth = Binding<Double>(get: { (14 - m.timeline.camera.omegaPan) / 11 },
                                     set: { s in m.edit(coalesce: true) { $0.camera.omegaPan = 14 - 11 * s; $0.camera.omegaZoom = 12 - 9 * s } })
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
                Row(label: "Preset") { LDropdown(sel: Binding(get: { m.timeline.camera.preset }, set: { v in m.edit { $0.camera.apply(preset: v) } }), options: ZoomPreset.allCases.map { ($0, $0.rawValue.capitalized, "plus.magnifyingglass") }).frame(width: 130) }
                Row(label: "Tilt") { LDropdown(sel: m.bind(\.camera.tilt), options: TiltMode.allCases.map { ($0, $0.rawValue.capitalized, "move.3d") }).frame(width: 130) }
                SliderRow(label: "Max zoom", v: m.bind(\.camera.maxScale), range: 1.2...6.0, fmt: { String(format: "%.2f×", $0) })
                Row(label: "Max upscale") { LDropdown(sel: m.bind(\.camera.upscaleMaxFactor), options: [2, 3, 4, 5, 6, 8, 10].map { ($0, "\($0)×", "arrow.up.right.and.arrow.down.right") }).frame(width: 130) }
                ToggleRow(label: "Real-time upscale", on: m.bind(\.camera.upscaleEnabled))
                SliderRow(label: "Min zoom", v: m.bind(\.camera.minScale), range: 1.0...2.5, fmt: { String(format: "%.2f×", $0) })
                SliderRow(label: "Smoothness", v: smooth, range: 0...1)
            }.card(padding: 16)
            VStack(spacing: 0) {
                SliderRow(label: "Dead zone", v: m.bind(\.camera.deadZone), range: 0.1...0.45)
                SliderRow(label: "Click weight", v: m.bind(\.camera.clickWeight), range: 1...8, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Motion blur", v: m.bind(\.camera.shutter), range: 0...1)
                SliderRow(label: "Hover sensitivity", v: m.bind(\.camera.sensitivity), range: 0...1,
                          fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Follow delay", v: m.bind(\.camera.followDelay), range: 0...0.5,
                          fmt: { "\(Int($0 * 1000)) ms" })
                SliderRow(label: "Focus X", v: m.bind(\.camera.centerOffsetX), range: (-0.2)...0.2,
                          fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Focus Y", v: m.bind(\.camera.centerOffsetY), range: (-0.2)...0.2,
                          fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Anticipation", v: m.bind(\.camera.leadIn), range: 0.15...0.30,
                          fmt: { "\(Int($0 * 1000)) ms" })
                SliderRow(label: "Zoom hold", v: m.bind(\.camera.tail), range: 0.8...1.5,
                          fmt: { String(format: "%.1f s", $0) })
                ToggleRow(label: "Focus debug", on: Binding(get: { m.zoomDebug }, set: { m.zoomDebug = $0 }))
            }.card(padding: 16)
        }
    }

    private var layout: some View {
        let kind = currentLayout
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                Row(label: "Layout") {
                    LDropdown(sel: layoutKind, options: LayoutKind.allCases.map {
                        ($0, $0 == .screenOnly ? "Screen only" : $0 == .cameraOverlay ? "Camera overlay"
                            : $0 == .cameraFullscreen ? "Camera fullscreen" : $0 == .cameraCutout ? "Cutout" : "Split", Self.layoutIcon($0))
                    }).frame(width: 150)
                }
                Row(label: "Camera size") {
                    HStack(spacing: 8) {
                        LSlider(value: layoutBinding(kind, \.size), range: 0.1...0.4, width: 100)
                        Text("\(Int(layoutBinding(kind, \.size).wrappedValue * 100))%")
                            .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2).frame(width: 40, alignment: .trailing)
                    }
                }
                Row(label: "Corner") {
                    LDropdown(sel: layoutBinding(kind, \.corner), options: WebcamLayout.Corner.allCases.map {
                        ($0, $0.rawValue, "rectangle.inset.filled")
                    }).frame(width: 130)
                }
                Row(label: "Shape") {
                    LSegmented(sel: layoutBinding(kind, \.shape), items: [(.circle, "Circle"), (.roundRect, "Square")]).frame(width: 130)
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                ToggleRow(label: "Mirror", on: layoutBinding(kind, \.mirror))
                ToggleRow(label: "Border", on: layoutBinding(kind, \.border))
                ToggleRow(label: "Auto framing", on: layoutBinding(kind, \.autoFrame))
            }.card(padding: 16)
            VStack(spacing: 0) {
                ToggleRow(label: "Avoid cursor", on: layoutBinding(kind, \.avoidCursor))
                Row(label: "Behind face") {
                    LSegmented(sel: layoutBinding(kind, \.behindFace), items: [(.move, "Move"), (.hide, "Hide"), (.fade, "Fade")]).frame(width: 170)
                }
                ToggleRow(label: "Hide on silence", on: layoutBinding(kind, \.hideOnSilence))
            }.card(padding: 16)
        }
    }

    private func highlightColor(_ m: EditorModel) -> Binding<Color> {
        Binding(get: {
            let c = m.timeline.captions.style.highlightColor
            return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
        }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            m.edit(coalesce: true) { timeline in
                timeline.captions.style.highlightColor = RGBA(r: Float(c.redComponent), g: Float(c.greenComponent), b: Float(c.blueComponent))
            }
        })
    }

    private var captions: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                ToggleRow(label: "Captions", on: m.bind(\.captions.enabled))
                Row(label: "Font") {
                    LDropdown(sel: m.bind(\.captions.style.font), options: CaptionFont.allCases.map {
                        ($0, $0.title, "textformat")
                    }).frame(width: 130)
                }
                Row(label: "Animation") {
                    LDropdown(sel: m.bind(\.captions.style.animation), options: CaptionAnimation.allCases.map {
                        ($0, $0.rawValue.capitalized, Self.captionAnimationIcon($0))
                    }).frame(width: 130)
                }
                Row(label: "Highlight") {
                    ColorPicker("Highlight", selection: highlightColor(m), supportsOpacity: false).labelsHidden()
                }
                DisclosureGroup("Advanced") {
                    Row(label: "Position") {
                        LDropdown(sel: m.bind(\.captions.style.position), options: CaptionPosition.allCases.map {
                            ($0, $0.rawValue.capitalized, Self.captionPositionIcon($0))
                        }).frame(width: 130)
                    }
                    Row(label: "Language") {
                        TextField("en-US", text: locale).textFieldStyle(.plain).font(AppType.body)
                            .padding(.horizontal, 12).frame(width: 130, height: 32)
                            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
                            .accessibilityLabel("Caption language")
                    }
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                SliderRow(label: "Size", v: m.bind(\.captions.style.size), range: 0.02...0.08, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Lines", v: maxLines, range: 1...3, fmt: { "\(Int($0))" })
                ToggleRow(label: "Word highlight", on: m.bind(\.captions.style.wordHighlight))
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Manual titles") {
                    LButton(title: "Add title", icon: "textformat", kind: .quiet) { m.addManualTitle() }
                }
                ForEach(m.timeline.overlays.texts) { title in
                    Row(label: "Text") {
                        TextField("Title", text: Binding(
                            get: { m.timeline.overlays.texts.first(where: { $0.id == title.id })?.text ?? title.text },
                            set: { m.dispatch(.editText(title.id, $0)) }
                        ))
                        .textFieldStyle(.plain)
                        .font(AppType.body)
                        .accessibilityLabel("Manual overlay text")
                        LButton(title: "Remove", icon: "trash", kind: .quiet) {
                            m.dispatch(.deleteText(title.id))
                        }
                    }
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Spotlights") {
                    LButton(title: "Add highlight", icon: "highlighter", kind: .quiet) { m.addManualHighlight() }
                }
                ForEach(m.timeline.overlays.highlights) { highlight in
                    Row(label: "Style") {
                        LDropdown(sel: Binding(
                            get: { m.timeline.overlays.highlights.first(where: { $0.id == highlight.id })?.style ?? highlight.style },
                            set: { m.dispatch(.setHighlightStyle(highlight.id, $0)) }
                        ), options: HighlightStyle.allCases.map {
                            ($0, $0.rawValue.capitalized, "highlighter")
                        }).frame(width: 120)
                        LButton(title: "Remove", icon: "trash", kind: .quiet) {
                            m.dispatch(.deleteHighlight(highlight.id))
                        }
                    }
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                Row(label: "Magnifier") {
                    LButton(title: "Add loupe", icon: "plus.magnifyingglass", kind: .quiet) { m.addLoupe() }
                }
                ForEach(m.timeline.overlays.loupes) { loupe in
                    VStack(spacing: 0) {
                        HStack {
                            Text(String(format: "%.1fs", loupe.start)).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                            Spacer()
                            LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.deleteLoupe(loupe.id)) }
                        }
                        SliderRow(label: "Zoom", v: loupeBinding(loupe, \.magnification), range: 1.2...6,
                                  fmt: { String(format: "%.1f×", $0) })
                        SliderRow(label: "Glass size", v: loupeBinding(loupe, \.radius), range: 0.04...0.3,
                                  fmt: { "\(Int($0 * 100))%" })
                        SliderRow(label: "Border", v: loupeBinding(loupe, \.border), range: 0.001...0.02,
                                  fmt: { String(format: "%.0f‰", $0 * 1000) })
                        SliderRow(label: "X", v: loupeBinding(loupe, \.cx), range: 0.05...0.95)
                        SliderRow(label: "Y", v: loupeBinding(loupe, \.cy), range: 0.05...0.95)
                        ToggleRow(label: "Follow cursor", on: Binding(
                            get: { m.timeline.overlays.loupes.first(where: { $0.id == loupe.id })?.follow ?? loupe.follow },
                            set: { value in
                                var l = m.timeline.overlays.loupes.first(where: { $0.id == loupe.id }) ?? loupe
                                l.follow = value; m.updateLoupe(l)
                            }))
                    }
                }
            }.card(padding: 16)
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Text("Transcript").font(AppType.title).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s2)
                    LButton(title: "Remove fillers", icon: "text.badge.xmark", kind: .quiet) { m.removeFillerWords() }
                }
                if m.transcriptWords.isEmpty {
                    Text("Transcript appears after speech analysis finishes.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                } else {
                    Text("Edit a word to fix a caption; delete removes it from captions and the cut map.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                    ForEach(Array(m.transcriptWords.prefix(200).enumerated()), id: \.offset) { index, word in
                        let deleted = m.timeline.captions.deletedWords.contains(index)
                        HStack(spacing: Space.s2) {
                            Text(String(format: "%.1f", word.start))
                                .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2).frame(width: 42, alignment: .trailing)
                            TextField("Word", text: Binding(
                                get: { m.timeline.captions.textEdits[String(index)] ?? word.text },
                                set: { m.editTranscriptWord(index, $0) }))
                                .textFieldStyle(.plain).font(AppType.body)
                                .strikethrough(deleted).foregroundStyle(deleted ? Tok.text2 : Tok.text)
                            LButton(title: deleted ? "Restore" : "Delete", kind: .quiet) {
                                m.setTranscriptWord(index, deleted: !deleted)
                            }
                        }
                    }
                }
            }.card(padding: 16)
            TranscriptTab(model: model)
        }
    }

    private var privacy: some View {
        let m = model
        let detected = m.timeline.derived?.autoMasks.count ?? 0
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                ToggleRow(label: "Detect sensitive data", on: m.bind(\.overlays.privacy.autoDetect))
                Row(label: "Mask style") {
                    LDropdown(sel: m.bind(\.overlays.privacy.mode), options: MaskMode.allCases.map {
                        ($0, $0.rawValue.capitalized, Self.maskModeIcon($0))
                    }).frame(width: 130)
                }
                SliderRow(label: "Padding", v: m.bind(\.overlays.privacy.padding), range: 0...24, fmt: { "\(Int($0)) px" })
                SliderRow(label: "Sensitivity", v: m.bind(\.overlays.privacy.entropyThreshold), range: 3...4.5, fmt: { String(format: "%.1f", $0) })
                if m.timeline.overlays.privacy.mode == .blur || m.timeline.overlays.privacy.mode == .pixelate {
                    Text("Blur and pixelation are visual effects, not secure redaction. Use Blend or Solid to hide secrets.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if m.privacyScanning {
                    Text("Scanning for sensitive text. Export is disabled until the scan is applied.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = m.privacyScanError {
                    Text("Sensitive text scan failed: \(error)")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.card(padding: 16)
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Text("Manual masks").font(AppType.title).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s2)
                    LButton(title: m.maskEditing ? "Cancel" : "Draw mask",
                            icon: m.maskEditing ? "xmark" : "rectangle.dashed",
                            kind: .secondary) {
                        m.focusEditing = false
                        m.maskEditing.toggle()
                    }
                }
                Text(m.maskEditing
                     ? "Drag over the video to cover sensitive content."
                     : "Masks protect the selected region from the playhead to the end of this recording.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                ForEach(m.timeline.overlays.masks.filter { $0.origin == .manual }) { mask in
                    Row(label: String(format: "%.1fs", mask.start)) {
                        HStack(spacing: Space.s2) {
                            LDropdown(
                                sel: Binding(
                                    get: { m.timeline.overlays.masks.first(where: { $0.id == mask.id })?.mode ?? mask.mode },
                                    set: { value in
                                        m.edit { tl in
                                            if let i = tl.overlays.masks.firstIndex(where: { $0.id == mask.id }) {
                                                tl.overlays.masks[i].mode = value
                                            }
                                        }
                                    }),
                                options: MaskMode.allCases.map { ($0, $0.rawValue.capitalized, "eye.slash") })
                                .frame(width: 104)
                            LButton(title: "Remove", icon: "trash", kind: .quiet) {
                                m.edit { $0.overlays.masks.removeAll { $0.id == mask.id } }
                            }
                        }
                    }
                }
            }.card(padding: 16)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Automatic detection").font(AppType.title).foregroundStyle(Tok.text)
                Text(detected == 0 ? "No sensitive text found." : "\(detected) detected mask\(detected == 1 ? "" : "s") follow content through zooms.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            }.card(padding: 16)
        }
    }

    // MARK: Nested bindings

    private var currentLayout: LayoutKind {
        let source = model.timeline.timeMap.source(atOutput: model.playhead)
        return model.timeline.layouts.first { source >= $0.start && source < $0.end }?.kind
            ?? (model.timeline.webcam != nil ? .cameraOverlay : .screenOnly)
    }

    private var layoutKind: Binding<LayoutKind> {
        Binding(get: { currentLayout }, set: { kind in
            model.edit { timeline in
                timeline.layouts = [LayoutSegment(start: 0, end: timeline.timeMap.sourceDuration, kind: kind)]
            }
        })
    }

    private func layoutBinding<V>(_ kind: LayoutKind, _ keyPath: WritableKeyPath<LayoutSettings, V>) -> Binding<V> {
        Binding(get: { model.timeline.layoutSettings[kind][keyPath: keyPath] },
                set: { value in model.edit(coalesce: true) { $0.layoutSettings[kind][keyPath: keyPath] = value } })
    }

    private var maxLines: Binding<Double> {
        Binding(get: { Double(model.timeline.captions.maxLines) },
                set: { value in model.edit(coalesce: true) { $0.captions.maxLines = min(max(Int(value.rounded()), 1), 3) } })
    }

    private var locale: Binding<String> {
        Binding(get: { model.timeline.captions.locale },
                set: { value in model.edit(coalesce: true) { $0.captions.locale = value } })
    }

    private var audio: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                Row(label: "Studio mode") {
                    LDropdown(sel: m.bind(\.audio.studioMode),
                              options: StudioMode.allCases.map { ($0, $0.title, "waveform") })
                        .frame(width: 138)
                }
                Row(label: "Loudness") {
                    SliderRow(label: "Target", v: Binding(
                        get: { m.timeline.audio.targetLUFS },
                        set: { v in m.edit(coalesce: true) { tl in let mode = tl.audio.micMode; tl.audio.targetLUFSOverride = abs(v - mode.targetLUFS) < 1e-9 ? nil : v } }), range: -18...(-8),
                              fmt: { String(format: "%.0f LUFS", $0) })
                    .frame(width: 138)
                }
                Row(label: "Microphone") {
                    LDropdown(sel: m.bind(\.audio.micMode),
                              options: MicMode.allCases.map { ($0, $0.rawValue.capitalized, Self.micModeIcon($0)) })
                        .frame(width: 138)
                }
                ToggleRow(label: "Clean mic", on: m.bind(\.audio.micClean))
                Row(label: "Studio voice preset") {
                    LButton(title: "Enhance voice", icon: "waveform", kind: .quiet) {
                        m.edit {
                            $0.audio.micMode = .podcast
                            $0.audio.studio = 0.75
                            $0.audio.micClean = true
                            $0.audio.dereverb = 0
                        }
                    }
                }
                Row(label: "Natural voice") {
                    LButton(title: "Reset processing", icon: "arrow.counterclockwise", kind: .quiet) {
                        m.edit { $0.audio.micClean = false; $0.audio.dereverb = 0; $0.audio.studio = 0.25; $0.audio.micMode = .standard }
                    }
                }
                SliderRow(label: "Voice level", v: m.bind(\.audio.micGainDb), range: -18...12,
                          fmt: { String(format: "%+.0f dB", $0) })
                SliderRow(label: "Room echo", v: m.bind(\.audio.dereverb), range: 0...1,
                          fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "System level", v: m.bind(\.audio.systemGainDb), range: -24...6,
                          fmt: { String(format: "%+.0f dB", $0) })
                SliderRow(label: "Studio voice", v: m.bind(\.audio.studio), range: 0...1,
                          fmt: { "\(Int($0 * 100))%" })
                ToggleRow(label: "Click sounds", on: m.bind(\.audio.clickSounds))
                if m.timeline.audio.clickSounds {
                    Row(label: "Click tone") {
                        LDropdown(sel: m.bind(\.audio.clickTone),
                                  options: [(ClickSound.fresh, "Fresh", "cursorarrow.click"),
                                            (ClickSound.mouse, "Mouse", "cursorarrow.click"),
                                            (.subtle, "Subtle", "cursorarrow.click")]).frame(width: 130)
                    }
                    SliderRow(label: "Click level", v: m.bind(\.audio.sfxGainDb), range: -24...6,
                              fmt: { String(format: "%+.0f dB", $0) })
                    Row(label: "Preview") {
                        LButton(title: "Play click", icon: "speaker.wave.2", kind: .quiet) { m.previewClick() }
                    }
                }
                ToggleRow(label: "Zoom whooshes", on: m.bind(\.audio.whooshes))
                ToggleRow(label: "Typing sound", on: m.bind(\.audio.keySounds))
                if m.timeline.audio.keySounds {
                    Row(label: "Pack") {
                        LDropdown(sel: m.bind(\.audio.typingPackId),
                                  options: TypingPackLoader.availablePacks().map { ($0.lastPathComponent, $0.lastPathComponent, "keyboard") }
                                    .isEmpty ? [("mechvibes-default", "Mechvibes Default", "keyboard")] :
                                    TypingPackLoader.availablePacks().map { ($0.lastPathComponent, $0.lastPathComponent, "keyboard") }).frame(width: 180)
                    }
                    SliderRow(label: "Typing level", v: m.bind(\.audio.typingLevelDb), range: -18...0,
                              fmt: { String(format: "%+.0f dB", $0) })
                }
                ToggleRow(label: "Speed up idle spans", on: m.bind(\.audio.speedRampsAuto))
            }.card(padding: 16)
            VStack(spacing: 0) {
                MusicPicker(model: m)
                Row(label: "Voice-over") {
                    LButton(title: "Import…", icon: "waveform") { m.importVoiceover() }
                }
                ForEach(m.timeline.audio.lanes.filter { $0.role == .voiceover }) { lane in
                    Row(label: (lane.variant ?? "Voice") + " · " + (lane.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Recorded")) {
                        HStack(spacing: Space.s1) {
                            LButton(title: lane.mute ? "Unmute" : "Mute", kind: .quiet) {
                                m.edit { tl in
                                    if let i = tl.audio.lanes.firstIndex(where: { $0.id == lane.id }) {
                                        tl.audio.lanes[i].mute.toggle()
                                    }
                                }
                            }
                            LButton(title: "Remove", icon: "trash", kind: .quiet) {
                                m.edit { tl in tl.audio.lanes.removeAll { $0.id == lane.id } }
                            }
                        }
                    }
                }
                if m.timeline.audio.musicPath != nil {
                    SliderRow(label: "Music level", v: m.bind(\.audio.musicGainDb), range: -30...(-6), fmt: { "\(Int($0)) dB" })
                    Row(label: "Remove music") { LButton(title: "Remove", icon: "trash", kind: .quiet) { m.edit { $0.audio.musicPath = nil } } }
                }
                ToggleRow(label: "Auto loudness", on: m.bind(\.audio.normalize))
                SliderRow(label: "Trim", v: m.bind(\.audio.outputGainDb), range: -12...6,
                          fmt: { String(format: "%+.0f dB", $0) })
                Text("Music ducks under voice with 50 ms attack / 400 ms release; click cues stay above music. Idle ramps mute mic, not music.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                if let stats = m.mixStats {
                    Row(label: "Master") {
                        Text(String(format: "%.1f LUFS · peak %.1f dBTP", stats.lufs, stats.peak))
                            .font(AppType.caption.monospacedDigit())
                            .foregroundStyle(stats.peak > -1 ? Tok.statusBad : Tok.text2)
                    }
                }
            }.card(padding: 16)
        }
    }

    private var webcam: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
            Row(label: "Corner") { LDropdown(sel: layoutBinding(.cameraOverlay, \.corner),
                options: WebcamLayout.Corner.allCases.map { ($0, $0.rawValue, "rectangle.inset.filled") }).frame(width: 130) }
            SliderRow(label: "Size", v: layoutBinding(.cameraOverlay, \.size), range: 0.1...0.4)
            Row(label: "Shape") { LSegmented(sel: layoutBinding(.cameraOverlay, \.shape),
                                             items: [(.circle, "Circle"), (.roundRect, "Square")]).frame(width: 130) }
            ToggleRow(label: "Mirror", on: layoutBinding(.cameraOverlay, \.mirror))
            ToggleRow(label: "Border", on: layoutBinding(.cameraOverlay, \.border))
            ToggleRow(label: "Auto framing", on: layoutBinding(.cameraOverlay, \.autoFrame))
            SliderRow(label: "Face zoom", v: Binding(get: { m.timeline.webcam?.faceZoom ?? 0.6 }, set: { v in m.edit(coalesce: true) { $0.webcam?.faceZoom = v } }), range: 0...1)
            SliderRow(label: "Face size", v: Binding(get: { m.timeline.webcam?.faceFill ?? 0.31 }, set: { v in m.edit(coalesce: true) { $0.webcam?.faceFill = v } }), range: 0.2...0.5)
        }.card(padding: 16)
        VStack(spacing: 0) {
            Row(label: "Video polish") {
                LSegmented(sel: Binding(get: { m.timeline.webcam?.enhancement ?? .natural },
                                        set: { v in m.edit { $0.webcam?.enhancement = v } }),
                           items: [(.natural, "Natural"), (.crisp, "Crisp")]).frame(width: 156)
            }
            if m.timeline.webcam?.enhancement == .crisp {
                SliderRow(label: "Detail", v: Binding(get: { m.timeline.webcam?.detailAmount ?? 0.5 },
                                                    set: { v in m.edit(coalesce: true) { $0.webcam?.detailAmount = v } }),
                          range: 0...1, fmt: { "\(Int($0 * 100))%" })
            }
            Row(label: "Background") {
                LDropdown(sel: Binding(get: { m.timeline.webcam?.backdrop ?? .original },
                                      set: { v in m.edit { $0.webcam?.backdrop = v } }),
                          options: WebcamBackdrop.allCases.map { ($0, $0.rawValue, "person.crop.rectangle") })
                    .frame(width: 168)
            }
            if m.timeline.webcam?.backdrop == .image {
                Row(label: "Image") {
                    LButton(title: m.timeline.webcam?.backdropImagePath.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    } ?? "Choose image…", icon: "photo", kind: .secondary) {
                        m.importWebcamBackground()
                    }
                }
            }
            if m.timeline.webcam?.backdrop != .original {
                Text("Person mask generated locally using Vision. It may take time to analyze a recording.")
                    .font(AppType.caption).foregroundStyle(Tok.text2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Row(label: "4K output") {
                LToggle(on: Binding(get: { m.exportSettings.resolution == .ultraHD },
                                    set: { on in m.updateExportSettings { $0.resolution = on ? .source : .ultraHD } }),
                        label: "4K composition")
            }
            Text("4K output increases pixel dimensions; it cannot restore detail the camera never captured.")
                .font(AppType.caption).foregroundStyle(Tok.text2).frame(maxWidth: .infinity, alignment: .leading)
            }.card(padding: 16)
        }
    }

    private var export: some View { ExportInspector(model: model) }
}

extension Inspector.Tab {
    @MainActor
    static func visibleFor(model: EditorModel) -> [Inspector.Tab] {
        Inspector.Tab.allCases.filter { $0 != Inspector.Tab.webcam || model.timeline.webcam != nil }
    }

    static var primaryTabs: [Inspector.Tab] { [Inspector.Tab.camera, Inspector.Tab.cursor, Inspector.Tab.captions, Inspector.Tab.audio] }

    var isPrimary: Bool {
        switch self { case Inspector.Tab.camera, Inspector.Tab.cursor, Inspector.Tab.captions, Inspector.Tab.audio: return true; default: return false }
    }

    @MainActor static func moreTabs(for model: EditorModel) -> [Inspector.Tab] {
        visibleFor(model: model).filter { !primaryTabs.contains($0) }
    }
}
