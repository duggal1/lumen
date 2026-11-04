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

    // MARK: Decode

    /// Whole file -> per-channel Float32 at the file's own sample rate.
    static func decode(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let total = Int(f.length), nch = Int(fmt.channelCount)
        guard total > 0, nch > 0 else { return ([], fmt.sampleRate) }
        var chans = [[Float]](repeating: [], count: nch)
        for c in 0..<nch { chans[c].reserveCapacity(total) }
        let cap: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw AudioIOError.unreadable("buffer") }
        while f.framePosition < f.length {
            try f.read(into: buf, frameCount: cap)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let d = buf.floatChannelData else { throw AudioIOError.unreadable("not float PCM") }
            for c in 0..<nch { chans[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: n)) }
        }
        return (chans, fmt.sampleRate)
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

    public static func readMono(_ url: URL) throws -> [Float] {
        let (l, r) = try readStereo(url)
        guard l.count == r.count else { return l }
        return vDSP.multiply(0.5, vDSP.add(l, r))
    }

    public static func loadMusic(_ url: URL) -> MusicTrack? {
        guard let (l, r) = try? readStereo(url), l.count > Int(fs), l.count == r.count else { return nil }
        return MusicTrack(l: l, r: r)
    }

    /// Float32 stereo CAF (the exporter reads this back and AAC-encodes it).
    public static func writeCAF(_ l: [Float], _ r: [Float], to url: URL) throws {
        let fmt = stereoFormat
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
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