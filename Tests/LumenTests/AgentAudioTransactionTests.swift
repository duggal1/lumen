import Foundation
import Testing
import LumenProject
@testable import LumenControl

@Test func finiteAudioClipSplitPreservesSourceAndOutputRanges() throws {
    var tl = Timeline(duration: 20)
    let id = UUID(), tail = UUID()
    var lane = AudioLane(id: id, role: .music, path: "/fixture.wav", placement: 2, gainDb: -12)
    lane.trimStart = 3; lane.trimDuration = 8; lane.loops = false
    let ctx = ReduceContext(playhead: 0, duration: 20)
    _ = try reduce(&tl, .addAudioLane(lane), ctx: ctx)
    _ = try reduce(&tl, .splitAudioLane(id, atOutput: 5, newID: tail), ctx: ctx)
    #expect(tl.audio.lanes.count == 2)
    #expect(tl.audio.lanes[0].trimDuration == 3)
    #expect(tl.audio.lanes[1].trimStart == 6)
    #expect(tl.audio.lanes[1].trimDuration == 5)
    #expect(tl.audio.lanes[1].placement == 5)
    #expect(tl.audio.lanes[1].id == tail)
    let before = tl
    do {
        _ = try reduce(&tl, .updateAudioLane(tail, AudioClipPatch(placement: .nan)), ctx: ctx)
        Issue.record("Invalid edit accepted")
    } catch { #expect(tl == before) }
}

@Test func finiteMusicStopsAtTrimInsteadOfLooping() {
    var lane = AudioLane(role: .music, path: "/fixture.wav", placement: 0, gainDb: 0)
    lane.trimStart = 0; lane.trimDuration = 0.5; lane.loops = false
    let track = MusicBed.PCM(left: Array(repeating: 1, count: 100), right: Array(repeating: 1, count: 100))
    let plan = MusicBed.plan(MusicBed(lane: lane), track: track, outputSamples: 100, fs: 100)
    let result = MusicBed.render(plan, track: track, duck: nil, outputSamples: 100, fs: 100)
    #expect(plan.count == 50)
    #expect(result.left[20] > 0)
    #expect(result.left[50...].allSatisfy { $0 == 0 })
}

@Test func agentAudioSchemaAndSkillsAreDiscoverable() {
    let registry = ToolRegistry()
    registry.registerAgentAudioTransactions()
    let spec = registry.spec("audio_edit_v2")
    #expect(spec?.required.contains("revision") == true)
    #expect(spec?.customDryRun == true)
    #expect(AgentEditingSkills.all.contains { $0.uri == "lumen://skills/audio-edit" })
    #expect(JSONValue.number(.greatestFiniteMagnitude).intValue == nil)
    #expect(JSONValue.number(1.5).intValue == nil)
}
