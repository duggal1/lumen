import Foundation
import Testing
import LumenCore
import LumenProject
import LumenExport
@testable import LumenDirector
@testable import LumenUI

/// Aggressive, headless validation of the model layer behind the core
/// features. These tests drive the real `reduce` command path and the real
/// project types — no mocks, no GUI, no network.
@Suite("CoreFeatureValidation")
struct CoreFeatureValidationTests {

    private func timeline(_ duration: Double = 60) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return tl
    }

    private func apply(_ command: Command, to tl: inout Timeline, playhead: Double = 0) throws {
        let ctx = ReduceContext(playhead: playhead, selection: nil,
                                duration: tl.compositionDuration, fps: 30)
        _ = try reduce(&tl, command, ctx: ctx)
    }

    private func words(_ spec: [(String, Double, Double)]) -> [WordToken] {
        spec.map { WordToken(text: $0.0, start: $0.1, end: $0.2) }
    }

    // MARK: Transcript editing — deleting a word cuts the PICTURE

    @Test func deletingWordCutsVideoAndMarksCaption() throws {
        let w = words([("Hello", 1.0, 1.3), ("um", 2.0, 2.4), ("world.", 3.0, 3.4)])
        let span = try #require(TranscriptEdits.span(for: w[1]))
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords([1], cuts: [span]), to: &tl)
        #expect(tl.captions.deletedWords == [1])
        #expect(abs(before - tl.timeMap.outputDuration - (span.end - span.start)) < 0.02)
        #expect(tl.timeMap.isCut(2.2))
        #expect(!tl.timeMap.isCut(1.1))
        #expect(tl.timeMap.cuts.count == 1)
        #expect(tl.timeMap.cuts[0].origin == .transcript)
    }

    @Test func restoringWordRestoresVideoAndNeverTouchesManualCuts() throws {
        let w = words([("um", 2.0, 2.4)])
        let span = try #require(TranscriptEdits.span(for: w[0]))
        var tl = timeline()
        try apply(.addCut(start: 10, end: 11), to: &tl)
        let manual = tl.timeMap.cuts[0]
        let withManual = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords([0], cuts: [span]), to: &tl)
        #expect(tl.timeMap.outputDuration < withManual - 0.4)
        try apply(.restoreTranscriptWords([0], cuts: [span]), to: &tl)
        #expect(tl.captions.deletedWords.isEmpty)
        #expect(tl.timeMap.cuts.filter { $0.origin == .transcript }.isEmpty)
        #expect(tl.timeMap.cuts.contains(manual))
        #expect(abs(tl.timeMap.outputDuration - withManual) < 0.02)
    }

    @Test func adjacentWordDeletionsMergeToOneCutAndRestoreSplitsIt() throws {
        let w = words([("uh", 2.0, 2.3), ("um", 2.34, 2.64), ("next.", 4.0, 4.4)])
        let spans = TranscriptEdits.spans(for: w, at: [0, 1])
        #expect(spans.count == 1)
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords([0, 1], cuts: spans), to: &tl)
        #expect(tl.timeMap.cuts.count == 1)
        #expect(abs(before - tl.timeMap.outputDuration - (spans[0].end - spans[0].start)) < 0.02)
        // Restore only the first word: the second stays cut.
        let first = try #require(TranscriptEdits.span(for: w[0]))
        try apply(.restoreTranscriptWords([0], cuts: [first]), to: &tl)
        #expect(tl.captions.deletedWords == [1])
        #expect(tl.timeMap.cuts.count == 1)
        #expect(abs(tl.timeMap.cuts[0].start - 2.34) < 0.01)
        #expect(abs(tl.timeMap.cuts[0].end - 2.68) < 0.01)
    }

    @Test func repeatedDeletionIsIdempotentUnderRapidFire() throws {
        let w = words([("um", 2.0, 2.4)])
        let span = try #require(TranscriptEdits.span(for: w[0]))
        var tl = timeline()
        let cmd: Command = .deleteTranscriptWords([0], cuts: [span])
        for _ in 0..<8 { try apply(cmd, to: &tl) }
        #expect(tl.timeMap.cuts.count == 1)
        #expect(tl.captions.deletedWords == [0])
        let once = tl.timeMap.outputDuration
        try apply(cmd, to: &tl)
        #expect(abs(tl.timeMap.outputDuration - once) < 0.001)
    }

    @Test func fillerBulkRemovalCutsPunctuationUnicodeAndLocaleVariants() throws {
        // Short gaps keep this test about fillers; long gaps are covered below.
        let en = words([("Um,", 1.0, 1.3), ("uh", 1.5, 1.9), ("like", 2.1, 2.3), ("real", 2.5, 3.0)])
        let cuts = TranscriptEdits.cleanupCuts(transcript: Transcript(words: en, locale: "en-US"))
        #expect(cuts.count == 3)
        #expect(cuts.allSatisfy { $0.origin == .transcript })
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        let indices = en.indices.filter { TranscriptEdits.terms(forLocale: "en-US")
            .contains(TranscriptEdits.normalized(en[$0].text)) }
        #expect(indices == [0, 1, 2])
        try apply(.deleteTranscriptWords(indices, cuts: cuts), to: &tl)
        #expect(tl.captions.deletedWords == [0, 1, 2])
        #expect(abs((before - tl.timeMap.outputDuration) - cuts.reduce(0) { $0 + ($1.end - $1.start) }) < 0.03)

        let de = Transcript(words: words([("ähm", 1, 1.4), ("gut", 1.6, 2.1)]), locale: "de-DE")
        #expect(TranscriptEdits.cleanupCuts(transcript: de).count == 1)
    }

    @Test func longPauseCutOnlyWhenNoInputActivityInside() throws {
        let w = words([("one", 1.0, 1.2), ("two", 2.2, 2.4)])
        let quiet = TranscriptEdits.cleanupCuts(transcript: Transcript(words: w, locale: "en-US"))
        #expect(quiet.count == 1)
        // 1.0 s gap, 0.25 s breath kept -> 0.75 s must be removed.
        #expect(abs((quiet[0].end - quiet[0].start) - 0.75) < 0.001)
        let busy = TranscriptEdits.cleanupCuts(transcript: Transcript(words: w, locale: "en-US"),
                                               events: [InputEvent(t: 1.6, kind: .keyDown)])
        #expect(busy.isEmpty)
        // Very long gaps (a break, not a pause) are never auto-removed.
        let longGap = words([("one", 1, 1.2), ("two", 4, 4.2)])
        #expect(TranscriptEdits.cleanupCuts(transcript: Transcript(words: longGap, locale: "en-US")).isEmpty)
    }

    @Test func hostileWordTimesAndIndicesAreIgnored() throws {
        var bad = words([("um", -5, -4), ("uh", .nan, .infinity), ("erm", 9, 8)])
        let spans = TranscriptEdits.spans(for: bad, at: [0, 1, 2, -1, 99])
        #expect(spans.isEmpty)
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords([0, 1, 2, -1, 99], cuts: spans), to: &tl)
        #expect(tl.timeMap.outputDuration == before)
        #expect(TranscriptEdits.sentenceSpan(for: bad, range: 0..<9) == nil)
        bad[0] = WordToken(text: "ok", start: 1, end: 2)
        #expect(TranscriptEdits.sentenceSpan(for: bad, range: 0..<1)?.start == 0.96)
    }

    @Test func deletingSentenceCutsOneSpanAndOneUndoStep() throws {
        let w = words([("First one.", 1, 1.5), ("second part", 2, 2.4),
                       ("ends now.", 2.5, 3.0), ("third.", 5, 5.4)])
        let cut = try #require(TranscriptEdits.sentenceSpan(for: w, range: 0..<3))
        #expect(abs(cut.start - 0.96) < 0.001)
        #expect(abs(cut.end - 3.04) < 0.001)
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords([0, 1, 2], cuts: [cut]), to: &tl)
        #expect(tl.timeMap.cuts.count == 1)
        #expect(abs((before - tl.timeMap.outputDuration) - (cut.end - cut.start)) < 0.02)
    }

    // MARK: Layouts / framing, aspect ratios, captions, voice

    @Test func allFiveLayoutsRoundTripWithFramingSettings() throws {
        #expect(Set(LayoutKind.allCases).count == 5)
        for kind in LayoutKind.allCases {
            var s = LayoutSettings()
            s.autoFrame = true
            s.hideOnSilence = true
            s.silenceHold = 0.9
            s.behindFace = .fade
            s.avoidCursor = true
            var set = LayoutSet()
            set[kind] = s
            var tl = timeline()
            tl.layouts = [LayoutSegment(start: 2, end: 8, kind: kind)]
            tl.layoutSettings = set
            let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(tl))
            #expect(back.layouts.first?.kind == kind)
            #expect(back.layoutSettings[kind].hideOnSilence)
            #expect(back.layoutSettings[kind].silenceHold == 0.9)
            #expect(back.layoutSettings[kind].behindFace == .fade)
            #expect(back.layoutSettings[kind].autoFrame)
        }
    }

    @Test func requiredAspectRatiosAndCaptionPositioningRoundTrip() throws {
        #expect(abs(CanvasAspect.r16x9.ratio - 16.0 / 9) < 1e-9)
        #expect(CanvasAspect.r1x1.ratio == 1)
        #expect(abs(CanvasAspect.r9x16.ratio - 9.0 / 16) < 1e-9)
        for aspect in [CanvasAspect.r16x9, .r1x1, .r9x16] {
            var tl = timeline()
            tl.style.canvas = aspect
            tl.style.customAspect = aspect.ratio
            tl.captions.enabled = true
            tl.captions.style.size = 0.06
            tl.captions.style.font = .serif
            tl.captions.locale = "en-US"
            let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(tl))
            #expect(back.style.aspectRatio == aspect.ratio)
            #expect(back.captions.enabled)
            #expect(back.captions.style.font == .serif)
        }
    }

    @Test func captionPillNoneSurvivesRoundTrip() throws {
        var style = CaptionStyle()
        style.pill = nil
        let back = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style))
        #expect(back.pill == nil, "no-pill must not silently revert to the default dark card")
        style.pill = RGBA(0x0A0A0A, a: 0.5)
        let withPill = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style))
        #expect(withPill.pill?.a == 0.5)
    }

    @Test func voiceProcessingDefaultsAndPodcastMode() throws {
        let plan = AudioPlan()
        #expect(plan.micClean, "noise reduction is on by default")
        #expect(plan.noiseReductionStrength == 1)
        #expect(plan.micMode.targetLUFS == -12)
        #expect(MicMode.podcast.targetLUFS == -16)
        var podcast = plan
        podcast.micMode = .podcast
        let back = try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(podcast))
        #expect(back.micMode == .podcast)
        #expect(back.targetLUFS == AudioPlan.studioTargetLUFS)
        #expect(back.micClean)
    }

    // MARK: Export — three aspects, portrait resolution, encoder validity

    @Test func portraitExportHonorsChosenResolution() {
        let src = SourceInfo(width: 3840, height: 2160, fps: 60, duration: 10,
                             backingScale: 2, originX: 0, originY: 0)
        var settings = ExportSettings()
        settings.resolution = .p1080
        #expect(settings.dimensions(source: src, aspect: 9.0 / 16) == (1080, 1920))
        settings.resolution = .ultraHD
        #expect(settings.dimensions(source: src, aspect: 9.0 / 16) == (2160, 3840))
        let preset = settings.preset(source: src, aspect: 9.0 / 16)
        #expect(preset.width(aspect: 9.0 / 16) == 2160)
        #expect(preset.height == 3840)
        for aspect in [16.0 / 9, 1.0, 9.0 / 16] {
            let (w, h) = settings.dimensions(source: src, aspect: aspect)
            #expect(w % 2 == 0 && h % 2 == 0, "odd dimensions are rejected by the encoder")
            #expect(abs(Double(w) / Double(h) - aspect) < 0.002)
        }
    }

    @Test func batchAspectsYieldThreeDistinctValidPresets() {
        let src = SourceInfo(width: 2560, height: 1440, fps: 60, duration: 10,
                             backingScale: 2, originX: 0, originY: 0)
        var settings = ExportSettings()
        settings.resolution = .p1080
        var seen: [String] = []
        for aspect in [16.0 / 9, 1.0, 9.0 / 16] {
            let preset = settings.preset(source: src, aspect: aspect)
            let (w, h) = settings.dimensions(source: src, aspect: aspect)
            #expect(preset.width(aspect: aspect) == w)
            #expect(preset.height == h)
            seen.append("\(w)x\(h)")
        }
        #expect(Set(seen).count == 3)
        #expect(seen == ["1920x1080", "1080x1080", "1080x1920"])
    }

    @Test func presetWidthRejectsOddCustomAndHostileAspect() {
        let p = ExportPreset(name: "test", codec: .h264, height: 1080, fps: 30)
        #expect(p.width(aspect: 16.0 / 9) == 1920)
        #expect(p.width(aspect: 9.0 / 16) == 608)
        for bad in [0, -1, Double.nan, Double.infinity] {
            let w = p.width(aspect: bad)
            #expect(w > 0 && w % 2 == 0)
        }
        var odd = p; odd.customWidth = 1081
        #expect(odd.width(aspect: 16.0 / 9) % 2 == 0)
    }

    // MARK: Privacy / offline-first — sharing is local, links are not uploads

    @Test func sharePackageStaysLocalAndLinkIsNotRemote() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coreval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bundle = try ProjectBundle.create(named: "Offline", in: root)
        var tl = timeline()
        tl.captions.enabled = true
        let meta = ProjectMeta(name: "Offline", source: SourceInfo(width: 1920, height: 1080, fps: 60,
                                                                   duration: 1, backingScale: 1,
                                                                   originX: 0, originY: 0),
                               clock: RecordingClock())
        try bundle.save(ProjectFile(meta: meta, timeline: tl))
        let link = bundle.shareLink
        #expect(link.hasPrefix("lumen://open"), "sharing must not generate a remote upload URL")
        #expect(!link.contains("http"))
        let package = root.appendingPathComponent("Offline.lumenshare")
        try bundle.exportSharePackage(to: package)
        #expect(fm.fileExists(atPath: package.path))
        let incoming = root.appendingPathComponent("incoming")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let installed = try ProjectBundle.installSharePackage(package, into: incoming)
        #expect(try installed.load().timeline.captions.enabled)
    }

    // MARK: Auto zoom must stay deleted across a deterministic replan

    @Test func deletingAutoZoomStaysDeletedAcrossReplans() throws {
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 30,
                             backingScale: 1, originX: 0, originY: 0)
        var tl = timeline(30)
        tl.camera.autoZoom = true
        tl.camera.preset = .fixed
        let input = DirectorInput(events: [], source: src)
        var cache = DeriveCache()
        let derived = Director.derive(tl, input: input, revision: 1, cache: &cache)
        #expect(derived.zoom.count == 1)
        let auto = derived.zoom[0]
        #expect(auto.origin == .auto)
        #expect(auto.id == ZoomPlanner.stableID(tl.timeMap.trimStart, tl.timeMap.trimEnd))
        tl = derived
        try apply(.deleteZoom(auto.id), to: &tl)
        #expect(tl.zoom.isEmpty)
        #expect(tl.suppressedAuto == [auto.id.uuidString])
        // A second delete on an already-gone zoom must not duplicate suppression.
        try apply(.deleteZoom(auto.id), to: &tl)
        #expect(tl.suppressedAuto.count == 1)
        // Cold replans (fresh cache) must not bring the same zoom back.
        for revision in 2...4 {
            var fresh = DeriveCache()
            tl = Director.derive(tl, input: input, revision: revision, cache: &fresh)
            #expect(!tl.zoom.contains { $0.id == auto.id })
        }
        // Manual zooms are still allowed, and deleting one does not suppress it.
        let manual = ZoomSegment(start: 5, end: 9, scale: 2, focus: .follow, origin: .manual)
        try apply(.addZoom(manual), to: &tl)
        var fresh = DeriveCache()
        var withManual = Director.derive(tl, input: input, revision: 5, cache: &fresh)
        #expect(withManual.zoom.contains { $0.id == manual.id })
        try apply(.deleteZoom(manual.id), to: &withManual)
        #expect(!withManual.suppressedAuto.contains(manual.id.uuidString))
    }

    // MARK: Raw-footage retention

    @Test func rawFootageSweepHonorsRetentionDeleteAfterExportAndExemptions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rawval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let meta = ProjectMeta(name: "x", source: SourceInfo(width: 1920, height: 1080, fps: 60,
                                                             duration: 1, backingScale: 1, originX: 0, originY: 0),
                               clock: RecordingClock())
        func make(_ name: String, keep: Int, deleteAfter: Bool, lastExport: Date?) throws -> ProjectBundle {
            let b = try ProjectBundle.create(named: name, in: root)
            var tl = timeline()
            tl.captions.enabled = true
            tl.overlays.privacy.rawRetentionDays = keep
            tl.overlays.privacy.deleteRawAfterExport = deleteAfter
            tl.overlays.privacy.lastExportAt = lastExport
            try b.save(ProjectFile(meta: meta, timeline: tl))
            for raw in RawFootageSweep.rawFileNames {
                try Data("raw".utf8).write(to: b.url.appendingPathComponent(raw))
            }
            try Data("deliverable".utf8).write(to: b.url.appendingPathComponent("export.mp4"))
            return b
        }
        let fresh = try make("fresh", keep: 7, deleteAfter: false, lastExport: now.addingTimeInterval(-3 * 86_400))
        let oldOneDay = try make("one-day", keep: 1, deleteAfter: false, lastExport: now.addingTimeInterval(-3 * 86_400))
        let oldThirty = try make("thirty", keep: 30, deleteAfter: false, lastExport: now.addingTimeInterval(-3 * 86_400))
        let afterExport = try make("after-export", keep: 30, deleteAfter: true, lastExport: now.addingTimeInterval(-1))
        let failed = try make("failed", keep: 1, deleteAfter: false, lastExport: now.addingTimeInterval(-10 * 86_400))
        failed.markFailed(at: now)
        let interrupted = try make("interrupted", keep: 1, deleteAfter: false, lastExport: now.addingTimeInterval(-10 * 86_400))
        let journal = RecordingJournal(started: now.addingTimeInterval(-20), updated: now.addingTimeInterval(-2 * 86_400),
                                       source: meta.source, fps: 60, mic: false, system: false, webcam: false,
                                       lastFramePTS: 5)
        try interrupted.writeJournal(journal).get()

        let report = RawFootageSweep.sweep(library: root, now: now)
        #expect(Set(report.deleted) == Set(["one-day.lumen", "after-export.lumen"]))
        for b in [fresh, oldThirty, failed, interrupted] {
            #expect(fm.fileExists(atPath: b.screenURL.path))
            #expect(fm.fileExists(atPath: b.projectURL.path))
        }
        for b in [oldOneDay, afterExport] {
            #expect(!fm.fileExists(atPath: b.screenURL.path))
            #expect(!fm.fileExists(atPath: b.micURL.path))
            // Deliverables and the project are never swept.
            #expect(fm.fileExists(atPath: b.url.appendingPathComponent("export.mp4").path))
            #expect(try b.load().timeline.captions.enabled)
        }

        // After the 30-day grace period, failed/interrupted raw footage ages out.
        failed.markFailed(at: now.addingTimeInterval(-31 * 86_400))
        let later = RecordingJournal(started: now.addingTimeInterval(-40 * 86_400),
                                     updated: now.addingTimeInterval(-31 * 86_400),
                                     source: meta.source, fps: 60, mic: false, system: false, webcam: false,
                                     lastFramePTS: 5)
        try interrupted.writeJournal(later).get()
        let second = RawFootageSweep.sweep(library: root, now: now)
        #expect(Set(second.deleted).isSuperset(of: ["failed.lumen", "interrupted.lumen"]))
    }

    @Test func retentionSettingRoundTripsAndClampsToValidDays() throws {
        var plan = PrivacyPlan()
        #expect(plan.rawRetentionDays == 7)
        plan.rawRetention = .thirtyDays
        plan.deleteRawAfterExport = true
        plan.lastExportAt = Date(timeIntervalSince1970: 1_700_000_000)
        let back = try JSONDecoder().decode(PrivacyPlan.self, from: JSONEncoder().encode(plan))
        #expect(back.rawRetention == .thirtyDays)
        #expect(back.deleteRawAfterExport)
        #expect(back.lastExportAt == plan.lastExportAt)
        // Hostile stored values fall back to the 7-day default.
        let json = #"{"rawRetentionDays":999,"deleteRawAfterExport":true}"#
        let hostile = try JSONDecoder().decode(PrivacyPlan.self, from: Data(json.utf8))
        #expect(hostile.rawRetention == .sevenDays)
    }

    // MARK: Crash recovery keeps the Area crop

    @Test func recordingJournalCarriesSmartCropThroughRecovery() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cropval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let b = try ProjectBundle.create(named: "Area", in: root)
        let now = Date()
        let crop = SmartCropConfig(enabled: true, roi: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
                                   revealMarginPt: 32, returnSeconds: 0.6)
        let j = RecordingJournal(started: now.addingTimeInterval(-10), updated: now.addingTimeInterval(-1),
                                 source: SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10,
                                                    backingScale: 1, originX: 0, originY: 0),
                                 fps: 60, mic: false, system: false, webcam: false,
                                 lastFramePTS: 5, smartCrop: crop)
        try b.writeJournal(j).get()
        let read = try #require(try b.readJournal())
        #expect(read.smartCrop == crop)
        let recovered = try #require(try b.recoverFromJournal())
        #expect(recovered.timeline.smartCrop == crop)
        #expect(!b.isUnfinished)
    }

    @Test func legacyJournalWithoutSmartCropKeyStillRecovers() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("legacyval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let b = try ProjectBundle.create(named: "Legacy", in: root)
        let now = Date()
        let j = RecordingJournal(started: now.addingTimeInterval(-10), updated: now.addingTimeInterval(-1),
                                 source: SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10,
                                                    backingScale: 1, originX: 0, originY: 0),
                                 fps: 60, mic: false, system: false, webcam: false, lastFramePTS: 5)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as! [String: Any]
        object.removeValue(forKey: "smartCrop")
        try JSONSerialization.data(withJSONObject: object).write(to: b.journalURL)
        let read = try #require(try b.readJournal())
        #expect(read.smartCrop == nil)
        let recovered = try #require(try b.recoverFromJournal())
        #expect(recovered.timeline.smartCrop == SmartCropConfig())
        // A malformed crop is refused rather than poisoning a recovered project.
        var bad = j
        bad.smartCrop = SmartCropConfig(enabled: true, roi: CGRect(x: 0, y: 0, width: -2, height: 4))
        #expect((try? b.writeJournal(bad).get()) == nil)
    }
}
