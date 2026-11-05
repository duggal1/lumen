import SwiftUI
import AppKit
import LumenExport
import LumenProject

/// Three meaning-based groups. The stage remains primary; export lives in the inspector.
struct ExportInspector: View {
    let model: EditorModel
    @State private var copied = false

    private var settings: ExportSettings { model.exportSettings }
    private var source: LumenProject.SourceInfo { model.session.meta.source }
    private var aspect: Double { model.timeline.style.aspectRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            output
            destination
            action
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Video").font(AppType.title).foregroundStyle(Tok.text)
            Row(label: "Kind") {
                LSegmented(sel: model.exportBinding(\.kind),
                           items: [(.video, "Video"), (.gif, "GIF")])
                    .frame(width: 132)
            }
            if settings.kind == .gif {
                Text("800 px wide, 15 fps, loops forever.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            } else {
                Row(label: "Format") {
                    HStack(spacing: Space.s2) {
                        LDropdown(sel: model.exportBinding(\.container),
                                  options: ExportContainer.allCases.map { ($0, $0.rawValue, "film") })
                            .frame(width: 90)
                            .disabled(settings.codec == .prores)
                        LDropdown(sel: model.exportBinding(\.codec),
                                  options: VideoCodec.allCases.map { ($0, $0.title, "video") })
                            .frame(width: 110)
                    }
                }
                Row(label: "Resolution") {
                    LDropdown(sel: model.exportBinding(\.resolution),
                              options: ExportResolution.allCases.map { ($0, $0.rawValue, "rectangle.dashed") })
                        .frame(width: 132)
                }
                if settings.resolution == .custom {
                    HStack(spacing: Space.s2) {
                        TextField("Width", value: model.exportBinding(\.customWidth), format: .number)
                            .textFieldStyle(.plain).font(AppType.body).frame(width: 88).field()
                        Text("×").font(AppType.caption).foregroundStyle(Tok.text2)
                        TextField("Height", value: model.exportBinding(\.customHeight), format: .number)
                            .textFieldStyle(.plain).font(AppType.body).frame(width: 88).field()
                    }
                }
                let dimensions = settings.dimensions(source: source, aspect: aspect)
                Text("\(dimensions.0) × \(dimensions.1) px")
                    .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                Row(label: "Frame rate") {
                    LDropdown(sel: model.exportBinding(\.frameRate),
                              options: ExportRate.allCases.map { ($0, $0.rawValue == "Source" ? "Source" : "\($0.rawValue) fps", "film.stack") })
                        .frame(width: 132)
                }
                Row(label: "Quality") {
                    LDropdown(sel: model.exportBinding(\.quality),
                              options: ExportQuality.allCases.map { ($0, $0.rawValue, "slider.horizontal.3") })
                        .frame(width: 132)
                }
                Row(label: "Audio") {
                    HStack(spacing: Space.s2) {
                        LToggle(on: model.exportBinding(\.includeAudio), label: "Include audio")
                        if settings.includeAudio {
                            LDropdown(sel: model.exportBinding(\.audioBitrate),
                                      options: [128, 192, 256, 320].map { ($0 * 1000, "\($0) kbps", "waveform") })
                                .frame(width: 110)
                        }
                    }
                }
                ToggleRow(label: "Also 1:1 and 9:16", on: model.exportBinding(\.batchAspects))
            }
        }.card()
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Location").font(AppType.title).foregroundStyle(Tok.text)
            TextField("Folder", text: model.exportBinding(\.folder))
                .textFieldStyle(.plain).font(AppType.body).field()
                .accessibilityLabel("Export folder")
            HStack(spacing: Space.s1) {
                LButton(title: "Desktop", kind: .quiet) { setFolder(.desktopDirectory) }
                LButton(title: "Downloads", kind: .quiet) { setFolder(.downloadsDirectory) }
                LButton(title: "Movies", kind: .quiet) { setFolder(.moviesDirectory) }
            }
            LButton(title: "Choose folder…", icon: "folder", kind: .secondary) { model.chooseExportFolder() }
            Text("Filename").font(AppType.label).foregroundStyle(Tok.text)
            TextField("Name", text: model.exportBinding(\.filename))
                .textFieldStyle(.plain).font(AppType.body).field()
                .accessibilityLabel("Export filename")
        }.card()
    }

    private func setFolder(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            model.updateExportSettings { $0.folder = url.path }
        }
    }

    private var action: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Estimate").font(AppType.title).foregroundStyle(Tok.text)
            if settings.kind == .gif {
                Text("GIF").font(AppType.metric).foregroundStyle(Tok.text)
                Text("Small, silent and loopable.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            } else {
                let bytes = settings.estimatedBytes(source: source, aspect: aspect, outputDuration: model.duration)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(AppType.metric).foregroundStyle(Tok.text)
                if let seconds = model.estimatedExportSeconds {
                    Text("Around \(Int(seconds.rounded())) s based on your last export")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                } else {
                    Text("Export time is measured after the first export.")
                        .font(AppType.caption).foregroundStyle(Tok.text2)
                }
            }
            switch model.exportState {
            case .idle:
                HStack(spacing: Space.s2) {
                    LButton(title: "Export", icon: "square.and.arrow.up", kind: .primary, height: 32) {
                        model.exportVideo()
                    }
                    if settings.kind == .video {
                        LButton(title: "Copy to clipboard", icon: "doc.on.clipboard", kind: .secondary, height: 32) {
                            model.exportToClipboard()
                        }
                    }
                }
            case .running(let fraction):
                progress(fraction)
                Text(String(format: "%.1f s elapsed", model.exportElapsed))
                    .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                LButton(title: "Cancel", kind: .quiet) { model.cancelExport() }
            case .done(let url):
                Text("Saved \(url.lastPathComponent)").font(AppType.caption).foregroundStyle(Tok.text2)
                    .lineLimit(2)
                HStack(spacing: Space.s2) {
                    LButton(title: "Reveal in Finder", icon: "folder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    LButton(title: copied ? "Copied" : "Copy path", kind: .quiet) {
                        NSPasteboard.general.clearContents()
                        _ = NSPasteboard.general.setString(url.path, forType: .string)
                        copied = true
                    }
                }
                LButton(title: "Export again", kind: .primary, height: 32) { model.exportVideo() }
            case .failed(let error):
                Text(error).font(AppType.caption).foregroundStyle(Tok.statusBad).fixedSize(horizontal: false, vertical: true)
                LButton(title: "Retry export", kind: .primary, height: 32) { model.exportVideo() }
            }
            if let notice = model.notice { Text(notice).font(AppType.caption).foregroundStyle(Tok.text2) }
        }.card()
    }

    private func progress(_ value: Double) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(value * 100))%")
                    .font(AppType.metric).foregroundStyle(Tok.text)
                Spacer(minLength: Space.s2)
                Text(model.exportETA.map { "\(Int($0.rounded())) s left" } ?? "Estimating")
                    .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
            }
            PixelProgress(value: value)
                .accessibilityLabel("Export progress")
                .accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}

private extension View {
    func field() -> some View {
        self.padding(.horizontal, Space.s3).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
    }
}
