import Foundation
import Testing
import LumenCore
@testable import LumenCapture

@Test @MainActor func eventWriterTimerRunsOffMainActor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = InputRecorder(url: directory.appendingPathComponent("events.bin"),
                                 axURL: directory.appendingPathComponent("ax.json"),
                                 origin: .zero, scale: 1, clock: RecordingClock())
    recorder.startFlushTimer()
    try await Task.sleep(for: .milliseconds(800))
    await recorder.stop()
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ax.json").path))
}
