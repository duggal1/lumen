import Foundation
import os
import Testing
import Synchronization
import LumenCore
import LumenProject
@testable import LumenCapture

// Regression oracle for typing focus delivery and provenance.
//
// These exercise the reservation/delivery path in-process: the event-tap
// callback and the real AX server are not available in a unit test, so the
// recorder's AX probe is replaced with a deterministic one. The property under
// test is the recorder's policy, not AX itself.

private final class LiveLog: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock<[InputEvent]>(initialState: [])
    private let focuses = OSAllocatedUnfairLock<[(InputEvent, AXFrame)]>(initialState: [])
    func event(_ e: InputEvent) { events.withLock { $0.append(e) } }
    func focus(_ e: InputEvent, _ f: AXFrame) { focuses.withLock { $0.append((e, f)) } }
    var eventCount: Int { events.withLock { $0.count } }
    var focusCount: Int { focuses.withLock { $0.count } }
    var allEvents: [InputEvent] { events.withLock { $0 } }
    var allFocuses: [(InputEvent, AXFrame)] { focuses.withLock { $0 } }
}

private func makeProbe(field: CGRect, caret: CGRect?, context: String,
                       appName: String? = "Mail", windowID: Int? = 7,
                       host: String? = nil) -> FocusProbe {
    var frame = AXFrame(x: Double(field.minX), y: Double(field.minY),
                        w: Double(field.width), h: Double(field.height))
    if let caret {
        frame.caret = .init(x: Double(caret.minX), y: Double(caret.minY),
                            w: Double(caret.width), h: Double(caret.height))
    }
    frame.sampledAt = HostClock.now()
    return FocusProbe(frame: frame, context: context, appName: appName,
                      windowID: windowID, host: host)
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

@MainActor
private func makeRecorder() throws -> (InputRecorder, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let recorder = InputRecorder(url: directory.appendingPathComponent("events.bin"),
                                 axURL: directory.appendingPathComponent("ax.json"),
                                 origin: .zero, scale: 1, clock: RecordingClock())
    recorder.debugSetAXTrusted(true)
    recorder.debugSetFocusDelay(0)
    recorder.debugSetRunning(true)
    return (recorder, directory)
}

private func key(_ t: Double, _ code: UInt16, flags: UInt16 = 0) -> InputEvent {
    InputEvent(t: t, kind: .keyDown, keyCode: code, flags: flags)
}

// A burst with no mouse click anywhere must still resolve a caret target.
// This is the "typing does not aim zoom" P0: the caret comes from the focused
// element, never from a click or a pointer position.
@Test @MainActor func burstWithoutMouseClickProducesValidCaretTarget() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, _ in
        makeProbe(field: CGRect(x: 80, y: 190, width: 200, height: 24),
                  caret: CGRect(x: 100, y: 200, width: 1, height: 16), context: "fieldA")
    }

    for i in 0..<3 { recorder.debugRecord(key(1.0 + Double(i) * 0.1, UInt16(i))) }

    let resolved = await waitUntil { log.focusCount >= 1 && log.eventCount >= 3 }
    #expect(resolved)
    let events = log.allEvents
    #expect(events.count == 3)
    // Every key owns its own reservation; none is a reused index.
    let indices = events.map(\.axFrameIndex)
    #expect(indices.allSatisfy { $0 > 0 })
    #expect(Set(indices).count == indices.count)

    let frames = recorder.axFramesSnapshot
    let resolvedFrames = indices.compactMap { index -> AXFrame? in
        guard index >= 1, Int(index) <= frames.count else { return nil }
        let frame = frames[Int(index) - 1]
        return frame.anchor?.resolved == true ? frame : nil
    }
    #expect(!resolvedFrames.isEmpty)
    if let frame = resolvedFrames.first {
        let caret = try #require(frame.caret)
        // The target is the AX caret, not the pointer (a key event has no
        // pointer position at all).
        #expect(abs(caret.x + caret.w / 2 - 100.5) < 0.01)
        #expect(abs(caret.y + caret.h / 2 - 208) < 0.01)
    }
    await recorder.stop()
}

// A pointer parked in the opposite corner while typing must not become the
// focus target.
@Test @MainActor func pointerInOppositeCornerDoesNotStealTypingFocus() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, _ in
        makeProbe(field: CGRect(x: 80, y: 190, width: 200, height: 24),
                  caret: CGRect(x: 100, y: 200, width: 1, height: 16), context: "fieldA")
    }

    recorder.debugRecord(InputEvent(t: 0.5, kind: .move, x: 1900, y: 1000))
    recorder.debugRecord(key(1.0, 0))

    let done = await waitUntil { log.focusCount >= 1 }
    #expect(done)
    if let (_, frame) = log.allFocuses.first {
        let caret = try #require(frame.caret)
        #expect(abs(caret.x + caret.w / 2 - 100.5) < 0.01)
        #expect(abs(caret.y + caret.h / 2 - 208) < 0.01)
        #expect(hypot(caret.x - 1900, caret.y - 1000) > 100)
    }
    await recorder.stop()
}

// A failing AX query still delivers the key exactly once, and the event's own
// slot stays explicitly unresolved rather than becoming a zeroed sample.
@Test @MainActor func failingFocusQueryStillDeliversKeyExactlyOnce() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, _ in nil }

    recorder.debugRecord(key(1.0, 0))
    let delivered = await waitUntil { log.eventCount == 1 }
    #expect(delivered)
    // Let the failed query finish before asserting no enrichment arrives.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(log.eventCount == 1)
    #expect(log.focusCount == 0)
    let frames = recorder.axFramesSnapshot
    let index = log.allEvents.first?.axFrameIndex ?? 0
    if index > 0, Int(index) <= frames.count {
        #expect(frames[Int(index) - 1].anchor?.resolved == false)
    }
    await recorder.stop()
}

// Enrichment for a key is an update to that key's identity, not a second
// key-down. The live consumer must not see two events for one press.
@Test @MainActor func lateFocusEnrichmentUpdatesSameEventWithoutDuplicate() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }

    let entered = OSAllocatedUnfairLock(initialState: 0)
    let release = DispatchSemaphore(value: 0)
    recorder.debugSetFocusProbe { _, _ in
        entered.withLock { $0 += 1 }
        release.wait()
        return makeProbe(field: CGRect(x: 80, y: 190, width: 200, height: 24),
                         caret: CGRect(x: 100, y: 200, width: 1, height: 16), context: "fieldA")
    }

    recorder.debugRecord(key(1.0, 0))
    let inQuery = await waitUntil { entered.withLock({ $0 }) == 1 }
    #expect(inQuery)
    #expect(log.eventCount == 1)
    #expect(log.focusCount == 0)

    release.signal()
    let enriched = await waitUntil { log.focusCount == 1 }
    #expect(enriched)
    #expect(log.eventCount == 1)                       // still one key-down
    let event = log.allEvents.first
    let focus = log.allFocuses.first
    #expect(event != nil && focus != nil)
    if let event, let focus {
        #expect(event.t == focus.0.t)
        #expect(event.keyCode == focus.0.keyCode)
        #expect(event.axFrameIndex == focus.0.axFrameIndex)
        #expect(focus.1.caret != nil)
    }
    await recorder.stop()
}

// Two different focus contexts in quick succession must never publish the
// first context's frame for the second. The second key owns a different
// reservation, and the late first sample lands only in the first slot.
@Test @MainActor func differentFocusContextsNeverPublishFirstFrameForSecond() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }

    let enteredA = OSAllocatedUnfairLock(initialState: 0)
    let releaseA = DispatchSemaphore(value: 0)
    recorder.debugSetFocusProbe { _, event in
        if event.keyCode == 0 {
            enteredA.withLock { $0 += 1 }
            releaseA.wait()
            return makeProbe(field: CGRect(x: 100, y: 100, width: 200, height: 24),
                             caret: CGRect(x: 120, y: 110, width: 1, height: 16), context: "A")
        }
        return makeProbe(field: CGRect(x: 700, y: 500, width: 240, height: 24),
                         caret: CGRect(x: 720, y: 510, width: 1, height: 16), context: "B")
    }

    recorder.debugRecord(key(1.0, 0))
    let aInQuery = await waitUntil { enteredA.withLock({ $0 }) == 1 }
    #expect(aInQuery)

    recorder.debugRecord(key(1.05, 1))
    let bDelivered = await waitUntil { log.eventCount >= 2 }
    #expect(bDelivered)

    let events = log.allEvents
    let aIndex = events.first { $0.keyCode == 0 }?.axFrameIndex ?? 0
    let bIndex = events.first { $0.keyCode == 1 }?.axFrameIndex ?? 0
    #expect(aIndex > 0 && bIndex > 0)
    #expect(aIndex != bIndex)          // the old code reused A's pending index

    releaseA.signal()
    let aDone = await waitUntil { log.focusCount >= 1 }
    #expect(aDone)
    let bDone = await waitUntil { log.focusCount >= 2 }
    #expect(bDone)

    let frames = recorder.axFramesSnapshot
    if aIndex > 0, Int(aIndex) <= frames.count, bIndex > 0, Int(bIndex) <= frames.count {
        #expect(frames[Int(aIndex) - 1].x == 100)
        #expect(frames[Int(bIndex) - 1].x == 700)
        #expect(frames[Int(bIndex) - 1].caret?.x == 720)
    }
    let bFocus = log.allFocuses.first { $0.0.keyCode == 1 }
    #expect(bFocus?.1.x == 700)
    await recorder.stop()
}

// A stale sample is only usable if the consumer can see which focus epoch it
// came from. The epoch changes when the focused element changes.
@Test @MainActor func focusEpochChangesWhenFocusContextChanges() async throws {
    let (recorder, directory) = try makeRecorder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = LiveLog()
    recorder.setLiveEventHook { log.event($0) }
    recorder.setLiveFocusHook { log.focus($0, $1) }
    recorder.debugSetFocusProbe { _, event in
        event.keyCode == 0
            ? makeProbe(field: CGRect(x: 100, y: 100, width: 200, height: 24),
                        caret: CGRect(x: 120, y: 110, width: 1, height: 16), context: "A")
            : makeProbe(field: CGRect(x: 700, y: 500, width: 240, height: 24),
                        caret: CGRect(x: 720, y: 510, width: 1, height: 16), context: "B")
    }

    recorder.debugRecord(key(1.0, 0))
    _ = await waitUntil { log.focusCount >= 1 }
    recorder.debugRecord(key(1.2, 1))
    _ = await waitUntil { log.focusCount >= 2 }

    let anchors = log.allFocuses.compactMap { $0.1.anchor }
    #expect(anchors.count == 2)
    #expect(anchors.allSatisfy { $0.resolved })
    #expect(anchors.allSatisfy { $0.sampledAt > 0 })
    #expect(anchors[0].epoch == 1)
    #expect(anchors[1].epoch == 2)
    await recorder.stop()
}

// Host provenance is evidence, not a URL. Only a known browser's AXURL may
// produce a host, and a full URL must never be stored.
@Test func verifiedHostIsDerivedOnlyFromBrowserAXEvidence() {
    let safari = "com.apple.Safari"
    #expect(InputRecorder.verifiedHost(url: "https://mail.google.com/mail/u/0/#inbox", bundleID: safari) == "mail.google.com")
    #expect(InputRecorder.verifiedHost(url: "HTTPS://Mail.Google.com./path?q=1", bundleID: safari) == "mail.google.com")
    #expect(InputRecorder.verifiedHost(url: "mail.google.com", bundleID: safari) == "mail.google.com")
    #expect(InputRecorder.verifiedHost(url: "https://192.168.1.1/", bundleID: safari) == nil)
    #expect(InputRecorder.verifiedHost(url: "file:///Users/me/secret.txt", bundleID: safari) == nil)
    #expect(InputRecorder.verifiedHost(url: "about:blank", bundleID: safari) == nil)
    #expect(InputRecorder.verifiedHost(url: "https://mail.google.com.example.test/", bundleID: safari) == "mail.google.com.example.test")
    // A title or a non-browser app is not evidence.
    #expect(InputRecorder.verifiedHost(url: "https://mail.google.com/", bundleID: "com.apple.Mail") == nil)
    #expect(InputRecorder.verifiedHost(url: nil, bundleID: safari) == nil)
}

// The stock shape id must survive the event codec so preview/export can pick
// the same cursor art.
@Test func stockCursorShapeSurvivesEventCodec() {
    for shape in StockCursor.allCases {
        let event = InputEvent(t: 1, kind: .move, x: 3, y: 4, cursorShape: shape.rawValue)
        var bytes: [UInt8] = []
        EventCodec.encode(event, into: &bytes)
        let decoded = EventCodec.decode(Data(EventCodec.header()) + Data(bytes))
        #expect(decoded.count == 1)
        #expect(decoded.first?.cursorShape == shape.rawValue)
    }
    // A custom cursor id (1000+) is opaque to the codec and must not be
    // remapped to a stock shape.
    let custom = InputEvent(t: 1, kind: .move, cursorShape: 1000)
    var bytes: [UInt8] = []
    EventCodec.encode(custom, into: &bytes)
    let decoded = EventCodec.decode(Data(EventCodec.header()) + Data(bytes))
    #expect(decoded.first?.cursorShape == 1000)
}