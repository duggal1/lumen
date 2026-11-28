import Foundation

/// Per-consumer reader admission. A single in-flight factory and small LRU
/// prevent concurrent seeks from constructing duplicate AVAssetReaders.
/// Preview/export still use separate instances; no mutable seek history is shared.
actor ClipReaderCache<Value: Sendable> {
    private struct Flight: Sendable {
        let key: String
        let id: UInt64
        let task: Task<Value, Error>
    }

    private let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []
    private var active: Flight?
    private var nextID: UInt64 = 0
    private var starts = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Concurrent requests join the same initialization. Different keys wait
    /// for the single active factory rather than starting another decoder.
    /// Cancelled callers never publish another request or retry a factory.
    func value(for key: String, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            if let value = values[key] {
                touch(key)
                return value
            }
            let flight: Flight
            if let existing = active {
                flight = existing
            } else {
                nextID &+= 1
                starts += 1
                flight = Flight(key: key, id: nextID, task: Task { try await load() })
                active = flight
            }
            let result = await flight.task.result
            settle(flight, result: result)
            try Task.checkCancellation()
            if flight.key == key { return try result.get() }
            // An unrelated failure must not poison this source. Retry
            // admission only after the previous factory has settled.
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func settle(_ flight: Flight, result: Result<Value, Error>) {
        guard active?.id == flight.id else { return }
        active = nil
        guard case .success(let value) = result else { return }
        values[flight.key] = value
        touch(flight.key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    /// Internal evidence for regression tests and later hardware profiling.
    func usage() -> (cached: Int, initializing: Bool, factoryStarts: Int) {
        (values.count, active != nil, starts)
    }
}
