import Foundation
import Testing
@testable import LumenCore
@testable import LumenProject
@testable import LumenDirector

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
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10, backingScale: 1, originX: 0, originY: 0)
    var plan = PrivacyPlan()
    plan.enabled = true
    plan.autoDetect = true
    plan.autoApply = ["email"]
    let hash = fnv1a64("user@example.com", salt: 7)
    let det = [OCRDetection(t: 5.0, x: 0.2, y: 0.3, w: 0.2, h: 0.05, category: .email, hash: hash, confidence: 0.9)]
    let masks = MaskTracks.build(det, plan: plan, src: src)
    #expect(masks.count == 1)
    #expect(masks.first!.start <= 5.0 - 0.59, "extends backward past first detection \(masks.first?.start ?? -1)")
    #expect(masks.first!.end >= 5.6, "extends forward")
    let enc = try? JSONEncoder().encode(masks)
    let json = String(data: enc ?? Data(), encoding: .utf8) ?? ""
    #expect(!json.contains("user@example.com"), "raw OCR text must never persist")
}
