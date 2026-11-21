import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector
@testable import LumenCapture

/// Headless validation of the core capture contract (CORE-FEATURES §§5, 7, 11).
/// No ScreenCaptureKit session, no camera, no event tap: every case drives pure
/// logic or in-memory buffers so it is safe to run in CI with no permissions.
@Suite struct CoreCaptureValidationTests {

    private static func writeSucceeded(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    // MARK: - Full display / window / custom region coverage

    /// All three source kinds must be representable; a region must be a real
    /// display + rect, not a flattened enum that loses the display identity.
    @Test func captureSourceCoversDisplayWindowAndRegion() {
        let display = RecordingConfig.Source.display(42)
        let window = RecordingConfig.Source.window(7)
        let region = RecordingConfig.Source.region(42, CGRect(x: 10, y: 20, width: 300, height: 200))
        if case .display(let d) = display { #expect(d == 42) } else { Issue.record("display lost id") }
        if case .window(let w) = window { #expect(w == 7) } else { Issue.record("window lost id") }
        if case .region(let rd, let r) = region {
            #expect(rd == 42)
            #expect(r == CGRect(x: 10, y: 20, width: 300, height: 200))
        } else { Issue.record("region lost display/rect") }
    }

    /// Hostile Area rectangles must never reach SCStreamConfiguration as an
    /// invalid sourceRect (zero/negative/NaN/off-screen). The validator clips
    /// a region into its display and rejects any region with no usable area.
    @Test func regionValidationClipsToDisplayAndRejectsDegenerateRects() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let partial = CaptureValidation.safeRegion(
            CGRect(x: 1800, y: 1000, width: 400, height: 300), in: bounds)
        #expect(partial != nil)
        #expect(partial?.width == 120 && partial?.height == 80)

        let exact = CaptureValidation.safeRegion(bounds, in: bounds)
        #expect(exact == bounds)

        // Entirely off-screen, degenerate, NaN and infinite rects are rejected.
        #expect(CaptureValidation.safeRegion(CGRect(x: 3000, y: 3000, width: 100, height: 100), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(CGRect(x: 0, y: 0, width: 8, height: 8), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(CGRect(x: 0, y: 0, width: -100, height: 50), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(bounds, in: .zero) == nil)
    }

    /// A region whose clipped size is under the 16 pt floor is unusable: the
    /// derived pixel dimensions round down to near-zero and SCK rejects them.
    @Test func regionValidationEnforcesMinimumUsableArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(CaptureValidation.safeRegion(CGRect(x: 10, y: 10, width: 15.9, height: 100), in: bounds) == nil)
        #expect(CaptureValidation.safeRegion(CGRect(x: 10, y: 10, width: 16, height: 16), in: bounds) != nil)
    }

    /// Area rects are stored display-relative even on a secondary display whose
    /// CGDisplayBounds origin is far from zero. Validation must use a local
    /// bounds rect or a perfectly valid Area becomes an "off-screen" reject.
    @Test func regionValidationUsesDisplayRelativeCoordinates() {
        let global = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let local = CGRect(x: 0, y: 0, width: global.width, height: global.height)
        let area = CGRect(x: 100, y: 100, width: 640, height: 480)
        let safe = CaptureValidation.safeRegion(area, in: local)
        #expect(safe == area)
        #expect(global.minX + (safe?.minX ?? 0) == -1820)
    }

    /// A hostile Area rect can carry finite but astronomical coordinates whose
    /// min/max arithmetic overflows to infinity inside CGRect.intersection.
    /// Whatever survives validation must still be a finite, on-screen region.
    @Test func regionValidationSurvivesExtremeFiniteCoordinates() {
        let bounds = CGRect(x: -100, y: -200, width: 1920, height: 1080)
        let hostile = [
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100),
            CGRect(x: -1e300, y: -1e300, width: 1e300, height: 1e300),
            CGRect(x: 100, y: 100, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            CGRect(x: -100, y: -200, width: CGFloat.greatestFiniteMagnitude, height: 1080),
            CGRect(x: 0, y: 0, width: 16, height: CGFloat.nan)
        ]
        for rect in hostile {
            guard let safe = CaptureValidation.safeRegion(rect, in: bounds) else { continue }
            #expect(safe.origin.x.isFinite && safe.origin.y.isFinite)
            #expect(safe.width.isFinite && safe.height.isFinite)
            #expect(safe.width >= CaptureValidation.minimumRegionPoints)
            #expect(safe.height >= CaptureValidation.minimumRegionPoints)
            #expect(safe.minX >= bounds.minX && safe.minY >= bounds.minY)
            #expect(safe.maxX <= bounds.maxX && safe.maxY <= bounds.maxY)
        }
    }

    // MARK: - Resource-light capture: bounded queues, visible overflow

    /// The event ring is single-producer/single-consumer and fixed capacity.
    /// Pushing far past capacity must allocate nothing proportional to pushes
    /// and must return exactly `capacity` events on drain.
    @Test func eventRingIsBoundedAndCountsOverflow() {
        let ring = EventRing(capacity: 8)
        for i in 0..<20 {
            var e = InputEvent(t: Double(i), kind: .down)
            e.x = Float(i)
            ring.push(e)
        }
        #expect(ring.overflow == 12)
        var drained: [InputEvent] = []
        ring.drain { drained.append($0) }
        #expect(drained.count == 8)
        // The ring rejects new writes while full, so the first `capacity`
        // events survive and the 12 later ones are counted as overflow.
        #expect(drained.map(\.x) == (0..<8).map(Float.init))
        // Draining again yields nothing; overflow is not reset by a drain.
        var again: [InputEvent] = []
        ring.drain { again.append($0) }
        #expect(again.isEmpty)
        #expect(ring.overflow == 12)
    }

    /// Overflow must be observable outside the ring: a silent drop violates
    /// the "overflow is counted, never silent" contract and hides resource
    /// exhaustion from diagnostics.
    @Test func eventRingOverflowIsSurfacedToDiagnostics() {
        CaptureDiagnostics.resetEventOverflow()
        let ring = EventRing(capacity: 4)
        for i in 0..<13 { var e = InputEvent(t: Double(i), kind: .move); ring.push(e) }
        #expect(CaptureDiagnostics.overflowCount >= 9)
        #expect(ring.overflow == 9)
    }

    // MARK: - Webcam + microphone + system audio

    /// Extra (loopback) microphones must be unique and must not duplicate the
    /// primary microphone SCK already owns, or two AVFoundation sessions fight
    /// over one device and the primary track disappears.
    @Test func extraMicSelectionExcludesPrimaryAndDedupes() {
        var cfg = RecordingConfig(source: .display(1))
        cfg.micDeviceID = "primary-mic"
        cfg.additionalMicDeviceIDs = ["blackhole", "primary-mic", "usb", "blackhole", "usb"]
        #expect(cfg.resolvedAdditionalMicDeviceIDs() == ["blackhole", "usb"])

        cfg.micDeviceID = nil
        // With no primary to exclude, de-duplication still applies but
        // "primary-mic" is now a legitimate standalone extra input.
        #expect(cfg.resolvedAdditionalMicDeviceIDs() == ["blackhole", "primary-mic", "usb"])

        cfg.additionalMicDeviceIDs = []
        #expect(cfg.resolvedAdditionalMicDeviceIDs().isEmpty)
    }

    // MARK: - Crash recovery journal

    /// The crash journal's validate() is the last line of defence before a
    /// recovered project is trusted. Corrupt checkpoints must be rejected.
    @Test func journalRejectsCorruptCheckpoints() throws {
        let lib = FileManager.default.temporaryDirectory
            .appendingPathComponent("capval-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lib) }
        let bundle = try ProjectBundle.create(named: "Corrupt", in: lib)
        var base = RecordingJournal(source: SourceInfo(width: 1920, height: 1080, fps: 60, duration: 5,
                                                        backingScale: 2, originX: 0, originY: 0),
                                    fps: 60, mic: true, system: false, webcam: false,
                                    lastFramePTS: 5, firstFramePTS: 0)
        #expect(Self.writeSucceeded(bundle.writeJournal(base)))

        base.source.width = 0
        #expect(!Self.writeSucceeded(bundle.writeJournal(base)))
        base = RecordingJournal(source: SourceInfo(width: 1920, height: 1080, fps: 60, duration: 5,
                                                    backingScale: 2, originX: 0, originY: 0),
                                fps: 60, mic: false, system: false, webcam: false,
                                lastFramePTS: 5, firstFramePTS: 7)
        #expect(!Self.writeSucceeded(bundle.writeJournal(base)))
        base.firstFramePTS = 0
        base.pauseIntervals = [PauseInterval(start: 4, end: 2)]
        #expect(!Self.writeSucceeded(bundle.writeJournal(base)))
    }

    // MARK: - Intelligent Area crop wiring

    @Test func smartCropConfigIsActiveOnlyForPositiveROI() {
        #expect(!SmartCropConfig().isActive)
        #expect(!SmartCropConfig(enabled: true, roi: nil).isActive)
        #expect(!SmartCropConfig(enabled: false, roi: CGRect(x: 0, y: 0, width: 100, height: 100)).isActive)
        #expect(!SmartCropConfig(enabled: true, roi: CGRect(x: 0, y: 0, width: 0, height: 100)).isActive)
        #expect(SmartCropConfig(enabled: true, roi: CGRect(x: 0, y: 0, width: 100, height: 100)).isActive)
    }

    /// The finalize path must persist the Area crop on the timeline so export
    /// and Studio agree with the floating preview (issue.md §12).
    @Test func smartCropRoundTripsThroughTimelineCodable() throws {
        var tl = Timeline(duration: 2)
        tl.smartCrop = SmartCropConfig(enabled: true, roi: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                       revealMarginPt: 33, returnSeconds: 0.6)
        let data = try JSONEncoder().encode(tl)
        let loaded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(loaded.smartCrop.isActive)
        #expect(loaded.smartCrop.roi == tl.smartCrop.roi)
        #expect(loaded.smartCrop.revealMarginPt == 33)
        #expect(loaded.smartCrop.returnSeconds == 0.6)
    }

    // MARK: - On-device voice processing (CORE-FEATURES §7, §11)

    /// Noise reduction is on by default and podcast mode keeps the -16 LUFS
    /// target; all of it is plain model state (no network code paths).
    @Test func voicePlanDefaultsAndPodcastModeAreWired() {
        let plan = AudioPlan()
        #expect(plan.micClean)
        #expect(plan.noiseReductionStrength == 1.0)
        #expect(plan.micMode.targetLUFS == -12)
        #expect(MicMode.podcast.targetLUFS == -16)
        #expect(MicMode.loud.targetLUFS == -12)
        #expect(plan.micMode == .standard)
    }
}
