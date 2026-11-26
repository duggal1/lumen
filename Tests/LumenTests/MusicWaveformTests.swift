import Foundation
import AVFoundation
import Testing
import LumenAudio

@Test func waveformPyramidMatchesActualIntervalPeaks() {
    let wave = MusicWaveform(peaks: [0, 0.25, 0.75, 0.125, 0, 1, 0.5], secondsPerBin: 1, duration: 7)
    #expect(wave.peak(from: 0, to: 1) == 0)
    #expect(wave.peak(from: 1, to: 4) == 0.75)
    #expect(wave.peak(from: 4, to: 7) == 1)
    #expect(wave.peak(from: 6, to: 7) == 0.5)
    #expect(wave.peak(from: 7, to: 100) == 0)
    #expect(wave.peak(from: .nan, to: 1) == 0)
    #expect(wave.peak(from: 0, to: .greatestFiniteMagnitude) == 1)
}

@Test func waveformReadsRealStereoPcmAndKeepsSilence() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1440))
    pcm.frameLength = 1440
    let channels = try #require(pcm.floatChannelData)
    for i in 0..<1440 { channels[0][i] = 0; channels[1][i] = (480..<960).contains(i) ? -0.75 : 0 }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: pcm)
    }
    let wave = try MusicWaveform.read(url)
    #expect(wave.peak(from: 0, to: 0.009) == 0)
    #expect(wave.peak(from: 0.011, to: 0.019) == 0.75)
    #expect(wave.peak(from: 0.021, to: 0.029) == 0)
}
