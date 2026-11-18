import Testing
import Foundation
import AVFoundation
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

/// Headless keyboard-audio acceptance tests. Nothing here starts an audio engine,
/// plays sound, opens a window, or touches the user's keyboard.
private let kSource = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6,
                                 backingScale: 1, originX: 0, originY: 0)
private let kPackID = "mechvibes-default"

private func derive(_ events: [InputEvent], zoom: [ZoomSegment] = [],
                    configure: (inout Timeline) -> Void = { _ in }) -> Timeline {
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    tl.zoom = zoom
    configure(&tl)
    return Director.derive(tl, input: DirectorInput(events: events, source: kSource), revision: 1)
}

// MARK: 1. No zoom whoosh, ever

@Test func KeyboardAudionoZoomWhooshCuesAreEverGenerated() {
    let zoom = [ZoomSegment(start: 1, end: 2.2, scale: 2, focus: .follow, origin: .auto),
                ZoomSegment(start: 3, end: 4, scale: 2.4, focus: .follow, origin: .auto)]
    let t = derive([], zoom: zoom)
    let whooshes = (t.derived?.cues ?? []).filter { $0.kind == .whooshIn || $0.kind == .whooshOut }
    #expect(whooshes.isEmpty, "default AudioPlan must generate zero whoosh events")
}

@Test func KeyboardAudiolegacyWhooshSettingsCannotReEnableWhoosh() throws {
    let json = "{\"whooshes\":true,\"zoomInGainDb\":12,\"zoomOutGainDb\":9,\"soundEffectsEnabled\":true}"
    let plan = try JSONDecoder().decode(AudioPlan.self, from: Data(json.utf8))
    #expect(plan.whooshes == false)
    #expect(plan.zoomInGainDb == 0)
    #expect(plan.zoomOutGainDb == 0)
    #expect(AudioPlan().whooshes == false)

    var tl = Timeline(duration: 6)
    tl.audio = plan
    tl.zoom = [ZoomSegment(start: 1, end: 3, scale: 2, focus: .follow, origin: .auto)]
    let t = Director.derive(tl, input: DirectorInput(events: [], source: kSource), revision: 1)
    #expect((t.derived?.cues ?? []).allSatisfy { $0.kind != .whooshIn && $0.kind != .whooshOut })
}

@Test func KeyboardAudiowhooshCuesRenderSilence() {
    let bank = SFXBank()
    for kind in [SFXCue.Kind.whooshIn, .whooshOut] {
        let (samples, gain) = bank.render(kind)
        #expect(samples.isEmpty, "\(kind) must render no audio")
        #expect(gain == 0)
    }
    #expect(BundledAudioAssets.whooshAssetsBundled == false)
}

// MARK: 2. keyDown timing offset

@Test func KeyboardAudiokeyDownCueLandsExactlyAtTheEventTime() {
    let t = derive([InputEvent(t: 2, kind: .keyDown, keyCode: 0),
                    InputEvent(t: 2.25, kind: .keyDown, keyCode: 55)])
    let keys = (t.derived?.cues ?? []).filter { $0.kind == .key }.sorted { $0.t < $1.t }
    #expect(keys.count == 2)
    #expect(abs(keys[0].t - 2.0) < 1e-6)          // zero added latency
    #expect(abs(keys[1].t - 2.25) < 1e-6)
    #expect(keys[0].keyCode == 0)
    #expect(keys[1].keyCode == 55)                // Command survives as a key cue
    let fs = 48_000
    #expect(abs(keys[0].t * Double(fs) - 96_000) <= 1) // within one sample at 48 kHz
}

@Test func KeyboardAudiokeyDownCueFollowsTheTimeMap() {
    let t = derive([InputEvent(t: 2, kind: .keyDown, keyCode: 0)]) { tl in
        tl.timeMap.trimStart = 1
    }
    let keys = (t.derived?.cues ?? []).filter { $0.kind == .key }
    #expect(keys.count == 1)
    #expect(abs(keys[0].t - 1.0) < 1e-6)          // source 2.0 -> output 1.0
}

@Test func KeyboardAudiocutKeyDownsAreSilent() {
    let t = derive([InputEvent(t: 1, kind: .keyDown, keyCode: 55),
                    InputEvent(t: 2, kind: .keyDown, keyCode: 56)]) { tl in
        tl.timeMap.cuts = [CutRange(start: 0.9, end: 1.1)]
    }
    let keys = (t.derived?.cues ?? []).filter { $0.kind == .key }
    #expect(keys.count == 1)
    #expect(keys[0].keyCode == 56)
}

// MARK: 3. Every key, including modifiers, has a distinct real recording

@Test func KeyboardAudioeveryKeyIncludingModifiersHasItsOwnSample() throws {
    let dir = try #require(TypingPackLoader.dir(for: kPackID))
    let buffers = TypingPackLoader.buffers(in: dir)
    #expect(buffers.count >= 80, "got \(buffers.count) key samples")
    let defined = Set(buffers.keys)

    // Command, Shift, Option, Control — left and right, plus caps and escape.
    let modifiers: [Int: String] = [54: "right Command", 55: "left Command",
                                    56: "left Shift", 60: "right Shift",
                                    58: "left Option", 61: "right Option",
                                    59: "left Control", 62: "right Control"]
    for (code, label) in modifiers {
        #expect(TypingPackLoader.macToMechvibes[code] != nil, "\(label) unmapped")
        #expect(TypingPackLoader.packCode(for: code, definedIn: defined) == code, "\(label) has no exact sample")
        let buf = try #require(buffers[code], "\(label) has no buffer")
        #expect(buf.frameLength > 0, "\(label) sample is empty")
    }

    // All other mapped keys (letters, digits, punctuation, arrows, F-keys, keypad).
    for code in TypingPackLoader.macToMechvibes.keys {
        #expect(buffers[code] != nil, "key \(code) fell back instead of using its own sample")
    }
    #expect(buffers[63] != nil, "Fn must have a real recorded modifier sample")

    // Distinct recordings, not eight copies of one sample.
    func signature(_ buf: AVAudioPCMBuffer) -> [Int] {
        guard let ch = buf.floatChannelData else { return [] }
        let n = min(48, Int(buf.frameLength))
        return (0..<n).map { Int(ch[0][$0] * 32767) }
    }
    let shapes = Set(modifiers.keys.compactMap { buffers[$0] }.map(signature))
    #expect(shapes.count >= 4, "modifier samples must not all be identical")
}

@Test func KeyboardAudiokeyDownSliceStartsAtTheRecordedDownOnset() throws {
    let dir = try #require(TypingPackLoader.dir(for: kPackID))
    let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    let pack = try JSONDecoder().decode(KeyPack.self, from: data)
    #expect(pack.isV2)
    #expect(pack.audio_file == "sound.aiff") // AIFF is not gitignored; WAV is
    let def = try #require(pack.definitions["MetaLeft"] ?? nil)
    let slice = try #require(def.downSlice)
    // Upstream Cherry MX Blue PBT: MetaLeft down = [43435, 43512.5] ms.
    #expect(abs(slice.start - 43_435) < 1)
    #expect(abs(slice.duration - 77.5) < 1)
    let second = def.timing[1]
    #expect(second[0] == slice.start + slice.duration) // release is a separate window

    let file = try AVAudioFile(forReading: dir.appendingPathComponent("sound.aiff"))
    let sliced = try sliceBuffer(file, startMs: slice.start, durMs: slice.duration)
    let buf = try #require(sliced)
    #expect(buf.frameLength > 0)
    #expect(abs(Double(buf.frameLength) / file.processingFormat.sampleRate - slice.duration / 1000) < 0.01)
}

// MARK: 4. Determinism, licensing, no clipping

@Test func KeyboardAudiopackSelectionIsDeterministic() {
    for _ in 0..<20 {
        #expect(TypingPackLoader.resolvedPackID(for: "does-not-exist") == kPackID)
        #expect(TypingPackLoader.resolvedPackID(for: kPackID) == kPackID)
    }
    let packs = TypingPackLoader.availablePacks().map(\.lastPathComponent)
    #expect(packs == packs.sorted())
    let dir = try? TypingPackLoader.dir(for: kPackID)
    #expect(dir != nil)
}

@Test func KeyboardAudiotypingMixDoesNotClip() throws {
    var events: [InputEvent] = []
    let keys = [0, 55, 56, 58, 59, 49, 36, 51]
    for i in 0..<48 {
        events.append(InputEvent(t: 0.5 + Double(i) * 0.05, kind: .keyDown,
                                 keyCode: UInt16(keys[i % keys.count])))
    }
    let t = derive(events)
    let mic = [Float](repeating: 0, count: 6 * 48_000)
    let mixer = AudioMixer(mic: mic, micOffset: 0, system: nil, systemOffset: 0)
    let mixed = try #require(mixer.mix(t))
    #expect(mixed.lufs.isFinite)
    #expect(mixed.truePeakDb <= -1, "true peak \(mixed.truePeakDb) dBTP clips")
    #expect(mixed.l.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect(mixed.r.allSatisfy { $0.isFinite && abs($0) <= 1 })

    // The recorded tap fallback is normalised too.
    let (fallback, _) = SFXBank().render(.key)
    #expect(!fallback.isEmpty)
    #expect((fallback.reduce(Float(0)) { max($0, abs($1)) }) <= 1)
}

@Test func KeyboardAudiomechvibesLicenseAndAttributionAreBundled() throws {
    let dir = try #require(TypingPackLoader.dir(for: kPackID))
    let attribution = try #require(BundledAudioAssets.typingAttribution(for: kPackID))
    #expect(attribution.localizedCaseInsensitiveContains("MIT"))
    #expect(attribution.localizedCaseInsensitiveContains("mechvibes"))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("LICENSE").path))
    let license = try String(contentsOf: dir.appendingPathComponent("LICENSE"), encoding: .utf8)
    #expect(license.contains("MIT License"))
    #expect(license.contains("Hải Nguyễn") || license.contains("Hai Nguyen"))
    // Only audio + config; no upstream source code was copied into the bundle.
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    #expect(files.allSatisfy { !["rs", "ts", "js", "swift"].contains($0.pathExtension.lowercased()) })
    let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    let pack = try JSONDecoder().decode(KeyPack.self, from: data)
    #expect(pack.author == "Mechvibes")
    #expect(pack.attribution?.localizedCaseInsensitiveContains("mechvibes") == true)
}

// MARK: 5. Brutal acceptance tests (Q4) — measurable, not by ear

/// Every recorded sample in the bundled pack must be reachable through a macOS
/// virtual keycode. An unrecognised W3C name means a real mechvibes recording
/// is silently unreachable and that key falls back to another key's sound.
@Test func KeyboardAudioeveryRecordedPackSampleIsReachableByKeycode() throws {
    let dir = try #require(TypingPackLoader.dir(for: kPackID))
    let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    let pack = try JSONDecoder().decode(KeyPack.self, from: data)
    let buffers = TypingPackLoader.buffers(in: dir)
    let reachable = Set(buffers.keys)
    #expect(buffers.count >= 104, "only \(buffers.count) of 104 recorded samples decoded")
    for name in pack.definitions.keys {
        let mac = TypingPackLoader.mechvibesToMac[name]
        #expect(mac != nil, "pack sample '\(name)' has no macOS keycode mapping (unreachable recording)")
        if let mac { #expect(reachable.contains(mac), "pack sample '\(name)' (key \(mac)) produced no buffer") }
    }
}

/// The acoustic attack of each key sample must land at the scheduled keyDown
/// instant. Leading silence in the source recording shifts every keystroke late.
/// Measured as the first sample at >= 5% of that slice's peak; must be sample 0.
@Test func KeyboardAudiokeySampleOnsetIsAlignedToKeyDown() throws {
    let dir = try #require(TypingPackLoader.dir(for: kPackID))
    let buffers = TypingPackLoader.buffers(in: dir)
    #expect(buffers.count >= 104)
    var worstMs = 0.0, worstCode = -1, lagging = 0
    for (code, buf) in buffers {
        guard let ch = buf.floatChannelData else { continue }
        let n = Int(buf.frameLength), fs = buf.format.sampleRate
        let pcm = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-4, fs > 0 else { continue }
        let threshold = peak * 0.05
        let onset = pcm.firstIndex { abs($0) >= threshold } ?? n
        let ms = Double(onset) / fs * 1000
        if ms > worstMs { worstMs = ms; worstCode = code }
        if ms > 2 { lagging += 1 }
    }
    #expect(worstMs <= 2.0, "worst key onset lag \(worstMs) ms at keyCode \(worstCode); \(lagging) samples lag")
}

/// A 1000-key storm at 1 ms spacing is a hostile but legal input. The master
/// must hold the -1 dBTP ceiling without suppressing normal typing.
@Test func KeyboardAudiothousandKeyStormDoesNotClip() throws {
    let keys: [UInt16] = [0, 55, 56, 58, 59, 49, 36, 51, 123, 126]
    let events = (0..<1000).map { i in
        InputEvent(t: 0.2 + Double(i) * 0.001, kind: .keyDown, keyCode: keys[i % keys.count])
    }
    let t = derive(events)
    let mic = [Float](repeating: 0, count: 6 * 48_000)
    let mixer = AudioMixer(mic: mic, micOffset: 0, system: nil, systemOffset: 0)
    let mixed = try #require(mixer.mix(t))
    #expect(mixed.lufs.isFinite)
    #expect(mixed.truePeakDb <= -1 + 0.01, "1000-key storm true peak \(mixed.truePeakDb) dBTP clips")
    #expect(mixed.l.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect(mixed.r.allSatisfy { $0.isFinite && abs($0) <= 1 })
}
