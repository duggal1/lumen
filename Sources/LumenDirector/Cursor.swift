import Foundation
import LumenCore
import LumenProject

enum CursorPipeline {
    static func run(events: [InputEvent], taps: [TapIndicator], st: CursorStyle, tm: TimeMap, src: SourceInfo) -> (CursorTrack, [ClickFX]) {
        let rate = gridRate, lo = tm.trimStart, hi = tm.trimEnd
        let n = max(Int((hi - lo) * rate) + 1, 3)
        let cutoff = hi - 0.8                                   // Stop click / hotkey at the very end: no ring, no hand

        // manual taps act like a press/release pair; they never move the cursor
        var tapEv: [InputEvent] = []
        for t in taps where t.t >= lo && t.t <= hi {
            tapEv.append(InputEvent(t: t.t, kind: .down, x: Float(t.x), y: Float(t.y)))
            tapEv.append(InputEvent(t: t.t + 0.12, kind: .up, x: Float(t.x), y: Float(t.y)))
        }
        let pressEv = (events.filter { $0.kind == .down || $0.kind == .up } + tapEv).sorted { $0.t < $1.t }
        let downs = events.filter { $0.kind == .down && $0.t <= cutoff } + tapEv.filter { $0.kind == .down }

        // 1. ingest: monotonic, deduped
        var ts: [Double] = [], xs: [Double] = [], ys: [Double] = []
        for e in events where e.hasPosition {
            if let l = ts.last, e.t <= l {
                if e.t == l { xs[xs.count - 1] = Double(e.x); ys[ys.count - 1] = Double(e.y) }
                continue
            }
            ts.append(e.t); xs.append(Double(e.x)); ys.append(Double(e.y))
        }
        let hasCursor = !ts.isEmpty                             // device recordings have no cursor: draw none
        // 3-5. PCHIP onto 1440 Hz, de-spike, zero-lag Gaussian
        var X = hasCursor ? pchipResample(t: ts, y: xs, t0: lo, count: n, rate: rate) : [Double](repeating: Double(src.width) / 2, count: n)
        var Y = hasCursor ? pchipResample(t: ts, y: ys, t0: lo, count: n, rate: rate) : [Double](repeating: Double(src.height) / 2, count: n)
        X = gaussianSmooth(median5(X), sigma: st.smoothingSigma * rate)
        Y = gaussianSmooth(median5(Y), sigma: st.smoothingSigma * rate)

        // 2. movements vs dwells (dwell = < 25 pt/s for >= 120 ms)
        var spd = [Double](repeating: 0, count: n)
        for i in 1..<n { spd[i] = hypot(X[i] - X[i - 1], Y[i] - Y[i - 1]) * rate }
        spd[0] = spd[1]
        let thr = 25 * src.backingScale, minDwell = Int(0.12 * rate)
        var moving = spd.map { $0 >= thr }
        var i = 0
        while i < n {
            if moving[i] { i += 1; continue }
            var j = i; while j < n && !moving[j] { j += 1 }
            if j - i < minDwell && i > 0 && j < n { for k in i..<j { moving[k] = true } }
            i = j
        }

        // 7. glide: min-jerk retiming along each movement's own path.
        // Never glide while a button is held: a dragged window must stay
        // exactly under the cursor, not trail it for cinematic smoothing.
        var held = [Bool](repeating: false, count: n)
        var downTime: Double? = nil
        for e in pressEv {
            if e.kind == .down { downTime = e.t }
            else if e.kind == .up, let d = downTime {
                let a = max(Int(((d - lo) * rate).rounded()) - Int(0.05 * rate), 0)
                let b = min(Int(((e.t - lo) * rate).rounded()) + Int(0.05 * rate), n - 1)
                if b >= a { for k in a...b { held[k] = true } }
                downTime = nil
            }
        }
        if let d = downTime {
            let a = max(Int(((d - lo) * rate).rounded()), 0)
            if a < n { for k in a..<n { held[k] = true } }
        }
        if st.glide > 0 {
            var s = 0
            while s < n {
                if !moving[s] { s += 1; continue }
                var e = s; while e < n && moving[e] { e += 1 }
                if e - s > Int(0.1 * rate), !(s..<e).contains(where: { held[$0] }) {
                    glide(&X, &Y, s, e, st.glide)
                }
                s = e
            }
        }

        // 6. click pinning (after glide so pins stay exact)
        let w = 0.065 * rate, r = Int(3 * w)
        for e in events where e.kind == .down || e.kind == .up {
            let c = Int(((e.t - lo) * rate).rounded()); guard c >= 0, c < n else { continue }
            let ex = Double(e.x) - X[c], ey = Double(e.y) - Y[c]
            for j in max(0, c - r)...min(n - 1, c + r) {
                let k = exp(-0.5 * pow(Double(j - c) / w, 2)); X[j] += ex * k; Y[j] += ey * k
            }
        }

        // 11. loop mode: the tail glides (min-jerk) back to the first-frame position so a short clip repeats seamlessly
        if hasCursor, let d = st.loop, d > 0 {
            let tailN = max(min(Int(d * rate), n - 2), 1), x0 = X[0], y0 = Y[0]
            for k in 0...tailN {
                let idx = n - 1 - tailN + k, tau = Double(k) / Double(tailN)
                let wgt = tau * tau * tau * (10 + tau * (-15 + 6 * tau))
                X[idx] = lerp(X[idx], x0, wgt); Y[idx] = lerp(Y[idx], y0, wgt)
            }
        }

        // 8. idle hide
        var op = [Float](repeating: hasCursor ? 1 : 0, count: n)
        if hasCursor, let idle = st.idleHide, idle > 0 {
            let acts = pressEv.map(\.t)
            var cur = 1.0, lastAct = lo, ci = 0
            let dt = 1 / rate
            for i in 0..<n {
                let t = lo + Double(i) * dt
                while ci < acts.count && acts[ci] <= t { lastAct = acts[ci]; ci += 1 }
                if moving[i] { lastAct = t }
                let target = (t - lastAct) >= idle ? 0.0 : 1.0
                cur += clamp(target - cur, -dt / 0.4, dt / 0.15)
                op[i] = Float(smoothstep(cur))
            }
        }

        // 9. press scale (critically damped)
        var press = [Float](repeating: 1, count: n)
        var px = 1.0, pv = 0.0, down = false, bi = 0
        for i in 0..<n {
            let t = lo + Double(i) / rate
            while bi < pressEv.count && pressEv[bi].t <= t { down = pressEv[bi].kind == .down; bi += 1 }
            springStep(&px, &pv, target: down ? st.pressScale : 1, omega: 38, dt: 1 / rate)
            press[i] = Float(px)
        }

        // shape: custom arrow normally; custom hand from 0.12 s before a press until 0.30 s after release
        let arrowID = StockCursor.arrow.rawValue, handID = StockCursor.pointingHand.rawValue
        let ups = pressEv.filter { $0.kind == .up }
        var windows: [(Double, Double)] = []
        for d in downs.sorted(by: { $0.t < $1.t }) {
            let up = ups.first(where: { $0.t > d.t })?.t ?? (d.t + 0.2)
            windows.append((d.t - 0.12, min(up, d.t + 10) + 0.30))
        }
        var shape = [UInt16](repeating: arrowID, count: n)
        var wi = 0
        for i in 0..<n {
            let t = lo + Double(i) / rate
            while wi < windows.count && windows[wi].1 < t { wi += 1 }
            if wi < windows.count, windows[wi].0 <= t { shape[i] = handID }
        }

        // source time -> output time resample (smoothing ran in source time)
        let m = max(Int(tm.outputDuration * rate) + 1, 2)
        var tr = CursorTrack(count: m)
        for j in 0..<m {
            let s = tm.source(atOutput: Double(j) / rate)
            let f = (s - lo) * rate, i0 = min(max(Int(f), 0), n - 2)
            let fr = Float(clamp(f - Double(i0), 0, 1))
            tr.x[j] = Float(X[i0]) * (1 - fr) + Float(X[i0 + 1]) * fr
            tr.y[j] = Float(Y[i0]) * (1 - fr) + Float(Y[i0 + 1]) * fr
            tr.opacity[j] = op[i0] * (1 - fr) + op[i0 + 1] * fr
            tr.press[j] = press[i0] * (1 - fr) + press[i0 + 1] * fr
            tr.shape[j] = shape[fr < 0.5 ? i0 : i0 + 1]
        }
        let clicks = downs.filter { !tm.isCut($0.t) }.map { ClickFX(t: tm.output(atSource: $0.t), x: $0.x, y: $0.y) }.sorted { $0.t < $1.t }
        return (tr, clicks)
    }

    static func glide(_ X: inout [Double], _ Y: inout [Double], _ a: Int, _ b: Int, _ g: Double) {
        let m = b - a
        var cum = [Double](repeating: 0, count: m)
        for k in 1..<m { cum[k] = cum[k - 1] + hypot(X[a + k] - X[a + k - 1], Y[a + k] - Y[a + k - 1]) }
        let L = cum[m - 1]; guard L > 1 else { return }
        let ox = Array(X[a..<b]), oy = Array(Y[a..<b])
        var p = 0
        for k in 0..<m {
            let tau = Double(k) / Double(m - 1)
            let s = L * (10 * pow(tau, 3) - 15 * pow(tau, 4) + 6 * pow(tau, 5))
            while p < m - 2 && cum[p + 1] < s { p += 1 }
            let seg = cum[p + 1] - cum[p], f = seg > 1e-9 ? (s - cum[p]) / seg : 0
            X[a + k] = lerp(ox[k], ox[p] + (ox[p + 1] - ox[p]) * f, g)
            Y[a + k] = lerp(oy[k], oy[p] + (oy[p + 1] - oy[p]) * f, g)
        }
    }
}
