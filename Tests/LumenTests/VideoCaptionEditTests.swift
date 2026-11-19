import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Headless oracle for transcript-driven video editing. Every test drives the
/// real `reduce` command path, the real `TimeMap`, the real caption planner and
/// real on-disk transcript IO. No mocks, no GUI, no network.
@Suite("VideoCaptionEdit")
struct VideoCaptionEditTests {
    private let eps = 0.002
    /// TimeMap integrates on a 1/240 s lattice, so a cut's output length can
    /// differ from its source length by up to one grid step.
    private let gridEps = 0.01

    private func words(_ spec: [(String, Double, Double, Float)]) -> [WordToken] {
        spec.map { WordToken(text: $0.0, start: $0.1, end: $0.2, confidence: $0.3) }
    }

    private func timeline(_ duration: Double = 30) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return tl
    }

    private func apply(_ command: Command, to tl: inout Timeline) throws {
        let ctx = ReduceContext(playhead: 0, selection: nil,
                                duration: tl.compositionDuration, fps: 60)
        _ = try reduce(&tl, command, ctx: ctx)
    }

    // MARK: - Round-trip persistence

    /// A transcript.json written by an older app has no `version` key. Losing
    /// the whole transcript on load is silent data loss, not a migration.
    @Test func legacyTranscriptWithoutVersionStillLoads() throws {
        let legacy = Data(#"{"engine":"moonshine","complete":true,"transcript":{"words":[{"text":"Um,","start":1,"end":1.3,"confidence":1}],"locale":"en-US"}}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptFile.self, from: legacy)
        #expect(decoded.version == 1)
        #expect(decoded.complete)
        #expect(decoded.transcript.words.first?.text == "Um,")
        #expect(decoded.transcript.locale == "en-US")
    }

    /// Save then load through a real project bundle, with unicode text and an
    /// edited caption mask. This is the path Studio and MCP actually use.
    @Test func transcriptBundleRoundTripPreservesUnicodeAndEditMask() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v4-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(named: "RoundTrip", in: dir)
        var plan = CaptionPlan()
        plan.enabled = true
        plan.locale = "de-DE"
        plan.deletedWords = [1, 3]
        plan.textEdits = ["0": "Zürich", "2": "—.naïve—"]
        let transcript = Transcript(words: words([
            ("Zürich", 1, 1.4, 1), ("ähm", 1.5, 1.8, 0.9),
            ("naïve", 2, 2.4, 1), ("gut", 2.5, 2.9, 1),
        ]), locale: "de-DE")
        try bundle.saveTranscript(TranscriptFile(engine: "moonshine", complete: true, transcript: transcript))
        let loaded = try #require(bundle.loadTranscript())
        #expect(loaded.transcript == transcript)
        #expect(loaded.engine == "moonshine")
        let shifted = loaded.transcript.shifted(by: 0.25)
        #expect(shifted.words.map(\.text) == transcript.words.map(\.text))
        #expect(shifted.words.map(\.start) == [1.25, 1.75, 2.25, 2.75])
        #expect(shifted.locale == "de-DE")
        #expect(plan.deletedWords == [1, 3]) // edit mask is independent of word shift
    }

    // MARK: - Filler removal: picture and caption must agree

    /// The UI hides the caption of every matching filler, including ones ASR
    /// heard with low confidence. Cleanup must cut the picture for those exact
    /// words, otherwise a visible picture has a silently missing caption.
    @Test func fillerCleanupCutsPictureForEveryCaptionItHides() throws {
        let transcript = Transcript(words: words([
            ("um", 1, 1.3, 0.2), ("uh", 1.4, 1.7, 0.35),
            ("hello", 1.9, 2.4, 1), ("world.", 2.5, 3.0, 1),
        ]), locale: "en-US")
        // The UI's definition: every word whose text matches a filler term,
        // regardless of ASR confidence.
        let expected = TranscriptEdits.fillerIndices(in: transcript)
        #expect(expected == [0, 1])
        let cuts = TranscriptEdits.cleanupCuts(transcript: transcript)
        #expect(cuts.count == 2, "both low-confidence fillers must cut the picture: \(cuts)")
        #expect(abs((cuts.first?.start ?? 0) - 0.96) < eps)
        #expect(abs((cuts.first?.end ?? 0) - 1.34) < eps)
        #expect(abs((cuts.last?.start ?? 0) - 1.36) < eps)
        #expect(abs((cuts.last?.end ?? 0) - 1.74) < eps)
        var tl = timeline()
        let before = tl.timeMap.outputDuration
        try apply(.deleteTranscriptWords(expected, cuts: cuts), to: &tl)
        #expect(tl.captions.deletedWords == [0, 1])
        #expect(tl.timeMap.cuts.count == 2)
        #expect(tl.timeMap.cuts.allSatisfy { $0.origin == .transcript })
        #expect(abs((before - tl.timeMap.outputDuration) - 0.76) < gridEps)
    }

    /// Streaming ASR re-emits overlap. One merged cut, one undo step; restoring
    /// one burst leaves the other burst's picture removed.
    @Test func overlappingFillerBurstsMergeThenRestoreIndependently() throws {
        let w = words([
            ("um", 1.0, 1.3, 1), ("uh", 1.2, 1.5, 1),
            ("a", 1.6, 1.8, 1), ("bit", 1.9, 2.2, 1), ("more.", 2.3, 2.7, 1),
        ])
        let cuts = TranscriptEdits.cleanupCuts(transcript: Transcript(words: w, locale: "en-US"))
        #expect(cuts.count == 1, "overlapping filler bursts must merge: \(cuts)")
        var tl = timeline()
        try apply(.deleteTranscriptWords([0, 1], cuts: cuts), to: &tl)
        #expect(tl.timeMap.cuts.count == 1)
        #expect(tl.captions.deletedWords == [0, 1])
        try apply(.restoreTranscriptWords([0], cuts: TranscriptEdits.spans(for: w, at: [0])), to: &tl)
        #expect(tl.captions.deletedWords == [1])
        #expect(tl.timeMap.cuts.count == 1)
        #expect(tl.timeMap.cuts[0].start > 1.3, "the second burst stays cut: \(tl.timeMap.cuts)")
    }

    // MARK: - Sentence deletion

    /// Overlapping windows can re-emit a word with a shorter end than an earlier
    /// word in the same sentence, or emit the bursts out of order. A sentence
    /// cut must cover every word in the range, not just first/last.
    @Test func sentenceSpanCoversEveryBurstNotJustFirstAndLast() throws {
        let w = words([
            ("First", 1.0, 1.4, 1), ("one.", 1.3, 1.9, 1),
            ("one", 1.5, 1.7, 1), ("Next.", 3.0, 3.4, 1),
        ])
        let cut = try #require(TranscriptEdits.sentenceSpan(for: w, range: 0..<3))
        #expect(abs(cut.start - 0.96) < eps)
        #expect(abs(cut.end - 1.94) < eps, "re-emit must not shrink the sentence: \(cut)")

        let outOfOrder = words([("Second.", 2.5, 3.0, 1), ("First", 1.0, 1.4, 1)])
        let c2 = try #require(TranscriptEdits.sentenceSpan(for: outOfOrder, range: 0..<2),
                              "out-of-order bursts must still form one sentence cut")
        #expect(abs(c2.start - 0.96) < eps)
        #expect(abs(c2.end - 3.04) < eps)
    }

    /// Delete a sentence on a timeline that already has a manual cut and a
    /// speed ramp. Picture and caption both go; the ramp retimes the cut and
    /// the manual cut survives unchanged.
    @Test func deleteSentenceOnRampedTimelineCutsPictureAndCaptions() throws {
        let w = words([
            ("First", 1.0, 1.4, 1), ("one.", 1.3, 2.0, 1),
            ("Second", 2.2, 2.6, 1), ("part.", 2.7, 3.1, 1),
            ("Kept.", 12.0, 12.5, 1),
        ])
        let manual = CutRange(start: 10, end: 11, origin: .manual)
        var tl = timeline(30)
        tl.timeMap = TimeMap(sourceDuration: 30, trimStart: 0, trimEnd: 30,
                             ramps: [SpeedRamp(start: 1, end: 9, speed: 4)],
                             cuts: [manual])
        let before = tl.timeMap.outputDuration
        let cut = try #require(TranscriptEdits.sentenceSpan(for: w, range: 0..<4))
        try apply(.deleteTranscriptWords([0, 1, 2, 3], cuts: [cut]), to: &tl)

        #expect(tl.captions.deletedWords == [0, 1, 2, 3])
        #expect(tl.timeMap.cuts.count == 2)
        #expect(tl.timeMap.cuts.contains(manual))
        let added = try #require(tl.timeMap.cuts.first { $0.origin == .transcript })
        #expect(abs(added.start - 0.96) < eps)
        #expect(abs(added.end - 3.14) < eps)

        // The picture removed is exactly the source span mapped through the
        // same ramp the captions use.
        let expected = TimeMap(sourceDuration: 30, trimStart: 0, trimEnd: 30,
                               ramps: [SpeedRamp(start: 1, end: 9, speed: 4)],
                               cuts: [manual, added]).outputDuration
        #expect(abs(tl.timeMap.outputDuration - expected) < 1e-6)
        #expect(before - tl.timeMap.outputDuration > 0.4, "ramp makes the cut short but real")
    }

    // MARK: - Caption timing / no orphans

    /// Captions are planned from the same time map as the picture. Words hidden
    /// by a transcript cut or a caption deletion must never reappear, and the
    /// surviving caption times are output times, not raw source times.
    @Test func captionsFollowCutsAndRampsWithoutDeletedWords() throws {
        let w = words([
            ("Hello", 1.0, 1.4, 1), ("um", 1.5, 1.8, 1),
            ("world.", 2.0, 2.5, 1), ("After", 10.0, 10.4, 1),
            ("ramp.", 10.5, 11.0, 1),
        ])
        let cut = TranscriptEdits.span(for: w[1])!
        let tm = TimeMap(sourceDuration: 30, ramps: [SpeedRamp(start: 9, end: 12, speed: 4)], cuts: [cut])
        var plan = CaptionPlan()
        plan.enabled = true
        plan.deletedWords = [1]
        let chunks = CaptionPlanner.plan(words: w, tm: tm, p: plan, aspect: 16.0 / 9,
                                         kindAt: { _ in .screenOnly }, cornerAt: { _ in nil })
        let text = chunks.flatMap { $0.lines }.flatMap { $0 }.map(\.text).joined(separator: " ")
        #expect(!text.localizedCaseInsensitiveContains("um"), "deleted word must not survive: \(text)")
        #expect(text.contains("Hello") && text.contains("world") && text.contains("After"))

        #expect(chunks == chunks.sorted { $0.start < $1.start }, "caption chunks stay in time order")
        #expect(chunks.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= tm.outputDuration + eps })

        // The word after the ramp must be retimed through it: its output time
        // is far earlier than its source time.
        let last = try #require(chunks.last)
        let firstWordOfLast = try #require(last.lines.flatMap { $0 }.first)
        #expect(firstWordOfLast.text == "After")
        #expect(firstWordOfLast.start < 10.0, "caption time follows the ramp: \(firstWordOfLast.start)")
        #expect(abs(firstWordOfLast.start - tm.output(atSource: 10.0)) < eps)

        // No caption chunk lives wholly inside a removed picture span.
        for chunk in chunks {
            let src = tm.source(atOutput: (chunk.start + chunk.end) / 2)
            #expect(!tm.isCut(src), "orphan caption over a cut: \(chunk.start)-\(chunk.end)")
        }
    }

    /// One definition of "filler" drives both the caption mask and the picture
    /// cut. Locale variants and hyphenated bursts resolve through it.
    @Test func fillerIndicesIsTheSharedDefinition() {
        let transcript = Transcript(words: words([
            ("Um,", 1, 1.3, 0.2), ("you-know", 1.4, 1.8, 1),
            ("real", 2, 2.4, 1), ("wörd.", 2.5, 3, 1),
        ]), locale: "en-US")
        #expect(TranscriptEdits.fillerIndices(in: transcript) == [0, 1])
        let german = Transcript(words: words([("ähm", 1, 1.4, 0.1), ("gut", 1.5, 2, 1)]), locale: "de-DE")
        #expect(TranscriptEdits.fillerIndices(in: german) == [0])
        let cuts = TranscriptEdits.cleanupCuts(transcript: german)
        #expect(cuts.count == 1)
        #expect(cuts.first?.origin == .transcript)
    }

    // MARK: - Rapid undo / idempotency

    /// Repeated delete/restore cycles must return the exact timeline, including
    /// a pre-existing manual cut, with no drift and no orphan cuts.
    @Test func rapidDeleteRestoreReturnsExactTimeline() throws {
        let w = words([("um", 2.0, 2.4, 1), ("kept", 4.0, 4.4, 1)])
        let span = TranscriptEdits.span(for: w[0])!
        var tl = timeline()
        try apply(.addCut(start: 8, end: 9), to: &tl)
        let manual = tl.timeMap.cuts[0]
        let original = tl.timeMap.outputDuration
        for _ in 0..<8 {
            try apply(.deleteTranscriptWords([0], cuts: [span]), to: &tl)
            #expect(tl.timeMap.cuts.count == 2)
            try apply(.restoreTranscriptWords([0], cuts: [span]), to: &tl)
        }
        #expect(tl.captions.deletedWords.isEmpty)
        #expect(tl.timeMap.cuts == [manual])
        #expect(abs(tl.timeMap.outputDuration - original) < eps)

        // 8 rapid repeats of the same delete are one cut, one undo step.
        let cmd: Command = .deleteTranscriptWords([0], cuts: [span])
        for _ in 0..<8 { try apply(cmd, to: &tl) }
        #expect(tl.timeMap.cuts.count == 2)
        #expect(tl.captions.deletedWords == [0])
        try apply(.restoreTranscriptWords([0], cuts: [span]), to: &tl)
        #expect(tl.timeMap.cuts == [manual])
        #expect(abs(tl.timeMap.outputDuration - original) < eps)
    }

    // MARK: - Normalization (punctuation + unicode)

    /// ASR emits hyphenated, symbol-wrapped and decomposed filler variants.
    /// They must all normalize to the same vocabulary key as the plain term.
    @Test func fillerNormalizationHandlesUnicodeAndPunctuation() {
        #expect(TranscriptEdits.normalized("*Um*,") == "um")
        #expect(TranscriptEdits.normalized("—UM—") == "um")
        #expect(TranscriptEdits.normalized("you-know") == "you know")
        #expect(TranscriptEdits.normalized("u\u{0308}m") == TranscriptEdits.normalized("üm"))
        #expect(TranscriptEdits.terms(forLocale: "en-US").contains("you know"))
        let w = words([("you-know", 1, 1.4, 1), ("right", 1.5, 1.9, 1)])
        #expect(TranscriptEdits.fillerIndices(in: Transcript(words: w, locale: "en-US")) == [0])
    }
}
