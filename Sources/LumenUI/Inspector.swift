import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenExport
import LumenAudio

struct Inspector: View {
    let model: EditorModel
    enum Tab: String, CaseIterable { case look = "Look", tools = "Tools", cursor = "Cursor", camera = "Camera", layout = "Layout", webcam = "Webcam", captions = "Captions", timeline = "Timeline", privacy = "Privacy", audio = "Audio", export = "Export", transcript = "Transcript" }
    @Binding var tab: Tab
    var width: CGFloat = Metrics.inspector
    @State private var presets = EditorModel.loadPresets()
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LDropdown(sel: $tab, options: Tab.allCases.filter { $0 != .webcam || model.timeline.webcam != nil }.map { ($0, $0.rawValue, icon($0)) })
                tabBody
            }.padding(20)
        }.frame(width: width).frame(maxHeight: .infinity).background(Tok.bg)
        .onChange(of: model.exportPanelRequest) { _, _ in tab = .export }
        .onChange(of: tab) { _, selected in model.exportPanelActive = selected == .export }
    }

    @ViewBuilder private var tabBody: some View {
        if tab == .transcript {
            transcriptTab
        } else {
            switch tab {
            case .look: look
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
            default: EmptyView()
            }
        }
    }

    private var transcriptTab: some View { TranscriptTab(model: model) }

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
        .card()
    }

    private func icon(_ t: Tab) -> String {
        switch t {
        case .look: "paintpalette"; case .tools: "slider.horizontal.3"; case .cursor: "cursorarrow"; case .camera: "video"
        case .layout: "rectangle.3.group"; case .audio: "waveform"; case .webcam: "person.crop.circle"
        case .captions: "captions.bubble"; case .timeline: "timeline.selection"; case .privacy: "lock"; case .export: "square.and.arrow.up"; case .transcript: "text.alignleft"
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
    private var timelineTab: some View {
        let m = model
        return VStack(spacing: 24) {
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
            }.card()
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
                            LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.deleteClip(clip.id)) }
                        }
                    }
                }
            }.card()
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
                        LButton(title: "Remove", icon: "trash", kind: .quiet) { m.dispatch(.deleteTap(tap.id)) }
                    }
                }
            }.card()
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
                ToggleRow(label: "Independent padding",
                          on: Binding(get: { m.timeline.style.paddingInsets != nil },
                                      set: { enabled in
                                          m.edit { $0.style.paddingInsets = enabled
                                              ? EdgeInsetsN(all: $0.style.padding) : nil }
                                      }))
                if m.timeline.style.paddingInsets == nil {
                    SliderRow(label: "Padding", v: m.bind(\.style.padding), range: 0...0.2, fmt: { "\(Int($0 * 100))%" })
                } else {
                    SliderRow(label: "Top", v: paddingEdge(\.top), range: 0...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Right", v: paddingEdge(\.right), range: 0...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Bottom", v: paddingEdge(\.bottom), range: 0...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                    SliderRow(label: "Left", v: paddingEdge(\.left), range: 0...0.2,
                              fmt: { "\(Int($0 * 100))%" })
                }
            }.card()
            VStack(spacing: 0) {
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
                if m.timeline.style.background == .wallpaper {
                    Row(label: "Source") {
                        Text("This Mac").font(AppType.body).foregroundStyle(Tok.text2)
                    }
                }
                if m.timeline.style.background == .image {
                    PhotoBackgroundRow(model: m)
                }
                ToggleRow(label: "Blur behind zoom", on: m.bind(\.style.zoomBackgroundBlur))
                if m.timeline.style.zoomBackgroundBlur {
                    Text("Softens only the background. Screen text and cursor stay sharp.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.card()
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
                Row(label: "Click effect") {
                    LDropdown(sel: m.bind(\.cursor.clickEffect),
                              options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow.click") })
                        .frame(width: 130)
                }
                SliderRow(label: "Click duration", v: m.bind(\.cursor.clickDuration), range: 0.1...1)
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
                Row(label: "Max upscale") { LDropdown(sel: m.bind(\.camera.upscaleMaxFactor), options: [2, 3, 4, 5, 6, 8, 10].map { ($0, "\($0)×", "arrow.up.right.and.arrow.down.right") }).frame(width: 130) }
                SliderRow(label: "Min zoom", v: m.bind(\.camera.minScale), range: 1.05...2.5, fmt: { String(format: "%.2f×", $0) })
                SliderRow(label: "Smoothness", v: smooth, range: 0...1)
            }.card()
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
            }.card()
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
            }.card()
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
            }.card()
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
            }.card()
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
            }.card()
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Automatic detection").font(AppType.title).foregroundStyle(Tok.text)
                Text(detected == 0 ? "No sensitive text found." : "\(detected) detected mask\(detected == 1 ? "" : "s") follow content through zooms.")
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
                Row(label: "Microphone") {
                    LDropdown(sel: m.bind(\.audio.micMode),
                              options: MicMode.allCases.map { ($0, $0.rawValue.capitalized, "mic") })
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
                                  options: [(ClickSound.mouse, "Mouse", "cursorarrow.click"),
                                            (.subtle, "Subtle", "cursorarrow.click")]).frame(width: 130)
                    }
                    SliderRow(label: "Click level", v: m.bind(\.audio.sfxGainDb), range: -24...6,
                              fmt: { String(format: "%+.0f dB", $0) })
                    Row(label: "Preview") {
                        LButton(title: "Play click", icon: "speaker.wave.2", kind: .quiet) { m.previewClick() }
                    }
                }
                ToggleRow(label: "Zoom whooshes", on: m.bind(\.audio.whooshes))
                ToggleRow(label: "Key sounds", on: m.bind(\.audio.keySounds))
                ToggleRow(label: "Speed up idle spans", on: m.bind(\.audio.speedRampsAuto))
            }.card()
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
                if m.timeline.audio.normalize {
                    SliderRow(label: "Loudness", v: m.bind(\.audio.targetLUFS), range: -23...(-10),
                              fmt: { String(format: "%.0f LUFS", $0) })
                    SliderRow(label: "Trim", v: m.bind(\.audio.outputGainDb), range: -12...6,
                              fmt: { String(format: "%+.0f dB", $0) })
                } else {
                    SliderRow(label: "Output level", v: m.bind(\.audio.outputGainDb), range: -24...6,
                              fmt: { String(format: "%+.0f dB", $0) })
                }
                if let stats = m.mixStats {
                    Row(label: "Master") {
                        Text(String(format: "%.1f LUFS · peak %.1f dBTP", stats.lufs, stats.peak))
                            .font(AppType.caption.monospacedDigit())
                            .foregroundStyle(stats.peak > -1 ? Tok.statusBad : Tok.text2)
                    }
                }
            }.card()
        }
    }

    private var webcam: some View {
        let m = model
        return VStack(spacing: 24) {
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
            }.card()
        }
    }

    private var export: some View { ExportInspector(model: model) }
}
