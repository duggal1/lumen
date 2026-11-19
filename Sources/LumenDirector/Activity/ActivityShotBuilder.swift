import Foundation
import LumenCore
import LumenProject

/// Pure, deterministic conversion of 10 Hz activity grids into proposed zoom shots.
/// Owns no state; safe to call from any task. Click/typing/scroll and hover-only
/// evidence are suppressed here; explicit input keeps priority in the planner.
public enum ActivityShotBuilder {
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

        mutating func absorb(_ c: Comp, t: Double, s: ActivitySettings) {
            lastT = t; samples += 1
            maxCells = max(maxCells, c.cells); energy += c.energy
            if capT == nil, t - firstT >= s.maxActiveSeconds { capT = t }
            if capT == nil {
                let u = union.union(c.box)
                if Double(u.area) / Double(ActivityConst.cells) <= s.maxAreaFraction { union = u }
            }
            guard samples >= s.onsetSamples, capT == nil else { return }
            if let last = wps.last {
                let grew = Double(union.area) >= 1.2 * Double(last.box.area)
                let moved = hypot(union.cx - last.box.cx, union.cy - last.box.cy) >= 3
                if (grew || moved), t - last.t >= 0.8, wps.count < 6 { wps.append((t, union)) }
            } else { wps.append((t, union)) }
        }
    }

    /// Builds shots and `busy` spans. Overlapping shots are chained into one shot
    /// with in-shot waypoints, never emitted as two overlapping segments.
    public static func build(grids: [ActivityGrid], source: (w: Double, h: Double),
                             inputs: ActivityInputs, settings s: ActivitySettings) -> ActivityResult {
        guard s.enabled, grids.count > 3 else { return ActivityResult() }
        let dt = (grids[grids.count - 1].t - grids[0].t) / Double(grids.count - 1)
        guard dt > 0 else { return ActivityResult() }
        let cw = source.w / Double(ActivityConst.gw)
        let ch = source.h / Double(ActivityConst.gh)
        var tracks: [Track] = []

        for g in grids {
            let active = mask(for: g, t: g.t, inputs: inputs, settings: s, cw: cw, ch: ch)
            for c in components(active, g.cells) {
                var best = -1, bestOv = 0
                for (i, tr) in tracks.enumerated() where g.t - tr.lastT <= s.settleHold + 1e-6 {
                    let ov = tr.union.inflated(1).overlapArea(c.box)
                    if ov > bestOv { bestOv = ov; best = i }
                }
                if best < 0 {
                    tracks.append(Track(firstT: g.t, lastT: g.t, union: c.box))
                    best = tracks.count - 1
                }
                assign(c, at: g.t, to: best, in: &tracks, settings: s)
            }
        }

        let made = shots(from: tracks, grids: grids, dt: dt, cw: cw, ch: ch,
                         source: source, settings: s)
        return ActivityResult(shots: chain(made.shots), busy: made.busy)
    }

    /// Explicit input and hover alone never create activity. A pointer-only
    /// change near the cursor is cleared; typing, scrolling and full-screen
    /// flashes are cleared outright.
    static func mask(for g: ActivityGrid, t: Double, inputs: ActivityInputs,
                     settings s: ActivitySettings, cw: Double, ch: Double) -> [Bool] {
        var active = g.cells.map { $0 >= s.threshold }
        let none = [Bool](repeating: false, count: ActivityConst.cells)
        if inputs.has(inputs.keys, t - s.suppressAfterKey, t + 0.1)
            || inputs.has(inputs.scrolls, t - s.scrollWindow, t + s.scrollWindow) {
            return none
        }
        if inputs.has(inputs.moveT, t - 0.5, t),
           !inputs.has(inputs.clicks, t - 1.2, t),
           let c = inputs.cursor(at: t) {
            let r = s.hoverRadiusCells
            for y in 0..<ActivityConst.gh {
                for x in 0..<ActivityConst.gw {
                    let dx = Double(x) + 0.5 - c.x / cw
                    let dy = Double(y) + 0.5 - c.y / ch
                    if dx * dx + dy * dy <= r * r { active[y * ActivityConst.gw + x] = false }
                }
            }
        }
        let covered = active.reduce(0) { $0 + ($1 ? 1 : 0) }
        return Double(covered) / Double(ActivityConst.cells) > s.maxAreaFraction ? none : active
    }

    private static func assign(_ c: Comp, at t: Double, to i: Int,
                               in tracks: inout [Track], settings s: ActivitySettings) {
        tracks[i].absorb(c, t: t, s: s)
    }

    private static func shots(from tracks: [Track], grids: [ActivityGrid], dt: Double,
                              cw: Double, ch: Double, source: (w: Double, h: Double),
                              settings s: ActivitySettings) -> (shots: [VisualShot], busy: [ClosedRange<Double>]) {
        var shots: [VisualShot] = []
        var busy: [ClosedRange<Double>] = []
        for tr in tracks {
            let span = tr.lastT - tr.firstT + dt
            let continuity = Double(tr.samples) * dt / span
            let loader = tr.maxCells < s.minCells
            if loader {
                guard s.zoomOnLoaders, span >= 0.8, continuity >= 0.8 else { continue }
            } else {
                guard tr.samples >= s.onsetSamples, continuity >= 0.35 || span < 1.2 else { continue }
            }
            let start = max(grids[0].t, tr.firstT - s.lead)
            let end = max((tr.capT ?? tr.lastT) + s.settleHold, start + s.minHold)
            busy.append(start...(tr.lastT + s.settleHold))
            let boxes = tr.wps.isEmpty ? [(t: tr.firstT, box: tr.union)] : tr.wps
            var wps: [VisualShot.Waypoint] = []
            for (i, w) in boxes.enumerated() {
                guard let tg = target(w.box, cw: cw, ch: ch, source: source, settings: s) else {
                    if i == 0 { break } else { continue }
                }
                wps.append(VisualShot.Waypoint(t: i == 0 ? start : w.t, rect: tg.rect, scale: tg.scale))
            }
            guard !wps.isEmpty else { continue }
            shots.append(VisualShot(start: start, end: end, waypoints: wps,
                                    strength: tr.energy, kind: loader ? .loader : .region))
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

    /// Overlapping shots become one shot whose later waypoints pan the camera
    /// inside it. Guarantees one target at a time and no overlapping segments.
    private static func chain(_ shots: [VisualShot]) -> [VisualShot] {
        var chained: [VisualShot] = []
        for sh in shots.sorted(by: { $0.start < $1.start }) {
            if var prev = chained.last, sh.start < prev.end {
                prev.waypoints += sh.waypoints.map { var w = $0; w.t = max(w.t, sh.start); return w }
                prev.waypoints.sort { $0.t < $1.t }
                prev.end = max(prev.end, sh.end)
                prev.strength = max(prev.strength, sh.strength)
                chained[chained.count - 1] = prev
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
