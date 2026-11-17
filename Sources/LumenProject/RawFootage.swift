import Foundation

/// How long the original capture tracks stay on disk after the last export.
/// A user can pick 1, 7 or 30 days; 7 is the privacy default.
public enum RawRetention: Int, Codable, CaseIterable, Sendable {
    case oneDay = 1, sevenDays = 7, thirtyDays = 30
    public var title: String {
        switch self {
        case .oneDay: "1 day"; case .sevenDays: "7 days"; case .thirtyDays: "30 days"
        }
    }
    public var days: Int { rawValue }
    public static func normalize(_ days: Int) -> Int {
        RawRetention(rawValue: days)?.rawValue ?? RawRetention.sevenDays.rawValue
    }
}

/// The storage sweep for raw footage. It only removes the original capture
/// tracks — the project JSON, captions, cuts, events and exported files are
/// never touched. Completed projects age out from their last export; a failed
/// or interrupted recording gets a 30-day grace period so nobody loses
/// recoverable footage while they are still dealing with the failure.
public enum RawFootageSweep {
    public struct Report: Sendable, Equatable {
        public var deleted: [String] = []
        public var retained: [String] = []
        public var markedFailed: [String] = []
        public init() {}
    }

    /// Original capture tracks. Deliverables live in the export folder and are
    /// deliberately not listed here.
    public static let rawFileNames = ["screen.mov", "mic.caf", "system.caf", "webcam.mov"]
    public static let failedGraceDays = 30

    /// Removes the raw tracks from one bundle. Returns the file names actually
    /// removed so a caller can report what happened.
    @discardableResult
    public static func deleteRaw(in bundle: ProjectBundle) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in rawFileNames {
            let url = bundle.url.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(name)
            } catch {
                // A locked or missing file is not a reason to abort the sweep:
                // the next launch tries again.
            }
        }
        // Extra microphones are written as mic-extra-N.caf by the recorder and
        // are raw voice tracks too. Enumerate them: a fixed list would leave
        // exactly the data the "delete raw" setting promises to remove.
        let extras = (try? fm.contentsOfDirectory(atPath: bundle.url.path)) ?? []
        for name in extras where name.hasPrefix("mic-extra-") && name.hasSuffix(".caf") {
            let url = bundle.url.appendingPathComponent(name)
            do {
                try fm.removeItem(at: url)
                removed.append(name)
            } catch { /* next sweep tries again */ }
        }
        return removed
    }

    /// Sweep every `.lumen` bundle in `library`. Pure file-system work, safe
    /// to run on a background queue at launch. `now` is injectable for tests.
    @discardableResult
    public static func sweep(library: URL, now: Date = Date()) -> Report {
        var report = Report()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "lumen" {
            let bundle = ProjectBundle(url: url)
            let name = url.lastPathComponent
            let privacy = (try? bundle.load())?.timeline.overlays.privacy
            let interrupted = bundle.isUnfinished || !fm.fileExists(atPath: bundle.projectURL.path)
                || fm.fileExists(atPath: bundle.failedMarkerURL.path)

            if interrupted {
                // Failed / interrupted footage is exempt for 30 days from the
                // moment it was last touched, regardless of export settings.
                let anchor = bundle.lastTouched(at: now)
                if now.timeIntervalSince(anchor) >= Double(failedGraceDays) * 86_400 {
                    if !deleteRaw(in: bundle).isEmpty { report.deleted.append(name) }
                    try? fm.removeItem(at: bundle.failedMarkerURL)
                } else {
                    report.retained.append(name)
                }
                continue
            }

            let policy = privacy ?? PrivacyPlan()
            let hasRaw = rawFileNames.contains { fm.fileExists(atPath: bundle.url.appendingPathComponent($0).path) }
            guard hasRaw else { continue }

            if policy.deleteRawAfterExport, policy.lastExportAt != nil {
                if !deleteRaw(in: bundle).isEmpty { report.deleted.append(name) }
                continue
            }

            // With no export there is no finished deliverable and raw footage
            // is the only master. The 7/30-day clock starts at the last export,
            // never at the recording date.
            guard let anchor = policy.lastExportAt else {
                report.retained.append(name)
                continue
            }
            let keep = Double(RawRetention.normalize(policy.rawRetentionDays)) * 86_400
            if now.timeIntervalSince(anchor) >= keep {
                if !deleteRaw(in: bundle).isEmpty { report.deleted.append(name) }
            } else {
                report.retained.append(name)
            }
        }
        return report
    }
}

public extension ProjectBundle {
    /// Written by the recorder when a capture fails. Its presence extends the
    /// retention grace period even after a partial project file was saved.
    var failedMarkerURL: URL { url.appendingPathComponent("recording.failed") }

    func markFailed(at date: Date = Date()) {
        try? String(date.timeIntervalSince1970).write(to: failedMarkerURL, atomically: true, encoding: .utf8)
    }

    /// Best available timestamp for a bundle with no usable project file.
    func lastTouched(at fallback: Date = Date()) -> Date {
        if let journal = try? readJournal() { return journal.updated }
        if let marker = try? String(contentsOf: failedMarkerURL, encoding: .utf8),
           let t = Double(marker), t.isFinite { return Date(timeIntervalSince1970: t) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: projectURL.path)
        return (attrs?[.modificationDate] as? Date) ?? fallback
    }
}
