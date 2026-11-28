import Foundation

/// One cached snapshot per timeline revision. Pure viewport queries are
/// logarithmic in the number of events plus the number actually visible.
@MainActor final class StudioTimelineEventIndex {
    struct Snapshot {
        let markers: [TimelineStrip.Marker]
        let keys: [Double]
        let bursts: [(start: Double, end: Double)]

        init(markers: [TimelineStrip.Marker], keys: [Double]) {
            self.markers = markers.filter { $0.t.isFinite }.sorted { $0.t < $1.t }
            self.keys = keys.filter(\.isFinite).sorted()
            bursts = TimelineGeometry.bursts(times: self.keys, gap: 0.5)
        }

        func visibleMarkers(from start: Double, through end: Double) -> ArraySlice<TimelineStrip.Marker> {
            guard start.isFinite, end.isFinite, end >= start else { return markers[0..<0] }
            let a = lowerBound(markers.count) { markers[$0].t >= start }
            let b = lowerBound(markers.count) { markers[$0].t > end }
            return markers[a..<b]
        }

        func visibleBursts(from start: Double, through end: Double) -> ArraySlice<(start: Double, end: Double)> {
            guard start.isFinite, end.isFinite, end >= start else { return bursts[0..<0] }
            let a = lowerBound(bursts.count) { bursts[$0].end >= start }
            let b = lowerBound(bursts.count) { bursts[$0].start > end }
            return bursts[a..<max(a, b)]
        }

        private func lowerBound(_ count: Int, where predicate: (Int) -> Bool) -> Int {
            var lo = 0, hi = count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if predicate(mid) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
    }

    private var revision: Int?
    private var cached: Snapshot?

    func snapshot(revision next: Int, build: () -> Snapshot) -> Snapshot {
        if revision == next, let cached { return cached }
        let value = build()
        revision = next; cached = value
        return value
    }
}
