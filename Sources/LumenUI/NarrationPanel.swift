import SwiftUI
import LumenControl
import LumenProject
import AVFoundation

/// Explicitly initiated by the human; the text and voice ID are sent to
/// ElevenLabs only when Generate is pressed. The same backend serves MCP.
struct NarrationPanel: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var voice = ElevenLabsProvider.defaultVoice
    @State private var providerModel = ElevenLabsProvider.defaultModel
    @State private var key = ""
    @State private var configured = false
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var generatedURL: URL?
    @State private var seconds: Double = 0
    @State private var disclosure = ""
    @State private var player: AVAudioPlayer?
    @State private var placement: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Generate narration").font(AppType.title)
                Spacer()
                Button("Close") { dismiss() }.disabled(task != nil)
            }
            Text("ElevenLabs · generated speech is added as an editable audio clip. Text is sent to the provider when you generate.").font(AppType.caption).foregroundStyle(Tok.text2)
            if !configured {
                SecureField("ElevenLabs API key", text: $key)
                Button("Save key to Keychain") {
                    configured = Keychain.write(key, service: ElevenLabsProvider.keychainService, account: ElevenLabsProvider.keychainAccount)
                    key = ""
                    if !configured { issue = "Could not save the API key." }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextEditor(text: $script).font(AppType.body).frame(minHeight: 115)
            TextField("Voice ID", text: $voice)
            TextField("Model ID", text: $providerModel)
            Text("Placement: \(placement, specifier: "%.2f") s · remaining \(max(0, model.duration - placement), specifier: "%.2f") s").font(AppType.caption)
            if let issue { Text(issue).foregroundStyle(.red).font(AppType.caption) }
            if generatedURL != nil {
                Text("\(seconds, specifier: "%.2f") seconds · \(disclosure)").font(AppType.caption)
                HStack {
                    Button("Preview") { player?.currentTime = 0; player?.play() }
                    Button("Add to timeline") { insert() }.disabled(placement + seconds > model.duration + 0.05)
                }
            }
            HStack {
                if task != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
                } else {
                    Button("Generate") { generate() }
                        .disabled(!configured || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 420)
        .foregroundStyle(Tok.text).background(Tok.bg)
        .onAppear {
            placement = model.playhead
            configured = !(Keychain.read(service: ElevenLabsProvider.keychainService, account: ElevenLabsProvider.keychainAccount) ?? "").isEmpty
        }
        .onDisappear { task?.cancel(); player?.stop(); discard() }
    }

    private func discard() {
        player?.stop()
        player = nil
        if let generatedURL { try? FileManager.default.removeItem(at: generatedURL) }
        generatedURL = nil
    }

    private func generate() {
        discard()
        issue = nil
        let text = script, voiceID = voice, modelID = providerModel
        let project = model.session.bundle.url
        let provider = DefaultVoiceProvider(cacheDirectory: nil)
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await NarrationAsset.generate(in: project, text: text, voice: voiceID, model: modelID, provider: provider)
                generatedURL = result.url
                try Task.checkCancellation()
                player = try AVAudioPlayer(contentsOf: result.url)
                seconds = result.duration
                disclosure = result.disclosure
            } catch {
                discard()
                if !(error is CancellationError) { issue = error.localizedDescription }
            }
        }
    }

    private func insert() {
        guard let url = generatedURL, placement + seconds <= model.duration + 0.05 else { return }
        var lane = AudioLane(role: .voiceover, path: url.path, placement: placement)
        lane.loops = false
        model.dispatch(.addAudioLane(lane))
        guard model.timeline.audio.lanes.contains(where: { $0.id == lane.id }) else {
            issue = model.editIssue ?? "Could not add narration."; return
        }
        generatedURL = nil
        dismiss()
    }
}
