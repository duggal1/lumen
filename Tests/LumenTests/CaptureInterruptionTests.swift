import Foundation
import Testing
@testable import LumenCapture

@Test func captureInterruptionFirstCauseWinsAndOldGenerationCannotStopNewTake() throws {
    var state = CaptureInterruptionState()
    let first = state.begin()
    let failure = CaptureInterruption(kind: .streamStopped, domain: "SCStreamErrorDomain", code: -3808)
    let accepted1 = state.accept(failure, generation: first)
    #expect(accepted1)
    let accepted2 = state.accept(.init(kind: .sleep), generation: first)
    #expect(!accepted2)
    #expect(state.reason == failure)
    let roundTrip = try JSONDecoder().decode(CaptureInterruption.self, from: JSONEncoder().encode(failure))
    #expect(roundTrip == failure)
    let second = state.begin()
    #expect(second != first)
    let accepted3 = state.accept(failure, generation: first)
    #expect(!accepted3)
    #expect(state.reason == nil)
    let accepted4 = state.accept(.init(kind: .diskPressure), generation: second)
    #expect(accepted4)
    state.invalidate()
    let accepted5 = state.accept(failure, generation: second)
    #expect(!accepted5)
    #expect(state.reason == nil)
}
