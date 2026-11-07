import Testing
@testable import LumenUI

/// Oracle for Plans/timeline-redesign.md. Red before the redesign:
/// old strip has no per-lane geometry helpers, so this fails to build.
@Test func sparseNineClicksStaySeparate() {
    let xs: [Double] = (0..<9).map { Double($0) * 10 }  // 10px apart at test scale
    let clusters = TimelineGeometry.cluster(xs: xs, minGap: 6)
    #expect(clusters.count == 9)
    #expect(clusters.allSatisfy { $0.count == 1 })
}

@Test func denseTwoHundredClusterBySixPixels() {
    let xs: [Double] = (0..<200).map { Double($0) * 0.3 }  // 0.3px apart -> one cluster
    let clusters = TimelineGeometry.cluster(xs: xs, minGap: 6)
    #expect(clusters.count == 1)
    #expect(clusters.first?.count == 200)
}

@Test func narrowZoomHidesLabel() {
    #expect(TimelineGeometry.labelFits(width: 12, text: "2.2×") == false)
    #expect(TimelineGeometry.labelFits(width: 80, text: "2.2×") == true)
}

@Test func hourLongWaveformWindow() {
    let wave = [Float](repeating: 0.5, count: 360_000)  // 3600s @100Hz
    let peak = TimelineGeometry.columnPeak(wave: wave, srcStart: 0, srcEnd: 3)
    #expect(peak == 0.5)
}

@Test func typingBurstsGroupCloseKeys() {
    let bursts = TimelineGeometry.bursts(times: [0, 0.2, 0.4, 5.0, 5.2], gap: 0.5)
    #expect(bursts.count == 2)
    #expect(bursts[0].end - bursts[0].start == 0.4)
}

@Test func triggerIsZoomContainingClick() {
    let zooms = [(start: 0.0, end: 2.0), (start: 5.0, end: 7.0)]
    #expect(TimelineGeometry.triggerZoom(t: 1.0, zooms: zooms) == 0)
    #expect(TimelineGeometry.triggerZoom(t: 3.0, zooms: zooms) == nil)
}
