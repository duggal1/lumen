#!/usr/bin/env swift
// T1 driver — headless real-video editing E2E.
// One job: generate a seeded manifest, run the Swift Testing sweep headlessly,
// turn its JSON results into a report with defect file:line hints. JSON out,
// nonzero exit on any failing scenario. No GUI, no player, no git.

import Foundation

struct Options {
    var scenarios = 100
    var out = ".proof/T1"
    var source = ".proof/visual/sequence.mp4"
    var scratch = "/private/var/folders/ct/cwpf7vpn059fkp932tq9zm4m0000gn/T/opencode/t1-build"
    var filter: String?
    var only: Int?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("real-video-e2e: " + message + "\n").utf8))
    exit(2)
}

func parseArgs(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String {
            i += 1
            guard i < args.count else { fail("missing value for \(a)") }
            return args[i]
        }
        switch a {
        case "--scenarios": o.scenarios = Int(value()) ?? 100
        case "--out": o.out = value()
        case "--source": o.source = value()
        case "--scratch": o.scratch = value()
        case "--filter": o.filter = value()
        case "--only": o.only = Int(value())
        case "-h", "--help":
            print("usage: real-video-e2e [--scenarios N] [--out DIR] [--source PATH] [--scratch PATH] [--only i]")
            exit(0)
        default: fail("unknown argument \(a)")
        }
        i += 1
    }
    return o
}

// Mirrors the test's deterministic LCG exactly (so manifest and oracle agree).
struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

func makeManifest(_ o: Options) -> [String: Any] {
    let captions = ["EDIT PROOF", "CUT VERIFIED", "合成字幕", "REORDERED", "LUMEN T1", "SPLIT AND SWAP"]
    var items: [[String: Any]] = []
    for i in 0..<o.scenarios {
        var r = LCG(state: UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        let cutStart = 0.12 + r.unit() * 0.20
        let cutLength = 0.12 + r.unit() * 0.08
        let splitOffset = 0.42 + r.unit() * 0.16
        let swap = r.next() % 2 == 0
        let toneHz = 220.0 + Double(r.next() % 660)
        let caption = captions[Int(r.next() % UInt64(captions.count))]
        let fps = r.next() % 2 == 0 ? 30 : 60
        items.append(["id": i, "cutStart": cutStart, "cutLength": cutLength,
                      "splitOffset": splitOffset, "swap": swap, "toneHz": toneHz,
                      "caption": caption, "fps": fps])
    }
    return ["source": o.source, "scenarios": items]
}

func writeJSON(_ value: Any, to url: URL, pretty: Bool = true) throws {
    let data = try JSONSerialization.data(withJSONObject: value,
                                          options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    try data.write(to: url)
}

func run(_ o: Options, manifest: URL, results: URL, log: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "test", "--filter", o.filter ?? "RealVideoEditE2ETests",
                         "--scratch-path", o.scratch]
    var env = ProcessInfo.processInfo.environment
    env["T1_SCENARIOS_FILE"] = manifest.path
    env["T1_RESULTS_FILE"] = results.path
    env["T1_SOURCE"] = o.source
    env["T1_SCRATCH"] = o.scratch + "-sweep"
    if let only = o.only { env["T1_SCENARIO_FILTER"] = String(only) }
    env["LUMEN_BENCHMARK"] = "0"
    process.environment = env
    let handle = FileHandle(forWritingAtPath: log.path) ?? FileHandle.standardError
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    try? handle.synchronize()
    return process.terminationStatus
}

let options = parseArgs(Array(CommandLine.arguments.dropFirst()))
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = URL(fileURLWithPath: options.out, relativeTo: root)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let manifestURL = outDir.appendingPathComponent("scenarios.json")
let resultsURL = outDir.appendingPathComponent("results.json")
let logURL = outDir.appendingPathComponent("test.log")
let reportURL = outDir.appendingPathComponent("report.json")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
try? FileManager.default.removeItem(at: resultsURL)

let manifest = makeManifest(options)
try writeJSON(manifest, to: manifestURL)
let exitCode = try run(options, manifest: manifestURL, results: resultsURL, log: logURL)

var resultItems: [[String: Any]] = []
if let data = try? Data(contentsOf: resultsURL),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let list = json["results"] as? [[String: Any]] {
    resultItems = list
}

var defects: [[String: Any]] = []
var seen = Set<String>()
let passed = resultItems.filter { ($0["pass"] as? Bool) == true }.count
let failed = resultItems.count - passed
for item in resultItems where (item["pass"] as? Bool) == false {
    let id = item["id"] ?? -1
    let failures = item["failures"] as? [String] ?? []
    let hints = item["hints"] as? [String] ?? []
    let location = hints.first ?? "unclassified (test harness)"
    let key = location + "|" + (failures.first ?? "")
    if seen.contains(key) { continue }
    seen.insert(key)
    defects.append(["scenario": id, "location": location,
                    "symptom": failures.joined(separator: " | ")])
}

let report: [String: Any] = [
    "tool": "real-video-e2e",
    "source": options.source,
    "scenarios_requested": options.scenarios,
    "scenarios_executed": resultItems.count,
    "passed": passed,
    "failed": failed,
    "test_exit_code": exitCode,
    "log": logURL.path,
    "defects": defects,
    "verdict": (failed == 0 && exitCode == 0 && resultItems.count > 0) ? "PASS" : "FAIL"
]
try writeJSON(report, to: reportURL)
print(String(decoding: try JSONSerialization.data(withJSONObject: [
    "verdict": report["verdict"]!, "executed": resultItems.count,
    "passed": passed, "failed": failed, "report": reportURL.path
] as [String: Any], options: [.sortedKeys]), as: UTF8.self))
if report["verdict"] as? String != "PASS" { exit(1) }
