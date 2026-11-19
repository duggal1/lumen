import Foundation
import Testing

// T5 — design + test-integrity compliance for the video-editing / MCP surface.
//
// Headless by construction: these tests only read source text relative to
// #filePath. They never launch an app, a window, a browser or global input.
// Each guard first proves the surface exists, so a test cannot pass because the
// file it was meant to inspect is missing.

// MARK: - File helpers

private func t5RepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LumenTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
}

private func t5Read(_ relative: String) throws -> String {
    let url = t5RepoRoot().appendingPathComponent(relative)
    return try String(contentsOf: url, encoding: .utf8)
}

private func t5Lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func t5SwiftTests() throws -> [String] {
    let root = t5RepoRoot().appendingPathComponent("Tests/LumenTests").path
    let all = try FileManager.default.subpathsOfDirectory(atPath: root)
    return all.filter { $0.hasSuffix(".swift") }
        .map { "Tests/LumenTests/\($0)" }
        .sorted()
}

/// True only when `token` appears as code, not inside a string literal. The
/// guards below declare their own marker literals, so a naive `contains` would
/// count the scanner as a violation of the rule it enforces.
private func t5HasToken(_ token: String, in line: String) -> Bool {
    var inside = false
    var i = line.startIndex
    while i < line.endIndex {
        let ch = line[i]
        if ch == "\"" {
            inside.toggle()
            i = line.index(after: i)
            continue
        }
        if !inside, line[i...].hasPrefix(token) { return true }
        i = line.index(after: i)
    }
    return false
}

/// Lines inside the `registerAllTools` function body only.
private func t5FunctionBody(_ text: String, named name: String) -> [String] {
    let lines = t5Lines(text)
    guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return [] }
    var depth = 0
    var body: [String] = []
    for line in lines[start...] {
        body.append(line)
        depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        if depth <= 0, body.count > 1 { break }
    }
    return body
}

/// Tool names from the machine-readable contract table in Docs/VIDEO-EDIT-API.md.
private func t5DocumentedToolNames() throws -> Set<String> {
    let text = try t5Read("Docs/VIDEO-EDIT-API.md")
    let names = t5Lines(text)
        .filter { $0.contains(" | ") && !$0.hasPrefix("#") && !$0.hasPrefix("`") }
        .compactMap { line -> String? in
            let cell = line.split(separator: "|", omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) }
            guard let cell, cell.range(of: #"^[a-z][a-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
            return cell
        }
    return Set(names)
}

// MARK: - Design compliance

@Test func videoEditSurfaceHasNoPlaceholderStubs() throws {
    // Guard: the surface must exist. A missing file is a failure, not a pass.
    let files = ["Sources/LumenProject/VideoEdits.swift",
                 "Sources/LumenControl/Tools+VideoEdit.swift"]
    var scanned = 0
    let markers = ["RED PHASE STUB", "compile-only scaffold", "// STUB",
                   "replaced by the full implementation", "fatalError(\"TODO\""]
    for relative in files {
        let lines = t5Lines(try t5Read(relative))
        scanned += 1
        for (index, line) in lines.enumerated() where markers.contains(where: { line.contains($0) }) {
            #expect(false, "\(relative):\(index + 1) ships a placeholder/dead knob: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
    #expect(scanned == files.count, "did not scan the whole video-edit surface")
}

@Test func daemonExposesTheVideoEditToolFamily() throws {
    let daemon = try t5Read("Sources/LumenControl/Daemon.swift")
    let body = t5FunctionBody(daemon, named: "registerAllTools")
    #expect(!body.isEmpty, "registerAllTools() not found in Daemon.swift")
    let registersEditFamily = body.contains { line in
        line.localizedCaseInsensitiveContains("edittools") ||
        line.localizedCaseInsensitiveContains("registerVideoEdit")
    }
    #expect(registersEditFamily,
            "Sources/LumenControl/Daemon.swift: registerAllTools() never registers the video-edit tool family; MCP/CLI cannot reach it")
}

@Test func videoEditToolVocabularyIsSingleAndDocumented() throws {
    let documented = try t5DocumentedToolNames()
    #expect(documented.count >= 40, "VIDEO-EDIT-API.md contract table is missing; nothing to compare against")
    let testSource = try t5Read("Tests/LumenTests/MCPVideoEditToolsTests.swift")
    let testLines = t5Lines(testSource)
    let pattern = #"call\(\"([a-z][a-z0-9_]*)\""#
    var used: [String: Int] = [:]
    for (index, line) in testLines.enumerated() {
        guard let range = line.range(of: pattern, options: .regularExpression) else { continue }
        let raw = String(line[range])
        let name = raw.replacingOccurrences(of: "call(\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        if used[name] == nil { used[name] = index + 1 }
    }
    #expect(used.count >= 8, "MCPVideoEditToolsTests.swift exposes too few tools to be a meaningful contract")
    for (name, line) in used.sorted(by: { $0.key < $1.key }) where !documented.contains(name) {
        #expect(false, "Tests/LumenTests/MCPVideoEditToolsTests.swift:\(line) uses '\(name)', absent from Docs/VIDEO-EDIT-API.md — two competing tool vocabularies")
    }
}

@Test func videoEditSurfaceHasNoForbiddenChrome() throws {
    let files = ["Sources/LumenProject/VideoEdits.swift",
                 "Sources/LumenControl/Tools+VideoEdit.swift",
                 "Docs/VIDEO-EDIT-API.md",
                 "Docs/AGENT-MCP-EDITING.md"]
    var scanned = 0
    let forbidden = [".stroke(", "LinearGradient", "RadialGradient",
                     "NSVisualEffectView", ".glass", "Color.accentColor",
                     "Color.orange"]
    let allowed = ["ContrastStroke", "EdgeFade", "Wallpaper", "Compositor"]
    for relative in files {
        let lines = t5Lines(try t5Read(relative))
        scanned += 1
        for (index, line) in lines.enumerated() where !allowed.contains(where: { line.contains($0) }) {
            for token in forbidden where line.contains(token) {
                #expect(false, "\(relative):\(index + 1) introduces forbidden chrome '\(token)'")
            }
            let emoji = line.unicodeScalars.contains { $0.value >= 0x1F300 || ($0.value >= 0x2600 && $0.value <= 0x27BF) }
            #expect(!emoji, "\(relative):\(index + 1) contains an emoji/symbol glyph in chrome or docs")
        }
    }
    #expect(scanned == files.count, "did not scan the whole video-edit surface")
}

// MARK: - Test-suite integrity

@Test func testSuiteHasNoSilentCapabilityGuards() throws {
    let files = try t5SwiftTests()
    #expect(files.count > 50, "test inventory looks incomplete; refusing a vacuous pass")
    let silent = #"guard\s+.*(isAvailable|isInstalled\(|MTLCreateSystemDefaultDevice\(\)\s*!=\s*nil).*else\s*\{\s*return\s*\}"#
    var hits: [String] = []
    for relative in files {
        for (index, line) in t5Lines(try t5Read(relative)).enumerated()
            where line.range(of: silent, options: .regularExpression) != nil {
            hits.append("\(relative):\(index + 1)")
        }
    }
    #expect(hits.isEmpty, "silent capability guards pass without testing anything: \(hits.joined(separator: ", "))")
}

@Test func testSuiteHasNoAlwaysTrueExpectations() throws {
    let files = try t5SwiftTests()
    #expect(files.count > 50, "test inventory looks incomplete; refusing a vacuous pass")
    let vacuous = ["#expect(true)", "XCTAssertTrue(true)", "#expect(!false)"]
    var hits: [String] = []
    for relative in files {
        for (index, line) in t5Lines(try t5Read(relative)).enumerated()
            where vacuous.contains(where: { t5HasToken($0, in: line) }) {
            hits.append("\(relative):\(index + 1)")
        }
    }
    #expect(hits.isEmpty, "vacuous always-true assertions: \(hits.joined(separator: ", "))")
}

@Test func videoEditTestsDoNotSilentlySkipOnMissingFixtures() throws {
    let files = ["Tests/LumenTests/RealVideoEditE2ETests.swift",
                 "Tests/LumenTests/VideoFrameAccuracyTests.swift",
                 "Tests/LumenTests/VideoEditModelTests.swift",
                 "Tests/LumenTests/MCPVideoEditToolsTests.swift"]
    var scanned = 0
    let silent = #"guard\s+FileManager\.default\.fileExists\(atPath:.*\)\s+else\s*\{\s*return\s*\}"#
    var hits: [String] = []
    for relative in files {
        let lines = t5Lines(try t5Read(relative))
        scanned += 1
        for (index, line) in lines.enumerated()
            where line.range(of: silent, options: .regularExpression) != nil {
            hits.append("\(relative):\(index + 1)")
        }
    }
    #expect(scanned == files.count, "did not scan the whole video-edit fixture inventory")
    #expect(hits.isEmpty, "missing fixtures silently pass the test: \(hits.joined(separator: ", "))")
}

@Test func videoEditTestsAreNotSkipped() throws {
    let files = ["Tests/LumenTests/VideoEditModelTests.swift",
                 "Tests/LumenTests/MCPVideoEditToolsTests.swift",
                 "Tests/LumenTests/MCPContractTests.swift",
                 "Tests/LumenTests/VideoCaptionEditTests.swift",
                 "Tests/LumenTests/VideoExportPipelineTests.swift"]
    var scanned = 0
    let skipMarkers = ["XCTSkip", ".disabled(", "@Test(.disabled", "try #expect(true)"]
    for relative in files {
        let lines = t5Lines(try t5Read(relative))
        scanned += 1
        for (index, line) in lines.enumerated() where skipMarkers.contains(where: { line.contains($0) }) {
            #expect(false, "\(relative):\(index + 1) skips or weakens a video-edit test")
        }
    }
    #expect(scanned == files.count, "did not scan the whole video-edit test inventory")
}
