import Foundation

public let gridRate: Double = 1440

public func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
public func smoothstep(_ x: Double) -> Double { let t = clamp(x, 0, 1); return t * t * (3 - 2 * t) }

/// Exact critically damped step, stable at any dt. Pure function.
public func springStep(_ x: inout Double, _ v: inout Double, target: Double, omega w: Double, dt: Double) {
    let d = x - target, e = exp(-w * dt)
    let nx = target + (d + (v + w * d) * dt) * e
    v = (v - w * (v + w * d) * dt) * e
    x = nx
}

/// Three independent critically damped springs. Value type.
public struct Spring3: Sendable {
    public var x: SIMD3<Double>, v: SIMD3<Double> = .zero
    public init(x: SIMD3<Double>) { self.x = x }
    public mutating func step(target: SIMD3<Double>, omega: SIMD3<Double>, dt: Double) {
        for i in 0..<3 { springStep(&x[i], &v[i], target: target[i], omega: omega[i], dt: dt) }
    }
}

private func endSlope(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
    var s = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
    if s * d0 <= 0 { s = 0 } else if d0 * d1 <= 0 && abs(s) > 3 * abs(d0) { s = 3 * d0 }
    return s
}

/// Monotone cubic (PCHIP) resample of (t, y) onto a uniform grid. No overshoot. `t` must be strictly increasing.
public func pchipResample(t: [Double], y: [Double], t0: Double, count: Int, rate: Double) -> [Double] {
    let n = t.count
    guard n > 0 else { return [Double](repeating: 0, count: count) }
    if n == 1 { return [Double](repeating: y[0], count: count) }
    var h = [Double](repeating: 0, count: n - 1), del = h
    for k in 0..<(n - 1) { h[k] = t[k + 1] - t[k]; del[k] = (y[k + 1] - y[k]) / h[k] }
    var m = [Double](repeating: 0, count: n)
    if n == 2 { m = [del[0], del[0]] } else {
        for k in 1..<(n - 1) where del[k - 1] * del[k] > 0 {
            let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
            m[k] = (w1 + w2) / (w1 / del[k - 1] + w2 / del[k])
        }
        m[0] = endSlope(h[0], h[1], del[0], del[1])
        m[n - 1] = endSlope(h[n - 2], h[n - 3], del[n - 2], del[n - 3])
    }
    var out = [Double](repeating: 0, count: count); var k = 0
    for i in 0..<count {
        let x = t0 + Double(i) / rate
        if x <= t[0] { out[i] = y[0]; continue }
        if x >= t[n - 1] { out[i] = y[n - 1]; continue }
        while k < n - 2 && t[k + 1] < x { k += 1 }
        let s = (x - t[k]) / h[k], s2 = s * s, s3 = s2 * s
        out[i] = (2 * s3 - 3 * s2 + 1) * y[k] + (s3 - 2 * s2 + s) * h[k] * m[k] + (-2 * s3 + 3 * s2) * y[k + 1] + (s3 - s2) * h[k] * m[k + 1]
    }
    return out
}

public func median5(_ a: [Double]) -> [Double] {
    guard a.count > 4 else { return a }
    var o = a
    for i in 2..<(a.count - 2) { var w = [a[i - 2], a[i - 1], a[i], a[i + 1], a[i + 2]]; w.sort(); o[i] = w[2] }
    return o
}

/// Non-causal (zero-lag) Gaussian smoothing, sigma in samples, edge-clamped.
public func gaussianSmooth(_ a: [Double], sigma: Double) -> [Double] {
    guard sigma > 0.3, a.count > 1 else { return a }
    let r = Int(ceil(3 * sigma)), n = a.count
    var k = (-r...r).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
    let s = k.reduce(0, +); k = k.map { $0 / s }
    var out = [Double](repeating: 0, count: n)
    a.withUnsafeBufferPointer { ap in
        out.withUnsafeMutableBufferPointer { op in
            for i in 0..<n {
                var acc = 0.0
                for j in -r...r { acc += k[j + r] * ap[min(max(i + j, 0), n - 1)] }
                op[i] = acc
            }
        }
    }
    return out
}

// MARK: Clock

public enum HostClock {
    private static let tb: mach_timebase_info_data_t = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return i }()
    public static func seconds(machTicks t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 }
    public static func now() -> Double { seconds(machTicks: mach_absolute_time()) }
}

public enum EventTimeUnit: String, Codable, Sendable { case machTicks, nanoseconds }

/// Shared host-time origin. Value type. All stored times are absolute host seconds; subtract `originHostSeconds` to rebase.
public struct RecordingClock: Codable, Sendable {
    public var originHostSeconds: Double
    public var eventUnit: EventTimeUnit
    public init(originHostSeconds: Double = 0, eventUnit: EventTimeUnit = .machTicks) {
        self.originHostSeconds = originHostSeconds; self.eventUnit = eventUnit
    }
    public func hostSeconds(eventTimestamp ts: UInt64) -> Double {
        eventUnit == .machTicks ? HostClock.seconds(machTicks: ts) : Double(ts) / 1e9
    }
}

// MARK: Input events (32-byte little-endian records)

public struct InputEvent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case move, down, up, drag, scroll, keyDown, keyUp, flagsChanged }
    public var t: Double
    public var kind: Kind
    public var x: Float, y: Float
    public var button: UInt8
    public var keyCode: UInt16
    public var flags: UInt16
    public var cursorShape: UInt16
    public var axFrameIndex: UInt32
    /// Signed wheel delta in lines for `.scroll` events (positive = up).
    /// Previously discarded at capture, so scroll smoothing was impossible.
    public var scrollDelta: Float
    public init(t: Double = 0, kind: Kind = .move, x: Float = 0, y: Float = 0, button: UInt8 = 0, keyCode: UInt16 = 0,
                flags: UInt16 = 0, cursorShape: UInt16 = 0, axFrameIndex: UInt32 = 0, scrollDelta: Float = 0) {
        self.t = t; self.kind = kind; self.x = x; self.y = y; self.button = button; self.keyCode = keyCode
        self.flags = flags; self.cursorShape = cursorShape; self.axFrameIndex = axFrameIndex
        self.scrollDelta = scrollDelta
    }
    public var hasPosition: Bool {
        switch kind { case .move, .down, .up, .drag, .scroll: true; default: false }
    }
}

public enum StockCursor: UInt16, CaseIterable, Sendable {
    case arrow, iBeam, pointingHand, crosshair, openHand, closedHand, resizeLeftRight, resizeUpDown, notAllowed, contextMenu
}

public enum EventCodec {
    public static let recordSize = 32, headerSize = 16
    public static func header() -> Data {
        var b: [UInt8] = Array("LMNE".utf8); b += [1, 0, 0, 0]; b += [UInt8](repeating: 0, count: 8); return Data(b)
    }
    public static func encode(_ e: InputEvent, into b: inout [UInt8]) {
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        put(e.t.bitPattern); put(e.x.bitPattern); put(e.y.bitPattern); put(e.axFrameIndex)
        put(e.keyCode); put(e.flags); put(e.cursorShape); put(e.kind.rawValue); put(e.button); put(e.scrollDelta.bitPattern)
    }
    public static func decode(_ d: Data) -> [InputEvent] {
        guard d.count >= headerSize else { return [] }
        let n = (d.count - headerSize) / recordSize
        var out = [InputEvent](); out.reserveCapacity(n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = headerSize + i * recordSize
                func u64(_ k: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: o + k, as: UInt64.self)) }
                func u32(_ k: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + k, as: UInt32.self)) }
                func u16(_ k: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + k, as: UInt16.self)) }
                func u8(_ k: Int) -> UInt8 { raw.loadUnaligned(fromByteOffset: o + k, as: UInt8.self) }
                out.append(InputEvent(t: Double(bitPattern: u64(0)), kind: .init(rawValue: u8(26)) ?? .move,
                                      x: Float(bitPattern: u32(8)), y: Float(bitPattern: u32(12)), button: u8(27),
                                      keyCode: u16(20), flags: u16(22), cursorShape: u16(24), axFrameIndex: u32(16),
                                      scrollDelta: Float(bitPattern: u32(28))))
            }
        }
        return out
    }
}