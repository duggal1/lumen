import Foundation
import Testing
import Metal
import AVFoundation
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio
import LumenControl
@testable import LumenRender

/// M2 — agent video-edit tools. Every test drives a real `ToolRegistry` against
/// a real `Engine` with a real encoded MP4 and reads state back from disk.
@Suite(.serialized)
struct MCPVideoEditToolsTests {
    // MARK: Fixture

    private final class HeadlessRuntime: LumenRuntime {
        func runtimeStatus() async -> RuntimeStatus {
            RuntimeStatus(phase: "idle", paused: false, recording: false,
                          permissions: RuntimePermissions(), libraryPath: "/tmp/Lumen",
                          projects: 0, activeProjectPath: nil, version: "0.1.0")
        }
        func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {
            throw RuntimeFailure("Not used by this test.")
        }
        func stopRecording() async throws -> URL { throw RuntimeFailure("Not used by this test.") }
        func pauseRecording() async throws {}
        func resumeRecording() async throws {}
        func addMarker(_ marker: CaptureMarker) async throws {}
        func activeRecordingBundle() async -> URL? { nil }
        func recordingLibrary() async -> [URL] { [] }
    }

    private struct Fixture {
        let root: URL
        let bundle: ProjectBundle
        let projectID: String
        let registry: ToolRegistry
        let engine: Engine
        let jobs: JobManager
        let audit: AuditLog
        let policy: Policy
        let musicURL: URL

        var context: ToolContext {
            ToolContext(engine: engine, policy: policy, jobs: jobs, audit: audit,
                        clientID: "m2-test", dryRun: false)
        }
    }

    private func writeScreen(_ url: URL, w: Int, h: Int, fps: Int, seconds: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * fps) {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &buffer) == kCVReturnSuccess,
                let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, i % 10 < 5 ? 60 : 200, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private func makeFixture() async throws -> Fixture {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw RuntimeFailure("No Metal device; cannot open a real project headlessly.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-m2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try ProjectBundle.create(named: "EditMe", in: root)
        try writeScreen(bundle.screenURL, w: 320, h: 180, fps: 30, seconds: 1)
        let quiet = [Float](repeating: 0, count: Int(AudioIO.fs))
        try AudioIO.writeCAF(quiet, quiet, to: bundle.micURL)
        let musicURL = root.appendingPathComponent("music.caf")
        let tone = [Float](repeating: 0.01, count: Int(AudioIO.fs))
        try AudioIO.writeCAF(tone, tone, to: musicURL)

        var meta = ProjectMeta(
            name: "EditMe",
            source: SourceInfo(width: 320, height: 180, fps: 30, duration: 1,
                               backingScale: 1, originX: 0, originY: 0),
            clock: RecordingClock())
        meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)

        var timeline = Timeline(duration: 1)
        timeline.audio.speedRampsAuto = false
        timeline.audio.clickSounds = false
        timeline.camera.autoZoom = false
        timeline.overlays.privacy.enabled = false
        timeline.overlays.privacy.autoDetect = false
        timeline.clips = [
            TimelineClip(path: bundle.screenURL.path, name: "A", duration: 1, start: 1, width: 320, height: 180),
            TimelineClip(path: bundle.screenURL.path, name: "B", duration: 1, start: 2, width: 320, height: 180),
        ]
        var eventBytes = EventCodec.header()
        var record = [UInt8]()
        for event in [InputEvent(t: 0.2, kind: .down, x: 50, y: 50),
                      InputEvent(t: 0.21, kind: .up, x: 50, y: 50)] {
            record.removeAll()
            EventCodec.encode(event, into: &record)
            eventBytes.append(contentsOf: record)
        }
        try eventBytes.write(to: bundle.eventsURL)
        try bundle.save(ProjectFile(meta: meta, timeline: timeline))

        let policy = Policy(fileURL: root.appendingPathComponent("policy.json"))
        policy.grant(client: "m2-test", capabilities: ["read", "edit", "export"], paths: [root.path])
        let jobs = JobManager()
        let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
        let engine = Engine(runtime: HeadlessRuntime(), jobs: jobs, policy: policy)
        let ref = try await engine.openProject(at: bundle.url.path)
        let registry = ToolRegistry()
        registry.registerVideoEditTools()
        return Fixture(root: root, bundle: bundle, projectID: ref.identifier, registry: registry,
                       engine: engine, jobs: jobs, audit: audit, policy: policy, musicURL: musicURL)
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func call(_ name: String, _ args: [String: Any] = [:],
                      on fixture: Fixture, dryRun: Bool = false,
                      includeProject: Bool = true) async throws -> JSONValue {
        var dict = args
        if includeProject { dict["project_id"] = fixture.projectID }
        let value = JSONValue.object(dict.mapValues { JSONValue(any: $0) })
        let context = ToolContext(engine: fixture.engine, policy: fixture.policy, jobs: fixture.jobs,
                                  audit: fixture.audit, clientID: "m2-test", dryRun: dryRun)
        return try await fixture.registry.call(name, arguments: value, context: context)
    }

    private func readback(_ fixture: Fixture) async throws -> JSONValue {
        try await call("get_edit", on: fixture)
    }

    private func count(_ json: JSONValue, _ key: String) -> Int {
        json[key]?.arrayValue?.count ?? -1
    }

    private func expectInvalid(code: String = "INVALID_ARGUMENTS",
                               _ body: () async throws -> JSONValue) async {
        do {
            _ = try await body()
            Issue.record("Expected ToolError \(code)")
        } catch let error as ToolError {
            #expect(error.code == code)
        } catch {
            Issue.record("Expected ToolError, got \(error)")
        }
    }

    // MARK: Catalog

    @Test func catalogIsTypedGatedAndIdempotencyAware() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let specs = Dictionary(uniqueKeysWithValues: fixture.registry.allSpecs().map { ($0.name, $0) })
        let expected: [String: Capability] = [
            "cut_span": .edit, "split_clip": .edit, "trim_clip": .edit,
            "reorder_clips": .edit, "set_speed": .edit, "add_music": .edit,
            "remove_music": .edit, "add_caption": .edit, "set_zoom": .edit,
            "get_edit": .read, "render_preview": .read, "export_final": .export,
        ]
        for (name, capability) in expected {
            let spec = try #require(specs[name], "missing tool \(name)")
            #expect(spec.capability == capability)
            #expect(spec.required.contains("project_id"))
            #expect(spec.mutating == (capability != .read))
            #expect(spec.title == name.replacingOccurrences(of: "_", with: " "))
            let schema = spec.inputSchema.objectValue
            #expect(schema?["type"]?.stringValue == "object")
            #expect(schema?["additionalProperties"]?.boolValue == false)
            #expect(schema?["properties"]?.objectValue?.isEmpty == false)
            if name != "get_edit" && name != "render_preview" && name != "export_final" {
                #expect(spec.outputSchema != nil, "\(name) must publish a stable result shape")
            }
        }
        #expect(specs["cut_span"]?.idempotent == false)
        #expect(specs["trim_clip"]?.idempotent == true)
        #expect(specs["remove_music"]?.idempotent == true)
        #expect(specs["get_edit"]?.idempotent == true)
    }

    // MARK: Real edits

    @Test func cutSpanChangesStateAndReadsBack() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        let originalDuration = before["output_duration"]?.doubleValue ?? 0
        let result = try await call("cut_span", ["start": 0.2, "end": 0.4, "basis": "source"], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        #expect(result["revision"]?.intValue == (before["revision"]?.intValue ?? 0) + 1)
        #expect(result["diff"]?.arrayValue?.isEmpty == false)
        #expect(result["before"]?["cuts"]?.arrayValue?.count == 0)
        #expect(result["after"]?["cuts"]?.arrayValue?.count == 1)
        let after = try await readback(fixture)
        #expect(count(after, "cuts") == 1)
        // Imported clips pin composition duration; the recording's own edited
        // length is the honest measure of a cut.
        #expect((after["output_duration"]?.doubleValue ?? 0) < originalDuration - 0.1)
    }

    @Test func splitClipPartitionsWithoutChangingDuration() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        let result = try await call("split_clip", ["at": 1.5, "basis": "output"], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        #expect(result["before"]?["clips"]?.arrayValue?.count == 2)
        #expect(result["after"]?["clips"]?.arrayValue?.count == 3)
        let after = try await readback(fixture)
        #expect(count(after, "clips") == 3)
        #expect(after["duration"]?.doubleValue == before["duration"]?.doubleValue)
    }

    @Test func trimClipMovesOnlyTheNamedEdgesAndIsIdempotent() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        let clips = try #require(before["clips"]?.arrayValue)
        let a = try #require(clips.first { $0["name"]?.stringValue == "A" })
        let clipID = try #require(a["id"]?.stringValue)
        let result = try await call("trim_clip", ["clip_id": clipID, "start": 1.2, "end": 1.8], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        let after = try await readback(fixture)
        let trimmed = try #require(after["clips"]?.arrayValue?.first { $0["id"]?.stringValue == clipID })
        #expect(trimmed["start"]?.doubleValue == 1.2)
        #expect(abs((trimmed["duration"]?.doubleValue ?? 0) - 0.6) < 1e-6)
        // Magnetic lane ripples the following clip left to close the new gap.
        let other = try #require(after["clips"]?.arrayValue?.first { $0["name"]?.stringValue == "B" })
        #expect(other["start"]?.doubleValue == 1.8)
        let again = try await call("trim_clip", ["clip_id": clipID, "start": 1.2, "end": 1.8], on: fixture)
        #expect(again["changed"]?.boolValue == false)
    }

    @Test func reorderClipsPersistsAndIsIdempotent() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        let clips = try #require(before["clips"]?.arrayValue)
        let a = try #require(clips.first { $0["name"]?.stringValue == "A" })["id"]?.stringValue
        let b = try #require(clips.first { $0["name"]?.stringValue == "B" })["id"]?.stringValue
        let result = try await call("reorder_clips", ["ordered_ids": [b, a]], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        let after = try await readback(fixture)
        #expect(after["clips"]?.arrayValue?.map { $0["name"]?.stringValue ?? "" } == ["B", "A"])
        let again = try await call("reorder_clips", ["ordered_ids": [b, a]], on: fixture)
        #expect(again["changed"]?.boolValue == false)
    }

    @Test func setSpeedAddsRampAndRejectsHostileSpeeds() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let result = try await call("set_speed", ["start": 0.2, "end": 0.6, "speed": 2, "basis": "source"], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        #expect(result["after"]?["ramps"]?.arrayValue?.count == 1)
        let again = try await call("set_speed", ["start": 0.2, "end": 0.6, "speed": 2, "basis": "source"], on: fixture)
        #expect(again["changed"]?.boolValue == false)
        await expectInvalid { try await self.call("set_speed", ["start": 0.2, "end": 0.6, "speed": 0], on: fixture) }
        await expectInvalid { try await self.call("set_speed", ["start": 0.2, "end": 0.6, "speed": 100], on: fixture) }
        await expectInvalid { try await self.call("set_speed", ["start": 0.6, "end": 0.2, "speed": 2], on: fixture) }
        #expect(count(try await readback(fixture), "ramps") == 1)
    }

    @Test func musicAddRemoveIsIdempotentAndPathConfined() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let result = try await call("add_music", ["path": fixture.musicURL.path, "gain_db": -20], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        #expect((try await readback(fixture))["music_path"]?.stringValue == fixture.musicURL.path)
        let again = try await call("add_music", ["path": fixture.musicURL.path, "gain_db": -20], on: fixture)
        #expect(again["changed"]?.boolValue == false)
        await expectInvalid(code: "PATH_NOT_ALLOWED") {
            try await self.call("add_music", ["path": "../../etc/passwd.mp3"], on: fixture)
        }
        let removed = try await call("remove_music", on: fixture)
        #expect(removed["changed"]?.boolValue == true)
        #expect((try await readback(fixture))["music_path"]?.isNull == true)
        let repeatRemove = try await call("remove_music", on: fixture)
        #expect(repeatRemove["changed"]?.boolValue == false)
    }

    @Test func addCaptionPersistsATextBlock() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let result = try await call("add_caption", ["text": "Hello from M2", "start": 0.2, "end": 0.6], on: fixture)
        #expect(result["changed"]?.boolValue == true)
        let after = try await readback(fixture)
        #expect(count(after, "texts") == 1)
        #expect(after["texts"]?.arrayValue?.first?["text"]?.stringValue == "Hello from M2")
        await expectInvalid { try await self.call("add_caption", ["text": ""], on: fixture) }
        await expectInvalid {
            try await self.call("add_caption", ["text": String(repeating: "x", count: 501)], on: fixture)
        }
    }

    @Test func setZoomAddsAndEditsAndIsIdempotent() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let added = try await call("set_zoom", ["start": 0.2, "end": 0.6, "scale": 2, "basis": "source"], on: fixture)
        #expect(added["changed"]?.boolValue == true)
        let zooms = try #require((try await readback(fixture))["zoom"]?.arrayValue)
        let id = try #require(zooms.first?["id"]?.stringValue)
        let edited = try await call("set_zoom", ["id": id, "scale": 2.5], on: fixture)
        #expect(edited["changed"]?.boolValue == true)
        #expect((try await readback(fixture))["zoom"]?.arrayValue?.first?["scale"]?.doubleValue == 2.5)
        let again = try await call("set_zoom", ["id": id, "scale": 2.5], on: fixture)
        #expect(again["changed"]?.boolValue == false)
        await expectInvalid {
            try await self.call("set_zoom", ["start": 0.2, "end": 0.6, "scale": 10], on: fixture)
        }
        await expectInvalid {
            try await self.call("set_zoom", ["start": 0.2, "end": 0.6, "focus_mode": "magic"], on: fixture)
        }
    }

    // MARK: Failure paths

    @Test func dryRunValidatesWithoutPersisting() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        let result = try await call("cut_span", ["start": 0.2, "end": 0.4], on: fixture, dryRun: true)
        #expect(result["dry_run"]?.boolValue == true)
        #expect(result["after"]?["cuts"]?.arrayValue?.count == 1)
        let after = try await readback(fixture)
        #expect(after["revision"]?.intValue == before["revision"]?.intValue)
        #expect(count(after, "cuts") == count(before, "cuts"))
    }

    @Test func hostileArgumentsNeverMutateTheProject() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let before = try await readback(fixture)
        await expectInvalid { try await self.call("cut_span", [:], on: fixture, includeProject: false) }
        await expectInvalid { try await self.call("cut_span", ["start": -1, "end": 0.4], on: fixture) }
        await expectInvalid { try await self.call("split_clip", ["at": 99], on: fixture) }
        await expectInvalid { try await self.call("trim_clip", ["clip_id": "not-a-uuid"], on: fixture) }
        await expectInvalid {
            try await self.call("reorder_clips", ["ordered_ids": ["nope", "nope"]], on: fixture)
        }
        await expectInvalid { try await self.call("add_caption", ["text": "x", "start": -2], on: fixture) }
        await expectInvalid { try await self.call("set_zoom", ["id": "not-a-uuid", "scale": 2], on: fixture) }
        await expectInvalid(code: "FAILED") { try await self.call("get_edit", ["project_id": "p_missing"], on: fixture, includeProject: false) }
        let after = try await readback(fixture)
        #expect(after["revision"]?.intValue == before["revision"]?.intValue)
        #expect(after["clips"]?.arrayValue?.count == before["clips"]?.arrayValue?.count)
    }

    // MARK: Verification and output

    @Test func renderPreviewReturnsRealPixels() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let jpeg = try await call("render_preview", ["time": 0.5, "max_width": 160], on: fixture)
        let encoded = try #require(jpeg["image_base64"]?.stringValue)
        #expect(!encoded.isEmpty)
        #expect(jpeg["mime_type"]?.stringValue == "image/jpeg")
        #expect((jpeg["width"]?.intValue ?? 0) > 0)
        #expect(Data(base64Encoded: encoded)?.isEmpty == false)
        let png = try await call("render_preview", ["time": 0.5, "max_width": 160, "png": true], on: fixture)
        #expect(png["mime_type"]?.stringValue == "image/png")
        await expectInvalid { try await self.call("render_preview", ["time": -3], on: fixture) }
    }

    @Test func exportFinalWritesARealMP4() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let output = fixture.root.appendingPathComponent("final.mp4")
        let result = try await call("export_final", [
            "output": output.path, "preset": "1080p30-h264", "wait": true,
        ], on: fixture)
        #expect(result["output"]?.stringValue == output.path)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)
        #expect(size.intValue > 0)
        await expectInvalid(code: "EXPORT_OUTPUT_EXISTS") {
            try await self.call("export_final", ["output": output.path], on: fixture)
        }
        await expectInvalid {
            try await self.call("export_final", ["output": output.path, "preset": "not-a-preset"], on: fixture)
        }
    }
}
