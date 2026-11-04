import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenExport

struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case look = "Look", cursor = "Cursor", camera = "Camera", audio = "Audio", webcam = "Webcam", export = "Export" }
    @State private var tab = Tab.look
    @State private var valid: [ExportPreset] = []
    @State private var presetName = "1080p60-h264"
    @State private var presets = EditorModel.loadPresets()
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LDropdown(sel: $tab, options: Tab.allCases.filter { $0 != .webcam || model.timeline.webcam != nil }.map { ($0, $0.rawValue, icon($0)) })
                switch tab {
                case .look: look
                case .cursor: cursor
                case .camera: camera
                case .audio: audio
                case .webcam: webcam
                case .export: export
                }
            }.padding(20)
        }.frame(width: Metrics.inspector).background(Tok.bg)
        .task { valid = await Task.detached { ExportCapabilityMatrix.shared.valid(ExportPresets.all) }.value }
    }

    private func icon(_ t: Tab) -> String {
        switch t { case .look: "paintpalette"; case .cursor: "cursorarrow"; case .camera: "video"; case .audio: "waveform"; case .webcam: "person.crop.circle"; case .export: "square.and.arrow.up" }
    }

    private var look: some View {
        let m = model
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                if m.session.webcam != nil {
                    ToggleRow(label: "Show face cam", on: Binding(get: { m.timeline.webcam != nil }, set: { m.setWebcam($0) }))
                }
                Row(label: "Canvas") { EmptyView() }
                LSegmented(sel: m.bind(\.style.canvas), items: CanvasAspect.allCases.map { ($0, $0.title) })
            }.card()
            VStack(spacing: 0) {
                Row(label: "Background") {
                    LDropdown(sel: m.bind(\.style.background),
                              options: (BackgroundKind.offered + (m.timeline.style.background == .dither ? [.dither] : []))
                                .map { ($0, $0 == .dither ? "Legacy" : $0.rawValue.capitalized, backgroundIcon($0)) })
                        .frame(width: 130)
                }
                if m.timeline.style.background != .wallpaper {
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
                if m.timeline.style.background == .wallpaper {
                    Row(label: "Source") {
                        Text("This Mac").font(AppType.body).foregroundStyle(Tok.text2)
                    }
                }
            }.card()
            VStack(spacing: 0) {
                SliderRow(label: "Video size", v: m.bind(\.style.contentScale), range: 0.5...2.0, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Radius", v: m.bind(\.style.cornerRadius), range: 0...40, fmt: { "\(Int($0))" })
                SliderRow(label: "Shadow", v: m.bind(\.style.shadow), range: 0...1)
                ToggleRow(label: "Inner border", on: m.bind(\.style.innerBorder))
            }.card()
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Looks").font(AppType.title); Spacer() }
                ForEach(presets) { p in LButton(title: p.name, kind: .quiet) { m.apply(p) } }
                HStack(spacing: 8) {
                    TextField("Name", text: $newName).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Tok.well))
                    LButton(title: "Save", kind: .secondary, height: 32) { if !newName.isEmpty { m.savePreset(newName); presets = EditorModel.loadPresets(); newName = "" } }
                }
            }.card()
        }
    }

    private func backgroundIcon(_ kind: BackgroundKind) -> String {
        switch kind {
        case .dither: "square.grid.3x3.fill"
        case .wave: "waveform.path"
        case .field: "square.grid.3x3"
        case .canvas: "rectangle.fill"
        case .wallpaper: "photo"
        case .solid: "square.fill"
        case .gradient, .mesh: "square.fill.on.square"
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

    private var cursor: some View {
        let m = model
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                Row(label: "Pack") { LDropdown(sel: m.bind(\.cursor.pack), options: CursorPack.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") }).frame(width: 130) }
                SliderRow(label: "Size", v: m.bind(\.cursor.size), range: 0.5...2.5)
                SliderRow(label: "Smoothing", v: m.bind(\.cursor.smoothingSigma), range: 0...0.12, fmt: { "\(Int($0 * 1000)) ms" })
                SliderRow(label: "Glide", v: m.bind(\.cursor.glide), range: 0...1)
            }.card()
            VStack(spacing: 0) {
                ToggleRow(label: "Hide when idle", on: Binding(get: { m.timeline.cursor.idleHide != nil }, set: { v in m.edit { $0.cursor.idleHide = v ? 2.0 : nil } }))
                ToggleRow(label: "Click ring", on: Binding(get: { m.timeline.cursor.clickRing != nil }, set: { v in m.edit { $0.cursor.clickRing = v ? 0.45 : nil } }))
                SliderRow(label: "Press scale", v: m.bind(\.cursor.pressScale), range: 0.7...1)
                SliderRow(label: "Zoom comp.", v: m.bind(\.cursor.zoomCompensation), range: 0...1)
            }.card()
        }
    }

    private var camera: some View {
        let m = model
        // "Smoothness" 0...1 maps onto the spring omegas (lower omega = floatier)
        let smooth = Binding<Double>(get: { (14 - m.timeline.camera.omegaPan) / 11 },
                                     set: { s in m.edit(coalesce: true) { $0.camera.omegaPan = 14 - 11 * s; $0.camera.omegaZoom = 12 - 9 * s } })
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
                Row(label: "Preset") { LDropdown(sel: m.bind(\.camera.preset), options: ZoomPreset.allCases.map { ($0, $0.rawValue.capitalized, "plus.magnifyingglass") }).frame(width: 130) }
                SliderRow(label: "Max zoom", v: m.bind(\.camera.maxScale), range: 1.2...4, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothness", v: smooth, range: 0...1)
            }.card()
            VStack(spacing: 0) {
                SliderRow(label: "Lookahead", v: m.bind(\.camera.lookahead), range: 0...0.6, fmt: { "\(Int($0 * 1000)) ms" })
                SliderRow(label: "Dead zone", v: m.bind(\.camera.deadZone), range: 0.1...0.45)
                SliderRow(label: "Motion blur", v: m.bind(\.camera.shutter), range: 0...1)
            }.card()
        }
    }

    private var audio: some View {
        let m = model
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                ToggleRow(label: "Clean mic", on: m.bind(\.audio.micClean))
                ToggleRow(label: "Click sounds", on: m.bind(\.audio.clickSounds))
                ToggleRow(label: "Zoom whooshes", on: m.bind(\.audio.whooshes))
                ToggleRow(label: "Key sounds", on: m.bind(\.audio.keySounds))
                ToggleRow(label: "Speed up idle spans", on: m.bind(\.audio.speedRampsAuto))
            }.card()
            VStack(spacing: 0) {
                Row(label: "Music") { LButton(title: m.timeline.audio.musicPath == nil ? "Import…" : "Replace…", icon: "music.note") { m.importMusic() } }
                if m.timeline.audio.musicPath != nil {
                    SliderRow(label: "Music level", v: m.bind(\.audio.musicGainDb), range: -30...(-6), fmt: { "\(Int($0)) dB" })
                    Row(label: "Remove music") { LButton(title: "Remove", icon: "trash", kind: .quiet) { m.edit { $0.audio.musicPath = nil } } }
                }
                SliderRow(label: "Loudness", v: m.bind(\.audio.targetLUFS), range: -23...(-10), fmt: { "\(Int($0)) LUFS" })
            }.card()
        }
    }

    private var webcam: some View {
        let m = model
        return VStack(spacing: 0) {
            Row(label: "Corner") { LDropdown(sel: Binding(get: { m.timeline.webcam?.corner ?? .bottomRight }, set: { v in m.edit { $0.webcam?.corner = v } }),
                options: WebcamLayout.Corner.allCases.map { ($0, $0.rawValue, "rectangle.inset.filled") }).frame(width: 130) }
            SliderRow(label: "Size", v: Binding(get: { m.timeline.webcam?.size ?? 0.22 }, set: { v in m.edit(coalesce: true) { $0.webcam?.size = v } }), range: 0.1...0.4)
            Row(label: "Shape") { LSegmented(sel: Binding(get: { m.timeline.webcam?.shape ?? .circle }, set: { v in m.edit { $0.webcam?.shape = v } }),
                                             items: [(.circle, "Circle"), (.roundRect, "Square")]).frame(width: 130) }
            ToggleRow(label: "Mirror", on: Binding(get: { m.timeline.webcam?.mirror ?? true }, set: { v in m.edit { $0.webcam?.mirror = v } }))
            ToggleRow(label: "Border", on: Binding(get: { m.timeline.webcam?.border ?? true }, set: { v in m.edit { $0.webcam?.border = v } }))
            ToggleRow(label: "Auto framing", on: Binding(get: { m.timeline.webcam?.autoFrame ?? true }, set: { v in m.edit { $0.webcam?.autoFrame = v } }))
            SliderRow(label: "Face zoom", v: Binding(get: { m.timeline.webcam?.faceZoom ?? 0.6 }, set: { v in m.edit(coalesce: true) { $0.webcam?.faceZoom = v } }), range: 0...1)
            SliderRow(label: "Face size", v: Binding(get: { m.timeline.webcam?.faceFill ?? 0.31 }, set: { v in m.edit(coalesce: true) { $0.webcam?.faceFill = v } }), range: 0.2...0.5)
        }.card()
    }

    private var export: some View {
        let m = model
        let opts = (valid.isEmpty ? [ExportPresets.parse("1080p60-h264")!] : valid).map { ($0.name, $0.name, "film") }
        return VStack(alignment: .leading, spacing: 16) {
            Row(label: "Preset") { LDropdown(sel: $presetName, options: opts).frame(width: 170) }
            switch m.exportState {
            case .idle, .done:
                LButton(title: "Export video", icon: "square.and.arrow.up", kind: .primary, height: 32) {
                    if let p = ExportPresets.parse(presetName) { m.export(p) }
                }
                LButton(title: "Export GIF", icon: "photo.on.rectangle", height: 32) { m.export(ExportPresets.all[0], gif: true) }
                if case .done(let u) = m.exportState { Text("Saved \(u.lastPathComponent)").font(AppType.caption).foregroundStyle(Tok.text2) }
            case .running(let p):
                Text("\(Int(p * 100))%").font(AppType.metric).foregroundStyle(Tok.text)
                LButton(title: "Cancel", kind: .quiet) { m.cancelExport() }
            case .failed(let why):
                Text(why).font(AppType.caption).foregroundStyle(Tok.statusBad)
                LButton(title: "Retry", kind: .secondary) { if let p = ExportPresets.parse(presetName) { m.export(p) } }
            }
            if let n = m.notice { Text(n).font(AppType.caption).foregroundStyle(Tok.text2) }
        }.card()
    }
}
