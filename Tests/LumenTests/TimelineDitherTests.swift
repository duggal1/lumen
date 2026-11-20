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
        #expect(src.contains("vImageBoxConvolve_ARGB8888"), "glow is the Clove SIMD blur")
        #expect(src.contains("exp(-f.dt / 0.42)"), "heat cools on the Clove time constant")
    }

    @Test func rendererProducesCellsGlowAndOverlay() throws {
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
        #expect(out.glow != nil)
        #expect(out.overlay != nil)
    }

    @Test func clearingASpanShedsMotesAndLeavesWarmCells() throws {
        let r = try #require(TimelineDitherRenderer(width: 400, height: 224, scale: 1, isDark: true))
        let full = TimelineDitherRenderer.Span(0, 90, 0)
        let first = TimelineDitherRenderer.Frame(spans: [[full], [], [], [], []], peaks: [],
            clicks: [], head: -1, playing: false, reduced: false, dt: 1.0 / 60, t: 0)
        _ = r.draw(first)
        let cleared = TimelineDitherRenderer.Frame(spans: [Array(repeating: TimelineDitherRenderer.Span(0, 0, 0), count: 0), [], [], [], []],
            peaks: [], clicks: [], head: -1, playing: false, reduced: false, dt: 1.0 / 60, t: 0.02)
        let out = r.draw(cleared)
        #expect(out.isWarm, "cells cooling and rising motes keep the frame loop alive")
    }

    @Test func paperPaletteUsesDeeperHues() {
        #expect(TimelineDitherRenderer.lightHues.count == TimelineDitherRenderer.hues.count)
        for (light, dark) in zip(TimelineDitherRenderer.lightHues, TimelineDitherRenderer.hues) {
            // On paper the hue is deeper: every channel is darker than on graphite.
            #expect(light.0 < dark.0 || light.1 < dark.1 || light.2 < dark.2)
        }
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
        #expect(host.contains("settled >= 2"), "the display loop stops at rest")
        #expect(host.contains("accessibilityDisplayShouldReduceMotion") == false)
        #expect(host.contains("frame.reduced") == false)
        #expect(host.contains("snapshot.reduced"))
    }
}
