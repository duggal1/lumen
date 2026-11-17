import Foundation
import Testing
import os
import Synchronization
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector
@testable import LumenCapture

// Agent 3 — dialog / new-window / typing intent capture.
//
// Everything here runs in-process. AX and the CGEventTap are replaced with
// deterministic seams; no window is opened, no key is sent globally, the real
// cursor is never moved, and no window is focused or raised.

// MARK: - Harness

private final class IntentLog: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock<[InputEvent]>(initialState: [])
    private let focuses = OSAllocatedUnfairLock<[(InputEvent, AXFrame)]>(initialState: [])
    func event(_ e: InputEvent) { events.withLock { $0.append(e) } }
    func focus(_ e: InputEvent, _ f: AXFrame) { focuses.withLock { $0.append((e, f)) } }
    var allEvents: [InputEvent] { events.withLock { $0 } }
    var allFocuses: [(InputEvent, AXFrame)] { focuses.withLock { $0 } }
    var eventCount: Int { events.withLock { $0.count } }
    var focusCount: Int { focuses.withLock { $0.count } }
    @discardableResult
    func reset() -> (Int, Int) {
        let e = events.withLock { v -> Int in let n = v.count; v.removeAll(); return n }
        let f = focuses.withLock { v -> Int in let n = v.count; v.removeAll(); return n }
        return (e, f)
    }
}

@MainActor
private func makeRecorder() throws -> (InputRecorder, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = InputRecorder(url: dir.appendingPathComponent("events.bin"),
                          axURL: dir.appendingPathComponent("ax.json"),
                          origin: .zero, scale: 1, clock: RecordingClock())
    r.debugSetAXTrusted(true)
    r.debugSetFocusDelay(0)
    r.debugSetRunning(true)
    return (r, dir)
}

@MainActor
private func waitUntil(_ predicate: @MainActor () -> Bool, timeout: Double = 2.0) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

private func down(_ t: Double, _ x: Double = 300, _ y: Double = 300) -> InputEvent {
    InputEvent(t: t, kind: .down, x: Float(x), y: Float(y), button: 0)
}

private func key(_ t: Double, _ code: UInt16) -> InputEvent {
    InputEvent(t: t, kind: .keyDown, keyCode: code)
}

private func surface(_ id: Int, _ kind: AXSurface.Kind = .window,
                     role: String? = nil, subrole: String? = nil, title: String? = nil,
                     rect: CGRect = CGRect(x: 100, y: 100, width: 900, height: 600)) -> AXSurface {
    AXSurface(id: id, kind: kind, role: role ?? (kind == .window ? "AXWindow" : "AXSheet"),
              subrole: subrole, title: title, frame: rect, appName: "Browser")
}

private func fieldProbe(_ rect: CGRect, caret: CGRect? = nil, context: String = "field") -> FocusProbe {
    var f = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    if let caret { f.caret = .init(x: caret.minX, y: caret.minY, w: caret.width, h: caret.height) }
    f.sampledAt = HostClock.now()
    return FocusProbe(frame: f, context: context, appName: "Browser", windowID: 1)
}

private func windowFrames(_ recorder: InputRecorder) -> [AXFrame] {
    recorder.axFramesSnapshot.filter { $0.label?.hasPrefix("window|") == true }
}

// MARK: - Fix 1: dialog / new-window frames at click time

@Test @MainActor func dialogFrameIsResolvedAtClickTimeWithWindowLabel() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    // Baseline = the app window only; a sheet appears in the same observation
    // that handles this click (the screenshot's "Share your card" moment).
    recorder.debugSetKnownSurfaceIDs([1])
    recorder.debugSetSurfaceProbe { _ in
        [surface(1, rect: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
         surface(2, .sheet, subrole: "AXDialog", title: "Share your card",
                 rect: CGRect(x: 600, y: 300, width: 720, height: 420))]
    }

    recorder.debugRecord(down(5.0))

    // This is the whole point: no wait, no 120 ms throttle, no follow-up poll.
    let frames = windowFrames(recorder)
    #expect(frames.count == 1)
    let dialog = try #require(frames.first)
    #expect(dialog.label == "window|AXSheet|AXDialog|Share your card")
    #expect(dialog.x == 600 && dialog.y == 300 && dialog.w == 720 && dialog.h == 420)
    #expect(dialog.sampledAt == 5.0)
    let anchor = try #require(dialog.anchor)
    #expect(anchor.resolved)
    #expect(anchor.sampledAt == 5.0)
    #expect(anchor.epoch >= 1)
    #expect(anchor.appName == "Browser")

    // Exactly one live delivery for the click. The dialog frame is a separate
    // reservation, so the planner does not mistake it for the clicked control.
    #expect(log.eventCount == 1)
    let click = try #require(log.allEvents.first)
    let dialogIndex = try #require(recorder.axFramesSnapshot.firstIndex { $0.label?.hasPrefix("window|") == true }) + 1
    #expect(Int(click.axFrameIndex) >= 1)
    #expect(Int(click.axFrameIndex) != dialogIndex)
    #expect(log.focusCount == 0)   // a click never fabricates a typing focus
    await recorder.stop()
}

@Test @MainActor func newWindowDetectedOnceEpochBumpsAndSubsequentClicksAreQuiet() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.debugSetKnownSurfaceIDs([1])

    let showWindow = OSAllocatedUnfairLock(initialState: false)
    recorder.debugSetSurfaceProbe { _ in
        var surfaces = [surface(1, rect: CGRect(x: 0, y: 0, width: 1600, height: 1000))]
        if showWindow.withLock({ $0 }) {
            surfaces.append(surface(9, .window, title: "New Tab",
                                    rect: CGRect(x: 280, y: 120, width: 720, height: 460)))
        }
        return surfaces
    }

    recorder.debugRecord(down(1.0))               // baseline refresh: no new window
    #expect(windowFrames(recorder).isEmpty)

    showWindow.withLock { $0 = true }
    recorder.debugRecord(down(2.0))               // new window appears
    let first = windowFrames(recorder)
    #expect(first.count == 1)
    let e1 = try #require(first.first?.anchor?.epoch)

    recorder.debugRecord(down(3.0))               // same window: no second emission
    recorder.debugRecord(down(4.0))
    #expect(windowFrames(recorder).count == 1)
    let anchor = try #require(windowFrames(recorder).first?.anchor)
    #expect(anchor.epoch == e1)
    #expect(anchor.sampledAt == 2.0)              // fresh frame was not overwritten
    #expect(log.eventCount == 4)                  // one delivery per click, no duplicates
    await recorder.stop()
}

@Test @MainActor func modalAndPopoverSurfacesAreRecognisedAsDialogs() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    recorder.debugSetKnownSurfaceIDs([1])
    recorder.debugSetSurfaceProbe { _ in
        [surface(1), surface(3, .modal, role: "AXDialog", title: "Color",
                            rect: CGRect(x: 600, y: 200, width: 400, height: 300)),
         surface(4, .popover, role: "AXPopover", title: "Finish",
                 rect: CGRect(x: 700, y: 300, width: 300, height: 220))]
    }
    recorder.debugRecord(down(6.0))
    let labels = windowFrames(recorder).compactMap(\.label)
    #expect(labels.contains("window|AXDialog||Color"))
    #expect(labels.contains("window|AXPopover||Finish"))
    #expect(windowFrames(recorder).allSatisfy { $0.anchor?.resolved == true })
    await recorder.stop()
}

@Test @MainActor func plannerConsumesTheCapturedDialogFrame() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    recorder.debugSetKnownSurfaceIDs([1])
    recorder.debugSetSurfaceProbe { _ in
        [surface(1, rect: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
         surface(2, .sheet, title: "Share your card",
                 rect: CGRect(x: 600, y: 300, width: 720, height: 420))]
    }
    recorder.debugRecord(down(5.0))
    let events = recorder.debugDrainEvents()
    let intents = ZoomPlanner.dialogIntents(ax: recorder.axFramesSnapshot, events: events,
                                            markers: [], tm: TimeMap(sourceDuration: 30),
                                            W: 1920, H: 1080)
    #expect(intents.count == 1)
    #expect(intents.first?.kind == ZoomPlanner.IntentKind.dialog)
    #expect(intents.first?.t == 5.0)
    #expect(intents.first?.frameRect?.width == 720)
    await recorder.stop()
}

// MARK: - Fix 2: immediate, provenance-carrying typing focus

@Test @MainActor func typingFieldResolvesImmediatelyFromCacheWhenEventHookIsInstalled() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    // Both hooks installed — this is the production wiring in AppModel. The
    // old code chose `.event` here and withheld the cached field until the AX
    // query returned, which is why address-bar typing did not re-aim at once.
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, _ in
        fieldProbe(CGRect(x: 400, y: 100, width: 800, height: 28),
                   caret: CGRect(x: 430, y: 106, width: 1, height: 16), context: "addressBar")
    }

    recorder.debugRecord(key(1.0, 0))
    #expect(await waitUntil { log.focusCount >= 1 })
    let firstEpoch = try #require(log.allFocuses.first?.1.anchor?.epoch)
    _ = log.reset()

    recorder.debugRecord(key(1.1, 1))
    // Immediate delivery: no waiting for a second AX round-trip.
    #expect(await waitUntil({ log.focusCount >= 1 }, timeout: 0.5))
    #expect(await waitUntil({ log.eventCount >= 1 }, timeout: 0.5))
    let immediate = try #require(log.allFocuses.first)
    let frame = immediate.1
    #expect(frame.caret?.x == 430)
    #expect(frame.anchor?.resolved == true)
    #expect(frame.anchor?.epoch == firstEpoch)      // same field, same context
    #expect(frame.anchor?.sampledAt ?? 0 > 0)
    // The late enrichment for this same key must be suppressed, not duplicated.
    try? await Task.sleep(for: .milliseconds(80))
    #expect(log.eventCount == 1)
    #expect(log.focusCount == 1)
    await recorder.stop()
}

@Test @MainActor func firstKeyWithoutCacheStillDeliversBareEventExactlyOnce() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, _ in nil }

    recorder.debugRecord(key(1.0, 0))
    #expect(await waitUntil { log.eventCount == 1 })
    try? await Task.sleep(for: .milliseconds(80))
    #expect(log.eventCount == 1)
    #expect(log.focusCount == 0)
    let index = try #require(log.allEvents.first?.axFrameIndex)
    #expect(index > 0)
    let frames = recorder.axFramesSnapshot
    if Int(index) <= frames.count {
        #expect(frames[Int(index) - 1].anchor?.resolved != true)
    } else {
        #expect(frames.isEmpty)   // nothing resolved: no slot was ever published
    }
    await recorder.stop()
}

// MARK: - Fix 3: provenance invariants

@Test @MainActor func staleAndUnresolvedSamplesNeverMasqueradeAsFreshResolvedOnes() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }

    let gateA = DispatchSemaphore(value: 0)
    let enteredA = OSAllocatedUnfairLock(initialState: false)
    recorder.debugSetFocusProbe { _, event in
        if event.keyCode == 0 {
            if !enteredA.withLock({ $0 }) {
                enteredA.withLock { $0 = true }
                gateA.wait()
            }
            return fieldProbe(CGRect(x: 10, y: 10, width: 200, height: 24), context: "old")
        }
        return fieldProbe(CGRect(x: 700, y: 500, width: 240, height: 28),
                          caret: CGRect(x: 720, y: 506, width: 1, height: 16), context: "new")
    }

    recorder.debugRecord(key(1.0, 0))
    #expect(await waitUntil { enteredA.withLock { $0 } })

    recorder.debugRecord(key(1.05, 1))
    // Both keys are delivered live once each while A's AX query is blocked.
    #expect(await waitUntil { log.eventCount == 2 })
    gateA.signal()
    // The serial focus queue completes A then B. B's epoch must still be the
    // new context's, and A's late sample must stay in A's own slot.
    #expect(await waitUntil { log.focusCount >= 2 })
    try? await Task.sleep(for: .milliseconds(60))
    let frames = recorder.axFramesSnapshot
    let aIndex = Int(try #require(log.allEvents.first { $0.keyCode == 0 }?.axFrameIndex))
    let bIndex = Int(try #require(log.allEvents.first { $0.keyCode == 1 }?.axFrameIndex))
    #expect(aIndex != bIndex)
    #expect(frames[bIndex - 1].x == 700)
    #expect(frames[bIndex - 1].anchor?.epoch == 2)
    #expect(frames[aIndex - 1].x == 10)
    #expect(frames[aIndex - 1].anchor?.epoch == 1)
    #expect(log.eventCount == 2)                    // no duplicate key-down
    #expect(log.allFocuses.last?.1.x == 700)        // newest context delivered last
    #expect(log.allFocuses.allSatisfy { $0.1.anchor?.resolved == true })
    await recorder.stop()
}

// MARK: - Fix 4: no perf regression under a click storm

@Test @MainActor func rapidClickStormHasNoDuplicateDeliveryAndStaysBounded() async throws {
    let (recorder, dir) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = IntentLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.debugSetKnownSurfaceIDs([1])
    recorder.debugSetSurfaceProbe { _ in [surface(1)] }

    let started = Date()
    for i in 0..<400 { recorder.debugRecord(down(1.0 + Double(i) * 0.001)) }
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 2.0, "400 click-time resolutions took \(elapsed)s")
    #expect(log.eventCount == 400)
    let events = log.allEvents
    #expect(Set(events.map(\.axFrameIndex)).count == 400)
    #expect(events.allSatisfy { $0.axFrameIndex > 0 })
    #expect(windowFrames(recorder).isEmpty)          // stable surface set emits nothing
    await recorder.stop()
}
