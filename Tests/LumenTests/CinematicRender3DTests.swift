import Foundation
import Testing
import simd
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector
@testable import LumenRender

// MARK: - Cinematic 3D geometry and control (headless, no GPU required)
//
// Every test here exercises the exact pure functions the render path calls to
// constrain and warp tilt. The GPU pixel tests live in CinematicRender3DGPUTests.

private let c3dSource = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4,
                                   backingScale: 1, originX: 0, originY: 0)

private func c3dDerived(_ mode: TiltMode, events: [InputEvent]? = nil,
                        configure: ((inout Timeline) -> Void)? = nil) -> Timeline {
    var tl = Timeline(duration: 3)
    tl.audio.speedRampsAuto = false
    tl.camera.tilt = mode
    configure?(&tl)
    let ev = events ?? (0...20).map { InputEvent(t: Double($0) * 0.1, kind: .move,
                                                 x: Float(100 + $0 * 80), y: 540) }
    return Director.derive(tl, input: DirectorInput(events: ev, source: c3dSource), revision: 1)
}

struct CinematicRender3DControlTests {

    @Test func offIsFlatEvenWithLeakedNonzeroState() {
        let leaked = SIMD2<Float>(12, -9)
        let flat = CameraTilt.effective(leaked, mode: .off, maxYaw: 8, maxPitch: 6)
        #expect(flat == .zero, "off must discard any leaked tilt, got \(flat)")
        #expect(CameraTilt.isFlat(flat))
        // Homography is exactly identity => no sampling deviation => flat frame.
        for n in [SIMD2<Float>(-0.5, -0.5), .zero, SIMD2<Float>(0.5, 0.5), SIMD2<Float>(0.31, -0.17)] {
            #expect(CameraTilt.homography(n, tiltDeg: flat) == n)
        }
        #expect(CameraTilt.revealScale(mode: .off, tilt: leaked) == 1)
        // Director agrees: with .off every derived tilt sample is zero.
        let out = c3dDerived(.off)
        #expect(out.derived?.camera.yaw.allSatisfy { $0 == 0 } == true)
        #expect(out.derived?.camera.pitch.allSatisfy { $0 == 0 } == true)
        for t in stride(from: 0.0, through: 2.9, by: 0.1) {
            #expect(out.evaluate(at: t).cameraTilt == .zero)
        }
    }

    @Test func leanHonorsConfiguredAndHardLimits() {
        let hostile: [SIMD2<Float>] = [
            SIMD2(1e9, -1e9), SIMD2(-99, 99), SIMD2(.nan, 3), SIMD2(4, .infinity),
            SIMD2(.infinity, -.infinity), SIMD2(Float.greatestFiniteMagnitude, 0)
        ]
        for raw in hostile {
            let t = CameraTilt.effective(raw, mode: .lean, maxYaw: 8, maxPitch: 6)
            #expect(t.x.isFinite && t.y.isFinite)
            #expect(abs(t.x) <= CameraTilt.maxYaw + 1e-5, "yaw \(t.x) exceeded 8")
            #expect(abs(t.y) <= CameraTilt.maxPitch + 1e-5, "pitch \(t.y) exceeded 6")
        }
        // User knob below the hard cap wins; above the cap it is clamped.
        let tight = CameraTilt.effective(SIMD2(12, -12), mode: .lean, maxYaw: 3, maxPitch: 2)
        #expect(abs(tight.x - 3) < 1e-5 && abs(tight.y + 2) < 1e-5)
        let loose = CameraTilt.effective(SIMD2(99, -99), mode: .lean, maxYaw: 40, maxPitch: 40)
        #expect(abs(loose.x - 8) < 1e-5 && abs(loose.y + 6) < 1e-5)
    }

    @Test func offModeIsCompletelyFlat() {
        let raw = SIMD2<Float>(1e9, -1e9)
        let t = CameraTilt.effective(raw, mode: .off, maxYaw: 8, maxPitch: 6)
        #expect(t.x == 0 && t.y == 0)
        let out = c3dDerived(.off)
        let maxYaw = out.derived?.camera.yaw.map { abs(Double($0)) }.max() ?? .infinity
        let maxPitch = out.derived?.camera.pitch.map { abs(Double($0)) }.max() ?? .infinity
        #expect(maxYaw < 1e-5, "off mode must be completely flat")
        #expect(maxPitch < 1e-5, "off mode must be completely flat")
    }

    @Test func leanFollowsCameraVelocityAndSettles() {
        var events = (0...20).map { InputEvent(t: Double($0) * 0.1, kind: .move,
                                               x: Float(100 + $0 * 80), y: 540) }
        events.append(InputEvent(t: 0.5, kind: .down, x: 1700, y: 540))
        let out = c3dDerived(.lean, events: events)
        let maxYaw = out.derived?.camera.yaw.map { abs(Double($0)) }.max() ?? 0
        #expect(maxYaw > 0.5, "lean must yaw during a pan, got \(maxYaw)")
        #expect(maxYaw <= Double(CameraTilt.maxYaw) + 1e-3)
        let maxPitch = out.derived?.camera.pitch.map { abs(Double($0)) }.max() ?? 0
        #expect(maxPitch <= Double(CameraTilt.maxPitch) + 1e-3)
        // Horizontal pan only: pitch stays small relative to yaw.
        #expect(maxPitch <= maxYaw + 1e-3)
        // At rest the lean settles back toward flat.
        let tail = out.evaluate(at: 2.9).cameraTilt
        #expect(abs(tail.x) < 1.0, "lean must settle, got \(tail.x)")
    }

    @Test func revealEntranceAndSettle() {
        let start = CameraTilt.effective(SIMD2(99, 99), mode: .reveal, maxYaw: 8, maxPitch: 6)
        #expect(abs(start.x - 12) < 1e-5, "reveal entrance yaw must be 12, got \(start.x)")
        #expect(abs(start.y - 6) < 1e-5)
        #expect(CameraTilt.revealScale(mode: .reveal, tilt: start) < 0.921)
        #expect(CameraTilt.revealScale(mode: .reveal, tilt: .zero) == 1)
        let out = c3dDerived(.reveal)
        #expect(abs(Double(out.derived?.camera.yaw[0] ?? 0) - 12) < 0.1)
        let end = out.evaluate(at: 2.9).cameraTilt
        #expect(abs(end.x) < 0.5, "reveal must settle, got \(end.x)")
        // Monotone decay from the entrance (no overshoot / bounce).
        let samples = (0...20).map { Double(abs(out.evaluate(at: Double($0) * 0.1).cameraTilt.x)) }
        for i in 1..<samples.count {
            #expect(samples[i] <= samples[i - 1] + 1e-3, "reveal \(i) bounced: \(samples)")
        }
    }
}

struct CinematicRender3DGeometryTests {

    @Test func homographyNeverLeavesUnitSquare() {
        var cases = 0
        for yaw in stride(from: -18.0, through: 18.0, by: 1.5) {
            for pitch in stride(from: -18.0, through: 18.0, by: 1.5) {
                let tilt = SIMD2<Float>(Float(yaw), Float(pitch))
                for i in 0...8 {
                    for j in 0...8 {
                        let n = SIMD2<Float>(Float(i) / 8 - 0.5, Float(j) / 8 - 0.5)
                        let s = CameraTilt.homography(n, tiltDeg: tilt)
                        #expect(s.x.isFinite && s.y.isFinite)
                        #expect(abs(s.x) <= 0.5 + 1e-6, "s.x \(s.x) outside quad at \(tilt)")
                        #expect(abs(s.y) <= 0.5 + 1e-6, "s.y \(s.y) outside quad at \(tilt)")
                        cases += 1
                    }
                }
            }
        }
        #expect(cases > 20_000)
    }

    @Test func homographyIsPerspectiveNotGlitch() {
        let yaw = SIMD2<Float>(8, 0)
        // Far edge compresses: right edge samples a smaller region than centre.
        let centre = CameraTilt.homography(SIMD2(0, 0), tiltDeg: yaw)
        let right = CameraTilt.homography(SIMD2(0.5, 0), tiltDeg: yaw)
        let left = CameraTilt.homography(SIMD2(-0.5, 0), tiltDeg: yaw)
        #expect(abs(centre.x) < 1e-6)
        #expect(right.x < 0.5 - 1e-3, "yaw must compress the far edge, got \(right.x)")
        #expect(left.x < -0.5 + 1e-3, "near edge must not expand, got \(left.x)")
        // Keystone: vertical scale differs between near and far vertical edges.
        let topRight = CameraTilt.homography(SIMD2(0.5, 0.4), tiltDeg: yaw).y
        let topLeft = CameraTilt.homography(SIMD2(-0.5, 0.4), tiltDeg: yaw).y
        #expect(abs(topRight - topLeft) > 0.004, "yaw must keystone, \(topRight) vs \(topLeft)")
        // Strictly monotone along x for fixed y: no flat clamped bands.
        let y: Float = 0.25
        var prev: Float = -1
        for i in 0...64 {
            let n = SIMD2<Float>(Float(i) / 64 - 0.5, y)
            let x = CameraTilt.homography(n, tiltDeg: yaw).x
            #expect(x > prev, "warp plateau (glitch) at \(i): \(x) <= \(prev)")
            prev = x
        }
        // Pitch is the vertical analogue, and zero tilt is exact identity.
        let pitch = CameraTilt.homography(SIMD2(0, 0.5), tiltDeg: SIMD2(0, 6))
        #expect(pitch.y < 0.5 - 1e-3)
        #expect(CameraTilt.homography(SIMD2(0.3, -0.2), tiltDeg: .zero) == SIMD2(0.3, -0.2))
    }

    @Test func hostileInputsNeverProduceNaN() {
        let hostile: [Float] = [.nan, .infinity, -.infinity, Float.greatestFiniteMagnitude, 1e9]
        for a in hostile {
            for b in hostile {
                let tilt = SIMD2(a, b)
                let s = CameraTilt.homography(SIMD2(a, b), tiltDeg: tilt)
                #expect(s.x.isFinite && s.y.isFinite)
                #expect(abs(s.x) <= 0.5 + 1e-6 && abs(s.y) <= 0.5 + 1e-6)
                let p = CameraTilt.sourcePoint(normalized: SIMD2(a, b), tiltDeg: tilt,
                                               camera: SIMD2(Double(a), Double(b)),
                                               view: SIMD2(100, 100),
                                               crop: CGRect(x: Double(a), y: Double(b), width: Double(a), height: Double(b)),
                                               sourceSize: SIMD2(1920, 1080))
                #expect(p.x.isFinite && p.y.isFinite)
            }
        }
    }

    @Test func smartCropContainsEveryTiltedSample() {
        let source = SIMD2<Double>(1920, 1080)
        let crops = [
            CGRect.zero,
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 320, y: 180, width: 640, height: 360),      // intelligent Area crop
            CGRect(x: 1500, y: 900, width: 300, height: 120),     // corner crop
            CGRect(x: -50, y: -50, width: 4000, height: 4000)     // oversized -> intersected
        ]
        let tilts = [SIMD2<Float>(0, 0), SIMD2(8, 6), SIMD2(-8, -6), SIMD2(12, 6), SIMD2(-12, -6)]
        for crop in crops {
            let bounds = CameraTilt.validCrop(crop, sourceSize: source)
            for tilt in tilts {
                for scale in [1.0, 1.5, 4.0, 20.0] {
                    let view = SIMD2(bounds.width, bounds.height) / scale
                    // Same camera clamp the renderer uses (ZoomTransform.clamp).
                    let centre = ZoomTransform.clamp(
                        SIMD2(bounds.midX, bounds.midY), source: SIMD2(bounds.width, bounds.height), scale: scale)
                    let camera = SIMD2(centre.x + bounds.minX, centre.y + bounds.minY)
                    for i in 0...16 {
                        for j in 0...16 {
                            let n = SIMD2<Float>(Float(i) / 16 - 0.5, Float(j) / 16 - 0.5)
                            let p = CameraTilt.sourcePoint(normalized: n, tiltDeg: tilt, camera: camera,
                                                           view: view, crop: crop, sourceSize: source)
                            #expect(p.x >= bounds.minX - 1e-6 && p.x <= bounds.maxX + 1e-6,
                                    "sample \(p.x) escaped crop \(bounds) at tilt \(tilt)")
                            #expect(p.y >= bounds.minY - 1e-6 && p.y <= bounds.maxY + 1e-6,
                                    "sample \(p.y) escaped crop \(bounds) at tilt \(tilt)")
                            #expect(p.x >= 0 && p.x <= source.x && p.y >= 0 && p.y <= source.y,
                                    "sample \(p) escaped source texture")
                        }
                    }
                }
            }
        }
    }
}

struct CinematicRender3DDeterminismTests {

    @Test func sameInputSameTiltBitwise() {
        let a = c3dDerived(.lean)
        let b = c3dDerived(.lean)
        #expect(a.derived?.camera.yaw == b.derived?.camera.yaw)
        #expect(a.derived?.camera.pitch == b.derived?.camera.pitch)
        for t in [0.0, 0.13, 0.5, 1.0, 2.7] {
            #expect(a.evaluate(at: t).cameraTilt == b.evaluate(at: t).cameraTilt)
        }
        // Pure geometry is equally repeatable.
        let n = SIMD2<Float>(0.4, -0.3), tilt = SIMD2<Float>(8, 6)
        #expect(CameraTilt.homography(n, tiltDeg: tilt) == CameraTilt.homography(n, tiltDeg: tilt))
    }

    @Test func subFramesCarryTheirOwnTiltAtEveryExportRate() {
        let derived = c3dDerived(.reveal)
        // A frame's motion-blur sub-frames are evaluated at t + (i+0.5)/K-0.5
        // times a shutter window. The tilt must differ across those times and
        // must be identical for the same absolute time regardless of the fps
        // grid used to get there (60 / 120 / 240 export).
        var seen = Set<UInt32>()
        for fps in [60.0, 120.0, 240.0] {
            let dt = 1 / fps
            for t in [0.05, 0.2, 0.5] {
                let early = derived.evaluate(at: t - dt / 2).cameraTilt
                let late = derived.evaluate(at: t + dt / 2).cameraTilt
                #expect(early != late, "sub-frames froze tilt at \(t) @ \(fps)fps")
                seen.insert(early.x.bitPattern)
                seen.insert(late.x.bitPattern)
            }
        }
        #expect(seen.count >= 6, "expected distinct per-sub-frame tilts, got \(seen.count)")
        // Same absolute output time -> same tilt on any fps grid.
        let reference = derived.evaluate(at: 0.2).cameraTilt
        for fps in [60.0, 120.0, 240.0] {
            let steps = Int(0.2 * fps)
            let t = Double(steps) / fps
            #expect(derived.evaluate(at: t).cameraTilt == derived.evaluate(at: t).cameraTilt)
            #expect(abs(Double(derived.evaluate(at: t).cameraTilt.x - reference.x)) < 1e-3)
        }
    }

    @Test func modeGateRunsAfterEvaluationNotInsteadOfIt() {
        // A stale nonzero tilt in a live FrameState must be dropped for .off,
        // but a real .lean tilt must survive the render gate unchanged (within
        // its limit). This proves the gate is a mode filter, not a blanket zero.
        let raw = SIMD2<Float>(12, 6)
        let off = CameraTilt.effective(raw, mode: .off, maxYaw: 8, maxPitch: 6)
        let lean = CameraTilt.effective(raw, mode: .lean, maxYaw: 8, maxPitch: 6)
        let reveal = CameraTilt.effective(raw, mode: .reveal, maxYaw: 8, maxPitch: 6)
        #expect(off == .zero)
        #expect(lean == SIMD2(8, 6))
        #expect(reveal == SIMD2(12, 6))
    }
}
