import Foundation
import AVFoundation
import Accelerate

/// Stereo 48 kHz Float32 music bed. Value type.
public struct MusicTrack: Sendable {
    public var l: [Float], r: [Float]
    public init(l: [Float], r: [Float]) { self.l = l; self.r = r }
}

public enum AudioIOError: Error { case unreadable(String) }

/// Hands a one-shot buffer to AVAudioConverter's input block.
private final class OnceBox: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    init(_ b: AVAudioPCMBuffer) { buffer = b }
}

public enum AudioIO {
    public static let fs = 48000.0
    static var stereoFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: false)!
    }

    /// Decodes only the first `seconds` of a file and downmixes it to mono at
    /// 48 kHz. Studio's first audible window must not pay for the whole
    /// recording: on a 30-minute take the difference is seconds of decode.
    /// The result is the head of `readMono` to within the resampler's edge
    /// (the full render replaces it at a synchronized boundary).
    public static func readMonoPrefix(_ url: URL, seconds: Double) throws -> [Float] {
        let (ch, rate) = try decodePrefix(url, seconds: seconds)
        guard let first = ch.first, !first.isEmpty else { return [] }
        return downmix(first, second: ch.count > 1 ? ch[1] : nil, rate: rate)
    }

    /// Read an arbitrary bounded interval directly from a file. The returned
    /// origin is the actual first native sample's source time, not the request.
    public static func readStereoWindow(_ url: URL, from start: Double, to end: Double) throws
        -> (left: [Float], right: [Float], origin: Double) {
        guard start.isFinite, end.isFinite, end > start else { return ([], [], 0) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = file.processingFormat, rate = fmt.sampleRate
        guard rate.isFinite, rate > 0, fmt.channelCount > 0 else { throw AudioIOError.unreadable("invalid format") }
        let first = AVAudioFramePosition(min(max((start * rate).rounded(.down), 0), Double(file.length)))
        let last = AVAudioFramePosition(min(max((end * rate).rounded(.up), Double(first)), Double(file.length)))
        file.framePosition = first
        let capacity = AVAudioFrameCount(16384)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { throw AudioIOError.unreadable("window buffer") }
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(Int(last - first)); right.reserveCapacity(Int(last - first))
        while file.framePosition < last {
            if Task.isCancelled { throw CancellationError() }
            let count = AVAudioFrameCount(min(Int64(capacity), last - file.framePosition))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            guard let pcm = buffer.floatChannelData else { throw AudioIOError.unreadable("window PCM") }
            let n = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: pcm[0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: pcm[fmt.channelCount > 1 ? 1 : 0], count: n))
        }
        return (resample(left, from: rate), resample(right, from: rate), Double(first) / rate)
    }

    /// Whole file -> per-channel Float32 at the file's own sample rate.
    static func decode(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
        try decodePrefix(url, seconds: nil)
    }

    private static func decodePrefix(_ url: URL, seconds: Double?) throws -> (channels: [[Float]], rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let total = seconds.map { min(Int(f.length), Int(($0 * fmt.sampleRate).rounded())) } ?? Int(f.length)
        let nch = Int(fmt.channelCount)
        guard total > 0, nch > 0 else { return ([], fmt.sampleRate) }
        var chans = [[Float]](repeating: [], count: nch)
        for c in 0..<nch { chans[c].reserveCapacity(total) }
        let cap: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw AudioIOError.unreadable("buffer") }
        var read = 0
        while read < total {
            let want = min(cap, AVAudioFrameCount(total - read))
            try f.read(into: buf, frameCount: want)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let d = buf.floatChannelData else { throw AudioIOError.unreadable("not float PCM") }
            for c in 0..<nch { chans[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: n)) }
            read += n
        }
        return (chans, fmt.sampleRate)
    }

    /// L+R downmix with the cancellation guard used by `readMono`.
    private static func downmix(_ l: [Float], second r: [Float]?, rate: Double) -> [Float] {
        let left = resample(l, from: rate)
        guard let r, r.count == l.count else { return left }
        let right = resample(r, from: rate)
        guard left.count == right.count, !left.isEmpty else { return left }
        let mono = vDSP.multiply(0.5, vDSP.add(left, right))
        // Opposed microphone channels can cancel almost completely in an L+R
        // downmix. Keep the stronger voice channel when cancellation is severe.
        let lp = vDSP.sumOfSquares(left), rp = vDSP.sumOfSquares(right)
        if vDSP.sumOfSquares(mono) < 0.2 * max(lp, rp) { return lp >= rp ? left : right }
        return mono
    }

    // MARK: Resample (mono -> 48 kHz)

    static func resample(_ x: [Float], from rate: Double) -> [Float] {
        guard !x.isEmpty, abs(rate - fs) > 0.5 else { return x }
        return convert(x, from: rate) ?? linear(x, from: rate)
    }

    private static func convert(_ x: [Float], from rate: Double) -> [Float]? {
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inB = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(x.count)),
              let outB = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(x.count) * fs / rate) + 4096)
        else { return nil }
        inB.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inB.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let box = OnceBox(inB)
        var err: NSError?
        let st = conv.convert(to: outB, error: &err) { _, status in
            if let b = box.buffer { box.buffer = nil; status.pointee = .haveData; return b }
            status.pointee = .endOfStream; return nil
        }
        guard st != .error, err == nil, outB.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: outB.floatChannelData![0], count: Int(outB.frameLength)))
    }

    /// Fallback if AVAudioConverter refuses.
    private static func linear(_ x: [Float], from rate: Double) -> [Float] {
        let n = Int(Double(x.count) * fs / rate), r = rate / fs
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * r, i0 = Int(p)
            if i0 + 1 < x.count { out[i] = x[i0] + (x[i0 + 1] - x[i0]) * Float(p - Double(i0)) }
            else if i0 < x.count { out[i] = x[i0] }
        }
        return out
    }

    // MARK: Public API

    /// Any audio file -> 48 kHz stereo Float32. Mono is duplicated; >2 channels use the first two.
    public static func readStereo(_ url: URL) throws -> ([Float], [Float]) {
        let (ch, rate) = try decode(url)
        guard let first = ch.first else { return ([], []) }
        let l = resample(first, from: rate)
        let r = ch.count > 1 ? resample(ch[1], from: rate) : l
        return (l, r)
    }

    /// The first `seconds` of a stereo file at 48 kHz, per channel.
    public static func readStereoPrefix(_ url: URL, seconds: Double) throws -> ([Float], [Float]) {
        let (ch, rate) = try decodePrefix(url, seconds: seconds)
        guard let first = ch.first else { return ([], []) }
        let l = resample(first, from: rate)
        let r = ch.count > 1 ? resample(ch[1], from: rate) : l
        return (l, r)
    }

    public static func readMono(_ url: URL) throws -> [Float] {
        let (ch, rate) = try decode(url)
        return downmix(ch.first ?? [], second: ch.count > 1 ? ch[1] : nil, rate: rate)
    }

    public static func loadMusic(_ url: URL) -> MusicTrack? {
        guard let (l, r) = try? readStereo(url), l.count > Int(fs), l.count == r.count else { return nil }
        return MusicTrack(l: l, r: r)
    }

    /// IEEE 32-bit float WAV for lossless handoff to Premiere, Resolve,
    /// Final Cut or any editor. File type is inferred from the .wav extension.
    public static func writeWAV(_ l: [Float], _ r: [Float], to url: URL) throws {
        precondition(url.pathExtension.lowercased() == "wav", "Stems must have .wav extension")
        try writeCAF(l, r, to: url)
    }

    /// Float32 stereo CAF (the exporter reads this back and AAC-encodes it).
    public static func writeCAF(_ l: [Float], _ r: [Float], to url: URL) throws {
        let fmt = stereoFormat
        var settings = fmt.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { throw AudioIOError.unreadable("buffer") }
        let total = min(l.count, r.count)
        var i = 0
        while i < total {
            let n = min(chunk, total - i)
            b.frameLength = AVAudioFrameCount(n)
            l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
            r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress! + i, count: n) }
            try f.write(from: b)
            i += n
        }
    }
}
extension AudioIO {
    /// DeepFilterNet's Rust CLI reads WAV through `wav_utils`, which only
    /// accepts 16-bit integer PCM with a correct `data` chunk size. A Float32
    /// or 24-bit WAV panics with "TooWide"; an AVAudioFile-written WAV declares
    /// a zero-length data chunk and panics in ndarray. Either failure used to
    /// send the default voice path silently to the SpectralGate fallback.
    /// The 16-bit quantisation sits below the model's own noise floor.
    static func writeMonoPCM16WAV(_ samples: [Float], paddingSamples: Int = 0, to url: URL) throws {
        let total = samples.count + max(paddingSamples, 0)
        let rate = UInt32(fs)
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            var v = value.littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        }
        var header = Data()
        header.reserveCapacity(44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le(UInt32(36 + total * 2)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le(UInt32(16)))       // fmt chunk size
        header.append(le(UInt16(1)))        // PCM
        header.append(le(UInt16(1)))        // mono
        header.append(le(rate))
        header.append(le(rate * 2))         // byte rate
        header.append(le(UInt16(2)))        // block align
        header.append(le(UInt16(16)))       // bits per sample
        header.append(contentsOf: Array("data".utf8))
        header.append(le(UInt32(total * 2)))
        try header.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(header.count))   // append after the header
        let chunk = 16_384
        for offset in stride(from: 0, to: total, by: chunk) {
            var bytes = Data()
            bytes.reserveCapacity(min(chunk, total - offset) * 2)
            for i in offset..<min(offset + chunk, total) {
                let v = i < samples.count ? Double(samples[i]) : 0
                bytes.append(le(Int16((max(-1, min(1, v)) * 32_767).rounded())))
            }
            try handle.write(contentsOf: bytes)
        }
    }

    public static func writeMonoWAV(_ samples: [Float], sampleRate: Double = fs, paddingSamples: Int = 0, to url: URL) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let data = buffer.floatChannelData else { throw AudioIOError.unreadable("mono format") }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = samples.count + max(paddingSamples, 0)
        for offset in stride(from: 0, to: total, by: Int(buffer.frameCapacity)) {
            let count = min(Int(buffer.frameCapacity), total - offset)
            let available = min(count, max(samples.count - offset, 0))
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if available > 0, let base = source.baseAddress { data[0].update(from: base + offset, count: available) }
            }
            if available < count { data[0].advanced(by: available).update(repeating: 0, count: count - available) }
            try file.write(from: buffer)
        }
    }

    static func resampleMono(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                              channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * outputRate / inputRate)) + 4096),
              let inputData = input.floatChannelData, let outputData = output.floatChannelData
        else { throw AudioIOError.unreadable("resampler") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { inputData[0].update(from: base, count: samples.count) }
        }
        let box = OnceBox(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let value = box.buffer else { state.pointee = .endOfStream; return nil }
            box.buffer = nil; state.pointee = .haveData; return value
        }
        guard status != .error, error == nil else { throw error ?? AudioIOError.unreadable("conversion") }
        let expected = Int((Double(samples.count) * outputRate / inputRate).rounded())
        var result = Array(UnsafeBufferPointer(start: outputData[0], count: min(Int(output.frameLength), expected)))
        if result.count < expected { result.append(contentsOf: repeatElement(0, count: expected - result.count)) }
        return result
    }
}
