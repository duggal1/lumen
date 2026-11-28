import Testing
import Foundation
@testable import LumenProject

@Test func sparseTimeMapPrototypeMatchesDenseTimingAcrossCutsAndRamps() {
    let maps = [
        TimeMap(sourceDuration: 60),
        TimeMap(sourceDuration: 60, trimStart: 0.123, trimEnd: 59.947,
                ramps: [.init(start: 1.34, end: 3.2, speed: 4), .init(start: 9, end: 30, speed: 0.5),
                        .init(start: 10, end: 32, speed: 2), .init(start: 35, end: 35.012, speed: 8)],
                cuts: [.init(start: 4.234, end: 8.129), .init(start: 7, end: 9),
                       .init(start: 40.8, end: 42.3)]),
        TimeMap(sourceDuration: 10, ramps: [.init(start: 0, end: 10, speed: 8)],
                cuts: [.init(start: 0, end: 1), .init(start: 9, end: 10)])
    ]
    for dense in maps {
        let sparse = SparseTimeMapIndex(dense)
        #expect(abs(dense.outputDuration - sparse.outputDuration) < 1e-7)
        for i in 0...4000 {
            let s = dense.trimStart + Double(i) / 4000 * (dense.trimEnd - dense.trimStart)
            #expect(abs(dense.output(atSource: s) - sparse.output(atSource: s)) < 1e-7)
            if dense.isCut(s) { continue }
            let t = dense.output(atSource: s)
            // Compare inverse queries away from cut plateaus; each seam has
            // a separate test using the index's own exact output boundary.
            let nearSeam = dense.cuts.contains { abs(t - dense.output(atSource: $0.start)) < 1e-5 }
            if !nearSeam { #expect(abs(dense.source(atOutput: t) - sparse.source(atOutput: t)) < 1e-6) }
        }
    }
}

@Test func sparseTimeMapPrototypeSelectsRightSideAtCutBoundary() {
    let dense = TimeMap(sourceDuration: 20, cuts: [.init(start: 2, end: 8), .init(start: 8, end: 10)])
    let sparse = SparseTimeMapIndex(dense)
    let seam = sparse.output(atSource: 2)
    #expect(abs(sparse.source(atOutput: seam) - 10) < 1e-8)
    #expect(sparse.source(atOutput: seam - 0.001) < 2)
    #expect(sparse.source(atOutput: seam + 0.001) > 10)
}

@Test func sparseTimeMapPrototypeStorageDependsOnEditComplexityNotDuration() {
    let dense = TimeMap(sourceDuration: 7200,
        ramps: [.init(start: 12, end: 6000, speed: 2)],
        cuts: [.init(start: 6100, end: 6200)])
    let sparse = SparseTimeMapIndex(dense)
    #expect(sparse.denseTickCount == 1_728_001)
    #expect(sparse.segmentCount <= 10)
    #expect(sparse.retainedKnots <= 250)
    #expect(abs(dense.outputDuration - sparse.outputDuration) < 0.0001)
    for t in [0.0, 20, 3000, 3600, 7199.9] {
        #expect(abs(dense.output(atSource: t) - sparse.output(atSource: t)) < 0.0001)
    }
}
