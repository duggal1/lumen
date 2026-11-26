import Foundation
import LumenCore
import LumenProject

// MARK: - Crop and cursor option tools

/// One partially-decodable carrier for the two option verbs. Each publishes a
/// precise, closed schema below; the shared type keeps the registry identical
/// to every other tool in the catalog.
public struct OptionsInput: ToolInput {
    public var projectID: String = ""
    public var revision: Int?
    // crop
    public var enabled: Bool?
    public var uncrop: String?
    public var insetPx: Double?
    public var holdAfterTyping: Double?
    public var holdAfterUIClick: Double?
    public var minDwell: Double?
    // cursor
    public var pack: String?
    public var size: Double?
    public var smoothingSigma: Double?
    public var glide: Double?
    public var constantSize: Bool?
    public var clickEffect: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", revision, enabled, uncrop
        case insetPx = "inset_px"
        case holdAfterTyping = "hold_after_typing"
        case holdAfterUIClick = "hold_after_ui_click"
        case minDwell = "min_dwell"
        case pack, size, smoothingSigma = "smoothing_sigma", glide
        case constantSize = "constant_size"
        case clickEffect = "click_effect"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        uncrop = try c.decodeIfPresent(String.self, forKey: .uncrop)
        insetPx = try c.decodeIfPresent(Double.self, forKey: .insetPx)
        holdAfterTyping = try c.decodeIfPresent(Double.self, forKey: .holdAfterTyping)
        holdAfterUIClick = try c.decodeIfPresent(Double.self, forKey: .holdAfterUIClick)
        minDwell = try c.decodeIfPresent(Double.self, forKey: .minDwell)
        pack = try c.decodeIfPresent(String.self, forKey: .pack)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        smoothingSigma = try c.decodeIfPresent(Double.self, forKey: .smoothingSigma)
        glide = try c.decodeIfPresent(Double.self, forKey: .glide)
        constantSize = try c.decodeIfPresent(Bool.self, forKey: .constantSize)
        clickEffect = try c.decodeIfPresent(String.self, forKey: .clickEffect)
    }
}

private enum OptionSchemas {
    static let projectID = J.str("Project id returned by project_open, project_list or record_stop.")
    static let revision = J.int("Expected revision; a mismatch returns REVISION_CONFLICT.", min: 0)
    static let editResult = J.obj([
        "project_id": projectID,
        "revision": J.int("Revision after applying the option.", min: 0),
        "changed": J.bool("False when the option was already set (idempotent no-op)."),
        "diff": J.arr(.object(["type": .string("object")]), "Field-level before/after changes."),
        "warnings": J.arr(J.str("Validation warning."), "Warnings."),
    ], required: ["project_id", "revision", "changed", "diff"])

    static let crop = J.obj([
        "project_id": projectID,
        "revision": revision,
        "enabled": J.bool("Turn browser-content auto-crop on or off.", def: true),
        "uncrop": J.str("When to temporarily reveal the browser chrome.", enum: ["chromeTyping", "anyTyping", "never"]),
        "inset_px": J.num("Pixels trimmed at the cropped page edge.", min: 0, max: 40),
        "hold_after_typing": J.num("Seconds to keep the crop after the last keystroke.", min: 0, max: 10),
        "hold_after_ui_click": J.num("Seconds to keep the crop after a UI click.", min: 0, max: 10),
        "min_dwell": J.num("Minimum seconds a crop state must persist.", min: 0, max: 10),
    ], required: ["project_id"])

    static let cursor = J.obj([
        "project_id": projectID,
        "revision": revision,
        "pack": J.str("Cursor artwork pack from CursorPack.rawValue."),
        "size": J.num("Cursor size multiplier.", min: 0.25, max: 4),
        "smoothing_sigma": J.num("Pointer smoothing in seconds.", min: 0, max: 0.5),
        "glide": J.num("Pointer glide in seconds.", min: 0, max: 2),
        "constant_size": J.bool("Keep the on-screen cursor size during zoom."),
        "click_effect": J.str("Click sound/visual effect.", enum: ["none", "ripple", "pulse", "burst", "glass"]),
    ], required: ["project_id"])
}

public extension ToolRegistry {
    func registerOptionsTools() {
        register(ToolDefinition<OptionsInput>(name: "crop_set",
            description: "Tune the browser-content auto-crop: enable or disable it, choose when typing reveals the chrome and adjust its timing. Idempotent; returns the edit diff.",
            capability: .edit, required: ["project_id"], mutating: true,
            schema: OptionSchemas.crop, idempotent: true,
            outputSchema: OptionSchemas.editResult, customDryRun: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID,
                    expectRevision: input.revision, describe: "crop options") { timeline in
                    var patch = CropSettingsPatch()
                    if let enabled = input.enabled { patch.enabled = enabled }
                    if let uncrop = input.uncrop {
                        guard let policy = UncropPolicy(rawValue: uncrop) else {
                            throw ToolError.invalidArguments("uncrop must be chromeTyping, anyTyping or never.")
                        }
                        patch.uncrop = policy
                    }
                    func bounded(_ value: Double?, _ name: String, _ range: ClosedRange<Double>) throws -> Double? {
                        guard let value else { return nil }
                        guard value.isFinite, range.contains(value) else {
                            throw ToolError.invalidArguments("\(name) must be in \(range.lowerBound)…\(range.upperBound).")
                        }
                        return value
                    }
                    patch.insetPx = try bounded(input.insetPx, "inset_px", 0...40)
                    patch.holdAfterTyping = try bounded(input.holdAfterTyping, "hold_after_typing", 0...10)
                    patch.holdAfterUIClick = try bounded(input.holdAfterUIClick, "hold_after_ui_click", 0...10)
                    patch.minDwell = try bounded(input.minDwell, "min_dwell", 0...10)
                    try applyCommand(.setCropSettings(patch), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<OptionsInput>(name: "cursor_set",
            description: "Set the cursor artwork pack, size, smoothing, glide and whether it keeps its size during zoom. Idempotent; returns the edit diff.",
            capability: .edit, required: ["project_id"], mutating: true,
            schema: OptionSchemas.cursor, idempotent: true,
            outputSchema: OptionSchemas.editResult, customDryRun: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID,
                    expectRevision: input.revision, describe: "cursor options") { timeline in
                    var cursor = timeline.cursor
                    if let pack = input.pack {
                        guard let parsed = CursorPack(rawValue: pack) else {
                            throw ToolError.invalidArguments("Unknown cursor pack \(pack).")
                        }
                        cursor.pack = parsed
                    }
                    func bounded(_ value: Double?, _ name: String, _ range: ClosedRange<Double>) throws -> Double? {
                        guard let value else { return nil }
                        guard value.isFinite, range.contains(value) else {
                            throw ToolError.invalidArguments("\(name) must be in \(range.lowerBound)…\(range.upperBound).")
                        }
                        return value
                    }
                    if let size = try bounded(input.size, "size", 0.25...4) { cursor.size = size }
                    if let smoothing = try bounded(input.smoothingSigma, "smoothing_sigma", 0...0.5) { cursor.smoothingSigma = smoothing }
                    if let glide = try bounded(input.glide, "glide", 0...2) { cursor.glide = glide }
                    if let constant = input.constantSize { cursor.constantSize = constant }
                    if let effect = input.clickEffect {
                        guard let parsed = ClickEffect(rawValue: effect) else {
                            throw ToolError.invalidArguments("Unknown click effect \(effect).")
                        }
                        cursor.clickEffect = parsed
                    }
                    try applyCommand(.setCursor(cursor), to: &timeline)
                }
                return .object(result)
            })
    }
}
