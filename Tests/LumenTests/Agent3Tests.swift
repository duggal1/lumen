import Foundation
import Testing
import Metal
import CoreVideo
import LumenCore
import LumenProject
@testable import LumenDirector
@testable import LumenRender
@testable import LumenExport
@testable import LumenUI

// MARK: - Helpers

private final class FakePhotoHTTP: PhotoHTTP, @unchecked Sendable {
    var searchCalls = 0
    var downloadCalls = 0
    let searchPayload: Data
    let imageData: Data

    init(searchPayload: Data, imageData: Data) {
        self.searchPayload = searchPayload; self.imageData = imageData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://api.unsplash.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        if url.host == "api.unsplash.com" {
            searchCalls += 1
            return (searchPayload, response)
        }
        downloadCalls += 1
        return (imageData, response)
    }
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-agent3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func unsplashPayload(_ remote: String) -> Data {
    Data("""
    {"total":1,"results":[{"id":"photo-1","description":"Mountain ridge","width":4000,"height":3000,
    "urls":{"full":"\(remote)","regular":"\(remote)","small":"\(remote)"},
    "user":{"name":"A Photographer"}}]}
    """.utf8)
}

// A valid 1x1 PNG: the cache test proves bytes land on disk, not that they decode.
private let png1x1 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

// MARK: - Unsplash + photo background

@Test func unsplashSearchDownloadsOnceAndCachesTheFile() async throws {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let remote = "https://images.unsplash.com/photo-1"
    let http = FakePhotoHTTP(searchPayload: unsplashPayload(remote), imageData: png1x1)
    let service = PhotoBackgroundService(
        client: UnsplashClient(accessKey: "test-key", http: http),
        cache: PhotoCache(directory: dir))

    let first = try await service.fetch(query: "mountains")
    let second = try await service.fetch(query: "mountains")

    #expect(first == second)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(try Data(contentsOf: first) == png1x1)
    #expect(http.downloadCalls == 1, "the cached image must not be downloaded twice")
    #expect(http.searchCalls == 2, "search still runs; the image bytes are what is cached")
}

@Test func unsplashMissingKeyFailsLoudly() async {
    #expect(UnsplashCredentials.resolve(environment: [:], stored: nil) == nil)
    #expect(UnsplashCredentials.resolve(environment: ["LUMEN_UNSPLASH_ACCESS_KEY": "  key  "], stored: nil) == "key")
    #expect(UnsplashCredentials.resolve(environment: [:], stored: "stored") == "stored")

    let client = UnsplashClient(accessKey: "", http: FakePhotoHTTP(searchPayload: Data(), imageData: Data()))
    do {
        _ = try await client.search("anything")
        Issue.record("an empty key must throw")
    } catch {
        #expect(error as? UnsplashError == .missingKey)
    }
}

@Test func downloadedPhotoBecomesTheCanvasBackground() throws {
    var style = Style()
    style.setPhotoBackground("/tmp/photo.jpg")
    #expect(style.background == .image)
    #expect(style.backgroundImagePath == "/tmp/photo.jpg")

    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
    #expect(restored.background == .image)
    #expect(restored.backgroundImagePath == "/tmp/photo.jpg")
    #expect(BackgroundKind.offered.contains(.image))

    // Old projects without the new key still decode with a nil photo.
    let legacy = try JSONSerialization.data(withJSONObject: ["background": "solid"])
    #expect(try JSONDecoder().decode(Style.self, from: legacy).backgroundImagePath == nil)

    style.clearPhotoBackground()
    #expect(style.background == .solid)
    #expect(style.backgroundImagePath == nil)
}

// MARK: - MCP

@MainActor
private final class FakeMCPActions: MCPActions {
    var status = MCPStatus(phase: "idle", paused: false, recording: false, projects: 4)
    var started = 0, stopped = 0, paused = 0
    var opened: String?
    var exported: (String, String, String)?

    var mcpStatus: MCPStatus { status }
    func mcpStart() async throws { started += 1; status.phase = "recording"; status.recording = true }
    func mcpStop() async throws { stopped += 1; status.phase = "idle"; status.recording = false }
    func mcpPauseToggle() async throws { paused += 1; status.paused.toggle() }
    func mcpOpen(path: String) throws { opened = path }
    func mcpExport(project: String, preset: String, output: String) async throws -> String {
        exported = (project, preset, output); return output
    }
}

@MainActor
private func rpc(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@MainActor
@Test func mcpInitializeListsToolsAndCallsStatus() async throws {
    let actions = FakeMCPActions()
    let router = MCPRouter(actions: actions)

    let initLine = rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
    let initOut = try #require(await router.handle(initLine))
    let initJSON = try #require(try JSONSerialization.jsonObject(with: Data(initOut.utf8)) as? [String: Any])
    let result = try #require(initJSON["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == MCPRouter.protocolVersion)
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)

    let listLine = rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let listOut = try #require(await router.handle(listLine))
    let listJSON = try #require(try JSONSerialization.jsonObject(with: Data(listOut.utf8)) as? [String: Any])
    let listResult = try #require(listJSON["result"] as? [String: Any])
    let tools = try #require(listResult["tools"] as? [[String: Any]])
    let names = Set(tools.compactMap { $0["name"] as? String })
    #expect(names.contains("lumen_start_recording"))
    #expect(names.contains("lumen_stop_recording"))
    #expect(names.contains("lumen_export"))
    #expect(names.count == 6)

    let statusLine = rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                          "params": ["name": "lumen_status", "arguments": [:]]])
    let statusOut = try #require(await router.handle(statusLine))
    let statusJSON = try #require(try JSONSerialization.jsonObject(with: Data(statusOut.utf8)) as? [String: Any])
    let statusResult = try #require(statusJSON["result"] as? [String: Any])
    let content = try #require(statusResult["content"] as? [[String: Any]])
    #expect((content.first?["text"] as? String)?.contains("\"projects\":4") == true)
}

@MainActor
@Test func mcpRoutesRecordingAndExportActions() async throws {
    let actions = FakeMCPActions()
    let router = MCPRouter(actions: actions)

    let start = rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                     "params": ["name": "lumen_start_recording", "arguments": [:]]])
    _ = await router.handle(start)
    #expect(actions.started == 1)

    let pause = rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                     "params": ["name": "lumen_toggle_pause", "arguments": [:]]])
    _ = await router.handle(pause)
    #expect(actions.paused == 1)

    let export = rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                      "params": ["name": "lumen_export",
                                 "arguments": ["project": "/tmp/a.lumen", "output": "/tmp/a.mp4", "preset": "1080p60-h264"]]])
    _ = await router.handle(export)
    #expect(actions.exported?.0 == "/tmp/a.lumen")
    #expect(actions.exported?.1 == "1080p60-h264")
    #expect(actions.exported?.2 == "/tmp/a.mp4")
}

@MainActor
@Test func mcpErrorsAreJSONRPCShapedAndNotificationsStaySilent() async throws {
    let router = MCPRouter(actions: FakeMCPActions())
    let unknown = rpc(["jsonrpc": "2.0", "id": 7, "method": "does/not/exist"])
    let out = try #require(await router.handle(unknown))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32601)

    let notification = rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])
    #expect(await router.handle(notification) == nil)
}

// MARK: - Email

private final class SpyEmailTransport: EmailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EmailMessage] = []
    var messages: [EmailMessage] { lock.withLock { storage } }

    func send(_ message: EmailMessage) async throws {
        lock.withLock { storage.append(message) }
    }
}

@Test func emailTriggerRespectsOptInAndSendsOneDraftPerEvent() async throws {
    let name = "lumen.email.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var prefs = EmailPreferences(enabled: true, recipient: "  editor@example.com ",
                                 onRecordingFinished: true, onExportFinished: false)
    prefs.save(defaults: defaults)

    let spy = SpyEmailTransport()
    let service = EmailNotificationService(transport: spy, defaults: defaults)

    #expect(await service.recordingFinished(project: URL(fileURLWithPath: "/tmp/Demo.lumen"), duration: 83))
    #expect(spy.messages.count == 1)
    #expect(spy.messages[0].to == "editor@example.com")
    #expect(spy.messages[0].subject.contains("Demo"))
    #expect(spy.messages[0].body.contains("1:23"))

    // Export notifications are off in these preferences.
    #expect(await service.exportFinished(file: URL(fileURLWithPath: "/tmp/Demo.mp4")) == false)
    #expect(spy.messages.count == 1)

    var disabled = prefs; disabled.enabled = false; disabled.save(defaults: defaults)
    #expect(await service.recordingFinished(project: URL(fileURLWithPath: "/tmp/Other.lumen"), duration: 2) == false)
    #expect(spy.messages.count == 1)
}

@Test func mailtoDraftEncodesSubjectAndBody() throws {
    let message = EmailMessage(to: "a@example.com", subject: "Recording finished: Demo",
                               body: "Line one\nLine two")
    let url = try #require(message.mailtoURL)
    #expect(url.scheme == "mailto")
    #expect(url.path == "a@example.com")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.first { $0.name == "subject" }?.value == message.subject)
    #expect(items.first { $0.name == "body" }?.value == message.body)
}

// MARK: - Background polish

@Test func independentPaddingRadiiAndShadowSurviveRoundTrip() throws {
    var style = Style()
    style.background = .mesh
    style.paddingInsets = EdgeInsetsN(top: 0.10, right: 0.02, bottom: 0.04, left: 0.18)
    style.cornerRadii = CornerRadii(tl: 4, tr: 8, br: 12, bl: 16)
    style.shadow = 0.82

    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
    #expect(restored.paddingInsets == style.paddingInsets)
    #expect(restored.cornerRadii == style.cornerRadii)
    #expect(restored.shadow == style.shadow)

    let geometry = Geometry(canvas: SIMD2(1920, 1080), src: SIMD2(1920, 1080), style: restored)
    #expect(geometry.content.x > 300, "left inset must push the frame right")
    #expect(geometry.content.x + geometry.content.z < 1900, "right inset must shrink the frame")
    #expect(geometry.radii.x > geometry.radii.y)
    #expect(geometry.radii.w > geometry.radii.z)
}

@Test func offeredBackdropsAndPalettesStayBrandConsistent() {
    #expect(BackgroundKind.offered.contains(.solid))
    #expect(BackgroundKind.offered.contains(.wallpaper))
    #expect(BackgroundKind.offered.contains(.image))
    #expect(DitherPalettes.all.count >= 8)
    #expect(Set(DitherPalettes.all.map(\.0)).count == DitherPalettes.all.count)
    #expect(DitherPalettes.all.allSatisfy { $0.1.count == 2 })
    #expect(ZoomPreset.cinematic.maxScale == 2.6)
    var camera = CameraParams()
    camera.apply(preset: .cinematic)
    #expect(camera.tilt == .lean)
    #expect(camera.maxScale == 2.6)
}

// MARK: - Frame budget

@Test func frameBudgetPassesSixtyFPSAndFailsHalfRate() {
    let sixty = FrameBudget(fps: 60)
    let pass = sixty.evaluate([15, 14, 16, 12, 15.5, 14.5, 16, 15, 13, 14])
    #expect(pass.passes)
    #expect(pass.overBudget == 0)

    let fail = sixty.evaluate([33, 34, 33, 33, 34, 33, 33, 34])
    #expect(!fail.passes)
    #expect(fail.overBudget == 8)
    #expect(fail.p99Ms > sixty.budgetMilliseconds)

    let empty = sixty.evaluate([])
    #expect(!empty.passes, "no measurements is never a pass")
}

@Test func renderBenchmarkRunsRealMetalFrames() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let result = try RenderBenchmark.run(frames: 4, width: 320, height: 180, fps: 60)
    #expect(result.frames == 4)
    #expect(result.report.frames == 4)
    #expect(result.report.p99Ms.isFinite)
    #expect(!result.report.summary.isEmpty)
}

// MARK: - Sync harness

private func syncTimeline(cut: ClosedRange<Double>? = nil) -> (Timeline, [InputEvent]) {
    var tl = Timeline(duration: 10)
    tl.audio.speedRampsAuto = false
    if let cut { tl.timeMap.cuts = [CutRange(start: cut.lowerBound, end: cut.upperBound)] }
    let events = [
        InputEvent(t: 1, kind: .down, x: 300, y: 300),
        InputEvent(t: 3, kind: .down, x: 500, y: 500),   // inside the cut when cut = 2...4
        InputEvent(t: 5, kind: .down, x: 700, y: 400),
        InputEvent(t: 9, kind: .down, x: 900, y: 600),
    ]
    return (tl, events)
}

@Test func flashAndClickStayOnTheSameFrameAcrossCuts() throws {
    let (timeline, events) = syncTimeline(cut: 2...4)
    let derived = Director.derive(timeline, input: DirectorInput(events: events,
                                                               source: SourceInfo(width: 1920, height: 1080, fps: 60,
                                                                                  duration: 10, backingScale: 1, originX: 0, originY: 0)),
                                  revision: 1)
    let report = SyncHarness.measure(derived, events: events, fps: 60)
    #expect(report.passes, "\(report.summary)")
    #expect(report.clicks.count == 3, "the click inside the cut has no output frame")
    #expect(report.maxDriftMs < 1)
    #expect(report.maxCueDriftMs < 1)
    #expect(report.earlyFlashes == 0)
    #expect(report.lateFlashes == 0)
}

@Test func syncHarnessCatchesAShiftedClickCue() throws {
    let (timeline, events) = syncTimeline()
    var derived = Director.derive(timeline, input: DirectorInput(events: events,
                                                               source: SourceInfo(width: 1920, height: 1080, fps: 60,
                                                                                  duration: 10, backingScale: 1, originX: 0, originY: 0)),
                                  revision: 1)
    guard var tracks = derived.derived else { Issue.record("no derived tracks"); return }
    tracks.cues = tracks.cues.map { SFXCue(t: $0.t + 0.02, kind: $0.kind, gainDb: $0.gainDb) }
    derived.derived = tracks

    let report = SyncHarness.measure(derived, events: events, fps: 60)
    #expect(!report.passes)
    #expect(report.maxCueDriftMs > 1, "a 20 ms audio shift must fail the harness")
}

// MARK: - Golden images

@Test func goldenComparisonDetectsChangedPixelsAndSizeMismatch() {
    let base = GoldenImage(width: 2, height: 1, pixels: [255, 0, 0, 255, 0, 255, 0, 255])
    #expect(GoldenComparison.compare(base, base).passes(tolerance: 0))

    var changed = base.pixels
    changed[1] = 40
    let diff = GoldenComparison.compare(base, GoldenImage(width: 2, height: 1, pixels: changed))
    #expect(diff.differingPixels == 1)
    #expect(diff.maxChannelDelta == 40)
    #expect(!diff.passes())

    let resized = GoldenComparison.compare(base, GoldenImage(width: 1, height: 1, pixels: [255, 0, 0, 255]))
    #expect(resized.differingFraction == 1)
    #expect(!resized.passes())
}

@Test func goldenPNGRoundTripsAndCapturesFromPixelBuffer() throws {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = GoldenImage(width: 2, height: 2, pixels: [
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    ])
    let url = dir.appendingPathComponent("frame.png")
    try image.writePNG(url)
    let loaded = try GoldenImage.loadPNG(url)
    #expect(GoldenComparison.compare(image, loaded).passes(tolerance: 0))

    // Real 32BGRA path used by the CLI golden harness.
    guard let pb = makeBGRABuffer(width: 2, height: 2) else { return }
    let captured = try GoldenImage(pixelBuffer: pb)
    #expect(captured.width == 2 && captured.height == 2)
    #expect(captured.pixels[0] == 0 && captured.pixels[2] == 255, "BGRA source must become RGBA")
}

private func makeBGRABuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let p = base.assumingMemoryBound(to: UInt8.self)
    // pixel 0: B=0 G=0 R=255, pixel 1: B=255 G=255 R=255
    p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255
    p[4] = 255; p[5] = 255; p[6] = 255; p[7] = 255
    return pb
}
