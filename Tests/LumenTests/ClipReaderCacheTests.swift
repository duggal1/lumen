import Foundation
import Testing
@testable import LumenExport

private actor ReaderFactoryProbe {
    var starts = 0
    var active = 0
    var peak = 0
    func create(_ value: Int) async throws -> Int {
        starts += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return value
    }
}

@Test func clipReaderCacheDeduplicatesConcurrentInitialization() async throws {
    let cache = ClipReaderCache<Int>(capacity: 2)
    let probe = ReaderFactoryProbe()
    let values = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<16 {
            group.addTask { try await cache.value(for: "source") { try await probe.create(7) } }
        }
        var result: [Int] = []
        for try await value in group { result.append(value) }
        return result
    }
    #expect(values == Array(repeating: 7, count: 16))
    #expect(await probe.starts == 1)
    let usage = await cache.usage()
    #expect(usage.cached == 1)
    #expect(!usage.initializing)
    #expect(usage.factoryStarts == 1)
}

@Test func clipReaderCacheSerializesDistinctFactoriesAndBoundsEntries() async throws {
    let cache = ClipReaderCache<Int>(capacity: 2)
    let probe = ReaderFactoryProbe()
    async let a = cache.value(for: "a") { try await probe.create(1) }
    async let b = cache.value(for: "b") { try await probe.create(2) }
    async let c = cache.value(for: "c") { try await probe.create(3) }
    let results = try await [a, b, c]
    #expect(results == [1, 2, 3])
    #expect(await probe.peak == 1)
    let usage = await cache.usage()
    #expect(usage.cached == 2)
    #expect(usage.factoryStarts == 3)
}

private enum ReaderFixtureError: Error { case failed }

@Test func clipReaderCacheDoesNotCacheFailedFactories() async throws {
    let cache = ClipReaderCache<Int>(capacity: 1)
    do {
        _ = try await cache.value(for: "broken") { throw ReaderFixtureError.failed }
        Issue.record("Failed source was accepted.")
    } catch ReaderFixtureError.failed {}
    let value = try await cache.value(for: "broken") { 42 }
    #expect(value == 42)
    let usage = await cache.usage()
    #expect(usage.factoryStarts == 2)
    #expect(usage.cached == 1)
}
