import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

/// Recorded event sidecars should be enough to plan zoom before the Studio opens.
@Test func recordingStopZoomIsDeterministicAndMatchesFullDerivation() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 30,
                            backingScale: 2, originX: 0, originY: 0)
    var timeline = Timeline(duration: 30)
    timeline.audio.speedRampsAuto = false
    let events = [
        InputEvent(t: 2, kind: .down, x: 500, y: 350),
        InputEvent(t: 2.1, kind: .up, x: 500, y: 350),
        InputEvent(t: 12, kind: .down, x: 1500, y: 750),
        InputEvent(t: 12.1, kind: .up, x: 1500, y: 750)
    ]
    let planned = Director.planRecordingZoom(events: events, ax: [], source: source, timeline: timeline)
    let again = Director.planRecordingZoom(events: events, ax: [], source: source, timeline: timeline)
    let fullyDerived = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 0)
    #expect(!planned.isEmpty)
    #expect(planned == again)
    #expect(planned == fullyDerived.zoom)
    timeline.zoom = planned
    #expect(timeline.zoom == planned)
}

@Test func noRecordedEventsNeverInventAutomaticZoom() {
    let source = SourceInfo(width: 1440, height: 900, fps: 60, duration: 10,
                            backingScale: 1, originX: 0, originY: 0)
    let timeline = Timeline(duration: 10)
    let zoom = Director.planRecordingZoom(events: [], ax: [], source: source, timeline: timeline)
    #expect(zoom.isEmpty)
}

@Test func stereoSystemAudioSurvivesSeparateStemAndFinalMix() throws {
    let fs = AudioIO.fs
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 1,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline.audio.normalize = false
    timeline = Director.derive(timeline, input: DirectorInput(events: [], source: source), revision: 1)

    let left = (0..<Int(fs)).map { Float(0.05 * sin(Double($0) * 2 * .pi * 440 / fs)) }
    let right = (0..<Int(fs)).map { Float(0.05 * sin(Double($0) * 2 * .pi * 880 / fs)) }
    let mixer = AudioMixer(mic: nil, micOffset: 0, system: left,
                           systemOffset: 0, systemRight: right)
    let stem = try #require(mixer.stems(timeline).first)
    #expect(stem.name == "system")
    #expect(stem.left != stem.right)
    #expect(stem.left.count == stem.right.count)

    let mixed = try #require(mixer.mix(timeline))
    #expect(mixed.l != mixed.r)
    #expect(mixed.truePeakDb <= -1)
}

@Test func oppositePhaseStereoMicDoesNotCancelRecordedVoice() throws {
    let fs = AudioIO.fs
    let left = (0..<Int(fs)).map { Float(0.15 * sin(Double($0) * 2 * .pi * 220 / fs)) }
    let right = left.map { -$0 }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-mic-phase-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    try AudioIO.writeCAF(left, right, to: url)
    let mono = try AudioIO.readMono(url)
    #expect(mono.count == left.count)
    let rms = sqrt(mono.reduce(0.0) { $0 + Double($1 * $1) } / Double(mono.count))
    #expect(rms > 0.09, "Opposed microphone channels were destructively summed")
}
