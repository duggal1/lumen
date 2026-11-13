import Foundation
import LumenCore

// MARK: - Demo script DSL
//
// The script is the source of truth; the video is a render of it. Every step
// writes a marker into the project so edits and audio can anchor to a moment
// instead of a magic second.

public struct DemoScript: Codable, Sendable, Equatable {
    public var version = 1
    public var app = Target()
    public var steps: [Step] = []
    public init(version: Int = 1, app: Target = Target(), steps: [Step] = []) {
        self.version = version; self.app = app; self.steps = steps
    }

    public struct Target: Codable, Sendable, Equatable {
        public var bundleID: String?
        public var name: String?
        public init(bundleID: String? = nil, name: String? = nil) {
            self.bundleID = bundleID; self.name = name
        }

        enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        }
}

    public struct Step: Codable, Sendable, Equatable {
        public var id: String = ""
        /// Narration for this step, in plain text.
        public var say: String?
        public var `do`: [Action] = []
        public var padAfterS: Double = 0
        public init(id: String = "", say: String? = nil, do actions: [Action] = [], padAfterS: Double = 0) {
            self.id = id; self.say = say; self.do = actions; self.padAfterS = padAfterS
        }

        enum CodingKeys: String, CodingKey {
            case id, say
            case `do` = "do"
            case padAfterS = "pad_after_s"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.say = try c.decodeIfPresent(String.self, forKey: .say)
        self.padAfterS = try c.decodeIfPresent(Double.self, forKey: .padAfterS) ?? 0
        }
}

    /// One action inside a step. The discriminator is `op`.
    public enum Action: Codable, Sendable, Equatable {
        case launch(Launch)
        case waitFor(WaitFor)
        case click(Click)
        case drag(Drag)
        case type(TypeText)
        case paste(Paste)
        case key(KeyPress)
        case sleep(Sleep)
        case move(Move)
        case scroll(Scroll)
        case screenshot(Screenshot)

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Operation.self, forKey: .op) {
            case .launch: self = .launch(try Launch(from: decoder))
            case .waitFor: self = .waitFor(try WaitFor(from: decoder))
            case .click: self = .click(try Click(from: decoder))
            case .drag: self = .drag(try Drag(from: decoder))
            case .type: self = .type(try TypeText(from: decoder))
            case .paste: self = .paste(try Paste(from: decoder))
            case .key: self = .key(try KeyPress(from: decoder))
            case .sleep: self = .sleep(try Sleep(from: decoder))
            case .move: self = .move(try Move(from: decoder))
            case .scroll: self = .scroll(try Scroll(from: decoder))
            case .screenshot: self = .screenshot(try Screenshot(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .launch(let v): try c.encode(v, forKey: .launch); try c.encode(Operation.launch, forKey: .op)
            case .waitFor(let v): try c.encode(v, forKey: .waitFor); try c.encode(Operation.waitFor, forKey: .op)
            case .click(let v): try c.encode(v, forKey: .click); try c.encode(Operation.click, forKey: .op)
            case .drag(let v): try c.encode(v, forKey: .drag); try c.encode(Operation.drag, forKey: .op)
            case .type(let v): try c.encode(v, forKey: .type); try c.encode(Operation.type, forKey: .op)
            case .paste(let v): try c.encode(v, forKey: .paste); try c.encode(Operation.paste, forKey: .op)
            case .key(let v): try c.encode(v, forKey: .key); try c.encode(Operation.key, forKey: .op)
            case .sleep(let v): try c.encode(v, forKey: .sleep); try c.encode(Operation.sleep, forKey: .op)
            case .move(let v): try c.encode(v, forKey: .move); try c.encode(Operation.move, forKey: .op)
            case .scroll(let v): try c.encode(v, forKey: .scroll); try c.encode(Operation.scroll, forKey: .op)
            case .screenshot(let v): try c.encode(v, forKey: .screenshot); try c.encode(Operation.screenshot, forKey: .op)
            }
        }

        public enum Operation: String, Codable, Sendable {
            case launch, waitFor = "wait_for", click, drag, type, paste, key, sleep, move, scroll, screenshot
        }

        enum CodingKeys: String, CodingKey {
            case op, launch, waitFor = "wait_for", click, drag, type, paste, key, sleep, move, scroll, screenshot
        }
    }

    public struct Launch: Codable, Sendable, Equatable {
        public var bundleID: String?
        public var waitS: Double = 2
        public init() {}

        enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case waitS = "wait_s"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        self.waitS = try c.decodeIfPresent(Double.self, forKey: .waitS) ?? 2
        }
}
    public struct WaitFor: Codable, Sendable, Equatable {
        public var role: String?
        public var title: String?
        public var identifier: String?
        public var timeoutS: Double = 8
        public init() {}

        enum CodingKeys: String, CodingKey {
        case role
        case title
        case identifier
        case timeoutS = "timeout_s"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        self.timeoutS = try c.decodeIfPresent(Double.self, forKey: .timeoutS) ?? 8
        }
}
    public struct Click: Codable, Sendable, Equatable {
        public var target: TargetRef?
        /// Normalized position inside the target window (0...1).
        public var x: Double?
        public var y: Double?
        public var moveMs: Int = 600
        /// "left" or "right".
        public var button: String?
        /// 1 for a click, 2 for a double click.
        public var count: Int = 1
        public init() {}

        enum CodingKeys: String, CodingKey {
        case target
        case x
        case y
        case moveMs = "move_ms"
        case button
        case count
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try c.decodeIfPresent(TargetRef.self, forKey: .target)
        self.x = try c.decodeIfPresent(Double.self, forKey: .x)
        self.y = try c.decodeIfPresent(Double.self, forKey: .y)
        self.moveMs = try c.decodeIfPresent(Int.self, forKey: .moveMs) ?? 600
        self.button = try c.decodeIfPresent(String.self, forKey: .button)
        self.count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        }
}
    public struct Drag: Codable, Sendable, Equatable {
        public var from: TargetRef?
        public var fromX: Double?
        public var fromY: Double?
        public var to: TargetRef?
        public var toX: Double?
        public var toY: Double?
        public var moveMs: Int = 600
        public init() {}

        enum CodingKeys: String, CodingKey {
        case from
        case fromX = "from_x"
        case fromY = "from_y"
        case to
        case toX = "to_x"
        case toY = "to_y"
        case moveMs = "move_ms"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try c.decodeIfPresent(TargetRef.self, forKey: .from)
        self.fromX = try c.decodeIfPresent(Double.self, forKey: .fromX)
        self.fromY = try c.decodeIfPresent(Double.self, forKey: .fromY)
        self.to = try c.decodeIfPresent(TargetRef.self, forKey: .to)
        self.toX = try c.decodeIfPresent(Double.self, forKey: .toX)
        self.toY = try c.decodeIfPresent(Double.self, forKey: .toY)
        self.moveMs = try c.decodeIfPresent(Int.self, forKey: .moveMs) ?? 600
        }
}
    public struct TypeText: Codable, Sendable, Equatable {
        public var text: String = ""
        public var cps: Double = 9
        public init() {}

        enum CodingKeys: String, CodingKey {
        case text
        case cps
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.cps = try c.decodeIfPresent(Double.self, forKey: .cps) ?? 9
        }
}
    public struct Paste: Codable, Sendable, Equatable {
        public var text: String = ""
        public init() {}

        enum CodingKeys: String, CodingKey {
        case text
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        }
}
    public struct KeyPress: Codable, Sendable, Equatable {
        public var key: String = ""
        public var modifiers: [String] = []
        public init() {}

        enum CodingKeys: String, CodingKey {
        case key
        case modifiers
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        }
}
    public struct Sleep: Codable, Sendable, Equatable {
        public var seconds: Double = 1
        public init() {}

        enum CodingKeys: String, CodingKey {
        case seconds
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 1
        }
}
    public struct Move: Codable, Sendable, Equatable {
        public var target: TargetRef?
        public var x: Double?
        public var y: Double?
        public var moveMs: Int = 600
        public init() {}

        enum CodingKeys: String, CodingKey {
        case target
        case x
        case y
        case moveMs = "move_ms"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try c.decodeIfPresent(TargetRef.self, forKey: .target)
        self.x = try c.decodeIfPresent(Double.self, forKey: .x)
        self.y = try c.decodeIfPresent(Double.self, forKey: .y)
        self.moveMs = try c.decodeIfPresent(Int.self, forKey: .moveMs) ?? 600
        }
}
    public struct Scroll: Codable, Sendable, Equatable {
        public var target: TargetRef?
        /// Wheel lines; negative scrolls down, matching a trackpad.
        public var dy: Double = -3
        public init() {}

        enum CodingKeys: String, CodingKey {
        case target
        case dy
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try c.decodeIfPresent(TargetRef.self, forKey: .target)
        self.dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? -3
        }
}
    public struct Screenshot: Codable, Sendable, Equatable {
        public var path: String?
        public init() {}

        enum CodingKeys: String, CodingKey {
        case path
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        }
}
}

/// How an element is addressed.
public struct TargetRef: Codable, Sendable, Equatable {
    public var ref: String?
    public var role: String?
    public var title: String?
    public var identifier: String?
    /// Which match to take when several elements match.
    public var index: Int = 0
    public init(role: String? = nil, title: String? = nil, identifier: String? = nil, index: Int = 0, ref: String? = nil) {
        self.ref = ref; self.role = role; self.title = title; self.identifier = identifier; self.index = index
    }

    enum CodingKeys: String, CodingKey {
    case ref
    case role
    case title
    case identifier
    case index
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.ref = try c.decodeIfPresent(String.self, forKey: .ref)
    self.role = try c.decodeIfPresent(String.self, forKey: .role)
    self.title = try c.decodeIfPresent(String.self, forKey: .title)
    self.identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    self.index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
    }
}
