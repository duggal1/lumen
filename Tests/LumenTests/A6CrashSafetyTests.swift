import Testing
import Foundation
import LumenCore
import LumenProject
import LumenCapture
import LumenControl

/// A6 — crash safety gates. These exercise the *real* on-disk primitives the
/// recorder uses, not mocks: incremental segment writes, torn-tail recovery,
/// the recovery journal, and fail-closed permission reporting. They run with
/// no Screen Recording / Accessibility permission and no live capture session.
@Suite struct A6CrashSafetyTests {
    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-a6-crash-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func source(duration: Double = 30) -> SourceInfo {
        SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                   backingScale: 1, originX: 0, originY: 0)
    }

    static func record(_ t: Double, w: Double = 100, h: Double = 80) -> ViewportRecord {
        ViewportRecord(t: t, flags: [.browserFront, .webValid],
                       window: PxRect(x: 0, y: 0, w: w, h: h),
                       web: PxRect(x: 4, y: 8, w: 80, h: 60))
    }

    // MARK: - Incremental segment writes

    @Test func viewportWriterOnlyPersistsAfterFlush() throws {
        let dir = try Self.tempDir("incremental")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("viewport.bin")
        let writer = try ViewportLog.Writer(url: url)

        writer.append(Self.record(1))
        // Pending records live in the writer's buffer; a crash here must not
        // expose a half-written segment to the reader.
        #expect(ViewportLog.read(url).isEmpty, "append must not write through before flush")

        writer.flush(sync: true)
        let first = ViewportLog.read(url)
        #expect(first.count == 1, "flush must publish a whole segment")
        #expect(first.first == Self.record(1))

        writer.append(Self.record(2))
        #expect(ViewportLog.read(url).count == 1, "second segment stays buffered until flush")
        writer.close()
        #expect(ViewportLog.read(url) == [Self.record(1), Self.record(2)])
    }

    @Test func tornTailRecordIsIgnoredThenPhysicallyRemoved() throws {
        let dir = try Self.tempDir("torn")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("viewport.bin")
        let writer = try ViewportLog.Writer(url: url)
        writer.append(Self.record(1))
        writer.append(Self.record(2))
        writer.close()
        let wholeSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber

        // Simulate a crash between writes: a partial trailing record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: ViewportLog.stride - 3))
        try handle.synchronize()
        try handle.close()

        #expect(ViewportLog.read(url) == [Self.record(1), Self.record(2)], "torn tail must be ignored")
        ViewportLog.truncateToWholeRecords(at: url)
        let repairedSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(repairedSize == wholeSize, "truncation must restore the whole-record length")
        #expect(ViewportLog.read(url).count == 2)
        ViewportLog.truncateToWholeRecords(at: url) // idempotent
        #expect(ViewportLog.read(url).count == 2)
    }

    @Test func hostileViewportFilesNeverCrashRecovery() throws {
        let dir = try Self.tempDir("hostile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let badMagic = dir.appendingPathComponent("magic.bin")
        try Data("NOPE".utf8).write(to: badMagic)
        let partialMagic = dir.appendingPathComponent("partial.bin")
        try Data("LVP".utf8).write(to: partialMagic)
        let magicOnly = dir.appendingPathComponent("header.bin")
        try ViewportLog.magic.write(to: magicOnly)

        for url in [empty, badMagic, partialMagic, magicOnly] {
            #expect(ViewportLog.read(url).isEmpty)
            ViewportLog.truncateToWholeRecords(at: url)
            #expect((try? Data(contentsOf: url)) != nil, "recovery must not delete a hostile file")
        }
    }

    // MARK: - Recovery journal (partial take survives interruption)

    @Test func journalCheckpointRecoversPartialTake() throws {
        let dir = try Self.tempDir("checkpoint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(named: "Crashed", in: dir)
        try Data("system".utf8).write(to: bundle.systemURL)
        let crop = SmartCropConfig(enabled: true, roi: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9))
        let journal = RecordingJournal(
            started: Date().addingTimeInterval(-30), updated: Date().addingTimeInterval(-1),
            source: Self.source(), fps: 60, mic: false, system: true, webcam: false,
            pauseIntervals: [PauseInterval(start: 14, end: 16)],
            lastFramePTS: 22.5, firstFramePTS: 10, droppedFrames: 7, smartCrop: crop)
        try bundle.writeJournal(journal).get()
        #expect(bundle.isUnfinished)

        let recovered = try #require(try bundle.recoverFromJournal())
        #expect(abs(recovered.meta.source.duration - 12.5) < 1e-6, "checkpoint duration = 22.5 - 10")
        #expect(recovered.meta.droppedFrames == 7)
        #expect(recovered.meta.system != nil, "existing system track is relinked")
        #expect(recovered.timeline.smartCrop == crop, "Area crop survives the crash")
        #expect(recovered.timeline.timeMap.cuts.contains { $0.start == 4 && $0.end == 6 },
                "paused span replays as a cut in project time")
        #expect(!bundle.isUnfinished, "recovery consumes the journal")
        #expect(try bundle.recoverFromJournal() == nil, "recovery is idempotent")
        #expect(try bundle.load().timeline.smartCrop == crop)
    }

    @Test func displayChangeCapsRecoveredDurationToPlayableFootage() throws {
        let dir = try Self.tempDir("dsize-crash")
        defer { try? FileManager.default.removeItem(at: dir) }
        func crashed(_ name: String) throws -> ProjectBundle {
            let b = try ProjectBundle.create(named: name, in: dir)
            try b.writeJournal(RecordingJournal(
                source: Self.source(), fps: 60, mic: false, system: false, webcam: false,
                lastFramePTS: 12.5, firstFramePTS: 0)).get()
            return b
        }
        // A display reconfigure mid-take can leave the writer with more frames
        // than are actually playable; recovery must never claim the larger span.
        let capped = try crashed("Capped")
        let short = try #require(try capped.recoverFromJournal(playableScreenDuration: 8))
        #expect(abs(short.meta.source.duration - 8) < 1e-6)

        for (name, value) in [("Zero", 0.0), ("Negative", -1), ("NaN", Double.nan), ("Infinite", Double.infinity)] {
            let b = try crashed(name)
            #expect(try b.recoverFromJournal(playableScreenDuration: value) == nil,
                    "hostile playable duration \(value) must be refused")
            #expect(b.isUnfinished, "a refused recovery leaves the journal for a later retry")
        }
    }

    @Test func checkpointWithoutUsableFramesIsNotRecovered() throws {
        let dir = try Self.tempDir("noframes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(named: "EmptyCrash", in: dir)
        try bundle.writeJournal(RecordingJournal(
            source: Self.source(), fps: 60, mic: false, system: false, webcam: false,
            lastFramePTS: 5, firstFramePTS: 5)).get()
        #expect(try bundle.recoverFromJournal() == nil, "zero-duration take is not a project")
        #expect(bundle.isUnfinished, "journal stays so a later scan can retry")

        let badOrder = RecordingJournal(source: Self.source(), fps: 60, mic: false, system: false,
                                        webcam: false, lastFramePTS: 1, firstFramePTS: 2)
        #expect((try? bundle.writeJournal(badOrder).get()) == nil, "first frame after last is rejected")
        let badDrops = RecordingJournal(source: Self.source(), fps: 60, mic: false, system: false,
                                        webcam: false, lastFramePTS: 5, droppedFrames: -1)
        #expect((try? bundle.writeJournal(badDrops).get()) == nil, "negative dropped count is rejected")
    }

    @Test func malformedJournalNeverPoisonsRecovery() throws {
        let dir = try Self.tempDir("badjournal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(named: "Malformed", in: dir)
        try Data("not json".utf8).write(to: bundle.journalURL)
        #expect((try? bundle.readJournal()) == nil, "a malformed journal must not decode")
        #expect((try? bundle.recoverFromJournal()) == nil)

        var future = RecordingJournal(source: Self.source(), fps: 60, mic: false, system: false,
                                      webcam: false, lastFramePTS: 5)
        future.schemaVersion = 99
        #expect((try? bundle.writeJournal(future).get()) == nil, "unknown schema is refused on write")
    }

    @Test func recoveryScannerFindsInterruptedTakeInLibrary() throws {
        let dir = try Self.tempDir("scan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let crashed = try ProjectBundle.create(named: "Interrupted", in: dir)
        try crashed.writeJournal(RecordingJournal(
            source: Self.source(), fps: 60, mic: false, system: false, webcam: false,
            lastFramePTS: 4)).get()
        _ = try ProjectBundle.create(named: "Finished", in: dir)
        let found = RecoveryScanner.scan(library: dir)
        #expect(Set(found.map(\.url.lastPathComponent)) == ["Interrupted.lumen"])
    }

    // MARK: - Permission loss / low disk (fail closed, keep footage)

    @Test func permissionSnapshotIsFailClosed() {
        let snapshot = PermissionSnapshot()
        #expect(!snapshot.screen && !snapshot.input && !snapshot.accessibility)
        #expect(!snapshot.mic && !snapshot.camera)
    }

    @Test func permissionLossReportsExactRecoveryPane() {
        let screen = ToolError.permission("screen recording", pane: "ScreenCapture")
        #expect(screen.code.contains("PERMISSION"))
        #expect(screen.hint.contains("human must grant"), "agent is told to escalate, not work around")
        #expect(screen.deepLink?.contains("Privacy_ScreenCapture") == true)
        let input = ToolError.permission("input monitoring", pane: "ListenEvent")
        #expect(input.deepLink?.contains("Privacy_ListenEvent") == true)
        #expect(input.deepLink != screen.deepLink, "each lost permission names its own pane")
    }

    @Test func diskFullFinalizeKeepsRecoverableProjectAndRawFootage() throws {
        let dir = try Self.tempDir("diskfull")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(named: "DiskFull", in: dir)
        try Data("screen".utf8).write(to: bundle.screenURL)
        try bundle.writeJournal(RecordingJournal(
            source: Self.source(), fps: 60, mic: false, system: false, webcam: false,
            lastFramePTS: 6, firstFramePTS: 1)).get()
        // The watchdog's disk-full path marks the take failed and finalizes.
        bundle.markFailed()
        let recovered = try #require(try bundle.recoverFromJournal())
        #expect(abs(recovered.meta.source.duration - 5) < 1e-6)
        #expect(FileManager.default.fileExists(atPath: bundle.projectURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.screenURL.path))

        let withinGrace = RawFootageSweep.sweep(library: dir, now: Date())
        #expect(withinGrace.retained.contains("DiskFull.lumen"), "interrupted raw footage gets grace")
        #expect(FileManager.default.fileExists(atPath: bundle.screenURL.path))

        let pastGrace = RawFootageSweep.sweep(
            library: dir, now: Date().addingTimeInterval(Double(RawFootageSweep.failedGraceDays + 1) * 86_400))
        #expect(pastGrace.deleted.contains("DiskFull.lumen"))
        #expect(!FileManager.default.fileExists(atPath: bundle.screenURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.projectURL.path), "project is never swept")
    }
}
