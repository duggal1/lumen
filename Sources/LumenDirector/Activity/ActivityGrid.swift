import Foundation

/// Grid geometry shared by the analyzer and the shot builder. Value type, thread-safe.
public enum ActivityConst {
    public static let gw = 48
    public static let gh = 27
    public static let cells = gw * gh
}

/// One 10 Hz energy sample: `gw * gh` bytes, row-major, top-left origin, source time in seconds.
/// Pure value type owned by Analysis, consumed by the Director; safe to share across tasks.
public struct ActivityGrid: Codable, Sendable, Equatable {
    public var t: Double
    public var cells: [UInt8]

    public init(t: Double, cells: [UInt8]) {
        self.t = t; self.cells = cells
    }
}
