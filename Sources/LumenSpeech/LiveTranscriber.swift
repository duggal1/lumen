import Foundation
import os
import Synchronization
import LumenCore
import LumenProject

public enum LiveState: Sendable, Equatable { case idle, loading, listening, degraded(String), failed(String), notInstalled }
public struct LiveUpdate: Sendable, Equatable {
    public var lines: [LiveLine]
    public var lagMs: Double          // host time between the newest audio fed to the model and the moment its text was published
    public var state: LiveState
}
/// `transcript` is in MIC-FILE time (seconds from the first sample of mic.caf).
public struct LiveResult: Sendable { public var transcript: Transcript; public var complete: Bool; public var engine: String }

final class OneShot<T: Sendable>: @unchecked Sendable {
    private let s = OSAllocatedUnfairLock<(value: T?, cont: CheckedContinuation<T, Never>?)>(uncheckedState: (nil, nil))
    func fulfill(_ v: T) {
        let c = s.withLock { st -> CheckedContinuation<T, Never>? in st.value = v; let c = st.cont; st.cont = nil; return c }
        c?.resume(returning: v)
    }
    func wait() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let v = s.withLock { st -> T? in if let v = st.value { return v }; st.cont = c; return nil }
            if let v { c.resume(returning: v) }
        }
    }
}

/// Live transcription of the microphone while recording. `push` is the only call made from the capture queue.
public final class LiveTranscriber: @unchecked Sendable {
    private struct Meta: Sendable { var rate = 0.0; var firstHost: Double? }
    public let updates: AsyncStream<LiveUpdate>
    public let size: MoonshineSize
    private let feed: AsyncStream<LiveUpdate>.Continuation
    private let ring = FloatRing(capacity: 48_000 * 8)
    private let stop = Atomic<Bool>(false)
    private let meta = OSAllocatedUnfairLock(initialState: Meta())
    private let started = OSAllocatedUnfairLock(initialState: false)
    private let done = OneShot<LiveResult>()

    public init(size: MoonshineSize = .current) {
        self.size = size
        let (s, c) = AsyncStream.makeStream(of: LiveUpdate.self, bufferingPolicy: .bufferingNewest(1))
        updates = s; feed = c
    }

    /// Call from the audio queue. No allocation, no waiting.
    public func push(_ p: UnsafePointer<Float>, _ n: Int, rate r: Double, hostSeconds h: Double) {
        guard n > 0, !stop.load(ordering: .relaxed) else { return }
        let ok = meta.withLock { m -> Bool in
            if m.rate == 0 { m.rate = r; m.firstHost = h }
            return abs(m.rate - r) < 1
        }
        guard ok else { ring.noteLoss(n); return }          // the device changed sample rate mid-take
        ring.push(p, n)
    }

    /// Starts the worker (loads the model on it). Safe to call before the countdown: audio waits in the ring.
    public func start() {
        guard started.withLock({ s -> Bool in if s { return false }; s = true; return true }) else { return }
        let t = Thread { [self] in run() }
        t.name = "lumen.moonshine"; t.qualityOfService = .utility; t.stackSize = 8 << 20
        t.start()
    }

    public func cancel() { stop.store(true, ordering: .releasing) }

    public func finish() async -> LiveResult {
        stop.store(true, ordering: .releasing)
        guard started.withLock({ $0 }) else { return LiveResult(transcript: Transcript(words: [], locale: "en-US"), complete: false, engine: engine) }
        return await done.wait()
    }

    private var engine: String { "moonshine-streaming-\(size.rawValue)" }

    private static func thermalScale() -> Double {
        switch ProcessInfo.processInfo.thermalState { case .serious: 2; case .critical: 4; default: 1 }
    }

    private func bail(_ s: LiveState) {
        feed.yield(LiveUpdate(lines: [], lagMs: 0, state: s))
        done.fulfill(LiveResult(transcript: Transcript(words: [], locale: "en-US"), complete: false, engine: engine))
        feed.finish()
    }

    private func run() {
        feed.yield(LiveUpdate(lines: [], lagMs: 0, state: .loading))
        let rt: MoonshineRuntime
        do { rt = try RuntimeCache.shared.acquire(size) }
        catch let e as SpeechError {
            switch e { case .notInstalled, .modelMissing: return bail(.notInstalled); default: return bail(.failed(e.description)) }
        } catch { return bail(.failed("\(error)")) }
        defer { RuntimeCache.shared.release() }
        let core: TranscribeCore
        do { core = try TranscribeCore(runtime: rt) } catch { return bail(.failed("\(error)")) }
        feed.yield(LiveUpdate(lines: [], lagMs: 0, state: .listening))

        var rs: StreamResampler?
        var inBuf = [Float](repeating: 0, count: 48_000), out16 = [Float]()
        out16.reserveCapacity(48_000)
        var consumed = 0
        var cost = 0.04, lastPoll = 0.0, lastText = HostClock.now(), fedSincePoll = false
        var thermal = 1.0, thermalAt = 0.0
        var lastState = LiveState.listening, failed = false

        loop: while true {
            let stopping = stop.load(ordering: .acquiring)
            let m = meta.withLock { $0 }
            while true {                                     // drain everything that arrived
                let n = inBuf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, max: $0.count) }
                if n == 0 { break }
                if rs == nil, m.rate > 0 { rs = StreamResampler(from: m.rate, to: 16_000) }
                out16.removeAll(keepingCapacity: true)
                inBuf.withUnsafeBufferPointer { b in rs?.process(UnsafeBufferPointer(rebasing: b[0..<n]), into: &out16) }
                do { try out16.withUnsafeBufferPointer { try core.feed($0) } } catch { failed = true; break loop }
                consumed += n; fedSincePoll = true
            }
            let now = HostClock.now()
            if now - thermalAt > 1 { thermalAt = now; thermal = Self.thermalScale() }
            let interval = min(max(cost / 0.2, 0.12), 0.5) * thermal           // keeps the worker near 20% of one core
            let wantPoll = !stopping && fedSincePoll && now - lastPoll >= interval
                && (core.env.activeNow() || now - lastText < 1.5 || now - lastPoll >= 0.6)   // silence: skip polls, keep feeding
            if wantPoll {
                let t0 = HostClock.now()
                do {
                    let changed = try core.poll()
                    let t1 = HostClock.now()
                    cost = 0.8 * cost + 0.2 * (t1 - t0)
                    lastPoll = t1; fedSincePoll = false
                    if changed { lastText = t1 }
                    try core.rotateIfQuiet()
                    let st: LiveState = ring.droppedSamples > 0
                        ? .degraded("Some audio was dropped. Lumen will re-transcribe from the recording.") : .listening
                    if changed || st != lastState {
                        lastState = st
                        let fedHost = (m.firstHost ?? t1) + Double(consumed) / max(m.rate, 1)
                        feed.yield(LiveUpdate(lines: core.visible(3), lagMs: max(0, t1 - fedHost) * 1000, state: st))
                    }
                } catch { failed = true; break loop }
            }
            if stopping { break }
            Thread.sleep(forTimeInterval: 0.04)
        }

        var words = core.finalWords
        if !failed { do { words = try core.finish() } catch { failed = true } }
        feed.yield(LiveUpdate(lines: core.visible(3), lagMs: 0, state: failed ? .failed("Live transcription stopped early.") : lastState))
        done.fulfill(LiveResult(transcript: Transcript(words: words, locale: "en-US"),
                                complete: !failed && ring.droppedSamples == 0, engine: engine))
        feed.finish()
    }
}
