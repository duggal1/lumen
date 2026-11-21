import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenRender
import LumenExport
import LumenAudio
import LumenCapture

/// Pure state mapping for the Studio's 3D (tilt) control. Kept free of SwiftUI
/// so the enable/disable contract is exercised headlessly, and so the toggle,
/// the style segmented control and the model all read the same single setting:
/// `CameraParams.tilt`. `.off` is disabled; any other mode is enabled.
enum Cinematic3D {
    /// Mode selected the first time 3D is switched on. Matches the cinematic
    /// preset's own choice, so the toggle never disagrees with the preset.
    static let enabledMode: TiltMode = .lean

    static func isEnabled(_ mode: TiltMode) -> Bool { mode != .off }

    /// Toggling on from `.off` selects the default; toggling off always returns
    /// to `.off`. Re-enabling never silently replaces a style the user picked.
    static func mode(_ current: TiltMode, enabling: Bool) -> TiltMode {
        enabling ? (current == .off ? enabledMode : current) : .off
    }

    /// The visual styles offered once 3D is on. `.off` is the toggle's job,
    /// never a fourth segment of the style control.
    static let styles: [(TiltMode, String)] = [(.lean, "Lean"), (.reveal, "Reveal")]

    static func label(_ mode: TiltMode) -> String {
        switch mode {
        case .off: "3D motion, off"
        case .lean: "3D motion, lean"
        case .reveal: "3D motion, reveal"
        }
    }

    /// A quiet readout under the style control (a tooltip's job, without a tooltip).
    static func hint(_ mode: TiltMode) -> String {
        switch mode {
        case .off: "Flat 2D framing."
        case .lean: "The frame banks with cursor motion."
        case .reveal: "Each zoom enters at an angle, then settles."
        }
    }
}

/// The right side of the editor. Rebuilt around the dieother theme: near-black
/// neutral chrome, one accent (signal orange), breathing room, nothing that
/// exists without earning its place.
struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case studio = "Studio", cursor = "Cursor", tools = "Tools", webcam = "Webcam", captions = "Captions", timeline = "Timeline", privacy = "Privacy", audio = "Audio", export = "Export" }

    @Binding var tab: Inspector.Tab
    var width: CGFloat = Metrics.inspector
    @State private var presets: [LookPreset] = []

    var body: some View {
        content
            .onChange(of: model.exportPanelRequest) { _, _ in tab = .export }
            .onChange(of: tab) { _, selected in
                model.exportPanelActive = selected == .export
                UserDefaults.standard.set(selected.rawValue, forKey: "lumen.inspector.tab")
            }
            .onAppear {
                if let saved = UserDefaults.standard.string(forKey: "lumen.inspector.tab"),
                   let t = Inspector.Tab(rawValue: saved) { tab = t } else { tab = .studio }
            }
            .task { presets = await EditorModel.loadPresetsOffMain() }
            .task {
                let choices = await Task.detached(priority: .utility) { Inspector.loadWallpaperChoices() }.value
                wallpaperChoices = choices
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            tabSelector
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .onAppear {}
            if tab == .export {
                ExportInspector(model: model).pinned
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            ScrollView {
                tabBody
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Tok.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested))
    }

    /// One dropdown at the top of the panel. Full names, nothing truncated.
    private var tabSelector: some View {
        LDropdown(sel: $tab, options: Inspector.Tab.allCases
            .filter { $0 != .webcam || model.timeline.webcam != nil }
            .map { ($0, $0.rawValue, Self.icon($0)) })
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Inspector section: \(tab.rawValue)")
    }

    @ViewBuilder private var tabBody: some View {
        switch tab {
        case .studio: studio
        case .cursor: cursor
        case .tools: tools
        case .audio: audio
        case .webcam: webcam
        case .captions: captions
        case .timeline: timelineTab
        case .privacy: privacy
        case .export: export
        }
    }

    // MARK: - Studio

    private var studio: some View {
        let m = model
        return VStack(spacing: 16) {
            MusicPicker(model: m)
            VStack(spacing: 0) {
                Row(label: "Canvas") {
                    LDropdown(sel: m.bind(\.style.canvas), options: CanvasAspect.allCases.map { ($0, $0.title, Self.canvasIcon($0)) }).frame(width: 130)
                }
                SliderRow(label: "Video size", v: m.bind(\.style.contentScale), range: 0.5...2.0, fmt: { "\(Int($0 * 100))%" })
                if m.timeline.style.paddingInsets == nil {
                    SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                }
                SliderRow(label: "Radius", v: m.bind(\.style.cornerRadius), range: 0...40, fmt: { "\(Int($0))" })
                ToggleRow(label: "Frame", on: m.bind(\.style.innerBorder))
                if m.timeline.style.innerBorder {
                    SliderRow(label: "Weight", v: m.bind(\.style.frameWeight), range: 0...4, fmt: { "\(Int($0)) pt" })
                }
            }.card(padding: 16)
            if !presets.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Looks").font(AppType.title).foregroundStyle(Tok.text)
                    ForEach(presets) { p in LButton(title: p.name, kind: .quiet) { m.apply(p) } }
                }.card(padding: 16)
            }
        }
    }

    // MARK: - Cursor

    private var cursor: some View {
        let m = model
        return VStack(spacing: 16) {
            Text("Pointer").font(AppType.title).foregroundStyle(Tok.text)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Self.cursorPacks, id: \.self) { pack in cursorTile(pack, selected: m.timeline.cursor.pack == pack) }
            }
            VStack(spacing: 0) {
                SliderRow(label: "Size", v: m.bind(\.cursor.size), range: 0.5...2.0, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothing", v: m.bind(\.cursor.smoothingSigma), range: 0...0.12, fmt: { "\(Int($0 * 1000)) ms" })
                Row(label: "Click effect") {
                    LDropdown(sel: m.bind(\.cursor.clickEffect),
                              options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") })
                        .frame(width: 130)
                }
            }.card(padding: 16)
        }
    }

    /// The cursor page: one standard arrow, one pixelated, one different.
    private static let cursorPacks: [CursorPack] = [.system, .pixel, .ring]

    private func cursorTile(_ pack: CursorPack, selected: Bool) -> some View {
        let title = CursorPack.allCases.count > 0 ? pack.rawValue.capitalized : ""
        return Button { model.edit { $0.cursor.pack = pack } } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well)
                    if let image = CursorAtlas.previewImage(pack: pack) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                            .frame(height: 44)
                    }
                    if selected {
                        PixelBitmap(rows: Bitmap.disc, cell: 1, color: Dieother.accentText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(5)
                    }
                }
                .frame(height: 52)
                Text(title).font(AppType.caption).foregroundStyle(Tok.text2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .clickable()
        .focusRing()
        .accessibilityLabel("\(title) cursor")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Tools

    private var tools: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                LButton(title: "Import clip", icon: "film", kind: .secondary) { m.importClips() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                LButton(title: "Add title", icon: "textformat", kind: .secondary) { m.addManualTitle() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                LButton(title: "Add highlight", icon: "highlighter", kind: .secondary) { m.addManualHighlight() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.card(padding: 16)
            VStack(spacing: 0) {
                ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
                SliderRow(label: "Zoom amount", v: Binding(get: { m.timeline.camera.baseScale },
                          set: { v in m.edit(coalesce: true) { $0.camera.baseScale = v } }),
                          range: 1.3...3.0, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothness", v: m.bind(\.camera.leadIn), range: 0.3...1.0,
                          fmt: { "\(Int($0 * 1000)) ms" })
            }.card(padding: 16)
        }
    }

    // MARK: - Audio (main things only)

    private var audio: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                Row(label: "Studio mode") {
                    LDropdown(sel: m.bind(\.audio.studioMode),
                              options: StudioMode.allCases.map { ($0, $0.title, "waveform") })
                        .frame(width: 138)
                }
                SliderRow(label: "Voice level", v: m.bind(\.audio.voiceBoostDb), range: 0...6,
                          fmt: { String(format: "%+.1f dB", $0) })
                SliderRow(label: "Noise reduction", v: Binding(
                    get: { m.timeline.audio.noiseReductionStrength },
                    set: { value in m.edit(coalesce: true) {
                        $0.audio.noiseReductionStrength = value
                        $0.audio.micClean = value > 0
                    } }), range: 0...1, fmt: { "\(Int($0 * 100))%" })
            }.card(padding: 16)
            ToggleRow(label: "Sound effects", on: m.bind(\.audio.soundEffectsEnabled)).card(padding: 16)
        }
    }

    // MARK: - Webcam

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
            }.card(padding: 16)
        }
    }

    private func layoutBinding<V>(_ kind: LayoutKind, _ keyPath: WritableKeyPath<LayoutSettings, V>) -> Binding<V> {
        Binding(get: { model.timeline.layoutSettings[kind][keyPath: keyPath] },
                set: { value in model.edit(coalesce: true) { $0.layoutSettings[kind][keyPath: keyPath] = value } })
    }

    // MARK: - Captions

    private var captions: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                ToggleRow(label: "Captions", on: m.bind(\.captions.enabled))
                Row(label: "Font") {
                    LSegmented(sel: m.bind(\.captions.style.font), items: [(.sans, "Sans"), (.serif, "Serif")])
                        .frame(width: 170)
                }
                SliderRow(label: "Size", v: m.bind(\.captions.style.size), range: 0.03...0.09,
                          fmt: { "\(Int($0 * 100))%" })
            }.card(padding: 16)
            VStack(spacing: 0) {
                HStack(spacing: Space.s2) {
                    Text("Titles").font(AppType.title).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s2)
                    LButton(title: "Add title", icon: "textformat", kind: .secondary) { m.addManualTitle() }
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
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Text("Transcript").font(AppType.title).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s2)
                    LButton(title: "Remove fillers", icon: "text.badge.xmark", kind: .quiet) { m.removeFillerWords() }
                }
                if m.transcriptWords.isEmpty {
                    Text("Transcript appears after speech analysis finishes.").font(AppType.caption).foregroundStyle(Tok.text2)
                } else {
                    Text("\(m.transcriptWords.count) words").font(AppType.caption).foregroundStyle(Tok.text2)
                }
            }.card(padding: 16)
        }
    }

    // MARK: - Timeline (the trimmer)

    private var timelineTab: some View {
        let m = model
        return VStack(spacing: 16) {
            VStack(spacing: 0) {
                Row(label: "Main lane") {
                    VStack(spacing: 8) {
                        LButton(title: "Split at playhead", icon: "scissors", kind: .quiet) { m.splitAtPlayhead() }
                        LButton(title: "Duplicate", icon: "doc.on.doc", kind: .quiet) { m.duplicateSelected() }
                            .disabled(m.selection == nil)
                    }
                }
                Row(label: "Ripple") {
                    VStack(spacing: 8) {
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
                ToggleRow(label: "Snap", on: Binding(get: { m.snapEnabled }, set: { m.snapEnabled = $0 }))
            }.card(padding: 16)
        }
    }

    // MARK: - Privacy

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
            }.card(padding: 16)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Masks").font(AppType.title).foregroundStyle(Tok.text)
                Text(detected == 0 ? "No sensitive text found." : "\(detected) mask\(detected == 1 ? "" : "s") follow content through zooms.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                ForEach(m.timeline.overlays.masks.filter { $0.origin == .manual }) { mask in
                    Row(label: String(format: "%.1fs", mask.start)) {
                        LButton(title: "Remove", icon: "trash", kind: .quiet) {
                            m.edit { $0.overlays.masks.removeAll { $0.id == mask.id } }
                        }
                    }
                }
            }.card(padding: 16)
        }
    }

    // MARK: - Export

    private var export: some View { ExportInspector(model: model) }

    // MARK: Icons

    private static func canvasIcon(_ c: CanvasAspect) -> String {
        switch c { case .r16x9: "rectangle"; case .r16x10: "rectangle"; case .r4x3: "rectangle.righthalf.inset.filled"; case .r5x4: "rectangle"; case .r3x2: "rectangle"; case .r1x1: "square"; case .r4x5: "rectangle.portrait"; case .r9x16: "rectangle.portrait"; case .r21x9: "aspectratio" }
    }
    private static func icon(_ t: Inspector.Tab) -> String {
        switch t {
        case .studio: "photo.stack"
        case .cursor: "cursorarrow"
        case .tools: "slider.horizontal.3"
        case .audio: "waveform"; case .webcam: "person.crop.circle"
        case .captions: "captions.bubble"; case .timeline: "timeline.selection"; case .privacy: "lock"; case .export: "square.and.arrow.up"
        }
    }

    // MARK: Wallpaper choices (Studio tab)

    @State private var wallpaperChoices: [String: [WallpaperChoice]] = [:]
    private nonisolated static let wallpaperExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    private nonisolated static func isJunkToken(_ token: String) -> Bool {
        let t = token.lowercased()
        if ["download", "light", "dark", "web", "4k", "iclarified", "cma", "the", "a", "an"].contains(t) { return true }
        if t.isEmpty { return true }
        if Int(t) != nil { return true }
        if t.range(of: #"^[0-9a-f]{6,}$"#, options: .regularExpression) != nil && t.range(of: #"[a-f]"#, options: .regularExpression) != nil { return true }
        if t.hasPrefix("cma-") || t.hasPrefix("download") { return true }
        return false
    }

    private nonisolated static func titleWord(_ w: String) -> String {
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

    private nonisolated static func humanizedTokens(_ raw: String) -> [String] {
        var parts: [String] = []
        for chunk in raw.split(separator: "_", omittingEmptySubsequences: true) {
            for w in chunk.split(separator: "-", omittingEmptySubsequences: true) {
                let s = String(w)
                if !isJunkToken(s) { parts.append(s) }
            }
        }
        return parts
    }

    /// Humanized tooltip/VoiceOver name: strip folder prefixes, hashes,
    /// extensions, "download-light_web" junk, Title Case, macOS-style.
    nonisolated static func humanizedName(for url: URL) -> String {
        var raw = (url.lastPathComponent as NSString).deletingPathExtension
        if raw.contains(" ") && !raw.contains("_") && !raw.contains("download") {
            return raw
        }
        if raw.contains("_") {
            let comps = raw.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            if comps.count >= 3 {
                let last = comps.last!
                if last.lowercased().hasPrefix("cma-") || last.lowercased().hasPrefix("met-") || last.lowercased() == "cma" {
                    raw = comps.dropLast().joined(separator: "_")
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
            let parent = url.deletingLastPathComponent().lastPathComponent
            tokens = humanizedTokens(parent)
        }
        if tokens.isEmpty { return "Wallpaper" }
        return tokens.map(titleWord).joined(separator: " ")
    }

    private nonisolated static func loadWallpaperChoices() -> [String: [WallpaperChoice]] {
        var out: [String: [WallpaperChoice]] = ["macOS": [], "painting": []]
        var seen = Set<String>()
        func add(_ url: URL, to source: String) {
            let name = humanizedName(for: url)
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out[source, default: []].append(WallpaperChoice(displayName: name, url: url))
        }
        func collect(_ root: URL, into source: String) {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard wallpaperExtensions.contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard Self.isUsableWallpaper(f) else { continue }
                add(f, to: source)
            }
        }
        if let root = AppAssets.directory(bundlePath: "Wallpapers", sourcePaths: ["App/public/assets/wallpapers", "wallpapers"]) {
            collect(root.appendingPathComponent("macos"), into: "macOS")
            collect(root.appendingPathComponent("paintings"), into: "painting")
        }
        let sysDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        if FileManager.default.fileExists(atPath: sysDir.path),
           let en = FileManager.default.enumerator(at: sysDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let f = en.nextObject() as? URL {
                let ext = f.pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "png", "tiff", "webp"].contains(ext) else { continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard Self.isUsableWallpaper(f) else { continue }
                add(f, to: "macOS")
            }
        }

        for key in out.keys {
            out[key]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return out
    }

    private nonisolated static func isUsableWallpaper(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let junk = ["grid", "chroma", "hello", "solid", "gradient", "colorful", "aurora", "bubble", "shade", "radial"]
        if junk.contains(where: { name.contains($0) }) { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat else { return true }
        return width >= 2560
    }

    struct WallpaperChoice: Identifiable {
        var id: String { url.path }
        var displayName: String
        var url: URL
    }

    private var wallpaperList: some View {
        let choices = wallpaperChoices["painting"] ?? []
        let macChoices = wallpaperChoices["macOS"] ?? []
        return VStack(spacing: 12) {
            LSegmented(sel: Binding(get: { wallpaperSource }, set: { source in selectWallpaperSource(source) }),
                       items: WallpaperSource.allCases.map { ($0, $0.rawValue) })
                .frame(maxWidth: .infinity)
            WallpaperGrid(choices: wallpaperSource == .painting ? choices : macChoices) { choice in
                model.edit { timeline in timeline.style.setPhotoBackground(choice.url.path) }
            }
            SliderRow(label: "Blur", v: model.bind(\.style.wallpaperBlur), range: 0...60, fmt: { "\(Int($0))" })
            SliderRow(label: "Opacity", v: model.bind(\.style.imageOpacity), range: 0...1, fmt: { "\(Int($0 * 100))%" })
            SliderRow(label: "Contrast", v: model.bind(\.style.imageContrast), range: 0...2, fmt: { "\(Int($0 * 100))%" })
            SliderRow(label: "Brightness", v: model.bind(\.style.imageBrightness), range: 0...2, fmt: { "\(Int($0 * 100))%" })
        }
        .padding(.top, 8)
    }

    @State private var wallpaperSource: WallpaperSource = .painting

    enum WallpaperSource: String, CaseIterable, Identifiable {
        case painting = "Painting"
        case macOS = "macOS"
        var id: String { rawValue }
    }

    private func selectWallpaperSource(_ source: WallpaperSource) {
        wallpaperSource = source
        let choices = wallpaperChoices[source == .painting ? "painting" : "macOS"] ?? []
        let currentPath = model.timeline.style.backgroundImagePath
        let choice = choices.first { $0.url.path == currentPath } ?? choices.first
        if model.timeline.style.background == .image, choice?.url.path == currentPath { return }
        model.edit { style in
            if let choice { style.style.setPhotoBackground(choice.url.path) }
            else { style.style.background = .image }
        }
    }

    private struct WallpaperGrid: View {
        let choices: [WallpaperChoice]
        let onSelect: (WallpaperChoice) -> Void
        private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

        var body: some View {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(choices) { choice in
                    WallpaperCell(url: choice.url, onSelect: { onSelect(choice) })
                }
            }
            .frame(height: choices.isEmpty ? 44 : nil)
        }
    }

    private struct WallpaperCell: View {
        let url: URL
        let onSelect: () -> Void
        @State private var image: NSImage?

        var body: some View {
            Button(action: onSelect) {
                ZStack {
                    if let image { Image(nsImage: image).resizable().aspectRatio(16 / 10, contentMode: .fill).clipped() }
                    else { Color.clear.aspectRatio(16 / 10, contentMode: .fill) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.field))
            }
            .buttonStyle(.plain)
            .help(url.lastPathComponent)
            .accessibilityLabel(url.lastPathComponent)
            .task { image = NSImage(contentsOf: url) }
        }
    }
}
