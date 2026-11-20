import SwiftUI
import AppKit
import LumenExport
import LumenProject

/// The remaining rail pages. Each one has a single headline action and at
/// most a few controls; anything that was only there because it used to be
/// there is gone.
extension Inspector {
    var soundPage: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Sound", "The voice matters. Everything else is already balanced.")
            panel {
                SliderRow(label: "Voice level", v: m.bind(\.audio.voiceBoostDb), range: 0...6,
                          fmt: { String(format: "%+.1f dB", $0) })
                SliderRow(label: "Noise reduction", v: Binding(
                    get: { m.timeline.audio.noiseReductionStrength },
                    set: { value in m.edit(coalesce: true) {
                        $0.audio.noiseReductionStrength = value
                        $0.audio.micClean = value > 0
                    } }), range: 0...1, fmt: { "\(Int($0 * 100))%" })
                ToggleRow(label: "Sound effects", on: m.bind(\.audio.soundEffectsEnabled))
            }
            Text("Music lives on the Look page. Microphone and system levels follow the source.")
                .font(Diether.prose(12)).foregroundStyle(Diether.ink2)
        }
    }

    var textPage: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Text", "Captions and the titles you write yourself.")
            panel {
                ToggleRow(label: "Captions", on: m.bind(\.captions.enabled))
                row("Font") {
                    LSegmented(sel: m.bind(\.captions.style.font), items: [(.sans, "Sans"), (.serif, "Serif")])
                        .frame(width: 128)
                }
                SliderRow(label: "Size", v: m.bind(\.captions.style.size), range: 0.03...0.09,
                          fmt: { "\(Int($0 * 100))%" })
            }
            panel {
                HStack {
                    Text("Manual titles").font(Diether.prose(13, .medium)).foregroundStyle(Diether.ink)
                    Spacer(minLength: 8)
                    LButton(title: "Add", icon: "plus", kind: .quiet) { m.addManualTitle() }
                }
                if m.timeline.overlays.texts.isEmpty {
                    Text("No titles yet.").font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                } else {
                    ForEach(m.timeline.overlays.texts) { title in
                        HStack(spacing: 8) {
                            TextField("Title", text: Binding(
                                get: { m.timeline.overlays.texts.first(where: { $0.id == title.id })?.text ?? title.text },
                                set: { m.dispatch(.editText(title.id, $0)) }))
                                .textFieldStyle(.plain).font(Diether.prose(13)).foregroundStyle(Diether.ink)
                            LIconButton(icon: "trash", label: "Remove title") { m.dispatch(.deleteText(title.id)) }
                        }
                    }
                }
            }
            if !m.transcriptWords.isEmpty {
                panel {
                    Text("\(m.transcriptWords.count) spoken words in the transcript.")
                        .font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                    LButton(title: "Remove fillers", icon: "text.badge.xmark", kind: .quiet) { m.removeFillerWords() }
                }
            }
        }
    }

    var trimPage: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Trim", "Cut the recording and choose what the camera follows.")
            panel {
                HStack(spacing: 8) {
                    LButton(title: "Split", icon: "scissors", kind: .secondary) { m.splitAtPlayhead() }
                    LButton(title: "Duplicate", icon: "doc.on.doc", kind: .secondary) { m.duplicateSelected() }
                        .disabled(m.selection == nil)
                }
                HStack(spacing: 8) {
                    LButton(title: "Ripple delete", icon: "trash", kind: .quiet) { m.rippleDeleteSelected() }
                        .disabled(m.selection == nil)
                    LButton(title: "Copy", icon: "doc.on.doc", kind: .quiet) { m.copySelectedClip() }
                        .disabled(m.selection == nil)
                    LButton(title: "Paste", icon: "doc.on.clipboard", kind: .quiet) { m.pasteClipAtPlayhead() }
                        .disabled(m.copiedClip == nil)
                }
                ToggleRow(label: "Snap to edits", on: Binding(get: { m.snapEnabled }, set: { m.snapEnabled = $0 }))
            }
            panel {
                Text("Framing").font(Diether.prose(13, .medium)).foregroundStyle(Diether.ink)
                ToggleRow(label: "Auto zoom", on: m.bind(\.camera.autoZoom))
                SliderRow(label: "Zoom amount",
                          v: Binding(get: { m.timeline.camera.baseScale },
                                     set: { v in m.edit(coalesce: true) { $0.camera.baseScale = v } }),
                          range: 1.3...3.0, fmt: { String(format: "%.1f×", $0) })
                row("Layout") {
                    LDropdown(sel: framingLayout,
                              options: FramingLayoutStyle.all.map { ($0.0, $0.1, "rectangle.3.group") })
                        .frame(width: 132)
                }
            }
        }
    }

    var framingLayout: Binding<LayoutKind> {
        Binding(get: { Self.currentLayout(in: model.timeline, at: model.playhead) },
                set: { kind in
                    model.edit { timeline in
                        timeline.layouts = [LayoutSegment(start: 0, end: timeline.timeMap.sourceDuration, kind: kind)]
                    }
                })
    }

    var privacyPage: some View {
        let m = model
        let detected = m.timeline.derived?.autoMasks.count ?? 0
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Privacy", "Cover anything sensitive before it leaves this Mac.")
            panel {
                ToggleRow(label: "Detect sensitive data", on: m.bind(\.overlays.privacy.autoDetect))
                row("Style") {
                    LDropdown(sel: m.bind(\.overlays.privacy.mode), options: [
                        (.blur, "Frost", "drop"), (.pixelate, "Pixelate", "square.grid.3x3"),
                        (.solid, "Redact", "rectangle.fill")])
                        .frame(width: 116)
                }
                LButton(title: m.maskEditing ? "Cancel mask" : "Draw mask",
                        icon: m.maskEditing ? "xmark" : "rectangle.dashed", kind: .secondary) {
                    m.focusEditing = false
                    m.maskEditing.toggle()
                }
            }
            panel {
                Text(detected == 0 ? "Nothing detected." : "\(detected) region\(detected == 1 ? "" : "s") will be covered.")
                    .font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                if m.privacyScanning {
                    Text("Scanning \(Int(m.privacyScanProgress * 100))%.")
                        .font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                } else if let error = m.privacyScanError {
                    Text("Scan failed: \(error)").font(Diether.prose(12)).foregroundStyle(Diether.ink2)
                }
            }
        }
    }

    var exportPage: some View {
        let m = model
        let s = m.exportSettings
        return VStack(alignment: .leading, spacing: 22) {
            pageHeader("Export", "One file, ready to share.")
            panel {
                DitherColorBandView(progress: exportFraction)
                    .frame(height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(exportHeadline).font(Diether.display(15)).foregroundStyle(Diether.ink)
                Text(exportDetail).font(Diether.prose(12)).foregroundStyle(Diether.ink2)
            }
            panel {
                row("Size") {
                    LSegmented(sel: resolutionSelection, items: [(ExportResolution.p1080, "1080p"), (.p1440, "1440p"), (.ultraHD, "4K")])
                        .frame(width: 188)
                }
                row("Rate") {
                    LSegmented(sel: rateSelection, items: [(ExportRate.f60, "60"), (.f120, "120")])
                        .frame(width: 128)
                }
                row("Codec") {
                    LDropdown(sel: m.exportBinding(\.codec),
                              options: VideoCodec.allCases.map { ($0, $0.title, "film") })
                        .frame(width: 128)
                }
                TextField("Filename", text: m.exportBinding(\.filename))
                    .textFieldStyle(.plain).font(Diether.prose(13)).foregroundStyle(Diether.ink)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Diether.lift))
                HStack(spacing: 8) {
                    Text((s.folder as NSString).lastPathComponent)
                        .font(Diether.prose(12)).foregroundStyle(Diether.ink2).lineLimit(1)
                    Spacer(minLength: 4)
                    LButton(title: "Choose…", kind: .quiet) { m.chooseExportFolder() }
                }
            }
            exportAction
        }
    }

    private var resolutionSelection: Binding<ExportResolution> {
        Binding(get: { model.exportSettings.resolution },
                set: { value in model.updateExportSettings { $0.resolution = value } })
    }

    private var rateSelection: Binding<ExportRate> {
        Binding(get: { model.exportSettings.frameRate },
                set: { value in model.updateExportSettings { $0.frameRate = value } })
    }

    private var exportFraction: Double {
        if case .running(let f) = model.exportState { return f }
        return 0
    }

    private var exportHeadline: String {
        switch model.exportState {
        case .idle: "Ready."
        case .running: "Writing the file."
        case .done: "Saved."
        case .failed: "Not saved."
        }
    }

    private var exportDetail: String {
        switch model.exportState {
        case .idle: "\(model.exportSettings.resolution.rawValue), \(model.exportSettings.frameRate.rawValue) fps, \(model.exportSettings.codec.title)"
        case .running(let f): "\(Int(f * 100))%  ·  \(model.exportETA.map { "\(Int($0.rounded())) s left" } ?? "Estimating")"
        case .done(let url): url.lastPathComponent
        case .failed(let error): error
        }
    }

    @ViewBuilder private var exportAction: some View {
        switch model.exportState {
        case .idle:
            LButton(title: "Export", icon: "square.and.arrow.up", kind: .primary, height: 32) {
                model.exportVideo()
            }
        case .running:
            LButton(title: "Cancel", kind: .quiet) { model.cancelExport() }
        case .done(let url):
            HStack(spacing: 8) {
                LButton(title: "Reveal", icon: "folder", kind: .secondary) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                LButton(title: "Again", kind: .quiet) { model.exportVideo() }
            }
        case .failed:
            LButton(title: "Retry", icon: "arrow.clockwise", kind: .primary, height: 32) {
                model.exportVideo()
            }
        }
    }
}
