import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenRender

/// Pure state mapping for the tilt control. Kept out of any view so the toggle
/// and the style segmented read the same single setting.
enum Cinematic3D {
    static let enabledMode: TiltMode = .lean
    static func isEnabled(_ mode: TiltMode) -> Bool { mode != .off }
    static func mode(_ current: TiltMode, enabling: Bool) -> TiltMode {
        enabling ? (current == .off ? enabledMode : current) : .off
    }
    static let styles: [(TiltMode, String)] = [(.lean, "Lean"), (.reveal, "Reveal")]
    static func label(_ mode: TiltMode) -> String {
        switch mode {
        case .off: "3D motion, off"
        case .lean: "3D motion, lean"
        case .reveal: "3D motion, reveal"
        }
    }
    static func hint(_ mode: TiltMode) -> String {
        switch mode {
        case .off: "Flat 2D framing."
        case .lean: "The frame banks with cursor motion."
        case .reveal: "Each zoom enters at an angle, then settles."
        }
    }
}

/// The Studio's right rail, rebuilt from scratch.
///
/// One idea per page, one primary action, and real air around it. The only
/// decoration is the Diether dither instrument: square cells on a 4 pt lattice,
/// Clove hues, a hot front and a dark grid where there is no data. No stacked
/// cards, no badge grammar, no settings furniture.
struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable {
        case look = "Look", cursor = "Cursor", sound = "Sound", text = "Text"
        case trim = "Trim", privacy = "Privacy", export = "Export"
    }

    @Binding var tab: Tab
    var width: CGFloat = 320

    /// Old saved tab names resolve to the quiet page that replaced them.
    static func normalizeTab(_ saved: String) -> String {
        switch saved {
        case "Focus", "Cursor", "Camera", "Layout": "Cursor"
        case "Tools", "Background", "Studio", "Timeline": "Look"
        case "Captions", "Transcript": "Text"
        case "Audio": "Sound"
        default: saved
        }
    }

    /// Framing survives the rebuild; it lives on the Trim page now.
    enum FramingLayoutStyle: Sendable {
        static let all: [(LayoutKind, String)] = [
            (.screenOnly, "Screen only"), (.cameraOverlay, "Camera overlay"),
            (.split, "Split"), (.cameraFullscreen, "Camera fullscreen"),
            (.cameraCutout, "Cutout"),
        ]
    }

    static func currentLayout(in timeline: Timeline, at playhead: Double) -> LayoutKind {
        let source = timeline.timeMap.source(atOutput: playhead)
        return timeline.layouts.first { source >= $0.start && source < $0.end }?.kind
            ?? (timeline.webcam != nil ? .cameraOverlay : .screenOnly)
    }

    static func visibleFor(model: EditorModel) -> [Inspector.Tab] { Tab.allCases }

    private static let glyphs: [Tab: String] = [
        .look: "photo.stack", .cursor: "cursorarrow", .sound: "waveform",
        .text: "textformat", .trim: "scissors", .privacy: "lock", .export: "square.and.arrow.up",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader
            sectionGrid
            ScrollView {
                page
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Diether.bg)
        .onAppear {
            guard let saved = UserDefaults.standard.string(forKey: "lumen.inspector.tab"),
                  let restored = Tab(rawValue: Self.normalizeTab(saved)) else { return }
            tab = restored
        }
        .onChange(of: tab) { _, selected in
            model.exportPanelActive = selected == .export
            UserDefaults.standard.set(selected.rawValue, forKey: "lumen.inspector.tab")
        }
        .onChange(of: model.exportPanelRequest) { _, _ in tab = .export }
    }

    // MARK: Header + navigation

    private var railHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Studio").font(Diether.display(22)).foregroundStyle(Diether.ink)
            Text("Shape the recording.").font(Diether.prose(12)).foregroundStyle(Diether.ink2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var sectionGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) {
                        Image(systemName: Self.glyphs[item] ?? "circle")
                            .font(.system(size: 15, weight: .medium))
                        Text(item.rawValue)
                            .font(Diether.prose(11))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(tab == item ? Diether.ink : Diether.ink2)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(tab == item ? Diether.liftStrong : Diether.lift))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityLabel("\(item.rawValue) section")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .look: lookPage
        case .cursor: cursorPage
        case .sound: soundPage
        case .text: textPage
        case .trim: trimPage
        case .privacy: privacyPage
        case .export: exportPage
        }
    }
}

// MARK: - Diether theme tokens

enum Diether {
    static let bg = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.106, alpha: 1) : NSColor(calibratedWhite: 0.985, alpha: 1)
    })
    static let panel = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.145, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)
    })
    static let ink = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.14, alpha: 1)
    })
    static let ink2 = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.68, alpha: 1) : NSColor(calibratedWhite: 0.45, alpha: 1)
    })
    static let lift = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(blackAlpha: 0.035)
    })
    static let liftStrong = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12) : NSColor(blackAlpha: 0.09)
    })
    static let orange = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 1, green: 0.53, blue: 0.09, alpha: 1)
            : NSColor(calibratedRed: 0.91, green: 0.41, blue: 0, alpha: 1)
    })

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func prose(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size).monospacedDigit() }
}

private extension NSColor {
    convenience init(blackAlpha: CGFloat) {
        self.init(calibratedRed: 0, green: 0, blue: 0, alpha: blackAlpha)
    }
}

// MARK: - Page furniture

extension Inspector {
    func pageHeader(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Diether.display(19)).foregroundStyle(Diether.ink)
            Text(note).font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Diether.panel))
    }

    func row<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(Diether.prose(13)).foregroundStyle(Diether.ink2)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 28)
    }
}

// MARK: - Look + Cursor

extension Inspector {
    var lookPage: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Look", "Sound and surface for this recording.")
            panel {
                MusicPicker(model: m)
            }
            panel {
                Text("Background").font(Diether.prose(13, .medium)).foregroundStyle(Diether.ink)
                HStack(spacing: 6) {
                    ForEach([(BackgroundKind.canvas, "Canvas"), (.dither, "Dither"), (.image, "Image")], id: \.0) { kind, name in
                        Button { m.edit { $0.style.background = kind } } label: {
                            Text(name).font(Diether.prose(12))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .foregroundStyle(m.timeline.style.background == kind ? Diether.ink : Diether.ink2)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(m.timeline.style.background == kind ? Diether.liftStrong : Diether.lift))
                        }
                        .buttonStyle(.plain).clickable()
                    }
                }
                if m.timeline.style.background == .image {
                    LButton(title: m.timeline.style.backgroundImagePath.map {
                        (URL(fileURLWithPath: $0).lastPathComponent as NSString).deletingPathExtension
                    } ?? "Choose image…", icon: "photo", kind: .secondary) { chooseWallpaper() }
                }
                if m.timeline.style.background == .canvas { CanvasPresetGrid(model: m) }
                if m.timeline.style.background == .dither { DitherPaletteGrid(model: m, kind: .dither) }
            }
            panel {
                Text("Frame").font(Diether.prose(13, .medium)).foregroundStyle(Diether.ink)
                SliderRow(label: "Radius", v: m.bind(\.style.cornerRadius), range: 0...40, fmt: { "\(Int($0))" })
                SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
            }
        }
    }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.edit { $0.style.setPhotoBackground(url.path) }
        }
    }

    var cursorPage: some View {
        let m = model
        let packs: [CursorPack] = [.system, .minimal, .dot, .ring, .outline, .pixel, .holiday] + TinyHandSkins.catalog.map(\.pack)
        let previews: [CursorPack: NSImage] = Dictionary(uniqueKeysWithValues: packs.compactMap { pack in
            let image = TinyHandSkins.isCoat(pack) ? TinyHandSkins.image(for: pack) : CursorAtlas.previewImage(pack: pack)
            return image.map { (pack, $0) }
        })
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Cursor", "The pointer people see in the export.")
            panel {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(packs, id: \.self) { pack in
                        let selected = m.timeline.cursor.pack == pack
                        Button { m.edit { $0.cursor.pack = pack } } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9).fill(selected ? Diether.liftStrong : Diether.lift)
                                    if let image = previews[pack] {
                                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                            .padding(7).frame(height: 42)
                                    }
                                    if selected {
                                        PixelBitmap(rows: Bitmap.check, cell: 1, color: Diether.orange)
                                            .frame(width: 9, height: 7)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                            .padding(5)
                                    }
                                }
                                .frame(height: 52)
                                Text(TinyHandSkins.isCoat(pack) ? TinyHandSkins.title(for: pack) : pack.rawValue.capitalized)
                                    .font(Diether.prose(10)).foregroundStyle(selected ? Diether.ink : Diether.ink2)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain).clickable()
                        .accessibilityLabel("\(pack.rawValue) cursor skin")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            panel {
                SliderRow(label: "Size", v: m.bind(\.cursor.size), range: 0.5...2.0,
                          fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothing", v: m.bind(\.cursor.smoothingSigma), range: 0...0.12,
                          fmt: { "\(Int($0 * 1000)) ms" })
                row("Click") {
                    LDropdown(sel: m.bind(\.cursor.clickEffect),
                              options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") })
                        .frame(width: 116)
                }
            }
        }
    }
}
