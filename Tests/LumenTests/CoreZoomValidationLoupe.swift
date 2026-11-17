import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Core-feature validation: Loupe zoom (classic zoom is covered by the
// planner suites; this pins the loupe half of "Zoom Types").
//
// Renderer source (read-only for this scope) wires these frames through
// `pLoupe` / `loupeFS` in Sources/LumenRender/Renderer.swift and Shaders.metal.
// Here we verify the loupe is fully authored, persisted and evaluated end to
// end through the real timeline. No window, no GPU.

@Suite struct CoreZoomValidationLoupeTests {
    private let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6,
                                 backingScale: 1, originX: 0, originY: 0)

    @Test func loupeFollowsCursorAndFixedTargetIsStable() {
        var tl = Timeline(duration: 6)
        tl.audio.speedRampsAuto = false
        tl.overlays.loupes = [
            Loupe(start: 1, end: 4, x: 0, y: 0, follow: true, radius: 0.12,
                  magnification: 3, round: true, cx: 0.8, cy: 0.8),
            Loupe(start: 2, end: 5, x: 350, y: 620, follow: false, radius: 0.08,
                  magnification: 2.5, round: false, cx: 0.2, cy: 0.3),
        ]
        let events = [InputEvent(t: 1.5, kind: .move, x: 700, y: 400),
                      InputEvent(t: 3.0, kind: .move, x: 1000, y: 520)]
        let out = Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)

        // Before any loupe: none.
        #expect(out.evaluate(at: 0.5).emphasis.loupes.isEmpty)

        let f2 = out.evaluate(at: 3.0).emphasis.loupes
        #expect(f2.count == 2, "both loupes must be active, got \(f2.count)")
        let follow = f2.first { $0.magnification == 3 }!
        let fixed = f2.first { $0.magnification == 2.5 }!
        // Follow: glass looks where the cursor is, not at Loupe.x/y (0,0).
        #expect(abs(follow.target.x - 1000) < 40 && abs(follow.target.y - 520) < 40,
                Comment(rawValue: "follow target \(follow.target)"))
        #expect(follow.round)
        #expect(abs(follow.glass.x - 0.8) < 1e-6 && abs(follow.glass.y - 0.8) < 1e-6)
        // Fixed: glass looks at its authored source pixel and ignores the cursor.
        #expect(abs(fixed.target.x - 350) < 1e-6 && abs(fixed.target.y - 620) < 1e-6,
                Comment(rawValue: "fixed target \(fixed.target)"))
        #expect(!fixed.round)

        // After the follow loupe ends but the fixed one is still active.
        let f45 = out.evaluate(at: 4.5).emphasis.loupes
        #expect(f45.count == 1 && f45[0].magnification == 2.5)
        #expect(out.evaluate(at: 5.5).emphasis.loupes.isEmpty)
    }

    /// A loupe and a classic camera zoom coexist: the classic zoom moves the
    /// frame while the loupe magnifies a detail over it.
    @Test func loupeCoexistsWithClassicZoom() {
        var tl = Timeline(duration: 6)
        tl.audio.speedRampsAuto = false
        tl.camera.autoZoom = false
        tl.zoom = [ZoomSegment(start: 1, end: 5, scale: 2.0,
                               focus: .fixed(x: 0.5, y: 0.5), origin: .manual)]
        tl.overlays.loupes = [Loupe(start: 2, end: 4, x: 900, y: 500, follow: false,
                                    radius: 0.1, magnification: 4, round: true)]
        let out = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
        let f = out.evaluate(at: 3)
        #expect(abs(Double(f.cameraScale) - 2.0) < 1e-4, "classic zoom missing")
        #expect(f.emphasis.loupes.count == 1)
        #expect(f.emphasis.loupes[0].magnification == 4)
    }

    /// Loupe geometry survives a project encode/decode round trip (the glass
    /// can be dragged and re-opened later).
    @Test func loupePersistsRoundTrip() throws {
        var tl = Timeline(duration: 6)
        tl.overlays.loupes = [Loupe(start: 1, end: 4, x: 123, y: 456, follow: false,
                                    radius: 0.15, magnification: 5, round: false,
                                    cx: 0.33, cy: 0.66, border: 0.008, shadow: 0.7)]
        let data = try JSONEncoder().encode(tl)
        let back = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(back.overlays.loupes.count == 1)
        let l = back.overlays.loupes[0]
        #expect(l.x == 123 && l.y == 456 && !l.follow && l.magnification == 5 &&
                l.radius == 0.15 && !l.round && abs(l.cx - 0.33) < 1e-9 && abs(l.cy - 0.66) < 1e-9)
    }
}
