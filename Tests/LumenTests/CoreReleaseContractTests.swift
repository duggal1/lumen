import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

@Test func studioPolicyPreservesRoutingButCanonicalizesLegacyModes() {
    var old = AudioPlan()
    old.micMode = .podcast; old.micClean = false
    old.noiseReductionStrength = 0; old.normalize = false
    old.studioMode = .optimized; old.micGainDb = -8
    let lane = AudioLane(role: .music, placement: 1)
    old.lanes = [lane]
    let studio = old.studioPolicy()
    #expect(studio.micMode == .standard)
    #expect(studio.micClean && studio.normalize && studio.voiceClarity)
    #expect(studio.noiseReductionStrength == 1)
    #expect(studio.studioMode == .standard)
    #expect(studio.micGainDb == -8 && studio.lanes == [lane])
    #expect(studio.studioPolicy() == studio)
    old.micMode = .off
    #expect(old.studioPolicy().micMode == .off)
}

@Test func fixedPivotTrajectorySettlesBeforeActionAndHoldsUntilRelease() {
    let p = CameraParams()
    let zoom = ZoomSegment(start: 2, end: 3, scale: 2, focus: .fixed(x: 0.35, y: 0.65), origin: .auto)
    let track = CameraSolver.solve(zoom: [zoom], tm: TimeMap(sourceDuration: 5),
                                   cursor: CursorTrack(count: 2), p: p, src: SIMD2(1920,1080), outDur: 5, loop: nil)
    let settled = Int((1.96 * track.rate).rounded())
    #expect(abs(Double(track.lz[settled]) - log(2)) < 0.00001)
    let end = Int(3 * track.rate)
    #expect(abs(Double(track.lz[end]) - log(2)) < 0.00001)
    for k in 0..<track.lz.count {
        let scale = exp(Double(track.lz[k]))
        let x = Double(track.nx[k])
        #expect(abs((x - 0.2) * scale - 0.3) < 0.00001)
    }
}

@Test func realKeyRepeatMetadataRoundTripsWithoutChangingKeyCode() {
    let e = InputEvent(t: 1, kind: .keyDown, keyCode: 12, flags: InputEvent.keyRepeatFlag)
    #expect(e.isKeyRepeat)
    #expect(e.keyCode == 12)
    #expect(!InputEvent(t: 1, kind: .keyUp, keyCode: 12, flags: InputEvent.keyRepeatFlag).isKeyRepeat)
}
