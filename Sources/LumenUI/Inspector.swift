import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenExport
import LumenAudio
import LumenCapture

struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case background = "Studio", tools = "Tools", cursor = "Cursor", camera = "Camera", layout = "Layout", webcam = "Webcam", captions = "Captions", timeline = "Timeline", privacy = "Privacy", audio = "Audio", export = "Export" }


    static func visibleFor(model: EditorModel) -> [Inspector.Tab] {
        Inspector.Tab.allCases.filter { $0 != Inspector.Tab.webcam || model.timeline.webcam != nil }
    }
    @Binding var tab: Inspector.Tab
    var width: CGFloat = Metrics.inspector
    @State private var presets: [LookPreset] = []
    @State private var newName = ""

    // Per-option Apple icons for inspector menus.
    private static func canvasIcon(_ c: CanvasAspect) -> String {
        switch c { case .r16x9: "rectangle"; case .r16x10: "rectangle"; case .r4x3: "rectangle.righthalf.inset.filled"; case .r5x4: "rectangle"; case .r3x2: "rectangle"; case .r1x1: "square"; case .r4x5: "rectangle.portrait"; case .r9x16: "rectangle.portrait"; case .r21x9: "aspectratio" }
    }
    private static func layoutIcon(_ k: LayoutKind) -> String {
        switch k { case .screenOnly: "display"; case .cameraOverlay: "rectangle.3.group"; case .split: "rectangle.split.2x1"; case .cameraFullscreen: "video"; case .cameraCutout: "person" }
    }
    private static func micModeIcon(_ m: MicMode) -> String {
        switch m { case .standard: "mic"; case .loud: "mic.fill"; case .podcast: "waveform.and.mic"; case .off: "mic.slash" }
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
                    else if saved == "Background" { tab = .background }
                    else if let t = Inspector.Tab(rawValue: saved) { tab = t }
                } else {
                    tab = .background
                }
            }
            // The presets live on disk: read them on a worker so opening the
            // editor never waits for the filesystem.
            .task { presets = await EditorModel.loadPresetsOffMain() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            tabSelector
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            if tab == .export {
                ExportInspector(model: model).pinned
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
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
        VStack(spacing: 0) {
            LButton(title: "Import clip", icon: "film") { model.importClips() }
                .frame(maxWidth: .infinity, alignment: .leading)
            LButton(title: "Add title", icon: "textformat") { model.addManualTitle() }
                .frame(maxWidth: .infinity, alignment: .leading)
            LButton(title: "Add highlight", icon: "highlighter") { model.addManualHighlight() }
                .frame(maxWidth: .infinity, alignment: .leading)
            LButton(title: "Speed 2×", icon: "gauge") { addSpeedRamp(speed: 2) }
                .frame(maxWidth: .infinity, alignment: .leading)
            SliderRow(label: "Cursor size", v: model.bind(\.cursor.size), range: 0.5...2.5)
            SliderRow(label: "Smoothing", v: model.bind(\.cursor.smoothingSigma), range: 0...0.12, fmt: { "\(Int($0 * 1000)) ms" })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func addSpeedRamp(speed: Double) {
        let tm = model.timeline.timeMap
        let sOut = model.playhead
        let eOut = min(sOut + 2.0, tm.outputDuration)
        guard eOut > sOut else { return }
        let sSrc = tm.source(atOutput: sOut)
        let eSrc = tm.source(atOutput: eOut)
        guard eSrc > sSrc else { return }
        model.dispatch(.addSpeedRamp(start: sSrc, end: eSrc, speed: speed))
    }

    private func icon(_ t: Inspector.Tab) -> String {
        switch t {
        case .background: "photo.stack"
        case .tools: "slider.horizontal.3"; case .cursor: "cursorarrow"; case .camera: "video"
        case .layout: "rectangle.3.group"; case .audio: "waveform"; case .webcam: "person.crop.circle"
        case .captions: "captions.bubble"; case .timeline: "timeline.selection"; case .privacy: "lock"; case .export: "square.and.arrow.up"
        }
    }

    /// The background picker presents its four actual sources as one tab row.
    enum WallpaperSource: String, CaseIterable, Identifiable {
        case painting = "Painting"
        case macOS = "macOS"
        case canvas = "Canvas"
        case dither = "Dither"
        var id: String { rawValue }
    }

    struct WallpaperChoice: Identifiable {
        var id: String { url.path }
        var displayName: String
        var url: URL
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
                if last.lowercased().hasPrefix("cma-") || last.lowercased().hasPrefix("met-") || last.lowercased() == "cma" {
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

    private static func wallpaperChoices() -> [WallpaperSource: [WallpaperChoice]] {
        var out: [WallpaperSource: [WallpaperChoice]] = [.macOS: [], .painting: []]
        var seen = Set<String>()
        func add(_ url: URL, to source: WallpaperSource) {
            let name = humanizedName(for: url)
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out[source, default: []].append(WallpaperChoice(displayName: name, url: url))
        }
        func collect(_ root: URL, into source: WallpaperSource) {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard wallpaperExtensions.contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard Self.isUsableWallpaper(f) else { continue }
                add(f, to: source)
            }
        }
        // Bundled gallery (packaged app + source assets for `swift run`).
        if let root = AppAssets.directory(bundlePath: "Wallpapers", sourcePaths: ["App/public/assets/wallpapers", "wallpapers"]) {
            collect(root.appendingPathComponent("macos"), into: .macOS)
            collect(root.appendingPathComponent("paintings"), into: .painting)
        }
        // Every macOS wallpaper on this Mac (14/15/26 incl. Dynamic).
        let sysDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        if FileManager.default.fileExists(atPath: sysDir.path),
           let en = FileManager.default.enumerator(at: sysDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "png", "tiff", "webp"].contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard Self.isUsableWallpaper(f) else { continue }
                add(f, to: .macOS)
            }
        }
        for key in out.keys {
            out[key]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return out
    }

    /// Solid colours and gradients are not wallpapers, and a thumbnail-sized
    /// file is not a wallpaper either. Both used to reach the grid.
    private static func isUsableWallpaper(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let junk = ["grid", "chroma", "hello", "solid", "gradient", "colorful", "aurora", "bubble", "shade", "radial"]
        if junk.contains(where: { name.contains($0) }) { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat else { return true }
        return width >= 2560
    }

    @State private var wallpaperSource: WallpaperSource = .painting
    @State private var wallpaperSelectTask: Task<Void, Never>?

    private var wallpaperList: some View {
        let choices = Self.wallpaperChoices()[wallpaperSource] ?? []
        return VStack(spacing: 12) {
            LSegmented(sel: Binding(get: { wallpaperSource }, set: { source in selectWallpaperSource(source) }),
                       items: WallpaperSource.allCases.map { ($0, $0.rawValue) })
                .frame(maxWidth: .infinity)
            switch wallpaperSource {
            case .painting, .macOS:
                WallpaperGrid(model: model, choices: choices) { choice in
                    wallpaperSelectTask?.cancel()
                    wallpaperSelectTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        model.edit { $0.style.setPhotoBackground(choice.url.path) }
                    }
                }
                SliderRow(label: "Blur", v: model.bind(\.style.wallpaperBlur), range: 0...60,
                          fmt: { "\(Int($0))" })
                SliderRow(label: "Opacity", v: model.bind(\.style.imageOpacity), range: 0...1, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Contrast", v: model.bind(\.style.imageContrast), range: 0...2, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Brightness", v: model.bind(\.style.imageBrightness), range: 0...2, fmt: { "\(Int($0 * 100))%" })
            case .canvas, .dither:
                generatedBackgroundControls
            }
        }
        .onAppear(perform: syncWallpaperSource)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var generatedBackgroundControls: some View {
        if wallpaperSource == .canvas {
            VStack(spacing: 0) {
                SliderRow(label: "Canvas speed", v: model.bind(\.style.canvasSpeed), range: -2...2,
                          fmt: { String(format: "%.1f×", $0) })
                CanvasPresetGrid(model: model)
            }
        } else {
            VStack(spacing: 0) {
                DitherPaletteGrid(model: model, kind: .dither)
                ToggleRow(label: "Saturation", on: model.bind(\.style.ditherSaturation))
            }
        }
    }

    private func selectWallpaperSource(_ source: WallpaperSource) {
        wallpaperSource = source
        switch source {
        case .painting, .macOS:
            let choices = Self.wallpaperChoices()[source] ?? []
            let currentPath = model.timeline.style.backgroundImagePath
            let choice = choices.first { $0.url.path == currentPath } ?? choices.first
            if model.timeline.style.background == .image, choice?.url.path == currentPath { return }
            model.edit { style in
                if let choice { style.style.setPhotoBackground(choice.url.path) }
                else { style.style.background = .image }
            }
        case .canvas:
            let currentStyle = model.timeline.style
            let selectedPreset = CanvasPresets.all.first { $0.id == currentStyle.canvasPresetID }
            let hasCanvasPreset = selectedPreset != nil
            guard currentStyle.background != .canvas || !hasCanvasPreset else { return }
            let preset = selectedPreset ?? CanvasPresets.all[0]
            model.edit { style in
                style.style.background = .canvas
                style.style.canvasPresetID = preset.id
                style.style.colors = preset.colors
                style.style.gradientAngle = preset.angle
            }
        case .dither:
            let paletteExists = DitherPalettes.all.contains { $0.1 == model.timeline.style.colors }
            guard model.timeline.style.background != .dither || !paletteExists else { return }
            model.edit { style in
                style.style.background = .dither
                if !paletteExists { style.style.colors = DitherPalettes.all[0].1 }
            }
        }
    }

    private func syncWallpaperSource() {
        switch model.timeline.style.background {
        case .canvas: wallpaperSource = .canvas
        case .dither: wallpaperSource = .dither
        case .wallpaper: wallpaperSource = .macOS
        case .image:
            let path = model.timeline.style.backgroundImagePath?.lowercased() ?? ""
            wallpaperSource = path.contains("/wallpapers/macos/")
                || path.hasPrefix("/system/library/desktop pictures/") ? .macOS : .painting
        default: wallpaperSource = .painting
        }
    }

    private var backgroundPage: some View {
        let m = model
        return VStack(spacing: 16) {
            MusicPicker(model: m).card(padding: 16)
            VStack(spacing: 0) {
                if m.session.webcam != nil {
                    ToggleRow(label: "Show face cam", on: Binding(get: { m.timeline.webcam != nil }, set: { m.setWebcam($0) }))
                }
                wallpaperList
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
                    LButton(title: "Save", kind: .secondary, height: 32) { if !newName.isEmpty { m.savePreset(newName); Task { presets = await EditorModel.loadPresetsOffMain() }; newName = "" } }
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
                    VStack(spacing: 8) {
                        LButton(title: "Split at playhead", icon: "scissors", kind: .quiet) { m.splitAtPlayhead() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LButton(title: "Duplicate", icon: "doc.on.doc", kind: .quiet) { m.duplicateSelected() }
                            .disabled(m.selection == nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Row(label: "Ripple") {
                    VStack(spacing: 8) {
                        LButton(title: "Ripple delete", icon: "trash", kind: .quiet) { m.rippleDeleteSelected() }
                            .disabled(m.selection == nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LButton(title: "Split recording", icon: "scissors", kind: .quiet) { m.splitRecordingAtPlayhead() }
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                ToggleRow(label: "Snap", on: Binding(
                    get: { m.snapEnabled },
                    set: { m.snapEnabled = $0 }))
            }.card(padding: 16)
        }
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
                ToggleRow(label: "Constant size", on: m.bind(\.cursor.constantSize))
                ToggleRow(label: "Loop position", on: Binding(get: { m.timeline.cursor.loop != nil }, set: { v in m.edit { $0.cursor.loop = v ? 1.2 : nil } }))
                SliderRow(label: "Press scale", v: m.bind(\.cursor.pressScale), range: 0.7...1)
                SliderRow(label: "Zoom comp.", v: m.bind(\.cursor.zoomCompensation), range: 0...1)
            }.card(padding: 16)
        }
    }

    private var camera: some View {
        let m = model
        // Zoom v3: Auto zoom · Zoom amount · Smoothness on top. Smoothness is
        // the lead-in (0.3-1.0 s); the camera arrives 95% at the click.
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
                SliderRow(label: "Zoom amount", v: Binding(get: { m.timeline.camera.baseScale },
                                        set: { v in m.edit { $0.camera.baseScale = v } }),
                          range: 1.3...3.0, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothness", v: m.bind(\.camera.leadIn), range: 0.3...1.0,
                          fmt: { "\(Int($0 * 1000)) ms" })
                Row(label: "Preset") { LDropdown(sel: Binding(get: { m.timeline.camera.preset }, set: { v in m.edit { $0.camera.apply(preset: v) } }), options: ZoomPreset.allCases.map { ($0, $0.rawValue.capitalized, "plus.magnifyingglass") }).frame(width: 130) }
            }.card(padding: 16)
            DisclosureGroup("Advanced") {
                VStack(spacing: 0) {
                    Row(label: "Tilt") { LDropdown(sel: m.bind(\.camera.tilt), options: TiltMode.allCases.map { ($0, $0.rawValue.capitalized, "move.3d") }).frame(width: 130) }
                    SliderRow(label: "Max zoom", v: m.bind(\.camera.maxScale), range: 1.2...6.0, fmt: { String(format: "%.2f×", $0) })
                    Row(label: "Max upscale") { LDropdown(sel: m.bind(\.camera.upscaleMaxFactor), options: [2, 3, 4, 5, 6, 8, 10].map { ($0, "\($0)×", "arrow.up.right.and.arrow.down.right") }).frame(width: 130) }
                    ToggleRow(label: "Real-time upscale", on: m.bind(\.camera.upscaleEnabled))
                    SliderRow(label: "Min zoom", v: m.bind(\.camera.minScale), range: 1.0...2.5, fmt: { String(format: "%.2f×", $0) })
                    SliderRow(label: "Zoom-out delay", v: m.bind(\.camera.zoomOutGap), range: 2.0...6.0,
                              fmt: { String(format: "%.1f s", $0) })
                    SliderRow(label: "Hold", v: m.bind(\.camera.hold), range: 0.5...2.5,
                              fmt: { String(format: "%.1f s", $0) })
                    SliderRow(label: "Safe zone", v: m.bind(\.camera.safeZone), range: 0.4...0.8,
                              fmt: { String(format: "%.2f", $0) })
                    SliderRow(label: "Motion blur", v: m.bind(\.camera.shutter), range: 0...1)
                    SliderRow(label: "Follow delay", v: m.bind(\.camera.followDelay), range: 0...0.5,
                              fmt: { "\(Int($0 * 1000)) ms" })
                    SliderRow(label: "Focus X", v: m.bind(\.camera.centerOffsetX), range: (-0.2)...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Focus Y", v: m.bind(\.camera.centerOffsetY), range: (-0.2)...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                    ToggleRow(label: "Focus debug", on: Binding(get: { m.zoomDebug }, set: { m.zoomDebug = $0 }))
                }.card(padding: 16)
            }
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

    private var captions: some View {
        let m = model
        return VStack(spacing: 16) {
            // One source of truth: on, two faces, one size. Everything else
            // (animation, lines, highlight colour, position, language) was a
            // decision the caption should make for itself.
            VStack(spacing: 0) {
                ToggleRow(label: "Captions", on: m.bind(\.captions.enabled))
                Row(label: "Font") {
                    LSegmented(sel: m.bind(\.captions.style.font), items: [(.sans, "Sans"), (.serif, "Serif")])
                        .frame(width: 170)
                }
                SliderRow(label: "Size", v: m.bind(\.captions.style.size), range: 0.03...0.09,
                          fmt: { "\(Int($0 * 100))%" })
            }.card(padding: 16)
            // Manual titles are their own overlays, not caption settings: the
            // text block is authored here and rendered by the same Metal pass.
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
                Row(label: "Style") {
                    LDropdown(sel: m.bind(\.overlays.privacy.mode), options: [
                        (.blur, "Frost", "drop"), (.pixelate, "Pixelate", "square.grid.3x3"), (.solid, "Redact", "rectangle.fill")
                    ]).frame(width: 130)
                }
                SliderRow(label: "Pixel size", v: m.bind(\.overlays.privacy.pixelSize), range: 0...64,
                          fmt: { $0 < 1 ? "Auto" : "\(Int($0)) px" })
                SliderRow(label: "Padding", v: m.bind(\.overlays.privacy.padding), range: 0...24, fmt: { "\(Int($0)) px" })
                SliderRow(label: "Sensitivity", v: Binding(
                    get: { clamp((4.2 - m.timeline.overlays.privacy.entropyThreshold) / 1.4, 0, 1) },
                    set: { value in m.edit(coalesce: true) { $0.overlays.privacy.entropyThreshold = 4.2 - value * 1.4 } }
                ), range: 0...1, fmt: { "\(Int($0 * 100))%" })
                if m.privacyScanning {
                    Text("Scanning sensitive text: \(Int(m.privacyScanProgress * 100))%. Export waits for the masks to be applied.")
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

    private var audio: some View {
        let m = model
        let soundEffectsEnabled = m.timeline.audio.soundEffectsEnabled
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                SliderRow(label: "Noise reduction", v: Binding(
                    get: { m.timeline.audio.noiseReductionStrength },
                    set: { value in m.edit(coalesce: true) {
                        $0.audio.noiseReductionStrength = value
                        $0.audio.micClean = value > 0
                    } }), range: 0...1, fmt: { "\(Int($0 * 100))%" })
                LButton(title: "Voice Isolation…", icon: "mic.badge.plus", kind: .quiet) {
                    MicrophoneModes.showVoiceIsolationControls()
                }
            }.card(padding: 16)
            VStack(spacing: 0) {
                ToggleRow(label: "Sound effects", on: m.bind(\.audio.soundEffectsEnabled))
                SliderRow(label: "Zoom in", v: m.bind(\.audio.zoomInGainDb), range: -24...6,
                          fmt: { "\(Int($0)) dB" })
                    .disabled(!soundEffectsEnabled)
                SliderRow(label: "Zoom out", v: m.bind(\.audio.zoomOutGainDb), range: -24...6,
                          fmt: { "\(Int($0)) dB" })
                    .disabled(!soundEffectsEnabled)
                SliderRow(label: "Cursor click", v: m.bind(\.audio.clickGainDb), range: -24...6,
                          fmt: { "\(Int($0)) dB" })
                    .disabled(!soundEffectsEnabled)
                SliderRow(label: "Typing", v: m.bind(\.audio.typingLevelDb), range: -18...0,
                          fmt: { "\(Int($0)) dB" })
                    .disabled(!soundEffectsEnabled)
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
            }
            Row(label: "4K output") {
                LToggle(on: Binding(get: { m.exportSettings.resolution == .ultraHD },
                                    set: { on in m.updateExportSettings { $0.resolution = on ? .source : .ultraHD } }),
                        label: "4K composition")
            }
            }.card(padding: 16)
        }
    }

    private var export: some View { ExportInspector(model: model) }
}

/// 2-column, 16:10, 8pt gaps. Thumbnails decode off the main thread at 2x
/// cell size and cache on disk; the grid never decodes full-res. No text,
/// badges, blur, shadow or material per cell — only the accent ring.
private struct WallpaperGrid: View {
    let model: EditorModel
    let choices: [Inspector.WallpaperChoice]
    let onSelect: (Inspector.WallpaperChoice) -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(choices) { choice in
                WallpaperCell(choice: choice,
                              selected: model.timeline.style.background == .image
                                  && model.timeline.style.backgroundImagePath == choice.url.path,
                              onSelect: { onSelect(choice) })
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A Sendable snapshot of decoded thumb pixels. NSImage is not Sendable, so
/// the cache moves Data across its boundary and the cell builds the image on
/// the main actor (`WallpaperCell.thumb`), which also decodes the disk path.
private struct WallpaperThumbData: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct WallpaperCell: View {
    let choice: Inspector.WallpaperChoice
    let selected: Bool
    let onSelect: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .clipped()
                } else {
                    Color.clear
                        .aspectRatio(16 / 10, contentMode: .fill)
                }
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Tok.accent, lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
        .accessibilityLabel(choice.displayName)
        .accessibilityValue(selected ? "Selected" : "")
        .task(id: choice.url.path) {
            guard let snapshot = await WallpaperThumbnailCache.shared.thumbnail(for: choice.url) else { return }
            thumb = NSImage(data: snapshot.data)
        }
    }
}

/// Disk-cached 2x thumbnails. Full-res is never touched by the grid;
/// picking a cell edits the timeline and the renderer loads full-res async.
private actor WallpaperThumbnailCache {
    static let shared = WallpaperThumbnailCache()
    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen/WallpaperThumbs", isDirectory: true)
    }
    private var memory: [String: WallpaperThumbData] = [:]

    func thumbnail(for url: URL) async -> WallpaperThumbData? {
        let key = cacheKey(for: url)
        if let hit = memory[key] { return hit }
        if let disk = diskImage(for: key) {
            memory[key] = disk
            return disk
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.makeThumbnail(at: url, targetWidth: 280)
        }.value
        if let snapshot {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? snapshot.data.write(to: directory.appendingPathComponent(key), options: .atomic)
            memory[key] = snapshot
        }
        return snapshot
    }

    private func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        return "\(stem)-\(Int(stamp))-\(size)-280.jpg"
    }

    private func diskImage(for key: String) -> WallpaperThumbData? {
        let url = directory.appendingPathComponent(key)
        guard let data = FileManager.default.contents(atPath: url.path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return WallpaperThumbData(data: data, pixelWidth: w, pixelHeight: h)
    }

    private nonisolated static func makeThumbnail(at url: URL, targetWidth: Int) -> WallpaperThumbData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: targetWidth,
        ] as CFDictionary) else { return nil }
        guard let data = cg.asBitmapData() else { return nil }
        return WallpaperThumbData(data: data, pixelWidth: cg.width, pixelHeight: cg.height)
    }
}

extension CGImage {
    /// Renders the image to JPEG data, fully off the main thread.
    nonisolated func asBitmapData() -> Data? {
        let width = self.width, height = self.height
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
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
