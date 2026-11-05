import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector

private let precisionSource = SourceInfo(width: 1920, height: 1080, fps: 60,
                                         duration: 6, backingScale: 1,
                                         originX: 0, originY: 0)

@Test func verifiedButtonCentersLandWithinTwoSourcePixelsAtNinePositions() {
    let xs = [20.0, 960.0, 1900.0], ys = [10.0, 540.0, 1070.0]
    for x in xs {
        for y in ys {
            let f = AXFrame(x: x - 20, y: y - 10, w: 40, h: 20)
            let e = InputEvent(t: 2, kind: .down, x: Float(x + 3),
                               y: Float(y), axFrameIndex: 1)
            var timeline = Timeline(duration: 6)
            timeline.audio.speedRampsAuto = false
            let output = Director.derive(timeline,
                input: DirectorInput(events: [e], source: precisionSource, ax: [f]), revision: 1)
            #expect(output.zoom.count == 1)
            guard let zoom = output.zoom.first else { continue }
            if case .element = zoom.focus {} else { Issue.record("Valid AX target should use its bounds") }
            let frame = output.evaluate(at: 2)
            let s = Double(frame.cameraScale)
            let feasibleX = clamp(x, Double(precisionSource.width) / (2 * s),
                                  Double(precisionSource.width) * (1 - 1 / (2 * s)))
            let feasibleY = clamp(y, Double(precisionSource.height) / (2 * s),
                                  Double(precisionSource.height) * (1 - 1 / (2 * s)))
            #expect(abs(Double(frame.cameraCenter.x) - feasibleX) < 2)
            #expect(abs(Double(frame.cameraCenter.y) - feasibleY) < 2)
            #expect(s >= 1.5)
        }
    }
}

@Test func staleAXElementDoesNotStealClickTarget() {
    let frame = AXFrame(x: 120, y: 200, w: 50, h: 30)
    let click = InputEvent(t: 2, kind: .down, x: 700, y: 400, axFrameIndex: 1)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    tl = Director.derive(tl, input: DirectorInput(events: [click], source: precisionSource,
                                                   ax: [frame]), revision: 1)
    #expect(tl.zoom.count == 1)
    if case .fixed(let x, let y) = tl.zoom[0].focus {
        #expect(abs(x - 700 / 1920) < 0.0001)
        #expect(abs(y - 400 / 1080) < 0.0001)
    } else {
        Issue.record("Stale AX frame must not move the center")
    }
}

@Test func keyboardShortcutsAndSingleKeysNeverInventZoom() {
    let events: [InputEvent] = [
        InputEvent(t: 1.0, kind: .keyDown, keyCode: 0),
        InputEvent(t: 2.0, kind: .keyDown, keyCode: 36),
        InputEvent(t: 3.0, kind: .keyDown, keyCode: 53),
        InputEvent(t: 4.0, kind: .keyDown, keyCode: 1, flags: 0x14),
    ]
    var t = Timeline(duration: 6)
    t.audio.speedRampsAuto = false
    let out = Director.derive(t, input: DirectorInput(events: events, source: precisionSource), revision: 1)
    #expect(out.zoom.isEmpty)
}

@Test func threeTypingKeysZoomToRecentPointerNotInventedCenter() {
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let keys = [InputEvent(t: 2, kind: .keyDown, keyCode: 0),
                InputEvent(t: 2.2, kind: .keyDown, keyCode: 1),
                InputEvent(t: 2.4, kind: .keyDown, keyCode: 2)]
    #expect(Director.derive(tl,
          input: DirectorInput(events: keys, source: precisionSource), revision: 1).zoom.isEmpty)
    let events = [InputEvent(t: 1.8, kind: .move, x: 1670, y: 290)] + keys
    let out = Director.derive(tl, input: DirectorInput(events: events, source: precisionSource), revision: 2)
    #expect(out.zoom.count == 1)
    if let z = out.zoom.first, case .fixed(let x, let y) = z.focus {
        #expect(abs(x * 1920 - 1670) < 1)
        #expect(abs(y * 1080 - 290) < 1)
    } else { Issue.record("Typing must target the actual pointer") }
}

@Test func clickAccuracyReportMeasuresArrivalNotJustZoomSegmentCount() {
    let click = InputEvent(t: 2, kind: .down, x: 900, y: 450)
    var timeline = Timeline(duration: 6)
    timeline.audio.speedRampsAuto = false
    timeline = Director.derive(timeline,
        input: DirectorInput(events: [click], source: precisionSource), revision: 1)
    let report = AccuracyReport.measure(timeline, events: [click])
    #expect(report.clicks == 1)
    #expect(report.zoomedClicks == 1)
    #expect(report.medianArrival >= 0.95)
    #expect(report.medianExcessError < 0.01)
}

@Test func followSmoothingDoesNotTrailConstantMovementOrChaseTinyWiggles() {
    let path = (0...200).map { Double($0) / 200 }
    let centered = CameraSolver.centredPlay(path, halfZone: 0.08)
    #expect(abs(centered[100] - 0.5) < 0.01)
    let noise = (0..<200).map { 0.5 + 0.01 * sin(Double($0) * 0.13) }
    let quiet = CameraSolver.centredPlay(noise, halfZone: 0.08)
    #expect(quiet.allSatisfy { abs($0 - 0.5) < 0.011 })
}
