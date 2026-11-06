import Foundation
import Synchronization
import LumenProject

final class CancelFlag: Sendable {
    private let f = Atomic<Bool>(false)
    func cancel() { f.store(true, ordering: .releasing) }
    var isCancelled: Bool { f.load(ordering: .acquiring) }
}

/// Streams a file through the same core as live mode, as fast as the CPU allows, in 2 s chunks. Memory is flat for any length.
/// Result is in the file's own time (mic-file time).
public enum FileTranscriber {
    public static func run(url: URL, size: MoonshineSize = .current,
                           progress: (@Sendable (Double) -> Void)? = nil) async -> Result<Transcript, SpeechError> {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Result<Transcript, SpeechError>, Never>) in
                let t = Thread { c.resume(returning: process(url, size, progress, flag)) }
                t.name = "lumen.moonshine.file"; t.qualityOfService = .utility; t.stackSize = 8 << 20
                t.start()
            }
        } onCancel: { flag.cancel() }
    }

    private static func process(_ url: URL, _ size: MoonshineSize, _ progress: (@Sendable (Double) -> Void)?,
                                _ flag: CancelFlag) -> Result<Transcript, SpeechError> {
        do {
            let rt = try RuntimeCache.shared.acquire(size)
            defer { RuntimeCache.shared.release() }
            let reader = try AudioChunkReader(url: url)
            var rs = StreamResampler(from: reader.sampleRate, to: 16_000)
            let core = try TranscribeCore(runtime: rt)
            var mono = [Float](), out16 = [Float]()
            var lastP = 0.0
            while try reader.next(into: &mono) {
                if flag.isCancelled { return .failure(.audio("Cancelled.")) }
                out16.removeAll(keepingCapacity: true)
                mono.withUnsafeBufferPointer { rs.process($0, into: &out16) }
                try out16.withUnsafeBufferPointer { try core.feed($0) }
                try core.poll()
                try core.rotateIfQuiet()
                let p = Double(reader.position) / Double(max(reader.totalFrames, 1))
                if p - lastP >= 0.01 { progress?(p); lastP = p }
            }
            let words = try core.finish()
            progress?(1)
            return .success(Transcript(words: words, locale: "en-US"))
        } catch let e as SpeechError { return .failure(e) }
        catch { return .failure(.audio("\(error)")) }
    }
}
