import Foundation
import AppKit
import ApplicationServices
import LumenCore
import LumenProject
import LumenActuator
import LumenSpeech
@preconcurrency import ScreenCaptureKit

public struct ProduceDemoInput: ToolInput {
    public struct Export: Codable, Sendable {
        public var preset = "1080p30-h264"
        public var output = ""
        public init() {}
        enum CodingKeys: String, CodingKey { case preset, output }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? "1080p30-h264"
            output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        }
    }

    public var bundleID = ""
    public var script = DemoScript()
    public var background: String?
    public var music: String?
    public var narration = "none"
    public var export = Export()
    public var mode = "virtual"
    public var wait = false
    public init() {}

    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", script, background, music, narration, export, mode, wait }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        script = try c.decodeIfPresent(DemoScript.self, forKey: .script) ?? DemoScript()
        background = try c.decodeIfPresent(String.self, forKey: .background)
        music = try c.decodeIfPresent(String.self, forKey: .music)
        narration = try c.decodeIfPresent(String.self, forKey: .narration) ?? "none"
        export = try c.decodeIfPresent(Export.self, forKey: .export) ?? Export()
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "virtual"
        wait = try c.decodeIfPresent(Bool.self, forKey: .wait) ?? false
    }
}

public extension ToolRegistry {
    func registerDemoTools() {
        let scriptSchema = J.obj([
            "version": J.int("Script format version.", min: 1, def: 1),
            "app": J.obj(["bundle_id": J.str("Target application bundle id.")]),
            "steps": J.arr(J.obj([
                "id": J.str("Unique marker id for this step."),
                "say": J.str("Optional narration for the step."),
                "do": ToolSchemas.actionArray,
                "pad_after_s": J.num("Pause after the step.", min: 0, def: 0),
            ], required: ["do"]), "Actions grouped into named recording steps.", minItems: 1),
        ], required: ["steps"])
        let schema = J.obj([
            "bundle_id": J.str("Approved app to record and drive."),
            "script": scriptSchema,
            "background": J.str("Optional approved image path for the project background."),
            "music": J.str("Optional approved audio path for background music."),
            "narration": J.str("Narration source.", enum: ["from_script", "none"], def: "none"),
            "export": J.obj([
                "preset": J.str("Export preset.", def: "1080p30-h264"),
                "output": J.str("Approved destination path for the exported movie."),
            ], required: ["output"]),
            "mode": J.str("Input delivery mode.", enum: ["virtual", "physical"], def: "virtual"),
            "wait": J.bool("Wait for the complete workflow and stream progress.", def: false),
        ], required: ["bundle_id", "script", "export"])

        register(ToolDefinition<ProduceDemoInput>(name: "produce_demo",
            description: "Records an approved app, drives its script, applies optional background and music, scans privacy, checks QA, and exports a finished demo as one job.",
            capability: .actuate, required: ["bundle_id", "script", "export"],
            mutating: true, longRunning: true, schema: schema,
            additionalCapabilities: [.record, .edit, .export], destructive: true) { input, ctx in
                guard !input.bundleID.isEmpty else { throw ToolError.invalidArguments("bundle_id is required.") }
                guard ctx.policy.bundleAllowed(input.bundleID, for: ctx.clientID) else {
                    throw ToolError(code: "BUNDLE_NOT_ALLOWED", hint: "Approve this app in Lumen Settings > Agents before producing a demo.")
                }
                guard input.export.output.isEmpty == false else { throw ToolError.invalidArguments("export.output is required.") }
                guard ["none", "from_script"].contains(input.narration) else {
                    throw ToolError.invalidArguments("narration must be from_script or none.")
                }
                let mode: InputMode
                switch input.mode {
                case "virtual": mode = .virtual
                case "physical": mode = .physical
                default: throw ToolError.invalidArguments("mode must be virtual or physical.")
                }
                guard AXIsProcessTrusted() else { throw ToolError.permission("accessibility", pane: "Accessibility") }
                let permissions = await ctx.engine.runtime.runtimeStatus().permissions
                guard permissions.screenRecording else { throw ToolError.permission("screen recording", pane: "ScreenCapture") }
                guard permissions.inputMonitoring else { throw ToolError.permission("input monitoring", pane: "ListenEvent") }
                let backgroundURL = try input.background.map { try ctx.paths.path($0, ext: PathGuard.imageExt) }
                let musicURL = try input.music.map { try ctx.paths.path($0, ext: PathGuard.audioExt) }
                if let backgroundURL, !FileManager.default.fileExists(atPath: backgroundURL.path) {
                    throw ToolError.invalidArguments("The background image does not exist.")
                }
                if let musicURL, !FileManager.default.fileExists(atPath: musicURL.path) {
                    throw ToolError.invalidArguments("The music file does not exist.")
                }
                let outputURL = try ctx.paths.writablePath(input.export.output, ext: ["mp4", "mov"])
                var script = input.script
                script.app.bundleID = input.bundleID
                var allowedBundles: Set<String> = [input.bundleID]
                for step in script.steps {
                    for action in step.do {
                        if case .launch(let launch) = action, let target = launch.bundleID {
                            guard ctx.policy.bundleAllowed(target, for: ctx.clientID) else {
                                throw ToolError(code: "BUNDLE_NOT_ALLOWED", hint: "Approve launch target \(target) in Lumen Settings > Agents.")
                            }
                            allowedBundles.insert(target)
                        }
                    }
                }
                // AGENT: freeze validated values before a concurrent job captures them.
                let validatedScript = script
                let approvedBundles = allowedBundles
                let runtime = ctx.engine.runtime
                let engine = ctx.engine
                let jobs = ctx.jobs
                let clientPaths = ctx.paths
                let narration = input.narration
                let export = input.export
                let jobID = ctx.jobs.start(kind: "produce_demo") { reporter in
                    reporter.progress(0.02, "preflight")
                    try Task.checkCancellation()
                    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: input.bundleID) else {
                        throw ToolError(code: "APP_NOT_FOUND", hint: "Install the approved target app, then retry.")
                    }
                    if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == input.bundleID && !$0.isTerminated }) {
                        guard NSWorkspace.shared.open(appURL) else {
                            throw ToolError(code: "APP_LAUNCH_FAILED", hint: "The approved target app could not be launched.")
                        }
                    }
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == input.bundleID }) {
                        app.activate(options: [.activateAllWindows])
                    }
                    // AGENT: wait for a real target window before asking capture to resolve it.
                    let windowDeadline = Date().addingTimeInterval(10)
                    var targetWindowReady = false
                    while Date() < windowDeadline {
                        try Task.checkCancellation()
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        if content.windows.contains(where: { $0.owningApplication?.bundleIdentifier == input.bundleID }) {
                            targetWindowReady = true
                            break
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    guard targetWindowReady else {
                        throw ToolError(code: "TARGET_WINDOW_NOT_FOUND", hint: "The approved app did not open an on-screen window within 10 seconds.")
                    }
                    reporter.progress(0.05, "recording")
                    var options = RecordingOptions()
                    options.fps = 30
                    options.microphone = false
                    options.privacyAutoMask = true
                    let target = RecordingTarget(kind: .window, bundleID: input.bundleID)
                    var isRecording = false
                    do {
                        try await runtime.startRecording(target, options: options)
                        isRecording = true
                        reporter.progress(0.10, "driving app")
                        let runner = ScriptRunner(mode: mode, sink: engine.markerSink(), allowedBundles: approvedBundles,
                            inputInjector: { kind, point, button, keyCode, flags, scrollDelta in
                                try await runtime.injectInput(kind: kind, screenPoint: point, button: button,
                                    keyCode: keyCode, flags: flags, scrollDelta: scrollDelta)
                            },
                            writablePath: { try clientPaths.writablePath($0, ext: PathGuard.imageExt) })
                        let markers = try await runner.run(validatedScript)
                        reporter.progress(0.45, "finalizing")
                        let projectURL = try await runtime.stopRecording()
                        isRecording = false
                        let project = try await engine.openProject(at: projectURL.path)
                        reporter.progress(0.50, "privacy scan")
                        let scanID = try await engine.startPrivacyScan(projectID: project.identifier)
                        let scan = try await jobs.waitForCompletion(scanID) { progress, message in
                            reporter.progress(0.50 + progress * 0.10, message ?? "Scanning")
                        }
                        guard scan.state == .done else {
                            throw ToolError(code: "PRIVACY_SCAN_FAILED", hint: "The privacy scan did not finish successfully.")
                        }
                        reporter.progress(0.60, "editing")
                        _ = try await engine.replanZoom(projectID: project.identifier)
                        try await engine.edit(projectID: project.identifier, expectRevision: nil, describe: "produce demo media") { timeline in
                            if let backgroundURL {
                                var style = timeline.style
                                style.setPhotoBackground(backgroundURL.path)
                                try applyCommand(.setStyle(style), to: &timeline)
                            }
                            var audio = timeline.audio
                            audio.normalize = true
                            audio.targetLUFSOverride = -16
                            audio.musicGainDb = -18
                            audio.duckDepthDb = -18
                            if let musicURL { audio.musicPath = musicURL.path }
                            try applyCommand(.setAudio(audio), to: &timeline)
                        }
                        if narration == "from_script" {
                            for (index, step) in validatedScript.steps.enumerated() {
                                try Task.checkCancellation()
                                guard let text = step.say?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                                let markerID = step.id.isEmpty ? "step-\(index + 1)" : step.id
                                let placement = try await engine.outputSeconds(projectID: project.identifier,
                                    time: .marker(id: markerID, offsetMs: 0))
                                let provider = DefaultVoiceProvider(cacheDirectory: engine.cacheDirectory(projectID: project.identifier))
                                let generated = try await provider.generate(text: text, voice: "", model: "")
                                let cache = engine.cacheDirectory(projectID: project.identifier)
                                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                                let voiceURL = cache.appendingPathComponent("voiceover-\(UUID().uuidString).mp3")
                                try generated.data.write(to: voiceURL, options: .atomic)
                                try await engine.edit(projectID: project.identifier, expectRevision: nil, describe: "add script narration") { timeline in
                                    var audio = timeline.audio
                                    audio.lanes.append(AudioLane(role: .voiceover, path: voiceURL.path, placement: placement))
                                    try applyCommand(.setAudio(audio), to: &timeline)
                                }
                            }
                        }
                        reporter.progress(0.75, "qa")
                        let qa = try await engine.qaReport(projectID: project.identifier)
                        let failed = qa["checks"]?.arrayValue?.filter { $0["ok"]?.boolValue != true } ?? []
                        guard failed.isEmpty else {
                            throw ToolError(code: "QA_FAILED", hint: "Quality checks failed: \(JSONValue.array(failed).jsonText)")
                        }
                        reporter.progress(0.80, "exporting")
                        let exportID = try await engine.startExport(projectID: project.identifier, presetName: export.preset,
                            outputPath: outputURL.path, includeAudio: true, exportStems: false)
                        let finalExport = try await jobs.waitForCompletion(exportID) { progress, message in
                            reporter.progress(0.80 + progress * 0.20, message ?? "Exporting")
                        }
                        let output = finalExport.result?["output"]?.stringValue ?? outputURL.path
                        return .object(["project_id": .string(project.identifier), "output": .string(output),
                                        "qa": qa, "markers": .int(markers.count)])
                    } catch {
                        if isRecording { _ = try? await runtime.stopRecording() }
                        throw error
                    }
                }
                if input.wait {
                    let job = try await ctx.waitForJob(jobID)
                    return job.result ?? job.jsonValue
                }
                return .object(["job_id": .string(jobID), "state": .string("queued")])
            })
    }
}
