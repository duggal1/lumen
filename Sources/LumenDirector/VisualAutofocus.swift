import Foundation
import CoreGraphics
import LumenCore
import LumenProject

/// Passive, intelligent visual autofocus. See `Docs/VISUAL-AUTOFOCUS.md`.
///
/// The user demos an AI product or a design without clicking or hovering. The
/// 10 Hz `ActivityPoint` stream from `ActivityAnalyzer` is the only new evidence:
/// it carries a changed-region rect, a coverage fraction and a weighted centre.
/// This component turns stable, localized change into `.visual` zoom intents,
/// suppressing hover, full-screen flashes, scrolling, tiny animations and rapid
/// flicker. It composes with the conservative `VisualZoom` baseline and never
/// emits a hover intent or a second animation system.
enum VisualAutofocus {
    // MARK: - Public vocabulary

    /// Why evidence or a candidate was dropped. Exposed so tests and the doc
    /// can name the failure instead of guessing from an empty intent list.
    enum Rejection: String, Sendable, Equatable, CaseIterable {
        case invalid, outsideTrim, onCut, fullScreen, tiny, lowCoverage, scroll,
             hoverOnly, tooBrief, flicker, animationLoop, inputOverlap, cooldown
    }

    /// Geometry-only classification. No OCR, no semantics, no text.
    enum BeatKind: String, Sendable, Equatable, CaseIterable {
        case result, reveal, textChange, cardDraw, panelOpen
    }

    /// One settled visual beat and the intent it hands to the camera solver.
    struct Beat: Sendable, Equatable {
        var kind: BeatKind
        var first: Double
        var settle: Double
        var rect: CGRect
        var observations: Int
        var coverage: Double
        var arrival: Double
        var end: Double

        /// The whole changed region is the subject. `frameRect` makes the planner
        /// emit `.element` focus, so a revealed panel is not cropped at the edge.
        var intent: ZoomPlanner.Intent {
            var i = ZoomPlanner.Intent(kind: .visual, t: arrival, tEnd: end,
                                       x: rect.midX, y: rect.midY)
            i.rect = rect
            i.frameRect = rect
            return i
        }
    }

    struct Decision: Sendable, Equatable {
        var beats: [Beat] = []
        var rejections: [Rejection] = []
    }

    struct Config: Sendable, Equatable {
        static let `default` = Config()

        var minArea = 0.004              // 0.4% of the frame: below this is speckle
        var maxArea = 0.70              // above this is a full-screen flash
        var minCoverage = 0.0012
        var maxCoverage = 0.45
        var minObservations = 3         // analyzer settles for 0.4 s => 3-5 points
        var minSpan = 0.28
        var clusterGap = 0.6
        var driftFraction = 0.16        // of the source diagonal
        // The camera solver already starts `.auto` shots early (lead-in + settle)
        // so the frame is composed before the marked time. Adding our own
        // anticipation would shift the action 0.2 s early and fight that solver.
        var anticipation = 0.0
        var readingBase = 0.7
        var readingSpan = 1.2
        var readingCap = 1.6
        var cooldown = 2.5              // no pumping between results
        var inputGuard = 1.0
        var hoverPixels = 48.0
        var hoverArea = 0.008
    }

    static let `default` = Config()

    // MARK: - Internal working types

    private struct Observation {
        let t: Double
        let rect: CGRect
        let coverage: Double
    }

    private struct Candidate {
        var obs: [Observation] = []
    }

    // MARK: - Analyze

    /// Pure and deterministic: the same activity stream always yields the same
    /// beats, regardless of input order.
    static func analyze(_ points: [ActivityPoint], events: [InputEvent] = [],
                        input: [ZoomPlanner.Intent] = [], src: SourceInfo,
                        tm: TimeMap, config: Config = .default) -> Decision {
        var decision = Decision()
        let W = Double(src.width), H = Double(src.height)
        guard W > 0, H > 0 else { return decision }
        let frameArea = W * H
        let diagonal = hypot(W, H)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)

        let sortedPoints = points.sorted { a, b in
            if a.t != b.t { return a.t < b.t }
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
        let sortedEvents = events.sorted { a, b in
            if a.t != b.t { return a.t < b.t }
            return a.kind.rawValue < b.kind.rawValue
        }
        let moves = sortedEvents.filter {
            $0.kind == .move && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite
        }
        let navigation = sortedEvents.filter { $0.kind == .scroll || $0.kind == .drag }
        let inputStamps = sortedEvents.filter { $0.kind == .down || $0.kind == .keyDown }.map(\.t)

        func hasNavigation(near t: Double) -> Bool {
            navigation.contains { abs($0.t - t) <= 0.8 }
        }
        func inputNear(_ t: Double) -> Bool {
            inputStamps.contains { abs($0 - t) <= 1.0 }
        }
        func pointer(near t: Double) -> CGPoint? {
            var best: CGPoint?
            var gap = Double.greatestFiniteMagnitude
            for e in moves {
                let d = t - e.t
                if d < -0.05 { break }
                if d <= 0.9, d < gap {
                    gap = d
                    best = CGPoint(x: Double(e.x), y: Double(e.y))
                }
            }
            return best
        }

        // 1. Gate each observation; a rejecting event also splits the candidate.
        var candidates: [Candidate] = []
        var current: Candidate?
        func closeCurrent() {
            if let c = current, !c.obs.isEmpty { candidates.append(c) }
            current = nil
        }

        for p in sortedPoints {
            guard p.t.isFinite, p.x.isFinite, p.y.isFinite,
                  let r = p.region,
                  r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
                  r.width > 0, r.height > 0,
                  let coverage = p.coverage, coverage.isFinite else {
                decision.rejections.append(.invalid)
                closeCurrent()
                continue
            }
            guard p.t >= tm.trimStart + 0.2, p.t <= tm.trimEnd - 0.2 else {
                decision.rejections.append(.outsideTrim)
                closeCurrent()
                continue
            }
            guard !tm.isCut(p.t) else {
                decision.rejections.append(.onCut)
                closeCurrent()
                continue
            }
            let rect = r.intersection(canvas)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else {
                decision.rejections.append(.invalid)
                closeCurrent()
                continue
            }
            let fraction = (rect.width * rect.height) / frameArea

            // A full-screen flash or a large navigation change is not a subject.
            if fraction > config.maxArea || coverage > config.maxCoverage {
                decision.rejections.append(.fullScreen)
                closeCurrent()
                continue
            }
            // Hover is never a trigger. A small change co-located with a pointer
            // and with no click/key nearby is a hover highlight. This is checked
            // before the tiny gate so the rejection names the real cause.
            if fraction < config.hoverArea,
               let pt = pointer(near: p.t),
               rect.insetBy(dx: -config.hoverPixels, dy: -config.hoverPixels)
                   .contains(pt),
               !inputNear(p.t) {
                decision.rejections.append(.hoverOnly)
                closeCurrent()
                continue
            }
            if fraction < config.minArea || coverage < config.minCoverage {
                decision.rejections.append(fraction < config.minArea ? .tiny : .lowCoverage)
                // Keep the candidate open: a tiny caret blink must not split a
                // legitimate change that happens alongside it.
                continue
            }
            if hasNavigation(near: p.t) {
                decision.rejections.append(.scroll)
                closeCurrent()
                continue
            }

            let observation = Observation(t: p.t, rect: rect, coverage: coverage)
            if let c = current, let last = c.obs.last {
                let gap = p.t - last.t
                let drift = hypot(rect.midX - last.rect.midX, rect.midY - last.rect.midY)
                if gap > config.clusterGap || drift > config.driftFraction * diagonal {
                    closeCurrent()
                }
            }
            if current == nil { current = Candidate() }
            current?.obs.append(observation)
        }
        closeCurrent()

        // 2. Validate candidates into beats.
        var beats: [Beat] = []
        for candidate in candidates {
            let obs = candidate.obs
            guard let first = obs.first, let last = obs.last else { continue }
            let span = last.t - first.t
            guard obs.count >= config.minObservations, span >= config.minSpan else {
                decision.rejections.append(.tooBrief)
                continue
            }
            // Repeated short pulses close together (a pulsing card, a looping
            // animation) are one candidate by time but several separate beats
            // by rhythm. Split on the quiet gaps inside the candidate: three or
            // more short bursts at one place are animation, not a result.
            var bursts: [[Observation]] = []
            var burst: [Observation] = []
            for o in obs {
                if let prev = burst.last, o.t - prev.t >= 0.35 {
                    bursts.append(burst); burst = []
                }
                burst.append(o)
            }
            if !burst.isEmpty { bursts.append(burst) }
            if bursts.count >= 3 {
                let short = bursts.filter { b in
                    guard let a = b.first, let z = b.last else { return false }
                    return z.t - a.t < 0.5
                }
                var local = true
                for b in bursts {
                    guard let c = b.first else { continue }
                    if hypot(c.rect.midX - first.rect.midX, c.rect.midY - first.rect.midY)
                        > 0.08 * diagonal { local = false }
                }
                if short.count == bursts.count, local {
                    decision.rejections.append(.animationLoop)
                    continue
                }
            }
            // Oscillation in place (spinner, pulse, blinking highlight) is not
            // a result: the path doubles back instead of travelling anywhere.
            var path = 0.0
            for i in 1..<obs.count {
                path += hypot(obs[i].rect.midX - obs[i - 1].rect.midX,
                              obs[i].rect.midY - obs[i - 1].rect.midY)
            }
            let net = hypot(last.rect.midX - first.rect.midX,
                            last.rect.midY - first.rect.midY)
            if path > 2.5 * max(net, 0.02 * diagonal) {
                decision.rejections.append(.flicker)
                continue
            }

            var union = first.rect
            for o in obs.dropFirst() { union = union.union(o.rect) }
            let fraction = (union.width * union.height) / frameArea
            let arrival = max(tm.trimStart, first.t - config.anticipation)
            let reading = clamp(config.readingBase + config.readingSpan * fraction,
                                config.readingBase, config.readingCap)
            let end = min(tm.trimEnd, last.t + reading)
            guard end - arrival >= 0.3 else {
                decision.rejections.append(.tooBrief)
                continue
            }

            let firstArea = first.rect.width * first.rect.height
            let lastArea = last.rect.width * last.rect.height
            let aspect = union.width / max(union.height, 1)
            let coverage = obs.map(\.coverage).reduce(0, +) / Double(obs.count)
            let kind: BeatKind
            if aspect >= 6, fraction < 0.15 {
                kind = .textChange
            } else if fraction >= 0.25 {
                kind = .panelOpen
            } else if fraction >= 0.12 {
                kind = .reveal
            } else if firstArea < 0.6 * lastArea {
                kind = .cardDraw
            } else {
                kind = .result
            }
            beats.append(Beat(kind: kind, first: first.t, settle: last.t,
                              rect: union, observations: obs.count, coverage: coverage,
                              arrival: arrival, end: end))
        }

        // 3. An animation loop is several short pulses at one place, not one
        //    more result. Drop the whole group so the camera does not pump.
        var loopFree: [Beat] = []
        var removed = [Beat]()
        for b in beats.sorted(by: { $0.arrival < $1.arrival }) {
            let cluster = beats.filter { other in
                abs(other.arrival - b.arrival) <= 3.5 &&
                hypot(other.rect.midX - b.rect.midX, other.rect.midY - b.rect.midY)
                    <= 0.08 * diagonal &&
                (other.settle - other.first) < 0.5 && (b.settle - b.first) < 0.5
            }
            if cluster.count >= 3 {
                if !removed.contains(b) { decision.rejections.append(.animationLoop) }
                removed.append(b)
            } else {
                loopFree.append(b)
            }
        }

        // 4. Explicit input (click, typing, dialog markers from Agents 1 and 3)
        //    outranks passive pixels.
        var afterInput: [Beat] = []
        for b in loopFree {
            let collides = input.contains { i in
                i.t <= b.end + config.inputGuard && i.tEnd >= b.arrival - config.inputGuard &&
                Self.near(i.rect.map { CGRect(x: $0.minX, y: $0.minY,
                                              width: $0.width, height: $0.height) },
                          center: CGPoint(x: i.x, y: i.y),
                          beatRect: b.rect, beatCenter: CGPoint(x: b.rect.midX, y: b.rect.midY),
                          tolerance: 0.15 * diagonal)
            }
            if collides { decision.rejections.append(.inputOverlap) }
            else { afterInput.append(b) }
        }

        // 5. Cooldown: one shot for one burst of results.
        var final: [Beat] = []
        for b in afterInput.sorted(by: { $0.arrival < $1.arrival }) {
            if let last = final.last, b.arrival - last.arrival < config.cooldown {
                decision.rejections.append(.cooldown)
            } else {
                final.append(b)
            }
        }
        decision.beats = final
        return decision
    }

    // MARK: - Composition

    /// The single entry point for the planner. It composes the conservative
    /// `VisualZoom` baseline with the passive detector. `.move` events are
    /// stripped before calling the baseline: VisualZoom relaxes its minimum
    /// sample count near the pointer, which is exactly how a hover highlight
    /// could become a shot. Scroll/drag and explicit-input vetoes stay intact.
    static func intents(_ points: [ActivityPoint], events: [InputEvent] = [],
                        input: [ZoomPlanner.Intent] = [], src: SourceInfo,
                        tm: TimeMap, config: Config = .default) -> [ZoomPlanner.Intent] {
        let mine = analyze(points, events: events, input: input, src: src,
                           tm: tm, config: config).beats.map(\.intent)
        let baseline = VisualZoom.intents(points,
                                          events: events.filter { $0.kind != .move },
                                          input: input, src: src, tm: tm)
        let diagonal = hypot(Double(src.width), Double(src.height))
        let keptBaseline = baseline.filter { b in
            !mine.contains { m in
                let mc = m.rect.map { CGPoint(x: Double($0.midX), y: Double($0.midY)) }
                    ?? CGPoint(x: m.x, y: m.y)
                return Self.overlaps(b.t, b.tEnd, m.t, m.tEnd, guard: 0.5) &&
                    Self.near(b.rect, center: CGPoint(x: b.x, y: b.y),
                              beatRect: m.rect, beatCenter: mc,
                              tolerance: 0.03 * diagonal)
            }
        }
        return (mine + keptBaseline).sorted { $0.t < $1.t }
    }

    // MARK: - Geometry helpers

    private static func overlaps(_ a: Double, _ aEnd: Double,
                                 _ b: Double, _ bEnd: Double, guard g: Double) -> Bool {
        a <= bEnd + g && b <= aEnd + g
    }

    private static func near(_ rect: CGRect?, center: CGPoint,
                             beatRect: CGRect?, beatCenter: CGPoint, tolerance: Double) -> Bool {
        if let rect, let beatRect {
            return rect.insetBy(dx: -tolerance, dy: -tolerance).intersects(beatRect)
        }
        if let rect {
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(beatCenter) ||
                   hypot(center.x - beatCenter.x, center.y - beatCenter.y) <= tolerance
        }
        return hypot(center.x - beatCenter.x, center.y - beatCenter.y) <= tolerance
    }
}
