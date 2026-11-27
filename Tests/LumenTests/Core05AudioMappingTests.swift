import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenAudio

@Test func directMappedAccumulationMatchesMaterializedChannels() {
    var tm = TimeMap(sourceDuration: 3)
    tm.cuts = [CutRange(start: 0.6, end: 0.9, origin: .manual),
               CutRange(start: 1.2, end: 1.5, origin: .manual)]
    let input = (0..<144_000).map { Float(sin(Double($0) * 0.037)) * 0.4 }
    let n = 115_200
    let expected = AudioMixer.mapped(input, offset: 0.00031, tm: tm, n: n, muteRamps: true)
    var left = [Float](repeating: 0.1, count: n)
    var right = [Float](repeating: -0.1, count: n)
    let completed = AudioMixer.addMappedMono(input, offset: 0.00031, tm: tm, muteRamps: true,
        gain: 0.7, left: &left, right: &right, cancelled: nil)
    #expect(completed)
    #expect(left == expected.map { 0.1 + $0 * 0.7 })
    #expect(right == expected.map { -0.1 + $0 * 0.7 })
}

@Test func mappedAccumulationRejectsCancelledWork() {
    var left = [Float](repeating: 0.1, count: 256)
    var right = left
    let result = AudioMixer.addMappedMono([1, 1, 1], offset: 0, tm: TimeMap(sourceDuration: 1),
        muteRamps: false, gain: 1, left: &left, right: &right, cancelled: { true })
    #expect(!result)
    #expect(left.allSatisfy { $0 == 0.1 })
    #expect(right.allSatisfy { $0 == 0.1 })
}
