import Foundation
import CoreGraphics
import LumenCore
import LumenProject
import LumenCapture

// MARK: - Record tools

public struct RecordStartInput: ToolInput {
    public var target: String = "display"          // display | window | region
    public var displayID: Int = 0
    public var bundleID: String = ""
    public var windowID: Int = 0
    /// Normalized region (0...1) of the target display.
    public var regionX: Double = 0
    public var regionY: Double = 0
    public var regionWidth: Double = 1
    public var regionHeight: Double = 1
    public var fps: Int = 60
    public var microphone: Bool = true
    public var systemAudio: Bool = false
    public var webcam: Bool = false
    /// Automatic privacy masking. On by default for agent recordings.
    public var privacyAutoMask: Bool = true
    public init() {}

    enum CodingKeys: String, CodingKey {
    case target
    case displayID = "display_id"
    case bundleID = "bundle_id"
    case windowID = "window_id"
    case regionX = "region_x"
    case regionY = "region_y"
    case regionWidth = "region_width"
    case regionHeight = "region_height"
    case fps
    case microphone
    case systemAudio = "system_audio"
    case webcam
    case privacyAutoMask = "privacy_auto_mask"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.target = try c.decodeIfPresent(String.self, forKey: .target) ?? "display"          // display | window | region
    self.displayID = try c.decodeIfPresent(Int.self, forKey: .displayID) ?? 0
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    self.windowID = try c.decodeIfPresent(Int.self, forKey: .windowID) ?? 0
    self.regionX = try c.decodeIfPresent(Double.self, forKey: .regionX) ?? 0
    self.regionY = try c.decodeIfPresent(Double.self, forKey: .regionY) ?? 0
    self.regionWidth = try c.decodeIfPresent(Double.self, forKey: .regionWidth) ?? 1
    self.regionHeight = try c.decodeIfPresent(Double.self, forKey: .regionHeight) ?? 1
    self.fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
    self.microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? true
    self.systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
    self.webcam = try c.decodeIfPresent(Bool.self, forKey: .webcam) ?? false
    self.privacyAutoMask = try c.decodeIfPresent(Bool.self, forKey: .privacyAutoMask) ?? true
    }
}

public struct RecordPauseInput: ToolInput {
    public init() {}
}

public struct RecordResumeInput: ToolInput {
    public init() {}
}

public struct RecordMarkerInput: ToolInput {
    public var id: String = ""
    public var label: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case id
    case label
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

public struct RecordStopInput: ToolInput {
    public init() {}
}

public extension ToolRegistry {
    func registerRecordTools() {
        register(ToolDefinition<RecordStartInput>(name: "record_start",
            description: "Starts a recording. Target a display, a window (by bundle id or window id) or a region. Automatic privacy masking is on by default: agent recordings show emails and tokens.",
            capability: .record, required: ["target"], mutating: true) { input, ctx in
                var target = RecordingTarget(kind: .display)
                switch input.target {
                case "window":
                    target.kind = .window
                    target.bundleID = input.bundleID.isEmpty ? nil : input.bundleID
                    target.windowID = input.windowID > 0 ? UInt32(input.windowID) : nil
                case "region":
                    target.kind = .region
                    target.displayID = input.displayID > 0 ? UInt32(input.displayID) : CGMainDisplayID()
                    target.rect = CGRect(x: input.regionX, y: input.regionY,
                                         width: input.regionWidth, height: input.regionHeight)
                default:
                    target.kind = .display
                    target.displayID = input.displayID > 0 ? UInt32(input.displayID) : CGMainDisplayID()
                }
                var options = RecordingOptions()
                options.fps = max(24, min(input.fps, 120))
                options.microphone = input.microphone
                options.systemAudio = input.systemAudio
                options.webcam = input.webcam
                options.privacyAutoMask = input.privacyAutoMask
                do {
                    try await ctx.engine.runtime.startRecording(target, options: options)
                } catch let e as ToolError {
                    throw e
                } catch {
                    throw ToolError.failed("Recording could not start: \(error)")
                }
                return .object(["recording": .bool(true), "target": .string(input.target),
                                "privacy_auto_mask": .bool(options.privacyAutoMask)])
            })

        register(ToolDefinition<RecordPauseInput>(name: "record_pause",
            description: "Pauses the running recording. Frames and audio stop being captured; the paused span is cut out of the final video.",
            capability: .record, mutating: true) { _, ctx in
                try await ctx.engine.runtime.pauseRecording()
                return .object(["paused": .bool(true)])
            })

        register(ToolDefinition<RecordResumeInput>(name: "record_resume",
            description: "Resumes a paused recording.",
            capability: .record, mutating: true) { _, ctx in
                try await ctx.engine.runtime.resumeRecording()
                return .object(["paused": .bool(false)])
            })

        register(ToolDefinition<RecordMarkerInput>(name: "record_marker",
            description: "Drops a named marker into the running recording. Anchor edits and audio to markers instead of seconds.",
            capability: .record, required: ["id"], mutating: true) { input, ctx in
                let now = HostClock.now()
                let marker = CaptureMarker(id: input.id, label: input.label.isEmpty ? nil : input.label,
                                           startHostSeconds: now, endHostSeconds: now, rect: nil)
                try await ctx.engine.runtime.addMarker(marker)
                return .object(["marker_id": .string(input.id), "host_seconds": .number(now)])
            })

        register(ToolDefinition<RecordStopInput>(name: "record_stop",
            description: "Stops the recording, finalizes the project and returns its project id. The project is written to the Lumen library.",
            capability: .record, mutating: true) { _, ctx in
                let url = try await ctx.engine.runtime.stopRecording()
                let identifier = url.deletingPathExtension().lastPathComponent
                _ = try? await ctx.engine.openProject(at: url.path)
                return .object(["project_id": .string(identifier), "path": .string(url.path)])
            })
    }
}
