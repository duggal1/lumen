import Foundation
import AVFoundation

/// Immutable source-amplitude summary. It contains no raw PCM and is safe to
/// pass from a decode worker to the editor. The max pyramid answers arbitrary
/// visible time ranges without scanning every sample or normalizing silence.
public struct MusicWaveform: Sendable {
    public let duration: Double
    public let secondsPerBin: Double
    private let levels: [[Float]]

    public init(peaks: [Float], secondsPerBin: Double, duration: Double) {
        self.secondsPerBin = secondsPerBin.isFinite && secondsPerBin > 0 ? secondsPerBin : 0.01
        self.duration = duration.isFinite ? max(duration, 0) : 0
        var row = peaks.map { $0.isFinite ? min(abs($0), 1) : 0 }
        var pyramid = [row]
        while row.count > 1 {
            var next = [Float]()
            next.reserveCapacity((row.count + 1) / 2)
            for i in stride(from: 0, to: row.count, by: 2) {
                next.append(max(row[i], i + 1 < row.count ? row[i + 1] : 0))
            }
            pyramid.append(next)
            row = next
        }
        levels = pyramid
    }

    /// Maximum source-channel amplitude over the interval, O(log bins).
    public func peak(from start: Double, to end: Double) -> Float {
        guard start.isFinite, end.isFinite, end > start, end > 0,
              start < duration, let first = levels.first, !first.isEmpty else { return 0 }
        let lo = max(start, 0), hi = min(end, duration)
        var a = Int(min((lo / secondsPerBin).rounded(.down), Double(first.count)))
        var b = Int(min((hi / secondsPerBin).rounded(.up), Double(first.count)))
        var result: Float = 0
        for row in levels {
            guard a < b else { break }
            if a & 1 == 1 { result = max(result, row[a]); a += 1 }
            if a < b, b & 1 == 1 { b -= 1; result = max(result, row[b]) }
            a /= 2; b /= 2
        }
        return result
    }

    /// Stream fixed-size native PCM buffers. Even very long tracks retain at
    /// most one million base bins (roughly 8MB including the max pyramid).
    public static func read(_ url: URL) throws -> MusicWaveform {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, rate = format.sampleRate
        guard rate.isFinite, rate > 0, rate <= 768_000,
              format.channelCount > 0, file.length >= 0 else { throw AudioIOError.unreadable("waveform format") }
        let duration = Double(file.length) / rate
        let binFrames = max(Int64((rate / 100).rounded(.up)), file.length / 1_000_000 + 1, 1)
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioIOError.unreadable("waveform buffer")
        }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(min(file.length / binFrames + 1, 1_000_000)))
        var peak: Float = 0
        var used: Int64 = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            guard let data = buffer.floatChannelData else { throw AudioIOError.unreadable("waveform PCM") }
            for i in 0..<n {
                for channel in 0..<min(Int(format.channelCount), 2) {
                    let x = data[channel][i]
                    if x.isFinite { peak = max(peak, abs(x)) }
                }
                used += 1
                if used == binFrames { peaks.append(peak); peak = 0; used = 0 }
            }
        }
        if used > 0 { peaks.append(peak) }
        return MusicWaveform(peaks: peaks, secondsPerBin: Double(binFrames) / rate, duration: duration)
    }
}
