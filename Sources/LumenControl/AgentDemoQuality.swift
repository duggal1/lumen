import Foundation
import LumenProject

/// Bounded, observable correction of measurable defects. Never repairs
/// missing privacy evidence, capture loss, or creative intent by hiding it.
enum AgentDemoQuality {
    struct Result: Sendable {
        let report: JSONValue
        let corrections: [JSONValue]
    }

    static func failedChecks(_ report: JSONValue) throws -> Set<String> {
        guard let rows = report["checks"]?.arrayValue, !rows.isEmpty,
              rows.allSatisfy({ $0["name"]?.stringValue != nil && $0["ok"]?.boolValue != nil }) else {
            throw ToolError(code: "QA_EVIDENCE_MISSING", hint: "Quality report has no valid checks.")
        }
        return Set(rows.compactMap { $0["ok"]?.boolValue == true ? nil : $0["name"]?.stringValue })
    }

    static func adjustment(_ report: JSONValue) -> Double? {
        guard let audio = report["audio_measurement"], audio["expected"]?.boolValue == true,
              audio["measured"]?.boolValue == true,
              let lufs = audio["lufs"]?.doubleValue, lufs.isFinite, lufs > -70,
              let peak = audio["true_peak_db"]?.doubleValue, peak.isFinite else { return nil }
        let desired = min(-16 - lufs, -1.2 - peak)
        let delta = min(max(desired, -6), 6)
        return abs(delta) >= 0.1 ? delta : nil
    }

    static func run(assess: () async throws -> JSONValue,
                    repair: (Double, Int) async throws -> Bool) async throws -> Result {
        var report = try await assess()
        var corrections: [JSONValue] = []
        // One measured adjustment per demo. No recursive retries, no recapture,
        // no changing manual cuts/zoom, no disabling privacy or audio.
        let failed = try failedChecks(report)
        if failed == ["loudness"], let delta = adjustment(report), let revision = report["revision"]?.intValue {
            try Task.checkCancellation()
            if try await repair(delta, revision) {
                corrections.append(.object(["kind": .string("master_gain"), "delta_db": .number(delta), "base_revision": .int(revision)]))
                report = try await assess()
            }
        }
        let unresolved = try failedChecks(report)
        guard unresolved.isEmpty else {
            throw ToolError(code: "QA_FAILED", hint: "Unresolved checks: " + unresolved.sorted().joined(separator: ", ") + ". Inspect the retained project; no output was approved.")
        }
        return Result(report: report, corrections: corrections)
    }
}

extension Engine {
    func adjustDemoMaster(projectID: String, revision: Int, adjustment: Double) async throws -> Bool {
        let result = try await edit(projectID: projectID, expectRevision: revision, describe: "bounded demo master correction") { timeline in
            var audio = timeline.audio
            audio.outputGainDb = min(max(audio.outputGainDb + adjustment, -12), 12)
            try applyCommand(.setAudio(audio), to: &timeline)
        }
        return result["changed"]?.boolValue == true
    }
}
