import Foundation
#if canImport(CMoonshine)
import CMoonshine
#endif

public enum SpeechError: Error, Sendable, CustomStringConvertible {
    case notInstalled, modelMissing(String), load(Int32), stream(Int32), audio(String)
    public var description: String {
        switch self {
        case .notInstalled: "The Moonshine runtime is not vendored in this build."
        case .modelMissing(let p): "No Moonshine model files found in \(p)."
        case .load(let c): "Moonshine could not load the model (code \(c))."
        case .stream(let c): "Moonshine stream error (code \(c))."
        case .audio(let m): m
        }
    }
}

public enum MoonshineSize: String, Codable, CaseIterable, Sendable {
    case tiny, small, medium
    public static let defaultsKey = "lumen.moonshine.size"
    public var title: String { switch self { case .tiny: "Tiny"; case .small: "Small"; case .medium: "Medium" } }
    public var detail: String {
        switch self { case .tiny: "34M parameters · fastest · 12.0% WER"; case .small: "123M parameters · 7.8% WER"; case .medium: "Most accurate · slowest" }
    }
    public var folder: String { "moonshine-streaming-\(rawValue)" }
    public static var current: MoonshineSize {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(MoonshineSize.init) ?? .tiny }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// One transcript line as the runtime reported it. Text is copied out immediately (the library owns the transcript memory).
struct RawLine: Sendable { var id: UInt64; var text: String; var start: Double; var duration: Double; var complete: Bool }

#if canImport(CMoonshine)
/// Owns the loaded model. Thread-safe to share; one stream at a time per worker.
public final class MoonshineRuntime: @unchecked Sendable {
    public static var isAvailable: Bool { true }
    let handle: Int32
    public let size: MoonshineSize
    public init(directory: URL, size: MoonshineSize) throws {
        let arch: UInt32
        switch size {
        case .tiny: arch = UInt32(MOONSHINE_MODEL_ARCH_TINY_STREAMING)
        case .small: arch = UInt32(MOONSHINE_MODEL_ARCH_SMALL_STREAMING)
        case .medium: arch = UInt32(MOONSHINE_MODEL_ARCH_MEDIUM_STREAMING)
        }
        let h = directory.path.withCString {
            moonshine_load_transcriber_from_files($0, arch, nil, 0, Int32(MOONSHINE_HEADER_VERSION))
        }
        guard h >= 0 else { throw SpeechError.load(h) }
        handle = h; self.size = size
    }
    deinit { moonshine_free_transcriber(handle) }
}

/// Confined to one thread. Audio in is 16 kHz mono Float32.
final class MoonshineStream {
    private let rt: MoonshineRuntime
    private let h: Int32
    private var stopped = false
    init(_ rt: MoonshineRuntime) throws {
        let s = moonshine_create_stream(rt.handle, 0)
        guard s >= 0 else { throw SpeechError.stream(s) }
        let r = moonshine_start_stream(rt.handle, s)
        guard r >= 0 else { _ = moonshine_free_stream(rt.handle, s); throw SpeechError.stream(r) }
        self.rt = rt; h = s
    }
    deinit {
        if !stopped { _ = moonshine_stop_stream(rt.handle, h) }
        _ = moonshine_free_stream(rt.handle, h)
    }
    func add(_ p: UnsafePointer<Float>, _ n: Int) throws {
        let r = moonshine_transcribe_add_audio_to_stream(rt.handle, h, p, UInt64(n), 16_000, 0)
        guard r >= 0 else { throw SpeechError.stream(r) }
    }
    func poll(force: Bool) throws -> [RawLine] {
        var out: UnsafeMutablePointer<transcript_t>? = nil
        let r = moonshine_transcribe_stream(rt.handle, h, force ? UInt32(MOONSHINE_FLAG_FORCE_UPDATE) : 0, &out)
        guard r >= 0 else { throw SpeechError.stream(r) }
        guard let t = out?.pointee, let base = t.lines else { return [] }
        var res: [RawLine] = []
        res.reserveCapacity(Int(t.line_count))
        for i in 0..<Int(t.line_count) {
            let l = base[i]
            guard let c = l.text else { continue }
            res.append(RawLine(id: l.id, text: String(cString: c), start: Double(l.start_time), duration: Double(l.duration),
                               complete: l.is_complete != 0))
        }
        return res
    }
    /// Ends the stream and returns the last lines (the open line is completed).
    func finish() throws -> [RawLine] {
        if !stopped { stopped = true; _ = moonshine_stop_stream(rt.handle, h) }
        return try poll(force: true)
    }
}
#else
public final class MoonshineRuntime: @unchecked Sendable {
    public static var isAvailable: Bool { false }
    public let size: MoonshineSize
    public init(directory: URL, size: MoonshineSize) throws { throw SpeechError.notInstalled }
}
final class MoonshineStream {
    init(_ rt: MoonshineRuntime) throws { throw SpeechError.notInstalled }
    func add(_ p: UnsafePointer<Float>, _ n: Int) throws { throw SpeechError.notInstalled }
    func poll(force: Bool) throws -> [RawLine] { throw SpeechError.notInstalled }
    func finish() throws -> [RawLine] { throw SpeechError.notInstalled }
}
#endif
