import Foundation
import CoreGraphics
import Testing
import LumenCore
import LumenProject
import LumenRender
@testable import LumenExport

@Test func exportReaderIsIndependentAndHonorsFrameCacheBudget() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("source.mov")
    try await ExportBenchmark.makeLadderMovie(at: movie, count: 12, fps: 60, size: CGSize(width: 320, height: 180))
    let (session, timeline) = try await ExportBenchmark.makeSession(directory: dir, movie: movie,
        source: SourceInfo(width: 320, height: 180, fps: 60, duration: 0.2,
                           backingScale: 1, originX: 0, originY: 0),
        timeline: Timeline(duration: 0.2))
    let reader = try await session.makeExportFrameReader()
    #expect(reader.screen !== session.screen)
    for i in 0..<10 {
        let t = Double(i) / 60
        let frame = try await reader.frames(atOutput: t, timeline: timeline).screen
        let preview = try await session.frames(atOutput: Double(11 - i) / 60, timeline: timeline).screen
        #expect(abs(frame.pts - t) <= 1.0 / 60)
        #expect(frame.id != preview.id)
    }
    let usage = await reader.screen.cacheUsage()
    #expect(usage.entries <= 2)
    #expect(usage.retainedBytes <= usage.budgetBytes)
}
