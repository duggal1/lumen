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
    }

    /// One action inside a step. The discriminator is `op`.
    public enum Action: Codable, Sendable, Equatable {
        case launch(Launch)
        case waitFor(WaitFor)
        case click(Click)
        case type(TypeText)
        case key(KeyPress)
        case sleep(Sleep)
        case move(Move)
        case scroll(Scroll)
        case screenshot(Screenshot)

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Operation.self, forKey: .op) {
            case .launch: self = .launch(try c.decode(Launch.self, forKey: .launch))
            case .waitFor: self = .waitFor(try c.decode(WaitFor.self, forKey: .waitFor))
            case .click: self = .click(try c.decode(Click.self, forKey: .click))
            case .type: self = .type(try c.decode(TypeText.self, forKey: .type))
            case .key: self = .key(try c.decode(KeyPress.self, forKey: .key))
            case .sleep: self = .sleep(try c.decode(Sleep.self, forKey: .sleep))
            case .move: self = .move(try c.decode(Move.self, forKey: .move))
            case .scroll: self = .scroll(try c.decode(Scroll.self, forKey: .scroll))
            case .screenshot: self = .screenshot(try c.decode(Screenshot.self, forKey: .screenshot))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .launch(let v): try c.encode(v, forKey: .launch); try c.encode(Operation.launch, forKey: .op)
            case .waitFor(let v): try c.encode(v, forKey: .waitFor); try c.encode(Operation.waitFor, forKey: .op)
            case .click(let v): try c.encode(v, forKey: .click); try c.encode(Operation.click, forKey: .op)
            case .type(let v): try c.encode(v, forKey: .type); try c.encode(Operation.type, forKey: .op)
            case .key(let v): try c.encode(v, forKey: .key); try c.encode(Operation.key, forKey: .op)
            case .sleep(let v): try c.encode(v, forKey: .sleep); try c.encode(Operation.sleep, forKey: .op)
            case .move(let v): try c.encode(v, forKey: .move); try c.encode(Operation.move, forKey: .op)
            case .scroll(let v): try c.encode(v, forKey: .scroll); try c.encode(Operation.scroll, forKey: .op)
            case .screenshot(let v): try c.encode(v, forKey: .screenshot); try c.encode(Operation.screenshot, forKey: .op)
            }
        }

        public enum Operation: String, Codable, Sendable {
            case launch, waitFor = "wait_for", click, type, key, sleep, move, scroll, screenshot
        }

        enum CodingKeys: String, CodingKey {
            case op, launch, waitFor = "wait_for", click, type, key, sleep, move, scroll, screenshot
        }
    }

    public struct Launch: Codable, Sendable, Equatable {
        public var bundleID: String?
        public var waitS: Double = 2
        public init() {}
    }
    public struct WaitFor: Codable, Sendable, Equatable {
        public var role: String?
        public var title: String?
        public var identifier: String?
        public var timeoutS: Double = 8
        public init() {}
    }
    public struct Click: Codable, Sendable, Equatable {
        public var target: TargetRef?
        /// Normalized position inside the target window (0...1).
        public var x: Double?
        public var y: Double?
        public var moveMs: Int = 600
        public init() {}
    }
    public struct TypeText: Codable, Sendable, Equatable {
        public var text: String = ""
        public var cps: Double = 9
        public init() {}
    }
    public struct KeyPress: Codable, Sendable, Equatable {
        public var key: String = ""
        public var modifiers: [String] = []
        public init() {}
    }
    public struct Sleep: Codable, Sendable, Equatable {
        public var seconds: Double = 1
        public init() {}
    }
    public struct Move: Codable, Sendable, Equatable {
        public var target: TargetRef?
        public var x: Double?
        public var y: Double?
        public var moveMs: Int = 600
        public init() {}
    }
    public struct Scroll: Codable, Sendable, Equatable {
        public var target: TargetRef?
        public var dy: Double = -3
        public init() {}
    }
    public struct Screenshot: Codable, Sendable, Equatable {
        public var path: String?
        public init() {}
    }
}

/// How an element is addressed.
public struct TargetRef: Codable, Sendable, Equatable {
    public var role: String?
    public var title: String?
    public var identifier: String?
    /// Which match to take when several elements match.
    public var index: Int = 0
    public init(role: String? = nil, title: String? = nil, identifier: String? = nil, index: Int = 0) {
        self.role = role; self.title = title; self.identifier = identifier; self.index = index
    }
}
