import Foundation
import Testing
import AppKit
@testable import LumenUI

/// Headless state and raster tests for the Clove dither instrument on the
/// timeline. No window is opened: the renderer is driven directly and its
/// images are inspected by size and pixel content.
@Suite("Timeline dither instrument")
struct TimelineDitherTests {

    @Test func bayerPatternIsTheCloveSixteenStepMatrix() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/LumenUI/TimelineDither.swift"), encoding: .utf8)
        #expect(src.contains("[0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]"))
        #expect(!src.contains("vImageBoxConvolve_ARGB8888"), "no viewport glow pass")
        #expect(!src.contains("Float.random"), "no particle randomness")
    }

    @Test func rendererProducesCellsAndSeamsWithoutGlow() throws {
        let r = try #require(TimelineDitherRenderer(width: 600, height: 224, scale: 2, isDark: true))
        let f = TimelineDitherRenderer.Frame(
            spans: [
                [TimelineDitherRenderer.Span(2, 40, 0), TimelineDitherRenderer.Span(40, 80, 1)],
                [TimelineDitherRenderer.Span(10, 60, 2)],
                [TimelineDitherRenderer.Span(4, 24, 3, 0.7)],
                [TimelineDitherRenderer.Span(0, 140, 4)],
                [TimelineDitherRenderer.Span(70, 120, 5)],
            ],
            peaks: [Float](repeating: 0.6, count: 140),
            clicks: [12, 30, 55], head: 44, playing: false, reduced: false, dt: 1.0 / 60, t: 0)
        let out = r.draw(f)
        let cells = try #require(out.cells)
        #expect(cells.width == 1200)
        #expect(cells.height == 448)
        #expect(out.glow == nil)
        #expect(out.overlay != nil)
    }

    @Test func clearingASpanImmediatelyMatchesFreshViewport() throws {
        let r = try #require(TimelineDitherRenderer(width: 400, height: 224, scale: 1, isDark: true))
        let full = TimelineDitherRenderer.Span(0, 90, 0)
        let first = TimelineDitherRenderer.Frame(spans: [[full], [], [], [], []], peaks: [],
            clicks: [], head: -1, playing: false, reduced: false, dt: 1.0 / 60, t: 0)
        _ = r.draw(first)
        let cleared = TimelineDitherRenderer.Frame(spans: [Array(repeating: TimelineDitherRenderer.Span(0, 0, 0), count: 0), [], [], [], []],
            peaks: [], clicks: [], head: -1, playing: false, reduced: false, dt: 1.0 / 60, t: 0.02)
        let out = r.draw(cleared)
        #expect(!out.isWarm, "pan or deletion cannot keep a particle loop alive")
        let fresh = try #require(TimelineDitherRenderer(width: 400, height: 224, scale: 1, isDark: true))
        let clean = fresh.draw(cleared)
        let oldPixels = try #require(out.cells?.dataProvider?.data as? Data)
        let newPixels = try #require(clean.cells?.dataProvider?.data as? Data)
        #expect(oldPixels == newPixels, "visible cells depend only on viewport, not previous ownership")
        let oldSeams = try #require(out.overlay?.dataProvider?.data as? Data)
        let newSeams = try #require(clean.overlay?.dataProvider?.data as? Data)
        #expect(oldSeams == newSeams, "no detached pixels can survive in the overlay")
    }

    @Test func paperPaletteUsesDeeperHues() {
        #expect(TimelineDitherRenderer.lightHues.count == TimelineDitherRenderer.hues.count)
        for (light, dark) in zip(TimelineDitherRenderer.lightHues, TimelineDitherRenderer.hues) {
            // On paper the hue is deeper: every channel is darker than on graphite.
            #expect(light.0 < dark.0 || light.1 < dark.1 || light.2 < dark.2)
        }
    }

    @Test func outputImagesOutliveTheirRenderer() throws {
        // The view holds these CGImages in CALayers while appearance and
        // backing changes replace (and deallocate) the renderer. They must own
        // their bytes, not alias the renderer's raw buffers.
        var output: TimelineDitherRenderer.Output?
        do {
            let r = try #require(TimelineDitherRenderer(width: 400, height: 224, scale: 1, isDark: true))
            output = r.draw(TimelineDitherRenderer.Frame(
                spans: [[.init(2, 80, 0)], [], [], [.init(0, 80, 4)], []],
                peaks: [Float](repeating: 0.7, count: 80), clicks: [], head: -1,
                playing: false, reduced: true, dt: 0, t: 0))
        }
        // Reuse the freed pages aggressively; an aliased image would now read
        // garbage or trap when CoreAnimation copies its provider.
        var churn: [[UInt8]] = []
        for _ in 0..<48 { churn.append([UInt8](repeating: 0xA5, count: 1 << 20)) }
        let cells = try #require(output?.cells)
        let bytes = try #require(cells.dataProvider?.data as? Data)
        #expect(bytes.count > 0)
        #expect(bytes.contains { $0 != 0 }, "cell image still carries pixels after its renderer is gone")
        withExtendedLifetime(churn) {}
    }

    @Test func rendererLifecycleNeverLeavesStaleImages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/LumenUI/TimelineDitherView.swift"), encoding: .utf8)
        #expect(host.contains("func releaseRenderer()"))
        #expect(host.contains("cellsLayer.contents = nil"))
        #expect(!host.contains("glowLayer"))
        #expect(host.contains("renderer = nil"))
        #expect(!host.contains("fatalError"))
        let renderer = try String(contentsOf: root.appendingPathComponent("Sources/LumenUI/TimelineDither.swift"), encoding: .utf8)
        #expect(renderer.contains("ownedImage(cellsContext"))
        #expect(!renderer.contains("glowContext"))
        #expect(renderer.contains("while resolved.count < Self.lanes"))
    }

    @Test func timelineKeepsItsChromeOverlays() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let strip = try String(contentsOf: root.appendingPathComponent("Sources/LumenUI/TimelineStrip.swift"), encoding: .utf8)
        #expect(strip.contains("TimelineDitherView(snapshot: ditherFrame(vp))"))
        for overlay in ["PlayheadLine", "GhostLine", "pendingLayer", "seamLayer", "threadLayer", "rulerLane"] {
            #expect(strip.contains(overlay), "\(overlay) survives the dither theme")
        }
        let host = try String(contentsOf: root.appendingPathComponent("Sources/LumenUI/TimelineDitherView.swift"), encoding: .utf8)
        #expect(host.contains("guard snapshot != lastDrawn else { stop(); return }"), "unchanged snapshots stop immediately")
        #expect(host.contains("accessibilityDisplayShouldReduceMotion") == false)
        #expect(host.contains("frame.reduced") == false)
        #expect(host.contains("next.dt = 0; next.t = 0"), "wall time does not invalidate static cells")
    }
}

@Test func ditherMusicCellsReflectRealAmplitude() throws {
    let renderer = try #require(TimelineDitherRenderer(width: 400, height: 224, scale: 1, isDark: true))
    let spans: [[TimelineDitherRenderer.Span]] = [[], [], [], [], [.init(0, 80, 5)]]
    let quiet = TimelineDitherRenderer.Frame(spans: spans, peaks: [], musicPeaks: Array(repeating: 0, count: 80),
        clicks: [], head: -1, playing: false, reduced: true, dt: 0, t: 0)
    var loud = quiet
    loud.musicPeaks = Array(repeating: 0.8, count: 80)
    let quietImage = try #require(renderer.draw(quiet).cells?.dataProvider?.data as? Data)
    let loudImage = try #require(renderer.draw(loud).cells?.dataProvider?.data as? Data)
    #expect(quietImage != loudImage)
}
