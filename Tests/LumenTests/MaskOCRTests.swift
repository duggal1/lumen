import Foundation
import Testing
@testable import LumenCore
@testable import LumenProject
@testable import LumenDirector
@testable import LumenAnalysis

// MARK: - Synthetic OCR corpus
//
// Every line is what Vision would have returned for one rendered line of text:
// the string, its normalized source box, and a per-range box. Nothing here
// touches pixels, so the rules are asserted exactly instead of "by eye".

private let salt: UInt64 = 7

private func proportionalBox(_ text: String, _ box: CGRect, _ range: Range<String.Index>) -> CGRect {
    let n = max(text.count, 1)
    let a = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / CGFloat(n)
    let b = CGFloat(text.distance(from: text.startIndex, to: range.upperBound)) / CGFloat(n)
    return CGRect(x: box.minX + box.width * a, y: box.minY, width: max(box.width * (b - a), 0.001), height: box.height)
}

private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.3, h: CGFloat = 0.03,
                  confidence: Float = 0.9) -> OCRTextLine {
    let box = CGRect(x: x, y: y, width: w, height: h)
    return OCRTextLine(text: text, box: box, confidence: confidence,
                       rangeBox: { proportionalBox(text, box, $0) })
}

private func scan(_ lines: [OCRTextLine], at t: Double = 1.0) -> [OCRDetection] {
    OCRClassify.detections(lines: lines, time: t, salt: salt, custom: [], entropyThreshold: 3.5)
}

private func context(host: String?, epoch: UInt32 = 1, at t: Double = 0) -> PrivacyContextTrack {
    PrivacyContextTrack(samples: [PrivacyContextSample(t: t, context: PrivacyContext(
        host: host, appName: host == nil ? nil : "Safari", windowID: host == nil ? nil : 1,
        epoch: epoch, resolved: host != nil))])
}

private func plan(autoApply: [String] = PrivacyPlan().autoApply) -> PrivacyPlan {
    var p = PrivacyPlan()
    p.enabled = true
    p.autoDetect = true
    p.autoApply = autoApply
    return p
}

private let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10, backingScale: 1, originX: 0, originY: 0)

/// An applied mask covers this detection: the mask owns a key at the detection's
/// source position. Masks carry geometry, never text, so geometry is the identity.
private func covers(_ mask: Mask, _ d: OCRDetection) -> Bool {
    mask.keys.contains { key in
        abs(key.x - d.x * Double(source.width)) < 1.5 && abs(key.y - d.y * Double(source.height)) < 1.5
    }
}

// MARK: - Host policy

@Test func onlyTheExactApprovedHostCountsAsPrivate() {
    #expect(PrivacyContext.hostIsApproved("mail.google.com"))
    #expect(PrivacyContext.hostIsApproved("accounts.google.com"))
    #expect(PrivacyContext.hostIsApproved("MAIL.GOOGLE.COM"))
    #expect(PrivacyContext.hostIsApproved("mail.google.com."))
    #expect(PrivacyContext.hostIsApproved("https://mail.google.com/mail/u/0/#inbox"))
    #expect(!PrivacyContext.hostIsApproved("mail.google.com.example.test"))
    #expect(!PrivacyContext.hostIsApproved("notmail.google.com"))
    #expect(!PrivacyContext.hostIsApproved("google.com"))
    #expect(!PrivacyContext.hostIsApproved("www.google.com"))
    #expect(!PrivacyContext.hostIsApproved("lumen.example"))
    #expect(!PrivacyContext.hostIsApproved(nil))
    #expect(!PrivacyContext.hostIsApproved(""))
    // A title, an app name or a logo is not evidence: only the host is.
    #expect(!PrivacyContext(host: nil, appName: "Google Chrome", resolved: true).isApprovedPrivateHost)
}

@Test func privacyContextComesFromTheFocusAnchor() {
    let anchor = FocusAnchor(epoch: 4, sampledAt: 12.5, host: "mail.google.com", windowID: 9,
                             appName: "Safari", resolved: true)
    let ctx = PrivacyContext(anchor: anchor)
    #expect(ctx.host == "mail.google.com")
    #expect(ctx.windowID == 9)
    #expect(ctx.epoch == 4)
    #expect(ctx.resolved)
    #expect(ctx.isApprovedPrivateHost)
    #expect(PrivacyContext(anchor: nil).isUnknown)
}

@Test func contextTrackIsRunLengthEncodedAndAnswersBySourceTime() {
    let a = AXFrame(x: 0, y: 0, w: 10, h: 10, secure: false, label: nil,
                    anchor: FocusAnchor(epoch: 1, sampledAt: 0, host: "lumen.example", windowID: 1, appName: "Safari", resolved: true))
    let b = AXFrame(x: 0, y: 0, w: 10, h: 10, secure: false, label: nil,
                    anchor: FocusAnchor(epoch: 2, sampledAt: 0, host: "mail.google.com", windowID: 2, appName: "Safari", resolved: true))
    var first = a, second = b
    first.sampledAt = 1
    second.sampledAt = 5
    let track = PrivacyContextTrack.from(ax: [first, first, second])
    #expect(track.samples.count == 2, "identical neighbouring contexts collapse")
    #expect(track.context(at: 0.5)?.host == "lumen.example")
    #expect(track.context(at: 4.9)?.host == "lumen.example")
    #expect(track.context(at: 5)?.host == "mail.google.com")
    #expect(track.context(at: 0.5)?.isApprovedPrivateHost == false)
    #expect(track.context(at: 9)?.isApprovedPrivateHost == true)
}

// MARK: - Corpus

private struct CorpusCase {
    var name: String
    var host: String?
    var lines: [OCRTextLine]
    var expected: [UInt64]          // hashes that must be masked automatically
    var visible: [UInt64] = []      // hashes that must never be masked automatically
    var t: Double = 1.0
}

private func corpus() -> [CorpusCase] {
    let landing = "hello@lumen.example"
    let gmail = "sam.okafor@gmail.com"
    let key = "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    var cases: [CorpusCase] = []
    cases.append(CorpusCase(name: "public landing page footer",
                            host: "lumen.example",
                            lines: [line("Lumen records your screen", x: 0.1, y: 0.1, w: 0.5),
                                    line("Contact", x: 0.1, y: 0.6, w: 0.1),
                                    line(landing, x: 0.1, y: 0.65, w: 0.3)],
                            expected: [], visible: [fnv1a64(landing, salt: salt)]))
    cases.append(CorpusCase(name: "public landing page with a date and ordinary copy",
                            host: "lumen.example",
                            lines: [line("© 2026 Lumen Labs", x: 0.1, y: 0.9, w: 0.25),
                                    line("Terms and privacy", x: 0.4, y: 0.9, w: 0.25)],
                            expected: []))
    cases.append(CorpusCase(name: "private mail surface with a visible address",
                            host: "mail.google.com",
                            lines: [line("To", x: 0.1, y: 0.2, w: 0.05),
                                    line(gmail, x: 0.16, y: 0.2, w: 0.3)],
                            expected: [fnv1a64(gmail, salt: salt)]))
    cases.append(CorpusCase(name: "private account surface with a visible address",
                            host: "accounts.google.com",
                            lines: [line(gmail, x: 0.3, y: 0.4, w: 0.3)],
                            expected: [fnv1a64(gmail, salt: salt)]))
    cases.append(CorpusCase(name: "unknown host (legacy import, no AX)",
                            host: nil,
                            lines: [line(gmail, x: 0.3, y: 0.4, w: 0.3)],
                            expected: [], visible: [fnv1a64(gmail, salt: salt)]))
    cases.append(CorpusCase(name: "spoofed host mail.google.com.example.test",
                            host: "mail.google.com.example.test",
                            lines: [line(gmail, x: 0.3, y: 0.4, w: 0.3)],
                            expected: [], visible: [fnv1a64(gmail, salt: salt)]))
    cases.append(CorpusCase(name: "the same address twice on one private page",
                            host: "mail.google.com",
                            lines: [line(gmail, x: 0.1, y: 0.2, w: 0.3),
                                    line(gmail, x: 0.1, y: 0.7, w: 0.3)],
                            expected: [fnv1a64(gmail, salt: salt)]))
    cases.append(CorpusCase(name: "api key on a public page",
                            host: "lumen.example",
                            lines: [line("token " + key, x: 0.1, y: 0.3, w: 0.6)],
                            expected: [fnv1a64(key.lowercased(), salt: salt)]))
    cases.append(CorpusCase(name: "password field showing only concealment glyphs",
                            host: "accounts.google.com",
                            lines: [line("••••••••", x: 0.3, y: 0.5, w: 0.2)],
                            expected: []))
    return cases
}

@Test func privacyCorpusHasNoFalseMasksAndCoversEveryTrueSecret() {
    var maskTrue = 0, maskFalse = 0, secretCovered = 0, secretTotal = 0
    var notes: [String] = []
    for c in corpus() {
        let detections = scan(c.lines, at: c.t)
        let masks = MaskTracks.build(detections, plan: plan(), src: source, contexts: context(host: c.host, at: 0))
        let approved = masks.filter(\.approved)
        for mask in approved {
            if detections.contains(where: { c.expected.contains($0.hash) && covers(mask, $0) }) { maskTrue += 1 }
            else { maskFalse += 1; notes.append("FALSE MASK \(c.name)") }
        }
        for hash in c.expected {
            secretTotal += 1
            let hit = detections.contains { d in d.hash == hash && approved.contains { covers($0, d) } }
            if hit { secretCovered += 1 } else { notes.append("MISS \(c.name)") }
        }
        for hash in c.visible {
            secretTotal += 1
            let leaked = detections.contains { d in d.hash == hash && approved.contains { covers($0, d) } }
            if leaked { maskFalse += 1; notes.append("FALSE MASK \(c.name)") } else { secretCovered += 1 }
        }
        notes.append("  \(c.name): \(detections.count) det, \(approved.count) applied")
    }
    let precision = (maskTrue + maskFalse) == 0 ? 1.0 : Double(maskTrue) / Double(maskTrue + maskFalse)
    let recall = secretTotal == 0 ? 1.0 : Double(secretCovered) / Double(secretTotal)
    print(notes.joined(separator: "\n"))
    print(String(format: "privacy corpus: precision %.2f (%d/%d), recall %.2f (%d/%d)",
                 precision, maskTrue, maskTrue + maskFalse, recall, secretCovered, secretTotal))
    #expect(maskFalse == 0, "automatic masks on public/dot-only negatives")
    #expect(secretCovered == secretTotal, "in-policy secrets left unmasked")
    #expect(precision == 1.0, "precision \(precision)")
    #expect(recall == 1.0, "recall \(recall)")
}

// MARK: - Navigation

@Test func navigationResetsTheContextAndNeverBridgesAcrossPages() {
    let address = "hello@lumen.example"
    // public page, then a mail surface, then back to the public page; the same
    // address is on screen in all three.
    let cases: [(String?, Double)] = [("lumen.example", 1.0), ("mail.google.com", 3.0), ("lumen.example", 5.0)]
    var detections: [OCRDetection] = []
    var samples: [PrivacyContextSample] = []
    for (host, t) in cases {
        detections += scan([line(address, x: 0.1, y: 0.2, w: 0.3)], at: t)
        samples.append(PrivacyContextSample(t: t, context: PrivacyContext(
            host: host, appName: host == nil ? nil : "Safari", windowID: 1, epoch: 1, resolved: host != nil)))
    }
    let masks = MaskTracks.build(detections, plan: plan(), src: source,
                                 contexts: PrivacyContextTrack(samples: samples))
    let approved = masks.filter(\.approved)
    // Only the mail-surface instance may be applied.
    #expect(approved.count == 1, "expected exactly one auto mask, got \(approved.count)")
    #expect(approved.first?.category == SensitiveCategory.email.rawValue)
    #expect((approved.first?.start ?? 0) >= 2.9, "the applied mask belongs to the mail surface")
    #expect((approved.first?.end ?? 0) <= 3.4, "the mask does not bridge past the surface change")
    // The public instances survive as proposals, never as applied masks.
    #expect(masks.count == 3, "each surface keeps its own proposal: \(masks.count)")
    #expect(masks.contains { !$0.approved && $0.start < 2 })
    #expect(masks.contains { !$0.approved && $0.start > 4 })
}

@Test func scrollingDoesNotSlideAMaskAcrossUnrelatedContent() {
    let address = "sam.okafor@gmail.com"
    // One address, then the same address after a scroll that moves it far up the
    // page: the track must not bridge the gap.
    let near = scan([line(address, x: 0.1, y: 0.2, w: 0.3)], at: 2.0)
    let far = scan([line(address, x: 0.1, y: 0.8, w: 0.3)], at: 2.9)
    let masks = MaskTracks.build(near + far, plan: plan(), src: source, contexts: context(host: "mail.google.com"))
    #expect(masks.count == 2, "a scroll jump is a new mask, not a bridging one")
    #expect(masks.allSatisfy { $0.end - $0.start <= 0.5 }, "a mask stays local")
}

@Test func anIncompatibleFieldGeometryStartsANewMask() {
    let address = "sam.okafor@gmail.com"
    let small = scan([line(address, x: 0.1, y: 0.2, w: 0.2, h: 0.02)], at: 2.0)
    let large = scan([line(address, x: 0.1, y: 0.24, w: 0.2, h: 0.09)], at: 2.2)
    let masks = MaskTracks.build(small + large, plan: plan(), src: source, contexts: context(host: "mail.google.com"))
    #expect(masks.count == 2, "a 4x taller box is a different field")
}

// MARK: - Password fields

private func secureField(host: String?, t: Double, x: Double, y: Double, w: Double, h: Double) -> AXFrame {
    var f = AXFrame(x: x, y: y, w: w, h: h, secure: true, label: "Password",
                    anchor: FocusAnchor(epoch: 1, sampledAt: 0, host: host, windowID: host == nil ? nil : 1,
                                        appName: host == nil ? nil : "Safari", resolved: host != nil))
    f.sampledAt = t
    return f
}

@Test func aDotOnlyPasswordFieldGetsNoAutomaticMask() {
    // Dots are never a detection, and with no readable pixels inside the field
    // the evidence path adds nothing.
    let detections = scan([line("••••••••", x: 0.16, y: 0.3, w: 0.1)], at: 2.0)
    #expect(detections.isEmpty, "concealment glyphs are not a secret")
    let field = secureField(host: "accounts.google.com", t: 2.0, x: 160, y: 300, w: 600, h: 44)
    let events = [InputEvent(t: 2.0, kind: .down, x: 200, y: 320, axFrameIndex: 1)]
    let masks = MaskTracks.secureFields(events: events, ax: [field], plan: plan(), src: source, ocr: detections)
    #expect(masks.isEmpty, "a field showing only dots gets no mask")
}

@Test func aRevealedPasswordIsMaskedOnlyWhereItIsReadable() {
    let value = "hunter2hunter2"
    let det = scan([line("Password: " + value, x: 0.09, y: 0.3, w: 0.3)], at: 2.0)
    #expect(det.count == 1, "the revealed value is detected: \(det.count)")
    let field = secureField(host: "accounts.google.com", t: 2.0, x: 160, y: 300, w: 600, h: 44)
    let events = [InputEvent(t: 2.0, kind: .down, x: 200, y: 320, axFrameIndex: 1)]
    let masks = MaskTracks.secureFields(events: events, ax: [field], plan: plan(), src: source, ocr: det)
    #expect(masks.count == 1, "the exposed value is masked")
    guard let mask = masks.first else { return }
    #expect(mask.approved)
    #expect(mask.category == SensitiveCategory.envSecret.rawValue)
    // The mask is clipped to the field, not the whole frame, and never bigger
    // than the field itself.
    guard let key = mask.keys.first else { return }
    #expect(key.w <= 600 && key.h <= 44, "mask stays inside the field: \(key.w)x\(key.h)")
    #expect(key.w > 0 && key.h > 0)
}

@Test func withoutEvidenceTheWholeSecureFieldStaysMasked() {
    let field = secureField(host: "accounts.google.com", t: 2.0, x: 160, y: 300, w: 600, h: 44)
    let events = [InputEvent(t: 2.0, kind: .down, x: 200, y: 320, axFrameIndex: 1)]
    let masks = MaskTracks.secureFields(events: events, ax: [field], plan: plan(), src: source, ocr: nil)
    #expect(masks.count == 1)
    #expect(masks.first?.approved == true, "no scan must not remove existing protection")
    guard let key = masks.first?.keys.first else { return }
    #expect(abs(key.w - 600) < 1 && abs(key.h - 44) < 1, "the whole field, so size leaks nothing")
}

// MARK: - Existing behaviour that must not regress

@Test func maskRecallOnKnownSecrets() {
    let secrets = [
        "user@example.com",
        "sk-ant-123456789012345678901234567890",
        "4111111111111111",
        "visa 4111 1111 1111 1111",
        "ghp_123456789012345678901234567890123456",
        "SECRET=abc123def456",
        "password=hunter2",
    ]
    var hits = 0
    for s in secrets where !SensitivePatterns.scan(s, custom: []).isEmpty { hits += 1 }
    #expect(hits == secrets.count, "recall \(hits)/\(secrets.count)")
    #expect(SensitivePatterns.scan("hello world nice day", custom: []).isEmpty)
}

@Test func maskBackExtendsAndStoresNoRawText() {
    var p = plan(autoApply: ["email"])
    p.mode = .pixelate
    let address = "user@example.com"
    let det = [OCRDetection(t: 5.0, x: 0.2, y: 0.3, w: 0.2, h: 0.05, category: .email,
                            hash: fnv1a64(address, salt: salt), confidence: 0.9)]
    let masks = MaskTracks.build(det, plan: p, src: source, contexts: context(host: "mail.google.com"))
    #expect(masks.count == 1)
    #expect(masks.first!.approved, "a verified private host applies the address mask")
    #expect(masks.first!.start <= 5.0 - 0.11, "extends backward past first detection \(masks.first?.start ?? -1)")
    #expect(masks.first!.start < 5.0)
    #expect(masks.first!.end >= 5.25, "extends forward")
    // Without a context the same detection is a proposal, not an applied mask.
    let unknown = MaskTracks.build(det, plan: p, src: source)
    #expect(unknown.count == 1)
    #expect(unknown.first?.approved == false, "unknown context must not auto-mask")
    let enc = try? JSONEncoder().encode(masks)
    let json = String(data: enc ?? Data(), encoding: .utf8) ?? ""
    #expect(!json.contains(address), "raw OCR text must never persist")
}

@Test func userDecisionsStillWinOverPolicy() {
    let address = "hello@lumen.example"
    let det = [OCRDetection(t: 2.0, x: 0.1, y: 0.2, w: 0.2, h: 0.03, category: .email,
                            hash: fnv1a64(address, salt: salt), confidence: 0.9)]
    let base = MaskTracks.build(det, plan: plan(), src: source, contexts: context(host: "lumen.example"))
    guard let id = base.first?.id.uuidString else { return }
    var p = plan()
    p.decisions[id] = true
    let approved = MaskTracks.build(det, plan: p, src: source, contexts: context(host: "lumen.example"))
    #expect(approved.first?.approved == true, "an explicit manual accept still applies")
    p.decisions[id] = false
    let rejected = MaskTracks.build(det, plan: p, src: source, contexts: context(host: "mail.google.com"))
    #expect(rejected.isEmpty, "an explicit reject still removes the mask")
}