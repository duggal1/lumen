import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenExport
import LumenAudio

struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case look = "Look", cursor = "Cursor", camera = "Camera", layout = "Layout", webcam = "Webcam", captions = "Captions", privacy = "Privacy", audio = "Audio", export = "Export" }
    @State private var tab = Tab.look
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
                case .layout: layout
                case .audio: audio
                case .webcam: webcam
                case .captions: captions
                case .privacy: privacy
                case .export: export
                }
            }.padding(20)
        }.frame(width: Metrics.inspector).frame(maxHeight: .infinity).background(Tok.bg)
        .onChange(of: model.exportPanelRequest) { _, _ in tab = .export }
        .onChange(of: tab) { _, selected in model.exportPanelActive = selected == .export }
    }

    private func icon(_ t: Tab) -> String {
        switch t {
        case .look: "paintpalette"; case .cursor: "cursorarrow"; case .camera: "video"
        case .layout: "rectangle.3.group"; case .audio: "waveform"; case .webcam: "person.crop.circle"
        case .captions: "captions.bubble"; case .privacy: "lock"; case .export: "square.and.arrow.up"
        }
    }

    private var look: some View {
        let m = model
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                if m.session.webcam != nil {
                    ToggleRow(label: "Show face cam", on: Binding(get: { m.timeline.webcam != nil }, set: { m.setWebcam($0) }))
                }
                Row(label: "Canvas") { LDropdown(sel: m.bind(\.style.canvas), options: CanvasAspect.allCases.map { ($0, $0.title, "rectangle.dashed") }).frame(width: 130) }
                SliderRow(label: "Video size", v: m.bind(\.style.contentScale), range: 0.5...2.0, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
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
                ToggleRow(label: "Constant size", on: m.bind(\.cursor.constantSize))
                ToggleRow(label: "Loop position", on: Binding(get: { m.timeline.cursor.loop != nil }, set: { v in m.edit { $0.cursor.loop = v ? 1.2 : nil } }))
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
                Row(label: "Preset") { LDropdown(sel: Binding(get: { m.timeline.camera.preset }, set: { v in m.edit { $0.camera.apply(preset: v) } }), options: ZoomPreset.allCases.map { ($0, $0.rawValue.capitalized, "plus.magnifyingglass") }).frame(width: 130) }
                Row(label: "Tilt") { LDropdown(sel: m.bind(\.camera.tilt), options: TiltMode.allCases.map { ($0, $0.rawValue.capitalized, "move.3d") }).frame(width: 130) }
                SliderRow(label: "Max zoom", v: m.bind(\.camera.maxScale), range: 1.2...4, fmt: { String(format: "%.1f×", $0) })
                SliderRow(label: "Smoothness", v: smooth, range: 0...1)
            }.card()
            VStack(spacing: 0) {
                SliderRow(label: "Dead zone", v: m.bind(\.camera.deadZone), range: 0.1...0.45)
                SliderRow(label: "Motion blur", v: m.bind(\.camera.shutter), range: 0...1)
                ToggleRow(label: "Focus debug", on: Binding(get: { m.zoomDebug }, set: { m.zoomDebug = $0 }))
            }.card()
        }
    }

    private var layout: some View {
        let kind = currentLayout
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                Row(label: "Layout") {
                    LDropdown(sel: layoutKind, options: LayoutKind.allCases.map {
                        ($0, $0 == .screenOnly ? "Screen only" : $0 == .cameraOverlay ? "Camera overlay"
                            : $0 == .cameraFullscreen ? "Camera fullscreen" : $0 == .cameraCutout ? "Cutout" : "Split", "rectangle.3.group")
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
            }.card()
            VStack(spacing: 0) {
                ToggleRow(label: "Mirror", on: layoutBinding(kind, \.mirror))
                ToggleRow(label: "Border", on: layoutBinding(kind, \.border))
                ToggleRow(label: "Auto framing", on: layoutBinding(kind, \.autoFrame))
            }.card()
            VStack(spacing: 0) {
                ToggleRow(label: "Avoid cursor", on: layoutBinding(kind, \.avoidCursor))
                Row(label: "Behind face") {
                    LSegmented(sel: layoutBinding(kind, \.behindFace), items: [(.move, "Move"), (.hide, "Hide"), (.fade, "Fade")]).frame(width: 170)
                }
                ToggleRow(label: "Hide on silence", on: layoutBinding(kind, \.hideOnSilence))
            }.card()
        }
    }

    private var captions: some View {
        let m = model
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                ToggleRow(label: "Captions", on: m.bind(\.captions.enabled))
                Row(label: "Position") {
                    LDropdown(sel: m.bind(\.captions.style.position), options: CaptionPosition.allCases.map {
                        ($0, $0.rawValue.capitalized, "text.alignleft")
                    }).frame(width: 130)
                }
                Row(label: "Animation") {
                    LDropdown(sel: m.bind(\.captions.style.animation), options: CaptionAnimation.allCases.map {
                        ($0, $0.rawValue.capitalized, "sparkles")
                    }).frame(width: 130)
                }
            }.card()
            VStack(spacing: 0) {
                SliderRow(label: "Size", v: m.bind(\.captions.style.size), range: 0.02...0.08, fmt: { "\(Int($0 * 100))%" })
                SliderRow(label: "Lines", v: maxLines, range: 1...3, fmt: { "\(Int($0))" })
                ToggleRow(label: "Word highlight", on: m.bind(\.captions.style.wordHighlight))
            }.card()
            VStack(spacing: 0) {
                Row(label: "Language") {
                    TextField("en-US", text: locale).textFieldStyle(.plain).font(AppType.body)
                        .padding(.horizontal, 12).frame(width: 130, height: 32)
                        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
                        .accessibilityLabel("Caption language")
                }
            }.card()
        }
    }

    private var privacy: some View {
        let m = model
        let detected = m.timeline.derived?.autoMasks.count ?? 0
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                ToggleRow(label: "Detect sensitive data", on: m.bind(\.overlays.privacy.autoDetect))
                Row(label: "Mask style") {
                    LDropdown(sel: m.bind(\.overlays.privacy.mode), options: MaskMode.allCases.map {
                        ($0, $0.rawValue.capitalized, "eye.slash")
                    }).frame(width: 130)
                }
                SliderRow(label: "Padding", v: m.bind(\.overlays.privacy.padding), range: 0...24, fmt: { "\(Int($0)) px" })
                SliderRow(label: "Sensitivity", v: m.bind(\.overlays.privacy.entropyThreshold), range: 3...4.5, fmt: { String(format: "%.1f", $0) })
            }.card()
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Masks").font(AppType.title).foregroundStyle(Tok.text)
                Text(detected == 0 ? "No sensitive text found." : "\(detected) mask\(detected == 1 ? "" : "s") follow the content through zooms.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
                Text("Manual masks and highlights are added from the timeline.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            }.card()
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
        return VStack(spacing: 24) {
            VStack(spacing: 0) {
                ToggleRow(label: "Clean mic", on: m.bind(\.audio.micClean))
                Row(label: "Voice profile") {
                    LSegmented(sel: m.bind(\.audio.voiceProfile),
                               items: [(.natural, "Natural"), (.studio, "Studio")]).frame(width: 156)
                }
                if m.timeline.audio.voiceProfile == .studio {
                    SliderRow(label: "Polish", v: m.bind(\.audio.studioAmount), range: 0...1,
                              fmt: { "\(Int($0 * 100))%" })
                }
                ToggleRow(label: "Click sounds", on: m.bind(\.audio.clickSounds))
                if m.timeline.audio.clickSounds {
                    Row(label: "Click tone") {
                        LDropdown(sel: m.bind(\.audio.clickTone),
                                  options: [(ClickSound.mouse, "Mouse", "cursorarrow.click"),
                                            (.subtle, "Subtle", "cursorarrow.click")]).frame(width: 130)
                    }
                }
                ToggleRow(label: "Zoom whooshes", on: m.bind(\.audio.whooshes))
                ToggleRow(label: "Key sounds", on: m.bind(\.audio.keySounds))
                ToggleRow(label: "Speed up idle spans", on: m.bind(\.audio.speedRampsAuto))
            }.card()
            VStack(spacing: 0) {
                MusicPicker(model: m)
                if m.timeline.audio.musicPath != nil {
                    SliderRow(label: "Music level", v: m.bind(\.audio.musicGainDb), range: -30...(-6), fmt: { "\(Int($0)) dB" })
                    Row(label: "Remove music") { LButton(title: "Remove", icon: "trash", kind: .quiet) { m.edit { $0.audio.musicPath = nil } } }
                }
                SliderRow(label: "Loudness", v: m.bind(\.audio.targetLUFS), range: -23...(-10), fmt: { "\(Int($0)) LUFS" })
                SliderRow(label: "Output level", v: m.bind(\.audio.outputGainDb), range: -24...6, fmt: { "\(Int($0)) dB" })
            }.card()
        }
    }

    private var webcam: some View {
        let m = model
        return VStack(spacing: 0) {
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
        }.card()
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
        }.card()
    }

    private var export: some View { ExportInspector(model: model) }
}
