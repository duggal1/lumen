import Foundation
import Testing
import os
import Synchronization
import CoreGraphics
import LumenCore

// Agent 3 — resolved intent frames crossing the core/runtime seam. These are
// the markers the planner can consume for a dialog/new-window/typing beat,
// with provenance intact (the rect is never invented from an unresolved AX
// sample).

@Test func intentFrameCarriesDialogProvenanceAcrossRoundTrip() throws {
    let intent = IntentFrame(id: "dialog-share", kind: .dialog,
                             startHostSeconds: 12.5, endHostSeconds: 15.0,
                             rect: CGRect(x: 520, y: 240, width: 560, height: 280),
                             label: "window|AXSheet|AXDialog|Share your card",
                             resolved: true, epoch: 3, sampledAt: 12.5,
                             windowID: 42, appName: "Browser")
    let data = try JSONEncoder().encode(intent)
    let restored = try JSONDecoder().decode(IntentFrame.self, from: data)
    #expect(restored == intent)
    #expect(restored.resolved)
    #expect(restored.epoch == 3)
    #expect(restored.label?.hasPrefix("window|") == true)
    #expect(restored.marker.rect == intent.rect)
    #expect(restored.marker.label == intent.label)
}

@Test func unresolvedIntentNeverClaimsAResolvedRect() throws {
    let intent = IntentFrame(id: "f", kind: .typing, startHostSeconds: 1, endHostSeconds: 1,
                             rect: nil, label: nil, resolved: false, epoch: 0,
                             sampledAt: 0, windowID: nil, appName: nil)
    #expect(!intent.resolved)
    #expect(intent.rect == nil)
    #expect(intent.marker.rect == nil)
    let data = try JSONEncoder().encode(intent)
    #expect(try JSONDecoder().decode(IntentFrame.self, from: data) == intent)
}

private final class MarkerRuntime: LumenRuntime {
    private let stored = OSAllocatedUnfairLock<[CaptureMarker]>(initialState: [])
    var markers: [CaptureMarker] { stored.withLock { $0 } }
    func runtimeStatus() async -> RuntimeStatus { RuntimeStatus() }
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {}
    func stopRecording() async throws -> URL { URL(fileURLWithPath: "/tmp/x") }
    func pauseRecording() async throws {}
    func resumeRecording() async throws {}
    func addMarker(_ marker: CaptureMarker) async throws { stored.withLock { $0.append(marker) } }
    func activeRecordingBundle() async -> URL? { nil }
    func recordingLibrary() async -> [URL] { [] }
}

@Test func runtimeRecordIntentReachesMarkerStream() async throws {
    let runtime = MarkerRuntime()
    let intent = IntentFrame(id: "w", kind: .newWindow, startHostSeconds: 2, endHostSeconds: 2,
                             rect: CGRect(x: 10, y: 20, width: 300, height: 200),
                             label: "window|AXWindow|AXStandardWindow|New Tab",
                             resolved: true, epoch: 2, sampledAt: 2, windowID: nil, appName: "Browser")
    try await runtime.recordIntent(intent)
    #expect(runtime.markers.count == 1)
    #expect(runtime.markers.first?.label == intent.label)
}
