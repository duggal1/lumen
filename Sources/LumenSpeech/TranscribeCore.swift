import Foundation
import LumenCore
import LumenProject

/// Stream + line bookkeeping. Confined to ONE thread. A line's words are emitted
/// once the runtime completes it, so live and file pacing share this core.
final class TranscribeCore {
    private struct State { var words: [String] = [] }
    private let runtime: MoonshineRuntime
    private var stream: MoonshineStream
    private var gen: UInt64 = 0
    private var base = 0.0                                  // absolute stream time at which the current stream began
    private var states: [UInt64: State] = [:]
    private var order: [UInt64] = []
    private var done = Set<UInt64>()                        // lines already emitted as final (cleared on rotation)
    private var finalsInStream = 0
    private(set) var env = EnergyTrack()
    private(set) var finalWords: [WordToken] = []
    private(set) var fedSamples = 0

    init(runtime: MoonshineRuntime) throws { self.runtime = runtime; stream = try MoonshineStream(runtime) }

    var seconds: Double { Double(fedSamples) / 16_000 }

    func feed(_ x: UnsafeBufferPointer<Float>) throws {
        guard let p = x.baseAddress, !x.isEmpty else { return }
        env.add(x)
        try stream.add(p, x.count)
        fedSamples += x.count
    }

    @discardableResult func poll() throws -> Bool { ingest(try stream.poll(force: true)) }

    @discardableResult
    func ingest(_ raw: [RawLine]) -> Bool {
        var changed = false
        for r in raw {
            let key = (gen << 40) | (r.id & 0xFF_FFFF_FFFF)
            if done.contains(key) { continue }
            let words = WordAligner.split(r.text)
            var st = states[key] ?? State()
            if states[key] == nil { order.append(key) }
            if st.words != words { st.words = words; changed = true }
            if r.complete {
                let dur = r.duration > 0.05 ? r.duration : Double(words.count) * 0.33
                finalWords += WordAligner.align(words: words, start: base + r.start, end: base + r.start + dur, env: env)
                done.insert(key); finalsInStream += 1; changed = true
            }
            states[key] = st
        }
        while order.count > 8, let k = order.first, done.contains(k) || states[k] == nil {
            order.removeFirst(); states.removeValue(forKey: k)
        }
        return changed
    }

    /// Long takes: after 30 final lines and 1 s of quiet, restart the stream so per-poll work and library memory stay bounded.
    @discardableResult
    func rotateIfQuiet() throws -> Bool {
        guard finalsInStream >= 30, env.quietSeconds() >= 1.0 else { return false }
        ingest(try stream.finish())
        base = seconds
        stream = try MoonshineStream(runtime)
        gen += 1; done.removeAll(); finalsInStream = 0
        return true
    }

    func finish() throws -> [WordToken] {
        ingest(try stream.finish())
        return finalWords
    }
}
