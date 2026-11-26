import Foundation
import ArgumentParser
import LumenControl

// MARK: - Shared pipeline plumbing

/// Builds the same tool-calling core the MCP proxy uses. The CLI never
/// reimplements a tool body: capture stays in the signed daemon, and every
/// record/edit/export command is a plain `tools/call` over its socket.
private func pipelineBridge(socket: String, client: String) throws -> AgentBridge {
    let path = socket.isEmpty ? LumenDaemon.defaultSocketPath()
                              : URL(fileURLWithPath: (socket as NSString).expandingTildeInPath)
    try DaemonLauncher.ensureRunning(socketPath: path)
    return AgentBridge(socketPath: path, client: client)
}

/// Prints a stable, machine-readable result. Identical shape for `record`,
/// `edit` and `export` so a script can consume all three the same way.
private func emitJSON(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

private func emitObject(_ value: [String: JSONValue]) { emitJSON(.object(value)) }

private func requireText(_ value: JSONValue?, _ field: String) throws -> String {
    guard let text = value?.stringValue, !text.isEmpty else {
        throw ValidationError("The daemon did not return \(field).")
    }
    return text
}

/// A project argument may be a canonical id (from `record_stop`) or a path to
/// a `.lumen` bundle. Paths are opened through the same `project_open` tool an
/// MCP client uses, so policy and path confinement apply here too.
private func resolveProject(_ value: String, bridge: AgentBridge) async throws -> String {
    guard value.contains("/") else { return value }
    let opened = try await bridge.callObject("project_open", arguments: ["path": .string(value)])
    return try requireText(opened["project_id"], "project_id")
}

/// Parses `start:end` or `start:end:factor` into finite numbers.
private func triple(_ text: String, field: String) throws -> (Double, Double, Double?) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts.count <= 3,
          let a = Double(parts[0]), let b = Double(parts[1]),
          a.isFinite, b.isFinite, a >= 0, b > a else {
        throw ValidationError("\(field) must be start:end or start:end:factor with 0 <= start < end.")
    }
    var factor: Double? = nil
    if parts.count == 3 {
        guard let parsed = Double(parts[2]), parsed.isFinite, parsed > 0 else {
            throw ValidationError("\(field) factor must be a positive number.")
        }
        factor = parsed
    }
    return (a, b, factor)
}

// MARK: - lumen record

/// `lumen-cli record` — start (and optionally stop) a capture through the daemon.
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start a display, window or region recording through the Lumen daemon.")

    @Option(name: .long, help: "Capture source: display, window or region.")
    var target = "display"
    @Option(name: .long, help: "Display id from `lumen-cli mcp` list_displays; 0 selects the main display.")
    var displayID = 0
    @Option(name: .long, help: "Bundle id of the window to capture.")
    var bundleID = ""
    @Option(name: .long, help: "Window id of the window to capture.")
    var windowID = 0
    @Option(name: .long, help: "Region left edge as a fraction of the display (0...1).")
    var regionX = 0.0
    @Option(name: .long, help: "Region top edge as a fraction of the display (0...1).")
    var regionY = 0.0
    @Option(name: .long, help: "Region width as a fraction of the display (0...1).")
    var regionWidth = 1.0
    @Option(name: .long, help: "Region height as a fraction of the display (0...1).")
    var regionHeight = 1.0
    @Option(name: .long, help: "Capture frame rate (24...120).")
    var fps = 60
    @Flag(name: .long, inversion: .prefixedNo, help: "Capture the microphone (default: yes).")
    var microphone = true
    @Flag(name: .long, help: "Capture system audio.")
    var systemAudio = false
    @Flag(name: .long, help: "Capture a connected camera.")
    var webcam = false
    @Flag(name: .long, inversion: .prefixedNo, help: "Automatically mask sensitive text (default: yes).")
    var privacyAutoMask = true
    @Option(name: .long, help: "Auto-stop after this many seconds and return the project path.")
    var duration: Double?
    @Option(name: .long, help: "Path to the daemon socket.")
    var socket = ""
    @Option(name: .long, help: "Client id used for capability grants.")
    var client = "cli"

    func run() async throws {
        guard ["display", "window", "region"].contains(target) else {
            throw ValidationError("target must be display, window or region.")
        }
        if let duration, (!duration.isFinite || duration < 0) {
            throw ValidationError("duration must be a nonnegative number of seconds.")
        }
        let bridge = try pipelineBridge(socket: socket, client: client)
        let arguments: [String: JSONValue] = .obj([
            "target": .string(target),
            "display_id": .int(displayID),
            "bundle_id": bundleID.isEmpty ? nil : .string(bundleID),
            "window_id": windowID == 0 ? nil : .int(windowID),
            "region_x": .number(regionX), "region_y": .number(regionY),
            "region_width": .number(regionWidth), "region_height": .number(regionHeight),
            "fps": .int(fps), "microphone": .bool(microphone),
            "system_audio": .bool(systemAudio), "webcam": .bool(webcam),
            "privacy_auto_mask": .bool(privacyAutoMask),
        ])
        let started = try await bridge.callObject("record_start", arguments: arguments)
        emitObject(started)
        guard let duration else { return }
        try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
        let stopped = try await bridge.callObject("record_stop")
        emitObject(stopped)
    }
}

// MARK: - lumen edit

/// `lumen-cli edit` — applies the same edit tools an MCP client calls.
struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a recording: cut, split, speed, zoom, background, caption and post-process.")

    @Argument(help: "Project id from `record`, or a path to a .lumen bundle.")
    var project: String
    @Option(name: .long, help: "Remove a source span, start:end.")
    var cut: [String] = []
    @Option(name: .long, help: "Split the clip at an output time in seconds.")
    var split: [Double] = []
    @Option(name: .long, help: "Playback speed over a source span, start:end:factor.")
    var speed: [String] = []
    @Option(name: .long, help: "Manual zoom over a source span, start:end:scale.")
    var zoom: [String] = []
    @Option(name: .long, help: "Canvas background kind (from background_list).")
    var background: String?
    @Option(name: .long, help: "Output aspect as W:H. Drives canvas framing; pixel size comes from the export preset.")
    var resolution: String?
    @Option(name: .long, help: "Browser auto-crop: on, off, chromeTyping, anyTyping or never.")
    var crop: String?
    @Option(name: .long, help: "Cursor artwork pack.")
    var cursorPack: String?
    @Option(name: .long, help: "Cursor size multiplier (0.25...4).")
    var cursorSize: Double?
    @Option(name: .long, help: "Click effect: none, ripple, pulse, burst or glass.")
    var clickEffect: String?
    @Option(name: .long, help: "Microphone gain in dB (-60...12).")
    var micGainDB: Double?
    @Option(name: .long, help: "Music gain in dB (-60...12).")
    var musicGainDB: Double?
    @Option(name: .long, help: "Master output gain in dB (-60...12).")
    var outputGainDB: Double?
    @Option(name: .long, help: "Caption text to overlay from 0s for 2s.")
    var overlay: String?
    @Option(name: .long, help: "Overlay start time in source seconds.")
    var overlayStart = 0.0
    @Option(name: .long, help: "Overlay end time in source seconds.")
    var overlayEnd = 2.0
    @Flag(name: .long, help: "Re-run derived analysis and QA checks after editing.")
    var postProcess = false
    @Flag(name: .long, help: "Validate every edit without writing anything.")
    var dryRun = false
    @Option(name: .long, help: "Path to the daemon socket.")
    var socket = ""
    @Option(name: .long, help: "Client id used for capability grants.")
    var client = "cli"

    func run() async throws {
        let bridge = try pipelineBridge(socket: socket, client: client)
        let projectID = try await resolveProject(project, bridge: bridge)
        var applied: [String: JSONValue] = ["project_id": .string(projectID), "operations": .array([])]
        var operations: [JSONValue] = []

        func apply(_ tool: String, _ args: [String: JSONValue]) async throws {
            var merged = args
            merged["project_id"] = .string(projectID)
            let result = try await bridge.callObject(tool, arguments: merged, dryRun: dryRun)
            operations.append(.object(["tool": .string(tool), "result": .object(result)]))
        }

        for span in cut {
            let (start, end, _) = try triple(span, field: "--cut")
            try await apply("cut_span", ["start": .number(start), "end": .number(end), "basis": .string("source")])
        }
        for at in split {
            guard at.isFinite, at >= 0 else { throw ValidationError("--split must be a nonnegative time.") }
            try await apply("split_clip", ["at": .number(at)])
        }
        for span in speed {
            let (start, end, factor) = try triple(span, field: "--speed")
            let rate = factor ?? 2
            guard (0.25...16).contains(rate) else { throw ValidationError("speed must be between 0.25 and 16.") }
            try await apply("set_speed", ["start": .number(start), "end": .number(end),
                                          "speed": .number(rate), "basis": .string("source")])
        }
        for span in zoom {
            let (start, end, scale) = try triple(span, field: "--zoom")
            let amount = scale ?? 1.8
            guard (1.1...4).contains(amount) else { throw ValidationError("zoom scale must be between 1.1 and 4.") }
            try await apply("set_zoom", ["start": .number(start), "end": .number(end),
                                         "scale": .number(amount), "basis": .string("source")])
        }
        var styleArgs: [String: JSONValue] = [:]
        if let background, !background.isEmpty { styleArgs["background"] = .string(background) }
        if let resolution {
            let parts = resolution.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
                  w > 0, h > 0, w.isFinite, h.isFinite else {
                throw ValidationError("--resolution must be W:H with positive numbers, e.g. 1920:1080.")
            }
            styleArgs["aspect"] = .number(w / h)
        }
        if !styleArgs.isEmpty { try await apply("style_set", styleArgs) }
        if let crop, !crop.isEmpty {
            switch crop {
            case "on": try await apply("crop_set", ["enabled": .bool(true)])
            case "off": try await apply("crop_set", ["enabled": .bool(false)])
            case "chromeTyping", "anyTyping", "never": try await apply("crop_set", ["uncrop": .string(crop)])
            default: throw ValidationError("--crop must be on, off, chromeTyping, anyTyping or never.")
            }
        }
        if cursorPack != nil || cursorSize != nil || clickEffect != nil {
            var args: [String: JSONValue] = .obj([
                "pack": cursorPack.map(JSONValue.string),
                "size": cursorSize.map(JSONValue.number),
                "click_effect": clickEffect.map(JSONValue.string),
            ])
            args["project_id"] = .string(projectID)
            let result = try await bridge.callObject("cursor_set", arguments: args, dryRun: dryRun)
            operations.append(.object(["tool": .string("cursor_set"), "result": .object(result)]))
        }
        let sounds: [String: JSONValue] = .obj([
            "mic_gain_db": micGainDB.map(JSONValue.number),
            "music_gain_db": musicGainDB.map(JSONValue.number),
            "output_gain_db": outputGainDB.map(JSONValue.number),
        ])
        if !sounds.isEmpty {
            for (key, value) in sounds {
                guard let db = value.doubleValue, (-60...12).contains(db) else {
                    throw ValidationError("\(key) must be between -60 and 12 dB.")
                }
            }
            try await apply("audio_mix_set", sounds)
        }
        if let overlay, !overlay.isEmpty {
            guard overlay.count <= 500, overlayEnd > overlayStart else {
                throw ValidationError("overlay must be 1...500 characters and end after start.")
            }
            try await apply("add_caption", ["text": .string(overlay),
                                            "start": .number(overlayStart), "end": .number(overlayEnd),
                                            "basis": .string("source")])
        }
        if postProcess {
            try await apply("post_process", [:])
        }
        let readback = try await bridge.callObject("get_edit", arguments: ["project_id": .string(projectID)])
        operations.append(.object(["tool": .string("get_edit"), "result": .object(readback)]))
        applied["operations"] = .array(operations)
        applied["revision"] = readback["revision"] ?? .null
        emitObject(applied)
    }
}

// MARK: - lumen export

/// `lumen-cli export` — exports a project and waits for the job, returning
/// the output path and the export metadata in one JSON document.
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a project to a movie and return its path and metadata.")

    @Argument(help: "Project id from `record`, or a path to a .lumen bundle.")
    var project: String
    @Option(name: .long, help: "Absolute output movie path inside an approved folder.")
    var output: String
    @Option(name: .long, help: "Preset name from export_presets.")
    var preset = "1080p30-h264"
    @Flag(name: .long, inversion: .prefixedNo, help: "Include the mixed soundtrack (default: yes).")
    var includeAudio = true
    @Flag(name: .long, help: "Also write separate audio stems.")
    var exportStems = false
    @Flag(name: .long, help: "Replace an existing file at the output path.")
    var overwrite = false
    @Option(name: .long, help: "Path to the daemon socket.")
    var socket = ""
    @Option(name: .long, help: "Client id used for capability grants.")
    var client = "cli"

    func run() async throws {
        guard !output.isEmpty else { throw ValidationError("--output is required.") }
        let bridge = try pipelineBridge(socket: socket, client: client)
        let projectID = try await resolveProject(project, bridge: bridge)
        let arguments: [String: JSONValue] = .obj([
            "project_id": .string(projectID),
            "output": .string(output),
            "preset": .string(preset),
            "include_audio": .bool(includeAudio),
            "export_stems": .bool(exportStems),
            "overwrite": .bool(overwrite),
            "wait": .bool(true),
        ])
        let result = try await bridge.callObject("export_final", arguments: arguments)
        let path = try requireText(result["output"], "output path")
        emitObject([
            "project_id": .string(projectID),
            "output": .string(path),
            "preset": .string(preset),
            "job": result["job_id"] ?? .null,
            "result": result["result"] ?? .null,
        ])
    }
}
