import AppKit
import Foundation

struct RecordedAppUsage: Codable, Sendable, Equatable {
    let id: String
    let name: String
    var seconds: Double
}

enum AppUsageSummary {
    static func aggregate(_ recordings: [(date: Date, apps: [RecordedAppUsage])], since: Date?) -> [RecordedAppUsage] {
        var totals: [String: RecordedAppUsage] = [:]
        for recording in recordings where since.map({ recording.date >= $0 }) ?? true {
            for item in recording.apps where !item.id.isEmpty && item.seconds.isFinite && item.seconds > 0 {
                var total = totals[item.id] ?? RecordedAppUsage(id: item.id, name: item.name, seconds: 0)
                total.seconds += item.seconds
                totals[item.id] = total
            }
        }
        return totals.values.sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
    }
}

struct AppUsageAccumulator {
    private(set) var totals: [String: RecordedAppUsage] = [:]
    private var current: (id: String, name: String, start: TimeInterval)?

    mutating func activate(id: String, name: String, at time: TimeInterval) {
        finish(at: time)
        guard !id.isEmpty, time.isFinite else { return }
        current = (id, name.isEmpty ? id : name, time)
    }

    mutating func pause(at time: TimeInterval) { finish(at: time) }

    mutating func finish(at time: TimeInterval) {
        guard let active = current else { return }
        current = nil
        let duration = time - active.start
        guard duration.isFinite, duration > 0 else { return }
        var item = totals[active.id] ?? RecordedAppUsage(id: active.id, name: active.name, seconds: 0)
        item.seconds += duration
        totals[active.id] = item
    }
}

@MainActor final class RecordingAppUsage {
    private var accumulator = AppUsageAccumulator()
    private var observer: NSObjectProtocol?
    private var fixedApp: (id: String, name: String)?
    private var paused = false

    func start(fixedApp: (id: String, name: String)?) {
        self.fixedApp = fixedApp
        if let fixedApp {
            activate(id: fixedApp.id, name: fixedApp.name)
        } else {
            activateCurrent()
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier ?? ""
                let name = app?.localizedName ?? id
                Task { @MainActor [weak self] in self?.activate(id: id, name: name) }
            }
        }
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if value { accumulator.pause(at: ProcessInfo.processInfo.systemUptime) }
        else if let fixedApp { activate(id: fixedApp.id, name: fixedApp.name) }
        else { activateCurrent() }
    }

    func finish() -> [RecordedAppUsage] {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        accumulator.finish(at: ProcessInfo.processInfo.systemUptime)
        return accumulator.totals.values.sorted { $0.id < $1.id }
    }

    private func activateCurrent() {
        let app = NSWorkspace.shared.frontmostApplication
        activate(id: app?.bundleIdentifier ?? "", name: app?.localizedName ?? "")
    }

    private func activate(id: String, name: String) {
        guard !paused else { return }
        let ownID = Bundle.main.bundleIdentifier ?? ""
        let allowed = id != ownID && id != "com.apple.dock"
        accumulator.activate(id: allowed ? id : "", name: name, at: ProcessInfo.processInfo.systemUptime)
    }
}
