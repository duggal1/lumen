import Foundation
import LumenRender

/// Explicit local acceptance probe; disabled by default. File IO occurs once
/// outside the render callback. No UI or user data leaves the Mac.
final class PreviewCadenceProbe: Sendable {
    private let output: URL
    private let commit: String
    private let cadence = PlaybackCadence()
    private struct Evidence: Codable, Sendable {
        let commit: String
        let operatingSystem: String
        let physicalMemoryBytes: UInt64
        let cadence: PlaybackCadence.Report
    }

    private init(output: URL, commit: String) {
        self.output = output
        self.commit = commit
    }

    static func configured() -> PreviewCadenceProbe? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LUMEN_CADENCE_REPORT"], path.hasPrefix("/"),
              let commit = env["LUMEN_CADENCE_COMMIT"],
              commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              !FileManager.default.fileExists(atPath: path) else { return nil }
        return PreviewCadenceProbe(output: URL(fileURLWithPath: path), commit: commit)
    }

    func observer(playing: Bool, generation: UInt64, sourceTime: Double,
                  expected: Double) -> (@Sendable (Double) -> Void)? {
        guard playing else { return nil }
        return { [self] actual in
            guard let report = cadence.record(generation: generation, sourceTime: sourceTime,
                                               actual: actual, expected: expected) else { return }
            let evidence = Evidence(commit: commit, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, cadence: report)
            Task.detached(priority: .utility) {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(evidence)
                    // No overwrite: one deliberate playback session per report.
                    try data.write(to: self.output, options: .withoutOverwriting)
                } catch {
                    NSLog("Lumen cadence report failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
