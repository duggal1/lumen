import Foundation
import Testing
import AVFoundation
import Metal
import CoreVideo
import simd
@testable import LumenAudio
@testable import LumenRender
import LumenCore
import LumenProject
@testable import LumenDirector
import LumenExport

/// Headless 2/3 AUDIO + RENDER adversarial acceptance checks.
/// Nothing here starts an audio engine, opens a window, plays sound or moves a
/// cursor. Audio is exercised through the real pack loader / sampler / mixer;
/// render is exercised through the real Metal renderer with read-back pixels.
private let advSource = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6,
                                   backingScale: 1, originX: 0, originY: 0)

// MARK: - AUDIO

/// Every macOS virtual keycode 0...127 must resolve to a real buffer, and the
/// resolution must be a pure function of the keycode (no random fallback, no
/// filesystem-order dependence). Modifiers are included in the full sweep.
@Test func brutalAll127MacKeycodesResolveDeterministically() throws {
    let dir = try #require(TypingPackLoader.dir(for: "mechvibes-default"))
    let buffers = TypingPackLoader.buffers(in: dir)
    #expect(buffers.count >= 80, "got \(buffers.count) key samples")
    let defined = Set(buffers.keys)

    // The W3C mapping is injective: two mac keycodes may not collapse onto one
    // Mechvibes code (that would silently merge two distinct recorded samples).
    let w3c = TypingPackLoader.macToMechvibes
    #expect(Set(w3c.values).count == w3c.values.count, "W3C mapping is not injective")

    let sampler = TypingSampler()
    sampler.load(packDir: dir)
    var resolved = Set<ObjectIdentifier>()
    for code in 0..<128 {
        let a = TypingPackLoader.packCode(for: code, definedIn: defined)
        let b = TypingPackLoader.packCode(for: code, definedIn: defined)
        #expect(a == b, "packCode not pure for keycode \(code)")
        if defined.contains(code) {
            #expect(a == code, "defined keycode \(code) lost its exact sample")
        } else {
            #expect(a == nil, "undefined keycode \(code) falsely claimed an exact sample")
        }
        let r1 = sampler.resolvedBuffer(for: code)
        let r2 = sampler.resolvedBuffer(for: code)
        #expect(r1 != nil, "keycode \(code) resolved to no buffer at all")
        #expect(r1 === r2, "keycode \(code) flipped between buffers on repeated lookup")
        if let r1 { resolved.insert(ObjectIdentifier(r1)) }
    }
    print("KEYCODES 0..127 resolved; defined=\(defined.count) distinctBuffers=\(resolved.count)")
}

/// A rapid storm of 1000 key-downs must never clip, produce NaN/Inf samples,
/// or change the mix on a second run (deterministic export requirement).
@Test func brutalThousandKeyStormMixesFiniteAndDeterministic() throws {
    var events: [InputEvent] = []
    events.reserveCapacity(1000)
    for i in 0..<1000 {
        let code = UInt16((i * 37 + 11) % 128)
        let t = 0.01 + Double(i) * 0.0059
        events.append(InputEvent(t: t, kind: .keyDown, keyCode: code))
    }
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let derived = Director.derive(tl, input: DirectorInput(events: events, source: advSource), revision: 1)
    let keys = (derived.derived?.cues ?? []).filter { $0.kind == .key }
    #expect(keys.count == 1000, "expected 1000 key cues, got \(keys.count)")

    let mic = [Float](repeating: 0, count: 6 * 48_000)
    let mixer = AudioMixer(mic: mic, micOffset: 0, system: nil, systemOffset: 0)
    let a = try #require(mixer.mix(derived))
    let b = try #require(mixer.mix(derived))
    #expect(a.l == b.l && a.r == b.r, "1000-key storm mix is not deterministic")
    #expect(a.l.allSatisfy { $0.isFinite && abs($0) <= 1 }, "left channel non-finite or clipped")
    #expect(a.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "right channel non-finite or clipped")
    #expect(a.lufs.isFinite, "LUFS not finite")
    #expect(a.truePeakDb <= -1, "storm clipped: true peak \(a.truePeakDb) dBTP")
    print("STORM 1000 keys: truePeak=\(String(format: "%.2f", a.truePeakDb))dBTP lufs=\(String(format: "%.2f", a.lufs))")
}

/// Corrupt / missing audio assets degrade to silence, never to generated noise
/// and never to a crash. This covers the loader, the preview sampler and SFX.
@Test func brutalCorruptAndMissingAudioAssetsDegradeToSilence() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("brutal2-assets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 1. Malformed JSON config.
    let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try Data("{ this is not json".utf8).write(to: corrupt.appendingPathComponent("config.json"))
    #expect(TypingPackLoader.buffers(in: corrupt).isEmpty)

    // 2. Valid config, missing audio file, and a null definition entry.
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    let cfg = """
    {"definition_method":"single","audio_file":"does-not-exist.aiff",
     "definitions":{"KeyA":{"timing":[[0,100],[100,200]]},"KeyB":null}}
    """
    try Data(cfg.utf8).write(to: missing.appendingPathComponent("config.json"))
    #expect(TypingPackLoader.buffers(in: missing).isEmpty)

    // 3. Empty directory and a directory that is not a pack.
    #expect(TypingPackLoader.buffers(in: root).isEmpty)

    // The sampler must tolerate every one of those packs without trapping.
    let sampler = TypingSampler()
    for pack in [corrupt, missing, root] {
        sampler.load(packDir: pack)
        #expect(sampler.resolvedBuffer(for: 55) == nil, "missing pack produced a phantom buffer")
        sampler.play(packCode: 0, gain: 1)
        sampler.play(keyCode: 55, gain: 1, hostTime: 0)
    }

    // Real SFX bank still yields finite (or empty, for whoosh) samples.
    let bank = SFXBank()
    for kind in [SFXCue.Kind.click, .key, .whooshIn, .whooshOut] {
        let (samples, gain) = bank.render(kind)
        #expect(samples.allSatisfy { $0.isFinite }, "\(kind) rendered non-finite samples")
        #expect(gain.isFinite)
        if kind == .whooshIn || kind == .whooshOut {
            #expect(samples.isEmpty, "\(kind) must be silent")
        }
    }
    #expect(BundledAudioAssets.typingAttribution(for: "no-such-pack-\(UUID())") == nil)
}

/// Every magnification from 0.5x to 100x, under every cap, resolves to a real
/// ladder rung whose stages multiply back to the reported factor. The factor
/// must also be monotone in the requested magnification.
@Test func brutalExtremeMagnificationSweepIsHonestAndMonotonic() {
    let caps = [2, 5, 10, 100]
    var previous = [Int](repeating: 0, count: caps.count)
    var steps = 0
    var m = 0.5
    while m <= 100.0001 {
        for (i, cap) in caps.enumerated() {
            let f = Upscaler.factor(forMagnification: m, maxFactor: cap)
            #expect(Upscaler.ladder.contains(f), "m=\(m) cap=\(cap): \(f) is not a real rung")
            #expect(f >= 2 && f <= 10, "m=\(m) cap=\(cap): \(f) outside 2..10")
            #expect(f <= cap, "m=\(m): factor \(f) exceeded cap \(cap)")
            #expect(Upscaler.stages(f).reduce(1, *) == f, "m=\(m): stages do not multiply to \(f)")
            #expect(f >= previous[i], "m=\(m) cap=\(cap): factor decreased from \(previous[i]) to \(f)")
            previous[i] = f
            let b = Upscaler.blend(forMagnification: m, UpscaleParams())
            #expect(b.isFinite && b >= 0 && b <= 1, "m=\(m): invalid blend \(b)")
        }
        steps += 1
        m += 0.5
    }
    #expect(steps == 200)
}

// MARK: - RENDER

/// Hostile camera centres and scales must be clamped to finite, in-source
/// coordinates before they can reach shader uniforms. NaN is not a valid
/// camera value. (Regression guard: ZoomTransform.clamp currently lets a NaN
/// focus or a NaN scale propagate — see the adversarial report for file:line.)
@Test func brutalNaNCameraNeverLeaksIntoGeometry() {
    let source = SIMD2<Double>(1920, 1080)
    let hostile: [SIMD2<Double>] = [
        SIMD2(.nan, 10), SIMD2(10, .nan), SIMD2(.nan, .nan),
        SIMD2(.infinity, 10), SIMD2(10, -.infinity),
        SIMD2(-1e12, 1e12)
    ]
    for focus in hostile {
        let out = ZoomTransform.clamp(focus, source: source, scale: 2)
        #expect(out.x.isFinite && out.y.isFinite, "clamp leaked \(focus) as \(out)")
        #expect(out.x >= 0 && out.x <= source.x && out.y >= 0 && out.y <= source.y,
                "clamp left source bounds for \(focus): \(out)")
    }
    let badScale = ZoomTransform.clamp(SIMD2(960, 540), source: source, scale: .nan)
    #expect(badScale.x.isFinite && badScale.y.isFinite, "NaN scale leaked as \(badScale)")
}

/// Hostile render requests (zero/negative/NaN fps, non-positive or NaN
/// shutter, NaN/out-of-range time, missing derived track, degenerate canvas)
/// must return one sub-frame without trapping.
@Test func brutalHostileRenderRequestsAreSafe() throws {
    var tl = Timeline(duration: 2)
    tl.audio.speedRampsAuto = false
    tl.camera.shutter = 0.6
    let derived = Director.derive(tl, input: DirectorInput(events: [], source: advSource), revision: 1)
    let renderer = try Renderer()
    // A tiny real texture is enough: sampleCount only reads metadata.
    let frame = try advFrame(renderer.device, 8, 8)
    let geometry = Geometry(canvas: SIMD2(64, 64), src: SIMD2(8, 8), style: derived.style)

    func subframes(_ timeline: Timeline, t: Double, fps: Double) -> Int {
        let req = RenderRequest(timeline: timeline, t: t, screen: frame,
                                canvas: SIMD2(64, 64), fps: fps, backingScale: 1)
        return renderer.sampleCount(req, geometry)
    }
    for fps in [0.0, -60, .nan, .infinity] {
        #expect(subframes(derived, t: 0.5, fps: fps) == 1, "fps \(fps) did not fall back to one sample")
    }
    for shutter in [0.0, -0.5, .nan] {
        var copy = derived; copy.camera.shutter = shutter
        #expect(subframes(copy, t: .nan, fps: 60) == 1, "shutter \(shutter) trapped or accumulated")
    }
    // No derived track: the pure static path is taken even with a NaN time.
    var bare = tl; bare.derived = nil
    #expect(subframes(bare, t: .nan, fps: 60) == 1)
    // Out-of-range but finite times clamp inside the timeline.
    #expect(subframes(derived, t: 1e12, fps: 60) >= 1)
    #expect(subframes(derived, t: -1e12, fps: 60) >= 1)
    // Degenerate canvases still construct without a trap.
    let zero = Geometry(canvas: .zero, src: SIMD2(8, 8), style: derived.style)
    let negative = Geometry(canvas: SIMD2(-4, -4), src: SIMD2(8, 8), style: derived.style)
    #expect(zero.content.x.isFinite && negative.content.x.isFinite)
}

/// Returning to a request after interleaving different live states and times
/// must produce byte-identical pixels — the compositor cache may not pollute.
@Test func brutalRepeatedRendersSurviveInterleavedStates() throws {
    let renderer = try Renderer()
    let frame = try advFrame(renderer.device, 64, 64)
    var tl = Timeline(duration: 2)
    tl.audio.speedRampsAuto = false
    tl.camera.shutter = 0
    tl.camera.upscaleEnabled = false
    tl.style.background = .solid
    let derived = Director.derive(tl, input: DirectorInput(events: [], source:
        SourceInfo(width: 64, height: 64, fps: 60, duration: 2, backingScale: 1,
                   originX: 0, originY: 0)), revision: 1)

    func live(_ c: Float, _ s: Float) -> FrameState {
        FrameState(cameraCenter: SIMD2(c, c), cameraScale: s,
                   cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                   clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 0)
    }
    let a = try advRender(renderer, derived, frame, t: 0.5, live: live(32, 1))
    _ = try advRender(renderer, derived, frame, t: 0.5, live: live(0, 8))
    _ = try advRender(renderer, derived, frame, t: 0.9, live: nil)
    let b = try advRender(renderer, derived, frame, t: 0.5, live: live(32, 1))
    #expect(a == b, "interleaved render states polluted the frame cache")
    #expect(a.count == 64 * 64 * 4)
}

// MARK: - minimal headless GPU helpers

private func advFrame(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> SourceFrame {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                 kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
          let buffer = pb else { throw RenderError.noDevice }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * h)
    }
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard let cache else { throw RenderError.noDevice }
    var cv: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cv)
    guard status == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else {
        throw RenderError.noDevice
    }
    return SourceFrame(id: 1, pts: 0, pixelBuffer: buffer, texture: texture, cv: cv)
}

private func advRender(_ renderer: Renderer, _ tl: Timeline, _ src: SourceFrame,
                       t: Double, live: FrameState?) throws -> [UInt8] {
    let w = 64, h = 64
    var req = RenderRequest(timeline: tl, t: t, screen: src, canvas: SIMD2(w, h),
                            fps: 60, backingScale: 1, quality: .export)
    req.live = live
    guard let pb = FrameImage.makeBuffer(w, h) else { throw RenderError.noDevice }
    let done = DispatchSemaphore(value: 0)
    guard renderer.render(req, into: pb, completion: { done.signal() }) else { throw RenderError.noDevice }
    guard case .success = done.wait(timeout: .now() + 20) else { throw RenderError.noDevice }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let stride = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { throw RenderError.noDevice }
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { memcpy(&out[y * w * 4], base.advanced(by: y * stride), w * 4) }
    return out
}
