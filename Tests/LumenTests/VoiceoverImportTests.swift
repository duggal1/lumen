import Foundation
import Testing
import LumenProject
import LumenDirector
import LumenAudio

@Test func importedVoiceoverIsPlacedInOutputTimeAndCanBeMuted() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let fs = AudioIO.fs
    let oneSecond = (0..<Int(fs)).map { Float(0.12 * sin(Double($0) * 2 * .pi * 350 / fs)) }
    try AudioIO.writeCAF(oneSecond, oneSecond, to: url)

    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 3,
                            backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 3)
    tl.audio.micMode = .off
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl.audio.lanes = [AudioLane(role: .voiceover, path: url.path, placement: 1, gainDb: -3)]
    tl = Director.derive(tl, input: DirectorInput(events: [], source: source), revision: 1)
    let mixer = AudioMixer(mic: nil, micOffset: 0, system: nil, systemOffset: 0)
    let mixed = try #require(mixer.mix(tl))
    #expect(mixed.l[Int(0.5 * fs)] == 0)
    #expect(abs(mixed.l[Int(1.25 * fs)]) > 0.005)
    #expect(mixed.truePeakDb <= -1 + 0.02)
    tl.audio.lanes[0].mute = true
    let muted = try #require(mixer.mix(tl))
    #expect(muted.l.allSatisfy { abs($0) < 0.0001 })
}

@Test func microphoneOffLeavesSystemTrackPresent() throws {
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 1,
                            backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl.audio.micMode = .off
    tl = Director.derive(tl, input: DirectorInput(events: [], source: source), revision: 1)
    let fs = AudioIO.fs
    let mic = [Float](repeating: 0.2, count: Int(fs))
    let sys = (0..<Int(fs)).map { Float(0.1 * sin(Double($0) * 2 * .pi * 500 / fs)) }
    let output = try #require(AudioMixer(mic: mic, micOffset: 0, system: sys, systemOffset: 0).mix(tl))
    #expect(output.l.reduce(Float(0)) { max($0, abs($1)) } > 0.02)
}
