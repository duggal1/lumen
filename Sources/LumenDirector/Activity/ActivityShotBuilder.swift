import Foundation
import LumenCore
import LumenProject

/// Pure, deterministic conversion of 10 Hz activity grids into proposed zoom shots.
/// Owns no state; safe to call from any task. Click/typing/scroll and hover-only
/// evidence are suppressed here; explicit input keeps priority in the planner.
public enum ActivityShotBuilder {
    // Distinct budgets: continuity bridges evidence gaps; reading hold is the
    // visible editorial tail. Neither is a semantic completion detector.
    private static let pendingGap = 2.0
    private static let continuationGap = 3.0
    private static let readingHold = 2.0
    private static let destinationLookback = 8.0

    struct Comp {
        var box: CellBox
        var cells: Int
        var energy: Double
    }

    struct Track {
        var firstT: Double
        var lastT: Double
        var union: CellBox
        var samples = 0
        var maxCells = 0
        var energy = 0.0
        var wps: [(t: Double, box: CellBox)] = []
        var capT: Double? = nil
        var hoverTainted = false
        var localHoverTainted = false
        var actionTime: Double? = nil
        var actionEnd: Double? = nil
        var growthSteps = 0
        var growthAnchor: CellBox? = nil
        var lastGrowth = -Double.infinity
        var progressionOverflow = false

        var sustained: Bool {
            actionTime != nil && !localHoverTainted && growthSteps >= 2 &&
                samples >= 5 && lastT - firstT >= 0.5
        }

        mutating func absorb(_ c: Comp, t: Double, s: ActivitySettings) {
            lastT = t; samples += 1
            maxCells = max(maxCells, c.cells); energy += c.energy
            if capT == nil, t - firstT >= s.maxActiveSeconds { capT = t }
            let u = union.union(c.box)
            if capT == nil || sustained {
                if Double(u.area) / Double(ActivityConst.cells) <= s.maxAreaFraction { union = u }
                else { progressionOverflow = true }
            }
            if actionTime != nil, !localHoverTainted {
                if let anchor = growthAnchor {
                    let extent = max(union.x1 - anchor.x1, anchor.x0 - union.x0,
                                     union.y1 - anchor.y1, anchor.y0 - union.y0)
                    if extent >= 1, Double(union.area) >= Double(anchor.area) * 1.18,
                       t - lastGrowth >= 0.25 {
                        growthSteps += 1; growthAnchor = union; lastGrowth = t
                    }
                } else {
                    growthAnchor = union; lastGrowth = t
                }
            }
            guard samples >= s.onsetSamples, capT == nil || sustained else { return }
            if let last = wps.last {
                let grew = Double(union.area) >= 1.2 * Double(last.box.area)
                let moved = hypot(union.cx - last.box.cx, union.cy - last.box.cy) >= 3
                if (grew || moved), t - last.t >= 0.8, wps.count < 6 { wps.append((t, union)) }
            } else { wps.append((t, union)) }
        }
    }

    /// Builds shots and busy spans; overlapping independent subjects are
    /// arbitrated rather than concatenated into a single camera path.
    public static func build(grids: [ActivityGrid], source: (w: Double, h: Double),
                             inputs: ActivityInputs, settings s: ActivitySettings) -> ActivityResult {
        guard s.enabled, source.w.isFinite, source.h.isFinite, source.w > 0, source.h > 0 else { return ActivityResult() }
        // Canonicalize before computing timing; malformed samples must not
        // poison the entire sequence or enter a binary-search timeline.
        let grids = grids.filter { $0.t.isFinite && $0.cells.count == ActivityConst.cells }
            .sorted { $0.t < $1.t }
        guard grids.count > 3, zip(grids, grids.dropFirst()).allSatisfy({ $0.0.t < $0.1.t }) else {
            return ActivityResult()
        }
        let dt = (grids[grids.count - 1].t - grids[0].t) / Double(grids.count - 1)
        guard dt > 0 else { return ActivityResult() }
        let cw = source.w / Double(ActivityConst.gw)
        let ch = source.h / Double(ActivityConst.gh)
        var tracks: [Track] = []
        var live: [Int] = []

        for g in grids where g.cells.count == ActivityConst.cells && g.t.isFinite {
            live.removeAll {
                let track = tracks[$0]
                // Freeze ALL action-owned evidence, including provisional
                // tracks. Post-click growth cannot retroactively prove the
                // previous action or change its historical framing.
                if let end = track.actionEnd, g.t >= end { return true }
                let grace: Double
                if track.sustained {
                    grace = max(s.settleHold, continuationGap)
                } else if track.actionTime != nil, !track.localHoverTainted,
                          track.samples >= max(2, s.onsetSamples) {
                    // An observed seed may bridge a bounded loading gap.
                    // A wholly unobserved delayed result earns no exception.
                    grace = max(s.settleHold, pendingGap)
                } else {
                    grace = s.settleHold
                }
                return g.t - track.lastT > grace + 1e-6
            }
            let active = mask(for: g, t: g.t, inputs: inputs, settings: s, cw: cw, ch: ch)
            for c in components(active, g.cells) {
                var best = -1, bestOv = 0
                for i in live {
                    let tr = tracks[i]
                    guard tr.lastT < g.t else { continue }
                    let ov = tr.union.inflated(1).overlapArea(c.box)
                    if ov > bestOv { bestOv = ov; best = i }
                }
                if best < 0 {
                    var track = Track(firstT: g.t, lastT: g.t, union: c.box)
                    track.actionTime = inputs.recentAction(at: g.t)
                    track.actionEnd = track.actionTime.flatMap { inputs.nextAction(after: $0) }
                    tracks.append(track)
                    best = tracks.count - 1
                    live.append(best)
                }
                // Keep rejected components tracked through settling. Otherwise
                // a persistent hover animation can re-enter as a new shot
                // the moment the remote uncertainty window expires.
                if g.t - tracks[best].firstT <= 0.25,
                   inputs.hoverAssociated(at: g.t, box: c.box, cw: cw, ch: ch,
                                          radius: s.hoverRadiusCells) {
                    tracks[best].hoverTainted = true
                }
                // Until corroborated, pointer-local growth is still hover
                // evidence even if the pointer arrived after track onset.
                // Once confirmed, reading the response with the pointer must
                // not revoke the already established subject.
                if (g.t - tracks[best].firstT <= 0.25 ||
                    (tracks[best].actionTime != nil && !tracks[best].sustained)),
                   inputs.localHover(at: g.t, box: c.box, cw: cw, ch: ch, radius: s.hoverRadiusCells) {
                    tracks[best].localHoverTainted = true
                }
                tracks[best].absorb(c, t: g.t, s: s)
            }
        }

        let made = shots(from: tracks, grids: grids, dt: dt, cw: cw, ch: ch,
                         source: source, inputs: inputs, settings: s)
        return ActivityResult(shots: chain(made.shots), busy: made.busy)
    }

    /// Clear typing, scrolling and full-screen flashes. Hover is classified
    /// at the whole-track level so masking cannot leave a false subject.
    static func mask(for g: ActivityGrid, t: Double, inputs: ActivityInputs,
                     settings s: ActivitySettings, cw: Double, ch: Double) -> [Bool] {
        let active = g.cells.map { $0 >= s.threshold }
        let none = [Bool](repeating: false, count: ActivityConst.cells)
        if inputs.has(inputs.keys, t - s.suppressAfterKey, t + 0.1)
            || inputs.has(inputs.scrolls, t - s.scrollWindow, t + s.scrollWindow) {
            return none
        }
        let covered = active.reduce(0) { $0 + ($1 ? 1 : 0) }
        return Double(covered) / Double(ActivityConst.cells) > s.maxAreaFraction ? none : active
    }

    private static func shots(from tracks: [Track], grids: [ActivityGrid], dt: Double,
                              cw: Double, ch: Double, source: (w: Double, h: Double),
                              inputs: ActivityInputs, settings s: ActivitySettings) -> (shots: [VisualShot], busy: [ClosedRange<Double>]) {
        var shots: [VisualShot] = []
        var busy: [ClosedRange<Double>] = []
        // Multiple growing candidates tied to the same action are ambiguous:
        // do not grant any of them an exception to remote-hover uncertainty.
        var confirmedPerAction: [Double: Int] = [:]
        for tr in tracks where tr.sustained {
            if let action = tr.actionTime { confirmedPerAction[action, default: 0] += 1 }
        }
        // A stationary revealed component can be a destination even if it
        // never grows like streamed text. Require a prior confirmed response,
        // a new primary click, a distinct region away from the clicked control,
        // and unambiguous, repeated non-hover observations.
        var precedingResponses: [Double: Track] = [:]
        for tr in tracks where tr.sustained && !tr.progressionOverflow {
            guard let owner = tr.actionTime, confirmedPerAction[owner] == 1,
                  let boundary = tr.actionEnd, boundary >= tr.lastT else { continue }
            let quiet = boundary - tr.lastT
            if quiet > max(s.settleHold, readingHold) {
                // After returning wide, a click on the earlier response can
                // still own a destination. Do not link arbitrary late clicks
                // elsewhere, or retain unbounded historical context.
                guard quiet <= destinationLookback,
                      let click = inputs.primaryClick(at: boundary) else { continue }
                let x = Double(click.x) / cw, y = Double(click.y) / ch
                let box = tr.union.inflated(1)
                guard x >= Double(box.x0), x <= Double(box.x1 + 1),
                      y >= Double(box.y0), y <= Double(box.y1 + 1) else { continue }
            }
            precedingResponses[boundary] = tr
        }
        var destinations: [Double: [Int]] = [:]
        for (id, tr) in tracks.enumerated() {
            guard !tr.hoverTainted, !tr.localHoverTainted, !tr.progressionOverflow,
                  let action = tr.actionTime, let previous = precedingResponses[action],
                  let click = inputs.primaryClick(at: action),
                  tr.firstT >= action, tr.firstT - action <= 1.2,
                  tr.samples >= max(4, s.onsetSamples), tr.maxCells >= s.minCells,
                  Double(tr.samples) * dt / (tr.lastT - tr.firstT + dt) >= 0.65,
                  previous.union.inflated(1).overlapArea(tr.union) == 0 else { continue }
            let x = Double(click.x) / cw, y = Double(click.y) / ch
            let dx = max(Double(tr.union.x0) - x, x - Double(tr.union.x1 + 1), 0)
            let dy = max(Double(tr.union.y0) - y, y - Double(tr.union.y1 + 1), 0)
            guard hypot(dx, dy) > max(s.hoverRadiusCells, 2.5) else { continue }
            destinations[action, default: []].append(id)
        }
        for (id, tr) in tracks.enumerated() {
            let sustained = tr.sustained && tr.actionTime.map { confirmedPerAction[$0] == 1 } == true
            guard !tr.localHoverTainted, !tr.hoverTainted || sustained else { continue }
            let span = tr.lastT - tr.firstT + dt
            let continuity = Double(tr.samples) * dt / span
            // Long-running motion confined to the same small region with
            // no meaningful geometry progression is weak attention evidence.
            // Keep it busy for time editing, but abstain from camera motion.
            if !sustained, tr.capT != nil, continuity >= 0.8, tr.wps.count <= 1 {
                busy.append(tr.firstT...(tr.lastT + s.settleHold))
                continue
            }
            let loader = tr.maxCells < s.minCells
            if loader {
                guard s.zoomOnLoaders, span >= 0.8, continuity >= 0.8 else { continue }
            } else {
                guard tr.samples >= s.onsetSamples, sustained || continuity >= 0.35 || span < 1.2 else { continue }
            }
            let destination = tr.actionTime.map { destinations[$0] == [id] && (confirmedPerAction[$0] ?? 0) == 0 } == true
            let associated = sustained || destination
            let start = max(grids[0].t, tr.firstT - s.lead,
                            associated ? (tr.actionTime ?? tr.firstT) : -.infinity)
            let settle = sustained ? max(s.settleHold, readingHold) : s.settleHold
            let naturalEnd = max((sustained ? tr.lastT : (tr.capT ?? tr.lastT)) + settle, start + s.minHold)
            let end = associated ? min(naturalEnd, tr.actionEnd ?? .infinity) : naturalEnd
            // Protect the entire editorial reading interval from idle ramps,
            // including a minimum hold longer than the observed activity.
            busy.append(start...max(start, end, tr.lastT + settle))
            guard end > start + 0.02 else { continue }
            // Recorded look-ahead can frame the eventual growing subject from
            // the start. No per-token camera chase; if it cannot fit, stay wide.
            if sustained && tr.progressionOverflow { continue }
            let boxes = associated ? [(t: tr.firstT, box: tr.union)] :
                (tr.wps.isEmpty ? [(t: tr.firstT, box: tr.union)] : tr.wps)
            var wps: [VisualShot.Waypoint] = []
            for (i, w) in boxes.enumerated() {
                guard let tg = target(w.box, cw: cw, ch: ch, source: source, settings: s) else {
                    if i == 0 { break } else { continue }
                }
                wps.append(VisualShot.Waypoint(t: i == 0 ? start : w.t, rect: tg.rect, scale: tg.scale))
            }
            guard !wps.isEmpty else { continue }
            var shot = VisualShot(start: start, end: end, waypoints: wps,
                                  strength: tr.energy, kind: loader ? .loader : .region)
            shot.subjectID = id
            shot.sustained = sustained
            shot.actionTime = associated ? tr.actionTime : nil
            shots.append(shot)
        }
        return (shots, busy)
    }

    private static func target(_ b: CellBox, cw: Double, ch: Double,
                               source: (w: Double, h: Double),
                               settings s: ActivitySettings) -> (rect: PxRect, scale: Double)? {
        var r = PxRect(x: Double(b.x0) * cw, y: Double(b.y0) * ch,
                       w: Double(b.x1 - b.x0 + 1) * cw, h: Double(b.y1 - b.y0 + 1) * ch)
        r = PxRect(x: r.x - r.w * s.padFraction / 2, y: r.y - r.h * s.padFraction / 2,
                   w: r.w * (1 + s.padFraction), h: r.h * (1 + s.padFraction))
        r = r.centered(w: max(r.w, source.w / s.maxScale), h: max(r.h, source.h / s.maxScale))
        r = r.intersection(PxRect(x: 0, y: 0, w: source.w, h: source.h))
        let scale = min(source.w / max(r.w, 1), source.h / max(r.h, 1))
        return scale >= s.minTrigger ? (r, min(scale, s.maxScale)) : nil
    }

    /// Distinct connected subjects never become an invented pan. Hold the
    /// current subject unless a corroborated action-associated one arrives.
    /// Conservative overlap arbitration leaves ambiguous competitors wide.
    private static func chain(_ shots: [VisualShot]) -> [VisualShot] {
        var chained: [VisualShot] = []
        for sh in shots.sorted(by: { $0.start < $1.start }) {
            if var prev = chained.last, sh.start < prev.end {
                // A new corroborated action can take ownership. The already
                // established subject remains intact before that boundary.
                guard let action = sh.actionTime,
                      prev.actionTime.map({ action > $0 }) ?? true else { continue }
                let boundary = min(sh.start, max(prev.start, action))
                if boundary - prev.start > 0.02 {
                    prev.end = boundary
                    prev.waypoints.removeAll { $0.t >= boundary }
                    chained[chained.count - 1] = prev
                } else { chained.removeLast() }
                chained.append(sh)
            } else { chained.append(sh) }
        }
        return chained
    }

    /// 4-neighbour components over the 1-cell-dilated mask (bridges text
    /// line gaps); boxes come from real active cells only.
    static func components(_ active: [Bool], _ energy: [UInt8]) -> [Comp] {
        let gw = ActivityConst.gw, gh = ActivityConst.gh
        var dil = [Bool](repeating: false, count: ActivityConst.cells)
        for y in 0..<gh {
            for x in 0..<gw where active[y * gw + x] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < gw, ny < gh { dil[ny * gw + nx] = true }
                    }
                }
            }
        }
        var seen = [Bool](repeating: false, count: ActivityConst.cells)
        var out: [Comp] = []
        var stack: [Int] = []
        for start in 0..<(gw * gh) where dil[start] && !seen[start] {
            var box: CellBox?
            var n = 0, e = 0.0
            stack.append(start); seen[start] = true
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                if active[i] {
                    n += 1; e += Double(energy[i])
                    let b = CellBox(x0: x, y0: y, x1: x, y1: y)
                    box = box.map { $0.union(b) } ?? b
                }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < gw, ny < gh,
                       dil[ny * gw + nx], !seen[ny * gw + nx] {
                        seen[ny * gw + nx] = true; stack.append(ny * gw + nx)
                    }
                }
            }
            if let box { out.append(Comp(box: box, cells: n, energy: e)) }
        }
        return out
    }
}
