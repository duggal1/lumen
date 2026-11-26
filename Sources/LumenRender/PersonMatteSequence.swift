import Foundation
import Metal
import LumenProject

/// Reads the real Vision-generated LUMASK1 person matte format. Only a few
/// matte frames are resident (a rolling buffer), not the entire recording.
/// The source timestamps in the file already include the webcam track offset.
final class PersonMatteSequence: @unchecked Sendable {
    struct Pair {
        let previous: MTLTexture
        let next: MTLTexture
        let fraction: Float
    }

    let url: URL
    let info: PersonMaskInfo
    private let file: FileHandle
    private let times: [Double]
    private let frameBytes: Int
    private let stride: Int
    /// All file reads and texture writes run on this serial queue so the
    /// render thread never blocks in `FileHandle.read` or `MTLTexture.replace`
    /// (synchronous driver calls on the matte path).
    private let work = DispatchQueue(label: "lumen.personmatte", qos: .utility)
    private let lock = NSLock()
    private var rolling: [Int: MTLTexture] = [:]
    private var rollingOrder: [Int] = []
    private let rollingCap = 4
    private var last: (a: Int, b: Int, f: Float, pair: Pair)?

    init?(url: URL, info: PersonMaskInfo) {
        guard info.width > 0, info.height > 0, info.fps > 0, info.frames > 0,
              let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        guard let h = try? fh.read(upToCount: 16), h.count == 16,
              Array(h.prefix(8)) == [0x4c, 0x55, 0x4d, 0x41, 0x53, 0x4b, 0x31, 0],
              Self.uint32(h, 8) == UInt32(info.width),
              Self.uint32(h, 12) == UInt32(info.height) else {
            try? fh.close(); return nil
        }
        let bytes = info.width * info.height, stride = bytes + 8
        guard let size = try? fh.seekToEnd(), size >= UInt64(16 + stride * info.frames) else {
            try? fh.close(); return nil
        }
        var stamps: [Double] = []
        stamps.reserveCapacity(info.frames)
        for i in 0..<info.frames {
            guard (try? fh.seek(toOffset: UInt64(16 + i * stride))) != nil,
                  let data = try? fh.read(upToCount: 8), data.count == 8 else {
                try? fh.close(); return nil
            }
            let t = Double(bitPattern: Self.uint64(data))
            guard t.isFinite && (stamps.last == nil || t >= stamps.last!) else {
                try? fh.close(); return nil
            }
            stamps.append(t)
        }
        self.url = url
        self.info = info
        self.file = fh
        self.times = stamps
        self.frameBytes = bytes
        self.stride = stride
    }

    deinit { try? file.close() }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for j in 0..<4 { v |= UInt32(data[data.startIndex + offset + j]) << (8 * j) }
        return v
    }

    private static func uint64(_ data: Data) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(data[data.startIndex + j]) << (8 * j) }
        return v
    }

    /// Find bracketing timestamp samples. Missing or stale masks are never
    /// reused across long video gaps; render a conventional webcam instead.
    func indices(at time: Double) -> (Int, Int, Float)? {
        guard time.isFinite, !times.isEmpty else { return nil }
        let maximumStaleness = max(2.5 / info.fps, 0.10)
        if time < times[0] {
            return times[0] - time <= maximumStaleness ? (0, 0, 0) : nil
        }
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        let a = max(0, lo - 1), b = min(times.count - 1, lo)
        guard time - times[a] <= maximumStaleness else { return nil }
        if a == b || times[b] - times[a] > maximumStaleness * 2 { return (a, a, 0) }
        let f = Float(min(max((time - times[a]) / max(times[b] - times[a], 0.000001), 0), 1))
        return (a, b, f)
    }

    /// Reads one matte frame. Rolling-buffer hits are instant; misses read a
    /// fresh `FileHandle` (the render thread and the serial queue must not
    /// share a file).
    private func readTexture(frame: Int, device: MTLDevice) -> MTLTexture? {
        lock.lock()
        if let t = rolling[frame] { lock.unlock(); return t }
        lock.unlock()
        guard let fh = try? FileHandle(forReadingFrom: url),
              (try? fh.seek(toOffset: UInt64(16 + frame * stride + 8))) != nil,
              let raw = try? fh.read(upToCount: frameBytes), raw.count == frameBytes else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: info.width,
                                                            height: info.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let texture = device.makeTexture(descriptor: desc)
        raw.withUnsafeBytes { bytes in
            if let pointer = bytes.baseAddress {
                texture?.replace(region: MTLRegionMake2D(0, 0, info.width, info.height),
                                 mipmapLevel: 0, withBytes: pointer, bytesPerRow: info.width)
            }
        }
        try? fh.close()
        return texture
    }

    func sample(at t: Double, slot: Int, device: MTLDevice) -> Pair? {
        guard let (a, b, fraction) = indices(at: t) else { return nil }
        // 1. Serve from the serial queue's rolling buffer: matte ticks are far
        //    slower than preview frames, so the pair is normally already there.
        lock.lock()
        if let p = last, p.a == a, p.b == b, p.2 == fraction { lock.unlock(); return p.pair }
        lock.unlock()
        // 2. Ask the serial queue to keep this pair rolling.
        work.async { [weak self] in
            guard let self, let first = readTexture(frame: a, device: device) else { return }
            let second = a == b ? first : readTexture(frame: b, device: device)
            lock.lock()
            if second != nil || a == b {
                rolling[a] = first
                rollingOrder.append(a)
                if a != b, let second {
                    rolling[b] = second
                    rollingOrder.append(b)
                }
                while rollingOrder.count > rollingCap { rolling.removeValue(forKey: rollingOrder.removeFirst()) }
                last = (a, b, fraction, Pair(previous: first, next: second ?? first, fraction: fraction))
            }
            lock.unlock()
        }
        // 3. Rare: the pair is not ready yet. Read inline so the matte does
        //    not vanish on the tick that moved it — identical to the old
        //    synchronous behavior, now only paid when the matte advances.
        if let first = readTexture(frame: a, device: device) {
            let second = a == b ? first : readTexture(frame: b, device: device)
            let pair = Pair(previous: first, next: second ?? first, fraction: fraction)
            lock.lock()
            if last?.a != a || last?.b != b || last?.2 != fraction { last = (a, b, fraction, pair) }
            lock.unlock()
            return pair
        }
        return nil
    }
}
