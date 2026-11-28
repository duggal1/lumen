import Foundation
import Testing
@testable import LumenCapture

@Test func captureInterruptionFirstCauseWinsAndOldGenerationCannotStopNewTake() throws {
    var state = CaptureInterruptionState()
    let first = state.begin()
    let failure = CaptureInterruption(kind: .streamStopped, domain: "SCStreamErrorDomain", code: -3808)
    #expect(state.accept(failure, generation: first))
    #expect(!state.accept(.init(kind: .sleep), generation: first))
    #expect(state.reason == failure)
    let roundTrip = try JSONDecoder().decode(CaptureInterruption.self, from: JSONEncoder().encode(failure))
    #expect(roundTrip == failure)
    let second = state.begin()
    #expect(second != first)
    #expect(!state.accept(failure, generation: first))
    #expect(state.reason == nil)
    #expect(state.accept(.init(kind: .diskPressure), generation: second))
    state.invalidate()
    #expect(!state.accept(failure, generation: second))
    #expect(state.reason == nil)
}
