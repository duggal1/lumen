import Foundation
import LumenCore

/// Append-only binary log for browser viewport observations: `viewport.bin`.
/// Layout: `"LVP1"` magic + 48-byte little-endian records. Crash-safe because
/// the record count is derived from file size: `count = (size - 4) / 48`.
/// Ownership: `Writer` has one owner (the ViewportRecorder queue); `read` and
/// `truncateToWholeRecords` are pure free functions safe to call off that queue.
public enum ViewportLog {
    public static let magic = Data("LVP1".utf8)
    public static let stride = 48

    /// Single-owner writer. Call every method from one serial queue only.
    /// Threading: `@unchecked Sendable` solely so it can cross the actor/queue
    /// boundary at construction; it is never used concurrently after that.
    public final class Writer: @unchecked Sendable {
        private let handle: FileHandle
        private var pending = Data()

        public init(url: URL) throws {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: ViewportLog.magic)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }

        public func append(_ r: ViewportRecord) {
            var d = Data(capacity: ViewportLog.stride)
            func put<T: FixedWidthInteger>(_ v: T) {
                withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            }
            put(r.t.bitPattern)
            put(r.flags.rawValue)
            put(UInt32(0))                       // reserved: keeps the stride at 48
            for v in [r.window.x, r.window.y, r.window.w, r.window.h,
                      r.web.x, r.web.y, r.web.w, r.web.h] {
                put(Float(v).bitPattern.littleEndian)
            }
            pending.append(d)
        }

        public func flush(sync: Bool) {
            if !pending.isEmpty {
                try? handle.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
            if sync { try? handle.synchronize() }
        }

        public func close() {
            flush(sync: true)
            try? handle.close()
        }
    }

    /// Reads every whole record. A torn tail record from a crash is ignored.
    public static func read(_ url: URL) -> [ViewportRecord] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= magic.count, data.prefix(magic.count) == magic else { return [] }
        let n = (data.count - magic.count) / stride
        var out: [ViewportRecord] = []
        out.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = magic.count + i * stride
                func u32(_ off: Int) -> UInt32 {
                    UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + off, as: UInt32.self))
                }
                func u64(_ off: Int) -> UInt64 {
                    UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: o + off, as: UInt64.self))
                }
                func f(_ off: Int) -> Double { Double(Float(bitPattern: u32(off))) }
                out.append(ViewportRecord(
                    t: Double(bitPattern: u64(0)), flags: .init(rawValue: u32(8)),
                    window: PxRect(x: f(16), y: f(20), w: f(24), h: f(28)),
                    web: PxRect(x: f(32), y: f(36), w: f(40), h: f(44))))
            }
        }
        return out
    }

    /// Physically drops a torn tail record left by a crash. Idempotent; used at
    /// finalize and by bundle recovery so the file contains whole records only.
    public static func truncateToWholeRecords(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              data.count >= magic.count, data.prefix(magic.count) == magic else { return }
        let whole = magic.count + ((data.count - magic.count) / stride) * stride
        guard whole < data.count, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: UInt64(whole))
        try? handle.synchronize()
    }
}
