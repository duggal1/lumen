import Foundation
import Testing
import Metal
import simd
import LumenCore
import LumenProject
import LumenDirector
@testable import LumenRender

@Test func clickEffectVisibilityAndDurationFollowSavedCursorPreferences() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4,
                            backingScale: 2, originX: 0, originY: 0)
    let events = [InputEvent(t: 1, kind: .down, x: 700, y: 350)]
    var timeline = Timeline(duration: 4)
    timeline.audio.speedRampsAuto = false
    timeline.cursor.clickDuration = 0.8
    timeline.cursor.clickEffect = .ripple
    timeline = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
    #expect(timeline.evaluate(at: 1.7).clickFX.count == 1)

    timeline.cursor.clickEffect = .none
    #expect(timeline.evaluate(at: 1.1).clickFX.isEmpty)

    timeline.cursor.clickEffect = .pulse
    timeline.cursor.clickDuration = 0.15
    #expect(timeline.evaluate(at: 1.3).clickFX.isEmpty)
}

// MARK: - Envelope

@Test func rippleEnvelopeStartsAndEndsAtNothing() {
    #expect(ClickEnvelope.amplitude(0) == 0)
    #expect(ClickEnvelope.amplitude(1) == 0)
    #expect(ClickEnvelope.amplitude(-1) == 0)
    #expect(ClickEnvelope.amplitude(2) == 0)
    #expect(ClickEnvelope.amplitude(0.5) > 0)
}

@Test func rippleEnvelopeIsContinuousWithOneHumpAndNoOvershoot() {
    let n = 2000
    var previous = ClickEnvelope.amplitude(0)
    var peak = previous, peakAt = 0.0, maxStep = 0.0
    for i in 1...n {
        let p = Double(i) / Double(n)
        let a = ClickEnvelope.amplitude(p)
        #expect(a >= 0 && a <= 1, "amplitude out of range at \(p)")
        maxStep = max(maxStep, Double(abs(a - previous)))
        if a > peak { peak = a; peakAt = p }
        previous = a
    }
    // Adjacent frames differ by less than a 1/255 step: nothing to see.
    #expect(maxStep < 0.01, "visible step between adjacent samples: \(maxStep)")
    #expect(peak > 0.55, "the ripple never really shows: peak \(peak)")
    #expect(peakAt > 0.05 && peakAt < 0.6, "peak sits at \(peakAt)")
    // Single hump: rises to the peak, then falls, never both.
    var before = ClickEnvelope.amplitude(0)
    for i in 1...n {
        let p = Double(i) / Double(n)
        let a = ClickEnvelope.amplitude(p)
        if p <= peakAt { #expect(a >= before - 1e-6, "dips before the peak at \(p)") }
        else { #expect(a <= before + 1e-6, "rises again after the peak at \(p)") }
        before = a
    }
    // Critically damped at both ends: no pop, no cut.
    #expect(ClickEnvelope.amplitude(0.002) < 0.002, "onset is not gentle enough")
    #expect(ClickEnvelope.amplitude(0.998) < 0.01, "tail does not settle")
}

// MARK: - Overlapping clicks

@Test func overlappingClicksKeepTheirOwnHotspotAndEnvelope() {
    let pulses = [ClickPulse(t: 1.0, position: [100, 200]), ClickPulse(t: 1.2, position: [700, 300])]
    let active = ClickPulses.active(pulses, at: 1.5, duration: 0.55)
    #expect(active.count == 2)
    #expect(active[0].position == SIMD2<Float>(100, 200))
    #expect(active[1].position == SIMD2<Float>(700, 300))
    // Each ripple ages on its own clock: the first pulse is older, so it is
    // further through its envelope than the second.
    #expect(active[0].progress > active[1].progress, "each ripple ages on its own clock")
    #expect(active.allSatisfy { $0.progress > 0 && $0.progress < 1 })
    #expect(active.allSatisfy { $0.amplitude > 0 })

    // The older one finishes while the newer is still expanding: no residual.
    let tail = ClickPulses.active(pulses, at: 1.56, duration: 0.55)
    #expect(tail.count == 1, "the finished ripple is gone")
    #expect(tail.first?.position.x == 700)
    #expect(ClickPulses.active(pulses, at: 2.0, duration: 0.55).isEmpty)
    #expect(ClickPulses.active(pulses, at: 0.5, duration: 0.55).isEmpty, "nothing before the click")
}

@Test func aTapRippleIsCentredOnTheTapHotspot() {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.overlays.taps = [TapIndicator(t: 2, x: 733, y: 411)]
    tl.cursor.clickEffect = .ripple
    tl.cursor.clickDuration = 0.55
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let state = tl.evaluate(at: 2.2)
    guard let ring = state.clickFX.first else { return }
    #expect(state.clickFX.count == 1)
    #expect(ring.position.x == 733, "the ripple is centred on the hotspot, not a smoothed point")
    #expect(ring.position.y == 411)
    #expect(ClickEnvelope.amplitude(Double(ring.progress)) > 0)
}

// MARK: - Preview / export parity

@Test func theRippleIsTheSameMotionInPreviewAndExport() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try Renderer()
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.style.background = .solid
    tl.style.colors = [RGBA(0x202020)]
    tl.camera.shutter = 0
    tl.cursor.clickEffect = .ripple
    tl.cursor.clickDuration = 0.55
    tl.cursor.clickColor = RGBA(0xFFFFFF, a: 0.6)
    let events = [InputEvent(t: 1.0, kind: .move, x: 600, y: 300),
                  InputEvent(t: 1.4, kind: .down, x: 600, y: 300),
                  InputEvent(t: 1.5, kind: .up, x: 600, y: 300)]
    tl = Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)
    guard let frame = LumenTestRender.solidFrame(device: device) else { return }
    let canvas = SIMD2<Int>(960, 540)
    let ring = tl.evaluate(at: 1.65).clickFX.first
    #expect(ring != nil, "the click is alive at 1.65")
    for t in [1.45, 1.65, 1.8] {
        guard let a = LumenTestRender.pixels(renderer, timeline: tl, t: t, canvas: canvas, quality: .preview, frame: frame),
              let b = LumenTestRender.pixels(renderer, timeline: tl, t: t, canvas: canvas, quality: .export, frame: frame) else { return }
        #expect(a.count == b.count)
        var worst = 0
        for i in 0..<a.count where a[i] != b[i] { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        #expect(worst == 0, "preview and export differ by \(worst) at t=\(t)")
    }
}