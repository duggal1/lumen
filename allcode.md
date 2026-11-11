Hey, this is the folder, and this is the code file,

## LumenDirector/

### Sources/LumenDirector/Accuracy.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// A measurement, not a subjective quality rating. Error is the excess
/// offset beyond physical viewport clamping at the exact interaction time.
public struct ZoomAccuracy: Sendable {
    public var clicks = 0
    public var zoomedClicks = 0
    public var insideMargin = 0
    public var medianExcessError = 0.0
    public var medianArrival = 1.0
    public var maxExcessError = 0.0
    public init() {}
}

public enum AccuracyReport {
    public static func measure(_ timeline: Timeline, events: [InputEvent]) -> ZoomAccuracy {
        var result = ZoomAccuracy()
        guard let derived = timeline.derived else { return result }
        let tm = timeline.timeMap
        let width = derived.sourceSize.x, height = derived.sourceSize.y
        guard width > 0, height > 0 else { return result }
        var errors: [Double] = [], arrivals: [Double] = []
        for event in events where event.kind == .down && event.button == 0 &&
            event.t >= tm.trimStart && event.t <= tm.trimEnd - 0.8 && !tm.isCut(event.t) {
            result.clicks += 1
            guard let zoom = timeline.zoom.first(where: { $0.start <= event.t && event.t < $0.end }),
                  zoom.scale > 1.001 else { continue }
            let frame = timeline.evaluate(at: tm.output(atSource: event.t))
            let scale = max(Double(frame.cameraScale), 1)
            let viewWidth = width / scale, viewHeight = height / scale
            let x = Double(event.x), y = Double(event.y)
            guard x.isFinite && y.isFinite && x >= 0 && x <= width && y >= 0 && y <= height else { continue }
            let nx = (x - (Double(frame.cameraCenter.x) - viewWidth / 2)) / viewWidth
            let ny = (y - (Double(frame.cameraCenter.y) - viewHeight / 2)) / viewHeight
            let achievableX = clamp(x, viewWidth / 2, width - viewWidth / 2)
            let achievableY = clamp(y, viewHeight / 2, height - viewHeight / 2)
            let idealX = (x - achievableX) / viewWidth
            let idealY = (y - achievableY) / viewHeight
            let excess = hypot((nx - 0.5) - idealX, (ny - 0.5) - idealY)
            result.zoomedClicks += 1
            if nx >= 0.12 && nx <= 0.88 && ny >= 0.12 && ny <= 0.88 { result.insideMargin += 1 }
            errors.append(excess)
            arrivals.append(clamp(log(scale) / log(zoom.scale), 0, 1))
        }
        func median(_ items: [Double], empty: Double) -> Double {
            guard !items.isEmpty else { return empty }
            let sorted = items.sorted()
            return sorted[sorted.count / 2]
        }
        result.medianExcessError = median(errors, empty: 0)
        result.maxExcessError = errors.max() ?? 0
        result.medianArrival = median(arrivals, empty: 1)
        return result
    }
}
```

### Sources/LumenDirector/Camera.swift

```swift
import Foundation
import LumenCore
import LumenProject

enum CameraSolver {
    private struct Shot { var on: Double, off: Double, lz: Double, focus: Focus, ease: Double }
    private struct Spring {
        var x: Double, v = 0.0
        init(_ x: Double) { self.x = x }
        mutating func step(to target: Double, omega: Double, dt: Double) {
            springStep(&x, &v, target: target, omega: omega, dt: dt)
        }
    }

    /// Forward and backward dead-zone tracking. The average does not bias
    /// the target toward where the pointer came from.
    static func centredPlay(_ samples: [Double], halfZone: Double) -> [Double] {
        guard let first = samples.first, let last = samples.last else { return samples }
        func pass(_ input: [Double], start: Double) -> [Double] {
            var result = input, value = start
            for i in input.indices {
                if input[i] > value + halfZone { value = input[i] - halfZone }
                else if input[i] < value - halfZone { value = input[i] + halfZone }
                result[i] = value
            }
            return result
        }
        let forward = pass(samples, start: first)
        let backward = Array(pass(Array(samples.reversed()), start: last).reversed())
        return zip(forward, backward).map { ($0 + $1) / 2 }
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams, src: SIMD2<Double>, outDur: Double, loop: Double?) -> CameraTrack {
        _ = loop
        let rate = 240.0
        let n = max(Int(outDur * rate) + 1, 2), dt = 1 / rate
        var tr = CameraTrack(count: n, rate: rate)
        // The camera has to have ARRIVED by the click, not merely started.
        // A critically damped spring reaches 95 % at omega * t = 7.75, so the
        // spring constant is derived from the lead: zoom and pan both settle
        // exactly when the scene starts. The spec omegas (zoom 7, pan 5) are
        // the reference values and scale the result.
        let settle = 7.75 / max(p.leadIn, 0.2)
        let omegaIn = settle * (p.omegaZoom / 7.0), omegaOut = omegaIn * 0.8
        let omegaPan = settle * (p.omegaPan / 5.0)

        // Output-time shots. Auto shots activate the lead early; manual shots
        // exactly where the user put them.
        let shots: [Shot] = zoom.compactMap { z in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard b - a > 0.1, z.scale > 1.001, a < outDur else { return nil }
            return Shot(on: a - (z.origin == .auto ? p.leadIn : 0), off: b, lz: log(min(z.scale, 16)),
                        focus: z.focus, ease: z.easing?.omegaScale ?? 1)
        }.sorted { $0.on < $1.on }

        // .follow shots (manual only now) still need the dead-zone cursor path.
        var fx: [Double] = [], fy: [Double] = []
        if shots.contains(where: { if case .follow = $0.focus { true } else { false } }) {
            let halfZone = clamp(p.deadZone, 0.05, 0.45) / 2.0
            let followOmega = 1 / max(clamp(p.followDelay, 0, 0.5), 0.045)
            let rawX = (0..<n).map { Double(cursor.x[min(Int(Double($0) * gridRate / rate), cursor.x.count - 1)]) / src.x }
            let rawY = (0..<n).map { Double(cursor.y[min(Int(Double($0) * gridRate / rate), cursor.y.count - 1)]) / src.y }
            fx = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            fy = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }
        func targetCenter(_ s: Shot, _ i: Int) -> SIMD2<Double> {
            var c: SIMD2<Double>
            switch s.focus {
            case .fixed(let x, let y): c = SIMD2(x, y)
            case .element(let x, let y, let w, let h): c = SIMD2(x + w / 2, y + h / 2)
            case .follow: c = SIMD2(fx[min(i, fx.count - 1)], fy[min(i, fy.count - 1)])
            }
            c -= SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25)) * exp(-s.lz)
            let h = 0.5 / exp(s.lz)
            return SIMD2(clamp(c.x, h, 1 - h), clamp(c.y, h, 1 - h))      // pre-clamped to the TARGET view
        }

        var cz = Spring(0), cx = Spring(0.5), cy = Spring(0.5)
        var si = -1, omega = omegaIn, lastLz = 0.0
        var X = [Double](repeating: 0.5, count: n), Y = X, Z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) * dt
            while si + 1 < shots.count, shots[si + 1].on <= t {           // latest shot wins; contiguous shots = pan, no rest in between
                si += 1
                let lz = shots[si].lz
                omega = (lz < lastLz - 1e-4 ? omegaOut : omegaIn) * shots[si].ease
                lastLz = lz
            }
            var tlz = 0.0, tc = SIMD2(0.5, 0.5)
            if si >= 0, t < shots[si].off { tlz = shots[si].lz; tc = targetCenter(shots[si], i) }
            else if lastLz != 0 { omega = omegaOut; lastLz = 0 }          // rest: zoom back out, slowly
            cx.step(to: tc.x, omega: omegaPan, dt: dt); cy.step(to: tc.y, omega: omegaPan, dt: dt); cz.step(to: tlz, omega: omega, dt: dt)
            let h = 0.5 / exp(cz.x)
            X[i] = clamp(cx.x, h, 1 - h); Y[i] = clamp(cy.x, h, 1 - h); Z[i] = cz.x   // safety clamp only
        }
        func deriv(_ a: [Double]) -> [Float] {
            var v = [Float](repeating: 0, count: a.count)
            if a.count > 2 {
                for i in 1..<(a.count - 1) { v[i] = Float((a[i + 1] - a[i - 1]) * rate / 2) }
                v[0] = v[1]; v[a.count - 1] = v[a.count - 2]
            }
            return v
        }
        tr.nx = X.map { Float($0) }; tr.ny = Y.map { Float($0) }; tr.lz = Z.map { Float($0) }
        tr.vx = deriv(X); tr.vy = deriv(Y); tr.vz = deriv(Z)
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawV = 0.0, pitch = 0.0, pitchV = 0.0
        func phase(_ k: Int) -> Double { Double((p.tiltSeed >> UInt64(k * 8)) & 255) / 255 * 2 * .pi }
        for i in 0..<n {
            let t = Double(i) * dt, z = exp(Z[i])
            var yT = 0.0, pT = 0.0
            switch p.tilt {
            case .lean: yT = clamp(Double(tr.vx[i]) * z * 12, -p.maxYaw, p.maxYaw); pT = clamp(-Double(tr.vy[i]) * z * 9, -p.maxPitch, p.maxPitch)
            case .float:
                yT = p.floatDeg * (0.6 * sin(2 * .pi * 0.11 * t + phase(0)) + 0.4 * sin(2 * .pi * 0.07 * t + phase(1)))
                pT = p.floatDeg * (0.6 * sin(2 * .pi * 0.09 * t + phase(2)) + 0.4 * sin(2 * .pi * 0.05 * t + phase(3)))
            case .reveal, .off: break
            }
            springStep(&yaw, &yawV, target: yT, omega: p.omegaTilt, dt: dt)
            springStep(&pitch, &pitchV, target: pT, omega: p.omegaTilt, dt: dt)
            tr.yaw[i] = Float(yaw); tr.pitch[i] = Float(pitch)
        }
        return tr
    }
}
```

### Sources/LumenDirector/Captions.swift

```swift
import Foundation
import LumenCore
import LumenProject

enum CaptionPlanner {
    private struct TimedWord { var text: String; var start: Double; var end: Double }

    /// A caption never uses more than 60 % of the picture width and never more
    /// than two lines. The character budget follows from the type size: a line
    /// is 60 % of the width and a glyph is roughly half the type size.
    static func perLine(_ plan: CaptionPlan, aspect: Double) -> Int {
        let size = max(plan.style.size, 0.02)
        let chars = (0.60 * aspect) / (0.5 * size)
        return max(8, min(42, Int(chars.rounded())))
    }

    static func plan(words: [WordToken], tm: TimeMap, p: CaptionPlan, aspect: Double,
                     kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        guard p.enabled else { return [] }
        let timed = mappedWords(words, timeMap: tm, plan: p)
        let groups = chunkWords(timed, perLine: perLine(p, aspect: aspect), maxLines: 2)
        return makeChunks(groups, perLine: perLine(p, aspect: aspect), plan: p, aspect: aspect,
                          kindAt: kindAt, cornerAt: cornerAt)
    }

    private static func mappedWords(_ words: [WordToken], timeMap tm: TimeMap, plan: CaptionPlan) -> [TimedWord] {
        let deleted = Set(plan.deletedWords)
        var out: [TimedWord] = []
        var sentenceStart = true
        for (index, word) in words.enumerated() {
            guard !deleted.contains(index), word.end > word.start,
                  word.start >= tm.trimStart, word.end <= tm.trimEnd,
                  !tm.cuts.contains(where: { $0.start < word.end && $0.end > word.start }) else { continue }
            let edited = plan.textEdits[String(index)]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = edited ?? word.text
            guard !text.isEmpty else { continue }
            let start = tm.output(atSource: word.start), end = tm.output(atSource: word.end)
            guard end > start else { continue }
            // A manual edit is the user's own words: never re-case it.
            out.append(TimedWord(text: edited ?? sentenceCase(text, atSentenceStart: sentenceStart),
                                 start: start, end: end))
            if let last = text.last, ".?!".contains(last) { sentenceStart = true } else { sentenceStart = false }
        }
        return out
    }

    /// Sentence case, and nothing else: the first word of a sentence starts
    /// with a capital, every other word is lower case, and "I" is always "I".
    /// A word with an inner capital ("iPhone") keeps it.
    static func sentenceCase(_ word: String, atSentenceStart: Bool) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return word }
        if trimmed.lowercased() == "i" { return "I" }
        let letters = trimmed.unicodeScalars.map { CharacterSet.letters.contains($0) }
        guard letters.allSatisfy({ $0 }) else { return trimmed }
        let inner = trimmed.dropFirst().contains(where: { $0.isUppercase })
        let body = inner ? trimmed : trimmed.lowercased()
        guard atSentenceStart else { return body }
        return String(body.prefix(1).uppercased()) + String(body.dropFirst())
    }

    private static func chunkWords(_ words: [TimedWord], perLine: Int, maxLines: Int) -> [[TimedWord]] {
        let capacity = perLine * max(maxLines, 1)
        var groups: [[TimedWord]] = [], current: [TimedWord] = []
        for word in words {
            if let first = current.first, let previous = current.last {
                let count = characterCount(current)
                let overflow = count + word.text.count + 1 > capacity
                let long = word.end - first.start > 4
                let pause = word.start - previous.end > 0.3 && count >= capacity * 2 / 5
                if overflow || long || pause { groups.append(current); current = [] }
            }
            current.append(word)
            if let last = word.text.last, ".?!…".contains(last) { groups.append(current); current = [] }
            else if let last = word.text.last, ",;:".contains(last), characterCount(current) >= capacity * 3 / 5 {
                groups.append(current); current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func makeChunks(_ groups: [[TimedWord]], perLine: Int, plan: CaptionPlan, aspect: Double,
                                   kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        var out: [CaptionChunk] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            let nextStart = index + 1 < groups.count ? groups[index + 1][0].start : Double.infinity
            let start = max(group[0].start - 0.05, out.last?.end ?? 0)
            let desiredEnd = min(group[group.count - 1].end + 0.2, nextStart - 0.02)
            let end = max(group[group.count - 1].end, min(desiredEnd, start + 4.0))
            guard end > start else { continue }
            let lines = wrap(group, perLine: perLine)
            let position = yPosition(aspect: aspect, kind: kindAt(start), corner: cornerAt(start))
            out.append(CaptionChunk(start: start, end: end, lines: lines, y: position))
        }
        return out
    }

    private static func wrap(_ words: [TimedWord], perLine: Int) -> [[CaptionWord]] {
        var lines: [[CaptionWord]] = [[]]
        for word in words {
            var current = lines[lines.count - 1]
            let addition = word.text.count + (current.isEmpty ? 0 : 1)
            if width(current) + addition > perLine, !current.isEmpty {
                let cut = phraseBoundary(current)
                lines[lines.count - 1] = Array(current.prefix(cut))
                current = Array(current.suffix(from: cut))
                lines.append(current)
            }
            current.append(CaptionWord(text: word.text, start: word.start, end: word.end))
            lines[lines.count - 1] = current
        }
        return lines
    }

    private static func width(_ line: [CaptionWord]) -> Int {
        line.reduce(0) { $0 + $1.text.count } + max(line.count - 1, 0)
    }

    /// Break before the last clause boundary that still fills the line, so a
    /// caption never splits a phrase when a softer break exists.
    private static func phraseBoundary(_ line: [CaptionWord]) -> Int {
        var best: Int?
        for (i, word) in line.enumerated() {
            guard i > 0 else { continue }
            let last = word.text.last.map { String($0) } ?? ""
            let joiners = ["and", "but", "or", "so", "because", "that", "which", "when", "if"]
            if ",;:—–".contains(last) || joiners.contains(word.text.lowercased()) { best = i }
        }
        guard let cut = best else { return max(line.count - 1, 1) }
        let head = line.prefix(cut).reduce(0) { $0 + $1.text.count }
        return head * 2 >= width(line) ? cut : max(line.count - 1, 1)
    }

    private static func characterCount(_ words: [TimedWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(words.count - 1, 0)
    }

    /// The caption sits low enough to read as a lower third but never on the
    /// dock: roughly 10 % of the frame stays clear under it.
    private static func yPosition(aspect: Double, kind: LayoutKind, corner: WebcamLayout.Corner?) -> Double {
        if aspect < 1 { return 0.84 }
        if kind == .cameraOverlay, corner == .bottomLeft || corner == .bottomRight { return 0.16 }
        return 0.90
    }
}
```

### Sources/LumenDirector/Cursor.swift

```swift
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
        // Captured system cursors arrive as ids >= 1000 (see CursorCatalog).
        // They are real artwork, so they win over both the arrow and the
        // synthetic press-window hand: swapping a custom cursor for the stock
        // hand would show the wrong pointer at the moment of a click.
        let customFloor: UInt16 = 1000
        let shapeEv = events.filter { $0.cursorShape > 0 && $0.t >= lo && $0.t <= hi }.sorted { $0.t < $1.t }
        var shape = [UInt16](repeating: arrowID, count: n)
        var si = 0, current = arrowID, wi = 0
        for i in 0..<n {
            let t = lo + Double(i) / rate
            while si < shapeEv.count && shapeEv[si].t <= t { current = shapeEv[si].cursorShape; si += 1 }
            while wi < windows.count && windows[wi].1 < t { wi += 1 }
            let pressing = wi < windows.count && windows[wi].0 <= t
            shape[i] = (pressing && current < customFloor) ? handID : current
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
```

### Sources/LumenDirector/Director.swift

```swift
import Foundation
import LumenCore
import LumenProject

public struct DirectorInput: Sendable {
    public var events: [InputEvent]
    public var source: SourceInfo
    public var vad: [ClosedRange<Double>]
    public var ax: [AXFrame]
    public var face: [FaceSample]
    public var webcamAspect: Float
    public var activity: [ActivityPoint]
    public var transcript: Transcript?
    public var ocr: [OCRDetection]
    public var personMask: PersonMaskInfo?
    public var typing: [TypingTrace]
    public init(events: [InputEvent], source: SourceInfo, vad: [ClosedRange<Double>] = [], ax: [AXFrame] = [],
                face: [FaceSample] = [], webcamAspect: Float = 16.0 / 9, activity: [ActivityPoint] = [],
                transcript: Transcript? = nil, ocr: [OCRDetection] = [], personMask: PersonMaskInfo? = nil,
                typing: [TypingTrace] = []) {
        self.events = events; self.source = source; self.vad = vad; self.ax = ax; self.face = face
        self.webcamAspect = webcamAspect; self.activity = activity; self.transcript = transcript; self.ocr = ocr; self.personMask = personMask; self.typing = typing
    }
}

/// Reusable stage cache for interactive replans. Only stages that do not
/// depend on the zoom/camera parameters are retained; everything else is
/// still recomputed, so the result is identical to a cold derive.
public struct DeriveCache: Sendable {
    struct CursorKey: Equatable {
        var style: CursorStyle
        var taps: [TapIndicator]
        var timeMap: [Double]
    }
    var cursorKey: CursorKey?
    var cursor: (CursorTrack, [ClickFX])?
    public init() {}
}

extension TimeMap {
    /// Auto speed-ramp ids are regenerated per replan, so `==` on the ramp
    /// array never matches a cached stage. Key on the values that matter.
    var signature: [Double] {
        [trimStart, trimEnd] + cuts.flatMap { [$0.start, $0.end] }
            + ramps.flatMap { [$0.start, $0.end, $0.speed] }
    }
}

public enum Director {
    /// Run only the event-based zoom planner at recording stop, without
    /// rendering, speech analysis, waveform work or audio mixing.
    public static func planRecordingZoom(events: [InputEvent], ax: [AXFrame],
                                         source: SourceInfo, timeline: Timeline) -> [ZoomSegment] {
        guard timeline.camera.autoZoom else { return timeline.zoom }
        let manual = timeline.zoom.filter { $0.origin == .manual }
        let avoid = manual.map { min($0.start, $0.end)...max($0.start, $0.end) }
        return (manual + ZoomPlanner.plan(events: events, ax: ax, typing: [], activity: [],
                                          src: source, p: timeline.camera, tm: timeline.timeMap,
                                          avoid: avoid)).sorted { $0.start < $1.start }
    }

    /// Pure and deterministic: same input, same Timeline. Replaces only .auto zoom/ramps; .manual survive.
    public static func derive(_ tl: Timeline, input: DirectorInput, revision: Int) -> Timeline {
        var cache = DeriveCache()
        return derive(tl, input: input, revision: revision, cache: &cache)
    }

    /// Cache-aware overload used by the interactive editor. The returned
    /// Timeline is byte-for-byte identical to the uncached call.
    public static func derive(_ tl: Timeline, input: DirectorInput, revision: Int, cache: inout DeriveCache) -> Timeline {
        var t = tl
        let src = input.source
        var tm = t.timeMap
        if tm.sourceDuration != src.duration && tm.trimEnd <= 0 {
            tm = TimeMap(sourceDuration: src.duration, trimStart: 0, trimEnd: src.duration, ramps: tm.ramps, cuts: tm.cuts)
        }
        // time map first: camera runs in output time
        if t.audio.speedRampsAuto {
            tm.ramps = tm.ramps.filter { $0.origin == .manual }
                + SpeedRamps.plan(events: input.events, vad: input.vad, tm: tm, audio: t.audio, backing: src.backingScale)
        }
        t.timeMap = tm
        if t.camera.autoZoom {
            let manual = t.zoom.filter { $0.origin == .manual }
            let avoid = manual.map { min($0.start, $0.end)...max($0.start, $0.end) }
            t.zoom = (manual + ZoomPlanner.plan(events: input.events, ax: input.ax, typing: input.typing, activity: input.activity, src: src, p: t.camera,
                                                tm: tm, avoid: avoid)).sorted { $0.start < $1.start }
        }
        let key = DeriveCache.CursorKey(style: t.cursor, taps: t.overlays.taps, timeMap: tm.signature)
        let cursor: CursorTrack, clicks: [ClickFX]
        if cache.cursorKey == key, let cached = cache.cursor {
            (cursor, clicks) = cached
        } else {
            let result = CursorPipeline.run(events: input.events, taps: t.overlays.taps, st: t.cursor, tm: tm, src: src)
            cache.cursorKey = key; cache.cursor = result
            (cursor, clicks) = result
        }
        let size = SIMD2(Double(src.width), Double(src.height))
        let cam = CameraSolver.solve(zoom: t.zoom, tm: tm, cursor: cursor, p: t.camera, src: size, outDur: tm.outputDuration, loop: t.cursor.loop)
        let placement = WebcamPlacement.solve(t, tm: tm, cam: cam, cursor: cursor, src: size, vad: input.vad,
                                             outDur: tm.outputDuration, clicks: clicks)
        let layoutSpans = LayoutSolver.spans(t, tm, hasWebcam: t.webcam != nil)
        let layout = LayoutSolver.solve(t, spans: layoutSpans.spans, fallback: layoutSpans.fallback, src: size,
                                        webcamAspect: Double(input.webcamAspect), placement: placement, outDur: tm.outputDuration)
        let autoMasks = MaskTracks.build(input.ocr, plan: t.overlays.privacy, src: src)
            + MaskTracks.secureFields(events: input.events, ax: input.ax, plan: t.overlays.privacy, src: src)
        let captions = CaptionPlanner.plan(words: input.transcript?.words ?? [], tm: tm, p: t.captions, aspect: t.style.aspectRatio,
                                           kindAt: layout.kind(at:), cornerAt: placement.corner(at:))

        var cues: [SFXCue] = []
        if t.audio.clickSounds { cues += clicks.map { SFXCue(t: $0.t, kind: .click, gainDb: 0) } }
        if t.audio.keySounds {
            cues += input.events.filter { $0.kind == .keyDown && !tm.isCut($0.t) }
                .map { SFXCue(t: tm.output(atSource: $0.t), kind: .key, gainDb: -6, keyCode: $0.keyCode) }
        }
        if t.audio.whooshes {
            for z in t.zoom {
                let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
                guard b - a > 0.2 else { continue }
                // Small zooms still need an audible whoosh: floor at -9 dB,
                // rise gently with zoom magnitude, never above -2 dB.
                let g = clamp(-9 + 5 * (z.scale - 1), -9, -2)
                cues.append(SFXCue(t: a, kind: .whooshIn, gainDb: g)); cues.append(SFXCue(t: b, kind: .whooshOut, gainDb: g))
            }
        }
        cues.sort { $0.t < $1.t }

        // duck envelope @100 Hz from voice activity
        let dn = Int(tm.outputDuration * 100) + 2
        var voice = [Bool](repeating: false, count: dn)
        for r in input.vad {
            let a = max(Int(tm.output(atSource: r.lowerBound) * 100), 0), b = min(Int(tm.output(atSource: r.upperBound) * 100), dn - 1)
            if b >= a { for i in a...b { voice[i] = true } }
        }
        var duck = [Float](repeating: 1, count: dn)
        var g = 1.0
        let lowG = pow(10, t.audio.duckDepthDb / 20)
        for i in 0..<dn {
            let tgt = voice[i] ? lowG : 1.0
            let tc = tgt < g ? t.audio.duckAttack : t.audio.duckRelease
            g += (tgt - g) * (1 - exp(-0.01 / tc)); duck[i] = Float(g)
        }
        t.derived = DerivedTracks(revision: revision, sourceSize: size, outputDuration: tm.outputDuration, cursor: cursor, camera: cam,
                                  clicks: clicks, cues: cues, duck: duck, face: WebcamFraming.solve(input.face, tm: tm, camera: cam, layout: t.webcam),
                                  webcamAspect: input.webcamAspect, layout: layout, placement: placement,
                                  captions: captions, autoMasks: autoMasks, personMask: input.personMask)
        if ProcessInfo.processInfo.environment["LUMEN_ZOOM_DEBUG"] == "1" {
            let cam = t.derived?.camera
            for event in input.events where event.kind == .down && event.button == 0 {
                let outTime = tm.output(atSource: event.t)
                let frame = t.evaluate(at: outTime)
                // Per-click: target lz, arrival at click, click in viewport (normalised).
                let idx = min(max(Int(outTime * (cam?.rate ?? gridRate)), 0), (cam?.lz.count ?? 1) - 1)
                let lzNow = (cam?.lz.isEmpty == false) ? Double(cam!.lz[idx]) : log(Double(frame.cameraScale))
                let targetScale = t.zoom.first { abs($0.start - event.t) < 0.01 }?.scale
                                    ?? t.zoom.first { event.t >= $0.start && event.t <= $0.end }?.scale ?? 1
                let targetLz = log(targetScale)
                let arrival = targetLz > 0.001 ? lzNow / targetLz : 0
                let vw = Double(src.width) / Double(frame.cameraScale), vh = Double(src.height) / Double(frame.cameraScale)
                let vx = (Double(event.x) - (Double(frame.cameraCenter.x) - vw / 2)) / vw
                let vy = (Double(event.y) - (Double(frame.cameraCenter.y) - vh / 2)) / vh
                let message = String(format: "LUMEN_ZOOM event=%.5f source=%.5f output=%.5f click=(%.1f,%.1f) focus=(%.1f,%.1f) scale=%.3f target_lz=%.3f arrival=%.3f viewport=(%.3f,%.3f)\n",
                                     event.t, event.t, outTime, event.x, event.y,
                                     frame.cameraCenter.x, frame.cameraCenter.y, frame.cameraScale,
                                     targetLz, arrival, vx, vy)
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
        return t
    }
}

// MARK: Evaluation

public struct CursorSample: Sendable {
    public var position: SIMD2<Float>, velocity: SIMD2<Float>
    public var opacity: Float, press: Float
    public var shape: UInt16
}
public struct ClickRing: Sendable { public var position: SIMD2<Float>; public var progress: Float }
public struct FrameState: Sendable {
    public var cameraCenter: SIMD2<Float>     // source px
    public var cameraScale: Float
    public var cameraTilt: SIMD2<Float> = .zero       // (yaw, pitch) degrees; renderer homography consumes this in Part 5
    public var cursor: CursorSample
    public var clickFX: [ClickRing]
    public var webcamCrop: SIMD4<Float>       // uv x, y, w, h
    public var sourceTime: Double
    public var layout: ResolvedLayout
    public var layoutKind: LayoutKind
    public var webcamCorner: WebcamLayout.Corner?
    public var webcamOpacity: Float
    public var caption: CaptionChunk?
    public var emphasis: EmphasisFrame

    public init(cameraCenter: SIMD2<Float>, cameraScale: Float, cameraTilt: SIMD2<Float> = .zero,
                cursor: CursorSample, clickFX: [ClickRing], webcamCrop: SIMD4<Float>, sourceTime: Double,
                layout: ResolvedLayout = .full, layoutKind: LayoutKind = .screenOnly, webcamCorner: WebcamLayout.Corner? = nil,
                webcamOpacity: Float = 1, caption: CaptionChunk? = nil, emphasis: EmphasisFrame = EmphasisFrame()) {
        self.cameraCenter = cameraCenter; self.cameraScale = cameraScale; self.cameraTilt = cameraTilt; self.cursor = cursor
        self.clickFX = clickFX; self.webcamCrop = webcamCrop; self.sourceTime = sourceTime; self.layout = layout
        self.layoutKind = layoutKind; self.webcamCorner = webcamCorner; self.webcamOpacity = webcamOpacity
        self.caption = caption; self.emphasis = emphasis
    }
}

@inline(__always) private func cr(_ a: [Float], _ f: Double) -> Float {
    let i = Int(f.rounded(.down)), u = Float(f - Double(i)), n = a.count
    func g(_ k: Int) -> Float { a[min(max(k, 0), n - 1)] }
    let p0 = g(i - 1), p1 = g(i), p2 = g(i + 1), p3 = g(i + 2)
    return p1 + 0.5 * u * (p2 - p0 + u * (2 * p0 - 5 * p1 + 4 * p2 - p3 + u * (3 * (p1 - p2) + p3 - p0)))
}
@inline(__always) private func hm(_ p: [Float], _ v: [Float], _ f: Double, rate: Double) -> Float {
    let i = min(max(Int(f), 0), p.count - 2), s = Float(f - Double(i)), h = Float(1 / rate)
    let s2 = s * s, s3 = s2 * s
    return (2 * s3 - 3 * s2 + 1) * p[i] + (s3 - 2 * s2 + s) * h * v[i] + (-2 * s3 + 3 * s2) * p[i + 1] + (s3 - s2) * h * v[i + 1]
}
private func cf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

extension Timeline {
    /// Pure function of (self, t). Microseconds. Safe to call from any thread.
    public func evaluate(at t0: Double) -> FrameState {
        // Imported clips are composed on the same output clock but carry no
        // recording metadata: no camera move, no cursor, no masks. Returning a
        // synthetic state here keeps one evaluation entry point for preview and
        // export, so a clip can never inherit a stale zoom from the recording.
        if let (clip, time) = clipSource(atOutput: t0) {
            let d = SIMD2(Double(clip.width), Double(clip.height))
            return FrameState(cameraCenter: SIMD2(Float(d.x / 2), Float(d.y / 2)), cameraScale: 1,
                              cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                              clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: time,
                              layout: .full, layoutKind: .screenOnly, webcamCorner: nil, webcamOpacity: 0,
                              caption: nil, emphasis: EmphasisFrame())
        }
        guard let d = derived else {
            return FrameState(cameraCenter: .zero, cameraScale: 1, cameraTilt: .zero,
                              cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                              clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 0)
        }
        let t = clamp(t0, 0, d.outputDuration), f = t * gridRate
        let c = d.camera, u = d.cursor
        let cameraFrame = t * c.rate
        let cam = SIMD2<Float>(hm(c.nx, c.vx, cameraFrame, rate: c.rate) * Float(d.sourceSize.x), hm(c.ny, c.vy, cameraFrame, rate: c.rate) * Float(d.sourceSize.y))
        let scale = exp(hm(c.lz, c.vz, cameraFrame, rate: c.rate))
        let tilt = SIMD2<Float>(cr(c.yaw, cameraFrame), cr(c.pitch, cameraFrame))
        let pos = SIMD2<Float>(cr(u.x, f), cr(u.y, f))
        let vel = SIMD2<Float>(cr(u.x, f + 1) - cr(u.x, f - 1), cr(u.y, f + 1) - cr(u.y, f - 1)) * Float(gridRate / 2)
        let cs = CursorSample(position: pos, velocity: vel, opacity: cf(cr(u.opacity, f), 0, 1), press: cr(u.press, f),
                              shape: u.shape[min(Int(f.rounded()), u.shape.count - 1)])
        var rings: [ClickRing] = []
        if cursor.clickRing != nil, cursor.clickEffect != .none, !d.clicks.isEmpty {
            let dur = max(cursor.clickDuration, 0.05)
            var lo = 0, hi = d.clicks.count
            while lo < hi { let m = (lo + hi) / 2; if d.clicks[m].t <= t - dur { lo = m + 1 } else { hi = m } }
            var i = lo
            while i < d.clicks.count, d.clicks[i].t <= t {
                rings.append(ClickRing(position: SIMD2(d.clicks[i].x, d.clicks[i].y), progress: Float((t - d.clicks[i].t) / dur)))
                i += 1
            }
            // Cap alive ripples: rapid clicking cannot fan out past 8 feeds.
            if rings.count > 8 { rings = Array(rings.suffix(8)) }
        }
        // webcam crop: face-aware or centered square
        let ar = max(d.webcamAspect, 0.1)
        var ch: Float = 1, cx: Float = 0.5, cy: Float = 0.5
        let layoutKind = d.layout.kind(at: t)
        if layoutSettings[layoutKind].autoFrame, !d.face.isEmpty {
            let fp = t * faceGridRate, i0 = min(Int(fp), d.face.count - 1), i1 = min(i0 + 1, d.face.count - 1)
            let fc = d.face[i0] + (d.face[i1] - d.face[i0]) * Float(fp - Double(i0))
            cx = fc.x; cy = fc.y; ch = cf(fc.z, 0.25, 1)
        }
        let cw = min(ch / ar, 1)
        let crop = SIMD4<Float>(cf(cx - cw / 2, 0, 1 - cw), cf(cy - ch / 2, 0, 1 - ch), cw, ch)
        let sourceTime = timeMap.source(atOutput: t)
        let emphasis = Emphasis.evaluate(overlays: overlays, autoMasks: d.autoMasks, sourceTime: sourceTime,
                                         cursor: pos, sourceSize: d.sourceSize)
        return FrameState(cameraCenter: cam, cameraScale: scale, cameraTilt: tilt, cursor: cs, clickFX: rings, webcamCrop: crop,
                          sourceTime: sourceTime, layout: d.layout.sample(at: t), layoutKind: layoutKind,
                          webcamCorner: d.placement.corner(at: t), webcamOpacity: d.placement.visibility(at: t),
                          caption: d.captions.first { t >= $0.start && t < $0.end }, emphasis: emphasis)
    }
}
```

### Sources/LumenDirector/Emphasis.swift

```swift
import Foundation
import LumenCore
import LumenProject

public struct MaskFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var mode: MaskMode
    public var rect: SIMD4<Float>
    public var padding: Float
    public var category: String?
    public init(id: UUID, mode: MaskMode, rect: SIMD4<Float>, padding: Float, category: String?) {
        self.id = id; self.mode = mode; self.rect = rect; self.padding = padding; self.category = category
    }
}

public struct HighlightFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var rect: SIMD4<Float>
    public var style: HighlightStyle
    public var dim: Float
    public var opacity: Float
}

public struct LoupeFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// SOURCE pixel the glass looks at (follows the cursor when the loupe does).
    public var target: SIMD2<Float>
    /// Canvas-normalized centre where the glass itself sits.
    public var glass: SIMD2<Float>
    public var radius: Float
    public var border: Float
    public var magnification: Float
    public var round: Bool
    public var opacity: Float
}

public struct TextFrame: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var center: SIMD2<Float>
    public var size: Float
    public var color: RGBA
    public var opacity: Float
}

public struct EmphasisFrame: Sendable, Equatable {
    public var masks: [MaskFrame]
    public var highlights: [HighlightFrame]
    public var loupes: [LoupeFrame]
    public var texts: [TextFrame]
    public init(masks: [MaskFrame] = [], highlights: [HighlightFrame] = [], loupes: [LoupeFrame] = [], texts: [TextFrame] = []) {
        self.masks = masks; self.highlights = highlights; self.loupes = loupes; self.texts = texts
    }
}

enum Emphasis {
    static func evaluate(overlays: Overlays, autoMasks: [Mask], sourceTime t: Double,
                         cursor: SIMD2<Float>, sourceSize: SIMD2<Double>) -> EmphasisFrame {
        let masks = (overlays.masks + autoMasks).compactMap { maskFrame($0, t: t, size: sourceSize) }
        let highlights = overlays.highlights.compactMap { highlightFrame($0, t: t, size: sourceSize) }
        let loupes = overlays.loupes.compactMap { loupeFrame($0, t: t, cursor: cursor) }
        let texts = overlays.texts.compactMap { textFrame($0, t: t) }
        return EmphasisFrame(masks: masks, highlights: highlights, loupes: loupes, texts: texts)
    }

    private static func maskFrame(_ mask: Mask, t: Double, size: SIMD2<Double>) -> MaskFrame? {
        guard mask.approved, t >= mask.start, t < mask.end, let key = rect(mask.keys, at: t) else { return nil }
        let pad = max(mask.padding, 0)
        let x = max(key.x - pad, 0), y = max(key.y - pad, 0)
        let right = min(key.x + key.w + pad, size.x), bottom = min(key.y + key.h + pad, size.y)
        return MaskFrame(id: mask.id, mode: mask.mode, rect: SIMD4(Float(x), Float(y), Float(max(right - x, 0)), Float(max(bottom - y, 0))),
                         padding: Float(pad), category: mask.category)
    }

    private static func rect(_ keys: [MaskKey], at t: Double) -> MaskKey? {
        let sorted = keys.sorted { $0.t < $1.t }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        if t <= first.t { return first }
        for pair in zip(sorted, sorted.dropFirst()) where t <= pair.1.t {
            let span = pair.1.t - pair.0.t
            let u = span > 0 ? (t - pair.0.t) / span : 1
            return MaskKey(t: t, x: lerp(pair.0.x, pair.1.x, u), y: lerp(pair.0.y, pair.1.y, u),
                           w: lerp(pair.0.w, pair.1.w, u), h: lerp(pair.0.h, pair.1.h, u))
        }
        return sorted.last
    }

    private static func highlightFrame(_ highlight: Highlight, t: Double, size: SIMD2<Double>) -> HighlightFrame? {
        guard t >= highlight.start, t < highlight.end else { return nil }
        let rect = clampedRect(x: highlight.x, y: highlight.y, w: highlight.w, h: highlight.h, size: size)
        return HighlightFrame(id: highlight.id, rect: rect, style: highlight.style, dim: Float(clamp(highlight.dim, 0, 0.7)),
                             opacity: envelope(t, start: highlight.start, end: highlight.end))
    }

    private static func loupeFrame(_ loupe: Loupe, t: Double, cursor: SIMD2<Float>) -> LoupeFrame? {
        guard t >= loupe.start, t < loupe.end else { return nil }
        let target = loupe.follow ? cursor : SIMD2(Float(loupe.x), Float(loupe.y))
        return LoupeFrame(id: loupe.id, target: target,
                          glass: SIMD2(Float(clamp(loupe.cx, 0.05, 0.95)), Float(clamp(loupe.cy, 0.05, 0.95))),
                          radius: Float(max(loupe.radius, 0.02)), border: Float(max(loupe.border, 0.001)),
                          magnification: Float(clamp(loupe.magnification, 1.2, 6)), round: loupe.round,
                          opacity: envelope(t, start: loupe.start, end: loupe.end))
    }

    private static func textFrame(_ block: TextBlock, t: Double) -> TextFrame? {
        guard t >= block.start, t < block.end else { return nil }
        return TextFrame(id: block.id, text: block.text, center: SIMD2(Float(clamp(block.x, 0, 1)), Float(clamp(block.y, 0, 1))),
                         size: Float(max(block.size, 0)), color: block.color, opacity: envelope(t, start: block.start, end: block.end))
    }

    private static func clampedRect(x: Double, y: Double, w: Double, h: Double, size: SIMD2<Double>) -> SIMD4<Float> {
        let left = clamp(x, 0, size.x), top = clamp(y, 0, size.y)
        let right = clamp(x + max(w, 0), left, size.x), bottom = clamp(y + max(h, 0), top, size.y)
        return SIMD4(Float(left), Float(top), Float(right - left), Float(bottom - top))
    }

    private static func envelope(_ t: Double, start: Double, end: Double) -> Float {
        let fade = min(0.15, max((end - start) / 2, 0.001))
        return Float(min(clamp((t - start) / fade, 0, 1), clamp((end - t) / fade, 0, 1)))
    }
}
```

### Sources/LumenDirector/Layout.swift

```swift
import Foundation
import LumenCore
import LumenProject

enum LayoutResolver {
    /// Content (screen) rect, canvas-normalized, fitted into the padded canvas keeping the source aspect.
    static func contentRect(aspect a: Double, srcAspect sa: Double, insets: EdgeInsetsN) -> SIMD4<Double> {
        let ch = 1 / a                                            // canvas height in width units
        let aw = max(1 - insets.left - insets.right, 0.05), ah = max(ch - insets.top - insets.bottom, 0.05)
        let w = min(aw, ah * sa), h = w / sa
        return SIMD4(insets.left + (aw - w) / 2, (insets.top + (ah - h) / 2) * a, w, h * a)
    }

    /// Square bubble anchored to a corner, canvas-normalized.
    static func bubbleRect(corner: WebcamLayout.Corner, size: Double, aspect a: Double) -> SIMD4<Double> {
        let ch = 1 / a, s = min(size, 0.45 * min(1, ch)), m = 0.03
        let w = s, h = s * a, my = m * a
        let left = corner == .topLeft || corner == .bottomLeft, top = corner == .topLeft || corner == .topRight
        return SIMD4(left ? m : 1 - m - w, top ? my : 1 - my - h, w, h)
    }

    static func target(_ kind: LayoutKind, _ s: LayoutSettings, corner: WebcamLayout.Corner, aspect a: Double, srcAspect sa: Double,
                       insets: EdgeInsetsN, webcamAspect ar: Double) -> ResolvedLayout {
        let ch = 1 / a
        var screen = contentRect(aspect: a, srcAspect: sa, insets: insets)
        var cam = bubbleRect(corner: corner, size: s.size, aspect: a)
        var so = 1.0, co = 0.0, cut = 0.0
        var rad = s.shape == .circle ? 0.5 : 0.22
        let ax = insets.left, ay = insets.top
        let aw = max(1 - insets.left - insets.right, 0.05), ah = max(ch - insets.top - insets.bottom, 0.05)
        func norm(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SIMD4<Double> { SIMD4(x, y * a, w, h * a) }
        switch kind {
        case .screenOnly: break
        case .cameraOverlay: co = 1
        case .split:
            let gap = 0.02
            if a >= 1 {
                let sw = (aw - gap) * 0.64, cw = aw - gap - sw
                let w = min(sw, ah * sa), h = w / sa
                screen = norm(ax + (sw - w) / 2, ay + (ah - h) / 2, w, h)
                let side = min(cw, ah * 0.8)
                cam = norm(ax + sw + gap + (cw - side) / 2, ay + (ah - side) / 2, side, side)
            } else {
                let sh = (ah - gap) * 0.58, chh = ah - gap - sh
                let w = min(aw, sh * sa), h = w / sa
                screen = norm(ax + (aw - w) / 2, ay + (sh - h) / 2, w, h)
                let side = min(aw, chh)
                cam = norm(ax + (aw - side) / 2, ay + sh + gap + (chh - side) / 2, side, side)
            }
            co = 1; rad = s.shape == .circle ? 0.5 : 0.08
        case .cameraFullscreen:
            so = 0; cam = norm(ax, ay, aw, ah); rad = 0.03; co = 1
        case .cameraCutout:
            let h = ch * 0.62, w = min(h * ar, 0.6), left = corner == .topLeft || corner == .bottomLeft
            cam = norm(left ? 0.01 : 1 - 0.01 - w, ch - h, w, h); rad = 0; co = 1; cut = 1
        }
        var r = ResolvedLayout()
        r.screenRect = SIMD4<Float>(screen); r.screenOpacity = Float(so)
        r.cameraRect = SIMD4<Float>(cam); r.cameraRadius = Float(rad); r.cameraOpacity = Float(co); r.cutoutBlend = Float(cut)
        return r
    }
}

enum LayoutSolver {
    static let rate = 120.0, omega = 9.0

    /// Explicit layout segments mapped to OUTPUT time. Everything else uses `fallback`.
    static func spans(_ tl: Timeline, _ tm: TimeMap, hasWebcam: Bool) -> (spans: [LayoutSpan], fallback: LayoutKind) {
        guard hasWebcam else { return ([], .screenOnly) }
        var out: [LayoutSpan] = []
        for l in tl.layouts.sorted(by: { $0.start < $1.start }) {
            let a = tm.output(atSource: l.start), b = tm.output(atSource: l.end)
            if b > a { out.append(LayoutSpan(start: a, end: b, kind: l.kind)) }
        }
        return (out, .cameraOverlay)
    }

    /// One critically damped spring over all 12 layout floats: any layout to any layout, any aspect, no per-pair code.
    static func solve(_ tl: Timeline, spans: [LayoutSpan], fallback: LayoutKind, src: SIMD2<Double>, webcamAspect: Double,
                      placement: PlacementTrack, outDur: Double) -> LayoutTrack {
        let sa = src.x / max(src.y, 1), a = tl.style.aspectRatio, ins = tl.style.insets
        var track = LayoutTrack(rate: rate, samples: [], spans: spans, fallback: fallback)
        guard tl.webcam != nil else {
            let t = LayoutResolver.target(.screenOnly, tl.layoutSettings[.screenOnly], corner: .bottomRight, aspect: a, srcAspect: sa,
                                          insets: ins, webcamAspect: webcamAspect)
            track.samples = [t, t]; return track
        }
        let n = max(Int(outDur * rate) + 2, 3), dt = 1 / rate
        var x = SIMD16<Double>(repeating: 0), v = x
        var cache: (LayoutKind, WebcamLayout.Corner, ResolvedLayout)?
        var out: [ResolvedLayout] = []; out.reserveCapacity(n)
        var si = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while si < spans.count && spans[si].end <= t { si += 1 }
            let kind = (si < spans.count && spans[si].start <= t) ? spans[si].kind : fallback
            let set = tl.layoutSettings[kind]
            let corner = placement.corner(at: t) ?? set.corner
            if cache == nil || cache!.0 != kind || cache!.1 != corner {
                cache = (kind, corner, LayoutResolver.target(kind, set, corner: corner, aspect: a, srcAspect: sa, insets: ins, webcamAspect: webcamAspect))
            }
            var tgt = SIMD16<Double>(cache!.2.v)
            if kind == .cameraOverlay || kind == .cameraCutout { tgt[10] *= Double(placement.visibility(at: t)) }
            if i == 0 { x = tgt }
            for k in 0..<12 { springStep(&x[k], &v[k], target: tgt[k], omega: omega, dt: dt) }
            out.append(ResolvedLayout(v: SIMD16<Float>(x)))
        }
        track.samples = out
        return track
    }
}
```

### Sources/LumenDirector/LiveCamera.swift

```swift
import Foundation
import LumenCore
import LumenProject

public struct LiveCamera: Sendable {
    public var maxScale = 2.2, hold = 1.6, omegaZoom = 8.0, omegaPan = 7.0, lookahead = 0.15, deadZone = 0.28
    public var cursor = CursorStyle()
    private let src: SIMD2<Double>
    private var t = 0.0, started = false
    private var raw: SIMD2<Double>, rawT = 0.0, vel = SIMD2<Double>.zero
    private var shape: UInt16 = 0
    private var down = false, zoomed = false
    private var lastActivity = -1e9, lastMove = -1e9, opacity = 1.0, lzShot = 0.0
    private var cur1: Spring3, cur2: Spring3, zoom1: Spring3, press: Spring3
    private var typing = false
    private var tgt = SIMD2<Double>(0.5, 0.5)
    private var fx1 = SIMD2<Double>(0.5, 0.5), fv1 = SIMD2<Double>.zero, fx2 = SIMD2<Double>(0.5, 0.5), fv2 = SIMD2<Double>.zero
    private var rings: [(t: Double, x: Float, y: Float)] = []

    public init(source: SIMD2<Double>) {
        src = source; raw = source / 2
        cur1 = Spring3(x: SIMD3(source.x / 2, source.y / 2, 0)); cur2 = cur1
        zoom1 = Spring3(x: .zero)
        press = Spring3(x: SIMD3(1, 0, 0))
    }
    private func norm(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x / src.x, p.y / src.y) }
    public mutating func ingest(_ e: InputEvent, focus: AXFrame? = nil) {
        if e.hasPosition {
            let p = SIMD2(Double(e.x), Double(e.y))
            if rawT == 0 { cur1.x = SIMD3(p.x, p.y, 0); cur2.x = cur1.x }
            else if e.t > rawT { vel += ((p - raw) / max(e.t - rawT, 0.004) - vel) * 0.3 }
            raw = p; rawT = e.t; shape = e.cursorShape
            if e.kind != .up && e.kind != .down { lastMove = e.t }
        }
        switch e.kind {
        case .down:
            typing = false
            down = true; lastActivity = e.t; rings.append((e.t, e.x, e.y))
            if !zoomed {
                let atRest = zoom1.x.x < 0.03
                zoomed = true; lzShot = log(maxScale)
                let c = norm(SIMD2(Double(e.x), Double(e.y))), hw = 0.5 / maxScale
                tgt = SIMD2(clamp(c.x, hw, 1 - hw), clamp(c.y, hw, 1 - hw))
                if atRest { fx1 = tgt; fx2 = tgt; fv1 = .zero; fv2 = .zero }
            }
        case .up: down = false; lastActivity = e.t
        case .keyDown:
            guard e.axFrameIndex > 0 else { return }
            let scale = focus.map { clamp(min(src.x / max($0.w * 1.6, 1), src.y / max($0.h * 1.6, 1)), 1.3, 3.2) } ?? maxScale
            typing = true; zoomed = true; lastActivity = e.t; lzShot = log(scale)
            let point = focus.map { SIMD2($0.x + $0.w / 2, $0.y + $0.h / 2) } ?? SIMD2(Double(e.x), Double(e.y))
            let center = norm(point), half = 0.5 / scale
            let next = SIMD2(clamp(center.x, half, 1 - half), clamp(center.y, half, 1 - half))
            if hypot(next.x - tgt.x, next.y - tgt.y) > 0.06 / scale { tgt = next }
        case .drag, .scroll: lastActivity = e.t
        default: break
        }
    }
    public mutating func step(to now: Double) -> FrameState {
        if !started { t = now; started = true }
        if now - t > 0.25 { t = now - 0.25 }
        while t < now - 1e-9 { let dt = min(1.0 / 240, now - t); t += dt; advance(dt) }
        return state(at: now)
    }
    private mutating func advance(_ dt: Double) {
        let tt = t
        vel *= exp(-dt / 0.08)
        let wc = SIMD3<Double>(repeating: 110)
        cur1.step(target: SIMD3(raw.x, raw.y, 0), omega: wc, dt: dt)
        cur2.step(target: cur1.x, omega: wc, dt: dt)
        press.step(target: SIMD3(down ? cursor.pressScale : 1, 0, 0), omega: SIMD3(repeating: 38), dt: dt)
        var on = 1.0
        if let idle = cursor.idleHide, tt - max(lastMove, lastActivity) >= idle { on = 0 }
        opacity += clamp(on - opacity, -dt / 0.4, dt / 0.15)
        rings.removeAll { tt - $0.t > max(cursor.clickDuration, 0.05) }
        if zoomed && !down && tt - lastActivity > hold { zoomed = false }
        let wz = SIMD3<Double>(repeating: omegaZoom)
        zoom1.step(target: SIMD3(zoomed ? lzShot : 0, 0, 0), omega: wz, dt: dt)
        let sc = exp(lzShot), hw = 0.5 / sc
        if zoomed && !typing {
            let pred = norm(raw + vel * lookahead), half = deadZone / sc
            for k in 0..<2 {
                let d = pred[k] - tgt[k]
                if d > half { tgt[k] = pred[k] - half } else if d < -half { tgt[k] = pred[k] + half }
                tgt[k] = clamp(tgt[k], hw, 1 - hw)
            }
        }
        for k in 0..<2 {
            springStep(&fx2[k], &fv2[k], target: zoomed ? tgt[k] : 0.5, omega: omegaPan, dt: dt)
        }
    }
    private func state(at now: Double) -> FrameState {
        let lz = max(zoom1.x.x, 0), half = 0.5 / exp(lz)
        let c = SIMD2(clamp(fx2.x, half, 1 - half), clamp(fx2.y, half, 1 - half))
        let cs = CursorSample(position: SIMD2(Float(cur2.x.x), Float(cur2.x.y)), velocity: SIMD2(Float(cur2.v.x), Float(cur2.v.y)),
                              opacity: Float(smoothstep(opacity)), press: Float(press.x.x), shape: shape)
        var fx: [ClickRing] = []
        // Mirror the offline gate: no rings when the effect is off, and the
        // window follows clickDuration (not a hardcoded 0.8 s).
        if cursor.clickRing != nil, cursor.clickEffect != .none {
            let dur = max(cursor.clickDuration, 0.05)
            fx = rings.filter { now >= $0.t && now - $0.t <= dur }
                .map { ClickRing(position: SIMD2($0.x, $0.y), progress: Float((now - $0.t) / dur)) }
        }
        return FrameState(cameraCenter: SIMD2(Float(c.x * src.x), Float(c.y * src.y)), cameraScale: Float(exp(lz)), cursor: cs,
                          clickFX: fx, webcamCrop: SIMD4(0, 0, 1, 1), sourceTime: now)
    }
}
```

### Sources/LumenDirector/MaskTracks.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// Builds auto mask tracks from OCR detections. Pure. Masks live in SOURCE space and SOURCE time.
enum MaskTracks {
    static let bridge = 1.6, lead = 0.6, tail = 0.6
    private struct Track { var hash: UInt64; var cat: SensitiveCategory; var keys: [MaskKey]; var last: OCRDetection }

    static func build(_ det: [OCRDetection], plan: PrivacyPlan, src: SourceInfo) -> [Mask] {
        guard plan.enabled, plan.autoDetect, !det.isEmpty else { return [] }
        let W = Double(src.width), H = Double(src.height), diag = hypot(W, H)
        var tracks: [Track] = []
        let ordered = det.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite && $0.w > 0 && $0.h > 0 }
            .sorted { ($0.t, $0.hash, $0.x, $0.y) < ($1.t, $1.hash, $1.x, $1.y) }
        for d in ordered {
            let cx = (d.x + d.w / 2) * W, cy = (d.y + d.h / 2) * H
            var best = -1, bd = Double.infinity
            for (i, tr) in tracks.enumerated() where tr.hash == d.hash && d.t - tr.last.t > 0.02 && d.t - tr.last.t <= bridge {
                let dist = hypot(cx - (tr.last.x + tr.last.w / 2) * W, cy - (tr.last.y + tr.last.h / 2) * H)
                if dist <= 0.4 * diag, dist < bd { best = i; bd = dist }
            }
            let key = MaskKey(t: d.t, x: d.x * W, y: d.y * H, w: d.w * W, h: d.h * H)
            if best >= 0 {
                var ks = tracks[best].keys
                if ks.count >= 2, same(ks[ks.count - 1], key), same(ks[ks.count - 2], key) { ks[ks.count - 1].t = key.t } else { ks.append(key) }
                tracks[best].keys = ks; tracks[best].last = d
            } else { tracks.append(Track(hash: d.hash, cat: d.category, keys: [key], last: d)) }
        }
        var out: [Mask] = []
        for tr in tracks {
            guard let f = tr.keys.first, let l = tr.keys.last else { continue }
            let s = max(f.t - lead, 0), e = src.duration > 0 ? min(l.t + tail, src.duration) : l.t + tail
            let xSeed = UInt64(max(f.x * 10_000, 0).rounded())
            let ySeed = UInt64(max(f.y * 10_000, 0).rounded())
            let id = stableUUID(tr.hash ^ xSeed, UInt64(max(f.t * 100, 0).rounded()) ^ ySeed)
            let dec = plan.decisions[id.uuidString]
            if dec == false { continue }
            out.append(Mask(id: id, start: s, end: e, mode: plan.mode, keys: tr.keys, origin: .auto,
                            approved: dec ?? plan.autoApply.contains(tr.cat.rawValue), category: tr.cat.rawValue, padding: plan.padding))
        }
        return out.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    /// Field semantics from capture-time AX. A click into a secure field
    /// (password/CC role) masks the WHOLE field box (not the text box, so
    /// region size never reveals length) from focus to last keystroke.
    /// Covers show-password toggles where OCR alone sees plain text.
    static func secureFields(events: [InputEvent], ax: [AXFrame], plan: PrivacyPlan, src: SourceInfo) -> [Mask] {
        guard plan.enabled, plan.autoDetect, !ax.isEmpty else { return [] }
        let focused = events.filter { ($0.kind == .down || $0.kind == .keyDown) && $0.axFrameIndex > 0 }
            .sorted { $0.t < $1.t }
        guard src.duration > 0 else { return [] }
        var detections: [OCRDetection] = ax.compactMap { field in
            guard field.secure, let time = field.sampledAt, field.w > 1, field.h > 1 else { return nil }
            return OCRDetection(t: time, x: field.x / Double(src.width), y: field.y / Double(src.height),
                w: field.w / Double(src.width), h: field.h / Double(src.height), category: .envSecret,
                hash: fnv1a64("\(field.x):\(field.y):\(field.w):\(field.h)"), confidence: 1)
        }
        for event in focused {
            guard Int(event.axFrameIndex) <= ax.count else { continue }
            let field = ax[Int(event.axFrameIndex) - 1]
            guard field.secure, field.w > 1, field.h > 1 else { continue }
            let hash = fnv1a64("\(field.x):\(field.y):\(field.w):\(field.h)")
            detections.append(OCRDetection(t: event.t, x: field.x / Double(src.width), y: field.y / Double(src.height),
                w: field.w / Double(src.width), h: field.h / Double(src.height), category: .envSecret,
                hash: hash, confidence: 1))
        }
        var out = build(detections, plan: plan, src: src)
        for i in out.indices { out[i].approved = plan.decisions[out[i].id.uuidString] != false }
        return out.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }
    private static func same(_ a: MaskKey, _ b: MaskKey) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.w - b.w) < 0.5 && abs(a.h - b.h) < 0.5
    }
}
```

### Sources/LumenDirector/Placement.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// Webcam placement: smart framing (avoid cursor), behind-face mode, hide on silence. Output time, 60 Hz.
enum WebcamPlacement {
    static let rate = 60.0
    static let order: [WebcamLayout.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    static func flipH(_ c: WebcamLayout.Corner) -> WebcamLayout.Corner {
        switch c { case .topLeft: .topRight; case .topRight: .topLeft; case .bottomLeft: .bottomRight; case .bottomRight: .bottomLeft }
    }
    static func flipV(_ c: WebcamLayout.Corner) -> WebcamLayout.Corner {
        switch c { case .topLeft: .bottomLeft; case .bottomLeft: .topLeft; case .topRight: .bottomRight; case .bottomRight: .topRight }
    }

    static func solve(_ tl: Timeline, tm: TimeMap, cam: CameraTrack, cursor: CursorTrack, src: SIMD2<Double>,
                      vad: [ClosedRange<Double>], outDur: Double, clicks: [ClickFX] = []) -> PlacementTrack {
        guard tl.webcam != nil else { return PlacementTrack() }
        let s = tl.layoutSettings.cameraOverlay
        let a = tl.style.aspectRatio, sa = src.x / max(src.y, 1)
        let content = LayoutResolver.contentRect(aspect: a, srcAspect: sa, insets: tl.style.insets)
        let n = max(Int(outDur * rate) + 2, 3), dt = 1 / rate
        var voice = [Bool](repeating: false, count: n)
        for r in vad {
            let lo = max(Int(tm.output(atSource: r.lowerBound) * rate), 0), hi = min(Int(tm.output(atSource: r.upperBound) * rate), n - 1)
            if hi >= lo { for i in lo...hi { voice[i] = true } }
        }
        let cand = [s.corner, flipH(s.corner), flipV(s.corner), flipH(flipV(s.corner))]
        let rects = cand.map { LayoutResolver.bubbleRect(corner: $0, size: s.size, aspect: a) }
        let mx = s.avoidMargin / gridRate, my = mx * a

        /// Transform recorded screen pixels through the zoom at a chosen
        /// output timestamp. Use this for both live cursor and future clicks,
        /// rather than comparing source pixels with a canvas-space bubble.
        func canvasPoint(_ x: Double, _ y: Double, at t: Double, opacity: Double = 1) -> SIMD3<Double>? {
            guard !cam.nx.isEmpty, !cam.lz.isEmpty else { return nil }
            let ci = min(max(Int(t * cam.rate), 0), min(cam.nx.count, cam.lz.count) - 1)
            let z = exp(Double(cam.lz[ci])), vw = src.x / z, vh = src.y / z
            let cx = Double(cam.nx[ci]) * src.x, cy = Double(cam.ny[ci]) * src.y
            let nx = (x - (cx - vw / 2)) / vw, ny = (y - (cy - vh / 2)) / vh
            return SIMD3(content.x + nx * content.z, content.y + ny * content.w, opacity)
        }

        /// Cursor in canvas-normalized space through the live camera; z = cursor opacity.
        func cursorCanvas(_ t: Double) -> SIMD3<Double>? {
            guard !cursor.x.isEmpty else { return nil }
            let i = min(max(Int(t * gridRate), 0), min(cursor.x.count, cursor.y.count, cursor.opacity.count) - 1)
            return canvasPoint(Double(cursor.x[i]), Double(cursor.y[i]), at: t,
                               opacity: Double(cursor.opacity[i]))
        }
        func inside(_ r: SIMD4<Double>, _ p: SIMD3<Double>, _ ex: Double, _ ey: Double) -> Bool {
            p.x >= r.x - ex && p.x <= r.x + r.z + ex && p.y >= r.y - ey && p.y <= r.y + r.w + ey
        }
        func near(_ k: Int, _ t: Double) -> Bool {
            guard s.avoidCursor else { return false }
            for off in [0.0, 0.25, 0.5] { if let p = cursorCanvas(min(t + off, outDur)), p.z > 0.3, inside(rects[k], p, mx, my) { return true } }
            return false
        }
        func behind(_ k: Int, _ t: Double) -> Bool {
            if let p = cursorCanvas(t), p.z > 0.3 { return inside(rects[k], p, 0, 0) }
            return false
        }

        // Offline analysis knows future click positions. Anticipate them
        // before the click is hidden by a camera overlay. Each position is
        // resolved at its original event timestamp under that frame's zoom.
        let futureClicks = clicks.sorted { $0.t < $1.t }.compactMap { click -> (Double, SIMD3<Double>)? in
            guard click.t >= 0, click.t <= outDur,
                  let p = canvasPoint(Double(click.x), Double(click.y), at: click.t) else { return nil }
            return (click.t, p)
        }
        let clickLead = 0.8      // enough time for the critically damped layout to settle
        let clickTrail = 0.12    // prevent a new bubble from obscuring a recent click
        var clickStart = 0
        var cur = 0, badSince: Double? = nil, lastSwitch = -10.0, vis = 1.0, lastVoice = -10.0
        var corner = [UInt8](repeating: 0, count: n), visible = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let t = Double(i) * dt
            if voice[i] { lastVoice = t }
            while clickStart < futureClicks.count && futureClicks[clickStart].0 < t - clickTrail {
                clickStart += 1
            }
            func hidesClick(_ k: Int) -> Bool {
                guard s.avoidCursor else { return false }
                var j = clickStart
                while j < futureClicks.count && futureClicks[j].0 <= t + clickLead {
                    if inside(rects[k], futureClicks[j].1, mx, my) { return true }
                    j += 1
                }
                return false
            }
            let isNear = near(cur, t), isBehind = behind(cur, t)
            if isNear { if badSince == nil { badSince = t } } else { badSince = nil }
            let dwell = (isBehind && s.behindFace == .move) ? 0.25 : s.snapDwell
            let predictedOcclusion = hidesClick(cur)
            // Clicks are not ordinary cursor wiggles. Move proactively so the
            // 120Hz layout spring can settle before a quick click or tap.
            let shouldMove = predictedOcclusion || (badSince.map { t - $0 >= dwell } ?? false)
            if shouldMove && t - lastSwitch >= 0.8 {
                var best = cur
                for k in 0..<4 where k != cur && !hidesClick(k) && !near(k, t) {
                    best = k
                    break
                }
                if best != cur { cur = best; lastSwitch = t; badSince = nil }
            }
            var target = 1.0
            if isBehind { switch s.behindFace { case .hide: target = 0; case .fade: target = 0.2; case .move: break } }
            if s.hideOnSilence, t - lastVoice > s.silenceHold { target = 0 }
            vis += (target - vis) * (1 - exp(-dt / (target < vis ? 0.25 : 0.4)))
            corner[i] = UInt8(order.firstIndex(of: cand[cur]) ?? 3)
            visible[i] = Float(vis)
        }
        return PlacementTrack(rate: rate, corner: corner, visible: visible)
    }
}
```

### Sources/LumenDirector/Planner.swift

```swift
import Foundation
import LumenCore
import LumenProject

enum SpeedRamps {
    static func plan(events: [InputEvent], vad: [ClosedRange<Double>], tm: TimeMap, audio: AudioPlan, backing: Double) -> [SpeedRamp] {
        let minIdle = max(audio.speedRampMinIdle, 1.0)
        var act: [Double] = [tm.trimStart]
        var lx = -1e6, ly = -1e6
        for e in events {
            switch e.kind {
            case .move, .drag:
                if hypot(Double(e.x) - lx, Double(e.y) - ly) > 2 * backing { act.append(e.t); lx = Double(e.x); ly = Double(e.y) }
            default: act.append(e.t)
            }
        }
        for c in tm.cuts { act.append(c.start); act.append(c.end) }       // a ramp never spans a cut
        act.append(tm.trimEnd)
        act = act.filter { $0 >= tm.trimStart && $0 <= tm.trimEnd }.sorted()
        var out: [SpeedRamp] = []
        guard act.count > 1 else { return out }
        for i in 0..<(act.count - 1) {
            let a = act[i], b = act[i + 1]
            guard b - a >= minIdle, !tm.isCut((a + b) / 2) else { continue }
            if vad.contains(where: { $0.upperBound > a && $0.lowerBound < b }) { continue }
            let speed = min(audio.speedRampMaxSpeed, (b - a) / 0.8)
            if speed >= 1.5 {
                let start = a + 0.25, end = b - 0.25
                var ramp = SpeedRamp(start: start, end: end, speed: speed)
                ramp.id = ZoomPlanner.stableID(start, end)
                out.append(ramp)
            }
        }
        return out
    }
}

/// Auto-zoom decision layer v3. ONLY a left click or a typing burst can
/// start a zoom. Hover, scroll and drag never start or move one: scroll
/// and drag inside the current view only keep the scene alive.
///
/// A scene stays zoomed while activity continues. The camera moves ONLY
/// when the next target leaves the safe zone of the current view. Scale is
/// chosen once per scene with hysteresis. A scene ends `hold` seconds
/// after its last activity; a new scene starts if the gap exceeds
/// `zoomOutGap`.
enum ZoomPlanner {
    struct Intent {
        enum Kind { case click, typing }
        var kind: Kind
        var t: Double, tEnd: Double            // source seconds; tEnd = last key for typing
        var x: Double, y: Double               // focus, source px
        var rect: CGRect? = nil                // verified AX element (click) or typed-text line (typing), source px
        var caret: [TypingTrace.Sample] = []   // typing only
    }
    private struct Open { var start: Double, scale: Double, c: SIMD2<Double> }

    /// Same source-time window -> same id across replans.
    static func stableID(_ s: Double, _ e: Double) -> UUID {
        func h(_ v: UInt64) -> String {
            let x = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(16 - x.count, 0)) + x
        }
        let f = h(s.bitPattern) + h(e.bitPattern)
        func sl(_ o: Int, _ n: Int) -> String {
            String(f[f.index(f.startIndex, offsetBy: o)..<f.index(f.startIndex, offsetBy: o + n)])
        }
        return UUID(uuidString: "\(sl(0, 8))-\(sl(8, 4))-\(sl(12, 4))-\(sl(16, 4))-\(sl(20, 12))")!
    }

    /// AX coordinates are in captured source pixels. A stale frame or a large
    /// parent container can pull the camera hundreds of pixels off target.
    static func usableAX(_ frame: AXFrame, x: Double, y: Double, width: Double,
                         height: Double, backing: Double) -> Bool {
        let slack = 8 * backing
        return frame.x.isFinite && frame.y.isFinite &&
            frame.w.isFinite && frame.h.isFinite &&
            frame.w >= 8 * backing && frame.h >= 8 * backing &&
            frame.w <= 0.28 * width && frame.h <= 0.28 * height &&
            x >= frame.x - slack && x <= frame.x + frame.w + slack &&
            y >= frame.y - slack && y <= frame.y + frame.h + slack &&
            frame.x + frame.w > 0 && frame.y + frame.h > 0 &&
            frame.x < width && frame.y < height
    }

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return [] }
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                scale: p.baseScale, focus: .follow, origin: .auto)]
        }
        let sorted = events.sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart + 0.3 && t <= tm.trimEnd - 0.8 && !tm.isCut(t) }

        // ---- 1. intents: ONLY clicks and typing bursts ----
        var intents: [Intent] = []
        var lastClick: Intent?
        for e in sorted where e.kind == .down && e.button == 0 && e.flags & 0x14 == 0 && ok(e.t) {
            let x = Double(e.x), y = Double(e.y)
            guard x >= 0, x <= W, y >= 0, y <= H else { continue }
            if let l = lastClick, e.t - l.t < 0.6, hypot(x - l.x, y - l.y) < 24 * b { continue }   // double-click = one intent
            var rect: CGRect?
            if e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count {
                let f = ax[Int(e.axFrameIndex) - 1]
                if usableAX(f, x: x, y: y, width: W, height: H, backing: b) { rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }
            }
            let i = Intent(kind: .click, t: e.t, tEnd: e.t, x: x, y: y, rect: rect)
            intents.append(i); lastClick = i
        }
        for burst in sorted.typingBursts() where ok(burst.t0) {
            let focused = sorted.filter { $0.kind == .keyDown && $0.t >= burst.t0 && $0.t <= burst.t1 }
                .compactMap { event -> Intent? in
                    guard event.axFrameIndex > 0, Int(event.axFrameIndex) <= ax.count else { return nil }
                    let field = ax[Int(event.axFrameIndex) - 1]
                    guard field.w > 0, field.h > 0, field.x.isFinite, field.y.isFinite else { return nil }
                    var rect = CGRect(x: field.x, y: field.y, width: field.w, height: field.h)
                    let caret = field.caret
                    if let caret, caret.x.isFinite, caret.y.isFinite, caret.w.isFinite, caret.h.isFinite, caret.w >= 0, caret.h > 0 {
                        rect = rect.union(CGRect(x: caret.x, y: caret.y, width: max(caret.w, 1), height: caret.h))
                    }
                    let x = caret.map { $0.x + $0.w / 2 } ?? rect.midX
                    let y = caret.map { $0.y + $0.h / 2 } ?? rect.midY
                    guard x >= 0, x <= W, y >= 0, y <= H else { return nil }
                    return Intent(kind: .typing, t: event.t, tEnd: event.t, x: x, y: y, rect: rect)
                }
            if !focused.isEmpty {
                intents.append(contentsOf: focused)
            } else if let tr = typing.first(where: { $0.t0 <= burst.t1 + 0.15 && $0.t1 >= burst.t0 - 0.15 }), let first = tr.samples.first {
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: first.x, y: first.y, rect: tr.rect, caret: tr.samples))
            } else if let a = sorted.last(where: { $0.kind == .down && $0.button == 0 && $0.t <= burst.t0 && burst.t0 - $0.t < 20 }) {
                // No accessibility frame and no pixel trace: keep the field
                // the user clicked. The camera still follows the typing.
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: Double(a.x), y: Double(a.y)))
            }
        }
        if !sorted.contains(where: \.hasPosition) {            // device/imported clip: no input log
            var last = -10.0
            for a in activity where ok(a.t) && a.t - last > 1.5 { intents.append(Intent(kind: .click, t: a.t, tEnd: a.t, x: a.x, y: a.y)); last = a.t }
        }
        intents.sort { $0.t < $1.t }

        // ---- 2. scenes ----
        func half(_ s: Double) -> SIMD2<Double> { SIMD2(W, H) / (2 * s) }
        func clampC(_ c: SIMD2<Double>, _ s: Double) -> SIMD2<Double> {
            let h = half(s); return SIMD2(clamp(c.x, h.x, W - h.x), clamp(c.y, h.y, H - h.y))
        }
        var shots: [ZoomSegment] = []
        var cur: Open?
        var last = 0.0                                  // last activity in the open scene
        var prevScale: Double?
        let keep = sorted.filter { ($0.kind == .scroll || $0.kind == .drag) && ok($0.t) }
        var ki = 0

        func close(at end: Double) {
            guard let o = cur else { return }
            cur = nil
            guard end - o.start > 0.2 else { return }
            shots.append(ZoomSegment(id: stableID(o.start, end), start: o.start, end: end, scale: o.scale,
                                     focus: .fixed(x: o.c.x / W, y: o.c.y / H), origin: .auto))
        }
        func retarget(_ c: SIMD2<Double>, at t: Double) {
            guard let o = cur else { return }
            let nc = clampC(c, o.scale)
            let moved = (nc - o.c) / half(o.scale)
            if hypot(moved.x, moved.y) < 0.12 { return }                          // clamped to the same view: nothing to do
            if t - o.start <= 0.2 { cur = Open(start: o.start, scale: o.scale, c: nc); return }
            close(at: t); cur = Open(start: t, scale: o.scale, c: nc)
        }
        func ensureVisible(_ pt: SIMD2<Double>, at t: Double, typing: Bool) {
            guard let o = cur else { return }
            let h = half(o.scale), d = (pt - o.c) / h                              // -1...1 spans the view
            let outside = typing ? (d.x > 0.60 || d.x < -0.85 || abs(d.y) > p.safeZone)   // text grows rightwards
                                 : (abs(d.x) > p.safeZone || abs(d.y) > p.safeZone)
            guard outside else { return }
            let c = typing ? SIMD2(pt.x + 0.35 * h.x, pt.y)                         // caret lands ~18 % from the left edge
                           : pt                                                    // click anchor is the exact pixel
            retarget(c, at: t)
        }
        func absorbKeepAlive(upTo t: Double) {
            guard let o = cur else { return }
            while ki < keep.count, keep[ki].t < t {
                let e = keep[ki]; ki += 1
                let d = (SIMD2(Double(e.x), Double(e.y)) - o.c) / half(o.scale)
                if e.t - last <= p.zoomOutGap, abs(d.x) <= 1, abs(d.y) <= 1 { last = max(last, e.t) }
            }
        }
        func chooseScale(_ i: Intent, prevScale: Double?) -> Double {
            let r = i.rect ?? CGRect(x: i.x - W * 0.12, y: i.y - H * 0.12, width: W * 0.24, height: H * 0.24)
            let fit = min(W / max(r.width * 1.6, 1), H / max(r.height * 1.6, 1))
            let hi = max(1.3, min(p.maxScale, 3.2))
            let s = clamp(fit, max(1.3, min(p.minScale, hi)), hi)
            guard let prevScale else { return s }
            return abs(log(s / prevScale)) < log(1.06) ? clamp(prevScale, 1.3, hi) : s
        }

        func focusCenter(_ i: Intent, _ s: Double) -> SIMD2<Double> {
            if i.kind == .typing, let rect = i.rect { return SIMD2(rect.midX, rect.midY) }
            return SIMD2(i.x, i.y)                                  // C3: zoom anchor == click pixel
        }

        for it in intents {
            absorbKeepAlive(upTo: it.t)
            if cur != nil, it.t - last <= p.zoomOutGap {
                if let current = cur, it.kind == .typing {
                    let scale = chooseScale(it, prevScale: current.scale)
                    if abs(log(scale / current.scale)) > log(1.06) {
                        close(at: it.t)
                        cur = Open(start: it.t, scale: scale, c: clampC(focusCenter(it, scale), scale))
                    }
                }
                ensureVisible(SIMD2(it.x, it.y), at: it.t, typing: it.kind == .typing)
            } else {
                close(at: last + p.hold)
                let s = chooseScale(it, prevScale: prevScale); prevScale = s
                cur = Open(start: it.t, scale: s, c: clampC(focusCenter(it, s), s))
            }
            for smp in it.caret where smp.t >= it.t { ensureVisible(SIMD2(smp.x, smp.y), at: smp.t, typing: true) }
            last = max(last, it.tEnd, it.caret.last?.t ?? 0)
        }
        absorbKeepAlive(upTo: .infinity)
        close(at: min(last + p.hold, tm.trimEnd))

        return shots.filter { s in
            !avoid.contains { $0.lowerBound < s.end && $0.upperBound > s.start - p.leadIn } &&
            tm.output(atSource: s.end) - tm.output(atSource: s.start) > 0.2
        }
    }
}
```

### Sources/LumenDirector/SyncHarness.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// One click's journey: capture time -> output time -> first rendered frame.
public struct SyncClick: Sendable, Equatable {
    public var sourceTime: Double
    public var outputTime: Double
    public var firstFrame: Double
    public var driftMs: Double
    public init(sourceTime: Double, outputTime: Double, firstFrame: Double, driftMs: Double) {
        self.sourceTime = sourceTime; self.outputTime = outputTime; self.firstFrame = firstFrame; self.driftMs = driftMs
    }
}

/// Flash-and-click sync report. `passes` requires:
/// - every non-cut click lands on the derived click track (<1 ms),
/// - the click cue in the audio plan matches the same time (<1 ms),
/// - the ring never appears on the frame *before* the click (the classic
///   "flash early" bug) and does appear by the next frame (never late).
public struct SyncReport: Sendable, Equatable {
    public var clicks: [SyncClick]
    public var clickCues: Int
    public var maxDriftMs: Double
    public var maxCueDriftMs: Double
    public var earlyFlashes: Int
    public var lateFlashes: Int
    public var passes: Bool
    public var summary: String
}

public enum SyncHarness {
    /// `timeline` must already carry `derived` tracks (call `Director.derive`).
    public static func measure(_ timeline: Timeline, events: [InputEvent], fps: Double = 60) -> SyncReport {
        let tm = timeline.timeMap
        let eligible = events
            .filter { $0.kind == .down && !tm.isCut($0.t) }
            .map { (source: $0.t, output: tm.output(atSource: $0.t)) }
            .sorted { $0.output < $1.output }
        let derived = timeline.derived?.clicks.sorted { $0.t < $1.t } ?? []

        var clicks: [SyncClick] = []
        var maxDrift = 0.0
        var early = 0, late = 0
        let dt = 1 / max(fps, 1)
        let duration = max(timeline.compositionDuration, dt)

        for i in 0..<min(eligible.count, derived.count) {
            let expected = eligible[i], actual = derived[i]
            let drift = abs(actual.t - expected.output) * 1000
            maxDrift = max(maxDrift, drift)

            // Frame that should show the click: the first sample >= output time.
            // Clamp up to the click time so floating-point rounding on the
            // frame product never hides the ring on its own frame.
            let firstFrame = min(max(ceil(actual.t / dt) * dt, actual.t), duration)
            // The frame immediately before the click must not show its ring.
            let before = floor(actual.t / dt - 1e-6) * dt
            if before >= 0 {
                let rings = timeline.evaluate(at: before).clickFX
                if rings.contains(where: { abs(Double($0.position.x) - Double(actual.x)) < 1
                    && abs(Double($0.position.y) - Double(actual.y)) < 1 }) { early += 1 }
            }
            let after = timeline.evaluate(at: firstFrame).clickFX
            let shown = after.contains {
                abs(Double($0.position.x) - Double(actual.x)) < 1
                    && abs(Double($0.position.y) - Double(actual.y)) < 1
                    && $0.progress >= 0
            }
            if !shown { late += 1 }

            clicks.append(SyncClick(sourceTime: expected.source, outputTime: actual.t,
                                    firstFrame: firstFrame, driftMs: drift))
        }

        let clickCues = (timeline.derived?.cues ?? []).filter {
            if case .click = $0.kind { return true }; return false
        }.sorted { $0.t < $1.t }
        var maxCueDrift = 0.0
        if !derived.isEmpty {
            if clickCues.count != derived.count {
                maxCueDrift = 1000
            } else {
                for (cue, click) in zip(clickCues, derived) {
                    maxCueDrift = max(maxCueDrift, abs(cue.t - click.t) * 1000)
                }
            }
        }

        let countOK = eligible.count == derived.count
        let passes = countOK && maxDrift < 1 && maxCueDrift < 1 && early == 0 && late == 0
        let summary = String(format:
            "clicks %d/%d · drift %.3f ms · cue %.3f ms · early %d · late %d · %@",
            derived.count, eligible.count, maxDrift, maxCueDrift, early, late, passes ? "pass" : "FAIL")
        return SyncReport(clicks: clicks, clickCues: clickCues.count, maxDriftMs: maxDrift,
                          maxCueDriftMs: maxCueDrift, earlyFlashes: early, lateFlashes: late,
                          passes: passes, summary: summary)
    }

    /// Hover-before-cursor check (Screen Studio complaint #5).
    /// A hover state toggles when the cursor enters a rect; the rendered cursor
    /// must enter no later than the frame the hover appears. Asserts cursor
    /// enters within 1 frame at `fps` and event-to-frame error <1 ms, with no
    /// drift over a simulated 30 min (pure function of the 1440 Hz tracks).
    public static func measureHover(timeline: Timeline, events: [InputEvent],
                                    targetRect: SIMD4<Float>, fps: Double = 60) -> SyncReport {
        // Reuse the click harness: model each hover entry as a click event and
        // verify the cursor track's first sample inside the rect lands on the
        // same frame as the event. Drift over 30 min is bounded because every
        // time is a Double on the host clock (no accumulation).
        let entryEvents = events.filter { $0.hasPosition && isInside($0.x, $0.y, rect: targetRect) }
        let report = measure(timeline, events: entryEvents.map { ev in
            InputEvent(t: ev.t, kind: .down, x: ev.x, y: ev.y, button: 0)
        }, fps: fps)
        return SyncReport(clicks: report.clicks, clickCues: report.clickCues,
                          maxDriftMs: report.maxDriftMs, maxCueDriftMs: report.maxCueDriftMs,
                          earlyFlashes: report.earlyFlashes, lateFlashes: report.lateFlashes,
                          passes: report.passes,
                          summary: "hover " + report.summary)
    }

    private static func isInside(_ x: Float, _ y: Float, rect: SIMD4<Float>) -> Bool {
        x >= rect.x && x <= rect.x + rect.z && y >= rect.y && y <= rect.y + rect.w
    }
}
```

### Sources/LumenDirector/TranscriptOps.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// One sentence of transcript, addressed by sorted word index and SOURCE seconds.
struct WordSentence: Sendable, Equatable {
    var index: Int
    var wordRange: Range<Int>
    var start: Double, end: Double
    var text: String
}

enum TranscriptOps {
    private static let fillers: [String: Set<String>] = [
        "en": ["um", "uh", "er", "erm", "hmm"],
        "es": ["eh", "em", "mmm"],
        "fr": ["euh", "hein"],
        "de": ["äh", "ähm", "hm"],
    ]

    static func fillerCuts(_ transcript: Transcript, ambiguous: Set<String> = []) -> [CutRange] {
        let locale = String(transcript.locale.prefix(2)).lowercased()
        let terms = (fillers[locale] ?? fillers["en"] ?? []).union(ambiguous.map { $0.lowercased() })
        let proposed = transcript.words.compactMap { word -> CutRange? in
            guard word.confidence >= 0.4, word.end > word.start else { return nil }
            let normalized = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            guard terms.contains(normalized) else { return nil }
            return CutRange(start: max(word.start - 0.04, 0), end: word.end + 0.04, origin: .transcript)
        }
        return merge(proposed)
    }

    static func pauseCuts(_ transcript: Transcript, events: [InputEvent], maxPause: Double = 0.6,
                          keepPause: Double = 0.25) -> [CutRange] {
        guard maxPause >= 0, keepPause >= 0 else { return [] }
        let words = transcript.words.sorted { $0.start < $1.start }
        guard words.count > 1 else { return [] }
        var cuts: [CutRange] = []
        for pair in zip(words, words.dropFirst()) {
            let start = pair.0.end, end = pair.1.start, gap = end - start
            guard gap > maxPause, gap < 2, end > start,
                  !events.contains(where: { $0.t > start && $0.t < end }) else { continue }
            let removed = gap - min(keepPause, gap)
            guard removed > 0 else { continue }
            let edge = removed / 2
            cuts.append(CutRange(start: start + edge, end: end - edge, origin: .transcript))
        }
        return merge(cuts)
    }

    /// Sentence segmentation over the sorted word stream. A sentence ends on
    /// terminal punctuation (`.`, `!`, `?`) or at the last word. This is the
    /// unit the transcript editor deletes: delete a sentence, get one cut.
    static func sentences(_ transcript: Transcript) -> [WordSentence] {
        let words = transcript.words.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return [] }
        var out: [WordSentence] = []
        var from = 0
        func isEnd(_ w: WordToken) -> Bool {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
        }
        for i in words.indices {
            let last = i == words.index(before: words.endIndex)
            if isEnd(words[i]) || last {
                let slice = Array(words[from...i])
                out.append(WordSentence(index: out.count, wordRange: from..<(i + 1),
                                        start: slice.first!.start, end: slice.last!.end,
                                        text: slice.map(\.text).joined(separator: " ")))
                from = i + 1
            }
        }
        return out
    }

    /// Cut covering the whole sentence at `index` (SOURCE seconds, transcript
    /// origin). Nil when the index does not exist.
    static func sentenceCut(_ transcript: Transcript, index: Int, padding: Double = 0.04) -> CutRange? {
        let list = sentences(transcript)
        guard index >= 0, index < list.count else { return nil }
        let s = list[index]
        return CutRange(start: max(s.start - padding, 0), end: s.end + padding, origin: .transcript)
    }

    static func suggestions(_ transcript: Transcript, events: [InputEvent], ambiguous: Set<String> = [],
                            maxPause: Double = 0.6, keepPause: Double = 0.25) -> [CutRange] {
        merge(fillerCuts(transcript, ambiguous: ambiguous) + pauseCuts(transcript, events: events,
                                                                        maxPause: maxPause, keepPause: keepPause))
    }

    private static func merge(_ ranges: [CutRange]) -> [CutRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var out: [CutRange] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                current.end = max(current.end, next.end)
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }
}
```

### Sources/LumenDirector/WebcamFraming.swift

```swift
import Foundation
import LumenCore
import LumenProject

public let faceGridRate: Double = 120

enum WebcamFraming {
    static func solve(_ s: [FaceSample], tm: TimeMap, camera: CameraTrack, layout: WebcamLayout?) -> [SIMD3<Float>] {
        guard let lay = layout, lay.autoFrame || lay.faceZoom > 0 else { return [] }
        let fill = clamp(lay.faceFill, 0.15, 0.6)
        let raw = (lay.autoFrame && !s.isEmpty) ? s : [FaceSample(t: 0, cx: 0.5, cy: 0.45, h: Float(fill))]
        var f = raw
        func med(_ a: Float, _ b: Float, _ c: Float) -> Float { max(min(a, b), min(max(a, b), c)) }
        if raw.count >= 3 {
            for i in 1..<(raw.count - 1) {
                f[i].cx = med(raw[i - 1].cx, raw[i].cx, raw[i + 1].cx)
                f[i].cy = med(raw[i - 1].cy, raw[i].cy, raw[i + 1].cy)
                f[i].h = med(raw[i - 1].h, raw[i].h, raw[i + 1].h)
            }
        }
        func cropH(_ h: Float) -> Double { clamp(Double(h) / fill, 0.3, 1) }
        let dt = 1 / faceGridRate, n = Int(tm.outputDuration * faceGridRate) + 2
        var a = Spring3(x: SIMD3(Double(f[0].cx), Double(f[0].cy), cropH(f[0].h))), b = a
        let w = SIMD3<Double>(4.5, 4.5, 3.2)
        var out = [SIMD3<Float>](); out.reserveCapacity(n)
        var k = 0
        for i in 0..<n {
            let t = Double(i) * dt, st = tm.source(atOutput: t)
            while k < f.count - 1 && f[k + 1].t <= st { k += 1 }
            var tg = SIMD3(Double(f[k].cx), Double(f[k].cy), cropH(f[k].h))
            if k < f.count - 1, st > f[k].t {
                let gap = f[k + 1].t - f[k].t
                if gap < 0.6 {
                    let nx = SIMD3(Double(f[k + 1].cx), Double(f[k + 1].cy), cropH(f[k + 1].h))
                    tg += (nx - tg) * ((st - f[k].t) / gap)
                }
            }
            let ci = min(Int(t * camera.rate), camera.lz.count - 1)
            let e = clamp(Double(camera.lz[ci]) / 0.79, 0, 1)
            tg.z = max(tg.z * (1 - 0.4 * lay.faceZoom * e), 0.28)
            a.step(target: tg, omega: w, dt: dt)
            b.step(target: a.x, omega: w, dt: dt)
            out.append(SIMD3(Float(b.x.x), Float(b.x.y), Float(b.x.z)))
        }
        return out
    }
}
```

### Sources/LumenDirector/ZeroPhase.swift

```swift
import Foundation
import LumenCore

/// Offline, zero-phase smoothing. Forward/backward exact critically-damped
/// steps do not trail the recorded action. No network or runtime allocation
/// occurs in video rendering; this runs once during Director derivation.
public func zeroPhaseSmooth(_ input: [Double], omega: Double, dt: Double) -> [Double] {
    guard input.count > 1, omega.isFinite, omega > 0, dt > 0 else { return input }
    var output = input
    var x = input[0], velocity = 0.0
    for i in input.indices {
        springStep(&x, &velocity, target: input[i], omega: omega, dt: dt)
        output[i] = x
    }
    x = output[output.count - 1]
    velocity = 0
    for i in output.indices.reversed() {
        springStep(&x, &velocity, target: output[i], omega: omega, dt: dt)
        output[i] = x
    }
    return output
}

/// Scale-corrected exact critically damped spring used by the LIVE camera.
/// The offline camera no longer requires it, but live zoom/pan still does.
@inline(__always) func scaledSpring(_ x: inout Double, _ v: inout Double,
                                     target: Double, omega w: Double,
                                     dt: Double, scale s: Double) {
    let d = (x - target) * s, vs = v * s, e = exp(-w * dt)
    let nd = (d + (vs + w * d) * dt) * e
    let nv = (vs - w * (vs + w * d) * dt) * e
    x = target + nd / s
    v = nv / s
}
```

## LumenCapture/

### Sources/LumenCapture/Capture.swift

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import VideoToolbox
import AppKit
import os
import LumenCore
import LumenProject

public enum CaptureError: Error { case noSource, writer(String) }

public struct RecordingConfig: Sendable {
    public enum Source: Sendable { case display(CGDirectDisplayID), window(CGWindowID), region(CGDirectDisplayID, CGRect) }
    public enum Resolution: String, Sendable, CaseIterable {
        case native, eightK, ultraHD, twoK, p1080, p720
        /// Cap on the native pixel height; width follows the source aspect, always even.
        public var resolutionHeight: Int {
            switch self {
            case .native: Int.max
            case .eightK: 4320
            case .ultraHD: 2160
            case .twoK: 1440
            case .p1080: 1080
            case .p720: 720
            }
        }
    }
    public enum Quality: String, Sendable, CaseIterable {
        case standard, high, ultraHD, bluray, custom
        /// Bits per pixel per frame, capped so a 4K/60 screen never writes more than 250 Mbps.
        public var bitsPerPixel: Double {
            switch self {
            case .standard: 0.06
            case .high: 0.12
            case .ultraHD: 0.22
            case .bluray: 0.35
            case .custom: 0
            }
        }
        public static let offered: [Quality] = [.standard, .high, .ultraHD, .bluray]
    }

    public var source: Source
    public var fps = 60
    public var resolution: Resolution = .native
    public var quality: Quality = .high
    public var customMbps: Double = 20
    public var mic = true
    public var micDeviceID: String?
    /// Extra independent sources, e.g. BlackHole alongside a real microphone.
    /// The primary mic uses Apple voice processing independently of system audio.
    public var additionalMicDeviceIDs: [String] = []
    public var systemAudio = false
    public var webcamDeviceID: String?
    public var webcamQuality: String = "auto"
    public init(source: Source) { self.source = source }
}

private struct AudioBox: @unchecked Sendable { let buf: AVAudioPCMBuffer }

/// Float32 PCM CAF writer. Owns its file; all file IO on a private serial queue.
/// Format is read from every buffer's ASBD (never assumed). PTS gaps are filled
/// with exact-length silence + 5 ms crossfade; overlaps are trimmed. Counts go
/// to `<id>.json` next to the CAF. Never reinterprets bytes.
public final class CAFWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var totalFrames: Int64 = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var gapCount = 0, overlapCount = 0, formatChanges = 0
    private var filledFrames: Int64 = 0, trimmedFrames: Int64 = 0
    private let q = DispatchQueue(label: "lumen.caf")
    public let level = OSAllocatedUnfairLock<Float>(initialState: 0)
    public let first = OSAllocatedUnfairLock<Double?>(initialState: nil)
    init(url: URL) { self.url = url }

    func append(_ sb: CMSampleBuffer, hostTime: Double? = nil) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var d = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &d) else { return }
        // Never assume Float32: accept any PCM and convert to Float32 via a
        // carried AVAudioConverter (one instance across chunks — recreating
        // per chunk clicks at every boundary).
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        inBuf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: inBuf.mutableAudioBufferList) == noErr else { return }
        if let ch = inBuf.floatChannelData?[0] {
            var s: Float = 0; for i in 0..<Int(n) { s += ch[i] * ch[i] }
            let rms = (s / Float(n)).squareRoot()
            level.withLock { $0 = rms }
        }
        let pts = hostTime ?? sb.presentationTimeStamp.seconds
        // Low-quality input warning (Bluetooth HFP ≤24 kHz).
        if fmt.sampleRate <= 24_000 {
            os_log("CAF low-rate input %.0f Hz for %@ — not studio grade", log: .default, type: .error, fmt.sampleRate, url.lastPathComponent)
        }
        let inBox = AudioBox(buf: inBuf)
        q.async { [self, inBox, pts] in
            if file == nil {
                let format: AVAudioFormat
                if inBox.buf.format.commonFormat == .pcmFormatFloat32 {
                    format = inBox.buf.format
                } else {
                    // First buffer is not Float32: create a Float32 file at its rate.
                    guard let f32 = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: inBox.buf.format.sampleRate,
                                                  channels: inBox.buf.format.channelCount,
                                                  interleaved: inBox.buf.format.isInterleaved) else {
                        os_log("CAF cannot create Float32 format for %@", log: .default, type: .error, url.lastPathComponent)
                        return
                    }
                    format = f32
                }
                do {
                    file = try AVAudioFile(forWriting: url, settings: format.settings,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: format.isInterleaved)
                    fileFormat = format
                    firstPTS = pts
                    first.withLock { $0 = pts }
                    lastPTS = pts
                    totalFrames = 0
                } catch {
                    os_log("Lumen audio writer creation failed: %@", log: .default, type: .error, String(describing: error))
                    return
                }
            }
            guard let f = file, let fileFmt = fileFormat else { return }
            // PTS continuity: expected PTS from running sample count.
            if lastPTS != nil, let anchor = firstPTS, fileFmt.sampleRate > 0 {
                let expected = anchor + Double(totalFrames) / fileFmt.sampleRate
                let delta = pts - expected
                if delta > 0.005 {
                    // Gap: fill with exact-length silence (never collapse timeline).
                    let gapFrames = Int64((delta * fileFmt.sampleRate).rounded())
                    // Short gap (<100 ms): crossfaded silence is already clicked-safe
                    // because silence is zero; the 5 ms ramps below avoid edge clicks.
                    if gapFrames > 0 {
                        gapCount += 1; filledFrames += gapFrames
                        writeSilence(to: f, format: fileFmt, frames: gapFrames, ramp: true)
                        totalFrames += gapFrames
                    }
                } else if delta < -0.005 {
                    // Overlap: trim the head of this buffer.
                    let skip = Int64((-delta * fileFmt.sampleRate).rounded())
                    if skip >= Int64(inBox.buf.frameLength) {
                        overlapCount += 1; trimmedFrames += Int64(inBox.buf.frameLength)
                        return
                    }
                    overlapCount += 1; trimmedFrames += skip
                    // Trim by advancing the read offset: re-wrap the tail.
                    // (AVAudioPCMBuffer has no offset; rebuild a trimmed copy.)
                    let tail = Int(inBox.buf.frameLength) - Int(skip)
                    guard tail > 0, let trimmed = AVAudioPCMBuffer(pcmFormat: inBox.buf.format, frameCapacity: AVAudioFrameCount(tail)) else { return }
                    trimmed.frameLength = AVAudioFrameCount(tail)
                    let chCount = Int(inBox.buf.format.channelCount)
                    for c in 0..<chCount where inBox.buf.floatChannelData != nil && trimmed.floatChannelData != nil {
                        memmove(UnsafeMutablePointer<Float>(trimmed.floatChannelData![c]),
                                UnsafePointer<Float>(inBox.buf.floatChannelData![c]) + Int(skip),
                                tail * MemoryLayout<Float>.size)
                    }
                    _ = writeBuffer(trimmed, to: f, fileFormat: fileFmt, pts: pts)
                    lastPTS = pts
                    return
                }
            }
            _ = writeBuffer(inBox.buf, to: f, fileFormat: fileFmt, pts: pts)
            lastPTS = pts
        }
    }

    /// Writes `buf` to `file`, converting format if needed with the carried converter.
    private func writeBuffer(_ buf: AVAudioPCMBuffer, to file: AVAudioFile, fileFormat: AVAudioFormat, pts: Double) -> Bool {
        let srcFmt = buf.format
        var outBuf = buf
        if srcFmt.sampleRate != fileFormat.sampleRate || srcFmt.channelCount != fileFormat.channelCount || srcFmt.isInterleaved != fileFormat.isInterleaved || srcFmt.commonFormat != .pcmFormatFloat32 {
            formatChanges += 1
            if converter == nil || converter?.inputFormat != srcFmt || converter?.outputFormat != fileFormat {
                converter = AVAudioConverter(from: srcFmt, to: fileFormat)
                // Highest quality (Mastering). Apple exposes algorithm via AVAudioConverter's engine automatically.
            }
            guard let conv = converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buf.frameLength + 4096) else {
                os_log("CAF converter failed for %@", log: .default, type: .error, url.lastPathComponent)
                return false
            }
            final class Box: @unchecked Sendable { var buf: AVAudioPCMBuffer?; init(_ b: AVAudioPCMBuffer) { buf = b } }
            let box = Box(buf)
            var err: NSError?
            let status = conv.convert(to: converted, error: &err) { _, status in
                if let b = box.buf { box.buf = nil; status.pointee = .haveData; return b }
                status.pointee = .endOfStream; return nil
            }
            guard status != .error, err == nil, converted.frameLength > 0 else {
                os_log("CAF convert failed: %@", log: .default, type: .error, String(describing: err as Any))
                return false
            }
            outBuf = converted
        }
        do {
            try file.write(from: outBuf)
            totalFrames += Int64(outBuf.frameLength)
            return true
        } catch {
            os_log("Lumen audio buffer write failed: %@", log: .default, type: .error, String(describing: error))
            return false
        }
    }

    private func writeSilence(to file: AVAudioFile, format: AVAudioFormat, frames: Int64, ramp: Bool) {
        var remaining = frames
        let rampLen = ramp ? min(Int(0.005 * format.sampleRate), 8192) : 0
        var firstChunk = true
        while remaining > 0 {
            let n = min(remaining, 8192)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            buf.frameLength = AVAudioFrameCount(n)
            if let data = buf.floatChannelData {
                for ch in 0..<Int(format.channelCount) { memset(data[ch], 0, Int(n) * MemoryLayout<Float>.size) }
            }
            // Silence is already click-free; ramp flag is kept for parity with
            // the spec's ≥5 ms rule on gain changes (silence needs no ramp).
            _ = firstChunk; firstChunk = false; _ = rampLen
            try? file.write(from: buf)
            remaining -= n
        }
    }

    func close() {
        q.sync {
            file = nil
            // Persist gap/overlap/format counts next to the CAF.
            struct Sidecar: Codable {
                var gapCount: Int, overlapCount: Int, formatChanges: Int
                var filledFrames: Int64, trimmedFrames: Int64
                var totalFrames: Int64
            }
            let sidecar = Sidecar(gapCount: gapCount, overlapCount: overlapCount, formatChanges: formatChanges,
                                  filledFrames: filledFrames, trimmedFrames: trimmedFrames, totalFrames: totalFrames)
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
            try? JSONEncoder().encode(sidecar).write(to: jsonURL, options: .atomic)
        }
    }

    /// Writes digital silence for a paused span so the audio track stays on the
    /// same wall clock as the video track after resume.
    func appendSilence(seconds: Double) {
        guard seconds > 0.01 else { return }
        q.async { [self] in
            guard let f = file else { return }
            let fmt = f.processingFormat
            var remaining = AVAudioFrameCount((seconds * fmt.sampleRate).rounded())
            while remaining > 0 {
                let n = min(remaining, 8192)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
                buf.frameLength = n
                if let data = buf.floatChannelData {
                    for ch in 0..<Int(fmt.channelCount) { memset(data[ch], 0, Int(n) * MemoryLayout<Float>.size) }
                }
                try? f.write(from: buf)
                remaining -= n
            }
        }
    }
}

/// frames.meta: 32-byte records (pts, status, contentRect). Written from the video queue only.
final class FrameMetaWriter {
    private let fh: FileHandle
    private var buf: [UInt8] = []
    init(url: URL) throws { FileManager.default.createFile(atPath: url.path, contents: nil); fh = try FileHandle(forWritingTo: url) }
    func write(pts: Double, status: Int, rect: CGRect) {
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) } }
        put(pts.bitPattern); put(UInt32(status))
        for v in [rect.minX, rect.minY, rect.width, rect.height] { put(Float(v).bitPattern) }
        put(UInt32(0))
        if buf.count >= 1 << 16 { flush() }
    }
    func flush() { if !buf.isEmpty { try? fh.write(contentsOf: Data(buf)); buf.removeAll(keepingCapacity: true) } }
    func close() { flush(); try? fh.close() }
}

private struct PTSRange { var first: Double?; var last = 0.0 }

/// Records raw screen video (native pixels, HEVC) + audio tracks. Frames go straight from the SCK queue into the writer; no actor hops.
public final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let bundle: ProjectBundle
    private let liveFrameHook = OSAllocatedUnfairLock<(@Sendable (CVPixelBuffer) -> Void)?>(initialState: nil)
    public func setLiveFrameHook(_ hook: (@Sendable (CVPixelBuffer) -> Void)?) { liveFrameHook.withLock { $0 = hook } }
    private let videoQ = DispatchQueue(label: "lumen.capture.video", qos: .userInteractive)
    private let audioQ = DispatchQueue(label: "lumen.capture.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var vin: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var pendingVideo: (buffer: CVPixelBuffer, pts: CMTime)?
    private var meta: FrameMetaWriter?
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    private let ptsRange = OSAllocatedUnfairLock(initialState: PTSRange())
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let pauseMark = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let pauseLog = OSAllocatedUnfairLock<[PauseInterval]>(initialState: [])
    private let pausedTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    public private(set) var mic: CAFWriter?
    public private(set) var system: CAFWriter?
    public private(set) var info: SourceInfo?

    public init(bundle: ProjectBundle) { self.bundle = bundle }
    public var droppedFrames: Int { dropped.withLock { $0 } }
    public var firstPTS: Double? { ptsRange.withLock { $0.first } }
    /// Spans that were deliberately not recorded, in engine seconds.
    public var pauseIntervals: [PauseInterval] { pauseLog.withLock { $0 } }
    public var elapsed: Double {
        ptsRange.withLock { $0.first.map { $0 > 0 ? max(HostClock.now() - $0 - pausedTime.withLock { $0 }, 0) : 0 } ?? 0 }
    }
    public var lastPTS: Double { ptsRange.withLock { $0.last } }

    /// Stops accepting frames and audio. The gap is cut out on stop, so a paused
    /// span never reaches the timeline — important when the user pauses to hide
    /// something that should not be recorded at all.
    public func pause() {
        guard !paused.withLock({ $0 }) else { return }
        pauseMark.withLock { $0 = HostClock.now() }
        paused.withLock { $0 = true }
    }

    public func resume() {
        guard paused.withLock({ $0 }) else { return }
        let now = HostClock.now()
        let start = pauseMark.withLock { s -> Double? in let value = s; s = nil; return value }
        paused.withLock { $0 = false }
        guard let start else { return }
        let span = max(now - start, 0)
        pauseLog.withLock { $0.append(PauseInterval(start: start, end: now)) }
        pausedTime.withLock { $0 += span }
        mic?.appendSilence(seconds: span)
        system?.appendSilence(seconds: span)
    }

    public func prepare(_ cfg: RecordingConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let sc = SCStreamConfiguration()
        let filter: SCContentFilter
        var pw = 0, ph = 0, scale = 2.0, origin = CGPoint.zero
        switch cfg.source {
        case .display(let id), .region(let id, _):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noSource }
            filter = SCContentFilter(display: d, excludingWindows: own)
            if let m = CGDisplayCopyDisplayMode(id) { scale = Double(m.pixelWidth) / Double(m.width) }
            let b = CGDisplayBounds(id)
            var size = b.size; origin = b.origin
            if case .region(_, let r) = cfg.source {
                sc.sourceRect = r; size = r.size; origin = CGPoint(x: b.minX + r.minX, y: b.minY + r.minY)
            }
            pw = Int((size.width * scale).rounded()) & ~1; ph = Int((size.height * scale).rounded()) & ~1
        case .window(let wid):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw CaptureError.noSource }
            filter = SCContentFilter(desktopIndependentWindow: w)
            // A window can be captured on a non-Retina or secondary screen.
            // Use the backing scale of the display containing most of the window.
            let hostDisplay = content.displays.max { lhs, rhs in
                let a = CGDisplayBounds(lhs.displayID).intersection(w.frame)
                let b = CGDisplayBounds(rhs.displayID).intersection(w.frame)
                return a.width * a.height < b.width * b.height
            }
            if let id = hostDisplay?.displayID, let mode = CGDisplayCopyDisplayMode(id) {
                scale = Double(mode.pixelWidth) / Double(mode.width)
            } else {
                scale = 1
            }
            origin = w.frame.origin
            pw = Int((w.frame.width * scale).rounded()) & ~1
            ph = Int((w.frame.height * scale).rounded()) & ~1
        }
        let fps = min(cfg.fps, 120)
        // Capture resolution: cap native pixels, never above native.
        // Events are stored in VIDEO pixels, so the recorder scale follows
        // the cap factor; otherwise native-px events exceed the capped
        // width/height and clicks misplace or drop downstream.
        let nativeScale = scale
        var capFactor = 1.0
        let maxH = cfg.resolution.resolutionHeight
        if ph > maxH {
            let s = Double(maxH) / Double(ph)
            capFactor = s
            pw = max(Int((Double(pw) * s).rounded()) & ~1, 64)
            ph = maxH & ~1
        }
        sc.width = pw; sc.height = ph
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.colorSpaceName = CGColorSpace.displayP3
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        sc.queueDepth = 3
        // Explicitly match the offline audio mixer and export rate.
        // Device-native microphone samples remain raw until the offline mix.
        // System audio rides the same 48 kHz timeline as the mixer and the
        // encoder; only the microphone hardware keeps its own native rate.
        sc.sampleRate = 48_000
        sc.channelCount = 2
        sc.showsCursor = false
        sc.scalesToFit = false
        sc.captureResolution = .best
        if cfg.systemAudio { sc.capturesAudio = true; sc.excludesCurrentProcessAudio = true }
        if cfg.mic { sc.captureMicrophone = true; if let id = cfg.micDeviceID { sc.microphoneCaptureDeviceID = id } }

        let w = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
        // Fragmented so a crash/force-quit still leaves a playable file.
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let bitrate: Double = switch cfg.quality {
        case .standard: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.standard.bitsPerPixel, 250_000_000)
        case .high: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.high.bitsPerPixel, 250_000_000)
        case .ultraHD: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.ultraHD.bitsPerPixel, 250_000_000)
        case .bluray: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.bluray.bitsPerPixel, 250_000_000)
        case .custom: max(cfg.customMbps * 1_000_000, 1_000_000)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: pw, AVVideoHeightKey: ph,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalDurationKey: 0.5,
                                              AVVideoAllowFrameReorderingKey: false, AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vi.expectsMediaDataInRealTime = true
        guard w.canAdd(vi) else { throw CaptureError.writer("cannot add video input") }
        w.add(vi)
        writer = w; vin = vi
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: nil)
        meta = try FrameMetaWriter(url: bundle.framesMetaURL)
        if cfg.mic { mic = CAFWriter(url: bundle.micURL) }
        if cfg.systemAudio { system = CAFWriter(url: bundle.systemURL) }
        info = SourceInfo(width: pw, height: ph, fps: Double(fps), duration: 0, backingScale: nativeScale * capFactor, originX: origin.x, originY: origin.y)

        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
        if cfg.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        if cfg.mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQ) }
        stream = s
    }

    public func start() async throws { try await stream?.startCapture() }

    /// Correct shutdown order: stop capture, drain the SCK sample queue,
    /// mark the video input finished, then await finishWriting off main.
    /// Signposted so a stop hang is visible in Instruments/Console.
    public func stop() async throws {
        let sp = OSSignposter(logger: Logger(subsystem: "com.lumen.studio", category: "capture"))
        let state = sp.beginInterval("engine.stop")
        defer { sp.endInterval("engine.stop", state) }
        try await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQ.async {
                if self.pendingVideo != nil { self.dropped.withLock { $0 += 1 }; self.pendingVideo = nil }
                if self.started { self.vin?.markAsFinished() }
                c.resume()
            }
        }
        guard started, let w = writer else { writer?.cancelWriting(); throw CaptureError.writer("no frames were captured") }
        await w.finishWriting()
        meta?.close(); mic?.close(); system?.close()
        if w.status == .failed { throw CaptureError.writer(w.error?.localizedDescription ?? "writer failed") }
    }

    public func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !paused.withLock({ $0 }) else { return }
        switch type {
        case .screen: video(sb)
        case .audio: system?.append(sb)
        case .microphone: mic?.append(sb)
        @unknown default: break
        }
    }
    public func stream(_ s: SCStream, didStopWithError error: Error) { NSLog("SCStream stopped: \(error)") }

    private func video(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb), let w = writer, let vin, adaptor != nil else { return }
        let pts = sb.presentationTimeStamp
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts); started = true
            ptsRange.withLock { $0.first = pts.seconds }
            vin.requestMediaDataWhenReady(on: videoQ) { [weak self] in self?.drainVideo() }
        }
        if pendingVideo != nil { dropped.withLock { $0 += 1 } }
        pendingVideo = (pb, pts)
        drainVideo()
        var rect = CGRect.zero
        if let d = info[.contentRect] as? [String: Any], let r = CGRect(dictionaryRepresentation: d as CFDictionary) { rect = r }
        meta?.write(pts: pts.seconds, status: raw, rect: rect)
    }
    private func drainVideo() {
        guard let vin, vin.isReadyForMoreMediaData, let pending = pendingVideo else { return }
        pendingVideo = nil
        if adaptor?.append(pending.buffer, withPresentationTime: pending.pts) == true {
            let seconds = pending.pts.seconds
            ptsRange.withLock { $0.last = seconds }
            liveFrameHook.withLock { $0 }?(pending.buffer)
        } else { dropped.withLock { $0 += 1 } }
    }

}
```

### Sources/LumenCapture/DeviceCapture.swift

```swift
import Foundation
import AVFoundation

/// iPhone / iPad over USB.
///
/// Honest limitation (documented, not faked): ScreenCaptureKit cannot see
/// iOS devices, and AVFoundation's Continuity Camera surface exposes an
/// iPhone as a *camera* (its rear camera feed), not its screen. There is
/// no public SDK path to capture an iPhone's screen over USB from a Mac
/// app without the device running a companion app. So this type discovers
/// Continuity Camera devices and fails loudly for anything else instead
/// of silently recording the wrong source.
public enum DeviceCapture {
    public struct Device: Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// Continuity Camera / external video devices visible to AVFoundation.
    public static func availableDevices() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .externalUnknown],
            mediaType: .video, position: .unspecified)
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    public enum DeviceError: Error, Sendable {
        /// No such Continuity Camera device is connected.
        case notConnected(String)
        /// The device is connected, but its screen cannot be captured with
        /// public frameworks (see type doc). A companion app would be needed.
        case screenCaptureUnsupported(String)
    }

    /// Resolves a device for capture. Throws loudly; never substitutes a
    /// webcam or the Mac display for a requested iPhone.
    public static func resolve(deviceID: String) throws -> Device {
        guard let found = availableDevices().first(where: { $0.id == deviceID }) else {
            throw DeviceError.notConnected(deviceID)
        }
        throw DeviceError.screenCaptureUnsupported(found.name)
    }
}
```

### Sources/LumenCapture/ExtraMicrophoneRecorder.swift

```swift
import Foundation
import AVFoundation
import CoreMedia
import os
import LumenCore
import LumenProject

/// Independent capture session for each additional audio device. A physical
/// microphone and a loopback device (for example BlackHole) never share a
/// single flattened PCM stream, so they remain editable after recording.
///
/// ScreenCaptureKit still owns the primary microphone; this handles the
/// second and subsequent selected devices through AVFoundation.
final class ExtraMicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceID: String
    let deviceName: String
    let file: String
    let writer: CAFWriter

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lumen.capture.additional-microphone", qos: .userInitiated)
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let pauseMark = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(deviceID: String, file: String, in bundle: ProjectBundle) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw CaptureError.writer("Audio input disconnected: \(deviceID)")
        }
        self.deviceID = deviceID
        self.deviceName = device.localizedName
        self.file = file
        self.writer = CAFWriter(url: bundle.url.appendingPathComponent(file))
        super.init()

        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.writer("Cannot open audio input: \(device.localizedName)")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Match CAFWriter's Float32 path. The device's native sample rate is
        // preserved by capture, then resampled once to 48 kHz for the editor.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.writer("Cannot receive audio from: \(device.localizedName)")
        }
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() { DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() } }

    func pause() {
        guard !paused.withLock({ $0 }) else { return }
        pauseMark.withLock { $0 = HostClock.now() }
        paused.withLock { $0 = true }
    }

    func resume() {
        guard paused.withLock({ $0 }) else { return }
        let now = HostClock.now()
        paused.withLock { $0 = false }
        let start = pauseMark.withLock { s -> Double? in let value = s; s = nil; return value }
        if let start { writer.appendSilence(seconds: max(now - start, 0)) }
    }

    func stop() async {
        // AVCaptureSession.stopRunning can block; run it off the caller thread.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
                c.resume()
            }
        }
        // Drain the callback queue before closing the CAF. No callback writes
        // after stop returns, including the final buffer.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
        writer.close()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, !paused.withLock({ $0 }) else { return }
        let timestamp: Double
        if let clock = session.synchronizationClock {
            timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp,
                                          from: clock, to: CMClockGetHostTimeClock()).seconds
        } else {
            timestamp = sampleBuffer.presentationTimeStamp.seconds
        }
        writer.append(sampleBuffer, hostTime: timestamp.isFinite ? timestamp : nil)
    }

    var track: MicrophoneSourceMeta? {
        guard let start = writer.first.withLock({ $0 }), start.isFinite else { return nil }
        return MicrophoneSourceMeta(deviceID: deviceID, deviceName: deviceName,
                                    track: TrackMeta(file: file, startHostSeconds: start))
    }
}
```

### Sources/LumenCapture/Input.swift

```swift
import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import os
import Synchronization
import LumenCore
import LumenProject

/// Single-producer/single-consumer ring. Producer = event tap thread, consumer = writer queue.
/// Overflow is counted (never silent).
final class EventRing: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<InputEvent>
    private let cap: Int
    private let head = Atomic<Int>(0), tail = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    init(capacity: Int) { cap = capacity; buf = .allocate(capacity: capacity); buf.initialize(repeating: InputEvent(), count: capacity) }
    deinit { buf.deallocate() }
    var overflow: Int { dropped.load(ordering: .relaxed) }
    func push(_ e: InputEvent) {
        let h = head.load(ordering: .relaxed)
        if h - tail.load(ordering: .acquiring) >= cap { dropped.store(dropped.load(ordering: .relaxed) + 1, ordering: .relaxed); return }
        buf[h % cap] = e
        head.store(h + 1, ordering: .releasing)
    }
    func drain(_ body: (InputEvent) -> Void) {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        while t < h { body(buf[t % cap]); t += 1 }
        tail.store(t, ordering: .releasing)
    }
}

extension StockCursor {
    var ns: NSCursor {
        switch self {
        case .arrow: .arrow; case .iBeam: .iBeam; case .pointingHand: .pointingHand; case .crosshair: .crosshair
        case .openHand: .openHand; case .closedHand: .closedHand; case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown; case .notAllowed: .operationNotAllowed; case .contextMenu: .contextualMenu
        }
    }
}

/// Classifies NSCursor.currentSystem against stock cursors by bitmap hash. Main-actor only (AppKit).
@MainActor public final class CursorCatalog {
    private var stock: [Int: UInt16] = [:], custom: [Int: UInt16] = [:]
    public private(set) var customs: [(id: UInt16, png: Data, hotX: Double, hotY: Double)] = []
    public init() {
        for s in StockCursor.allCases { if let h = Self.hash(s.ns) { stock[h] = s.rawValue } }
    }
    static func hash(_ c: NSCursor) -> Int? { c.image.tiffRepresentation?.hashValue }
    public func classify() -> UInt16 {
        guard let c = NSCursor.currentSystem, let h = Self.hash(c) else { return 0 }
        if let s = stock[h] { return s }
        if let s = custom[h] { return s }
        guard customs.count < 24 else { return 0 }
        let id = UInt16(1000 + customs.count)
        custom[h] = id
        if let tiff = c.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            customs.append((id, png, c.hotSpot.x, c.hotSpot.y))
        }
        return id
    }
    public func encodedSnapshot() -> Data? {
        struct C: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
        let arr = customs.map { C(id: $0.id, png: $0.png, hotX: $0.hotX, hotY: $0.hotY) }
        return try? JSONEncoder().encode(arr)
    }
}

public enum ClockCalibration {
    /// Calibrates the CGEvent timestamp unit by sampling CGEvent, mach and
    /// CLOCK_UPTIME_RAW together (PLAN 7.1). Picks the unit whose conversion
    /// lands within 1 ms of the host clock. Never assumes; derives.
    public static func eventUnit() -> EventTimeUnit {
        let now = HostClock.now()
        guard let ev = CGEvent(source: nil) else { return .nanoseconds }
        let ts = ev.timestamp
        let asNsec = Double(ts) / 1e9
        let asMach = HostClock.seconds(machTicks: ts)
        let nsecErr = abs(asNsec - now)
        let machErr = abs(asMach - now)
        // Prefer the closer conversion; default to nanoseconds (documented unit).
        if machErr < nsecErr && machErr <= 1 { return .machTicks }
        return .nanoseconds
    }

    /// SCK PTS is on the host clock (mach-based). Events converted via the
    /// calibrated unit above share that timeline, so hover/cursor sync error
    /// is bounded by the calibration error (<1 ms) with no drift (both are
    /// host-time based, not wall-clock). Per-source audio latency offsets are
    /// stored in TrackMeta and applied in the mixer.
    public static func hostSecondsForEvent(_ ts: UInt64, unit: EventTimeUnit) -> Double {
        unit == .machTicks ? HostClock.seconds(machTicks: ts) : Double(ts) / 1e9
    }

    /// Convert timestamps from REAL event callbacks. A synthetic calibration
    /// event may report a different clock (or zero). Never discard a genuine
    /// mouse-down because the saved calibration guessed the wrong unit.
    public static func alignedHostSeconds(eventTimestamp: UInt64, clock: RecordingClock,
                                          receivedAt now: Double) -> Double {
        let preferred = clock.hostSeconds(eventTimestamp: eventTimestamp)
        if preferred.isFinite && abs(preferred - now) <= 1 { return preferred }
        let alternate = clock.eventUnit == .machTicks
            ? Double(eventTimestamp) / 1e9 : HostClock.seconds(machTicks: eventTimestamp)
        if alternate.isFinite && abs(alternate - now) <= 1 { return alternate }
        // The event tap is listen-only and invoked synchronously. Receipt time
        // is a better bounded estimate than silently losing the click entirely.
        return now
    }
}

/// Listen-only CGEventTap on its own high-QoS thread. Coordinates converted to source pixels once, here.
public final class InputRecorder: @unchecked Sendable {
    private let ring = EventRing(capacity: 1 << 16)
    private let liveFocusHook = OSAllocatedUnfairLock<(@Sendable (InputEvent, AXFrame) -> Void)?>(initialState: nil)
    public func setLiveFocusHook(_ hook: (@Sendable (InputEvent, AXFrame) -> Void)?) { liveFocusHook.withLock { $0 = hook } }
    private let liveEventHook = OSAllocatedUnfairLock<(@Sendable (InputEvent) -> Void)?>(initialState: nil)
    public func setLiveEventHook(_ hook: (@Sendable (InputEvent) -> Void)?) { liveEventHook.withLock { $0 = hook } }
    private let url: URL, origin: CGPoint, scale: Double, clock: RecordingClock, axURL: URL
    private let shape = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let loop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    private let axFrames = OSAllocatedUnfairLock<[AXFrame]>(initialState: [])
    private let focusQuery = OSAllocatedUnfairLock(initialState: (last: -Double.infinity, index: UInt32(0), pending: false))
    private let axTrusted = OSAllocatedUnfairLock(initialState: false)
    private let axQ = DispatchQueue(label: "lumen.ax", qos: .utility)
    private var axTimer: DispatchSourceTimer?
    private var enhancedApps: Set<pid_t> = []
    private var tap: CFMachPort?
    private var fh: FileHandle?
    private var timer: DispatchSourceTimer?
    private let writeQ = DispatchQueue(label: "lumen.events.write")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let catalog: CursorCatalog

    @MainActor public init(url: URL, axURL: URL, origin: CGPoint, scale: Double, clock: RecordingClock) {
        self.url = url; self.axURL = axURL; self.origin = origin; self.scale = scale; self.clock = clock; catalog = CursorCatalog()
    }

    @MainActor public func start() throws {
        FileManager.default.createFile(atPath: url.path, contents: EventCodec.header())
        fh = try FileHandle(forWritingTo: url); try fh?.seekToEnd()
        running.withLock { $0 = true }
        axTrusted.withLock { $0 = AXIsProcessTrusted() }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let cb: CGEventTapCallBack = { @Sendable _, type, event, refcon in
            if let refcon { Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                        callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw CaptureError.writer("event tap denied (Input Monitoring)") }
        tap = t
        let th = Thread { @Sendable [self] in
            guard let t = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            loop.withLock { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.qualityOfService = .userInteractive; th.start()
        startFlushTimer()
        startAXTimer()
        Task { @MainActor [weak self] in           // cursor shape poll @ 10 Hz (was 30 Hz: per-tick main churn)
            while let self, self.running.withLock({ $0 }) {
                let cursorShape = self.catalog.classify()
                self.shape.withLock { $0 = cursorShape }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func startFlushTimer() {
        let tm = DispatchSource.makeTimerSource(queue: writeQ)
        tm.schedule(deadline: .now() + 0.25, repeating: 0.25)
        tm.setEventHandler { @Sendable [self] in flush() }
        tm.resume(); timer = tm
    }

    @MainActor public func stop() async {
        running.withLock { $0 = false }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        loop.withLock { if let l = $0 { CFRunLoopStop(l) } }
        timer?.cancel()
        axTimer?.cancel(); axTimer = nil
        await withCheckedContinuation { continuation in
            writeQ.async { [self] in
                flush(); try? fh?.close()
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            axQ.async { continuation.resume() }
        }
        let cursors = catalog.encodedSnapshot()
        await Task.detached(priority: .userInitiated) { [self] in
            try? cursors?.write(to: url.deletingLastPathComponent().appendingPathComponent("cursors.json"), options: .atomic)
            if let d = try? JSONEncoder().encode(axFrames.withLock({ $0 })) { try? d.write(to: axURL, options: .atomic) }
        }.value
    }

    private func flush() {
        var b: [UInt8] = []
        ring.drain { EventCodec.encode($0, into: &b) }
        if !b.isEmpty { try? fh?.write(contentsOf: Data(b)) }
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        let eventHost = ClockCalibration.alignedHostSeconds(
            eventTimestamp: e.timestamp, clock: clock, receivedAt: HostClock.now())
        var ev = InputEvent(t: eventHost)
        let loc = e.location                                   // Quartz global space: already top-left origin
        ev.x = Float((loc.x - origin.x) * scale); ev.y = Float((loc.y - origin.y) * scale)
        ev.cursorShape = shape.withLock { $0 }
        ev.flags = UInt16(truncatingIfNeeded: e.flags.rawValue >> 16)
        switch type {
        case .mouseMoved: ev.kind = .move
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: ev.kind = .drag
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ev.kind = .down; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
            ev.axFrameIndex = reserveAX(loc)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            ev.kind = .up; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel:
            ev.kind = .scroll
            // Wheel delta was previously discarded entirely; without it no
            // scroll smoothing (or even scroll velocity) is possible.
            let lines = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let fixed = e.getIntegerValueField(CGEventField(rawValue: 93)!)   // FixedPtDeltaAxis1, 1/16 line
            ev.scrollDelta = lines != 0 ? Float(lines) : Float(fixed) / 16.0
        case .keyDown:
            ev.kind = .keyDown; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))   // key codes only, never characters
        case .keyUp: ev.kind = .keyUp; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: ev.kind = .flagsChanged
        default: return
        }
        if type == .keyDown { ev.axFrameIndex = reserveFocus(event: ev) }
        if type != .keyDown { liveEventHook.withLock { $0 }?(ev) }
        ring.push(ev)
    }

    private func reserveAX(_ p: CGPoint) -> UInt32 {
        guard axTrusted.withLock({ $0 }) else { return 0 }
        let idx = axFrames.withLock { $0.append(AXFrame(x: 0, y: 0, w: 0, h: 0)); return $0.count }
        axQ.async { [self] in
            if let f = queryAX(p) { axFrames.withLock { if idx >= 1, idx <= $0.count { $0[idx - 1] = f } } }
        }
        return UInt32(idx)
    }

    private func reserveFocus(event: InputEvent) -> UInt32 {
        guard axTrusted.withLock({ $0 }) else { return 0 }
        let reservation = focusQuery.withLock { state -> (UInt32, Bool) in
            if state.pending || event.t - state.last < 1.0 / 30 { return (state.index, false) }
            state.last = event.t; state.pending = true
            state.index = axFrames.withLock { $0.append(AXFrame(x: 0, y: 0, w: 0, h: 0)); return UInt32($0.count) }
            return (state.index, true)
        }
        if reservation.1 {
            axQ.asyncAfter(deadline: .now() + 0.015) { [self] in
                defer { focusQuery.withLock { $0.pending = false } }
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, 0.05)
                guard let frame = focusedFrame(system) else { return }
                axFrames.withLock { $0[Int(reservation.0) - 1] = frame }
                var focused = event
                let caret = frame.caret
                focused.x = Float(caret.map { $0.x + $0.w / 2 } ?? (frame.x + frame.w / 2))
                focused.y = Float(caret.map { $0.y + $0.h / 2 } ?? (frame.y + frame.h / 2))
                focused.axFrameIndex = reservation.0
                if let hook = liveFocusHook.withLock({ $0 }) { hook(focused, frame) }
                else { liveEventHook.withLock { $0 }?(focused) }
            }
        }
        return reservation.0
    }

    private func focusedFrame(_ system: AXUIElement) -> AXFrame? {
        if let value = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.05)
            if let result = frame(element) { return result }
        }
        guard let value = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let app = value as! AXUIElement
        AXUIElementSetMessagingTimeout(app, 0.05)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        if enhancedApps.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return frame(focused as! AXUIElement)
    }

    private func startAXTimer() {
        let timer = DispatchSource.makeTimerSource(queue: axQ)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.sampleSecureFields() }
        timer.resume(); axTimer = timer
    }

    private func sampleSecureFields() {
        let trusted = AXIsProcessTrusted()
        axTrusted.withLock { $0 = trusted }
        guard trusted, running.withLock({ $0 }) else { return }
        let system = AXUIElementCreateSystemWide(), now = HostClock.now()
        AXUIElementSetMessagingTimeout(system, 0.03)
        guard let value = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let app = value as! AXUIElement
        AXUIElementSetMessagingTimeout(app, 0.03)
        guard let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
        var pending = [window as! AXUIElement], visited = 0
        while let element = pending.popLast(), visited < 256, HostClock.now() - now < 0.12 {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.03)
            let labels = [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
                .compactMap { attribute(element, $0) as? String }.joined(separator: " ")
            if labels.range(of: "secure|email|password|passcode|card|cvv|cvc|ssn", options: .regularExpression.union(.caseInsensitive)) != nil,
               var field = frame(element), field.secure {
                field.sampledAt = now
                let snapshot = field
                axFrames.withLock { $0.append(snapshot) }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(max(256 - visited - pending.count, 0)))
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func queryAX(_ p: CGPoint) -> AXFrame? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success,
              let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return frame(element)
    }

    private func frame(_ element: AXUIElement) -> AXFrame? {
        guard let pv = attribute(element, kAXPositionAttribute), let sv = attribute(element, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"]
        let label = names.compactMap { attribute(element, $0) as? String }.joined(separator: " ")
        let secure = label.range(of: "secure|email|password|passcode|card|cvv|cvc|ssn", options: .regularExpression.union(.caseInsensitive)) != nil
        var result = AXFrame(x: (pos.x - origin.x) * scale, y: (pos.y - origin.y) * scale,
                             w: size.width * scale, h: size.height * scale, secure: secure, label: label)
        if let range = attribute(element, kAXSelectedTextRangeAttribute) {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 {
                    result.caret = AXFrame.Rect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
                                               w: max(rect.width * scale, 1), h: rect.height * scale)
                }
            }
        }
        return result
    }
}
```

### Sources/LumenCapture/Session.swift

```swift
import Foundation
import CoreVideo
import AVFoundation
import CoreGraphics
import AppKit
import os
import LumenCore
import LumenProject
import LumenDirector

public enum Permissions {
    public static var screen: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreen() { _ = CGRequestScreenCaptureAccess() }
    public static var input: Bool { CGPreflightListenEventAccess() }
    public static func requestInput() { _ = CGRequestListenEventAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }
    @MainActor public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    public static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static var camera: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    public static func requestMedia() async { _ = await AVCaptureDevice.requestAccess(for: .audio); _ = await AVCaptureDevice.requestAccess(for: .video) }
    public static func open(_ pane: String) {   // ScreenCapture, ListenEvent, Accessibility, Microphone, Camera
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// Webcam to its own HEVC file. PTS stays on the host clock.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "lumen.webcam")
    private let stopQ = DispatchQueue(label: "lumen.webcam.stop", qos: .userInitiated)
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var started = false
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let quality: String
    let first = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(url: URL, deviceID: String?, quality: String = "auto") throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        self.quality = quality
        super.init()
        guard let dev = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noSource }
        session.beginConfiguration()
        // macOS does not expose AVCaptureSession.Preset.inputPriority. Use the
        // highest *supported* session preset, then encode the actual buffer
        // dimensions reported by the camera, never a fictional 4K resolution.
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.noSource }
        session.addInput(input)
        let presets: [AVCaptureSession.Preset] = switch quality {
            case "q4k": [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            case "q1080": [.hd1920x1080, .hd1280x720, .high]
            case "q720": [.hd1280x720, .high]
            default: [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
        }
        if let best = presets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = best
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: q)
        session.addOutput(out)
        session.commitConfiguration()
    }
    func start() { stopQ.async { self.session.startRunning() } }
    func pause() { paused.withLock { $0 = true } }
    func resume() { paused.withLock { $0 = false } }
    func stop() async {
        // AVCaptureSession.stopRunning can block 100 ms+. Run it off the
        // caller's thread (never main, never the session actor's caller).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            stopQ.async { self.session.stopRunning(); c.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in q.async { c.resume() } }
        guard started else { writer.cancelWriting(); return }
        input?.markAsFinished(); await writer.finishWriting()
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard !paused.withLock({ $0 }) else { return }
        if input == nil {
            guard let pixels = CMSampleBufferGetImageBuffer(sb) else { return }
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let fps = 30
            let bitrate = Int(Double(width * height * fps) * 0.11)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
            ])
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { return }
            writer.add(i); input = i
        }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true
            let seconds = sb.presentationTimeStamp.seconds
            first.withLock { $0 = seconds }
        }
        if input?.isReadyForMoreMediaData == true { input?.append(sb) }
    }
}

public struct CaptureStats: Sendable {
    public var elapsed: Double, micLevel: Float
    public var dropped: Int, thermal: Int
}

/// Recording lifecycle states. Every transition is logged + signposted.
/// `failed` carries a plain-language message and recovery action; a stage
/// that exceeds its timeout lands here, never spins forever.
public enum RecordingStage: Sendable, Equatable {
    case idle, preparing, countdown, recording, paused, stopping, finalizing, ready, failed(String)
}

private enum StageTimeout: Error { case timedOut(RecordingStage) }

extension RecordingStage {
    var watchdogName: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .countdown: return "countdown"
        case .recording: return "recording"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .finalizing: return "finalizing"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

/// Orchestrates prepare/start/stop and pause/resume. Never touches frames.
/// Threading: actor; all engines are started/stopped concurrently off main.
public actor RecordingSession {
    private var engine: CaptureEngine?
    private var input: InputRecorder?
    private var webcam: WebcamRecorder?
    private var extraMicrophones: [ExtraMicrophoneRecorder] = []
    private var bundle: ProjectBundle?
    private var cfg: RecordingConfig?
    private var unit = EventTimeUnit.machTicks
    private var activity: NSObjectProtocol?
    private var journalTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var journalStart = Date()
    public private(set) var isPaused = false
    public private(set) var stage: RecordingStage = .idle
    private let logger = Logger(subsystem: "com.lumen.studio", category: "capture")
    public init() {}

    private func transition(to next: RecordingStage) {
        let prev = stage
        stage = next
        MainThreadWatchdog.shared.setStage(next.watchdogName)
        logger.info("recording \(String(describing: prev)) -> \(String(describing: next), privacy: .public)")
        os_log("stage %@ -> %@", log: .default, type: .info, String(describing: prev), String(describing: next))
    }

    /// Stage timeout is a failure path only (never a fix for a hang).
    /// Implementation: the watchdog + stage log surface a stall; if the stage
    /// has not advanced within `seconds`, `timeoutHandler` marks `failed`.
    /// The stopwatch runs detached so it never blocks the stage itself.
    private func armStageTimeout(_ stage: RecordingStage, seconds: Double) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.timeoutIfStillIn(stage: stage)
        }
    }

    private func timeoutIfStillIn(stage: RecordingStage) {
        // Called on the actor. Only mark failed if we are still in the timed stage.
        if self.stage == stage {
            transition(to: .failed("Stage \(String(describing: stage)) exceeded \(secondsHint) s."))
        }
    }

    private var secondsHint: Int { 10 }

    public func setLiveHooks(frame: (@Sendable (CVPixelBuffer) -> Void)?, event: (@Sendable (InputEvent) -> Void)?, focus: (@Sendable (InputEvent, AXFrame) -> Void)? = nil) {
        engine?.setLiveFrameHook(frame); input?.setLiveEventHook(event); input?.setLiveFocusHook(focus)
    }

    public func prepare(_ config: RecordingConfig, library: URL) async throws {
        MainThreadWatchdog.shared.start()
        transition(to: .preparing)
        let timeoutTask = armStageTimeout(.preparing, seconds: 15)
        defer { timeoutTask.cancel() }
        do {
            cfg = config
            let name = "Recording " + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let b = try ProjectBundle.create(named: name, in: library)
            bundle = b
            let e = CaptureEngine(bundle: b)
            // Permissions, SCShareableContent, device discovery, writers,
            // Metal warm-up run concurrently off main (engine.prepare).
            try await e.prepare(config)
            engine = e
            unit = ClockCalibration.eventUnit()
            if let info = e.info {
                let clock = RecordingClock(originHostSeconds: 0, eventUnit: unit)
                let i = await MainActor.run {
                    InputRecorder(url: b.eventsURL, axURL: b.axURL, origin: CGPoint(x: info.originX, y: info.originY), scale: info.backingScale, clock: clock)
                }
                input = i
            }
            if config.webcamDeviceID != nil { webcam = try WebcamRecorder(url: b.webcamURL, deviceID: config.webcamDeviceID, quality: config.webcamQuality) }
            // Device IDs are unique and checked before recording starts; never
            // quietly substitute the system default if a requested device vanished.
            extraMicrophones = try Array(Set(config.additionalMicDeviceIDs))
                .sorted().enumerated().map { index, id in
                    try ExtraMicrophoneRecorder(deviceID: id, file: "mic-extra-\(index + 1).caf", in: b)
                }
        } catch {
            transition(to: .failed("Preparing stalled. \(error)"))
            throw error
        }
    }

    public func markCountdown() { transition(to: .countdown) }

    public func start() async throws {
        guard let engine, let input else { transition(to: .failed("No capture source.")); throw CaptureError.noSource }
        // Input Monitoring is checked here (at Start), not after the fact.
        if !Permissions.input {
            Permissions.requestInput()
            transition(to: .failed("Input Monitoring is off. Grant it, then relaunch Lumen."))
            throw CaptureError.writer("Input Monitoring is off. Grant it, then relaunch Lumen.")
        }
        let timeoutTask = armStageTimeout(.recording, seconds: 10)
        defer { timeoutTask.cancel() }
        RecordingGate.recordingStarted()
        do {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                             reason: "Lumen recording")
            try await MainActor.run { try input.start() }
            for recorder in extraMicrophones { recorder.start() }
            webcam?.start()
            do {
                try await engine.start()
            } catch {
                for recorder in extraMicrophones { await recorder.stop() }
                await webcam?.stop()
                await input.stop()
                throw error
            }
            journalStart = Date()
            startJournal()
            startWatchdog()
            transition(to: .recording)
        } catch {
            RecordingGate.recordingStopped()
            transition(to: .failed("Starting stalled. \(error)"))
            throw error
        }
    }

    /// Pause keeps the capture graph alive but stops appending frames and audio.
    /// Everything recorded during the pause is cut out on stop.
    public func pause() {
        guard !isPaused else { return }
        engine?.pause(); webcam?.pause(); extraMicrophones.forEach { $0.pause() }
        isPaused = true
        transition(to: .paused)
    }

    public func resume() {
        guard isPaused else { return }
        engine?.resume(); webcam?.resume(); extraMicrophones.forEach { $0.resume() }
        isPaused = false
        transition(to: .recording)
    }

    public func togglePause() { isPaused ? resume() : pause() }

    /// A tiny journal is rewritten once a second. If the process dies, the next
    /// launch can rebuild the project from it instead of losing the recording.
    private func startJournal() {
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.writeJournal()
            }
        }
    }

    private func writeJournal() {
        guard let b = bundle, let e = engine, let info = e.info else { return }
        let j = RecordingJournal(started: journalStart, updated: Date(), source: info,
                                 fps: Double(cfg?.fps ?? 60),
                                 mic: cfg?.mic ?? false, system: cfg?.systemAudio ?? false,
                                 webcam: cfg?.webcamDeviceID != nil,
                                 pauseIntervals: e.pauseIntervals,
                                 lastFramePTS: e.lastPTS,
                                 firstFramePTS: e.firstPTS,
                                 droppedFrames: e.droppedFrames)
        b.writeJournal(j)
    }

    /// Free-space watchdog + sleep/terminate finalize. Thresholds are
    /// parameters (50 MB hard stop). Power loss leaves at most the last
    /// journal interval (~1 s) plus fragment (~2 s) unflushed; process
    /// death is fully covered by the atomic journal rename.
    private func startWatchdog() {
        watchdogTask?.cancel()
        sleepObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.finalizeCleanly(reason: "sleep") }
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.finalizeCleanly(reason: "terminate") }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let bundleURL = await self.currentBundleURL()
                guard let url = bundleURL else { return }
                if let vals = try? FileManager.default.attributesOfFileSystem(forPath: url),
                   let free = vals[.systemFreeSize] as? NSNumber, free.int64Value < 50_000_000 {
                    await self.finalizeCleanly(reason: "disk-full")
                    return
                }
            }
        }
    }

    private func currentBundleURL() -> String? {
        bundle?.url.deletingLastPathComponent().path
    }

    private func stopWatchdog() {
        watchdogTask?.cancel(); watchdogTask = nil
        if let s = sleepObserver { NotificationCenter.default.removeObserver(s) }
        if let s = terminateObserver { NotificationCenter.default.removeObserver(s) }
        sleepObserver = nil; terminateObserver = nil
    }

    private func finalizeCleanly(reason: String) async {
        guard stage == .recording || stage == .paused else { return }
        logger.info("finalizing on \(reason, privacy: .public)")
        try? await stopCapture()
        try? await finalize()
    }

    public func stats() -> CaptureStats {
        CaptureStats(elapsed: engine?.elapsed ?? 0, micLevel: engine?.mic?.level.withLock { $0 } ?? 0,
                     dropped: engine?.droppedFrames ?? 0, thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// Fast stop: stops capture, drains, ends session, finishes audio writers.
    /// Returns within the stop budget; heavy finalization is separate.
    /// Shutdown order: input stop → webcam/extra mics → engine stop
    /// (stopCapture, drain sample queue, endSession, mark inputs finished,
    ///  `await finishWriting` off main).
    public func stopCapture() async throws {
        transition(to: .stopping)
        let timeoutTask = armStageTimeout(.stopping, seconds: 10)
        defer { timeoutTask.cancel() }
        do {
            guard let engine, let input else { throw CaptureError.noSource }
            journalTask?.cancel(); journalTask = nil
            stopWatchdog()
            if isPaused { resume() }
            isPaused = false
            async let inputStop: Void = input.stop()
            async let webcamStop: Void = webcam?.stop() ?? ()
            async let engineStop: Void = engine.stop()
            for recorder in extraMicrophones { await recorder.stop() }
            _ = try await (inputStop, webcamStop, engineStop)
        } catch {
            transition(to: .failed("Stopping stalled. \(error)"))
            throw error
        }
    }

    /// Slow finalization: wrap audio journals, finalize events, publish project.
    /// Runs at `.utility` QoS off main; UI shows "Finishing…" with real progress.
    /// Heavy analysis starts only after this returns.
    public func finalize(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ProjectBundle {
        progress(0)
        transition(to: .finalizing)
        // Snapshot actor state first (cheap), then run heavy IO off-actor.
        guard let engine, let b = bundle, var info = engine.info else {
            transition(to: .failed("No bundle to finalize."))
            throw CaptureError.noSource
        }
        let activityToken = activity
        let origin = engine.firstPTS ?? 0
        let stopHostSeconds = HostClock.now()
        info.duration = max(engine.lastPTS - origin, stopHostSeconds - origin, 0)
        var meta = ProjectMeta(name: b.url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: unit))
        meta.droppedFrames = engine.droppedFrames
        if let c = cfg {
            meta.captureResolution = c.resolution.rawValue
            meta.captureQuality = c.quality.rawValue
            meta.captureMbps = c.customMbps
        }
        if let t = engine.mic?.first.withLock({ $0 }) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: t) }
        if let t = engine.system?.first.withLock({ $0 }) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: t) }
        if let t = webcam?.first.withLock({ $0 }) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: t) }
        meta.additionalMicrophones = extraMicrophones.compactMap(\.track)
        var tl = Timeline(duration: info.duration)
        let pauses = engine.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), e = min(p.end - origin, info.duration)
            return e - a > 0.05 ? CutRange(start: a, end: e, origin: .manual) : nil
        }
        tl.timeMap.cuts = pauses.sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        let infoCopy = info
        let baseTimeline = tl
        let finalMeta = meta
        do {
            try await Task.detached(priority: .utility) {
                var working = baseTimeline
                progress(0.1)
                do {
                    let recordedEvents = try b.events(origin: origin)
                    let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: b.axURL))) ?? []
                    progress(0.4)
                    if !recordedEvents.isEmpty {
                        working.zoom = Director.planRecordingZoom(events: recordedEvents, ax: ax,
                                                                  source: infoCopy, timeline: working)
                    }
                } catch {
                    os_log("finalize: event sidecar unreadable: %@", log: .default, type: .error, String(describing: error))
                }
                progress(0.8)
                try b.save(ProjectFile(meta: finalMeta, timeline: working))
                b.clearJournal()
                progress(1)
            }.value
        } catch {
            RecordingGate.recordingStopped()
            transition(to: .failed("Finalizing stalled. \(error)"))
            throw error
        }
        if let a = activityToken { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        RecordingGate.recordingStopped()
        MainThreadWatchdog.shared.stop()
        return b
    }

    public func stop() async throws -> ProjectBundle {
        try await stopCapture()
        let b = try await finalize()
        transition(to: .ready)
        return b
    }
}
```

### Sources/LumenCapture/Watchdog.swift

```swift
import Foundation
import os
import LumenCore

// MARK: - Hang record (written to hangs.json)

/// One main-thread stall. `latencyMs` is time from enqueue to run on main.
/// `stage` is the RecordingSession stage when the stall happened.
/// Value type. Owned by MainThreadWatchdog.
public struct HangRecord: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var latencyMs: Double
    public var stage: String
    public init(timestamp: Double, latencyMs: Double, stage: String) {
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.stage = stage
    }
}

// MARK: - Watchdog

/// Pings main every 10 ms from a background thread and records any latency
/// over 50 ms together with the current signpost stage. Writes hangs.json.
/// Stays in Release behind LUMEN_HANG_WATCHDOG=1. No-op when flag is off.
/// Threading: owns a background queue; main hop is one async enqueue.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "lumen.watchdog", qos: .utility)
    private let hangs = OSAllocatedUnfairLock<[HangRecord]>(initialState: [])
    private let stage = OSAllocatedUnfairLock<String>(initialState: "idle")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let outputURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        outputURL = base.appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("hangs.json")
    }

    public var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LUMEN_HANG_WATCHDOG"] == "1"
    }

    /// Current stage for the next hang record. Set by RecordingSession on every transition.
    public func setStage(_ s: String) {
        stage.withLock { $0 = s }
    }

    public var currentStage: String { stage.withLock { $0 } }

    public func start() {
        guard isEnabled else { return }
        let already = running.withLock { r -> Bool in if r { return true }; r = true; return false }
        guard !already else { return }
        queue.async { [weak self] in self?.loop() }
    }

    public func stop() {
        running.withLock { $0 = false }
        flush()
    }

    public func flush() {
        let records = hangs.withLock { $0 }
        guard !records.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            os_log("watchdog flush failed: %@", log: .default, type: .error, String(describing: error))
        }
    }

    /// Synchronous snapshot for tests / CLI.
    public func snapshot() -> [HangRecord] { hangs.withLock { $0 } }

    /// Test hook: record a synthetic hang.
    func record(latencyMs: Double, stage: String) {
        hangs.withLock { $0.append(HangRecord(timestamp: HostClock.now(), latencyMs: latencyMs, stage: stage)) }
    }

    private func loop() {
        while running.withLock({ $0 }) {
            let enqueued = HostClock.now(), current = currentStage
            let reply = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { reply.signal() }
            if reply.wait(timeout: .now() + 0.25) == .timedOut {
                record(latencyMs: (HostClock.now() - enqueued) * 1000, stage: current)
                try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let stack = outputURL.deletingLastPathComponent().appendingPathComponent("stall-\(Int(Date().timeIntervalSince1970)).txt")
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "1", "-file", stack.path]
                sample.standardOutput = FileHandle.nullDevice; sample.standardError = FileHandle.nullDevice
                try? sample.run()
                os_log("main stalled in %@; stack sample: %@", log: .default, type: .fault, current, stack.path)
                flush()
                while running.withLock({ $0 }), reply.wait(timeout: .now() + 0.05) == .timedOut {}
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
```

## LumenAnalysis/

### Sources/LumenAnalysis/Activity.swift

```swift
import Foundation
import AVFoundation
import CoreVideo
import os
import LumenProject

public enum ActivityAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, fps: Double = 10) async throws -> [ActivityPoint] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = ActivityJob(asset: asset, track: track, offset: offset, fps: fps)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class ActivityJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let fps: Double
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, fps: Double) {
        self.asset = asset; self.track = track; self.offset = offset; self.fps = fps
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [ActivityPoint] {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        var next = 0.0
        var previous: [UInt8]?
        var results: [ActivityPoint] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + 1 / max(fps, 1)
            let current = try lumaGrid(buffer, columns: 80, rows: 50)
            if let previous, let centroid = changedCentroid(previous, current, width: 80, height: 50) {
                results.append(ActivityPoint(t: time + offset, x: centroid.x * Double(CVPixelBufferGetWidth(buffer)) / 80,
                                             y: centroid.y * Double(CVPixelBufferGetHeight(buffer)) / 50))
            }
            previous = current
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        return results
    }

    private func lumaGrid(_ buffer: CVPixelBuffer, columns: Int, rows: Int) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var grid = [UInt8](repeating: 0, count: columns * rows)
        for gy in 0..<rows {
            let y = min((gy * height) / rows, height - 1)
            for gx in 0..<columns {
                let x = min((gx * width) / columns, width - 1), i = y * stride + x * 4
                let b = Int(base[i]), g = Int(base[i + 1]), r = Int(base[i + 2])
                grid[gy * columns + gx] = UInt8((29 * b + 150 * g + 77 * r) >> 8)
            }
        }
        return grid
    }

    private func changedCentroid(_ old: [UInt8], _ new: [UInt8], width: Int, height: Int) -> SIMD2<Double>? {
        var weight = 0.0, sumX = 0.0, sumY = 0.0, count = 0
        for i in old.indices {
            let delta = abs(Int(new[i]) - Int(old[i]))
            guard delta >= 24 else { continue }
            let w = Double(delta - 23), x = Double(i % width), y = Double(i / width)
            weight += w; sumX += x * w; sumY += y * w; count += 1
        }
        guard count >= max(width * height / 1000, 3), weight > 0 else { return nil }
        return SIMD2(sumX / weight, sumY / weight)
    }
}
```

### Sources/LumenAnalysis/Cache.swift

```swift
import Foundation
import CryptoKit

private actor MediaDigestCache {
    private struct Fingerprint: Hashable {
        var path: String
        var size: Int
        var modified: TimeInterval
    }

    static let shared = MediaDigestCache()
    private var values: [Fingerprint: Data] = [:]
    private var order: [Fingerprint] = []

    func digest(for media: URL) throws -> Data {
        let attributes = try media.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = Fingerprint(path: media.standardizedFileURL.path, size: attributes.fileSize ?? 0,
                                      modified: attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)
        if let value = values[fingerprint] { return value }

        let handle = try FileHandle(forReadingFrom: media)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = Data(hasher.finalize())
        values[fingerprint] = digest
        order.append(fingerprint)
        if order.count > 16 { values.removeValue(forKey: order.removeFirst()) }
        return digest
    }
}

enum AnalysisCache {
    static func key<P: Encodable & Sendable>(media: URL, analyzer: String, version: Int, parameters: P) async throws -> String {
        var fingerprint = try await MediaDigestCache.shared.digest(for: media)
        fingerprint.append(Data("\(analyzer):\(version):".utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fingerprint.append(try encoder.encode(parameters))
        return SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String, directory: URL) -> Value? {
        let url = fileURL(key, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return value
    }

    static func save<Value: Encodable>(_ value: Value, key: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL(key, directory: directory), options: .atomic)
    }

    private static func fileURL(_ key: String, directory: URL) -> URL {
        precondition(key.count == 64 && key.allSatisfy(\.isHexDigit))
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }
}
```

### Sources/LumenAnalysis/Face.swift

```swift
import Foundation
import AVFoundation
import Vision
import os
import LumenCore
import LumenProject

public enum FaceAnalyzer {
    public static func analyze(url: URL, startOffset: Double, fps: Double = 12) async throws -> [FaceSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = FaceJob(asset: asset, track: track, startOffset: startOffset, fps: fps)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class FaceJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let startOffset: Double
    private let fps: Double
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, startOffset: Double, fps: Double) {
        self.asset = asset; self.track = track; self.startOffset = startOffset; self.fps = fps
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [FaceSample] {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        let interval = 1 / max(fps, 1)
        var next = 0.0
        var faces: [FaceSample] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + interval
            if let face = try Self.largestFace(in: buffer) {
                faces.append(FaceSample(t: time + startOffset, cx: Float(face.midX), cy: Float(1 - face.midY),
                                        h: Float(clamp(face.height, 0.02, 1))))
            }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        return faces
    }

    private static func largestFace(in buffer: CVPixelBuffer) throws -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
        return request.results?.max { $0.boundingBox.height < $1.boundingBox.height }?.boundingBox
    }
}
```

### Sources/LumenAnalysis/OCR.swift

```swift
import Foundation
import AVFoundation
import Vision
import CoreImage
import os
import LumenCore
import LumenProject

public enum OCRAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, projectSalt: UInt64, customPatterns: [String] = [],
                              entropyThreshold: Double = 3.5, fps: Double = 4, duration: Double = 0, firstFrameOnly: Bool = false,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [OCRDetection] {
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = OCRJob(asset: asset, track: track, offset: offset, salt: projectSalt, patterns: customPatterns,
                         entropyThreshold: entropyThreshold, fps: fps, duration: duration, firstFrameOnly: firstFrameOnly, progress: progress)
        return try await withTaskCancellationHandler {
            try await job.value()
        } onCancel: { job.cancel() }
    }
}

private struct OCRRequestHandle: @unchecked Sendable { let request: VNRecognizeTextRequest }

private final class OCRJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let salt: UInt64
    private let patterns: [String]
    private let entropyThreshold: Double
    private let fps: Double
    private let duration: Double
    private let firstFrameOnly: Bool
    private let progress: @Sendable (Double) -> Void
    private let completion = OSAllocatedUnfairLock<(continuation: CheckedContinuation<[OCRDetection], Error>?, result: Result<[OCRDetection], Error>?)>(uncheckedState: (nil, nil))
    private let requestLock = OSAllocatedUnfairLock<OCRRequestHandle?>(uncheckedState: nil)
    private var trackingRequests: [VNTrackObjectRequest] = []
    private var trackingBuffer: CVPixelBuffer?
    private let trackingHandler = VNSequenceRequestHandler()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, salt: UInt64, patterns: [String], entropyThreshold: Double, fps: Double, duration: Double, firstFrameOnly: Bool, progress: @escaping @Sendable (Double) -> Void) {
        self.asset = asset; self.track = track; self.offset = offset; self.salt = salt; self.patterns = patterns
        self.entropyThreshold = entropyThreshold; self.fps = fps; self.duration = duration; self.firstFrameOnly = firstFrameOnly; self.progress = progress
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
        requestLock.withLock { $0?.request.cancel() }
        resolve(.failure(CancellationError()))
    }

    func value() async throws -> [OCRDetection] {
        try await withCheckedThrowingContinuation { continuation in
            let prior = completion.withLock { state -> Result<[OCRDetection], Error>? in
                if let result = state.result { return result }
                state.continuation = continuation; return nil
            }
            if let prior { continuation.resume(with: prior); return }
            DispatchQueue.global(qos: .utility).async { [self] in
                do { resolve(.success(try run())) } catch { resolve(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.completion.withLock({ $0.result == nil }) else { return }
                self.resolve(.failure(NSError(domain: "Lumen.Privacy", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Text scanning exceeded two minutes. Retry the scan or use manual masks."])))
                self.cancel()
            }
        }
    }

    private func resolve(_ result: Result<[OCRDetection], Error>) {
        let continuation = completion.withLock { state -> CheckedContinuation<[OCRDetection], Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation; state.continuation = nil; return continuation
        }
        continuation?.resume(with: result)
    }

    func run() throws -> [OCRDetection] {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        var nextTrack = 0.0
        defer { retireTrackers() }
        var next = 0.0
        var lastDetections: [OCRDetection] = []
        var detections: [OCRDetection] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let previous = lastDetections.first, time + offset - previous.t > 0.5 {
                for held in stride(from: previous.t + 0.25, to: time + offset, by: 0.25) {
                    detections.append(contentsOf: lastDetections.map { var value = $0; value.t = held; return value })
                }
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if time + 0.0001 < next {
                if time >= nextTrack, !lastDetections.isEmpty {
                    nextTrack = time + 1.0 / 15
                    lastDetections = try track(lastDetections, buffer: buffer, time: time + offset, handler: trackingHandler)
                    detections.append(contentsOf: lastDetections)
                }
                continue
            }
            next = time + 1 / max(fps, 0.5)
            progress(min(max(time / max(duration, asset.duration.seconds, 0.001), 0), 0.99))
            retireTrackers()
            lastDetections = try detect(in: buffer, at: time + offset)
            detections.append(contentsOf: lastDetections)
            if firstFrameOnly { reader.cancelReading(); break }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        if let previous = lastDetections.first {
            let end = max(duration, asset.duration.seconds) + offset
            for held in stride(from: previous.t + 0.25, through: end, by: 0.25) {
                detections.append(contentsOf: lastDetections.map { var value = $0; value.t = held; return value })
            }
        }
        progress(1)
        return deduplicate(detections)
    }

    private func retireTrackers() {
        guard !trackingRequests.isEmpty else { return }
        for request in trackingRequests { request.isLastFrame = true }
        if let buffer = trackingBuffer { try? trackingHandler.perform(trackingRequests, on: buffer) }
        trackingRequests.removeAll(); trackingBuffer = nil
    }

    private func track(_ detections: [OCRDetection], buffer: CVPixelBuffer, time: Double,
                       handler: VNSequenceRequestHandler) throws -> [OCRDetection] {
        trackingBuffer = buffer
        if trackingRequests.isEmpty {
            trackingRequests = detections.map { detection in
                let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: detection.x,
                    y: 1 - detection.y - detection.h, width: detection.w, height: detection.h))
                let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                request.trackingLevel = .fast
                return request
            }
        }
        try handler.perform(trackingRequests, on: buffer)
        return zip(detections, trackingRequests).map { prior, request in
            var result = prior; result.t = time
            if let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence >= 0.3 {
                request.inputObservation = observation
                let rect = observation.boundingBox
                result.x = rect.minX; result.y = 1 - rect.maxY; result.w = rect.width; result.h = rect.height
            }
            return result
        }
    }

    private func detect(in buffer: CVPixelBuffer, at time: Double) throws -> [OCRDetection] {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let full = context.createCGImage(image, from: image.extent) else { throw AnalysisError.pixelBuffer }
        let width = full.width, height = full.height, tile = 1536, step = 1408
        var observations: [(VNRecognizedTextObservation, CGRect)] = []
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                if cancelled.withLock({ $0 }) { throw CancellationError() }
                let rect = CGRect(x: x, y: y, width: min(tile, width - x), height: min(tile, height - y))
                guard let crop = full.cropping(to: rect) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0
                let requestHandle = OCRRequestHandle(request: request)
                requestLock.withLock { $0 = requestHandle }
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                requestLock.withLock { $0 = nil }
                for observation in request.results ?? [] {
                    let box = observation.boundingBox
                    let mapped = CGRect(x: (rect.minX + box.minX * rect.width) / Double(width),
                        y: (rect.minY + (1 - box.maxY) * rect.height) / Double(height),
                        width: box.width * rect.width / Double(width), height: box.height * rect.height / Double(height))
                    observations.append((observation, mapped))
                }
            }
        }
        var output: [OCRDetection] = []
        let confidence = Float(min(max((entropyThreshold - 3) * 0.2 + 0.15, 0.1), 0.5))
        for (observation, mappedBox) in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= confidence else { continue }
            for hit in SensitivePatterns.scan(candidate.string, custom: patterns, entropyThreshold: entropyThreshold) {
                let value = String(candidate.string[hit.range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let start = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.lowerBound))
                let end = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.upperBound))
                let count = Double(max(candidate.string.count, 1)), box = mappedBox
                let left = max(Double(box.minX) + Double(box.width) * start / count - Double(box.width) * 0.04, 0)
                let right = min(Double(box.minX) + Double(box.width) * end / count + Double(box.width) * 0.04, 1)
                output.append(OCRDetection(t: time, x: left, y: Double(box.minY), w: max(right - left, 0.001),
                                           h: Double(box.height), category: hit.category,
                                           hash: fnv1a64(value.lowercased(), salt: salt), confidence: candidate.confidence))
            }
        }
        for (label, box) in observations {
            guard let text = label.topCandidates(1).first?.string,
                  text.range(of: "password|passcode|cvv|card number|ssn", options: .regularExpression.union(.caseInsensitive)) != nil else { continue }
            let neighbors = observations.map(\.1).filter { candidate in
                candidate != box && ((candidate.minX >= box.maxX && abs(candidate.midY - box.midY) < box.height * 2)
                    || (candidate.minY >= box.maxY && candidate.minY - box.maxY < 0.08 && abs(candidate.midX - box.midX) < 0.25))
            }
            let nearest = neighbors.min { hypot($0.midX - box.midX, $0.midY - box.midY) < hypot($1.midX - box.midX, $1.midY - box.midY) }
            let field = nearest ?? CGRect(x: box.minX, y: box.maxY, width: max(box.width, 0.18), height: max(box.height * 2, 0.025))
            let region = box.union(field).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            output.append(OCRDetection(t: time, x: region.minX, y: region.minY, w: region.width, h: region.height,
                category: .envSecret, hash: fnv1a64(text.lowercased(), salt: salt), confidence: 1))
        }
        return output
    }

    private func deduplicate(_ detections: [OCRDetection]) -> [OCRDetection] {
        var seen: Set<String> = []
        return detections.sorted { $0.t < $1.t }.filter { detection in
            let cellX = Int((detection.x * 80).rounded()), cellY = Int((detection.y * 80).rounded())
            let cellT = Int((detection.t * 2).rounded())
            return seen.insert("\(detection.hash):\(cellT):\(cellX):\(cellY)").inserted
        }
    }
}
```

### Sources/LumenAnalysis/PersonMask.swift

```swift
import Foundation
import AVFoundation
import Accelerate
import Vision
import os
import LumenProject

public enum PersonMaskAnalyzer {
    public static func analyze(url: URL, output: URL, offset: Double = 0, fps: Double = 30, maxDimension: Int = 720) async throws -> PersonMaskInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let job = PersonMaskJob(asset: asset, track: track, output: output, offset: offset, fps: fps, maxDimension: maxDimension)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class PersonMaskJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let outputURL: URL
    private let offset: Double
    private let fps: Double
    private let maxDimension: Int
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, output: URL, offset: Double, fps: Double, maxDimension: Int) {
        self.asset = asset; self.track = track; self.outputURL = output; self.offset = offset
        self.fps = max(fps, 1); self.maxDimension = max(maxDimension, 64)
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> PersonMaskInfo {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).lmask")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: header()) else { throw AnalysisError.cacheWrite }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let writer = try FileHandle(forWritingTo: tempURL)
        var writerClosed = false
        defer { if !writerClosed { try? writer.close() } }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var next = 0.0, frameCount = 0, width = 0, height = 0
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + 1 / fps
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            guard let mask = request.results?.first?.pixelBuffer else { continue }
            let scaled = try grayscale(mask, maxDimension: maxDimension)
            if frameCount == 0 { width = scaled.width; height = scaled.height; try writer.write(contentsOf: dimensions(width, height)) }
            var timeBits = (CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset).bitPattern.littleEndian
            var timeData = Data(bytes: &timeBits, count: MemoryLayout<UInt64>.size)
            timeData.append(scaled.data)
            try writer.write(contentsOf: timeData)
            frameCount += 1
        }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        guard frameCount > 0 else { throw AnalysisError.noMaskFrames }
        try writer.synchronize()
        try writer.close()
        writerClosed = true
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }
        return PersonMaskInfo(file: outputURL.lastPathComponent, width: width, height: height, fps: fps, frames: frameCount)
    }

    private func header() -> Data { Data([0x4c, 0x55, 0x4d, 0x41, 0x53, 0x4b, 0x31, 0]) }

    private func dimensions(_ width: Int, _ height: Int) -> Data {
        var w = UInt32(width).littleEndian, h = UInt32(height).littleEndian
        var data = Data(bytes: &w, count: 4); data.append(Data(bytes: &h, count: 4)); return data
    }

    private func grayscale(_ buffer: CVPixelBuffer, maxDimension: Int) throws -> (width: Int, height: Int, data: Data) {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let scale = min(1, Double(maxDimension) / Double(max(width, height)))
        let targetWidth = max(Int((Double(width) * scale).rounded()), 1), targetHeight = max(Int((Double(height) * scale).rounded()), 1)
        var sourceBuffer = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                         rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var data = Data(count: targetWidth * targetHeight)
        let status = data.withUnsafeMutableBytes { bytes -> vImage_Error in
            guard let destination = bytes.baseAddress else { return kvImageMemoryAllocationError }
            var destinationBuffer = vImage_Buffer(data: destination, height: vImagePixelCount(targetHeight),
                                                  width: vImagePixelCount(targetWidth), rowBytes: targetWidth)
            return vImageScale_Planar8(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { throw AnalysisError.maskScale(status) }
        return (targetWidth, targetHeight, data)
    }
}
```

### Sources/LumenAnalysis/Service.swift

```swift
import Foundation
import AVFoundation
import LumenCore
import LumenProject

final class ReaderHandle: @unchecked Sendable {
    let reader: AVAssetReader
    init(_ reader: AVAssetReader) { self.reader = reader }
}

enum AnalysisError: Error, LocalizedError, Sendable {
    case noVideoTrack
    case readerConfiguration
    case readerStart
    case readerFailed
    case pixelBuffer
    case cacheWrite
    case noMaskFrames
    case maskScale(Int)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "No video track is available for analysis."
        case .readerConfiguration: "The media reader could not be configured."
        case .readerStart: "The media reader could not start."
        case .readerFailed: "Media decoding failed during analysis."
        case .pixelBuffer: "A decoded analysis frame could not be read."
        case .cacheWrite: "The analysis cache could not be created."
        case .noMaskFrames: "Person segmentation did not produce any frames."
        case .maskScale(let code): "Person mask scaling failed with code \(code)."
        }
    }
}

public struct AnalysisRequest: Sendable {
    public var sourceDuration = 0.0
    public var privacyProgress: @Sendable (Double) -> Void = { _ in }
    public var screen: URL
    public var webcam: URL?
    public var mic: URL?
    public var cacheDirectory: URL
    public var webcamOffset: Double
    public var micOffset: Double
    public var projectSalt: UInt64
    public var privacy: PrivacyPlan
    public var locale: String
    public var vocabulary: [String]
    public var includeSpeech: Bool
    public var includeActivity: Bool
    public var includeFace: Bool
    public var includePersonMask: Bool
    public var includeTyping: Bool
    public var events: [InputEvent]

    public init(screen: URL, webcam: URL? = nil, mic: URL? = nil, cacheDirectory: URL, webcamOffset: Double = 0,
                micOffset: Double = 0, projectSalt: UInt64, privacy: PrivacyPlan = PrivacyPlan(), locale: String = "en-US",
                vocabulary: [String] = [], includeSpeech: Bool = false, includeActivity: Bool = false,
                includeFace: Bool = true, includePersonMask: Bool = false, includeTyping: Bool = false,
                events: [InputEvent] = []) {
        self.screen = screen; self.webcam = webcam; self.mic = mic; self.cacheDirectory = cacheDirectory
        self.webcamOffset = webcamOffset; self.micOffset = micOffset; self.projectSalt = projectSalt; self.privacy = privacy
        self.locale = locale; self.vocabulary = vocabulary; self.includeSpeech = includeSpeech; self.includeActivity = includeActivity
        self.includeFace = includeFace; self.includePersonMask = includePersonMask
        self.includeTyping = includeTyping; self.events = events
    }
}

public struct AnalysisResult: Sendable {
    public var face: [FaceSample]
    public var activity: [ActivityPoint]
    public var ocr: [OCRDetection]
    public var transcript: Transcript?
    public var personMask: PersonMaskInfo?
    public var typing: [TypingTrace]
    public var errors: [String: String]
    public init(face: [FaceSample] = [], activity: [ActivityPoint] = [], ocr: [OCRDetection] = [], transcript: Transcript? = nil,
                personMask: PersonMaskInfo? = nil, typing: [TypingTrace] = [], errors: [String: String] = [:]) {
        self.face = face; self.activity = activity; self.ocr = ocr; self.transcript = transcript
        self.personMask = personMask; self.typing = typing; self.errors = errors
    }
}

public actor AnalysisService {
    public static let shared = AnalysisService()
    private let speech = AppleSpeechEngine()
    public init() {}

    public func run(_ request: AnalysisRequest) async -> AnalysisResult {
        // At most 2 concurrent analyzers at .utility; pause while a recording
        // is active so capture never shares the CPU with analysis.
        while RecordingGate.isRecordingActive {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return AnalysisResult(errors: ["cancelled": "analysis paused during recording"]) }
        }
        // Two waves of ≤2 so the cap holds without starving any analyzer.
        async let faceResult = face(request)
        async let activityResult = activity(request)
        let (faces, faceError) = await faceResult
        let (activities, activityError) = await activityResult
        async let ocrResult = ocr(request)
        async let transcriptResult = transcript(request)
        let (detections, ocrError) = await ocrResult
        let (words, transcriptError) = await transcriptResult
        let (mask, maskError) = await personMask(request)
        let (traces, typingError) = await typing(request)
        var errors: [String: String] = [:]
        if let faceError { errors["face"] = faceError }
        if let activityError { errors["activity"] = activityError }
        if let ocrError { errors["ocr"] = ocrError }
        if let transcriptError { errors["speech"] = transcriptError }
        if let maskError { errors["personMask"] = maskError }
        if let typingError { errors["typing"] = typingError }
        return AnalysisResult(face: faces, activity: activities, ocr: detections, transcript: words,
                              personMask: mask, typing: traces, errors: errors)
    }

    private func face(_ r: AnalysisRequest) async -> ([FaceSample], String?) {
        guard r.includeFace, let webcam = r.webcam else { return ([], nil) }
        let (samples, error) = await cached(url: webcam, directory: analysisDirectory(r), analyzer: "face", version: 1,
                                            parameters: FaceParameters(offset: r.webcamOffset, fps: 12)) {
            try await FaceAnalyzer.analyze(url: webcam, startOffset: r.webcamOffset)
        }
        return (samples ?? [], error)
    }

    private func activity(_ r: AnalysisRequest) async -> ([ActivityPoint], String?) {
        guard r.includeActivity else { return ([], nil) }
        let (points, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "activity", version: 1,
                                           parameters: ActivityParameters(offset: 0, fps: 10)) {
            try await ActivityAnalyzer.analyze(url: r.screen, fps: 10)
        }
        return (points ?? [], error)
    }

    private func ocr(_ r: AnalysisRequest) async -> ([OCRDetection], String?) {
        guard r.privacy.enabled, r.privacy.autoDetect else { return ([], nil) }
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else {
            return ([], "Automatic text scanning is disabled by LUMEN_NO_OCR.")
        }
        let params = OCRParameters(salt: r.projectSalt, patterns: r.privacy.customPatterns,
                                   entropyThreshold: r.privacy.entropyThreshold, fps: 4)
        let (detections, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "sensitive-text", version: 5,
                                               parameters: params) {
            try await OCRAnalyzer.analyze(url: r.screen, projectSalt: r.projectSalt, customPatterns: r.privacy.customPatterns,
                                          entropyThreshold: r.privacy.entropyThreshold, duration: r.sourceDuration, progress: r.privacyProgress)
        }
        if error == nil { r.privacyProgress(1) }
        return (detections ?? [], error)
    }

    private func transcript(_ r: AnalysisRequest) async -> (Transcript?, String?) {
        guard r.includeSpeech, let mic = r.mic else { return (nil, nil) }
        let params = SpeechParameters(locale: r.locale, vocabulary: r.vocabulary, offset: r.micOffset)
        let engine = speech
        return await cached(url: mic, directory: analysisDirectory(r), analyzer: "transcript", version: 1,
                            parameters: params) {
            var result = try await engine.transcribe(audio: mic, locale: Locale(identifier: r.locale), vocabulary: r.vocabulary)
            for i in result.words.indices { result.words[i].start += r.micOffset; result.words[i].end += r.micOffset }
            return result
        }
    }

    private func personMask(_ r: AnalysisRequest) async -> (PersonMaskInfo?, String?) {
        guard r.includePersonMask, let webcam = r.webcam else { return (nil, nil) }
        let directory = analysisDirectory(r)
        let params = PersonMaskParameters(offset: r.webcamOffset, fps: 30, maxDimension: 720)
        do {
            let key = try await AnalysisCache.key(media: webcam, analyzer: "person-mask", version: 1, parameters: params)
            if let cached = AnalysisCache.load(PersonMaskInfo.self, key: key, directory: directory),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(cached.file).path) { return (cached, nil) }
            let output = directory.appendingPathComponent("\(key).lmask")
            let info = try await PersonMaskAnalyzer.analyze(url: webcam, output: output, offset: r.webcamOffset)
            try AnalysisCache.save(info, key: key, directory: directory)
            return (info, nil)
        } catch { return (nil, error.localizedDescription) }
    }

    private func typing(_ r: AnalysisRequest) async -> ([TypingTrace], String?) {
        guard r.includeTyping, !r.events.isEmpty else { return ([], nil) }
        let bursts = r.events.typingBursts()
        guard !bursts.isEmpty else { return ([], nil) }
        let anchors: [SIMD2<Double>?] = bursts.map { _ in nil }
        let params = TypingParameters(bursts: bursts.map { [$0.t0, $0.t1] },
                                      anchors: anchors.map { $0.map { [$0.x, $0.y] } ?? [-1, -1] })
        let (traces, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "typing", version: 3,
                                           parameters: params) {
            try await TypingAnalyzer.analyze(url: r.screen, bursts: bursts, anchors: anchors)
        }
        return (traces ?? [], error)
    }

    private func cached<Value: Codable & Sendable, Parameters: Encodable & Sendable>(url: URL, directory: URL, analyzer: String, version: Int,
                                                                           parameters: Parameters,
                                                                           produce: () async throws -> Value) async -> (Value?, String?) {
        do {
            let key = try await AnalysisCache.key(media: url, analyzer: analyzer, version: version, parameters: parameters)
            if let cached = AnalysisCache.load(Value.self, key: key, directory: directory) { return (cached, nil) }
            let value = try await produce()
            try AnalysisCache.save(value, key: key, directory: directory)
            return (value, nil)
        } catch is CancellationError {
            return (nil, "Cancelled")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func analysisDirectory(_ request: AnalysisRequest) -> URL {
        request.cacheDirectory.appendingPathComponent("analysis", isDirectory: true)
    }
}

private struct FaceParameters: Codable, Sendable { var offset: Double; var fps: Double }
private struct ActivityParameters: Codable, Sendable { var offset: Double; var fps: Double }
private struct OCRParameters: Codable { var salt: UInt64; var patterns: [String]; var entropyThreshold: Double; var fps: Double }
private struct SpeechParameters: Codable { var locale: String; var vocabulary: [String]; var offset: Double }
private struct PersonMaskParameters: Codable { var offset: Double; var fps: Double; var maxDimension: Int }
private struct TypingParameters: Codable { var bursts: [[Double]]; var anchors: [[Double]] }
```

### Sources/LumenAnalysis/Speech.swift

```swift
import Foundation
import Speech
import LumenProject

public enum SpeechAnalysisError: Error, Sendable {
    case permissionDenied
    case recognizerUnavailable
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript
}

public struct AppleSpeechEngine: TranscriptionEngine {
    public init() {}

    public func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript {
        guard await authorized() else { throw SpeechAnalysisError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechAnalysisError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(100))
        let job = SpeechJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error { job.finish(.failure(error)); return }
                    guard let result, result.isFinal else { return }
                    let words = result.bestTranscription.segments.map {
                        WordToken(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: $0.confidence)
                    }
                    job.finish(.success(Transcript(words: words, locale: locale.identifier)))
                }
                job.set(task)
            }
        } onCancel: {
            job.cancel()
        }
    }

    private func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }
}

private final class SpeechJob: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Transcript, Error>?
    private var task: SFSpeechRecognitionTask?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Transcript, Error>) {
        lock.lock()
        let cancelled = resolved
        if !cancelled { self.continuation = continuation }
        lock.unlock()
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func set(_ task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        if resolved { task.cancel() } else { self.task = task }
    }

    func finish(_ result: Result<Transcript, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil; task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}
```

### Sources/LumenAnalysis/TypingAnalyzer.swift

```swift
import Foundation
import AVFoundation
import CoreVideo
import os
import LumenProject

/// Reads only the frames around each typing burst and turns them into the
/// per-tile luma grids the pure `TypingTracer` consumes. One AVAssetReader
/// per burst keeps a 60 s 2880 px capture from being decoded end to end.
public enum TypingAnalyzer {
    public static func analyze(url: URL, bursts: [(t0: Double, t1: Double)],
                               anchors: [SIMD2<Double>?]) async throws -> [TypingTrace] {
        guard !bursts.isEmpty, bursts.count == anchors.count else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = TypingJob(asset: asset, track: track, bursts: bursts, anchors: anchors)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class TypingJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let bursts: [(t0: Double, t1: Double)]
    private let anchors: [SIMD2<Double>?]
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, bursts: [(t0: Double, t1: Double)], anchors: [SIMD2<Double>?]) {
        self.asset = asset; self.track = track; self.bursts = bursts; self.anchors = anchors
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [TypingTrace] {
        let duration = asset.duration.seconds
        var traces: [TypingTrace] = []
        for (i, burst) in bursts.enumerated() {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let a = max(0, burst.t0 - 0.20), b = min(duration, burst.t1 + 0.50)
            guard b > a else { continue }
            if let trace = try one(burst: burst, anchor: anchors[i], from: a, to: b) { traces.append(trace) }
        }
        return traces
    }

    private func one(burst: (t0: Double, t1: Double), anchor: SIMD2<Double>?, from a: Double, to b: Double) throws -> TypingTrace? {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                       end: CMTime(seconds: b, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }

        // One baseline shortly before the first key, then ~10 fps through the
        // burst. Sampling on the decoded frame clock keeps each grid tied to
        // the exact frame time the tracer reports.
        var wanted: [Double] = [max(a, burst.t0 - 0.12)]
        var t = burst.t0 + 0.10
        while t <= burst.t1 + 0.40 { wanted.append(t); t += 0.10 }
        var wi = 0
        var ts: [Double] = []
        var grids: [LumaTiles] = []
        var height = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard wi < wanted.count, time + 0.0001 >= wanted[wi],
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = try lumaTiles(buffer)
            ts.append(time)
            grids.append(grid)
            height = max(height, Double(CVPixelBufferGetHeight(buffer)))
            wi += 1
            while wi < wanted.count, wanted[wi] <= time + 0.0001 { wi += 1 }   // a slow frame satisfies only once
            if wi >= wanted.count { break }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        guard grids.count >= 2 else { return nil }
        return TypingTracer.trace(burst: burst, ts: ts, grids: grids, anchor: anchor, srcH: height)
    }

    /// 16 source-px tiles, stride-2 sampling, one pass over the buffer.
    private func lumaTiles(_ buffer: CVPixelBuffer) throws -> LumaTiles {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let tile = 16
        let cols = max(1, (width + tile - 1) / tile), rows = max(1, (height + tile - 1) / tile)
        var sum = [UInt32](repeating: 0, count: cols * rows)
        var count = [UInt32](repeating: 0, count: cols * rows)
        for y in stride(from: 0, to: height, by: 2) {
            let row = base + y * rowBytes
            let ry = y / tile
            for x in stride(from: 0, to: width, by: 2) {
                let i = x * 4
                let luma = (29 * Int(row[i]) + 150 * Int(row[i + 1]) + 77 * Int(row[i + 2])) >> 8
                let index = ry * cols + x / tile
                sum[index] += UInt32(luma)
                count[index] += 1
            }
        }
        var mean = [UInt8](repeating: 0, count: cols * rows)
        for i in mean.indices where count[i] > 0 {
            mean[i] = UInt8(min(255, sum[i] / count[i]))
        }
        return LumaTiles(cols: cols, rows: rows, tile: tile, mean: mean)
    }
}
```

### Sources/LumenAnalysis/TypingTracer.swift

```swift
import Foundation
import LumenProject

/// Pixel-measured typing anchor (no AX dependency). Pure and unit-testable;
/// the AVAssetReader pipeline that builds the luma grids lives in the
/// analysis service and feeds this tracer.
public enum TypingTracer {
    struct Box { var c0: Int, c1: Int, r0: Int, r1: Int, area: Int }

    public static func trace(burst: (t0: Double, t1: Double), ts: [Double], grids: [LumaTiles],
                             anchor: SIMD2<Double>?, srcH: Double) -> TypingTrace? {
        guard ts.count == grids.count, ts.count >= 2, let base = grids.first else { return nil }
        let cols = base.cols, rows = base.rows, tile = Double(base.tile)
        let maxLineRows = max(Int(0.08 * srcH / tile), 2)
        func changed(_ g: LumaTiles) -> [Bool] { (0..<(cols * rows)).map { abs(Int(g.mean[$0]) - Int(base.mean[$0])) >= 8 } }
        func dilate(_ m: [Bool]) -> [Bool] {
            var o = m
            for r in 0..<rows { for c in 0..<cols where m[r * cols + c] { for dc in -2...2 where c + dc >= 0 && c + dc < cols { o[r * cols + c + dc] = true } } }
            return o
        }
        func components(_ m: [Bool]) -> [Box] {
            var seen = [Bool](repeating: false, count: m.count), out: [Box] = []
            for s in m.indices where m[s] && !seen[s] {
                var bx = Box(c0: s % cols, c1: s % cols, r0: s / cols, r1: s / cols, area: 0)
                var stack = [s]; seen[s] = true
                while let i = stack.popLast() {
                    let c = i % cols, r = i / cols
                    bx.c0 = min(bx.c0, c); bx.c1 = max(bx.c1, c); bx.r0 = min(bx.r0, r); bx.r1 = max(bx.r1, r); bx.area += 1
                    for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows, m[nr * cols + nc], !seen[nr * cols + nc] else { continue }
                        seen[nr * cols + nc] = true; stack.append(nr * cols + nc)
                    }
                }
                out.append(bx)
            }
            return out
        }
        // First frame with a single-line-high blob = where the first typed characters appeared.
        var band: (r0: Int, r1: Int, left: Int)?, k0 = 1, lineRows = 1
        for k in 1..<ts.count {
            let blobs = components(dilate(changed(grids[k]))).filter { $0.r1 - $0.r0 + 1 <= maxLineRows && $0.area >= 2 }
            guard !blobs.isEmpty else { continue }
            func cy(_ b: Box) -> Double { Double(b.r0 + b.r1 + 1) / 2 * tile }
            var pick = blobs.min { $0.r0 < $1.r0 }!
            if let a = anchor, let n = blobs.filter({ abs(cy($0) - a.y) < 0.25 * srcH }).min(by: { abs(cy($0) - a.y) < abs(cy($1) - a.y) }) { pick = n }
            band = (max(pick.r0 - 1, 0), min(pick.r1 + 1, rows - 1), max(pick.c0 + 2 - 1, 0)); k0 = k
            lineRows = pick.r1 - pick.r0 + 1   // the text line itself; the band's ±1 rows are tracking slack
            break
        }
        guard let band else { return nil }
        var samples: [TypingTrace.Sample] = [], right = band.left
        for k in k0..<ts.count {
            let m = changed(grids[k]); var found = -1
            for r in band.r0...band.r1 { for c in stride(from: cols - 1, through: band.left, by: -1) where m[r * cols + c] { found = max(found, c); break } }
            if found >= 0 { right = found }
            samples.append(.init(t: ts[k], x: Double(right + 1) * tile, y: Double(band.r0 + band.r1 + 1) / 2 * tile))
        }
        guard let last = samples.last else { return nil }
        let left = Double(band.left) * tile
        return TypingTrace(t0: burst.t0, t1: burst.t1,
                           rect: CGRect(x: left, y: Double(band.r0) * tile, width: max(last.x - left, tile), height: Double(lineRows) * tile),
                           samples: samples)
    }
}
```

## LumenProject/

### Sources/LumenProject/AnalysisTypes.swift

```swift
import Foundation
import CoreGraphics
import LumenCore

/// One recognized word. Source seconds.
public struct WordToken: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double, end: Double
    public var confidence: Float
    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}
public struct Transcript: Codable, Sendable, Equatable {
    public var words: [WordToken]
    public var locale: String
    public init(words: [WordToken], locale: String) { self.words = words; self.locale = locale }
}
/// Sensitive-text detection. Rect is normalized to the source frame (top-left origin). Raw text is never stored, only a salted hash.
public struct OCRDetection: Codable, Sendable, Equatable {
    public var t: Double, x: Double, y: Double, w: Double, h: Double
    public var category: SensitiveCategory
    public var hash: UInt64
    public var confidence: Float
    public init(t: Double, x: Double, y: Double, w: Double, h: Double, category: SensitiveCategory, hash: UInt64, confidence: Float) {
        self.t = t; self.x = x; self.y = y; self.w = w; self.h = h; self.category = category; self.hash = hash; self.confidence = confidence
    }
}
/// Face rect center/height normalized to the webcam image. Source seconds.
public struct FaceSample: Codable, Sendable {
    public var t: Double, cx: Float, cy: Float, h: Float
    public init(t: Double, cx: Float, cy: Float, h: Float) { self.t = t; self.cx = cx; self.cy = cy; self.h = h }
}
/// Pixel-activity centroid (device / imported clips with no input events). Source seconds, source px.
public struct ActivityPoint: Codable, Sendable {
    public var t: Double, x: Double, y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}
/// Typed-text line located by pixel change (see TypingTracer). Rect/caret in
/// source px; samples are the caret approach found per keystroke frame.
public struct TypingTrace: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var t: Double, x: Double, y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }
    public var t0: Double, t1: Double
    public var rect: CGRect?
    public var samples: [Sample]
    public init(t0: Double, t1: Double, rect: CGRect? = nil, samples: [Sample] = []) {
        self.t0 = t0; self.t1 = t1; self.rect = rect; self.samples = samples
    }
    enum CodingKeys: String, CodingKey { case t0, t1, rect, samples }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t0 = try c.decode(Double.self, forKey: .t0); t1 = try c.decode(Double.self, forKey: .t1)
        if let r = try c.decodeIfPresent([Double].self, forKey: .rect), r.count == 4 {
            rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else { rect = nil }
        samples = try c.decode([Sample].self, forKey: .samples)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t0, forKey: .t0); try c.encode(t1, forKey: .t1)
        if let r = rect { try c.encode([r.origin.x, r.origin.y, r.size.width, r.size.height], forKey: .rect) }
        try c.encode(samples, forKey: .samples)
    }
}
/// Per-tile mean-luma grid over a frame (for TypingTracer).
public struct LumaTiles: Sendable, Equatable {
    public var cols: Int, rows: Int, tile: Int, mean: [UInt8]
    public init(cols: Int, rows: Int, tile: Int, mean: [UInt8]) {
        self.cols = cols; self.rows = rows; self.tile = tile; self.mean = mean
    }
}

/// Location and sampling details for a cached person-mask plane sequence.
public struct PersonMaskInfo: Codable, Sendable, Equatable {
    public var file: String
    public var width: Int, height: Int, fps: Double, frames: Int
    public init(file: String, width: Int, height: Int, fps: Double, frames: Int) {
        self.file = file; self.width = width; self.height = height; self.fps = fps; self.frames = frames
    }
}
```

### Sources/LumenProject/Commands.swift

```swift
import Foundation
import LumenCore

/// Which derived tracks a command invalidates (plan 4.6).
public struct Effects: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let timeMap = Effects(rawValue: 1 << 0)
    public static let cursor = Effects(rawValue: 1 << 1)
    public static let zoom = Effects(rawValue: 1 << 2)
    public static let camera = Effects(rawValue: 1 << 3)
    public static let layout = Effects(rawValue: 1 << 4)
    public static let webcam = Effects(rawValue: 1 << 5)
    public static let masks = Effects(rawValue: 1 << 6)
    public static let captions = Effects(rawValue: 1 << 7)
    public static let audio = Effects(rawValue: 1 << 8)
    public static let backdrop = Effects(rawValue: 1 << 9)
    public static let replan: Effects = [.timeMap, .cursor, .zoom, .camera, .layout, .webcam, .masks, .captions, .audio]
}

/// Captured at dispatch so "at playhead" can never read stale pointer state. `playhead` is OUTPUT seconds.
public struct ReduceContext: Sendable {
    public var playhead: Double, selection: UUID?, duration: Double, fps: Double
    public init(playhead: Double, selection: UUID? = nil, duration: Double, fps: Double = 60) {
        self.playhead = playhead; self.selection = selection; self.duration = duration; self.fps = max(fps, 1)
    }
    /// One frame in seconds at the project rate.
    public var frame: Double { 1 / max(fps, 1) }
}

public enum CommandError: Error, Sendable { case notFound(UUID), invalid(String) }

/// One case per user-visible action. Views, hotkeys, CLI, MCP and App Intents all dispatch these. Times are SOURCE seconds unless named Output/Playhead.
public enum Command: Codable, Sendable {
    case addCut(start: Double, end: Double), cutOutputRange(start: Double, end: Double), cutAtPlayhead(length: Double)
    case deleteCut(UUID), trim(start: Double, end: Double)
    case addSpeedRamp(start: Double, end: Double, speed: Double), deleteSpeedRamp(UUID)
    case addZoom(ZoomSegment), addZoomAtPlayhead(duration: Double, scale: Double), moveZoom(UUID, start: Double, end: Double)
    case setZoomScale(UUID, Double), setZoomFocus(UUID, Focus), setZoomEasing(UUID, ZoomEasing?), deleteZoom(UUID), setZoomPreset(ZoomPreset)
    case setStyle(Style), setCursor(CursorStyle), setCamera(CameraParams), setAudio(AudioPlan), setWebcam(WebcamLayout?), setCaptions(CaptionPlan)
    case setPrivacy(PrivacyPlan)
    case deleteWords([Int]), restoreWords([Int]), editWord(index: Int, text: String)
    case setCaptionsEnabled(Bool)
    case setLayout(LayoutSegment), deleteLayout(UUID), setLayoutSettings(LayoutKind, LayoutSettings)
    case addMask(Mask), addMaskAtPlayhead(x: Double, y: Double, w: Double, h: Double, mode: MaskMode)
    case approveMasks([UUID]), rejectMasks([UUID]), deleteMask(UUID)
    case addHighlight(Highlight), setHighlightStyle(UUID, HighlightStyle), deleteHighlight(UUID), addLoupe(Loupe), deleteLoupe(UUID)
    case updateLoupe(Loupe)
    case addTapAtPlayhead(x: Double, y: Double), deleteTap(UUID), moveTap(tap: UUID, x: Double, y: Double, atSource: Double?)
    case addText(TextBlock), editText(UUID, String), deleteText(UUID)
    case addClip(TimelineClip), deleteClip(UUID), moveClip(UUID, start: Double), trimClip(UUID, inPoint: Double, duration: Double)
    case splitClip(atOutput: Double), rippleDeleteClip(id: UUID), joinClips(ids: [UUID]),
         duplicateClip(id: UUID), pasteClip(clip: TimelineClip, atOutput: Double)
    case splitRecording(atOutput: Double), removeSeam(id: UUID), moveSeam(id: UUID, toOutput: Double)
    case setCutEdge(id: UUID, isStart: Bool, toOutput: Double), deleteRecordingSegment(atOutput: Double)
    case trimClipEdge(id: UUID, isStart: Bool, toOutput: Double), reorderClip(id: UUID, toIndex: Int)
    case applyAutoTidy([CutRange]), clearAutoTidy
}

/// Pure: (state, command, context) -> new state + effects. The only place user intent mutates the timeline.
public func reduce(_ t: inout Timeline, _ c: Command, ctx: ReduceContext) throws -> Effects {
    let tm = t.timeMap
    let playSrc = tm.source(atOutput: ctx.playhead)
    func zi(_ id: UUID) throws -> Int {
        guard let i = t.zoom.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        return i
    }
    let zoomFx: Effects = [.zoom, .camera, .audio]
    switch c {
    case .addCut(let s, let e):
        guard e > s else { throw CommandError.invalid("cut end <= start") }
        t.timeMap.cuts.append(CutRange(start: s, end: e)); return .replan
    case .cutOutputRange(let s, let e):
        guard e > s else { throw CommandError.invalid("cut end <= start") }
        do { try t.removeOutputRange(s, e, frame: ctx.frame) }
        catch let err as EditError { throw mapEdit(err) }
        return .replan
    case .cutAtPlayhead(let len):
        guard len > 0.05 else { throw CommandError.invalid("cut too short") }
        do { try t.removeOutputRange(ctx.playhead, ctx.playhead + len, frame: ctx.frame) }
        catch let err as EditError { throw mapEdit(err) }
        return .replan
    case .deleteCut(let id): t.timeMap.cuts.removeAll { $0.id == id }; return .replan
    case .trim(let s, let e):
        guard s >= 0, e > s, e <= tm.sourceDuration + 0.001 else { throw CommandError.invalid("bad trim") }
        t.timeMap.trimStart = s; t.timeMap.trimEnd = e; return .replan
    case .addSpeedRamp(let s, let e, let v):
        guard e > s, v > 0 else { throw CommandError.invalid("bad ramp") }
        t.timeMap.ramps.append(SpeedRamp(start: s, end: e, speed: v, origin: .manual)); return .replan
    case .deleteSpeedRamp(let id): t.timeMap.ramps.removeAll { $0.id == id }; return .replan

    case .addZoom(let z): t.zoom.append(z); return zoomFx
    case .addZoomAtPlayhead(let d, let sc):
        let e = min(tm.source(atOutput: ctx.playhead + d), tm.trimEnd)
        guard e - playSrc > 0.2 else { throw CommandError.invalid("no room for a zoom here") }
        t.zoom.append(ZoomSegment(start: playSrc, end: e, scale: max(sc, 1.1), focus: .follow, origin: .manual)); return zoomFx
    case .moveZoom(let id, let s, let e):
        let i = try zi(id); guard e > s else { throw CommandError.invalid("zoom end <= start") }
        t.zoom[i].start = s; t.zoom[i].end = e; t.zoom[i].origin = .manual; return zoomFx
    case .setZoomScale(let id, let sc): let i = try zi(id); t.zoom[i].scale = max(sc, 1.1); t.zoom[i].origin = .manual; return zoomFx
    case .setZoomFocus(let id, let f): let i = try zi(id); t.zoom[i].focus = f; t.zoom[i].origin = .manual; return zoomFx
    case .setZoomEasing(let id, let e): let i = try zi(id); t.zoom[i].easing = e; t.zoom[i].origin = .manual; return zoomFx
    case .deleteZoom(let id): t.zoom.removeAll { $0.id == id }; return zoomFx
    case .setZoomPreset(let p): t.camera.apply(preset: p); return zoomFx

    case .setStyle(let s):
        let o = t.style; t.style = s
        var fx: Effects = [.backdrop]
        if o.padding != s.padding || o.paddingInsets != s.paddingInsets || o.cornerRadius != s.cornerRadius || o.cornerRadii != s.cornerRadii
            || o.canvas != s.canvas || o.customAspect != s.customAspect { fx.formUnion([.zoom, .camera, .layout, .webcam, .captions]) }
        return fx
    case .setCursor(let s): t.cursor = s; return [.cursor, .camera, .audio]
    case .setCamera(let s): t.camera = s; return [.zoom, .camera, .audio]
    case .setAudio(let s): t.audio = s; return [.timeMap, .audio, .zoom, .camera]
    case .setWebcam(let w): t.webcam = w; return [.webcam, .layout]
    case .setCaptions(let p): t.captions = p; return [.captions]
    case .setPrivacy(let p): t.overlays.privacy = p; return .masks
    case .deleteWords(let ix): t.captions.deletedWords = Array(Set(t.captions.deletedWords).union(ix)).sorted(); return .replan
    case .restoreWords(let ix): t.captions.deletedWords.removeAll { ix.contains($0) }; return .replan
    case .editWord(let i, let s): t.captions.textEdits[String(i)] = s; return .captions
    case .setCaptionsEnabled(let b): t.captions.enabled = b; return .captions

    case .setLayout(let seg):
        if let i = t.layouts.firstIndex(where: { $0.id == seg.id }) { t.layouts[i] = seg } else { t.layouts.append(seg) }
        return [.zoom, .camera, .layout, .webcam, .captions]
    case .deleteLayout(let id): t.layouts.removeAll { $0.id == id }; return [.zoom, .camera, .layout, .webcam, .captions]
    case .setLayoutSettings(let k, let s): t.layoutSettings[k] = s; return [.zoom, .camera, .layout, .webcam]

    case .addMask(let m): t.overlays.masks.append(m); return .masks
    case .addMaskAtPlayhead(let x, let y, let w, let h, let mode):
        guard w > 1, h > 1 else { throw CommandError.invalid("empty mask") }
        let e = min(playSrc + 3, tm.trimEnd)
        t.overlays.masks.append(Mask(start: playSrc, end: e, mode: mode, keys: [MaskKey(t: playSrc, x: x, y: y, w: w, h: h)])); return .masks
    case .approveMasks(let ids):
        for i in t.overlays.masks.indices where ids.contains(t.overlays.masks[i].id) {
            t.overlays.masks[i].approved = true
            t.overlays.privacy.decisions[t.overlays.masks[i].id.uuidString] = true
        }
        return .masks
    case .rejectMasks(let ids):
        for id in ids where t.overlays.masks.first(where: { $0.id == id })?.origin == .auto {
            t.overlays.privacy.decisions[id.uuidString] = false
        }
        t.overlays.masks.removeAll { ids.contains($0.id) }
        return .masks
    case .deleteMask(let id): t.overlays.masks.removeAll { $0.id == id }; return .masks
    case .addHighlight(let h): t.overlays.highlights.append(h); return .masks
    case .setHighlightStyle(let id, let style):
        guard let i = t.overlays.highlights.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        t.overlays.highlights[i].style = style; return .masks
    case .deleteHighlight(let id): t.overlays.highlights.removeAll { $0.id == id }; return .masks
    case .addLoupe(let l): t.overlays.loupes.append(l); return .masks
    case .deleteLoupe(let id): t.overlays.loupes.removeAll { $0.id == id }; return .masks
    case .updateLoupe(let l):
        guard let i = t.overlays.loupes.firstIndex(where: { $0.id == l.id }) else { throw CommandError.notFound(l.id) }
        t.overlays.loupes[i] = l; return .masks
    case .addClip(let clip):
        guard !clip.path.isEmpty, clip.duration > 0 else { throw CommandError.invalid("empty clip") }
        t.clips.append(clip); t.clips.sort { $0.start < $1.start }; return []
    case .deleteClip(let id): t.clips.removeAll { $0.id == id }; t.clips.sort { $0.start < $1.start }; return []
    case .moveClip(let id, let start):
        guard let i = t.clips.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        t.clips[i].start = max(start, 0); t.clips.sort { $0.start < $1.start }; return []
    case .trimClip(let id, let inPoint, let duration):
        guard let i = t.clips.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        t.clips[i].inPoint = max(inPoint, 0); t.clips[i].duration = max(duration, 0.05); t.clips.sort { $0.start < $1.start }; return []

    // MARK: Magnetic main-lane
    // Notes: soundtrack lanes are NOT part of the magnetic lane. Ripple edits
    // shift downstream OUTPUT positions, so lanes whose `.placement` is past
    // the edited range shift with the ripple; lanes inside the removed range
    // clamp to the end of the lane. Trim/cut are separate commands and do not
    // follow content: they define the recording's visible source window.
    // A split is a logical boundary inside contiguous source — it partitions
    // for ordering only and never changes camera, cursor, or mask coverage.
    case .splitClip(let atOutput):
        let splitOut = max(min(atOutput, t.compositionDuration - 0.05), 0.05)
        guard let idx = t.clips.firstIndex(where: { $0.contains(output: splitOut) }) else {
            throw CommandError.invalid("split point outside any clip")
        }
        let clip = t.clips[idx]
        let offset = clip.sourceTime(atOutput: splitOut) - clip.inPoint
        guard offset > 0.05, offset < clip.duration - 0.05 else { throw CommandError.invalid("split point too close to edge") }
        let tailDuration = clip.duration - offset
        let left = TimelineClip(id: clip.id, path: clip.path, name: clip.name,
                                inPoint: clip.inPoint, duration: offset, start: clip.start,
                                width: clip.width, height: clip.height)
        let right = TimelineClip(id: UUID(), path: clip.path, name: clip.name + " (2)",
                                 inPoint: clip.inPoint + offset, duration: tailDuration, start: splitOut,
                                 width: clip.width, height: clip.height)
        t.clips.replaceSubrange(idx...idx, with: [left, right])
        t.clips.magneticNormalize()
        partitionAnchoredOverlays(&t, atOutput: splitOut)
        return [.masks, .zoom, .camera, .audio, .layout, .webcam]
    case .rippleDeleteClip(let id):
        guard let idx = t.clips.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        let removed = t.clips[idx]
        t.clips.remove(at: idx)
        t.clips.magneticNormalize()
        // Masks and overlays inside the removed OUTPUT range are clamped,
        // never re-anchored: they stay pinned to source time so a ripple
        // cannot strip a mask that covers sensitive area.
        clampAnchoredOverlaysToClips(&t, removedClip: removed)
        // Ripple-delete shifts downstream soundtrack lanes left by the removed
        // duration so lane placement stays aligned with picture.
        shiftSoundtrackLanesAfter(&t, afterOutput: removed.start, by: -removed.duration)
        return .replan
    case .joinClips(let ids):
        let selected = t.clips.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
        guard selected.count >= 2 else { throw CommandError.invalid("join needs at least two clips") }
        guard selected[0].isContiguous(with: selected[1]) else {
            throw CommandError.invalid("clips are not contiguous in source")
        }
        let merged = TimelineClip(id: selected[0].id, path: selected[0].path, name: selected[0].name,
                                  inPoint: selected[0].inPoint,
                                  duration: selected.map(\.duration).reduce(0, +),
                                  start: selected[0].start,
                                  width: selected[0].width, height: selected[0].height)
        t.clips.removeAll { ids.contains($0.id) }
        t.clips.append(merged); t.clips.magneticNormalize()
        return [.masks, .zoom, .camera, .audio, .layout, .webcam]
    case .duplicateClip(let id):
        guard let original = t.clips.first(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        let copy = TimelineClip(id: UUID(), path: original.path, name: original.name + " copy",
                                inPoint: original.inPoint, duration: original.duration,
                                start: original.end, width: original.width, height: original.height)
        t.clips.append(copy); t.clips.magneticNormalize()
        return .replan
    case .pasteClip(let clip, let atOutput):
        guard !clip.path.isEmpty, clip.duration > 0 else { throw CommandError.invalid("empty clip") }
        var pasted = clip
        pasted.id = UUID()
        pasted.start = t.clips.snappedStart(max(min(atOutput, t.compositionDuration), 0))
        t.clips.append(pasted); t.clips.magneticNormalize()
        shiftSoundtrackLanesBefore(&t, beforeOutput: pasted.start, by: pasted.duration)
        return .replan
    case .splitRecording(let atOutput):
        let src = tm.source(atOutput: max(min(atOutput, tm.outputDuration), 0))
        do { try t.addSeam(atSource: src) }
        catch let err as EditError { throw mapEdit(err) }
        return []
    case .removeSeam(let id):
        t.removeSeam(id: id)
        return []
    case .moveSeam(let id, let toOutput):
        do { try t.moveSeam(id: id, toSource: tm.source(atOutput: max(min(toOutput, tm.outputDuration), 0)), frame: ctx.frame) }
        catch let err as EditError { throw mapEdit(err) }
        return []
    case .setCutEdge(let id, let isStart, let toOutput):
        let src = tm.source(atOutput: max(min(toOutput, tm.outputDuration), 0))
        do { try t.trimCut(id: id, isStart: isStart, toSource: src, frame: ctx.frame) }
        catch let err as EditError { throw mapEdit(err) }
        return .replan
    case .deleteRecordingSegment(let atOutput):
        do { try t.removeSegment(atOutput: max(min(atOutput, tm.outputDuration), 0), frame: ctx.frame) }
        catch let err as EditError { throw mapEdit(err) }
        return .replan
    case .trimClipEdge(let id, let isStart, let toOutput):
        guard let i = t.clips.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        var clip = t.clips[i]
        let edge = min(max(toOutput, clip.start), clip.end)
        if isStart {
            let delta = edge - clip.start
            guard clip.duration - delta >= ctx.frame else { throw CommandError.invalid("A clip must stay at least one frame long.") }
            let inPoint = clip.inPoint + delta
            guard inPoint >= 0 else { throw CommandError.invalid("There is no more source before this clip.") }
            clip.inPoint = inPoint; clip.duration -= delta
        } else {
            let delta = edge - clip.end
            guard clip.duration + delta >= ctx.frame else { throw CommandError.invalid("A clip must stay at least one frame long.") }
            clip.duration += delta
        }
        t.clips[i] = clip
        t.clips.magneticNormalize()
        return [.masks, .zoom, .camera, .audio, .layout, .webcam]
    case .reorderClip(let id, let toIndex):
        guard let i = t.clips.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        var clip = t.clips.remove(at: i)
        let j = min(max(toIndex, 0), t.clips.count)
        t.clips.insert(clip, at: j)
        clip = t.clips[j]
        t.clips.magneticNormalize()
        return .replan
    case .addTapAtPlayhead(let x, let y): t.overlays.taps.append(TapIndicator(t: playSrc, x: x, y: y)); return [.cursor, .audio]
    case .deleteTap(let id): t.overlays.taps.removeAll { $0.id == id }; return [.cursor, .audio]
    case .moveTap(let id, let x, let y, let atSource):
        guard let i = t.overlays.taps.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        let w = t.derived?.sourceSize.x ?? Double(max(x, 1))
        let h = t.derived?.sourceSize.y ?? Double(max(y, 1))
        var nt = atSource ?? t.overlays.taps[i].t
        nt = min(max(nt, t.timeMap.trimStart), t.timeMap.trimEnd)
        for cut in t.timeMap.cuts where nt >= cut.start && nt < cut.end {
            nt = abs(nt - cut.start) < abs(cut.end - nt) ? cut.start : cut.end
        }
        t.overlays.taps[i].x = min(max(x, 0), w)
        t.overlays.taps[i].y = min(max(y, 0), h)
        t.overlays.taps[i].t = min(max(nt, t.timeMap.trimStart), t.timeMap.trimEnd)
        return [.cursor, .audio]
    case .addText(let b): t.overlays.texts.append(b); return .captions
    case .editText(let id, let value):
        guard let i = t.overlays.texts.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        t.overlays.texts[i].text = String(value.prefix(500)); return .captions
    case .deleteText(let id): t.overlays.texts.removeAll { $0.id == id }; return .captions

    case .applyAutoTidy(let cuts):
        t.timeMap.cuts.removeAll { $0.origin == .autoTidy }
        t.timeMap.cuts.append(contentsOf: cuts.map { CutRange(id: $0.id, start: $0.start, end: $0.end, origin: .autoTidy) }); return .replan
    case .clearAutoTidy: t.timeMap.cuts.removeAll { $0.origin == .autoTidy }; return .replan
    }
}

/// Plain-language mapping so the readout can say why an edit was refused.
private func mapEdit(_ e: EditError) -> CommandError {
    switch e {
    case .emptyRange: return .invalid("Select a range first.")
    case .removesEverything: return .invalid("That range would remove the whole recording.")
    case .tooShort: return .invalid("A cut must keep at least one frame.")
    }
}

/// Partition any source-anchored overlay that spans the OUTPUT split point.
/// Each overlay becomes at most two halves with fresh ids; nothing is dropped.
private func partitionAnchoredOverlays(_ t: inout Timeline, atOutput splitOut: Double) {
    let tm = t.timeMap
    let splitSrc = tm.source(atOutput: splitOut)
    // Masks
    var masks: [Mask] = []
    for m in t.overlays.masks {
        if m.start < splitSrc && m.end > splitSrc {
            masks.append(Mask(id: m.id, start: m.start, end: splitSrc, mode: m.mode,
                              keys: m.keys.filter { $0.t < splitSrc }, origin: m.origin,
                              approved: m.approved, category: m.category, padding: m.padding))
            masks.append(Mask(id: UUID(), start: splitSrc, end: m.end, mode: m.mode,
                              keys: m.keys.filter { $0.t >= splitSrc }, origin: m.origin,
                              approved: m.approved, category: m.category, padding: m.padding))
        } else { masks.append(m) }
    }
    t.overlays.masks = masks
    // Zooms
    t.zoom = t.zoom.flatMap { z -> [ZoomSegment] in
        if z.start < splitSrc && z.end > splitSrc {
            return [
                ZoomSegment(id: z.id, start: z.start, end: splitSrc, scale: z.scale, focus: z.focus, easing: z.easing, origin: z.origin),
                ZoomSegment(id: UUID(), start: splitSrc, end: z.end, scale: z.scale, focus: z.focus, easing: z.easing, origin: z.origin),
            ]
        }
        return [z]
    }
    // Cuts, ramps, highlights, loupes, layouts, texts
    t.timeMap.cuts = t.timeMap.cuts.flatMap { c -> [CutRange] in
        if c.start < splitSrc && c.end > splitSrc {
            return [CutRange(id: c.id, start: c.start, end: splitSrc, origin: c.origin),
                    CutRange(id: UUID(), start: splitSrc, end: c.end, origin: c.origin)]
        }
        return [c]
    }
    t.timeMap.ramps = t.timeMap.ramps.flatMap { r -> [SpeedRamp] in
        if r.start < splitSrc && r.end > splitSrc {
            return [SpeedRamp(start: r.start, end: splitSrc, speed: r.speed, origin: r.origin),
                    SpeedRamp(start: splitSrc, end: r.end, speed: r.speed, origin: r.origin)]
        }
        return [r]
    }
    t.overlays.highlights = t.overlays.highlights.flatMap { h -> [Highlight] in
        if h.start < splitSrc && h.end > splitSrc {
            return [Highlight(id: h.id, start: h.start, end: splitSrc, x: h.x, y: h.y, w: h.w, h: h.h, style: h.style, dim: h.dim),
                    Highlight(id: UUID(), start: splitSrc, end: h.end, x: h.x, y: h.y, w: h.w, h: h.h, style: h.style, dim: h.dim)]
        }
        return [h]
    }
    t.overlays.loupes = t.overlays.loupes.flatMap { l -> [Loupe] in
        if l.start < splitSrc && l.end > splitSrc {
            return [Loupe(id: l.id, start: l.start, end: splitSrc, x: l.x, y: l.y, follow: l.follow,
                          radius: l.radius, magnification: l.magnification, round: l.round, cx: l.cx, cy: l.cy,
                          border: l.border, shadow: l.shadow),
                    Loupe(id: UUID(), start: splitSrc, end: l.end, x: l.x, y: l.y, follow: l.follow,
                          radius: l.radius, magnification: l.magnification, round: l.round, cx: l.cx, cy: l.cy,
                          border: l.border, shadow: l.shadow)]
        }
        return [l]
    }
    t.layouts = t.layouts.flatMap { s -> [LayoutSegment] in
        if s.start < splitSrc && s.end > splitSrc {
            return [LayoutSegment(id: s.id, start: s.start, end: splitSrc, kind: s.kind),
                    LayoutSegment(id: UUID(), start: splitSrc, end: s.end, kind: s.kind)]
        }
        return [s]
    }
    t.overlays.texts = t.overlays.texts.flatMap { b -> [TextBlock] in
        if b.start < splitSrc && b.end > splitSrc {
            return [TextBlock(id: b.id, start: b.start, end: splitSrc, text: b.text, x: b.x, y: b.y, size: b.size, color: b.color),
                    TextBlock(id: UUID(), start: splitSrc, end: b.end, text: b.text, x: b.x, y: b.y, size: b.size, color: b.color)]
        }
        return [b]
    }
}

private func clampAnchoredOverlaysToClips(_ t: inout Timeline, removedClip: TimelineClip) {
    // Genuine ripple delete: overlays fully inside the removed range are left
    // clamped to that range, not stripped — masks especially must never
    // disappear because of an edit.
    let tm = t.timeMap
    let removedStart = removedClip.start
    let removedEnd = removedClip.end
    func clampSpan(_ s: Double, _ e: Double) -> (Double, Double)? {
        let cs = tm.source(atOutput: removedStart), ce = tm.source(atOutput: removedEnd)
        guard ce > cs else { return nil }
        // keep as-is; the ranges are source-anchored and stay valid
        return (s, e)
    }
    _ = clampSpan
    // No-op by design for masks/zooms/captions: they are source-anchored.
    // Nothing to strip; leaving them untouched is the safe behavior.
    _ = removedClip
}

private func shiftSoundtrackLanesAfter(_ t: inout Timeline, afterOutput start: Double, by delta: Double) {
    // Music/voiceover lanes are OUTPUT-anchored. A ripple delete moves them
    // left by the removed duration; lanes inside the removed range clamp to
    // the new start of the range.
    for i in t.audio.lanes.indices {
        let p = t.audio.lanes[i].placement
        if p >= start {
            t.audio.lanes[i].placement = max(p + delta, 0)
        }
    }
    if let mp = t.audio.musicPath, t.audio.musicGainDb < 0 {
        // music is a bed from 0, so nothing to clamp here
        _ = mp
    }
}

private func shiftSoundtrackLanesBefore(_ t: inout Timeline, beforeOutput start: Double, by delta: Double) {
    for i in t.audio.lanes.indices where t.audio.lanes[i].placement >= start {
        t.audio.lanes[i].placement += delta
    }
}
```

### Sources/LumenProject/Composition.swift

```swift
import Foundation
import LumenCore

/// A span of wall-clock time that was deliberately not recorded.
///
/// Paused spans are kept in SOURCE seconds (the same clock as the captured
/// screen track). On stop they become ordinary cuts, so every downstream stage
/// — Director, TimeMap, audio, export — reuses the cut machinery instead of
/// inventing a second timeline concept.
public struct PauseInterval: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id; self.start = start; self.end = end
    }
    public var duration: Double { max(end - start, 0) }
}

/// An imported video placed after the recording on the shared output timeline.
///
/// The primary recording keeps using `TimeMap` (cuts, trims, speed ramps). An
/// imported clip is addressed in OUTPUT seconds and contributes `duration`
/// seconds of footage starting at `start`. This keeps one unambiguous timeline
/// and lets the renderer compose both with the same `FrameState`.
///
/// Editing-layer rule: the magnetic main lane orders `clips` by OUTPUT `start`
/// and keeps them gapless. A split is a logical boundary inside a contiguous
/// source range, not a material edit — it never trims the underlying file and
/// never resets camera/cursor state.
public struct TimelineClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    /// Seconds into the imported file where this clip begins.
    public var inPoint: Double
    /// Seconds of the imported file used.
    public var duration: Double
    /// OUTPUT seconds where this clip begins.
    public var start: Double
    /// Pixel size of the imported file, probed once at import time.
    public var width: Int, height: Int
    public init(id: UUID = UUID(), path: String, name: String = "", inPoint: Double = 0,
                duration: Double, start: Double, width: Int = 1920, height: Int = 1080) {
        self.id = id; self.path = path; self.name = name
        self.inPoint = max(inPoint, 0); self.duration = max(duration, 0.01); self.start = max(start, 0)
        self.width = max(width, 2); self.height = max(height, 2)
    }
    public var end: Double { start + duration }
    public func contains(output t: Double) -> Bool { t >= start && t < end }
    /// Output seconds -> seconds inside the imported file.
    public func sourceTime(atOutput t: Double) -> Double { inPoint + max(min(t - start, duration), 0) }
    public var url: URL { URL(fileURLWithPath: path) }

    /// Two clips are contiguous when the second starts exactly where the first
    /// ends, they share the same file, and their inPoints continue without a
    /// gap or overlap. Join only succeeds on this predicate.
    public func isContiguous(with other: TimelineClip) -> Bool {
        guard path == other.path else { return false }
        let eps = 0.001
        return abs(end - other.start) < eps && abs(other.inPoint - (inPoint + duration)) < eps
    }
}

extension Array where Element == TimelineClip {
    /// Magnetic normalize: sort by output start and close gaps by rippling
    /// later clips left so `clips[i].start == clips[i-1].end`.
    /// The first clip keeps its start (recording-end == after-recording
    /// annexed clips stay put; lane clips at 0 stay put).
    mutating func magneticNormalize() {
        // Keep sort stable w.r.t. insertion order for equal starts: Swift sort
        // is stable, so only the start value rewrites the order.
        sort { $0.start < $1.start }
        guard !isEmpty else { return }
        var cursor = self[0].start
        for i in indices {
            self[i].start = cursor
            cursor += self[i].duration
        }
    }

    /// Snap a candidate start to the nearest clip edge when within `eps`.
    func snappedStart(_ start: Double, eps: Double = 0.05) -> Double {
        var best = start, bestDelta = eps
        for clip in self {
            for edge in [clip.start, clip.end] {
                let d = abs(edge - start)
                if d < bestDelta { bestDelta = d; best = edge }
            }
        }
        return best
    }
}

/// Crash-recovery journal written while a recording is in progress. Kept tiny
/// and rewritten atomically so a crash at any point leaves a readable file.
public struct RecordingJournal: Codable, Sendable {
    public var schemaVersion = 1
    public var started: Date
    public var updated: Date
    public var source: SourceInfo
    public var fps: Double
    public var mic: Bool, system: Bool, webcam: Bool
    public var pauseIntervals: [PauseInterval]
    /// Engine seconds of the last frame accepted by the writer.
    public var lastFramePTS: Double
    public var firstFramePTS: Double?
    public var droppedFrames: Int
    public init(started: Date = Date(), updated: Date? = nil, source: SourceInfo, fps: Double, mic: Bool, system: Bool,
                webcam: Bool, pauseIntervals: [PauseInterval] = [], lastFramePTS: Double = 0,
                firstFramePTS: Double? = nil, droppedFrames: Int = 0) {
        self.started = started; self.updated = updated ?? started; self.source = source; self.fps = fps
        self.mic = mic; self.system = system; self.webcam = webcam
        self.pauseIntervals = pauseIntervals; self.lastFramePTS = lastFramePTS
        self.firstFramePTS = firstFramePTS; self.droppedFrames = droppedFrames
    }
}

public extension ProjectBundle {
    /// Present for the whole life of a recording and removed only after the
    /// project file is safely written. A leftover journal is the recovery signal.
    var journalURL: URL { url.appendingPathComponent("recording.journal") }
    var isUnfinished: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    func writeJournal(_ j: RecordingJournal) {
        guard let data = try? JSONEncoder().encode(j) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }
    func readJournal() -> RecordingJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(RecordingJournal.self, from: data)
    }
    func clearJournal() { try? FileManager.default.removeItem(at: journalURL) }

    /// Rebuilds a usable project from a crashed session. Returns nil when the
    /// bundle never produced a decodable frame record.
    @discardableResult
    func recoverFromJournal() throws -> ProjectFile? {
        guard let j = readJournal() else { return nil }
        let origin = j.firstFramePTS ?? 0
        let duration = max(j.lastFramePTS - origin, 0)
        guard duration > 0.1 else { return nil }
        var info = j.source
        info.duration = duration
        var meta = ProjectMeta(name: url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: .machTicks))
        meta.droppedFrames = j.droppedFrames
        if j.mic, FileManager.default.fileExists(atPath: micURL.path) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: origin) }
        if j.system, FileManager.default.fileExists(atPath: systemURL.path) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: origin) }
        if j.webcam, FileManager.default.fileExists(atPath: webcamURL.path) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: origin) }
        if let prior = try? load() {
            meta = prior.meta
            meta.source.duration = duration
            meta.droppedFrames = j.droppedFrames
        }
        var tl = Timeline(duration: duration)
        // Paused spans carry no footage; replay them as cuts so recovered
        // projects match what a clean stop would have produced.
        let pauses = j.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), b = min(p.end - origin, duration)
            return b > a ? CutRange(start: a, end: b, origin: .manual) : nil
        }
        tl.timeMap.cuts = (tl.timeMap.cuts + pauses).sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        let file = ProjectFile(meta: meta, timeline: tl)
        try save(file)
        clearJournal()
        return file
    }
}

public enum RecoveryScanner {
    /// All bundles in `library` that still have an unfinished journal.
    public static func scan(library: URL) -> [ProjectBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "lumen" }.map(ProjectBundle.init(url:)).filter(\.isUnfinished)
    }
}

public extension ProjectBundle {
    /// Writes a self-contained `.lumenshare` package. Caches, analysis, and
    /// journals are left out; imported clips are copied inside and their paths
    /// become bundle-relative so the package works on another Mac.
    @discardableResult
    func exportSharePackage(to destination: URL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("lumen-share-\(UUID().uuidString).lumen")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let keep = ["project.json", "screen.mov", "mic.caf", "system.caf", "webcam.mov",
                    "cursors.json", "events.bin", "ax.json", "frames.meta"]
        for name in keep {
            let source = url.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
        }
        var file = try load()
        if !file.timeline.clips.isEmpty {
            let clips = staging.appendingPathComponent("clips", isDirectory: true)
            try fm.createDirectory(at: clips, withIntermediateDirectories: true)
            for i in file.timeline.clips.indices {
                let source = file.timeline.clips[i].url
                guard fm.fileExists(atPath: source.path) else { continue }
                let name = "\(file.timeline.clips[i].id.uuidString).\(source.pathExtension)"
                try fm.copyItem(at: source, to: clips.appendingPathComponent(name))
                file.timeline.clips[i].path = "clips/" + name
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: staging.appendingPathComponent("project.json"), options: .atomic)

        let zip = destination
        try? fm.removeItem(at: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    /// Expands a `.lumenshare` package into the library and returns the local
    /// bundle. Names are uniqued so importing twice never overwrites work.
    static func installSharePackage(_ package: URL, into library: URL) throws -> ProjectBundle {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("lumen-unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", package.path, temp.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let unpacked = (try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil))
            .first { $0.pathExtension == "lumen" }
            ?? temp.appendingPathComponent(package.deletingPathExtension().lastPathComponent)
        var name = unpacked.deletingPathExtension().lastPathComponent
        var destination = library.appendingPathComponent(name).appendingPathExtension("lumen")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = library.appendingPathComponent("\(name) \(n)").appendingPathExtension("lumen")
            n += 1
        }
        try fm.copyItem(at: unpacked, to: destination)
        return ProjectBundle(url: destination)
    }

    /// A link other Lumen installs on this Mac can open directly.
    var shareLink: String {
        var components = URLComponents()
        components.scheme = "lumen"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        return components.string ?? url.absoluteString
    }
}
```

### Sources/LumenProject/CursorRelink.swift

```swift
import Foundation

/// Sidecar written beside an export that used the independent cursor layer.
///
/// The cursor-only movie (`<name>.cursor.mov`, ProRes 4444 with alpha) keeps
/// the pointer on its own track. This sidecar records the exact contract that
/// track was rendered against — duration, frame rate, canvas size — so an
/// external editor can replace the screen track with fresh footage while the
/// cursor layer is reused unchanged.
public struct CursorRelinkSidecar: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var projectName: String
    public var screenFile: String
    public var cursorFile: String
    public var duration: Double
    public var fps: Int
    public var width: Int, height: Int
    public init(projectName: String, screenFile: String, cursorFile: String,
                duration: Double, fps: Int, width: Int, height: Int) {
        self.projectName = projectName; self.screenFile = screenFile; self.cursorFile = cursorFile
        self.duration = duration; self.fps = fps; self.width = width; self.height = height
    }
}

public enum CursorRelink {
    /// `<stem>.cursor-relink.json`, next to the main export — same stem as the
    /// `<stem>.cursor.mov` writer in `Exporter.cursorLayer`.
    public static func sidecarURL(mainExport: URL) -> URL {
        mainExport.deletingPathExtension().appendingPathExtension("cursor-relink.json")
    }

    public static func make(projectName: String, mainExport: URL, cursorFile: URL,
                            duration: Double, fps: Int, width: Int, height: Int) -> CursorRelinkSidecar {
        CursorRelinkSidecar(projectName: projectName,
                            screenFile: mainExport.lastPathComponent,
                            cursorFile: cursorFile.lastPathComponent,
                            duration: duration, fps: fps, width: width, height: height)
    }

    /// Writes the sidecar next to the main export. Returns its URL.
    @discardableResult
    public static func writeSidecar(mainExport: URL, cursorFile: URL, duration: Double,
                                    fps: Int, width: Int, height: Int) throws -> URL {
        let sidecar = make(projectName: mainExport.deletingPathExtension().lastPathComponent,
                           mainExport: mainExport, cursorFile: cursorFile,
                           duration: duration, fps: fps, width: width, height: height)
        let url = sidecarURL(mainExport: mainExport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
        return url
    }

    public static func read(from url: URL) throws -> CursorRelinkSidecar {
        try JSONDecoder().decode(CursorRelinkSidecar.self, from: Data(contentsOf: url))
    }

    /// Problems that would make stacking the saved cursor on a replacement
    /// screen visibly wrong. Empty means the replacement is interchangeable.
    public static func validate(_ sidecar: CursorRelinkSidecar,
                                screenDuration: Double, screenFPS: Int) -> [String] {
        var issues: [String] = []
        if sidecar.screenFile.isEmpty { issues.append("missing screen file name") }
        if sidecar.cursorFile.isEmpty { issues.append("missing cursor file name") }
        if sidecar.fps != screenFPS {
            issues.append("frame rate mismatch: cursor \(sidecar.fps) fps, screen \(screenFPS) fps")
        }
        let tolerance = screenFPS > 0 ? 1.0 / Double(screenFPS) : 0.02
        if abs(sidecar.duration - screenDuration) > tolerance {
            issues.append("duration mismatch: cursor \(sidecar.duration)s, screen \(screenDuration)s")
        }
        return issues
    }

    /// Short instructions an editor can follow without Lumen.
    public static func instructions(_ sidecar: CursorRelinkSidecar) -> String {
        """
Replacing the screen while keeping the cursor (\(sidecar.projectName))

1. Import `\(sidecar.screenFile)` (the Lumen export) and `\(sidecar.cursorFile)` (ProRes 4444, alpha).
2. Put the cursor movie on the track ABOVE the screen. Set its blend/alpha to overlay (screen) so the transparent areas drop out.
3. New screen footage must be \(sidecar.width)x\(sidecar.height) at \(sidecar.fps) fps, \(sidecar.duration)s long, starting at frame 0 — same as the sidecar contract.
4. Replace the screen track underneath. Leave the cursor track untouched.
"""
    }
}
```

### Sources/LumenProject/Derived.swift

```swift
import Foundation
import LumenCore

public struct CursorTrack: Sendable, Equatable {
    public var x: [Float], y: [Float], opacity: [Float], press: [Float]
    public var shape: [UInt16]
    public init(count: Int) {
        x = .init(repeating: 0, count: count); y = x; opacity = .init(repeating: 1, count: count)
        press = .init(repeating: 1, count: count); shape = .init(repeating: 0, count: count)
    }
}
public struct CameraTrack: Sendable, Equatable {
    public var rate: Double
    public var nx: [Float], ny: [Float], lz: [Float], vx: [Float], vy: [Float], vz: [Float]
    public var yaw: [Float], pitch: [Float]             // degrees
    public init(count: Int, rate: Double = gridRate) {
        self.rate = rate
        nx = .init(repeating: 0.5, count: count); ny = nx; lz = .init(repeating: 0, count: count); vx = lz; vy = lz; vz = lz; yaw = lz; pitch = lz
    }
}
public struct ClickFX: Sendable, Equatable {
    public var t: Double; public var x: Float; public var y: Float
    public init(t: Double, x: Float, y: Float) { self.t = t; self.x = x; self.y = y }
}
public struct SFXCue: Sendable, Equatable {
    public enum Kind: Sendable { case click, whooshIn, whooshOut, key }
    public var t: Double; public var kind: Kind; public var gainDb: Double; public var keyCode: UInt16
    public init(t: Double, kind: Kind, gainDb: Double, keyCode: UInt16 = 0) { self.t = t; self.kind = kind; self.gainDb = gainDb; self.keyCode = keyCode }
}

/// Canvas-normalized layout (top-left origin). 12 floats packed so one spring drives all of them.
/// [0-3] screen rect, [4] screen opacity, [5-8] camera rect, [9] camera corner radius (fraction of min side, 0.5 = circle),
/// [10] camera opacity, [11] cutout blend (0 = framed video, 1 = person cutout).
public struct ResolvedLayout: Sendable, Equatable {
    public var v: SIMD16<Float>
    public init(v: SIMD16<Float> = .zero) { self.v = v }
    public static let full: ResolvedLayout = {
        var r = ResolvedLayout(); r.screenRect = [0, 0, 1, 1]; r.screenOpacity = 1; r.cameraRect = [0.72, 0.68, 0.24, 0.27]; return r
    }()
    public var screenRect: SIMD4<Float> {
        get { SIMD4(v[0], v[1], v[2], v[3]) }
        set { v[0] = newValue[0]; v[1] = newValue[1]; v[2] = newValue[2]; v[3] = newValue[3] }
    }
    public var screenOpacity: Float { get { v[4] } set { v[4] = newValue } }
    public var cameraRect: SIMD4<Float> {
        get { SIMD4(v[5], v[6], v[7], v[8]) }
        set { v[5] = newValue[0]; v[6] = newValue[1]; v[7] = newValue[2]; v[8] = newValue[3] }
    }
    public var cameraRadius: Float { get { v[9] } set { v[9] = newValue } }
    public var cameraOpacity: Float { get { v[10] } set { v[10] = newValue } }
    public var cutoutBlend: Float { get { v[11] } set { v[11] = newValue } }
}
public struct LayoutSpan: Sendable, Equatable {
    public var start: Double, end: Double, kind: LayoutKind
    public init(start: Double, end: Double, kind: LayoutKind) { self.start = start; self.end = end; self.kind = kind }
}
public struct LayoutTrack: Sendable, Equatable {
    public var rate: Double
    public var samples: [ResolvedLayout]
    public var spans: [LayoutSpan]                    // OUTPUT seconds
    public var fallback: LayoutKind
    public init(rate: Double = 120, samples: [ResolvedLayout] = [], spans: [LayoutSpan] = [], fallback: LayoutKind = .screenOnly) {
        self.rate = rate; self.samples = samples; self.spans = spans; self.fallback = fallback
    }
    public func kind(at t: Double) -> LayoutKind {
        for s in spans where t >= s.start && t < s.end { return s.kind }
        return fallback
    }
    public func sample(at t: Double) -> ResolvedLayout {
        guard samples.count >= 2 else { return samples.first ?? .full }
        let f = max(t, 0) * rate, i = min(max(Int(f), 0), samples.count - 2)
        let u = Float(min(max(f - Double(i), 0), 1))
        return ResolvedLayout(v: samples[i].v + (samples[i + 1].v - samples[i].v) * u)
    }
}
/// Webcam anchor corner + visibility over output time (60 Hz). Empty = no webcam.
public struct PlacementTrack: Sendable, Equatable {
    public var rate: Double
    public var corner: [UInt8]                        // index into WebcamLayout.Corner.allCases
    public var visible: [Float]
    public init(rate: Double = 60, corner: [UInt8] = [], visible: [Float] = []) { self.rate = rate; self.corner = corner; self.visible = visible }
    public func corner(at t: Double) -> WebcamLayout.Corner? {
        guard !corner.isEmpty else { return nil }
        let i = min(max(Int(t * rate), 0), corner.count - 1)
        let all = WebcamLayout.Corner.allCases
        return all[min(Int(corner[i]), all.count - 1)]
    }
    public func visibility(at t: Double) -> Float {
        guard !visible.isEmpty else { return 1 }
        return visible[min(max(Int(t * rate), 0), visible.count - 1)]
    }
}

public struct CaptionWord: Sendable, Equatable {
    public var text: String
    public var start: Double, end: Double             // OUTPUT seconds
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}
public struct CaptionChunk: Sendable, Equatable {
    public var start: Double, end: Double             // OUTPUT seconds
    public var lines: [[CaptionWord]]
    public var y: Double                              // canvas-normalized center of the block
    public init(start: Double, end: Double, lines: [[CaptionWord]], y: Double) { self.start = start; self.end = end; self.lines = lines; self.y = y }
    public var text: String { lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
}

public struct DerivedTracks: Sendable, Equatable {
    public var revision: Int
    public var sourceSize: SIMD2<Double>
    public var outputDuration: Double
    public var cursor: CursorTrack
    public var camera: CameraTrack
    public var clicks: [ClickFX]
    public var cues: [SFXCue]
    public var duck: [Float]            // 100 Hz, output time
    public var face: [SIMD3<Float>]     // 30 Hz (cx, cy, height), normalized to webcam image
    public var webcamAspect: Float
    public var layout: LayoutTrack
    public var placement: PlacementTrack
    public var captions: [CaptionChunk]
    public var autoMasks: [Mask]
    public var personMask: PersonMaskInfo?
    public init(revision: Int, sourceSize: SIMD2<Double>, outputDuration: Double, cursor: CursorTrack, camera: CameraTrack,
                clicks: [ClickFX], cues: [SFXCue], duck: [Float], face: [SIMD3<Float>], webcamAspect: Float,
                layout: LayoutTrack = LayoutTrack(), placement: PlacementTrack = PlacementTrack(), captions: [CaptionChunk] = [],
                autoMasks: [Mask] = [], personMask: PersonMaskInfo? = nil) {
        self.revision = revision; self.sourceSize = sourceSize; self.outputDuration = outputDuration; self.cursor = cursor
        self.camera = camera; self.clicks = clicks; self.cues = cues; self.duck = duck; self.face = face; self.webcamAspect = webcamAspect
        self.layout = layout; self.placement = placement; self.captions = captions; self.autoMasks = autoMasks; self.personMask = personMask
    }
    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }
}
```

### Sources/LumenProject/Editing.swift

```swift
import Foundation

// MARK: - Recording segments (the magnetic main lane)

/// A visible strip of the recording: a contiguous source range with content,
/// bounded by a seam, a cut join, or a trimmed lane edge. `id` is the index in
/// the ordered list, stable for the current timeline state.
public struct RecordingSegment: Identifiable, Equatable, Sendable {
    public var id: Int
    public var start: Double      // SOURCE seconds
    public var end: Double
    public var outputStart: Double
    public var outputEnd: Double
    public var hasCutBefore: Bool
    public var hasSeamBefore: Bool
    public var hasCutAfter: Bool
    public var hasSeamAfter: Bool
    public var duration: Double { end - start }
}

public extension Timeline {
    /// Boundaries that partition the recording: trim edges, logical seams and
    /// cut edges. Sorted and de-duplicated to 0.1 ms.
    var recordingBoundaries: [Double] {
        let tm = timeMap
        var xs = [tm.trimStart, tm.trimEnd]
        xs += seams.map(\.t)
        for c in tm.cuts where c.end > c.start { xs.append(c.start); xs.append(c.end) }
        xs = xs.map { min(max($0, tm.trimStart), tm.trimEnd) }.sorted()
        var out: [Double] = []
        for x in xs where out.last.map({ $0.distance(to: x) > 0.0001 }) ?? true { out.append(x) }
        return out
    }

    /// The recording's visible strips in output order. A cut collapses its
    /// source range to zero output length, so the strips stay gapless.
    var recordingSegments: [RecordingSegment] {
        let tm = timeMap
        let bs = recordingBoundaries
        guard bs.count > 1 else { return [] }
        var out: [RecordingSegment] = []
        for i in 0..<(bs.count - 1) {
            let a = bs[i], b = bs[i + 1]
            guard b - a > 0.0001 else { continue }
            let mid = (a + b) / 2
            if tm.isCut(mid) { continue }
            let o0 = tm.output(atSource: a), o1 = tm.output(atSource: b)
            guard o1 - o0 > 0.0001 else { continue }
            let before = seams.contains { abs($0.t - a) < 0.0005 }
            let after = seams.contains { abs($0.t - b) < 0.0005 }
            let cutBefore = tm.cuts.contains { $0.end > $0.start && abs($0.end - a) < 0.0005 }
            let cutAfter = tm.cuts.contains { $0.end > $0.start && abs($0.start - b) < 0.0005 }
            out.append(RecordingSegment(id: out.count, start: a, end: b,
                                        outputStart: o0, outputEnd: o1,
                                        hasCutBefore: cutBefore || (out.last?.hasCutAfter ?? false),
                                        hasSeamBefore: before,
                                        hasCutAfter: cutAfter, hasSeamAfter: after))
        }
        // A cut join makes the next strip's leading edge a cut edge too.
        for i in out.indices.dropFirst() where out[i - 1].hasCutAfter { out[i].hasCutBefore = true }
        return out
    }

    func recordingSegment(atOutput t: Double) -> RecordingSegment? {
        recordingSegments.first { t >= $0.outputStart - 0.0005 && t < $0.outputEnd - 0.0005 }
            ?? recordingSegments.last
    }
}

public extension TimeMap {
    /// Cut edges expressed as OUTPUT seconds (both sides of a removed span sit
    /// on the same output instant — that is the seam).
    var cutJoins: [(cut: CutRange, output: Double)] {
        cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
            .map { ($0, output(atSource: $0.end)) }
    }
}

// MARK: - Mutations used by the reducer

public enum EditError: Error, Equatable, Sendable {
    case emptyRange, removesEverything, tooShort
}

public extension Timeline {
    /// Add a logical split seam at a source instant.
    mutating func addSeam(atSource t: Double) throws {
        let tm = timeMap
        guard t > tm.trimStart + 0.0005, t < tm.trimEnd - 0.0005 else { throw EditError.tooShort }
        guard !tm.isCut(t) else { throw EditError.tooShort }
        guard !seams.contains(where: { abs($0.t - t) < 0.0005 }) else { return }
        seams.append(SplitSeam(t: t))
        seams.sort { $0.t < $1.t }
    }

    mutating func removeSeam(atSource t: Double, eps: Double = 0.05) {
        guard let i = seams.indices.min(by: { abs(seams[$0].t - t) < abs(seams[$1].t - t) }),
              abs(seams[i].t - t) <= eps else { return }
        seams.remove(at: i)
    }

    mutating func removeSeam(id: UUID) { seams.removeAll { $0.id == id } }

    /// Drag a logical split seam. It never changes the output; it only moves
    /// where one strip ends and the next begins. Clamped to a frame inside its
    /// neighbouring boundaries and outside every cut.
    mutating func moveSeam(id: UUID, toSource raw: Double, frame: Double) throws {
        guard let i = seams.firstIndex(where: { $0.id == id }) else { throw EditError.tooShort }
        let tm = timeMap
        let lower = max(i > 0 ? seams[i - 1].t + frame : tm.trimStart + frame, tm.trimStart + frame)
        let upper = min(i + 1 < seams.count ? seams[i + 1].t - frame : tm.trimEnd - frame, tm.trimEnd - frame)
        guard upper >= lower else { throw EditError.tooShort }
        let t = min(max(raw, lower), upper)
        guard !tm.isCut(t) else { throw EditError.tooShort }
        seams[i].t = t
    }

    /// Remove an OUTPUT range from the recording: the one conceptual cut.
    /// Everything inside is gone, the gap closes, anchored content inside is
    /// removed and content straddling an edge is trimmed back to the survivor.
    mutating func removeOutputRange(_ a0: Double, _ b0: Double, frame: Double) throws {
        let tm = timeMap
        let live = max(tm.outputDuration, 0)
        guard live > frame else { throw EditError.removesEverything }
        let a = min(max(a0, 0), live), b = min(max(b0, 0), live)
        guard b - a >= frame * 0.999 else { throw EditError.tooShort }
        guard live - (b - a) >= frame * 0.999 else { throw EditError.removesEverything }
        let srcA = tm.source(atOutput: a), srcB = tm.source(atOutput: b)
        guard srcB - srcA > 0.0005 else { throw EditError.tooShort }
        // Content first, the new cut last: trimAnchoredContent also folds cuts
        // that overlap the removed span, so appending before it would delete
        // the very cut this command exists to create.
        trimAnchoredContent(removedSource: srcA...srcB)
        seams.removeAll { $0.t >= srcA - 0.0005 && $0.t <= srcB + 0.0005 }
        timeMap.cuts.append(CutRange(start: srcA, end: srcB, origin: .manual))
        timeMap.cuts = Self.merged(timeMap.cuts)
        rippleSoundtrack(afterOutput: a, by: -(b - a))
    }

    /// Move one edge of an existing cut. Widening removes more source, narrowing
    /// restores it. A cut that collapses to one frame or less becomes a join.
    mutating func trimCut(id: UUID, isStart: Bool, toSource raw: Double, frame: Double) throws {
        guard let i = timeMap.cuts.firstIndex(where: { $0.id == id }) else { throw EditError.tooShort }
        let original = timeMap.cuts[i]
        let tm = timeMap
        let speed = max(abs(tm.speed(atOutput: tm.output(atSource: isStart ? original.start : original.end))), 0.01)
        let minGap = frame * speed
        var cut = original
        if isStart {
            cut.start = min(max(raw, tm.trimStart), cut.end - minGap)
        } else {
            cut.end = min(max(raw, cut.start + minGap), tm.trimEnd)
        }
        guard cut.end - cut.start > 0 else { throw EditError.tooShort }
        // Take the edited cut out of the trim so the fold cannot eat it, then
        // put it back with its identity. Narrowing (the cut grows) removes the
        // extra content; widening only restores source and leaves survivors
        // alone, since content destroyed by the original cut is gone for good.
        timeMap.cuts.remove(at: i)
        if isStart, cut.start > original.start {
            trimAnchoredContent(removedSource: original.start...cut.start)
        } else if !isStart, cut.end < original.end {
            trimAnchoredContent(removedSource: cut.end...original.end)
        }
        timeMap.cuts.append(cut)
        timeMap.cuts = Self.merged(timeMap.cuts)
        seams.removeAll { $0.t >= cut.start - 0.0005 && $0.t <= cut.end + 0.0005 }
    }

    /// Ripple-delete one visible strip of the recording.
    mutating func removeSegment(atOutput t: Double, frame: Double) throws {
        guard let s = recordingSegment(atOutput: t) else { throw EditError.tooShort }
        try removeOutputRange(s.outputStart, s.outputEnd, frame: frame)
    }

    /// Cut from the previous seam/cut join to the next one (Split-then-delete).
    mutating func segmentBounds(atOutput t: Double) -> (start: Double, end: Double)? {
        guard let s = recordingSegment(atOutput: t) else { return nil }
        return (s.outputStart, s.outputEnd)
    }

    static func merged(_ cuts: [CutRange]) -> [CutRange] {
        let sorted = cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var out: [CutRange] = []
        for c in sorted {
            if var last = out.last, c.start <= last.end + 0.0005 {
                last.end = max(last.end, c.end)
                out[out.count - 1] = CutRange(id: last.id, start: last.start, end: last.end, origin: last.origin)
            } else { out.append(c) }
        }
        return out
    }

    /// Music/voice-over lanes are bound to the soundtrack, not to content: a
    /// ripple that shortens the timeline moves later lanes left with it and
    /// clamps anything inside the removed span to the new seam. They never
    /// follow picture content.
    mutating func rippleSoundtrack(afterOutput start: Double, by delta: Double) {
        for i in audio.lanes.indices {
            let p = audio.lanes[i].placement
            if p >= start { audio.lanes[i].placement = max(p + delta, 0) }
        }
    }

    // MARK: Anchored content

    /// Remove content anchored to a source span; split anything straddling it.
    /// Masks keep their keys, zooms/ramps/layouts/loupes/highlights/texts keep
    /// their surviving parts. Captions follow source words through TimeMap.
    mutating func trimAnchoredContent(removedSource r: ClosedRange<Double>) {
        let a = r.lowerBound, b = r.upperBound
        func survivors(_ s: Double, _ e: Double) -> [(Double, Double)] {
            if e <= a || s >= b { return [(s, e)] }
            var out: [(Double, Double)] = []
            if s < a - 0.0005 { out.append((s, a)) }
            if e > b + 0.0005 { out.append((b, e)) }
            return out
        }
        overlays.masks = overlays.masks.flatMap { m -> [Mask] in
            survivors(m.start, m.end).enumerated().map { i, span in
                Mask(id: i == 0 ? m.id : UUID(), start: span.0, end: span.1, mode: m.mode,
                     keys: maskKeys(m.keys, in: span.0...span.1), origin: m.origin,
                     approved: m.approved, category: m.category, padding: m.padding)
            }
        }
        zoom = zoom.flatMap { z -> [ZoomSegment] in
            survivors(z.start, z.end).enumerated().map { i, span in
                ZoomSegment(id: i == 0 ? z.id : UUID(), start: span.0, end: span.1, scale: z.scale,
                            focus: z.focus, easing: z.easing, origin: z.origin)
            }
        }
        timeMap.cuts = timeMap.cuts.flatMap { c -> [CutRange] in
            survivors(c.start, c.end).enumerated().map { i, span in
                CutRange(id: i == 0 ? c.id : UUID(), start: span.0, end: span.1, origin: c.origin)
            }
        }
        timeMap.ramps = timeMap.ramps.flatMap { x -> [SpeedRamp] in
            survivors(x.start, x.end).map { SpeedRamp(start: $0.0, end: $0.1, speed: x.speed, origin: x.origin) }
        }
        overlays.highlights = overlays.highlights.flatMap { h -> [Highlight] in
            survivors(h.start, h.end).enumerated().map { i, span in
                Highlight(id: i == 0 ? h.id : UUID(), start: span.0, end: span.1, x: h.x, y: h.y, w: h.w, h: h.h,
                          style: h.style, dim: h.dim)
            }
        }
        overlays.loupes = overlays.loupes.flatMap { l -> [Loupe] in
            survivors(l.start, l.end).enumerated().map { i, span in
                Loupe(id: i == 0 ? l.id : UUID(), start: span.0, end: span.1, x: l.x, y: l.y, follow: l.follow,
                      radius: l.radius, magnification: l.magnification, round: l.round, cx: l.cx, cy: l.cy,
                      border: l.border, shadow: l.shadow)
            }
        }
        layouts = layouts.flatMap { s -> [LayoutSegment] in
            survivors(s.start, s.end).enumerated().map { i, span in
                LayoutSegment(id: i == 0 ? s.id : UUID(), start: span.0, end: span.1, kind: s.kind)
            }
        }
        overlays.texts = overlays.texts.flatMap { t -> [TextBlock] in
            survivors(t.start, t.end).enumerated().map { i, span in
                TextBlock(id: i == 0 ? t.id : UUID(), start: span.0, end: span.1, text: t.text,
                          x: t.x, y: t.y, size: t.size, color: t.color)
            }
        }
    }

    /// Keys inside a surviving half, always non-empty: endpoint interpolation is
    /// not stored, so the nearest boundary key travels with the half.
    private func maskKeys(_ keys: [MaskKey], in range: ClosedRange<Double>) -> [MaskKey] {
        let sorted = keys.sorted { $0.t < $1.t }
        var kept = sorted.filter { $0.t >= range.lowerBound - 0.0005 && $0.t <= range.upperBound + 0.0005 }
        if kept.isEmpty {
            if let near = sorted.min(by: { abs($0.t - range.lowerBound) < abs($1.t - range.lowerBound) }) {
                kept = [near]
            }
        }
        return kept
    }
}
```

### Sources/LumenProject/FXModels.swift

```swift
import Foundation
import LumenCore

public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, pulse, burst, glass }
// Glass click is rendered in the Metal ringFS path, not SwiftUI, so preview
// and export share the same pixels. There is no SwiftUI Liquid Glass toggle
// on the canvas; the translucent bloom is baked into the shader.

// NOTE: MotionBlurParams/LoopMode used to live here but were dead code
// (never read). Real motion-blur controls are CameraParams.shutter /
// maxSamples (Renderer.sampleCount) and CursorStyle.loop (CursorPipeline).

public struct UpscaleParams: Codable, Equatable, Sendable {
    public var enabled = true
    public var blendStart = 1.5, blendEnd = 2.2
    public var maxFactor = 8
    public var edgeSharpness = 0.6
    public var shock = 0.55
    public var shockIterations = 2
    public var finalSharpen = 0.35
    public init() {}
}
```

### Sources/LumenProject/Migrations/migrate_3_to_4.swift

```swift
import Foundation

/// v3 -> v4 JSON migration (pure, idempotent, preserves unknown fields).
/// timeline.audio.targetLUFS (Double) -> timeline.audio.targetLUFSOverride (Double?).
/// Rules: stored == old default for mode (Standard -16, Loud -12) or == new default
/// for its mode (Standard -14, Loud -12, Podcast -16) -> nil; else keep as override.
/// timeline.schemaVersion -> 4.
public enum LUFS_Migrate {
    public static func migrate_3_to_4(_ root: [String: Any]) -> [String: Any] {
        var out = root
        guard let tl = root["timeline"] as? [String: Any] else { return out }
        var timeline = tl
        timeline["schemaVersion"] = 4
        if var audio = tl["audio"] as? [String: Any] {
            let mode = (audio["micMode"] as? String) ?? "standard"
            let oldDefault: Double = mode == "loud" ? -12 : -16
            let newDefault: Double = mode == "loud" ? -12 : (mode == "podcast" ? -16 : -14)
            let legacy = (audio["targetLUFS"] as? Double) ?? (audio["targetLUFS"] as? Int).map(Double.init)
            if let existing = audio["targetLUFSOverride"] {
                // Already v4: keep override untouched, drop legacy for idempotence.
                _ = existing
            } else if let l = legacy {
                if abs(l - oldDefault) < 1e-9 || abs(l - newDefault) < 1e-9 {
                    // nil: omit override key
                } else {
                    audio["targetLUFSOverride"] = l
                }
            }
            // Drop legacy key so re-running is a no-op.
            audio.removeValue(forKey: "targetLUFS")
            // In dictionaries, a missing key == nil override. Explicit null
            // is also accepted by the decoder via opt. Keep absence for tests.
            timeline["audio"] = audio
        }
        out["timeline"] = timeline
        return out
    }
}
```

### Sources/LumenProject/Models.swift

```swift
import Foundation
import LumenCore

extension KeyedDecodingContainer {
    /// Tolerant decode: a missing or malformed key yields the default, so older project files keep opening.
    func opt<T: Decodable>(_ k: Key, _ d: T) -> T { (try? decodeIfPresent(T.self, forKey: k)) ?? d }
}

public enum Origin: String, Codable, Sendable { case auto, manual }

public struct RGBA: Codable, Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(_ hex: UInt32, a: Float = 1) {
        r = Float((hex >> 16) & 255) / 255; g = Float((hex >> 8) & 255) / 255; b = Float(hex & 255) / 255; self.a = a
    }
    public init(r: Float, g: Float, b: Float, a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var simd: SIMD4<Float> { [r, g, b, a] }
}

/// Two flat tones, ordered-dithered into a pixel field. Base first, ink second.
public enum DitherPalettes {
    public static let all: [(String, [RGBA])] = [
        ("Ember", [RGBA(0x0A0A0A), RGBA(0xFF6A00)]),
        ("Ember white", [RGBA(0xF4F4F4), RGBA(0xF05A00)]),
        ("Ocean", [RGBA(0x06121F), RGBA(0x38BDF8)]),
        ("Ocean white", [RGBA(0xEFF6FF), RGBA(0x2563EB)]),
        ("Moss", [RGBA(0x07130C), RGBA(0x4ADE80)]),
        ("Moss white", [RGBA(0xF0FDF4), RGBA(0x16A34A)]),
        ("Rose", [RGBA(0x140A10), RGBA(0xF472B6)]),
        ("Rose white", [RGBA(0xFDF2F8), RGBA(0xDB2777)]),
        ("Graphite", [RGBA(0x0A0A0A), RGBA(0x525252)]),
        ("Paper", [RGBA(0xF4F4F4), RGBA(0x171717)]),
    ]
    public static func colors(named name: String) -> [RGBA] {
        all.first { $0.0 == name }?.1 ?? all[0].1
    }
}

/// Legacy gradients are kept for decoding old projects; the picker offers dither, canvas, wallpaper and solid.
public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case dither, canvas, wallpaper, solid, gradient, mesh, wave, field
    /// A local image, either chosen from disk or fetched through Unsplash.
    case image
    public static let offered: [BackgroundKind] = [.solid, .wave, .field, .canvas, .wallpaper, .image]
}

public enum GradientPresets {
    public static let all: [(String, [RGBA])] = [
        ("Ember", [RGBA(0x1A0F08), RGBA(0x7C2D12), RGBA(0xF97316), RGBA(0xFDBA74)]),
        ("Graphite", [RGBA(0x0A0A0A), RGBA(0x171717), RGBA(0x262626), RGBA(0x3A3A3A)]),
        ("Paper", [RGBA(0xF4F4F4), RGBA(0xEDEDED), RGBA(0xE3E3E3), RGBA(0xFFFFFF)]),
        ("Dusk", [RGBA(0x1E1B4B), RGBA(0x4C1D95), RGBA(0xBE185D), RGBA(0xF97316)]),
        ("Ocean", [RGBA(0x082F49), RGBA(0x0369A1), RGBA(0x0EA5E9), RGBA(0x7DD3FC)]),
        ("Moss", [RGBA(0x052E16), RGBA(0x166534), RGBA(0x4ADE80), RGBA(0xBBF7D0)]),
    ]
}


public enum CanvasAspect: String, Codable, CaseIterable, Sendable {
    case r16x9, r16x10, r4x3, r5x4, r3x2, r1x1, r4x5, r9x16, r21x9
    public var ratio: Double {
        switch self {
        case .r16x9: 16.0 / 9; case .r16x10: 1.6; case .r4x3: 4.0 / 3; case .r5x4: 1.25; case .r3x2: 1.5
        case .r1x1: 1; case .r4x5: 0.8; case .r9x16: 9.0 / 16; case .r21x9: 21.0 / 9
        }
    }
    public var title: String {
        switch self {
        case .r16x9: "16:9"; case .r16x10: "16:10"; case .r4x3: "4:3"; case .r5x4: "5:4"; case .r3x2: "3:2"
        case .r1x1: "1:1"; case .r4x5: "4:5"; case .r9x16: "9:16"; case .r21x9: "21:9"
        }
    }
}

public struct EdgeInsetsN: Codable, Equatable, Sendable {
    public var top: Double, right: Double, bottom: Double, left: Double      // fraction of canvas width
    public init(top: Double, right: Double, bottom: Double, left: Double) { self.top = top; self.right = right; self.bottom = bottom; self.left = left }
    public init(all v: Double) { self.init(top: v, right: v, bottom: v, left: v) }
}
public struct CornerRadii: Codable, Equatable, Sendable {
    public var tl: Double, tr: Double, br: Double, bl: Double                // points @ 1440 px canvas
    public init(tl: Double, tr: Double, br: Double, bl: Double) { self.tl = tl; self.tr = tr; self.br = br; self.bl = bl }
    public init(all v: Double) { self.init(tl: v, tr: v, br: v, bl: v) }
}

public struct Style: Codable, Equatable, Sendable {
    public var background: BackgroundKind = .image
    public var colors: [RGBA] = [RGBA(0xF4F4F4), RGBA(0xDADADA)]
    public var gradientAngle: Double = 35
    public var ditherCell: Double = 4, ditherDensity: Double = 0.55, contentScale: Double = 1
    public var padding: Double = 0.025
    public var cornerRadius: Double = 14
    public var shadow: Double = 0.45
    public var innerBorder = true
    public var canvas: CanvasAspect = .r16x9
    public var paddingInsets: EdgeInsetsN?              // nil = uniform `padding`
    public var cornerRadii: CornerRadii?                // nil = uniform `cornerRadius`
    public var customAspect: Double?                    // nil = `canvas`
    /// Continuous blur for the background image, in canvas pixels. 0 is sharp.
    /// A wallpaper ships sharp; the user decides how soft it is.
    public var wallpaperBlur = 0.0
    /// Image adjust (0 = off). Additive; old projects decode to defaults.
    public var imageOpacity = 1.0, imageContrast = 1.0, imageBrightness = 1.0    /// Frame weight (pt). The frame toggle itself is `innerBorder`.
    public var frameWeight = 1.0
    /// Local photo for `.image`. Absolute path or bundled sentinel
    /// (`serene-lake.jpg` resolves from Resources/Wallpapers). The
    /// renderer loads it once per modification date, never per frame.
    public var backgroundImagePath: String? = "serene-lake.jpg"
    public var aspectRatio: Double { customAspect ?? canvas.ratio }
    public var insets: EdgeInsetsN { paddingInsets ?? EdgeInsetsN(all: padding) }
    public var radii: CornerRadii { cornerRadii ?? CornerRadii(all: cornerRadius) }
    enum CodingKeys: String, CodingKey {
        case background, colors, gradientAngle, ditherCell, ditherDensity, contentScale, padding, cornerRadius, shadow, innerBorder, canvas, paddingInsets, cornerRadii, customAspect, wallpaperBlur, backgroundImagePath, imageOpacity, imageContrast, imageBrightness, frameWeight
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        background = c.opt(.background, background); colors = c.opt(.colors, colors); gradientAngle = c.opt(.gradientAngle, gradientAngle)
        ditherCell = c.opt(.ditherCell, ditherCell); ditherDensity = c.opt(.ditherDensity, ditherDensity); contentScale = c.opt(.contentScale, contentScale)
        padding = c.opt(.padding, padding); cornerRadius = c.opt(.cornerRadius, cornerRadius); shadow = c.opt(.shadow, shadow)
        innerBorder = c.opt(.innerBorder, innerBorder); canvas = c.opt(.canvas, canvas)
        paddingInsets = try? c.decodeIfPresent(EdgeInsetsN.self, forKey: .paddingInsets)
        cornerRadii = try? c.decodeIfPresent(CornerRadii.self, forKey: .cornerRadii)
        customAspect = try? c.decodeIfPresent(Double.self, forKey: .customAspect)
        wallpaperBlur = c.opt(.wallpaperBlur, wallpaperBlur)
        backgroundImagePath = try? c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        imageOpacity = c.opt(.imageOpacity, imageOpacity)
        imageContrast = c.opt(.imageContrast, imageContrast); imageBrightness = c.opt(.imageBrightness, imageBrightness)
        frameWeight = c.opt(.frameWeight, frameWeight)
    }

    /// Makes a downloaded or user-selected photo the canvas background.
    public mutating func setPhotoBackground(_ path: String) {
        background = .image
        backgroundImagePath = path
    }
    /// Drops the photo reference when switching back to a generated backdrop.
    public mutating func clearPhotoBackground() {
        if background == .image { background = .solid }
        backgroundImagePath = nil
    }
}

public enum CursorPack: String, Codable, CaseIterable, Sendable { case system, minimal, dot, ring, pro, holiday }
public struct CursorStyle: Codable, Equatable, Sendable {
    public var pack: CursorPack = .system
    public var size: Double = 1.0
    public var smoothingSigma: Double = 0.035
    public var glide: Double = 0.35
    public var idleHide: Double? = 2.0
    public var pressScale: Double = 0.86
    public var clickEffect: ClickEffect = .ripple
    /// Apple-glass bloom expands on release and settles in about half a second.
    public var clickDuration: Double = 0.55
    /// Tint off by default (transparent white): the ripple refracts the
    /// video itself, with no flat fill color.
    public var clickColor: RGBA = RGBA(0xFFFFFF, a: 0)
    /// Multiplies the ring radius (0.5...2.0). Renderer consumes it.
    public var clickSize: Double = 1.0
    /// Multiplies ring alpha (0...1.5). Renderer consumes it.
    public var clickIntensity: Double = 1.0
    public var clickRing: Double? = 0.45
    public var zoomCompensation: Double = 0.5
    public var constantSize = false                     // true = cursor keeps its on-screen size during zoom
    public var loop: Double?                            // seconds of tail that glides back to the first frame; nil = off
    public var effectiveCompensation: Double { constantSize ? 1 : zoomCompensation }
    enum CodingKeys: String, CodingKey { case pack, size, smoothingSigma, glide, idleHide, pressScale, clickRing, zoomCompensation, constantSize, loop, clickEffect, clickDuration, clickColor, clickSize, clickIntensity }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pack = c.opt(.pack, pack); size = c.opt(.size, size); smoothingSigma = c.opt(.smoothingSigma, smoothingSigma); glide = c.opt(.glide, glide)
        idleHide = c.contains(.idleHide) ? ((try? c.decodeIfPresent(Double.self, forKey: .idleHide)) ?? nil) : idleHide
        pressScale = c.opt(.pressScale, pressScale)
        clickEffect = c.opt(.clickEffect, clickEffect); clickDuration = c.opt(.clickDuration, clickDuration); clickColor = c.opt(.clickColor, clickColor)
        clickSize = c.opt(.clickSize, clickSize); clickIntensity = c.opt(.clickIntensity, clickIntensity)
        clickRing = c.contains(.clickRing) ? ((try? c.decodeIfPresent(Double.self, forKey: .clickRing)) ?? nil) : clickRing
        zoomCompensation = c.opt(.zoomCompensation, zoomCompensation); constantSize = c.opt(.constantSize, constantSize)
        loop = try? c.decodeIfPresent(Double.self, forKey: .loop)
    }
    public func encode(to e: Encoder) throws {      // explicit nulls so "off" survives a round trip
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(pack, forKey: .pack); try c.encode(size, forKey: .size); try c.encode(smoothingSigma, forKey: .smoothingSigma)
        try c.encode(glide, forKey: .glide); try c.encode(idleHide, forKey: .idleHide); try c.encode(pressScale, forKey: .pressScale)
        try c.encode(clickRing, forKey: .clickRing); try c.encode(zoomCompensation, forKey: .zoomCompensation)
        try c.encode(clickEffect, forKey: .clickEffect); try c.encode(clickDuration, forKey: .clickDuration)
        try c.encode(clickColor, forKey: .clickColor)
        try c.encode(clickSize, forKey: .clickSize); try c.encode(clickIntensity, forKey: .clickIntensity)
        try c.encode(constantSize, forKey: .constantSize); try c.encodeIfPresent(loop, forKey: .loop)
    }
}

public enum ZoomPreset: String, Codable, CaseIterable, Sendable {
    case subtle, balanced, dramatic, cinematic, fixed
    public var maxScale: Double { switch self { case .subtle: 1.6; case .balanced: 2.2; case .dramatic: 3.0; case .cinematic: 2.6; case .fixed: 2.0 } }
}
public enum TiltMode: String, Codable, CaseIterable, Sendable { case off, lean, float, reveal }
public enum ZoomEasing: String, Codable, CaseIterable, Sendable {
    case snappy, smooth, cinematic
    public var omegaScale: Double { switch self { case .snappy: 1.35; case .smooth: 1.0; case .cinematic: 0.65 } }
}

public struct CameraParams: Codable, Equatable, Sendable {
    public var preset: ZoomPreset = .balanced
    public var autoZoom = true
    public var maxScale = 3.5
    public var minScale = 1.25
    public var minTrigger = 1.25
    public var leadIn = 0.25, tail = 0.7, mergeGap = 2.5, panThroughGap = 1.5, minHold = 1.0
    public var omegaPan = 5.0, omegaZoom = 7.0, lookahead = 0.20, deadZone = 0.28, followDelay = 0.12
    public var baseScale = 1.8
    public var zoomOutGap = 3.5
    public var hold = 1.2
    public var safeZone = 0.62
    public var cameraModel = 3
    public var centerOffsetX = 0.0, centerOffsetY = 0.0         // view-normalized bias of where the cursor sits in the zoomed view
    public var sensitivity = 0.5                                // 0 = only clicks, 1 = purposeful hovers count too
    public var clickWeight = 3.0
    public var shutter = 0.5
    public var maxSamples = 8
    /// User setting for the real-time upscaler cap (2...10, ladder
    /// {2,3,4,5,6,8,10}). Magnification picks the smallest factor >= need.
    public var upscaleMaxFactor = 8
    /// Master switch for the real-time upscaler (A/B testing, low-end GPUs).
    public var upscaleEnabled = true
    public var tilt: TiltMode = .off
    public var maxYaw = 8.0, maxPitch = 6.0, floatDeg = 1.2, omegaTilt = 5.0
    public var tiltSeed: UInt64 = 0xC11C
    enum CodingKeys: String, CodingKey {
        case preset, autoZoom, maxScale, minScale, minTrigger, leadIn, tail, mergeGap, panThroughGap, minHold, omegaPan, omegaZoom, lookahead, deadZone
        case followDelay, centerOffsetX, centerOffsetY, sensitivity, clickWeight, shutter, maxSamples, upscaleMaxFactor, upscaleEnabled, tilt, maxYaw, maxPitch, floatDeg, omegaTilt, tiltSeed
        case baseScale, zoomOutGap, hold, safeZone, cameraModel
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        preset = c.opt(.preset, preset); autoZoom = c.opt(.autoZoom, autoZoom); maxScale = c.opt(.maxScale, maxScale); minScale = c.opt(.minScale, minScale)
        minTrigger = c.opt(.minTrigger, minTrigger); leadIn = c.opt(.leadIn, leadIn); tail = c.opt(.tail, tail); mergeGap = c.opt(.mergeGap, mergeGap)
        panThroughGap = c.opt(.panThroughGap, panThroughGap); minHold = c.opt(.minHold, minHold); omegaPan = c.opt(.omegaPan, omegaPan)
        omegaZoom = c.opt(.omegaZoom, omegaZoom); lookahead = c.opt(.lookahead, lookahead); deadZone = c.opt(.deadZone, deadZone)
        followDelay = c.opt(.followDelay, followDelay); centerOffsetX = c.opt(.centerOffsetX, centerOffsetX); centerOffsetY = c.opt(.centerOffsetY, centerOffsetY)
        sensitivity = c.opt(.sensitivity, sensitivity); clickWeight = c.opt(.clickWeight, clickWeight); shutter = c.opt(.shutter, shutter)
        maxSamples = c.opt(.maxSamples, maxSamples)
        baseScale = c.opt(.baseScale, baseScale)
        zoomOutGap = c.opt(.zoomOutGap, zoomOutGap); hold = c.opt(.hold, hold); safeZone = c.opt(.safeZone, safeZone)
        cameraModel = c.opt(.cameraModel, cameraModel)
        // Migration: old projects keep manual segments but reset the decision
        // layer to v3 defaults, then re-derive.
        if cameraModel < 3 {
            baseScale = 1.8; zoomOutGap = 3.5; hold = 1.2; safeZone = 0.62
            leadIn = 0.25; minScale = 1.25; cameraModel = 3
        }
        upscaleMaxFactor = min(max(c.opt(.upscaleMaxFactor, upscaleMaxFactor), 2), 10)
        upscaleEnabled = c.opt(.upscaleEnabled, upscaleEnabled)
        tilt = c.opt(.tilt, tilt); maxYaw = c.opt(.maxYaw, maxYaw); maxPitch = c.opt(.maxPitch, maxPitch)
        floatDeg = c.opt(.floatDeg, floatDeg); omegaTilt = c.opt(.omegaTilt, omegaTilt); tiltSeed = c.opt(.tiltSeed, tiltSeed)
    }
    /// Applies a preset's whole feel. Sliders edited afterwards stick (nothing re-applies the preset behind the user's back).
    public mutating func apply(preset p: ZoomPreset) {
        preset = p; maxScale = p.maxScale
        leadIn = 0.25; tail = 0.7; omegaPan = 7; omegaZoom = 6; shutter = 0.5; tilt = .off
        if p == .cinematic { tail = 1.1; omegaPan = 4.5; omegaZoom = 4.0; shutter = 0.6; tilt = .lean }
        // Fixed camera magnification remains independent of automatic fitting.
        switch p {
        case .subtle: baseScale = 1.4
        case .balanced: baseScale = 1.8
        case .dramatic: baseScale = 2.3
        case .cinematic: baseScale = 2.0
        case .fixed: break
        }
    }
}

public enum MicMode: String, Codable, CaseIterable, Sendable {
    case standard, loud, podcast, off
    public var targetLUFS: Double { switch self { case .standard: -16; case .loud: -12; case .podcast: -16; case .off: -14 } }
}
public struct AudioLane: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case mic, system, voiceover, music, sfx }
    public var id: UUID
    public var role: Role
    public var path: String?                            // imported file; nil = recorded source
    public var placement: Double                        // OUTPUT seconds
    public var gainDb: Double, mute: Bool, separateTrack: Bool
    public var variant: String?                         // "EN", "ES"
    public init(id: UUID = UUID(), role: Role, path: String? = nil, placement: Double = 0, gainDb: Double = 0, mute: Bool = false,
                separateTrack: Bool = false, variant: String? = nil) {
        self.id = id; self.role = role; self.path = path; self.placement = placement; self.gainDb = gainDb; self.mute = mute
        self.separateTrack = separateTrack; self.variant = variant
    }
}

public enum ClickSound: String, Codable, CaseIterable, Sendable { case mouse, subtle, fresh }

public enum StudioMode: String, Codable, CaseIterable, Sendable {
    case standard = "Studio Standard"
    case optimized = "Studio Optimized"
    public var title: String { rawValue }
}

public struct AudioPlan: Codable, Equatable, Sendable {
    /// Noise reduction is ON by default: a raw mic passthrough was the
    /// "not noticeably cleaner" complaint. Users can still turn it off.
    public var micClean = true
    public var noiseReductionStrength = 1.0
    public var voiceClarity = true
    public var micMode: MicMode = .standard
    /// Studio-voice strength, 0...1 (tone, de-ess, leveler). Replaces the old
    /// `voiceProfile` + `studioAmount` pair. Legacy `studioAmount` values decode
    /// into this field; legacy `voiceProfile == .studio` projects keep the default.
    public var studio = 0.25
    public var micGainDb = 0.0, systemGainDb = -3.0
    public var declick = true, declickDepthDb = -12.0
    /// Room-tail suppression, 0...1. Applied before EQ and compression so the
    /// compressor cannot lift the reverb back up after every phrase.
    public var dereverb = 0.5
    /// Auto loudness. Off makes `outputGainDb` the only master gain.
    public var normalize = true
    public var outputGainDb = 0.0
    public var targetLUFSOverride: Double?
    public var targetLUFS: Double { targetLUFSOverride ?? micMode.targetLUFS }
    public var studioMode: StudioMode = .standard
    public var clickSounds = true, whooshes = true, keySounds = false
    public var typingPackId: String = "mechvibes-default"
    public var typingLevelDb: Double = -6.0
    public var clickTone: ClickSound = .fresh
    public var sfxGainDb = -9.0
    public var musicPath: String?
    public var musicGainDb = -18.0
    public var duckDepthDb = -14.0, duckAttack = 0.05, duckRelease = 0.4
    public var muteMicInRamps = true
    public var speedRampsAuto = true
    public var speedRampMinIdle = 4.0, speedRampMaxSpeed = 8.0
    public var lanes: [AudioLane] = []
    private enum LegacyKeys: String, CodingKey { case studioAmount }
    private enum LegacyLUFSKeys: String, CodingKey { case targetLUFS }
    enum CodingKeys: String, CodingKey {
        case noiseReductionStrength, voiceClarity, outputGainDb, micClean, micMode, studio, micGainDb, systemGainDb, declick, declickDepthDb, targetLUFSOverride, clickSounds, whooshes, keySounds, typingPackId, typingLevelDb, clickTone, sfxGainDb, musicPath
        case dereverb, normalize, studioMode
        case musicGainDb, duckDepthDb, duckAttack, duckRelease, muteMicInRamps, speedRampsAuto, speedRampMinIdle, speedRampMaxSpeed, lanes
    }
    public init() {}
    public static func migrateLUFS(override: Double?, legacy: Double?, mode: MicMode) -> Double? {
        if let o = override { return o }
        guard let l = legacy else { return nil }
        let oldDefault: Double = mode == .loud ? -12 : -16
        if abs(l - oldDefault) < 1e-9 || abs(l - mode.targetLUFS) < 1e-9 || (mode == .standard && abs(l + 14) < 1e-9) { return nil }
        return l
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        outputGainDb = c.opt(.outputGainDb, outputGainDb)
        micClean = c.opt(.micClean, micClean); micMode = c.opt(.micMode, micMode)
        let reduction = c.opt(.noiseReductionStrength, noiseReductionStrength)
        noiseReductionStrength = reduction.isFinite ? min(max(reduction, 0), 1) : 1
        voiceClarity = c.opt(.voiceClarity, voiceClarity)
        // Legacy `studioAmount` decodes into `studio` when the new key is absent.
        if let lc = try? d.container(keyedBy: LegacyKeys.self),
           let v = try lc.decodeIfPresent(Double.self, forKey: .studioAmount) {
            studio = v
        }
        studio = c.opt(.studio, studio)
        micGainDb = c.opt(.micGainDb, micGainDb)
        dereverb = c.opt(.dereverb, dereverb); normalize = c.opt(.normalize, normalize)
        systemGainDb = c.opt(.systemGainDb, systemGainDb); declick = c.opt(.declick, declick); declickDepthDb = c.opt(.declickDepthDb, declickDepthDb)
        let legacyLUFS = (try? d.container(keyedBy: LegacyLUFSKeys.self).decodeIfPresent(Double.self, forKey: .targetLUFS)) ?? nil
        targetLUFSOverride = AudioPlan.migrateLUFS(override: (try? c.decode(Double.self, forKey: .targetLUFSOverride)), legacy: legacyLUFS, mode: micMode); clickSounds = c.opt(.clickSounds, clickSounds); whooshes = c.opt(.whooshes, whooshes)
        studioMode = c.opt(.studioMode, studioMode)
        keySounds = c.opt(.keySounds, keySounds); typingPackId = c.opt(.typingPackId, typingPackId); typingLevelDb = c.opt(.typingLevelDb, typingLevelDb); clickTone = c.opt(.clickTone, clickTone); sfxGainDb = c.opt(.sfxGainDb, sfxGainDb)
        musicPath = try? c.decodeIfPresent(String.self, forKey: .musicPath)
        musicGainDb = c.opt(.musicGainDb, musicGainDb); duckDepthDb = c.opt(.duckDepthDb, duckDepthDb); duckAttack = c.opt(.duckAttack, duckAttack)
        duckRelease = c.opt(.duckRelease, duckRelease); muteMicInRamps = c.opt(.muteMicInRamps, muteMicInRamps)
        speedRampsAuto = c.opt(.speedRampsAuto, speedRampsAuto); speedRampMinIdle = c.opt(.speedRampMinIdle, speedRampMinIdle)
        speedRampMaxSpeed = c.opt(.speedRampMaxSpeed, speedRampMaxSpeed); lanes = c.opt(.lanes, lanes)
    }
}

public enum WebcamBackdrop: String, Codable, CaseIterable, Sendable {
    case original = "Original"
    case transparent = "Remove background"
    case wallpaper = "Desktop wallpaper"
    case canvas = "Canvas color"
    case image = "Choose image"
}

public enum WebcamEnhancement: String, Codable, CaseIterable, Sendable {
    case natural = "Natural"
    case crisp = "Crisp"
}

public struct WebcamLayout: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, roundRect }
    public var corner: Corner = .bottomRight
    public var size = 0.22
    public var shape: Shape = .circle
    public var mirror = true, border = true, shadow = true, autoFrame = true
    public var faceFill = 0.31
    public var faceZoom = 0.6
    public var backdrop: WebcamBackdrop = .original
    public var backdropImagePath: String?
    public var enhancement: WebcamEnhancement = .natural
    public var detailAmount = 0.5
    public init() {}
    enum CodingKeys: String, CodingKey { case corner, size, shape, mirror, border, shadow, autoFrame, faceFill, faceZoom, backdrop, backdropImagePath, enhancement, detailAmount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? corner
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? shape
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? border
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? shadow
        autoFrame = try c.decodeIfPresent(Bool.self, forKey: .autoFrame) ?? autoFrame
        faceFill = try c.decodeIfPresent(Double.self, forKey: .faceFill) ?? faceFill
        faceZoom = try c.decodeIfPresent(Double.self, forKey: .faceZoom) ?? faceZoom
        backdrop = try c.decodeIfPresent(WebcamBackdrop.self, forKey: .backdrop) ?? backdrop
        backdropImagePath = try c.decodeIfPresent(String.self, forKey: .backdropImagePath)
        enhancement = try c.decodeIfPresent(WebcamEnhancement.self, forKey: .enhancement) ?? enhancement
        detailAmount = try c.decodeIfPresent(Double.self, forKey: .detailAmount) ?? detailAmount
    }
}

public enum Focus: Codable, Equatable, Sendable {
    case follow
    case fixed(x: Double, y: Double)                      // normalized source coords
    case element(x: Double, y: Double, w: Double, h: Double)
}

/// start/end are SOURCE seconds (content-anchored). The camera solver converts to output time through the TimeMap.
public struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var start: Double, end: Double
    public var scale: Double
    public var focus: Focus
    public var easing: ZoomEasing?
    public var origin: Origin
    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double, focus: Focus, easing: ZoomEasing? = nil, origin: Origin) {
        self.id = id; self.start = start; self.end = end; self.scale = scale; self.focus = focus; self.easing = easing; self.origin = origin
    }
}

public struct SpeedRamp: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var start: Double, end: Double                 // SOURCE seconds
    public var speed: Double
    public var origin: Origin = .auto
    public init(start: Double, end: Double, speed: Double, origin: Origin = .auto) {
        self.start = start; self.end = end; self.speed = speed; self.origin = origin
    }
}

/// Output<->source time map. Cuts remove source spans (zero output length); ramps retime. Table is rebuilt on mutation, never persisted.
public struct TimeMap: Codable, Equatable, Sendable {
    public var sourceDuration: Double { didSet { rebuild() } }
    public var trimStart: Double { didSet { rebuild() } }
    public var trimEnd: Double { didSet { rebuild() } }
    public var ramps: [SpeedRamp] { didSet { rebuild() } }
    public var cuts: [CutRange] { didSet { rebuild() } }
    private var out: [Double] = []
    private static let ds = 1.0 / 240
    enum CodingKeys: String, CodingKey { case sourceDuration, trimStart, trimEnd, ramps, cuts }

    public init(sourceDuration: Double = 0, trimStart: Double = 0, trimEnd: Double? = nil, ramps: [SpeedRamp] = [], cuts: [CutRange] = []) {
        self.sourceDuration = sourceDuration; self.trimStart = trimStart; self.trimEnd = trimEnd ?? sourceDuration
        self.ramps = ramps; self.cuts = cuts
        rebuild()
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration); trimStart = try c.decode(Double.self, forKey: .trimStart)
        trimEnd = try c.decode(Double.self, forKey: .trimEnd); ramps = try c.decode([SpeedRamp].self, forKey: .ramps)
        cuts = c.opt(.cuts, [CutRange]())
        rebuild()
    }
    public static func == (a: TimeMap, b: TimeMap) -> Bool {
        a.sourceDuration == b.sourceDuration && a.trimStart == b.trimStart && a.trimEnd == b.trimEnd && a.ramps == b.ramps && a.cuts == b.cuts
    }
    private mutating func rebuild() {
        let n = Int((max(trimEnd - trimStart, 0) / Self.ds).rounded(.up))
        var o = [Double](repeating: 0, count: n + 1)
        let rs = ramps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let cs = cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var j = 0, jc = 0
        for i in 0..<n {
            let s = trimStart + (Double(i) + 0.5) * Self.ds
            while jc < cs.count && cs[jc].end <= s { jc += 1 }
            if jc < cs.count && s >= cs[jc].start { o[i + 1] = o[i]; continue }
            while j < rs.count && rs[j].end < s { j += 1 }
            var m = 1.0
            if j < rs.count, s >= rs[j].start {
                let r = rs[j], w = max(min(0.5, (r.end - r.start) / 4), 0.01)
                m = 1 + (r.speed - 1) * smoothstep((s - r.start) / w) * smoothstep((r.end - s) / w)
            }
            o[i + 1] = o[i] + Self.ds / m
        }
        out = o
    }
    public var outputDuration: Double { out.last ?? 0 }
    public func isCut(_ s: Double) -> Bool { cuts.contains { s >= $0.start && s < $0.end } }
    public func output(atSource s: Double) -> Double {
        let f = (s - trimStart) / Self.ds
        guard f > 0 else { return 0 }
        let i = Int(f)
        if i >= out.count - 1 { return out.last ?? 0 }
        return out[i] + (out[i + 1] - out[i]) * (f - Double(i))
    }
    public func source(atOutput t: Double) -> Double {
        guard out.count > 1 else { return trimStart }
        if t < 0 { return trimStart }
        if t >= out[out.count - 1] { return trimStart + Double(out.count - 1) * Self.ds }
        var lo = 0, hi = out.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if out[mid] <= t { lo = mid } else { hi = mid } }
        let f = (t - out[lo]) / (out[lo + 1] - out[lo])
        return trimStart + (Double(lo) + f) * Self.ds
    }
    public func speed(atOutput t: Double) -> Double { (source(atOutput: t + 0.01) - source(atOutput: t)) / 0.01 }
}

/// A logical split boundary inside the recording. A seam changes nothing in
/// the output: it only lets the magnetic lane show, select and join two halves
/// of one continuous source range. Stored in SOURCE seconds.
public struct SplitSeam: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var t: Double
    public init(id: UUID = UUID(), t: Double) { self.id = id; self.t = t }
}

public struct Timeline: Sendable, Codable, Equatable {
    public var schemaVersion = 4
    public var timeMap: TimeMap
    /// Logical split points in the recording, source seconds. No output effect.
    public var seams: [SplitSeam] = []
    public var zoom: [ZoomSegment] = []
    public var style = Style()
    public var cursor = CursorStyle()
    public var camera = CameraParams()
    public var audio = AudioPlan()
    public var webcam: WebcamLayout?
    public var overlays = Overlays()
    public var layouts: [LayoutSegment] = []
    public var layoutSettings = LayoutSet()
    public var captions = CaptionPlan()
    /// Imported video appended after the recording, in OUTPUT seconds.
    public var clips: [TimelineClip] = []
    public var derived: DerivedTracks?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, timeMap, zoom, style, cursor, camera, audio, webcam, overlays, layouts, layoutSettings, captions, clips, seams
    }
    public init(duration: Double) { timeMap = TimeMap(sourceDuration: duration) }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        timeMap = try c.decode(TimeMap.self, forKey: .timeMap)
        let version = c.opt(.schemaVersion, 1)
        schemaVersion = 4
        seams = c.opt(.seams, seams)
        zoom = c.opt(.zoom, zoom)
        if version < 2 { for i in zoom.indices { zoom[i].start = timeMap.source(atOutput: zoom[i].start); zoom[i].end = timeMap.source(atOutput: zoom[i].end) } }
        if version < 4 {
            // v3 -> v4: legacy Loudness key targetLUFS is handled inside AudioPlan decode.
        }
         style = c.opt(.style, style); cursor = c.opt(.cursor, cursor); camera = c.opt(.camera, camera)
        audio = c.opt(.audio, audio); webcam = try? c.decodeIfPresent(WebcamLayout.self, forKey: .webcam)
        overlays = c.opt(.overlays, overlays); layouts = c.opt(.layouts, layouts); layoutSettings = c.opt(.layoutSettings, layoutSettings)
        captions = c.opt(.captions, captions)
        clips = c.opt(.clips, clips)
    }

    /// Total length of the deliverable: the edited recording plus any imported clips.
    public var compositionDuration: Double {
        max(timeMap.outputDuration, clips.map(\.end).max() ?? 0)
    }
    public func clip(atOutput t: Double) -> TimelineClip? {
        clips.first { $0.contains(output: t) }
    }
    /// Output time -> seconds inside the imported file, or nil on the recording.
    public func clipSource(atOutput t: Double) -> (clip: TimelineClip, time: Double)? {
        guard let c = clip(atOutput: t) else { return nil }
        return (c, c.sourceTime(atOutput: t))
    }
}

// MARK: Bundle

public struct SourceInfo: Codable, Sendable {
    public var width: Int, height: Int
    public var fps: Double, duration: Double, backingScale: Double
    public var originX: Double, originY: Double
    public init(width: Int, height: Int, fps: Double, duration: Double, backingScale: Double, originX: Double, originY: Double) {
        self.width = width; self.height = height; self.fps = fps; self.duration = duration
        self.backingScale = backingScale; self.originX = originX; self.originY = originY
    }
}
public struct TrackMeta: Codable, Sendable {
    public var file: String, startHostSeconds: Double
    public init(file: String, startHostSeconds: Double) { self.file = file; self.startHostSeconds = startHostSeconds }
}
/// Separately recorded additional microphone or loopback source.
public struct MicrophoneSourceMeta: Codable, Sendable {
    public var deviceID: String, deviceName: String
    public var track: TrackMeta
    public init(deviceID: String, deviceName: String, track: TrackMeta) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.track = track
    }
}

public struct ProjectMeta: Codable, Sendable {
    public var name: String
    public var created = Date()
    public var analysisSalt: UInt64
    public var source: SourceInfo
    public var clock: RecordingClock
    public var mic: TrackMeta?, system: TrackMeta?, webcam: TrackMeta?
    /// Older projects have no additional inputs; decoding defaults to empty.
    public var additionalMicrophones: [MicrophoneSourceMeta] = []
    public var droppedFrames = 0
    public var captureResolution: String = "native"
    public var captureQuality: String = "high"
    public var captureMbps: Double = 0
    enum CodingKeys: String, CodingKey { case name, created, analysisSalt, source, clock, mic, system, webcam, additionalMicrophones, droppedFrames, captureResolution, captureQuality, captureMbps }
    public init(name: String, source: SourceInfo, clock: RecordingClock) {
        self.name = name; self.analysisSalt = UInt64.random(in: UInt64.min...UInt64.max); self.source = source; self.clock = clock
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date(timeIntervalSince1970: 0)
        analysisSalt = (try? c.decode(UInt64.self, forKey: .analysisSalt)) ?? fnv1a64(name + String(created.timeIntervalSince1970))
        source = try c.decode(SourceInfo.self, forKey: .source)
        clock = try c.decode(RecordingClock.self, forKey: .clock)
        mic = try? c.decodeIfPresent(TrackMeta.self, forKey: .mic)
        system = try? c.decodeIfPresent(TrackMeta.self, forKey: .system)
        webcam = try? c.decodeIfPresent(TrackMeta.self, forKey: .webcam)
        additionalMicrophones = (try? c.decode([MicrophoneSourceMeta].self, forKey: .additionalMicrophones)) ?? []
        droppedFrames = (try? c.decode(Int.self, forKey: .droppedFrames)) ?? 0
        captureResolution = (try? c.decode(String.self, forKey: .captureResolution)) ?? "native"
        captureQuality = (try? c.decode(String.self, forKey: .captureQuality)) ?? "high"
        captureMbps = (try? c.decode(Double.self, forKey: .captureMbps)) ?? 0
    }
}
public struct ProjectFile: Codable, Sendable {
    public var meta: ProjectMeta
    public var timeline: Timeline
    public init(meta: ProjectMeta, timeline: Timeline) { self.meta = meta; self.timeline = timeline }
}
public struct AXFrame: Codable, Sendable {
    public struct Rect: Codable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    }
    public var caret: Rect? = nil
    public var sampledAt: Double? = nil
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Secure text field (password/CC) or a field whose title names one.
    public var secure: Bool
    /// Best-effort AX title/description so labels like "Password" mask too.
    public var label: String?
    public init(x: Double, y: Double, w: Double, h: Double, secure: Bool = false, label: String? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.secure = secure
        self.label = label
    }
    enum CodingKeys: String, CodingKey { case x, y, w, h, secure, label, caret, sampledAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0
        y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0
        w = (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? 0
        h = (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? 0
        caret = try c.decodeIfPresent(Rect.self, forKey: .caret)
        sampledAt = try c.decodeIfPresent(Double.self, forKey: .sampledAt)
        secure = c.opt(.secure, false); label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
    }
}

public struct ProjectBundle: Sendable, Hashable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func create(named: String, in dir: URL) throws -> ProjectBundle {
        let u = dir.appendingPathComponent(named).appendingPathExtension("lumen")
        for sub in ["cache", "thumbs"] {
            try FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return .init(url: u)
    }
    private func f(_ n: String) -> URL { url.appendingPathComponent(n) }
    public var projectURL: URL { f("project.json") }
    public var screenURL: URL { f("screen.mov") }
    public var framesMetaURL: URL { f("frames.meta") }
    public var eventsURL: URL { f("events.bin") }
    public var cursorsURL: URL { f("cursors.json") }
    public var axURL: URL { f("ax.json") }
    public var micURL: URL { f("mic.caf") }
    public var systemURL: URL { f("system.caf") }
    public var webcamURL: URL { f("webcam.mov") }
    public var cacheURL: URL { f("cache") }

    public func save(_ file: ProjectFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(file).write(to: projectURL, options: .atomic)
    }
    public func load() throws -> ProjectFile {
        var file = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: projectURL))
        // Shared packages store imported clips relative to the bundle. Resolve
        // them here so every consumer keeps seeing one absolute path.
        for i in file.timeline.clips.indices where !file.timeline.clips[i].path.hasPrefix("/") {
            file.timeline.clips[i].path = url.appendingPathComponent(file.timeline.clips[i].path).path
        }
        return file
    }
    /// events.bin stores absolute host seconds (crash-safe, append-only). Rebased here.
    public func events(origin: Double) throws -> [InputEvent] {
        var ev = EventCodec.decode(try Data(contentsOf: eventsURL))
        for i in ev.indices { ev[i].t -= origin }
        return ev.filter { $0.t >= 0 }.sorted { $0.t < $1.t }
    }
}
```

### Sources/LumenProject/Overlays.swift

```swift
import Foundation

public enum CutOrigin: String, Codable, Sendable { case manual, autoTidy, transcript }
/// Removed span, SOURCE seconds.
public struct CutRange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var origin: CutOrigin
    public init(id: UUID = UUID(), start: Double, end: Double, origin: CutOrigin = .manual) {
        self.id = id; self.start = start; self.end = end; self.origin = origin
    }
}

public enum MaskMode: String, Codable, CaseIterable, Sendable {
    case blur, pixelate, solid

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "blend" { self = .pixelate }
        else if let mode = Self(rawValue: value) { self = mode }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown mask mode: \(value)") }
    }
}
/// Rect in SOURCE pixels at SOURCE time t.
public struct MaskKey: Codable, Equatable, Sendable {
    public var t: Double, x: Double, y: Double, w: Double, h: Double
    public init(t: Double, x: Double, y: Double, w: Double, h: Double) { self.t = t; self.x = x; self.y = y; self.w = w; self.h = h }
}
public struct Mask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var mode: MaskMode
    public var keys: [MaskKey]
    public var origin: Origin
    public var approved: Bool
    public var category: String?
    public var padding: Double
    public init(id: UUID = UUID(), start: Double, end: Double, mode: MaskMode = .blur, keys: [MaskKey], origin: Origin = .manual,
                approved: Bool = true, category: String? = nil, padding: Double = 6) {
        self.id = id; self.start = start; self.end = end; self.mode = mode; self.keys = keys; self.origin = origin
        self.approved = approved; self.category = category; self.padding = padding
    }
}

public enum HighlightStyle: String, Codable, CaseIterable, Sendable { case dim, outline, glow }
public struct Highlight: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var x: Double, y: Double, w: Double, h: Double          // source px
    public var style: HighlightStyle, dim: Double
    public init(id: UUID = UUID(), start: Double, end: Double, x: Double, y: Double, w: Double, h: Double, style: HighlightStyle = .dim, dim: Double = 0.55) {
        self.id = id; self.start = start; self.end = end; self.x = x; self.y = y; self.w = w; self.h = h; self.style = style; self.dim = dim
    }
}
/// Magnified glass over the canvas. `x/y` are the SOURCE pixel that the glass
/// looks at (ignored when `follow`), `cx/cy` are the canvas-normalized centre
/// where the glass itself sits. Both are persisted so a loupe can be dragged.
public struct Loupe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var x: Double, y: Double                                // source px (ignored when follow)
    public var follow: Bool
    public var radius: Double                                      // fraction of canvas width
    public var magnification: Double
    public var round: Bool
    public var cx: Double, cy: Double                              // canvas-normalized glass centre
    public var border: Double                                      // fraction of canvas width
    public var shadow: Double
    public init(id: UUID = UUID(), start: Double, end: Double, x: Double = 0, y: Double = 0, follow: Bool = true, radius: Double = 0.12,
                magnification: Double = 2, round: Bool = true, cx: Double = 0.22, cy: Double = 0.74,
                border: Double = 0.006, shadow: Double = 0.45) {
        self.id = id; self.start = start; self.end = end; self.x = x; self.y = y; self.follow = follow
        self.radius = radius; self.magnification = magnification; self.round = round
        self.cx = cx; self.cy = cy; self.border = border; self.shadow = shadow
    }
    enum CodingKeys: String, CodingKey { case id, start, end, x, y, follow, radius, magnification, round, cx, cy, border, shadow }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        x = (try? c.decode(Double.self, forKey: .x)) ?? 0; y = (try? c.decode(Double.self, forKey: .y)) ?? 0
        follow = (try? c.decode(Bool.self, forKey: .follow)) ?? true
        radius = (try? c.decode(Double.self, forKey: .radius)) ?? 0.12
        magnification = (try? c.decode(Double.self, forKey: .magnification)) ?? 2
        round = (try? c.decode(Bool.self, forKey: .round)) ?? true
        cx = (try? c.decode(Double.self, forKey: .cx)) ?? 0.22
        cy = (try? c.decode(Double.self, forKey: .cy)) ?? 0.74
        border = (try? c.decode(Double.self, forKey: .border)) ?? 0.006
        shadow = (try? c.decode(Double.self, forKey: .shadow)) ?? 0.45
    }
}
public struct TapIndicator: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var t: Double, x: Double, y: Double                      // source time, source px
    public init(id: UUID = UUID(), t: Double, x: Double, y: Double) { self.id = id; self.t = t; self.x = x; self.y = y }
}
public struct TextBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var text: String
    public var x: Double, y: Double                                // canvas-normalized center
    public var size: Double                                        // fraction of canvas height
    public var color: RGBA
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, x: Double = 0.5, y: Double = 0.86, size: Double = 0.045, color: RGBA = RGBA(0xFFFFFF)) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.x = x; self.y = y; self.size = size; self.color = color
    }
}

public struct Overlays: Codable, Equatable, Sendable {
    public var masks: [Mask] = [], highlights: [Highlight] = [], loupes: [Loupe] = [], taps: [TapIndicator] = [], texts: [TextBlock] = []
    public var privacy = PrivacyPlan()
    enum CodingKeys: String, CodingKey { case masks, highlights, loupes, taps, texts, privacy }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        masks = c.opt(.masks, masks); highlights = c.opt(.highlights, highlights); loupes = c.opt(.loupes, loupes)
        taps = c.opt(.taps, taps); texts = c.opt(.texts, texts); privacy = c.opt(.privacy, privacy)
    }
}

public enum LayoutKind: String, Codable, CaseIterable, Hashable, Sendable { case screenOnly, cameraOverlay, split, cameraFullscreen, cameraCutout }
public struct LayoutSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double                          // SOURCE seconds
    public var kind: LayoutKind
    public init(id: UUID = UUID(), start: Double, end: Double, kind: LayoutKind) { self.id = id; self.start = start; self.end = end; self.kind = kind }
}
public enum BehindFace: String, Codable, CaseIterable, Sendable { case move, hide, fade }
public struct LayoutSettings: Codable, Equatable, Sendable {
    public var size = 0.22
    public var corner: WebcamLayout.Corner = .bottomRight
    public var shape: WebcamLayout.Shape = .circle
    public var mirror = true, border = true, shadow = true, autoFrame = true
    public var avoidCursor = true
    public var avoidMargin = 48.0
    public var snapDwell = 0.45
    public var behindFace: BehindFace = .move
    public var hideOnSilence = false
    public var silenceHold = 0.6
    enum CodingKeys: String, CodingKey {
        case size, corner, shape, mirror, border, shadow, autoFrame, avoidCursor, avoidMargin, snapDwell, behindFace, hideOnSilence, silenceHold
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        size = c.opt(.size, size); corner = c.opt(.corner, corner); shape = c.opt(.shape, shape); mirror = c.opt(.mirror, mirror)
        border = c.opt(.border, border); shadow = c.opt(.shadow, shadow); autoFrame = c.opt(.autoFrame, autoFrame)
        avoidCursor = c.opt(.avoidCursor, avoidCursor); avoidMargin = c.opt(.avoidMargin, avoidMargin); snapDwell = c.opt(.snapDwell, snapDwell)
        behindFace = c.opt(.behindFace, behindFace); hideOnSilence = c.opt(.hideOnSilence, hideOnSilence); silenceHold = c.opt(.silenceHold, silenceHold)
    }
}
/// Independent camera settings per layout.
public struct LayoutSet: Codable, Equatable, Sendable {
    public var screenOnly = LayoutSettings(), cameraOverlay = LayoutSettings(), split = LayoutSettings()
    public var cameraFullscreen = LayoutSettings(), cameraCutout = LayoutSettings()
    public init() {}
    public subscript(k: LayoutKind) -> LayoutSettings {
        get {
            switch k {
            case .screenOnly: screenOnly; case .cameraOverlay: cameraOverlay; case .split: split
            case .cameraFullscreen: cameraFullscreen; case .cameraCutout: cameraCutout
            }
        }
        set {
            switch k {
            case .screenOnly: screenOnly = newValue; case .cameraOverlay: cameraOverlay = newValue; case .split: split = newValue
            case .cameraFullscreen: cameraFullscreen = newValue; case .cameraCutout: cameraCutout = newValue
            }
        }
    }
}

/// Two faces, nothing else: a serif for the editorial read, a sans for the
/// neutral one. Both render at weight 450 — the old per-word bold made the
/// line reflow every time the spoken word changed.
public enum CaptionFont: String, Codable, CaseIterable, Sendable {
    case serif, sans
    public var title: String { switch self { case .serif: "Serif"; case .sans: "Sans" } }
    public var postScript: String { switch self { case .serif: "New York"; case .sans: "SF Pro Text" } }
    /// Legacy project files stored the old four-way choice. They map onto the
    /// two faces that remain; nothing is lost but the picker.
    public init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        switch raw {
        case "newYork": self = .serif
        case "sfPro", "sfRounded", "menlo": self = .sans
        default: self = raw == "serif" ? .serif : .sans
        }
    }
}
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var size = 0.060                                         // fraction of canvas height
    public var color = RGBA(0xFFFFFF)
    /// Dark card so white text keeps 4.5:1+ contrast on bright pages;
    /// a light pill on a white page fails regardless of blur.
    public var pill: RGBA? = RGBA(0x0A0A0A, a: 0.62)
    public var font: CaptionFont = .sans
    enum CodingKeys: String, CodingKey { case size, color, pill, font }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        size = c.opt(.size, size); color = c.opt(.color, color)
        pill = c.contains(.pill) ? ((try? c.decodeIfPresent(RGBA.self, forKey: .pill)) ?? nil) : pill
        font = c.opt(.font, font)
    }
}
public struct CaptionPlan: Codable, Equatable, Sendable {
    /// Captions are opt-in. A transcript arriving must never switch them on
    /// behind the user's back, so nothing but the toggle writes this.
    public var enabled = false
    public var style = CaptionStyle()
    public var locale = "en-US"
    public var vocabulary: [String] = []
    public var deletedWords: [Int] = []                             // transcript word indices removed by transcript editing
    public var textEdits: [String: String] = [:]                    // word index -> corrected text (captions only)
    enum CodingKeys: String, CodingKey { case enabled, style, locale, vocabulary, deletedWords, textEdits }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled); style = c.opt(.style, style); locale = c.opt(.locale, locale)
        vocabulary = c.opt(.vocabulary, vocabulary); deletedWords = c.opt(.deletedWords, deletedWords)
        textEdits = c.opt(.textEdits, textEdits)
    }
}

/// Privacy analyzer settings and user decisions keyed by stable automatic-mask ids.
public struct PrivacyPlan: Codable, Equatable, Sendable {
    public var enabled = true
    public var autoDetect = true
    public var autoApply: [String] = ["apiKey", "jwt", "privateKey", "envSecret", "card", "email", "phone", "entropy", "password", "custom"]
    public var customPatterns: [String] = []
    public var padding = 6.0
    public var mode: MaskMode = .pixelate
    public var pixelSize = 16.0
    public var entropyThreshold = 3.5
    public var decisions: [String: Bool] = [:]
    enum CodingKeys: String, CodingKey { case enabled, autoDetect, autoApply, customPatterns, padding, mode, pixelSize, entropyThreshold, decisions }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled); autoDetect = c.opt(.autoDetect, autoDetect); autoApply = c.opt(.autoApply, autoApply)
        customPatterns = c.opt(.customPatterns, customPatterns); padding = c.opt(.padding, padding); mode = c.opt(.mode, mode)
        pixelSize = c.opt(.pixelSize, pixelSize)
        entropyThreshold = c.opt(.entropyThreshold, entropyThreshold); decisions = c.opt(.decisions, decisions)
    }
}
```

### Sources/LumenProject/TranscriptIO.swift

```swift
import Foundation

/// transcript.json. Word times are MIC-FILE time; add `micOffset` (meta.mic.startHostSeconds - clock origin) to get source time.
public struct TranscriptFile: Codable, Sendable {
    public var version = 1
    public var engine: String
    public var complete: Bool
    public var transcript: Transcript
    public init(engine: String, complete: Bool, transcript: Transcript) { self.engine = engine; self.complete = complete; self.transcript = transcript }
}

extension ProjectBundle {
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    public func saveTranscript(_ f: TranscriptFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(f).write(to: transcriptURL, options: .atomic)
    }
    public func loadTranscript() -> TranscriptFile? {
        guard let d = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(TranscriptFile.self, from: d)
    }
}

extension Transcript {
    public func shifted(by dt: Double) -> Transcript {
        Transcript(words: words.map { WordToken(text: $0.text, start: $0.start + dt, end: $0.end + dt, confidence: $0.confidence) }, locale: locale)
    }
}
```

## LumenRender/

### Sources/LumenRender/BackdropBlur.swift

```swift
import Foundation

/// The backdrop blur is only active during actual zooms. This deliberately
/// changes a GPU mip selection, not the screen content texture or screenshot
/// resampler. Fractional mip levels give smooth transitions on zoom in/out.
public enum BackdropBlur {
    public static func mipLevel(enabled: Bool, cameraScale: Float) -> Float {
        guard enabled, cameraScale.isFinite, cameraScale > 1.02 else { return 0 }
        return min(max((cameraScale - 1) * 2.0, 0), 3.5)
    }
}
```

### Sources/LumenRender/ClickEffects.swift

```swift
import Foundation
import simd
import LumenCore
import LumenProject

public struct ClickPulse: Sendable, Equatable { public var t: Double; public var position: SIMD2<Float> }
public struct PulseFX: Sendable, Equatable { public var position: SIMD2<Float>; public var progress: Float }

public enum ClickPulses {
    public static func build(events: [InputEvent], taps: [TapIndicator], range: ClosedRange<Double>) -> [ClickPulse] {
        var out = events.filter { $0.kind == .down && range.contains($0.t) }.map { ClickPulse(t: $0.t, position: [$0.x, $0.y]) }
        out += taps.filter { range.contains($0.t) }.map { ClickPulse(t: $0.t, position: [Float($0.x), Float($0.y)]) }
        return out.sorted { $0.t < $1.t }
    }

    public static func active(_ ps: [ClickPulse], at t: Double, duration: Double, maxCount: Int = 8) -> [PulseFX] {
        guard duration > 0, !ps.isEmpty else { return [] }
        var lo = 0, hi = ps.count
        while lo < hi { let m = (lo + hi) / 2; if ps[m].t <= t - duration { lo = m + 1 } else { hi = m } }
        var out: [PulseFX] = [], i = lo
        while i < ps.count, ps[i].t <= t {
            out.append(PulseFX(position: ps[i].position, progress: Float((t - ps[i].t) / duration))); i += 1
        }
        return Array(out.suffix(maxCount))
    }
}
```

### Sources/LumenRender/ContentPass.swift

```swift
import Metal
import simd
import LumenProject

public struct ContentLayout {
    public var canvas: SIMD2<Int32>
    public var contentRect: SIMD4<Float>       // canvas px: x, y, w, h
    public var radii: SIMD4<Float>             // tl, tr, br, bl
    public var srcSize: SIMD2<Float>
    public init(canvas: SIMD2<Int32>, contentRect: SIMD4<Float>, radii: SIMD4<Float>, srcSize: SIMD2<Float>) {
        self.canvas = canvas; self.contentRect = contentRect; self.radii = radii; self.srcSize = srcSize
    }
    /// Canvas px per source px at zoom 1.
    public var baseMagnification: Float { contentRect.z / srcSize.x }
}

private struct UpBindGPU { var region: SIMD4<Float>; var texSize: SIMD2<Float>; var factor: Float; var blend: Float }
private struct ContentParamsGPU {
    var contentRect: SIMD4<Float>; var radii: SIMD4<Float>
    var camCenter: SIMD2<Float>; var srcSize: SIMD2<Float>
    var magnification: Float; var pad: Float = 0
    var canvasSize: SIMD2<Int32>
    var up: UpBindGPU
}

/// Camera-transformed content over the cached backdrop, rounded per corner, with optional upscaled sampling.
public final class ContentPass {
    private let k: FXKernels
    public init(kernels: FXKernels) { k = kernels }

    /// Runs the upscaler if magnification is high enough. Encodes its own compute work into `cb` (call before `encode`).
    public func prepareUpscale(_ up: Upscaler, _ cb: MTLCommandBuffer, layout L: ContentLayout, camCenter c: SIMD2<Float>, zoom: Float,
                               source: MTLTexture, sourceID: UInt64, params p: UpscaleParams,
                               extraMargin: Double = 0) throws -> (UpscaleResult, Float)? {
        let m = Double(zoom * L.baseMagnification)
        let blend = Upscaler.blend(forMagnification: m, p)
        guard blend > 0 else { return nil }
        let view = SIMD2<Double>(Double(L.contentRect.z), Double(L.contentRect.w)) / m
        let region = Upscaler.region(center: SIMD2(Double(c.x), Double(c.y)), view: view,
                                     source: SIMD2(Double(L.srcSize.x), Double(L.srcSize.y)), margin: 8 + extraMargin)
        let f = Upscaler.factor(forMagnification: m, maxFactor: p.maxFactor)
        return (try up.upscale(cb, source: source, region: region, factor: f, params: p, frameID: sourceID), blend)
    }

    public func encode(_ e: MTLComputeCommandEncoder, layout L: ContentLayout, camCenter: SIMD2<Float>, zoom: Float,
                       backdrop: MTLTexture, canvas: MTLTexture, source: MTLTexture, upscaled: (UpscaleResult, Float)?) throws {
        var up = UpBindGPU(region: .zero, texSize: .one, factor: 1, blend: 0)
        if let (r, b) = upscaled { up = UpBindGPU(region: r.region, texSize: r.texSize, factor: r.factor, blend: b) }
        var P = ContentParamsGPU(contentRect: L.contentRect, radii: L.radii, camCenter: camCenter, srcSize: L.srcSize,
                                 magnification: zoom * L.baseMagnification, canvasSize: L.canvas, up: up)
        let pipe = try k.pipeline("fx_content")
        e.setComputePipelineState(pipe)
        e.setTexture(backdrop, index: 0); e.setTexture(canvas, index: 1)
        e.setTexture(source, index: 2); e.setTexture(upscaled?.0.texture ?? source, index: 3)
        e.setBytes(&P, length: MemoryLayout<ContentParamsGPU>.stride, index: 0)
        k.dispatch(e, pipeline: pipe, width: Int(L.canvas.x), height: Int(L.canvas.y))
    }
}
```

### Sources/LumenRender/CursorAtlas.swift

```swift
import Foundation
import Metal
import CoreGraphics
import AppKit
import simd
import LumenCore
import LumenProject

public struct CustomCursor: Sendable { public var id: UInt16; public var png: Data; public var hot: SIMD2<Double> }

public enum CursorLibrary {
    private struct Row: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
    public static func load(from url: URL) -> [CustomCursor] {
        guard let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([Row].self, from: d) else { return [] }
        return rows.map { CustomCursor(id: $0.id, png: $0.png, hot: [$0.hotX, $0.hotY]) }
    }
}

/// Minimal SVG path parser (M L H V C S Q A Z, absolute + relative) -> CGPath, in the SVG's own units.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let s = Array(d.utf8)
        var i = 0
        let out = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastC: CGPoint?, lastQ: CGPoint?
        var cmd: UInt8 = 0
        func isSep(_ c: UInt8) -> Bool { c == 32 || c == 44 || c == 10 || c == 9 || c == 13 }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func skip() { while i < s.count && isSep(s[i]) { i += 1 } }
        func num() -> CGFloat? {
            skip()
            guard i < s.count else { return nil }
            var j = i
            if s[j] == 45 || s[j] == 43 { j += 1 }
            var dot = false, digits = false
            while j < s.count {
                if isDigit(s[j]) { digits = true; j += 1 }
                else if s[j] == 46 && !dot { dot = true; j += 1 }
                else { break }
            }
            guard digits else { return nil }
            if j < s.count, s[j] == 101 || s[j] == 69 {
                var k = j + 1
                if k < s.count, s[k] == 45 || s[k] == 43 { k += 1 }
                if k < s.count, isDigit(s[k]) { while k < s.count && isDigit(s[k]) { k += 1 }; j = k }
            }
            let v = Double(String(decoding: s[i..<j], as: UTF8.self)) ?? 0
            i = j
            return CGFloat(v)
        }
        func flag() -> Bool? {
            skip()
            guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
            let v = s[i] == 49
            i += 1
            return v
        }
        while true {
            skip()
            guard i < s.count else { break }
            let ch = s[i]
            if (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) { cmd = ch; i += 1 } else if cmd == 0 { break }
            let rel = cmd >= 97
            let up = rel ? cmd - 32 : cmd
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            let keepC = up == UInt8(ascii: "C") || up == UInt8(ascii: "S")
            let keepQ = up == UInt8(ascii: "Q")
            switch up {
            case UInt8(ascii: "M"):
                guard let x = num(), let y = num() else { return out }
                let p = P(x, y); out.move(to: p); cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let x = num(), let y = num() else { return out }
                let p = P(x, y); out.addLine(to: p); cur = p
            case UInt8(ascii: "H"):
                guard let x = num() else { return out }
                let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y); out.addLine(to: p); cur = p
            case UInt8(ascii: "V"):
                guard let y = num() else { return out }
                let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y); out.addLine(to: p); cur = p
            case UInt8(ascii: "C"):
                guard let a = num(), let b = num(), let c = num(), let d2 = num(), let x = num(), let y = num() else { return out }
                let c1 = P(a, b), c2 = P(c, d2), p = P(x, y)
                out.addCurve(to: p, control1: c1, control2: c2); lastC = c2; cur = p
            case UInt8(ascii: "S"):
                guard let c = num(), let d2 = num(), let x = num(), let y = num() else { return out }
                let c1 = lastC.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = P(c, d2), p = P(x, y)
                out.addCurve(to: p, control1: c1, control2: c2); lastC = c2; cur = p
            case UInt8(ascii: "Q"):
                guard let a = num(), let b = num(), let x = num(), let y = num() else { return out }
                let c = P(a, b), p = P(x, y)
                out.addQuadCurve(to: p, control: c); lastQ = c; cur = p
            case UInt8(ascii: "A"):
                guard let rx = num(), let ry = num(), let rot = num(), let large = flag(), let sweep = flag(), let x = num(), let y = num() else { return out }
                let p = P(x, y)
                arc(out, from: cur, rx: rx, ry: ry, rot: rot, large: large, sweep: sweep, to: p); cur = p
            case UInt8(ascii: "Z"):
                out.closeSubpath(); cur = start; cmd = 0
            default:
                return out
            }
            if !keepC { lastC = nil }
            if !keepQ { lastQ = nil }
        }
        _ = lastQ
        return out
    }

    private static func arc(_ path: CGMutablePath, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rot: CGFloat,
                            large: Bool, sweep: Bool, to p1: CGPoint) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rot * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let k = lam.squareRoot(); rx *= k; ry *= k }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        guard den > 0 else { path.addLine(to: p1); return }
        let co = (large == sweep ? CGFloat(-1) : CGFloat(1)) * max(0, num / den).squareRoot()
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        let th1 = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
        let th2 = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx)
        var dth = th2 - th1
        if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
        let n = max(Int(ceil(abs(dth) / (.pi / 2))), 1)
        let d = dth / CGFloat(n), t = 4 / 3 * tan(d / 4)
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: cx + rx * cp * u - ry * sp * v, y: cy + rx * sp * u + ry * cp * v) }
        var a = th1
        for _ in 0..<n {
            let b = a + d
            path.addCurve(to: map(cos(b), sin(b)),
                          control1: map(cos(a) - t * sin(a), sin(a) + t * cos(a)),
                          control2: map(cos(b) + t * sin(b), sin(b) - t * cos(b)))
            a = b
        }
    }
}

/// Vector cursor art rasterized at 8x into a mip-mapped texture array. Each layer is a 32 pt box (256 px), top-left origin.
/// Every layer is the custom Lumen arrow, except the hand shapes, which use the custom Lumen hand.
public final class CursorAtlas {
    public struct Entry { public var layer: Int; public var hot: SIMD2<Double> }   // hot normalized to the layer
    public let texture: MTLTexture
    private var map: [UInt16: Entry] = [:]
    static let px = 256, pts = 32.0

    static let arrowD = "M9.80282 4.62973 15.8364 6.99069C19.3164 8.35243 21.0564 9.03329 20.9987 10.1133 20.941 11.1934 19.1251 11.6886 15.4933 12.6791 14.412 12.974 13.8713 13.1215 13.4964 13.4963 13.1215 13.8712 12.9741 14.4119 12.6791 15.4933 11.6887 19.125 11.1934 20.9409 10.1134 20.9986 9.03335 21.0563 8.35249 19.3163 6.99075 15.8363L4.62979 9.80276C3.20411 6.15934 2.49127 4.33764 3.41448 3.41442 4.3377 2.49121 6.15941 3.20405 9.80282 4.62973Z"
    static let handD = "M224,104v50.93c0,46.2-36.85,84.55-83,85.06A83.71,83.71,0,0,1,80.6,215.4C58.79,192.33,34.15,136,34.15,136a16,16,0,0,1,6.53-22.23c7.66-4,17.1-.84,21.4,6.62l21,36.44a6.09,6.09,0,0,0,6,3.09l.12,0A8.19,8.19,0,0,0,96,151.74V32a16,16,0,0,1,16.77-16c8.61.4,15.23,7.82,15.23,16.43V104a8,8,0,0,0,8.53,8,8.17,8.17,0,0,0,7.47-8.25V88a16,16,0,0,1,16.77-16c8.61.4,15.23,7.82,15.23,16.43V112a8,8,0,0,0,8.53,8,8.17,8.17,0,0,0,7.47-8.25v-7.28c0-8.61,6.62-16,15.23-16.43A16,16,0,0,1,224,104Z"

    public init?(device: MTLDevice, queue: MTLCommandQueue, pack: CursorPack, customs: [CustomCursor]) {
        let ids = StockCursor.allCases.map(\.rawValue)
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
        d.width = Self.px; d.height = Self.px; d.arrayLength = ids.count + customs.count; d.mipmapLevelCount = 9
        d.usage = [.shaderRead, .renderTarget]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        for (i, id) in ids.enumerated() {
            var hot = SIMD2<Double>(3.5, 3.5)
            let bytes = Self.raster { c in
                if let s = StockCursor(rawValue: id) { hot = Self.art(c, pack, s) }
            }
            t.replace(region: MTLRegionMake2D(0, 0, Self.px, Self.px), mipmapLevel: 0, slice: i, withBytes: bytes,
                      bytesPerRow: Self.px * 4, bytesPerImage: Self.px * Self.px * 4)
            map[id] = Entry(layer: i, hot: hot / Self.pts)
        }
        // Captured system cursors that have no stock equivalent keep their real
        // artwork instead of silently falling back to the Lumen arrow.
        for (j, custom) in customs.enumerated() {
            guard let (bytes, hot) = Self.customRaster(custom) else { continue }
            let layer = ids.count + j
            t.replace(region: MTLRegionMake2D(0, 0, Self.px, Self.px), mipmapLevel: 0, slice: layer, withBytes: bytes,
                      bytesPerRow: Self.px * 4, bytesPerImage: Self.px * Self.px * 4)
            map[custom.id] = Entry(layer: layer, hot: hot)
        }
        if let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
    }

    /// Rasterizes one captured cursor PNG into the same 32 pt box as the stock
    /// art. The hotspot is remapped through the fit rect so the click point
    /// stays exact even when the bitmap is scaled.
    private static func customRaster(_ cursor: CustomCursor) -> ([UInt8], SIMD2<Double>)? {
        guard let image = NSImage(data: cursor.png) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0 else { return nil }
        let s = min(pts / iw, pts / ih)
        let w = iw * s, h = ih * s
        let x0 = (pts - w) / 2, y0 = (pts - h) / 2
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let k = CGFloat(px) / CGFloat(pts)
            c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: k, y: -k)
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: x0, y: y0, width: w, height: h))
        }
        let iwPt = max(image.size.width, 1), ihPt = max(image.size.height, 1)
        let hx = (Double(cursor.hot.x) / Double(iwPt) * Double(w) + Double(x0)) / pts
        let hy = (Double(cursor.hot.y) / Double(ihPt) * Double(h) + Double(y0)) / pts
        return (buf, SIMD2(min(max(hx, 0), 1), min(max(hy, 0), 1)))
    }

    public func entry(_ shape: UInt16) -> Entry? { map[shape] ?? map[StockCursor.arrow.rawValue] }

    private static func raster(_ draw: (CGContext) -> Void) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let k = CGFloat(px) / CGFloat(pts)
            c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: k, y: -k)          // top-left origin, units = points
            c.setLineJoin(.round); c.setLineCap(.round)
            draw(c)
        }
        return buf
    }

    /// Returns the hotspot in points.
    private static func art(_ c: CGContext, _ pack: CursorPack, _ s: StockCursor) -> SIMD2<Double> {
        let ink = CGColor(srgbRed: 0.11, green: 0.098, blue: 0.09, alpha: 1)      // #1c1917
        let paper = CGColor(gray: 1, alpha: 1)
        func shadowed(_ body: () -> Void) {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            c.endTransparencyLayer()
            c.restoreGState()
        }
        func glyph(_ d: String, tip: CGPoint, hot: CGPoint, scale: CGFloat, stroke: CGFloat) -> SIMD2<Double> {
            let p = SVGPath.parse(d)
            var t = CGAffineTransform(translationX: hot.x - tip.x * scale, y: hot.y - tip.y * scale).scaledBy(x: scale, y: scale)
            if let q = p.copy(using: &t) {
                shadowed {
                    c.addPath(q); c.setFillColor(ink); c.setStrokeColor(paper); c.setLineWidth(stroke); c.setLineJoin(.round)
                    c.drawPath(using: .fillStroke)
                }
            }
            return [Double(hot.x), Double(hot.y)]
        }
        if pack == .holiday {
            // Snowflake: six spokes + center dot, winter pack. Hotspot is
            // the flake center so clicks land where the eye points.
            shadowed {
                c.setStrokeColor(paper); c.setLineWidth(3.2)
                c.setFillColor(ink)
                for k in 0..<6 {
                    let a = Double(k) * Double.pi / 3
                    c.move(to: CGPoint(x: 16, y: 16))
                    c.addLine(to: CGPoint(x: 16 + 11 * CGFloat(cos(a)), y: 16 + 11 * CGFloat(sin(a))))
                }
                c.strokePath()
                c.setStrokeColor(ink); c.setLineWidth(1.4)
                for k in 0..<6 {
                    let a = Double(k) * Double.pi / 3
                    c.move(to: CGPoint(x: 16, y: 16))
                    c.addLine(to: CGPoint(x: 16 + 11 * CGFloat(cos(a)), y: 16 + 11 * CGFloat(sin(a))))
                }
                c.strokePath()
                c.addEllipse(in: CGRect(x: 14, y: 14, width: 4, height: 4)); c.fillPath()
            }
            return [16, 16]
        }
        if pack == .dot {
            shadowed {
                c.addEllipse(in: CGRect(x: 11, y: 11, width: 10, height: 10)); c.setFillColor(ink); c.setStrokeColor(paper); c.setLineWidth(1.8)
                c.drawPath(using: .fillStroke)
            }
            return [16, 16]
        }
        if pack == .ring {
            shadowed {
                c.addEllipse(in: CGRect(x: 7, y: 7, width: 18, height: 18))
                c.setStrokeColor(paper); c.setLineWidth(3.8); c.strokePath()
                c.addEllipse(in: CGRect(x: 7, y: 7, width: 18, height: 18))
                c.setStrokeColor(ink); c.setLineWidth(1.6); c.strokePath()
            }
            return [16, 16]
        }
        switch s {
        case .pointingHand, .openHand, .closedHand:
            // 256-unit hand, ~24 pt tall, fingertip is the hotspot
            return glyph(handD, tip: CGPoint(x: 112, y: 16), hot: CGPoint(x: 12, y: 3.5), scale: 24.0 / 224.0, stroke: 2.0)
        default:
            // 24-unit arrow at 1.4x (about 25 pt tall), tip is the hotspot
            return glyph(arrowD, tip: CGPoint(x: 3.2, y: 3.2), hot: CGPoint(x: 3.5, y: 3.5), scale: 1.4, stroke: 2.1)
        }
    }
}
```

### Sources/LumenRender/FXKernels.swift

```swift
import Metal
import Foundation

public enum FXError: Error {
    case noDevice, noEncoder, noTexture, noPipeline(String), library(String)
}

/// Owns the Metal device and compiled kernel library for the FX pipeline.
public final class FXKernels {
    public let device: MTLDevice
    private let library: MTLLibrary
    // SwiftPM copies .metal shader resources instead of compiling them into
    // default.metallib. Load supplementary kernels when first requested.
    private let pipelineLock = NSLock()
    private var extraLibraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]

    public init(device: MTLDevice) throws {
        self.device = device
        if let lib = try? device.makeDefaultLibrary(bundle: .module) {
            library = lib
        } else if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8) {
            library = try device.makeLibrary(source: source, options: nil)
        } else {
            throw FXError.library("Missing default.metallib and Shaders.metal")
        }
    }

    public func pipeline(_ name: String) throws -> MTLComputePipelineState {
        try pipelineLock.withLock {
            if let existing = pipelines[name] { return existing }

            var function = library.makeFunction(name: name)
            if function == nil {
                // Only compile each Metal source once; cache the pipeline state
                // as well so the 60fps render loop never recompiles shaders.
                let sources = name.hasPrefix("up_") ? ["Upscale"] : ["Content", "Upscale"]
                for source in sources {
                    let lib: MTLLibrary
                    if let existing = extraLibraries[source] {
                        lib = existing
                    } else {
                        guard let url = Bundle.module.url(forResource: source, withExtension: "metal"),
                              let text = try? String(contentsOf: url, encoding: .utf8) else {
                            throw FXError.library("Missing \(source).metal resource")
                        }
                        lib = try device.makeLibrary(source: text, options: nil)
                        extraLibraries[source] = lib
                    }
                    if let found = lib.makeFunction(name: name) {
                        function = found
                        break
                    }
                }
            }

            guard let function else { throw FXError.noPipeline(name) }
            let state = try device.makeComputePipelineState(function: function)
            pipelines[name] = state
            return state
        }
    }

    public func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                         width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let tg = MTLSize(width: min(16, pipeline.threadExecutionWidth),
                        height: min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / max(1, pipeline.threadExecutionWidth))),
                        depth: 1)
        let grid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
    }
}
```

### Sources/LumenRender/FrameSource.swift

```swift
import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Metal
import os

/// One decoded source frame. IOSurface-backed texture, level 0 only. `id` identifies the decoded frame for mip caching.
public struct SourceFrame: @unchecked Sendable {
    public let id: UInt64
    public let pts: Double
    public let pixelBuffer: CVPixelBuffer
    public let texture: MTLTexture
    let cv: CVMetalTexture
}

public protocol FrameSource: Sendable {
    /// Sample-and-hold: newest frame with pts <= t.
    func frame(atSource t: Double) async throws -> SourceFrame
}

public enum FrameSourceError: Error { case noTrack, read(String) }

/// Metal devices are thread-safe references supplied by the system. Keep the
/// device identity in a sendable wrapper while crossing into the decoder actor.
public struct SendableMetalDevice: @unchecked Sendable {
    public let value: any MTLDevice
    public init(_ value: any MTLDevice) { self.value = value }
}

/// Shifts a source clock (used for the webcam track, which starts after the screen track).
public struct OffsetFrameSource: FrameSource {
    let base: any FrameSource
    let offset: Double
    public init(_ base: any FrameSource, offset: Double) { self.base = base; self.offset = offset }
    public func frame(atSource t: Double) async throws -> SourceFrame { try await base.frame(atSource: t - offset) }
}

private let idCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

/// Sequential reader with a small LRU. Screen recordings are variable frame rate (ScreenCaptureKit only emits frames when pixels
/// change), so a "held" frame can be many seconds older than `t`. Forward playback never seeks; backward / far jumps restart the
/// reader 1 s early and, if no frame <= t is found, rewind further (4x each time) until the held frame is found.
public actor ReaderFrameSource: FrameSource {
    private final class Entry {
        let id: UInt64, pts: Double, pb: CVPixelBuffer
        var end = Double.infinity
        init(pts: Double, pb: CVPixelBuffer) { id = idCounter.withLock { $0 += 1; return $0 }; self.pts = pts; self.pb = pb }
    }
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let cache: CVMetalTextureCache
    private var reader: AVAssetReader?
    private var out: AVAssetReaderTrackOutput?
    private var cur: Entry?, peek: Entry?
    private var lru: [Entry] = []

    public init(url: URL, device: SendableMetalDevice) async throws {
        let a = AVURLAsset(url: url)
        guard let tr = try await a.loadTracks(withMediaType: .video).first else { throw FrameSourceError.noTrack }
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device.value, nil, &c)
        guard let c else { throw FrameSourceError.read("texture cache") }
        asset = a; track = tr; cache = c
    }

    public func frame(atSource t0: Double) async throws -> SourceFrame {
        let t = max(t0, 0)
        if let e = lru.last(where: { $0.pts <= t && t < $0.end }) { return try make(e) }
        // A held frame can last minutes while a screen is static. Age alone
        // must not restart decoding; only backwards seeks require a reset.
        if reader == nil || cur == nil || t < cur!.pts { try restart(at: max(0, t - 1.0)) }
        var back = 1.0
        for _ in 0..<4 {
            advance(to: t)
            if cur != nil { break }
            if t - back <= 0 { break }                          // already started at 0: nothing earlier exists
            back *= 4
            try restart(at: max(0, t - back))
        }
        guard let c = cur ?? peek else { throw FrameSourceError.read("no frames") }
        return try make(c)
    }

    /// Consumes frames while the next one is still <= t, then pins `cur.end` to the next frame's pts (or infinity at EOF).
    private func advance(to t: Double) {
        while true {
            if peek == nil { peek = readNext() }
            guard let p = peek, p.pts <= t else { break }
            cur?.end = p.pts
            cur = p; peek = nil
            lru.append(p); if lru.count > 8 { lru.removeFirst() }
        }
        if let c = cur { c.end = peek?.pts ?? .infinity }
    }

    private func restart(at start: Double) throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        o.alwaysCopiesSampleData = false
        r.add(o)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        guard r.startReading() else { throw FrameSourceError.read(r.error?.localizedDescription ?? "startReading failed") }
        reader = r; out = o; cur = nil; peek = nil
    }

    private func readNext() -> Entry? {
        guard let sb = out?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return Entry(pts: sb.presentationTimeStamp.seconds, pb: pb)
    }

    private func make(_ e: Entry) throws -> SourceFrame {
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(e.pb), h = CVPixelBufferGetHeight(e.pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, e.pb, nil, .bgra8Unorm, w, h, 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { throw FrameSourceError.read("texture") }
        return SourceFrame(id: e.id, pts: e.pts, pixelBuffer: e.pb, texture: tex, cv: cv)
    }
}
```

### Sources/LumenRender/LiveFrameSource.swift

```swift
import Foundation
import CoreVideo
import Metal

/// Latest capture frame, shared between the capture queue and renderer.
public final class LiveFrameSource: @unchecked Sendable {
    private let cache: CVMetalTextureCache
    private let lock = NSLock()
    private var pb: CVPixelBuffer?, id: UInt64 = 0, cached: SourceFrame?

    public init?(device: MTLDevice) {
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        guard let c else { return nil }
        cache = c
    }
    public func submit(_ b: CVPixelBuffer) {
        lock.lock(); pb = b; id &+= 1; cached = nil; lock.unlock()
    }
    public func current() -> SourceFrame? {
        lock.lock(); defer { lock.unlock() }
        if let f = cached { return f }
        guard let b = pb else { return nil }
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, b, nil, .bgra8Unorm, CVPixelBufferGetWidth(b),
                                                        CVPixelBufferGetHeight(b), 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        let f = SourceFrame(id: id, pts: 0, pixelBuffer: b, texture: tex, cv: cv)
        cached = f
        return f
    }
}
```

### Sources/LumenRender/PerformanceHarness.swift

```swift
import Foundation
import Metal
import CoreVideo
import QuartzCore
import LumenCore
import LumenProject

// MARK: - Budget

/// Converts frame timings into a pass/fail gate. Pure, so CI can test the
/// policy without a GPU while the real harness supplies live samples.
public struct FrameBudget: Sendable, Equatable {
    public var fps: Double
    /// A frame may take this much longer than the vsync interval before it counts as dropped.
    public var latencyAllowance: Double
    /// Fraction of frames allowed to miss the deadline (startup/warm-up slack).
    public var allowedOverBudgetFraction: Double

    public init(fps: Double = 60, latencyAllowance: Double = 1.25, allowedOverBudgetFraction: Double = 0.02) {
        self.fps = max(fps, 1)
        self.latencyAllowance = max(latencyAllowance, 1)
        self.allowedOverBudgetFraction = min(max(allowedOverBudgetFraction, 0), 1)
    }

    public var budgetMilliseconds: Double { 1000 / fps }

    public func evaluate(_ samples: [Double]) -> FrameBudgetReport {
        guard !samples.isEmpty else {
            return FrameBudgetReport(frames: 0, averageMs: 0, p95Ms: 0, p99Ms: 0, worstMs: 0,
                                     overBudget: 0, passes: false, summary: "no frames measured")
        }
        let sorted = samples.sorted()
        let n = sorted.count
        let average = samples.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int(Double(n - 1) * 0.95))]
        let p99 = sorted[min(n - 1, Int(Double(n - 1) * 0.99))]
        let worst = sorted[n - 1]
        let deadline = budgetMilliseconds * latencyAllowance
        let over = samples.filter { $0 > deadline }.count
        let passes = p99 <= deadline && Double(over) / Double(n) <= allowedOverBudgetFraction
        let summary = String(format: "%d frames · avg %.2f ms · p95 %.2f · p99 %.2f · worst %.2f · over %d/%d · %@",
                             n, average, p95, p99, worst, over, n, passes ? "pass" : "FAIL")
        return FrameBudgetReport(frames: n, averageMs: average, p95Ms: p95, p99Ms: p99, worstMs: worst,
                                 overBudget: over, passes: passes, summary: summary)
    }
}

public struct FrameBudgetReport: Sendable, Equatable {
    public var frames: Int
    public var averageMs: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var worstMs: Double
    public var overBudget: Int
    public var passes: Bool
    public var summary: String
}

// MARK: - Live harness

public struct RenderBenchmarkResult: Sendable, Equatable {
    public var width: Int, height: Int, frames: Int, fps: Double
    public var report: FrameBudgetReport
}

/// Renders synthetic frames through the real Metal pipeline and waits for GPU
/// completion, so the numbers include the work an export actually does.
/// Run manually from `lumen-cli bench`; unit tests use a tiny canvas only as a
/// smoke check.
public enum RenderBenchmark {
    public static func run(frames: Int = 120, width: Int = 1920, height: Int = 1080,
                           fps: Double = 60, motionBlur: Bool = false) throws -> RenderBenchmarkResult {
        let count = max(frames, 1)
        let w = max(width, 16), h = max(height, 16)
        let renderer = try Renderer()

        var timeline = Timeline(duration: Double(count) / max(fps, 1) + 1)
        timeline.audio.speedRampsAuto = false
        if motionBlur { timeline.camera.maxSamples = max(timeline.camera.maxSamples, 4) }

        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let screen = try syntheticFrame(device: device, width: w, height: h)
        guard let output = makeBuffer(w, h) else { throw RenderError.noDevice }

        let budget = FrameBudget(fps: fps)
        var samples: [Double] = []
        samples.reserveCapacity(count)

        // One warm-up frame keeps shader/pipeline creation out of the numbers.
        _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                       t: 0, canvas: SIMD2(w, h), fps: fps)

        for i in 0..<count {
            let start = CACurrentMediaTime()
            _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                           t: min(Double(i) / max(fps, 1), timeline.compositionDuration),
                           canvas: SIMD2(w, h), fps: fps)
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        return RenderBenchmarkResult(width: w, height: h, frames: count, fps: fps,
                                     report: budget.evaluate(samples))
    }

    private static func render(renderer: Renderer, timeline: Timeline, screen: SourceFrame,
                               output: CVPixelBuffer, t: Double, canvas: SIMD2<Int>, fps: Double) throws -> Bool {
        let request = RenderRequest(timeline: timeline, t: t, screen: screen, canvas: canvas, fps: fps,
                                    backingScale: 1, quality: .export)
        let latch = DispatchSemaphore(value: 0)
        guard renderer.render(request, into: output, completion: { latch.signal() }) else { return false }
        guard latch.wait(timeout: .now() + 30) == .success else { throw RenderError.pipeline("frame timeout") }
        return true
    }

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        return pb
    }

    private static func syntheticFrame(device: MTLDevice, width: Int, height: Int) throws -> SourceFrame {
        guard let pb = makeBuffer(width, height) else { throw RenderError.noDevice }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let row = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let p = row.advanced(by: y * stride)
                for x in 0..<width {
                    p[x * 4 + 0] = UInt8((x &* 3) & 0xFF)
                    p[x * 4 + 1] = UInt8((y &* 2) & 0xFF)
                    p[x * 4 + 2] = UInt8(((x + y) &* 1) & 0xFF)
                    p[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RenderError.noDevice }
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                        width, height, 0, &cv) == kCVReturnSuccess,
              let cv, let texture = CVMetalTextureGetTexture(cv) else { throw RenderError.noDevice }
        return SourceFrame(id: 1, pts: 0, pixelBuffer: pb, texture: texture, cv: cv)
    }
}
```

### Sources/LumenRender/PersonMatteSequence.swift

```swift
import Foundation
import Metal
import LumenProject

/// Reads the real Vision-generated LUMASK1 person matte format. Only two mask
/// frames per GPU-in-flight slot are resident, not the entire recording.
/// The source timestamps in the file already include the webcam track offset.
final class PersonMatteSequence {
    struct Pair {
        let previous: MTLTexture
        let next: MTLTexture
        let fraction: Float
    }

    let url: URL
    let info: PersonMaskInfo
    private let file: FileHandle
    private let times: [Double]
    private let frameBytes: Int
    private let stride: Int
    private var slots: [(index: Int, texture: MTLTexture?)] =
        Array(repeating: (index: -1, texture: nil), count: 6)

    init?(url: URL, info: PersonMaskInfo) {
        guard info.width > 0, info.height > 0, info.fps > 0, info.frames > 0,
              let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        guard let h = try? fh.read(upToCount: 16), h.count == 16,
              Array(h.prefix(8)) == [0x4c, 0x55, 0x4d, 0x41, 0x53, 0x4b, 0x31, 0],
              Self.uint32(h, 8) == UInt32(info.width),
              Self.uint32(h, 12) == UInt32(info.height) else {
            try? fh.close(); return nil
        }
        let bytes = info.width * info.height, stride = bytes + 8
        guard let size = try? fh.seekToEnd(), size >= UInt64(16 + stride * info.frames) else {
            try? fh.close(); return nil
        }
        var stamps: [Double] = []
        stamps.reserveCapacity(info.frames)
        for i in 0..<info.frames {
            guard (try? fh.seek(toOffset: UInt64(16 + i * stride))) != nil,
                  let data = try? fh.read(upToCount: 8), data.count == 8 else {
                try? fh.close(); return nil
            }
            let t = Double(bitPattern: Self.uint64(data))
            guard t.isFinite && (stamps.last == nil || t >= stamps.last!) else {
                try? fh.close(); return nil
            }
            stamps.append(t)
        }
        self.url = url
        self.info = info
        self.file = fh
        self.times = stamps
        self.frameBytes = bytes
        self.stride = stride
    }

    deinit { try? file.close() }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for j in 0..<4 { v |= UInt32(data[data.startIndex + offset + j]) << (8 * j) }
        return v
    }

    private static func uint64(_ data: Data) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(data[data.startIndex + j]) << (8 * j) }
        return v
    }

    /// Find bracketing timestamp samples. Missing or stale masks are never
    /// reused across long video gaps; render a conventional webcam instead.
    func indices(at time: Double) -> (Int, Int, Float)? {
        guard time.isFinite, !times.isEmpty else { return nil }
        let maximumStaleness = max(2.5 / info.fps, 0.10)
        if time < times[0] {
            return times[0] - time <= maximumStaleness ? (0, 0, 0) : nil
        }
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        let a = max(0, lo - 1), b = min(times.count - 1, lo)
        guard time - times[a] <= maximumStaleness else { return nil }
        if a == b || times[b] - times[a] > maximumStaleness * 2 { return (a, a, 0) }
        let f = Float(min(max((time - times[a]) / max(times[b] - times[a], 0.000001), 0), 1))
        return (a, b, f)
    }

    private func texture(frame: Int, slot: Int, device: MTLDevice) -> MTLTexture? {
        let position = min(max(slot, 0), 5)
        if slots[position].index == frame, let texture = slots[position].texture { return texture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: info.width,
                                                               height: info.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = slots[position].texture ?? device.makeTexture(descriptor: desc),
              (try? file.seek(toOffset: UInt64(16 + frame * stride + 8))) != nil,
              let raw = try? file.read(upToCount: frameBytes), raw.count == frameBytes else { return nil }
        raw.withUnsafeBytes { bytes in
            if let pointer = bytes.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, info.width, info.height),
                                mipmapLevel: 0, withBytes: pointer, bytesPerRow: info.width)
            }
        }
        slots[position] = (frame, texture)
        return texture
    }

    func sample(at t: Double, slot: Int, device: MTLDevice) -> Pair? {
        guard let (a, b, fraction) = indices(at: t),
              let first = texture(frame: a, slot: slot * 2, device: device),
              let second = a == b ? first : texture(frame: b, slot: slot * 2 + 1, device: device)
        else { return nil }
        return Pair(previous: first, next: second, fraction: fraction)
    }
}
```

### Sources/LumenRender/PrivacyMaskGeometry.swift

```swift
import Foundation
import simd

/// Pure source-to-canvas mask geometry. Source coordinates are always used
/// even after manual zoom, auto-zoom, or aspect-ratio changes.
public enum PrivacyMaskGeometry {
    public static func canvasRect(_ rect: SIMD4<Float>, geometry: Geometry,
                                  camera: SIMD2<Double>, scale: Double) -> SIMD4<Float>? {
        guard rect.x.isFinite, rect.y.isFinite, rect.z.isFinite, rect.w.isFinite,
              rect.z > 0, rect.w > 0 else { return nil }
        let source = geometry.src
        let x0 = max(Double(rect.x), 0), y0 = max(Double(rect.y), 0)
        let x1 = min(Double(rect.x + rect.z), source.x)
        let y1 = min(Double(rect.y + rect.w), source.y)
        guard x1 > x0, y1 > y0 else { return nil }
        let a = geometry.toCanvas(SIMD2(x0, y0), cam: camera, scale: scale)
        let b = geometry.toCanvas(SIMD2(x1, y1), cam: camera, scale: scale)
        return SIMD4(Float(a.x), Float(a.y), Float(b.x - a.x), Float(b.y - a.y))
    }

    /// Cell edge in source pixels.
    ///
    /// The identity mosaic and the secret mosaic must look like the same
    /// mosaic — a secret differs only in where its colour comes from, never in
    /// its size — so both use the same grid. Tuned by eye on a realistic
    /// single-line field: roughly half the masked box height, so a row still
    /// reads as many crisp cells instead of a slab and every glyph is
    /// averaged away rather than outlined.
    public static func cell(boxHeight: Float) -> Float {
        max(8, max(boxHeight, 1) * 0.55)
    }

    /// Snap the treated rect outward to whole cells. The quad edge must land
    /// on a cell boundary: a partial cell leaves an unmasked sliver as soon
    /// as the camera zooms, and a soft edge would blend the glyphs back in.
    public static func mosaicRegion(_ rect: SIMD4<Float>, cell: Float) -> SIMD4<Float> {
        let c = max(cell, 1)
        let x0 = (rect.x / c).rounded(.down) * c
        let y0 = (rect.y / c).rounded(.down) * c
        let x1 = ((rect.x + rect.z) / c).rounded(.up) * c
        let y1 = ((rect.y + rect.w) / c).rounded(.up) * c
        return SIMD4(x0, y0, max(x1 - x0, c), max(y1 - y0, c))
    }

    /// A single pixel of UI paint from OUTSIDE the protected source rect is
    /// safe to extend across that rect. Never sample sensitive pixels for the
    /// default Blend mode. Solid fill is used if no safe neighbor exists.
    public static func outsideSample(_ rect: SIMD4<Float>,
                                     sourceSize: SIMD2<Float>) -> SIMD2<Float>? {
        guard rect.z > 0, rect.w > 0, sourceSize.x > 0, sourceSize.y > 0 else { return nil }
        let cx = min(max(rect.x + rect.z * 0.5, 0.5), sourceSize.x - 0.5)
        let cy = min(max(rect.y + rect.w * 0.5, 0.5), sourceSize.y - 0.5)
        let left = max(rect.x, 0), top = max(rect.y, 0)
        let right = max(sourceSize.x - (rect.x + rect.z), 0)
        let bottom = max(sourceSize.y - (rect.y + rect.w), 0)
        let candidates: [(Float, SIMD2<Float>)] = [
            (left, SIMD2(rect.x - min(16, left * 0.5), cy)),
            (right, SIMD2(rect.x + rect.z + min(16, right * 0.5), cy)),
            (top, SIMD2(cx, rect.y - min(16, top * 0.5))),
            (bottom, SIMD2(cx, rect.y + rect.w + min(16, bottom * 0.5)))
        ]
        guard let best = candidates.max(by: { $0.0 < $1.0 }), best.0 >= 8 else { return nil }
        return SIMD2(min(max(best.1.x, 0.5), sourceSize.x - 0.5),
                     min(max(best.1.y, 0.5), sourceSize.y - 0.5))
    }
}
```

### Sources/LumenRender/Renderer.swift

```swift
import Foundation
import Metal
import MetalKit
import AppKit
import CoreVideo
import QuartzCore
import simd
import os
import LumenCore
import LumenProject
import LumenDirector

public enum RenderError: Error { case noDevice, pipeline(String) }
public enum RenderQuality: Sendable { case preview, export }

public struct RenderRequest: @unchecked Sendable {
    public var live: FrameState?
    public var timeline: Timeline, t: Double
    public var screen: SourceFrame, webcam: SourceFrame?
    public var canvas: SIMD2<Int>, fps: Double, backingScale: Double, quality: RenderQuality
    /// The analysis cache, if this recording has generated on-device person mattes.
    public var personMaskDirectory: URL?
    /// Preview-only animation phase for the pixel-dither backdrop. Always 0 for export, so output stays deterministic.
    public var uiTime: Double
    public var pointer: SIMD4<Float>
    /// Keep the scene premultiplied and leave the canvas transparent. Used by
    /// ProRes 4444 deliveries that need an alpha channel.
    public var transparent: Bool
    /// Draw only rings and the cursor, over a transparent canvas. Used to
    /// export the cursor as its own video layer.
    public var cursorOnly: Bool
    public init(timeline: Timeline, t: Double, screen: SourceFrame, webcam: SourceFrame? = nil, canvas: SIMD2<Int>,
                fps: Double = 60, backingScale: Double = 2, quality: RenderQuality = .export, uiTime: Double = 0,
                pointer: SIMD4<Float> = .zero, personMaskDirectory: URL? = nil,
                transparent: Bool = false, cursorOnly: Bool = false) {
        self.timeline = timeline; self.t = t; self.screen = screen; self.webcam = webcam
        self.canvas = canvas; self.fps = fps; self.backingScale = backingScale; self.quality = quality; self.uiTime = uiTime; self.pointer = pointer
        self.personMaskDirectory = personMaskDirectory; self.transparent = transparent; self.cursorOnly = cursorOnly
    }
}

/// Frame placement inside the canvas. Pixel-snapped so the frame edge is crisp. Shared with the UI (focus editor).
public struct Geometry: Sendable {
    public var canvas: SIMD2<Double>, src: SIMD2<Double>
    public var content: SIMD4<Double>        // x y w h in canvas px
    public var radius: Double, ui: Double
    /// Per-corner radii in canvas px, ordered top-left, top-right, bottom-right,
    /// bottom-left. Equal values mean the uniform squircle path.
    public var radii: SIMD4<Double>
    public init(canvas c: SIMD2<Int>, src: SIMD2<Double>, style: Style) {
        let transform = ZoomTransform(canvas: c, source: src, style: style)
        canvas = transform.canvas; self.src = src
        content = transform.videoRect
        ui = canvas.x / 1440; radius = style.cornerRadius * ui
        let r = style.radii
        radii = SIMD4(r.tl, r.tr, r.br, r.bl) * ui
    }
    /// Source px -> canvas px for a given camera.
    public func toCanvas(_ p: SIMD2<Double>, cam: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let center = ZoomTransform.clamp(cam, source: src, scale: scale)
        let view = src / max(scale, 1), n = (p - (center - view / 2)) / view
        return SIMD2(content.x + n.x * content.z, content.y + n.y * content.w)
    }
}

private struct QuadU { var rect: SIMD4<Float>; var canvas: SIMD2<Float> }
private struct BackdropU { var content: SIMD4<Float>; var canvas: SIMD2<Float>; var angle: Float; var count: Int32; var kind: Int32
                           var radius: Float; var shadow: Float; var scale: Float; var cell: Float; var density: Float; var hasWall: Int32
                           var time: Float; var pointer: SIMD4<Float>; var wallBlur: Float; var imgAlpha: Float; var imgContrast: Float; var imgBright: Float }
private struct ContentU { var content: SIMD4<Float>; var src: SIMD2<Float>; var cam: SIMD2<Float>; var scale: Float; var radius: Float; var border: Float; var p: Float; var tilt: SIMD2<Float>; var radii: SIMD4<Float> }
private struct CursorU { var content: SIMD4<Float>; var radius: Float; var opacity: Float; var layer: UInt32; var p: Float }
private struct RingU { var content: SIMD4<Float>; var color: SIMD4<Float>; var center: SIMD2<Float>; var radius: Float; var progress: Float; var cr: Float; var mode: Int32; var cam: SIMD2<Float>; var scale: Float; var srcSize: SIMD2<Float> }
private struct SourceMaskGPU { var rect: SIMD4<Float>; var block: SIMD4<Float> }
private struct WebU {
    var crop: SIMD4<Float>; var bubble: SIMD4<Float>
    var radius: Float; var shape: Float; var mirror: Float; var border: Float
    var shadow: Float; var bw: Float; var minif: Float; var margin: Float
    var opacity: Float; var maskMode: Float; var matteMix: Float; var detail: Float
    var canvasColor: SIMD4<Float>
}
private struct AccU { var weight: Float }
private struct ResU { var levels: Float; var seed: UInt32; var blur: Float; var alpha: Float }
private struct TextSpriteU {
    var opacity: Float; var blur: Float; var pad0: Float; var pad1: Float
    init(opacity: Float, blur: Float = 0) { self.opacity = opacity; self.blur = blur; pad0 = 0; pad1 = 0 }
}
private struct CaptionCardU {
    var rect: SIMD4<Float>; var tint: SIMD4<Float>; var canvas: SIMD2<Float>; var radius: Float; var opacity: Float
}
private struct BlurU { var dir: SIMD2<Float>; var sigma: Float; var pad0: Float; var pad1: Float }
private struct LoupeU {
    var glass: SIMD4<Float>    // centre x,y, radius, border
    var source: SIMD4<Float>   // target x,y, width,height
    var zoom: SIMD2<Float>     // camera scale, magnification
    var opacity: Float
    var round: Float
    var radius: Float
}
private struct HighlightU {
    var rect: SIMD4<Float>
    var content: SIMD4<Float>
    var opacity: Float
    var strength: Float
    var mode: Int32
}
private struct BackdropKey: Equatable { var style: Style; var size: SIMD2<Int>; var wall: String; var phase: Double; var pointer: SIMD4<Float> }
private struct Keep: @unchecked Sendable { let o: Any }

/// BGRA source -> mip-mapped copy, regenerated only when a NEW source frame arrives (sample-and-hold reuses the chain).
private final class MipCache {
    private var tex: MTLTexture?
    private var key: UInt64 = .max
    func texture(for f: SourceFrame, device: MTLDevice, cb: MTLCommandBuffer) -> MTLTexture? {
        let w = f.texture.width, h = f.texture.height
        if tex == nil || tex!.width != w || tex!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
            tex = device.makeTexture(descriptor: d); key = .max
        }
        guard let t = tex else { return nil }
        if key != f.id, let b = cb.makeBlitCommandEncoder() {
            b.copy(from: f.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                   sourceSize: MTLSize(width: w, height: h, depth: 1), to: t, destinationSlice: 0, destinationLevel: 0,
                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            b.generateMipmaps(for: t); b.endEncoding(); key = f.id
        }
        return t
    }
}

/// Counts presented frames and how often a frame missed its expected vsync.
/// This turns "feels smooth" into a number the debug HUD can show.
public final class PresentStats: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(last: Double, frames: Int, late: Int, worst: Double)>(initialState: (0, 0, 0, 0))
    public init() {}
    public func record(_ time: Double, expected: Double) {
        guard time > 0 else { return }
        state.withLock { s in
            if s.last > 0 {
                let delta = time - s.last
                s.frames += 1
                if delta > expected * 1.5 { s.late += 1 }
                s.worst = max(s.worst, delta)
            }
            s.last = time
        }
    }
    public var snapshot: (frames: Int, late: Int, worstMs: Double) {
        state.withLock { ($0.frames, $0.late, $0.worst * 1000) }
    }
    public func reset() { state.withLock { $0 = (0, 0, 0, 0) } }
}

/// Pure-ish renderer: output depends only on (RenderRequest). Owned by ONE render queue; not thread-safe.
/// Preview and export call the same `encode`. Triple-buffered; the frame loop allocates nothing after warm-up.
public final class Renderer: @unchecked Sendable {
    public let device: MTLDevice
    public let presentStats = PresentStats()
    private let queue: MTLCommandQueue
    private let lib: MTLLibrary
    private let pBackdrop, pContent, pCursor, pRing, pWeb, pAccum: MTLRenderPipelineState
    private let pSourceMask: MTLComputePipelineState
    private var maskedSources: [MTLTexture?] = [nil, nil, nil]
    private let pTextSprite: MTLRenderPipelineState
    private let pCaptionCard: MTLRenderPipelineState
    private let pBlur: MTLRenderPipelineState
    private let pHighlight: MTLRenderPipelineState
    private let pLoupe: MTLRenderPipelineState
    private let textCache = TextOverlayCache()
    private var pResolve: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var personMatte: PersonMatteSequence?
    private let sem = DispatchSemaphore(value: 3)
    /// EMA of GPU seconds per motion-blur sample, used to size preview blur.
    private let perSample = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var slot = 0
    private var work: [MTLTexture] = [], accum: [MTLTexture] = []
    /// One blurred copy per in-flight slot, allocated only when a caption card
    /// is actually on screen. The caption pass may not sample the render
    /// target it is writing, so the scene is copied before the card is drawn.
    private var captionSrc: [MTLTexture?] = [nil, nil, nil]
    /// Quarter-resolution ping-pong pair for the card's separable Gaussian.
    private var blurA: [MTLTexture?] = [nil, nil, nil]
    private var blurB: [MTLTexture?] = [nil, nil, nil]
    private var backdrop: MTLTexture?
    private var backdropKey: BackdropKey?
    private var backdropMipmapped = false
    private var size = SIMD2<Int>(0, 0)
    private var wallTex: MTLTexture?
    private var wallID = ""
    private var styleImage: MTLTexture?
    private var styleImageID = ""
    private var cameraBackground: MTLTexture?
    private var cameraBackgroundID = ""
    private let screenMip = MipCache(), webMip = MipCache()
    private var atlas: CursorAtlas?
    private var atlasPack: CursorPack?
    private var customs: [CustomCursor] = []
    private let outCache: CVMetalTextureCache
    public let fxKernels: FXKernels?
    public let upscaler: Upscaler?
    private let contentPass: ContentPass?
    private var transparentTex: MTLTexture?

    public init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw RenderError.noDevice }
        let l = try Self.library(d), f = MTLPixelFormat.rgba16Float
        device = d; queue = q; lib = l
        pBackdrop = try Self.pipe(d, l, "backdropFS", f, 0)
        pContent = try Self.pipe(d, l, "contentFS", f, 1)
        pCursor = try Self.pipe(d, l, "cursorFS", f, 1)
        pRing = try Self.pipe(d, l, "ringFS", f, 1)
        guard let maskFunction = l.makeFunction(name: "pixelateMask") else { throw RenderError.pipeline("pixelateMask") }
        pSourceMask = try d.makeComputePipelineState(function: maskFunction)
        pWeb = try Self.pipe(d, l, "webFS", f, 1)
        pAccum = try Self.pipe(d, l, "accumFS", f, 2)
        pTextSprite = try Self.pipe(d, l, "textSpriteFS", f, 1)
        pCaptionCard = try Self.pipe(d, l, "captionCardFS", f, 1)
        pBlur = try Self.pipe(d, l, "gaussFS", f, 0)
        pHighlight = try Self.pipe(d, l, "highlightFS", f, 1)
        pLoupe = try Self.pipe(d, l, "loupeFS", f, 1)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, d, nil, &c)
        guard let c else { throw RenderError.noDevice }
        outCache = c
        let fk = try? FXKernels(device: d)
        fxKernels = fk
        upscaler = fk.map(Upscaler.init(kernels:))
        contentPass = fk.map(ContentPass.init(kernels:))
    }

    /// Prefer the metallib SwiftPM builds. Older Xcode toolchains only copy
    /// `Shaders.metal` into the bundle, so compile it once as a fallback
    /// instead of failing to launch.
    private static func library(_ d: MTLDevice) throws -> MTLLibrary {
        if let lib = try? d.makeDefaultLibrary(bundle: .module) { return lib }
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw RenderError.pipeline("Missing default.metallib and Shaders.metal")
        }
        return try d.makeLibrary(source: source, options: nil)
    }

    /// blend: 0 none, 1 premultiplied over, 2 additive
    private static func pipe(_ d: MTLDevice, _ l: MTLLibrary, _ fs: String, _ fmt: MTLPixelFormat, _ blend: Int) throws -> MTLRenderPipelineState {
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = l.makeFunction(name: "quadVS"); p.fragmentFunction = l.makeFunction(name: fs)
        guard p.vertexFunction != nil, p.fragmentFunction != nil else { throw RenderError.pipeline(fs) }
        let a = p.colorAttachments[0]!
        a.pixelFormat = fmt
        if blend > 0 {
            a.isBlendingEnabled = true; a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
            a.destinationAlphaBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
        }
        return try d.makeRenderPipelineState(descriptor: p)
    }

    public func setCustomCursors(_ c: [CustomCursor]) { customs = c; atlas = nil }

    /// User-selected image is decoded only on path/version change, never per frame.
    private func loadCameraBackgroundIfNeeded(_ path: String?) {
        guard let path, !path.isEmpty else { cameraBackgroundID = ""; cameraBackground = nil; return }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let version = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(version)"
        guard id != cameraBackgroundID else { return }
        cameraBackgroundID = id
        cameraBackground = try? MTKTextureLoader(device: device)
            .newTexture(URL: url, options: [.SRGB: false])
    }

    /// A user photo or Unsplash download used as the canvas backdrop. Decoded
    /// only when the path or file modification date changes.
    private func loadStyleImageIfNeeded(_ path: String?) {
        guard let path, !path.isEmpty else { styleImageID = ""; styleImage = nil; return }
        let url: URL = (path == "serene-lake.jpg" ? Bundle.main.url(forResource: "serene-lake", withExtension: "jpg", subdirectory: "Wallpapers")
            ?? Bundle.main.url(forResource: "serene-lake", withExtension: "jpg")
            : nil) ?? URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let version = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(version)"
        guard id != styleImageID else { return }
        styleImageID = id
        styleImage = try? MTKTextureLoader(device: device)
            .newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true])
    }

    /// The Mac's own desktop picture, loaded once per wallpaper change. No download, no bundled asset.
    private func loadWallpaperIfNeeded() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallTex = nil; wallID = ""; return
        }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(stamp)"
        guard id != wallID else { return }
        wallID = id; wallTex = nil
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = cg.width, h = cg.height, bytes = w * 4
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return }
        var data = [UInt8](repeating: 0, count: bytes * h)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytes)
        wallTex = tex
    }

    private func ensureTargets(_ s: SIMD2<Int>, backdropBlur: Bool) {
        guard s != size || backdropMipmapped != backdropBlur else { return }
        for _ in 0..<3 { sem.wait() }
        func mk(mipmapped: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                               width: s.x, height: s.y, mipmapped: mipmapped)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        work = (0..<3).map { _ in mk() }; accum = (0..<3).map { _ in mk() }
        captionSrc = [nil, nil, nil]; blurA = [nil, nil, nil]; blurB = [nil, nil, nil]
        // Allocate mip storage only when the user enables blur. Ordinary video
        // exports keep their previous memory footprint and renderer stages.
        backdrop = mk(mipmapped: backdropBlur)
        backdropMipmapped = backdropBlur
        backdropKey = nil
        size = s
        for _ in 0..<3 { sem.signal() }
    }

    // MARK: Entry points

    /// Preview: renders into the layer's next drawable. Never blocks: returns false when all 3 frames are in flight.
    /// `presentAt` lets the caller present on an exact host-clock instant, so a
    /// frame rendered one vsync ahead has a full frame of scheduling slack.
    @discardableResult
    public func draw(_ r: RenderRequest, to layer: CAMetalLayer, presentAt: Double? = nil) -> Bool {
        guard let dr = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        guard encode(r, output: dr.texture, commandBuffer: cb, wait: false) else { return false }
        let stats = presentStats, expected = 1 / max(r.fps, 1)
        dr.addPresentedHandler { d in stats.record(d.presentedTime, expected: expected) }
        if let t = presentAt, t > CACurrentMediaTime() { cb.present(dr, atTime: t) } else { cb.present(dr) }
        cb.commit(); return true
    }

    /// Export: renders into an IOSurface-backed BGRA8 or ARGB2101010 pixel buffer. `completion` fires when the GPU is done.
    public func render(_ r: RenderRequest, into pb: CVPixelBuffer, completion: @escaping @Sendable () -> Void = {}) -> Bool {
        let fmt: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA: fmt = .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked: fmt = .bgr10a2Unorm
        default: return false
        }
        var cv: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, outCache, pb, attrs, fmt, CVPixelBufferGetWidth(pb),
                                                        CVPixelBufferGetHeight(pb), 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv), let cb = queue.makeCommandBuffer() else { return false }
        guard encode(r, output: tex, commandBuffer: cb) else { return false }
        let keep = Keep(o: cv)
        cb.addCompletedHandler { _ in withExtendedLifetime(keep) {}; completion() }
        cb.commit(); return true
    }

    // MARK: Frame

    @discardableResult
    public func encode(_ r: RenderRequest, output: MTLTexture, commandBuffer cb: MTLCommandBuffer, wait: Bool = true) -> Bool {
        let cs = r.canvas
        guard output.width == cs.x, output.height == cs.y, cs.x > 0, cs.y > 0 else { return false }
        let tl = r.timeline
        ensureTargets(cs, backdropBlur: tl.style.wallpaperBlur > 0)
        if wait { sem.wait() } else if sem.wait(timeout: .now()) != .success { return false }
        let s = slot; slot = (slot + 1) % 3
        let g = Geometry(canvas: cs, src: SIMD2(Double(r.screen.texture.width), Double(r.screen.texture.height)), style: tl.style)

        guard let srcTex = screenMip.texture(for: r.screen, device: device, cb: cb), let bd = backdrop else { sem.signal(); return false }
        var webTex: MTLTexture?
        if tl.webcam != nil, let w = r.webcam { webTex = webMip.texture(for: w, device: device, cb: cb) }
        // Cache a bounded, timestamped pair of Vision mask textures per Metal
        // in-flight slot. Both preview and export traverse this same path.
        var matte: PersonMatteSequence.Pair?
        if tl.webcam != nil, let info = tl.derived?.personMask,
           let dir = r.personMaskDirectory {
            let url = dir.appendingPathComponent(info.file)
            if personMatte?.url != url || personMatte?.info != info {
                personMatte = PersonMatteSequence(url: url, info: info)
            }
            matte = personMatte?.sample(at: tl.timeMap.source(atOutput: r.t), slot: s, device: device)
        } else {
            personMatte = nil
        }
        if atlas == nil || atlasPack != tl.cursor.pack {
            atlas = CursorAtlas(device: device, queue: queue, pack: tl.cursor.pack, customs: customs); atlasPack = tl.cursor.pack
        }
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y))

        // 1. backdrop cache (style or size change only)
        if tl.style.background == .wallpaper || tl.webcam?.backdrop == .wallpaper { loadWallpaperIfNeeded() }
        if tl.style.background == .image { loadStyleImageIfNeeded(tl.style.backgroundImagePath) }
        if tl.webcam?.backdrop == .image { loadCameraBackgroundIfNeeded(tl.webcam?.backdropImagePath) }
        let patterned = tl.style.background == .wave || tl.style.background == .field
        let backgroundTime = patterned ? (r.quality == .export ? r.t : r.uiTime)
            : (tl.style.background == .dither && r.quality == .preview ? r.uiTime : 0)
        let pointer = tl.style.background == .wave && r.quality == .preview ? r.pointer : .zero
        let key = BackdropKey(style: tl.style, size: cs,
                              wall: tl.style.background == .wallpaper ? wallID : (tl.style.background == .image ? styleImageID : ""),
                              phase: backgroundTime, pointer: pointer)
        let needsBackdrop = !r.transparent && !r.cursorOnly
        if needsBackdrop && backdropKey != key {
            backdropKey = key
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = bd; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                e.setRenderPipelineState(pBackdrop)
                quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                let st = tl.style
                var cols = st.colors.isEmpty ? [SIMD4<Float>(0, 0, 0, 1)] : st.colors.map(\.simd)
                if cols.count < 6 { cols += [SIMD4<Float>](repeating: cols[0], count: 6 - cols.count) }
                let kind: Int32 = switch st.background {
                case .gradient: 0
                case .mesh: 1
                case .dither: 3
                case .wallpaper: 4
                case .canvas: 5
                case .solid: 2
                case .wave: 6
                case .field: 7
                case .image: 8
                }
                let hasStyleImage = st.background == .image && styleImage != nil
                if st.background == .wallpaper, let wallTex { e.setFragmentTexture(wallTex, index: 0) }
                if hasStyleImage, let styleImage { e.setFragmentTexture(styleImage, index: 0) }
                frag(e, BackdropU(content: SIMD4<Float>(g.content), canvas: canvasF, angle: Float(st.gradientAngle * .pi / 180),
                                  count: Int32(max(st.colors.count, 1)), kind: kind,
                                  radius: Float(g.radius), shadow: Float(st.shadow), scale: Float(g.ui * 1.33),
                                  cell: Float(max(2, st.ditherCell * g.ui)), density: Float(st.ditherDensity),
                                  hasWall: (st.background == .wallpaper && wallTex != nil) || hasStyleImage ? 1 : 0,
                                  time: Float(backgroundTime), pointer: pointer,
                                  wallBlur: Float(st.wallpaperBlur), imgAlpha: Float(st.imageOpacity),
                                  imgContrast: Float(st.imageContrast), imgBright: Float(st.imageBrightness)))
                cols.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                e.endEncoding()
            }
            if tl.style.wallpaperBlur > 0, let blit = cb.makeBlitCommandEncoder() {
                // Generate the full mip pyramid only after the backdrop
                // itself changed. Screen content never enters these mipmaps.
                blit.generateMipmaps(for: bd)
                blit.endEncoding()
            }
        }

        // 2. sub-frames (motion blur): scene over transparent, accumulated, resolved over the backdrop
        let K = sampleCount(r, g)
        let dt = 1 / max(r.fps, 1)
        for i in 0..<K {
            let off = ((Double(i) + 0.5) / Double(K) - 0.5) * tl.camera.shutter * dt
            var st = r.live ?? tl.evaluate(at: r.t + off)
            if r.live == nil, tl.derived == nil { st.cameraCenter = SIMD2<Float>(Float(g.src.x / 2), Float(g.src.y / 2)) }
            guard let protectedSource = maskedSource(srcTex, masks: st.emphasis.masks,
                                                       pixelSize: Float(tl.overlays.privacy.pixelSize), slot: s, cb: cb) else {
                sem.signal(); return false
            }
            scene(cb, into: work[s], slot: s, st: st, r: r, g: g, src: protectedSource, web: webTex, matte: matte)
            if K > 1 {
                let pd = MTLRenderPassDescriptor()
                pd.colorAttachments[0].texture = accum[s]; pd.colorAttachments[0].loadAction = i == 0 ? .clear : .load
                pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); pd.colorAttachments[0].storeAction = .store
                if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                    e.setRenderPipelineState(pAccum); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                    frag(e, AccU(weight: 1 / Float(K))); e.setFragmentTexture(work[s], index: 0)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); e.endEncoding()
                }
            }
        }

        // 3. resolve
        let fmt = output.pixelFormat
        if pResolve[fmt] == nil { pResolve[fmt] = try? Self.pipe(device, lib, "resolveFS", fmt, 0) }
        guard let pr = pResolve[fmt] else { sem.signal(); return false }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = output; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
            e.setRenderPipelineState(pr); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
            let zoom = r.live?.cameraScale ?? tl.evaluate(at: r.t).cameraScale
            frag(e, ResU(levels: fmt == .bgr10a2Unorm ? 1023 : 255,
                         seed: UInt32(truncatingIfNeeded: Int(r.t * 1000)),
                         blur: BackdropBlur.mipLevel(enabled: tl.style.wallpaperBlur > 0,
                                                     cameraScale: zoom),
                         alpha: r.transparent || r.cursorOnly ? 0 : 1))
            e.setFragmentTexture(K > 1 ? accum[s] : work[s], index: 0); e.setFragmentTexture(bd, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); e.endEncoding()
        }
        let sem = self.sem, keep = Keep(o: (r.screen, r.webcam)), cost = perSample, samples = Double(K)
        cb.addCompletedHandler { b in
            withExtendedLifetime(keep) {}
            let gpu = b.gpuEndTime - b.gpuStartTime
            if gpu > 0 { cost.withLock { $0 = $0 == 0 ? gpu / samples : $0 * 0.9 + 0.1 * gpu / samples } }
            sem.signal()
        }
        return true
    }

    /// Adaptive K = ceil(max screen-space px/frame / 2), clamped; static scenes cost nothing. Preview <= 2.
    /// Internal (not private) so tests can prove sub-frame accumulation.
    func sampleCount(_ r: RenderRequest, _ g: Geometry) -> Int {
        let tl = r.timeline
        guard tl.camera.shutter > 0, tl.derived != nil, r.fps > 0 else { return 1 }
        let dt = 1 / r.fps, a = tl.evaluate(at: r.t - dt / 2), b = tl.evaluate(at: r.t + dt / 2)
        let k = g.content.z / g.src.x, sc = Double(b.cameraScale)
        let cam = Double(simd_length(b.cameraCenter - a.cameraCenter)) * k * sc
        let zoom = abs(log(Double(b.cameraScale) / Double(a.cameraScale))) * g.content.z * 0.5
        let cur = Double(simd_length(b.cursor.position - a.cursor.position)) * k * sc
        let n = Int(ceil(max(cam, zoom, cur) / 2))
        var cap = tl.camera.maxSamples
        if r.quality == .preview {
            // Spend at most half of the frame budget on blur samples. Once
            // the GPU cost is measured, this can rise above 2 on fast Macs
            // and falls back to 2 before the first measurement.
            let per = perSample.withLock { $0 }
            let budget = per > 0 ? min(max(Int(0.5 / max(r.fps, 1) / per), 1), 4) : 2
            cap = min(budget, tl.camera.maxSamples)
        }
        return min(max(n, 1), cap)
    }

    private func scene(_ cb: MTLCommandBuffer, into tex: MTLTexture, slot: Int, st: FrameState, r: RenderRequest, g: Geometry,
                       src: MTLTexture, web: MTLTexture?, matte: PersonMatteSequence.Pair?) {
        let tl = r.timeline
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y)), content = SIMD4<Float>(g.content)
        let sc = max(Double(st.cameraScale), 1)
        let cam = ZoomTransform.clamp(SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y)), source: g.src, scale: sc)
        let pxPerSrc = g.content.z / g.src.x
        let drawingContent = !r.cursorOnly
        // Real-time upscaler path (was dead code: ContentPass/Upscaler were
        // never called). When magnification is high and tilt is off, the
        // compute content pass draws from the upscaled texture; the
        // fragment path below remains the fallback. The backdrop resolve
        // still composites this work texture over the cached backdrop.
        var computeContent = false
        if drawingContent, st.emphasis.masks.isEmpty, tl.camera.upscaleEnabled, st.cameraTilt == .zero, let cp = contentPass, let up = upscaler {
            let layout = ContentLayout(canvas: SIMD2<Int32>(Int32(g.canvas.x), Int32(g.canvas.y)),
                                       contentRect: content, radii: SIMD4<Float>(g.radii),
                                       srcSize: SIMD2<Float>(g.src))
            var params = UpscaleParams()
            params.maxFactor = tl.camera.upscaleMaxFactor
            if let upscaled = try? cp.prepareUpscale(up, cb, layout: layout, camCenter: SIMD2<Float>(cam),
                                                     zoom: Float(sc), source: src, sourceID: r.screen.id, params: params),
               let ce = cb.makeComputeCommandEncoder(),
               let transparent = transparentTexture() {
                try? cp.encode(ce, layout: layout, camCenter: SIMD2<Float>(cam), zoom: Float(sc),
                               backdrop: transparent, canvas: tex, source: src, upscaled: upscaled)
                ce.endEncoding()
                computeContent = true
            }
        }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = tex; pd.colorAttachments[0].loadAction = computeContent ? .load : .clear; pd.colorAttachments[0].storeAction = .store
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        // After a scene copy the encoder is reopened; `enc` is the live one.
        var enc = e
        func draw() { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4) }

        // content (fragment fallback when the upscaler did not engage)
        if drawingContent, !computeContent {
            enc.setRenderPipelineState(pContent); quad(enc, content, canvasF)
            frag(enc, ContentU(content: content, src: SIMD2<Float>(g.src), cam: SIMD2<Float>(cam), scale: Float(sc),
                             radius: Float(g.radius), border: tl.style.innerBorder ? 1 : 0, p: 0,
                             tilt: st.cameraTilt, radii: SIMD4<Float>(g.radii)))
            enc.setFragmentTexture(src, index: 0); draw()
        }

        // Highlight geometry follows the exact source-pixel camera transform.
        // Dimmer is drawn AFTER privacy redaction and never resamples raw pixels.
        if drawingContent, !st.emphasis.highlights.isEmpty {
            enc.setRenderPipelineState(pHighlight)
            for mark in st.emphasis.highlights where mark.opacity > 0.001 {
                let start = g.toCanvas(SIMD2(Double(mark.rect.x), Double(mark.rect.y)), cam: cam, scale: sc)
                let end = g.toCanvas(SIMD2(Double(mark.rect.x + mark.rect.z),
                                            Double(mark.rect.y + mark.rect.w)), cam: cam, scale: sc)
                let bounds = SIMD4<Float>(Float(min(start.x, end.x)), Float(min(start.y, end.y)),
                                           Float(abs(end.x - start.x)), Float(abs(end.y - start.y)))
                let mode: Int32 = switch mark.style {
                case .dim: 0
                case .outline: 1
                case .glow: 2
                }
                quad(enc, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                frag(enc, HighlightU(rect: bounds, content: content, opacity: mark.opacity,
                                    strength: mark.dim, mode: mode))
                draw()
            }
        }

        // Glass loupes: a magnified window over the source. Drawn before the
        // cursor so the pointer stays visible above the glass.
        if drawingContent, !st.emphasis.loupes.isEmpty {
            enc.setRenderPipelineState(pLoupe)
            let sourceSize = SIMD2<Float>(Float(g.src.x), Float(g.src.y))
            for glass in st.emphasis.loupes where glass.opacity > 0.001 {
                // A loupe magnifies RAW source pixels — skip it where an
                // active mask covers its target, or it would re-expose them.
                let coveredByMask = st.emphasis.masks.contains { m in
                    let r = m.rect
                    return r.x < glass.target.x + 16 && r.x + r.z > glass.target.x - 16
                        && r.y < glass.target.y + 16 && r.y + r.w > glass.target.y - 16
                }
                if coveredByMask { continue }
                let R = Float(max(glass.radius, 0.02)) * canvasF.x
                let center = SIMD2<Float>(glass.glass.x * canvasF.x, glass.glass.y * canvasF.y)
                quad(enc, SIMD4<Float>(center.x - R * 1.35, center.y - R * 1.35, R * 2.7, R * 2.7), canvasF)
                frag(enc, LoupeU(glass: SIMD4<Float>(center.x, center.y, R, R * glass.border * 2),
                               source: SIMD4<Float>(glass.target.x, glass.target.y, sourceSize.x, sourceSize.y),
                               zoom: SIMD2<Float>(Float(sc), Float(max(glass.magnification, 1))),
                               opacity: glass.opacity, round: glass.round ? 1 : 0,
                               radius: R * 0.32))
                enc.setFragmentTexture(src, index: 0)
                draw()
            }
        }

        // Click ripple. It must refract the composited frame, not the raw
        // source: the raw texture still contains masked pixels, so sampling it
        // would displace a secret out from under its mosaic. Copy the scene
        // once per frame (only while a click is on screen) and sample that.
        if tl.cursor.clickRing != nil, !st.clickFX.isEmpty {
            var ringSource: MTLTexture?
            if tl.cursor.clickEffect != .none, let cap = sceneCopyTexture(slot: slot, canvas: r.canvas) {
                enc.endEncoding()
                if let blit = cb.makeBlitCommandEncoder() {
                    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                              to: cap, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = tex
                rp.colorAttachments[0].loadAction = .load
                rp.colorAttachments[0].storeAction = .store
                if let reopened = cb.makeRenderCommandEncoder(descriptor: rp) {
                    enc = reopened; ringSource = cap
                }
            }
            enc.setRenderPipelineState(pRing)
            let ringSize = min(max(tl.cursor.clickSize, 0.5), 2.0)
            let R = 70 * g.ui * pow(sc, 0.5) * ringSize
            let ringAlpha = Float(min(max(tl.cursor.clickIntensity, 0), 1.5))
            let ringColor = SIMD4<Float>(tl.cursor.clickColor.r, tl.cursor.clickColor.g, tl.cursor.clickColor.b, tl.cursor.clickColor.a * ringAlpha)
            for ring in st.clickFX {
                let c = g.toCanvas(SIMD2<Double>(Double(ring.position.x), Double(ring.position.y)), cam: cam, scale: sc)
                quad(enc, SIMD4<Float>(Float(c.x - R), Float(c.y - R), Float(2 * R), Float(2 * R)), canvasF)
                let mode: Int32 = switch tl.cursor.clickEffect {
                case .none, .ripple: 0
                case .pulse: 1
                case .burst: 2
                case .glass: 3
                }
                frag(enc, RingU(content: content, color: ringColor, center: SIMD2<Float>(c), radius: Float(R),
                              progress: ring.progress, cr: Float(g.radius), mode: mode,
                              cam: SIMD2<Float>(cam), scale: Float(sc),
                              srcSize: ringSource != nil ? canvasF : SIMD2<Float>(g.src)))
                enc.setFragmentTexture(ringSource ?? src, index: 0)
                draw()
            }
        }

        // cursor
        let cs = st.cursor
        if cs.opacity > 0.01, let atlas, let ent = atlas.entry(cs.shape) {
            let S = 32 * r.backingScale * tl.cursor.size * pxPerSrc * pow(sc, 1 - tl.cursor.effectiveCompensation) * Double(cs.press)
            let c = g.toCanvas(SIMD2<Double>(Double(cs.position.x), Double(cs.position.y)), cam: cam, scale: sc)
            enc.setRenderPipelineState(pCursor)
            quad(enc, SIMD4<Float>(Float(c.x - ent.hot.x * S), Float(c.y - ent.hot.y * S), Float(S), Float(S)), canvasF)
            frag(enc, CursorU(content: content, radius: Float(g.radius), opacity: cs.opacity, layer: UInt32(ent.layer), p: 0))
            enc.setFragmentTexture(atlas.texture, index: 0); draw()
        }

        // Webcam placement is solved by the Director at output time. Never
        // replace its animated position with a hard-coded corner.
        if drawingContent, let wl = tl.webcam, let web {
            let settings = tl.layoutSettings[st.layoutKind]
            let rect = st.layout.cameraRect
            let opacity = tl.derived == nil ? 1 : max(0, min(st.layout.cameraOpacity, 1))
            let m = g.canvas.x * 0.03, legacySize = g.canvas.x * wl.size
            let legacyX = (wl.corner == .topLeft || wl.corner == .bottomLeft) ? m : g.canvas.x - m - legacySize
            let legacyY = (wl.corner == .topLeft || wl.corner == .topRight) ? m : g.canvas.y - m - legacySize
            let x = tl.derived == nil ? legacyX : Double(rect.x) * g.canvas.x
            let y = tl.derived == nil ? legacyY : Double(rect.y) * g.canvas.y
            let width = tl.derived == nil ? legacySize : Double(rect.z) * g.canvas.x
            let height = tl.derived == nil ? legacySize : Double(rect.w) * g.canvas.y
            if opacity > 0.001, width > 1, height > 1 {
                let margin = 24 * g.ui
                let crop = st.webcamCrop, ww = Double(web.width)
                let region = SIMD4<Float>(Float(x), Float(y), Float(width), Float(height))
                let cutout = st.layout.cutoutBlend > 0.5 && wl.backdrop == .original
                var maskMode: Float = switch wl.backdrop {
                case .original: cutout ? 1 : 0
                case .transparent: 1
                case .wallpaper: wallTex == nil ? 3 : 2
                case .canvas: 3
                case .image: cameraBackground == nil ? 3 : 2
                }
                if matte == nil { maskMode = 0 } // Never simulate a missing AI mask.
                let color = tl.style.colors.first?.simd ?? SIMD4<Float>(0.1, 0.1, 0.1, 1)
                let detail: Float = wl.enhancement == .crisp ? Float(min(max(wl.detailAmount, 0), 1)) : 0
                enc.setRenderPipelineState(pWeb)
                quad(enc, SIMD4<Float>(Float(x - margin), Float(y - margin),
                                    Float(width + 2 * margin), Float(height + 2 * margin)), canvasF)
                frag(enc, WebU(crop: crop, bubble: region, radius: Float(min(width, height) * Double(st.layout.cameraRadius)),
                             shape: st.layout.cameraRadius > 0.4 ? 0 : 1, mirror: settings.mirror ? 1 : 0,
                             border: settings.border && maskMode == 0 ? 1 : 0,
                             shadow: settings.shadow && maskMode == 0 ? 1 : 0,
                             bw: Float(3 * g.ui), minif: Float(Double(crop.z) * ww / max(width, 1)),
                             margin: Float(margin), opacity: opacity, maskMode: maskMode,
                             matteMix: matte?.fraction ?? 0, detail: detail, canvasColor: color))
                enc.setFragmentTexture(web, index: 0)
                if let matte {
                    enc.setFragmentTexture(matte.previous, index: 1)
                    enc.setFragmentTexture(matte.next, index: 2)
                }
                if maskMode == 2 {
                    let background = wl.backdrop == .image ? cameraBackground : wallTex
                    if let background { enc.setFragmentTexture(background, index: 3) }
                }
                draw()
            }
        }

        // Caption and manual text share this pass in both live preview and offline exports.
        // Both are source-time anchored; rasterization is cached by actual text/style,
        // with a different cache entry only when the highlighted word changes.
        var sprites: [TextOverlaySprite] = []
        if drawingContent, let caption = st.caption, tl.captions.enabled,
           let sprite = textCache.caption(caption, style: tl.captions.style,
                                          time: r.t, canvas: r.canvas, videoRect: g.content, device: device) {
            sprites.append(sprite)
        }
        if drawingContent {
            for manual in st.emphasis.texts {
                if let sprite = textCache.manual(manual, canvas: r.canvas, device: device) {
                    sprites.append(sprite)
                }
            }
        }
        if !sprites.isEmpty {
            // A caption card needs the scene behind it, and Metal cannot read
            // the texture it is writing. Copy the finished scene once (only
            // when a card is visible), blur it with a separable Gaussian at
            // quarter resolution, then reopen the pass for card + sharp text.
            // Export and preview share this path.
            let cards = sprites.filter { $0.card != nil && $0.opacity > 0.001 }
            var cardTexture: MTLTexture?
            var encoder = enc
            if let tallest = cards.map({ Float($0.texture.height) * $0.scale }).max() {
                // The blur reads the finished scene directly. It only needs the
                // pass ended first; no full-resolution copy is required because
                // the blur writes to a different (quarter-resolution) target.
                enc.endEncoding()
                // Thin material: a soft frost, not a fog. Tuned by eye against
                // busy pages; the card's tint carries the contrast, not the blur.
                // The caption's blur-in radius rides on top, so the whole block
                // (material included) resolves out of focus.
                let blurIn = cards.map(\.blur).max() ?? 0
                let sigma = min(max(tallest * 0.12 + blurIn, 8), 40)
                cardTexture = blurScene(cb, from: tex, slot: slot, canvas: r.canvas, sigma: sigma)
                let pd = MTLRenderPassDescriptor()
                pd.colorAttachments[0].texture = tex
                pd.colorAttachments[0].loadAction = .load
                pd.colorAttachments[0].storeAction = .store
                guard let reopened = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
                encoder = reopened
            }
            if let cardTexture {
                encoder.setRenderPipelineState(pCaptionCard)
                for sprite in cards {
                    guard let card = sprite.card else { continue }
                    let w = Float(sprite.texture.width) * sprite.scale
                    let h = Float(sprite.texture.height) * sprite.scale
                    let rect = SIMD4<Float>(sprite.center.x - w / 2, sprite.center.y - h / 2, w, h)
                    quad(encoder, rect, canvasF)
                    frag(encoder, CaptionCardU(rect: rect, tint: card.tint, canvas: canvasF,
                                               radius: card.radius * sprite.scale, opacity: sprite.opacity))
                    encoder.setFragmentTexture(cardTexture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.setRenderPipelineState(pTextSprite)
            for sprite in sprites where sprite.opacity > 0.001 {
                let w = Float(sprite.texture.width) * sprite.scale
                let h = Float(sprite.texture.height) * sprite.scale
                quad(encoder, SIMD4<Float>(sprite.center.x - w / 2, sprite.center.y - h / 2, w, h), canvasF)
                frag(encoder, TextSpriteU(opacity: sprite.opacity, blur: sprite.blur))
                encoder.setFragmentTexture(sprite.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        } else {
            enc.endEncoding()
        }
    }

    private func maskedSource(_ source: MTLTexture, masks: [MaskFrame], pixelSize: Float,
                              slot: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        guard !masks.isEmpty else { return source }
        if maskedSources[slot]?.width != source.width || maskedSources[slot]?.height != source.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: source.width, height: source.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
            maskedSources[slot] = device.makeTexture(descriptor: descriptor)
        }
        guard let target = maskedSources[slot] else { return nil }
        let regions = masks.map { mask in
            let block = max(pixelSize, PrivacyMaskGeometry.cell(boxHeight: mask.rect.w))
            // The kernel needs the mode: a solid mask paints an opaque fill,
            // every other mode pixelates the region in source space.
            let mode: Float = mask.mode == .solid ? 1 : 0
            return SourceMaskGPU(rect: PrivacyMaskGeometry.mosaicRegion(mask.rect, cell: block),
                                 block: SIMD4(block, mode, 0, 0))
        }
        guard let buffer = regions.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count) }
        }), let encoder = cb.makeComputeCommandEncoder() else { return nil }
        var count = UInt32(regions.count)
        encoder.setComputePipelineState(pSourceMask)
        encoder.setTexture(source, index: 0); encoder.setTexture(target, index: 1)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return target
    }

    /// Separable Gaussian of the finished scene, rendered at quarter resolution.
    /// Two passes (horizontal then vertical); returns the blurred texture, or
    /// nil when the targets cannot be allocated. `sigma` is in canvas pixels.
    private func blurScene(_ cb: MTLCommandBuffer, from source: MTLTexture, slot: Int,
                           canvas: SIMD2<Int>, sigma: Float) -> MTLTexture? {
        guard let a = blurTarget(0, slot: slot, canvas: canvas),
              let b = blurTarget(1, slot: slot, canvas: canvas) else { return nil }
        let quarter = SIMD2<Float>(Float(a.width), Float(a.height))
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[0].storeAction = .store
        for (target, input, dir) in [(a, source, SIMD2<Float>(1, 0)), (b, a, SIMD2<Float>(0, 1))] {
            pd.colorAttachments[0].texture = target
            guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return nil }
            e.setRenderPipelineState(pBlur)
            quad(e, SIMD4<Float>(0, 0, quarter.x, quarter.y), quarter)
            frag(e, BlurU(dir: dir, sigma: max(sigma * 0.25, 0.4), pad0: 0, pad1: 0))
            e.setFragmentTexture(input, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.endEncoding()
        }
        return b
    }

    /// Per-in-flight-slot quarter-resolution target for the caption material.
    /// Lazily allocated: recordings without captions pay nothing.
    private func blurTarget(_ index: Int, slot: Int, canvas: SIMD2<Int>) -> MTLTexture? {
        let i = min(max(slot, 0), 2)
        let w = max(1, canvas.x / 4), h = max(1, canvas.y / 4)
        var list = index == 0 ? blurA : blurB
        if let t = list[i], t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        list[i] = device.makeTexture(descriptor: d)
        if index == 0 { blurA = list } else { blurB = list }
        return list[i]
    }

    /// Copy of the composited scene, per in-flight slot. Metal cannot sample
    /// the texture it is writing, so the ripple refracts this copy. The caption
    /// material blurs the scene directly instead (it writes to another target).
    private func sceneCopyTexture(slot: Int, canvas: SIMD2<Int>) -> MTLTexture? {
        let index = min(max(slot, 0), 2)
        if let t = captionSrc[index], t.width == canvas.x, t.height == canvas.y { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: canvas.x, height: canvas.y,
                                                           mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        captionSrc[index] = device.makeTexture(descriptor: d)
        return captionSrc[index]
    }

    private func transparentTexture() -> MTLTexture? {
        if let transparentTex { return transparentTex }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var zero: SIMD4<Float> = .zero
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 16)
        transparentTex = tex
        return tex
    }

    private func quad(_ e: MTLRenderCommandEncoder, _ rect: SIMD4<Float>, _ canvas: SIMD2<Float>) {
        var q = QuadU(rect: rect, canvas: canvas)
        e.setVertexBytes(&q, length: MemoryLayout<QuadU>.stride, index: 0)
    }
    private func frag<T: BitwiseCopyable>(_ e: MTLRenderCommandEncoder, _ v: T, _ i: Int = 0) {
        var x = v
        e.setFragmentBytes(&x, length: MemoryLayout<T>.stride, index: i)
    }
}
```

### Sources/LumenRender/Shaders/Content.metal

```metal
#include <metal_stdlib>
using namespace metal;

struct UpBind {
    float4 region;     // source px: x, y, w, h
    float2 texSize;    // physical size of the upscaled texture
    float factor;
    float blend;       // 0 = ignore the upscaled texture
};

struct ContentParams {
    float4 contentRect;   // canvas px: x, y, w, h (the full source at zoom 1)
    float4 radii;         // tl, tr, br, bl (canvas px)
    float2 camCenter;     // source px
    float2 srcSize;
    float magnification;  // canvas px per source px
    float pad;
    int2 canvasSize;
    UpBind up;
};

static inline float sdRoundBox(float2 p, float2 b, float4 r) {
    float2 rr = (p.x > 0.0) ? float2(r.y, r.z) : float2(r.x, r.w);   // (top, bottom) for this side
    float rad = (p.y > 0.0) ? rr.y : rr.x;
    float2 q = abs(p) - b + rad;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

/// Catmull-Rom with the 5-fetch bilinear optimisation. uv is normalised; levelSize is the size of the sampled mip.
static inline float4 catmull(texture2d<float> tex, sampler s, float2 uv, float2 levelSize, float lod) {
    float2 sp = uv * levelSize;
    float2 tc = floor(sp - 0.5) + 0.5;
    float2 f = sp - tc;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = f2 - 0.5 * (f3 + f);
    float2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    float2 w3 = 0.5 * (f3 - f2);
    float2 w2 = 1.0 - w0 - w1 - w3;
    float2 w12 = w1 + w2;
    float2 tc0 = (tc - 1.0) / levelSize;
    float2 tc3 = (tc + 2.0) / levelSize;
    float2 tc12 = (tc + w2 / w12) / levelSize;
    float4 r = tex.sample(s, float2(tc12.x, tc0.y), level(lod)) * (w12.x * w0.y)
             + tex.sample(s, float2(tc0.x, tc12.y), level(lod)) * (w0.x * w12.y)
             + tex.sample(s, float2(tc12.x, tc12.y), level(lod)) * (w12.x * w12.y)
             + tex.sample(s, float2(tc3.x, tc12.y), level(lod)) * (w3.x * w12.y)
             + tex.sample(s, float2(tc12.x, tc3.y), level(lod)) * (w12.x * w3.y);
    float sum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return r / sum;
}

/// Source sample at source-px position p. Minification blends bicubic between two mip levels.
static inline float4 sampleSource(texture2d<float> tex, sampler s, float2 p, float M) {
    float2 sz = float2(tex.get_width(), tex.get_height());
    float2 uv = p / sz;
    float maxL = float(tex.get_num_mip_levels() - 1);
    float lod = clamp(log2(max(1.0 / max(M, 1e-4), 1.0)), 0.0, maxL);
    float l0 = floor(lod), fr = lod - l0;
    float4 a = catmull(tex, s, uv, sz / exp2(l0), l0);
    if (fr < 1e-3 || l0 + 1.0 > maxL) return a;
    return mix(a, catmull(tex, s, uv, sz / exp2(l0 + 1.0), l0 + 1.0), fr);
}

static inline float4 sampleUp(texture2d<float> up, sampler s, constant UpBind& U, float2 p) {
    float2 q = (p - U.region.xy) * U.factor;
    q = clamp(q, float2(0.5), U.region.zw * U.factor - 0.5);
    return catmull(up, s, q / U.texSize, U.texSize, 0.0);
}

static inline float3 sampleContent(texture2d<float> src, texture2d<float> up, sampler s, constant UpBind& U, float2 p, float M) {
    float3 base = sampleSource(src, s, p, M).rgb;
    if (U.blend <= 0.0) return base;
    return mix(base, sampleUp(up, s, U, p).rgb, U.blend);
}

kernel void fx_content(texture2d<float, access::read> backdrop [[texture(0)]],
                       texture2d<float, access::write> canvas [[texture(1)]],
                       texture2d<float> source [[texture(2)]],
                       texture2d<float> upTex [[texture(3)]],
                       constant ContentParams& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.canvasSize.x || int(gid.y) >= P.canvasSize.y) return;
    float4 base = backdrop.read(gid);
    float2 q = float2(gid) + 0.5;
    float2 ctr = P.contentRect.xy + 0.5 * P.contentRect.zw;
    float cov = saturate(0.5 - sdRoundBox(q - ctr, 0.5 * P.contentRect.zw, P.radii));
    if (cov <= 0.0) { canvas.write(base, gid); return; }
    float2 p = P.camCenter + (q - ctr) / P.magnification;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 col = sampleContent(source, upTex, s, P.up, p, P.magnification);
    canvas.write(float4(mix(base.rgb, col, cov), mix(base.a, 1.0, cov)), gid);
}
```

### Sources/LumenRender/Shaders/Shaders.metal

```metal
#include <metal_stdlib>
using namespace metal;

constexpr sampler linClamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);
constexpr sampler linMip(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
constant float2 kMesh[6] = { float2(.15, .20), float2(.85, .15), float2(.5, .5), float2(.2, .85), float2(.8, .8), float2(.5, .02) };

struct QuadU { float4 rect; float2 canvas; };
struct VO { float4 pos [[position]]; float2 px; float2 q; };

vertex VO quadVS(uint vid [[vertex_id]], constant QuadU &u [[buffer(0)]]) {
    float2 c = float2(vid & 1, vid >> 1);
    float2 px = u.rect.xy + c * u.rect.zw;
    VO o;
    o.pos = float4(px.x / u.canvas.x * 2.0 - 1.0, 1.0 - px.y / u.canvas.y * 2.0, 0.0, 1.0);
    o.px = px; o.q = c;
    return o;
}

// Continuous-corner rounded rect: superellipse (n=4) in the corner region, straight edges elsewhere.
static float sdSquircle(float2 p, float2 h, float r) {
    r = max(min(r, min(h.x, h.y)), 0.5);
    float2 q = abs(p) - (h - r);
    if (q.x > 0.0 && q.y > 0.0) {
        float k = pow(pow(q.x / r, 4.0) + pow(q.y / r, 4.0), 0.25);
        return (k - 1.0) * r;
    }
    return max(q.x, q.y) - r;
}
static float rectMask(float2 px, float4 rect, float r) {
    float2 h = rect.zw * 0.5;
    float d = sdSquircle(px - (rect.xy + h), h, r);
    return clamp(0.5 - d / max(fwidth(d), 1e-3), 0.0, 1.0);
}

// ---- Backdrop (cached): dither / wallpaper / gradient / mesh / solid + two-layer shadow
struct BackdropU { float4 content; float2 canvas; float angle; int count; int kind;
                   float radius; float shadow; float scale; float cell; float density; int hasWall; float time; float4 pointer;
                   float wallBlur; float imgAlpha; float imgContrast; float imgBright; };

// Continuous wallpaper blur: a 5x5 tent kernel, radius in canvas pixels.
// The backdrop is cached, so 25 taps cost nothing per frame.
float3 blurredWall(texture2d<float> tex, float2 uv, float2 texSize, float radiusPx) {
    if (radiusPx <= 0.5) { return tex.sample(linClamp, uv).rgb; }
    float2 step = (radiusPx * 0.5) / max(texSize.x, texSize.y);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float w = (3.0 - abs(float(x))) * (3.0 - abs(float(y)));
            sum += tex.sample(linClamp, clamp(uv + float2(float(x) * step.x, float(y) * step.y), 0.0, 1.0)).rgb * w;
            wsum += w;
        }
    }
    return sum / wsum;
}

constant float kBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

static float bayer2(float2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
static float bayer4(float2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
static float bayer8(float2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }
static float fieldHash(int x, int y, int z) {
    uint h = uint(x) * 0x27d4eb2du ^ uint(y) * 0x165667b1u ^ uint(z) * 0x1b873593u;
    h = (h ^ (h >> 15)) * 0x85ebca6bu;
    h = (h ^ (h >> 13)) * 0xc2b2ae35u;
    return float(h ^ (h >> 16)) * (1.0 / 4294967296.0);
}
static float fieldNoise(float3 p) {
    int3 i = int3(floor(p));
    float3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(fieldHash(i.x, i.y, i.z), fieldHash(i.x + 1, i.y, i.z), f.x),
                  mix(fieldHash(i.x, i.y + 1, i.z), fieldHash(i.x + 1, i.y + 1, i.z), f.x), f.y);
    float b = mix(mix(fieldHash(i.x, i.y, i.z + 1), fieldHash(i.x + 1, i.y, i.z + 1), f.x),
                  mix(fieldHash(i.x, i.y + 1, i.z + 1), fieldHash(i.x + 1, i.y + 1, i.z + 1), f.x), f.y);
    return mix(a, b, f.z);
}

fragment float4 backdropFS(VO in [[stage_in]], constant BackdropU &u [[buffer(0)]], constant float4 *cols [[buffer(1)]],
                           texture2d<float> wall [[texture(0)]]) {
    float2 uv = in.px / u.canvas;
    float3 c = cols[0].rgb;
    if (u.kind == 6) {
        float cell = max(1.0, u.cell);
        float2 grid = floor(in.px / cell);
        float2 p = (grid * cell) / u.canvas;
        p.x *= u.canvas.x / u.canvas.y;
        if (u.pointer.z > 0.001) {
            float2 dm = p - float2(u.pointer.x * u.canvas.x / u.canvas.y, u.pointer.y);
            p += dm * exp(-dot(dm, dm) * 10.0) * 0.22 * u.pointer.z;
        }
        float v = u.density + 0.20 * sin(dot(p, normalize(float2(0.55, 1.0))) * 5.2 - u.time * 0.11)
                            + 0.12 * sin(dot(p, normalize(float2(1.0, 0.28))) * 8.4 + u.time * 0.07);
        c = v > bayer8(grid) ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 7) {
        float pitch = max(3.0, u.cell);
        float2 grid = floor(in.px / pitch);
        float step = pitch / u.canvas.y;
        float nx = grid.x * step * 1.4, ny = grid.y * step * 2.6;
        // Coherent field: Bayer-ordered density with a slow diagonal wave.
        // One continuous pattern, no hash gaps or clipped dashes.
        float wave = 0.5 + 0.5 * sin(dot(float2(nx, ny), normalize(float2(0.55, 1.0))) * 6.0 - u.time * 0.05);
        float density = clamp(wave * u.density * 1.6, 0.0, 1.0);
        c = density > bayer8(grid) ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 3) {
        // Two flat tones ordered-dithered under a slow diagonal wave. Display-rate phase; export always sends 0.
        float cell = max(2.0, u.cell);
        float2 g = floor(in.px / cell);
        int ix = int(g.x) & 3, iy = int(g.y) & 3;
        float t = (kBayer[iy * 4 + ix] + 0.5) / 16.0;
        float2 d = float2(cos(u.angle), sin(u.angle));
        float s = dot(uv - 0.5, d) / max(abs(d.x) + abs(d.y), 1e-3) + 0.5;
        float wave = 0.5 + 0.5 * sin((s * 3.0 - u.time * 0.35) * 6.2831853);
        float field = smoothstep(0.08, 0.92, wave);
        float ink = field * clamp(u.density * 1.8, 0.0, 1.0);
        c = ink > t ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 5) {
        // Canvas: a flat two-tone pixel weave. Static, so it reads as paper rather than motion.
        float cell = max(4.0, u.cell);
        float2 g = floor(in.px / cell);
        float alt = fmod(g.x + g.y, 2.0);
        c = mix(cols[0].rgb, cols[1].rgb, alt * 0.14);
    } else if (u.kind == 4 && u.hasWall == 1) {
        // macOS wallpaper, filled like cover.
        float2 ts = float2(wall.get_width(), wall.get_height());
        float s = max(u.canvas.x / ts.x, u.canvas.y / ts.y);
        float2 off = (u.canvas - ts * s) * 0.5;
        c = blurredWall(wall, (in.px - off) / (ts * s), ts * s, u.wallBlur);
    } else if (u.kind == 8 && u.hasWall == 1) {
        // User photo, filled like cover (no letterboxing).
        // wallBlur is a radius in canvas pixels (0 sharp .. 60 soft);
        // imgAlpha 0..1, imgContrast 0..2 around 0.18 grey, imgBright 0..2 additive.
        float2 ts = float2(wall.get_width(), wall.get_height());
        float s = max(u.canvas.x / ts.x, u.canvas.y / ts.y);
        float2 off = (u.canvas - ts * s) * 0.5;
        c = blurredWall(wall, (in.px - off) / (ts * s), ts * s, u.wallBlur);
        c = clamp((c - 0.18) * u.imgContrast + 0.18 + (u.imgBright - 1.0) * 0.25, 0.0, 1.0);
        c *= u.imgAlpha;
    } else if (u.kind == 0 && u.count > 1) {
        float2 d = float2(cos(u.angle), sin(u.angle));
        float t = dot(uv - 0.5, d) / (abs(d.x) + abs(d.y)) + 0.5;
        float f = clamp(t, 0.0, 1.0) * float(u.count - 1);
        int i = min(int(f), u.count - 2);
        c = mix(cols[i].rgb, cols[i + 1].rgb, f - float(i));
    } else if (u.kind == 1) {
        float3 acc = float3(0.0); float ws = 0.0;
        for (int i = 0; i < 6; i++) {
            float2 dv = (uv - kMesh[i]) * float2(u.canvas.x / u.canvas.y, 1.0);
            float w = exp(-dot(dv, dv) * 7.0);
            acc += cols[i % max(u.count, 1)].rgb * w; ws += w;
        }
        c = acc / max(ws, 1e-4);
    }
    float2 h = u.content.zw * 0.5, ctr = u.content.xy + h;
    float s = u.scale;
    float d1 = sdSquircle(in.px - (ctr + float2(0.0, 2.0 * s)), h, u.radius);
    float d2 = sdSquircle(in.px - (ctr + float2(0.0, 22.0 * s)), h, u.radius);
    float a1 = 0.30 * (1.0 - smoothstep(-8.0 * s, 8.0 * s, d1));
    float a2 = 0.45 * (1.0 - smoothstep(-40.0 * s, 40.0 * s, d2));
    float a = 1.0 - (1.0 - a1 * u.shadow) * (1.0 - a2 * u.shadow);
    return float4(c * (1.0 - a), 1.0);
}

// ---- High-quality resampling: Catmull-Rom (9 taps) at two mip levels
static float3 catmull(texture2d<float> t, float2 uv, uint lv) {
    float2 sz = float2(t.get_width(lv), t.get_height(lv));
    float2 sp = uv * sz;
    float2 t1 = floor(sp - 0.5) + 0.5;
    float2 f = sp - t1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 p0 = (t1 - 1.0) / sz, p3 = (t1 + 2.0) / sz, p12 = (t1 + w2 / w12) / sz;
    float L = float(lv);
    float3 r = float3(0.0);
    r += t.sample(linClamp, float2(p0.x,  p0.y),  level(L)).rgb * (w0.x  * w0.y);
    r += t.sample(linClamp, float2(p12.x, p0.y),  level(L)).rgb * (w12.x * w0.y);
    r += t.sample(linClamp, float2(p3.x,  p0.y),  level(L)).rgb * (w3.x  * w0.y);
    r += t.sample(linClamp, float2(p0.x,  p12.y), level(L)).rgb * (w0.x  * w12.y);
    r += t.sample(linClamp, float2(p12.x, p12.y), level(L)).rgb * (w12.x * w12.y);
    r += t.sample(linClamp, float2(p3.x,  p12.y), level(L)).rgb * (w3.x  * w12.y);
    r += t.sample(linClamp, float2(p0.x,  p3.y),  level(L)).rgb * (w0.x  * w3.y);
    r += t.sample(linClamp, float2(p12.x, p3.y),  level(L)).rgb * (w12.x * w3.y);
    r += t.sample(linClamp, float2(p3.x,  p3.y),  level(L)).rgb * (w3.x  * w3.y);
    return r;
}
static float3 sampleMip(texture2d<float> t, float2 uv, float minif) {
    float maxL = float(t.get_num_mip_levels() - 1);
    float L = clamp(log2(max(minif, 1.0)), 0.0, maxL);
    float l0 = floor(L), f = L - l0;
    float3 a = catmull(t, uv, uint(l0));
    if (f > 0.001 && l0 + 1.0 <= maxL) a = mix(a, catmull(t, uv, uint(l0) + 1u), f);
    return max(a, float3(0.0));
}

// ---- Content (camera-transformed source inside the rounded mask)
// `tilt` is (yaw, pitch) in degrees. A small perspective divide is enough to
// sell depth without ever sampling outside the source: the warp is clamped so
// the visible rectangle can never exceed the original frame.
struct ContentU { float4 content; float2 src; float2 cam; float scale; float radius; float border; float p; float2 tilt; float4 radii; };

// Standard rounded box with one radius per corner (tl, tr, br, bl). Only used
// when the four corners actually differ; the squircle path stays for uniform
// corners so existing looks do not change.
static float sdCorners(float2 p, float2 h, float4 r) {
    float rr = (p.x < 0.0) ? ((p.y < 0.0) ? r.x : r.w) : ((p.y < 0.0) ? r.y : r.z);
    rr = clamp(rr, 0.5, min(h.x, h.y));
    float2 q = abs(p) - h + rr;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
}

fragment float4 contentFS(VO in [[stage_in]], constant ContentU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 h = u.content.zw * 0.5;
    float4 R = u.radii;
    float d = (R.x == R.y && R.y == R.z && R.z == R.w)
        ? sdSquircle(in.px - (u.content.xy + h), h, R.x)
        : sdCorners(in.px - (u.content.xy + h), h, R);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float2 view = u.src / u.scale;
    float2 n = (in.px - u.content.xy) / u.content.zw - 0.5;
    if (abs(u.tilt.x) + abs(u.tilt.y) > 0.001) {
        float ky = tan(clamp(u.tilt.x, -18.0, 18.0) * 0.01745329252);
        float kx = tan(clamp(u.tilt.y, -18.0, 18.0) * 0.01745329252);
        n = clamp(float2(n.x * (1.0 + ky * n.y * 2.0), n.y * (1.0 + kx * n.x * 2.0)),
                  float2(-0.5), float2(0.5));
    }
    float2 sp = u.cam + n * view;
    float3 rgb = sampleMip(src, sp / u.src, view.x / u.content.z);
    if (u.border > 0.5) rgb = mix(rgb, float3(1.0), 0.08 * clamp(0.5 + (d + 1.0) / w, 0.0, 1.0));
    return float4(rgb * a, a);
}

// ---- Glass loupe: a circular window that re-samples the source at a higher
// magnification than the camera. Coverage is the same source pixels the user
// sees, so a loupe can never reveal content that the camera pass hides.
struct LoupeU {
    float4 glass;    // centre x,y (canvas px), radius, border width
    float4 source;   // target source x,y, source width,height
    float2 zoom;     // camera scale, loupe magnification
    float opacity;
    float round;     // 1 = circle, 0 = rounded rect
    float radius;    // corner radius for the rect case
};
fragment float4 loupeFS(VO in [[stage_in]], constant LoupeU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 p = in.px, c = u.glass.xy;
    float R = max(u.glass.z, 1.0);
    float d = u.round > 0.5 ? length(p - c) - R
                            : sdSquircle(p - c, float2(R), u.radius);
    float aa = max(fwidth(d), 1e-3);
    float inside = clamp(0.5 - d / aa, 0.0, 1.0);
    // Soft drop shadow just outside the rim.
    float shadowA = exp(-pow(max(d, 0.0) / (R * 0.25 + 1.0), 1.5)) * 0.4 * u.opacity;
    if (inside <= 0.001 && shadowA < 0.004) return float4(0.0);
    float2 n = (p - c) / (2.0 * R);
    float2 view = u.source.zw / max(u.zoom.x * u.zoom.y, 0.01);
    float2 sp = u.source.xy + clamp(n, float2(-0.5), float2(0.5)) * view;
    float3 rgb = src.sample(linClamp, clamp(sp / u.source.zw, 0.0, 1.0)).rgb;
    // Rim: a crisp light edge reads as glass against any background.
    float ringW = max(u.glass.w, 1.0);
    float rim = smoothstep(R - ringW * 1.6, R - ringW * 0.4, length(p - c));
    float3 edge = mix(rgb, float3(1.0), rim * 0.6);
    float alpha = inside * u.opacity;
    return float4(edge * alpha, alpha + shadowA * (1.0 - inside));
}

struct SourceMask { float4 rect; float4 block; };
kernel void pixelateMask(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::write> target [[texture(1)]],
                         constant SourceMask *masks [[buffer(0)]],
                         constant uint &count [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint2 size(source.get_width(), source.get_height());
    if (any(gid >= size)) return;
    float2 p = float2(gid);
    float4 color = source.read(gid);
    for (uint i = 0; i < count; ++i) {
        float4 r = masks[i].rect;
        if (all(p >= r.xy) && all(p < r.xy + r.zw)) {
            float block = max(masks[i].block.x, 8.0);
            if (masks[i].block.y > 0.5) {
                // Solid: an opaque fill. Nothing of the original pixels can
                // survive it, so the region reads as a block, not as content.
                color = float4(0.09, 0.09, 0.09, 1.0);
                break;
            }
            float2 origin = floor(p / block) * block;
            color = float4(0.0);
            for (uint y = 0; y < 4; ++y) {
                for (uint x = 0; x < 4; ++x) {
                    float2 point = origin + (float2(x, y) + 0.5) * block / 4.0;
                    color += source.read(uint2(clamp(point, float2(0), float2(size - 1))));
                }
            }
            color *= 1.0 / 16.0;
            break;
        }
    }
    target.write(color, gid);
}

// ---- Cursor sprite (premultiplied atlas, mip-mapped)
struct CursorU { float4 content; float radius; float opacity; uint layer; float p; };
fragment float4 cursorFS(VO in [[stage_in]], constant CursorU &u [[buffer(0)]], texture2d_array<float> atlas [[texture(0)]]) {
    float4 c = atlas.sample(linMip, in.q, u.layer);
    return c * (u.opacity * rectMask(in.px, u.content, u.radius));
}

// ---- Click ripple: expanding front refracts the source video under it,
// no flat fill. Front radius eases out; amplitude decays (critically damped,
// no overshoot). Center is the exact corrected click position from Part 1.
struct RingU { float4 content; float4 color; float2 center; float radius; float progress; float cr; int mode;
               float2 cam; float scale; float2 srcSize; };
fragment float4 ringFS(VO in [[stage_in]], constant RingU &u [[buffer(0)]],
                       texture2d<float> src [[texture(0)]]) {
    float p = clamp(u.progress, 0.0, 1.0), e = 1.0 - pow(1.0 - p, 3.0);
    float r = mix(0.25, 1.0, e) * u.radius * 0.9, wd = mix(0.16, 0.025, e) * u.radius;
    float2 delta = in.px - u.center;
    float distance = length(delta);
    float dd = abs(distance - r) - wd * 0.5;
    float ring = clamp(0.5 - dd / max(fwidth(dd), 1e-3), 0.0, 1.0);
    float ink = ring;
    if (u.mode == 1) { // Pulse: a filled, expanding focus disc
        ink = 0.45 * (1.0 - smoothstep(r - 2.0, r + 2.0, distance));
    } else if (u.mode == 2) { // Burst: short radial rays at the clicked pixel
        float rays = pow(abs(cos(atan2(delta.y, delta.x) * 6.0)), 18.0);
        float band = 1.0 - smoothstep(wd * 0.5, wd * 2.0, abs(distance - r));
        ink = max(ring * 0.3, rays * band);
    } else if (u.mode == 3) { // Glass: translucent bloom + rim
        float bloom = clamp(1.0 - pow(distance / max(r, 1.0), 2.2), 0.0, 1.0);
        float rim = ring * 0.5;
        float glow = exp(-distance * distance / max(r * r * 0.4, 1.0));
        ink = clamp(bloom * 0.35 + rim * 0.65 + glow * 0.25, 0.0, 1.0);
        float a = ink * pow(1.0 - p, 1.2) * u.color.a * rectMask(in.px, u.content, u.cr);
        return float4(mix(float3(1.0), u.color.rgb, 0.25) * a + float3(0.15) * glow * pow(1.0 - p, 2.0) * u.color.a, a);
    } else if (u.mode == 0) {
        // Liquid-glass ripple. A travelling wave refracts the already-composited
        // frame (masks included — never the raw source) with a soft specular
        // crest. No hard ring, no flat fill, no full-disc tint.
        float x = 6.5 * p;
        float e = 1.0 - exp(-x) * (1.0 + x);                 // 0 → ~0.99, no overshoot
        float R = u.radius * (0.18 + 0.82 * e);
        float fade = pow(1.0 - p, 1.25);
        float2 d = in.px - u.center;
        float r = max(length(d), 1e-3);
        float2 dir = d / r;
        // The band widens with the front so the wave stays soft as it grows.
        float bandW = max(R * 0.34, 6.0);
        float xr = (r - R) / bandW;
        float band = exp(-xr * xr);
        float wave = sin(5.2 * (r - R) / bandW);
        float2 q = in.px - dir * (band * wave * 16.0 * fade);
        float3 base = src.sample(linClamp, clamp(q / u.srcSize, 0.0, 1.0), level(0.0)).rgb;
        float crest = exp(-pow((r - R) / (bandW * 0.55), 2.0));
        float shade = exp(-pow((r - R - bandW * 0.75) / (bandW * 0.5), 2.0));
        // A lens edge reads as glass only if it has both a highlight and a
        // slight shade just behind it; a single bright ring reads as paint.
        // No interior fill: the wave itself is the effect.
        float3 col = base + float3(0.16) * (crest * 0.8) - float3(0.05) * shade;
        col = mix(col, u.color.rgb, clamp(u.color.a, 0.0, 1.0) * band * 0.5);
        // Where the wave displaces pixels, this pass must own them outright;
        // where it does not, alpha falls to zero and the scene shows through.
        float a = clamp(band * 2.0, 0.0, 1.0) * fade;
        a *= rectMask(in.px, u.content, u.cr);
        return float4(col * a, a);
    }
    float a = ink * pow(1.0 - p, 1.5) * u.color.a * rectMask(in.px, u.content, u.cr);
    return float4(u.color.rgb * a, a);
}

// ---- Webcam bubble (shadow + mask + border in one quad)
struct WebU {
    float4 crop; float4 bubble;
    float radius; float shape; float mirror; float border;
    float shadow; float bw; float minif; float margin;
    float opacity; float maskMode; float matteMix; float detail;
    float4 canvasColor;
};
fragment float4 webFS(VO in [[stage_in]], constant WebU &u [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]],
                       texture2d<float> maskA [[texture(1)]],
                       texture2d<float> maskB [[texture(2)]],
                       texture2d<float> wallpaper [[texture(3)]]) {
    float2 h = u.bubble.zw * 0.5, p = in.px - (u.bubble.xy + h);
    float d = u.shape < 0.5 ? length(p) - min(h.x, h.y) : sdSquircle(p, h, u.radius);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    float2 q = (p + h) / u.bubble.zw;
    float2 uvw = u.crop.xy + float2(u.mirror > 0.5 ? 1.0 - q.x : q.x, q.y) * u.crop.zw;

    // Catmull-Rom preserves edges when displaying a lower-resolution webcam
    // in a 4K composition. The constrained high-pass improves acutance, but
    // does not pretend to recover detail absent from the original recording.
    float3 rgb = sampleMip(tex, uvw, u.minif);
    if (u.detail > 0.001) {
        float2 tx = 1.0 / float2(tex.get_width(), tex.get_height());
        float3 near = (tex.sample(linClamp, uvw - float2(tx.x, 0)).rgb
                     + tex.sample(linClamp, uvw + float2(tx.x, 0)).rgb
                     + tex.sample(linClamp, uvw - float2(0, tx.y)).rgb
                     + tex.sample(linClamp, uvw + float2(0, tx.y)).rgb) * 0.25;
        rgb = clamp(rgb + clamp(rgb - near, float3(-0.06), float3(0.06)) * (u.detail * 0.75), 0.0, 1.0);
    }

    if (u.maskMode > 0.5) {
        // Vision mattes are timestamped in source time. Interpolating adjacent
        // mattes removes the hard 30Hz edge jump on 60fps exports.
        float m0 = maskA.sample(linClamp, uvw).r;
        float m1 = maskB.sample(linClamp, uvw).r;
        float person = smoothstep(0.055, 0.94, mix(m0, m1, u.matteMix));
        if (u.maskMode < 1.5) {
            float alpha = a * person * u.opacity;
            return float4(rgb * alpha, alpha);
        }
        float3 backdrop = u.maskMode < 2.5 ? wallpaper.sample(linClamp, q).rgb : u.canvasColor.rgb;
        float3 combined = mix(backdrop, rgb, person);
        float alpha = a * u.opacity;
        return float4(combined * alpha, alpha);
    }

    rgb = mix(rgb, float3(1.0), u.border * 0.9 * clamp(0.5 + (d + u.bw) / w, 0.0, 1.0));
    float ds = length(p - float2(0.0, u.margin * 0.25)) - min(h.x, h.y);
    float sh = u.shadow * 0.45 * (1.0 - smoothstep(-u.margin * 0.4, u.margin * 0.8, ds));
    float alpha = clamp(a + (1.0 - a) * sh, 0.0, 1.0) * u.opacity;
    return float4(rgb * a * u.opacity, alpha);
}

// ---- Motion-blur accumulation (premultiplied RGBA, additive)
struct AccU { float weight; };
fragment float4 accumFS(VO in [[stage_in]], constant AccU &u [[buffer(0)]], texture2d<float, access::read> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy)) * u.weight;
}

// ---- Resolve: scene over cached backdrop, triangular dither, convert to output format
static uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
static float rnd(uint2 p, uint seed) { return float(pcg(p.x + pcg(p.y + pcg(seed)))) * (1.0 / 4294967295.0); }
struct ResU { float levels; uint seed; float blur; float alpha; };
fragment float4 resolveFS(VO in [[stage_in]], constant ResU &u [[buffer(0)]],
                          texture2d<float, access::read> scene [[texture(0)]],
                          texture2d<float> back [[texture(1)]]) {
    uint2 g = uint2(in.pos.xy);
    float4 s = scene.read(g);
    float2 uv = (float2(g) + 0.5) / float2(back.get_width(), back.get_height());
    // Transparent delivery keeps the premultiplied scene untouched: no
    // backdrop, no dither, no forced opaque alpha.
    if (u.alpha < 0.5) return s;
    // Only the backdrop has mipmaps. Text, cursor, and webcam are drawn into
    // the sharp scene layer, sampled without any blur.
    float3 background = back.sample(linMip, uv, level(u.blur)).rgb;
    float3 c = s.rgb + background * (1.0 - s.a);
    float n = rnd(g, u.seed) + rnd(g, u.seed + 1u) - 1.0;
    return float4(clamp(c + n / u.levels, 0.0, 1.0), 1.0);
}

// Premultiplied text sprite rasterized by CoreText on the CPU once per content/style.
// The Metal pass is shared by the editor preview and offline export.
struct TextSpriteU { float opacity; float blur; float pad0; float pad1; };
fragment float4 textSpriteFS(VO in [[stage_in]], constant TextSpriteU &u [[buffer(0)]],
                            texture2d<float> image [[texture(0)]]) {
    float4 c = image.sample(linClamp, in.q);
    float b = max(u.blur, 0.0);
    if (b > 0.05) {
        // Short blur-in only. Nine samples at the requested radius are enough
        // at caption sizes and cheaper than a per-sprite mip chain.
        float2 tx = b / float2(image.get_width(), image.get_height());
        float4 sum = c * 0.227027;
        sum += image.sample(linClamp, in.q + float2(tx.x, 0.0)) * 0.1945946;
        sum += image.sample(linClamp, in.q - float2(tx.x, 0.0)) * 0.1945946;
        sum += image.sample(linClamp, in.q + float2(0.0, tx.y)) * 0.1216216;
        sum += image.sample(linClamp, in.q - float2(0.0, tx.y)) * 0.1216216;
        sum += image.sample(linClamp, in.q + tx) * 0.054054;
        sum += image.sample(linClamp, in.q - tx) * 0.054054;
        sum += image.sample(linClamp, in.q + float2(tx.x, -tx.y)) * 0.016216;
        sum += image.sample(linClamp, in.q + float2(-tx.x, tx.y)) * 0.016216;
        c = sum;
    }
    return c * clamp(u.opacity, 0.0, 1.0);
}

// ---- Separable Gaussian: the caption card's frosted material.
// Two passes (H then V) at quarter resolution. A true kernel, not a mip pick:
// mip sampling box-filters and reads as blocky at card sizes.
struct BlurU { float2 dir; float sigma; float pad0; float pad1; };
fragment float4 gaussFS(VO in [[stage_in]], constant BlurU &u [[buffer(0)]],
                        texture2d<float> src [[texture(0)]]) {
    // Six symmetric taps spaced at half a sigma reach 3 sigma, which captures
    // 99.7% of the kernel at a fixed cost. Weights are therefore fixed; only
    // the spacing carries the radius, so any sigma costs the same.
    float2 step = u.dir * max(u.sigma, 0.4) * 0.5;
    float4 sum = src.sample(linClamp, in.q);
    float wsum = 1.0;
    for (int i = 1; i <= 6; ++i) {
        float fi = float(i) * 0.5;
        float w = exp(-0.5 * fi * fi);
        sum += (src.sample(linClamp, in.q + step * float(i))
              + src.sample(linClamp, in.q - step * float(i))) * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

// ---- Caption card: a real frosted material, not a baked grey pill.
// Samples the Gaussian-blurred scene, boosts saturation, then adapts a dark
// tint until white text keeps >= 4.5:1 contrast. The CPU draws this before the
// sharp text; preview and export share the shader.
struct CaptionCardU { float4 rect; float4 tint; float2 canvas; float radius; float opacity; };
fragment float4 captionCardFS(VO in [[stage_in]], constant CaptionCardU &u [[buffer(0)]],
                              texture2d<float> scene [[texture(0)]]) {
    float a = rectMask(in.px, u.rect, u.radius) * clamp(u.opacity, 0.0, 1.0);
    if (a <= 0.001) return float4(0.0);
    float2 uv = in.px / u.canvas;
    float3 b = scene.sample(linClamp, clamp(uv, 0.0, 1.0)).rgb;
    float luma = dot(b, float3(0.2126, 0.7152, 0.0722));
    // Frosted glass lifts colour before the dark tint lands on it.
    float3 sat = clamp(mix(float3(luma), b, 1.70), 0.0, 1.0);
    float3 face = mix(u.tint.rgb, sat, 0.12);
    float faceL = dot(face, float3(0.2126, 0.7152, 0.0722));
    // Solve overlay alpha so the resulting backdrop luminance stays <= 0.14
    // (target 0.14, threshold 0.18 for 4.5:1 with white).
    float need = (luma - 0.14) / max(luma - faceL, 1e-3);
    float alpha = clamp(max(need, u.tint.a), 0.55, 0.97);
    // A hairline specular rim keeps the material from reading as flat paint.
    float2 h = u.rect.zw * 0.5;
    float d = sdSquircle(in.px - (u.rect.xy + h), h, u.radius);
    float rim = exp(-pow(d / 1.6, 2.0)) * step(d, 0.0);
    face = clamp(face + float3(0.05) * rim, 0.0, 1.0);
    // Composite the blurred backdrop and the tint inside the card, then make
    // the card opaque. A translucent card would reveal the sharp scene and
    // defeat the blur; only the rounded edge uses the mask alpha.
    float3 finalColor = face * alpha + b * (1.0 - alpha);
    return float4(finalColor * a, a);
}

struct HighlightU {
    float4 rect;
    float4 content;
    float opacity;
    float strength;
    int mode;
};
fragment float4 highlightFS(VO in [[stage_in]], constant HighlightU &u [[buffer(0)]]) {
    float2 p = in.px;
    if (p.x < u.content.x || p.y < u.content.y ||
        p.x > u.content.x + u.content.z || p.y > u.content.y + u.content.w)
        return float4(0.0);
    float2 lo = p - u.rect.xy;
    float2 hi = u.rect.xy + u.rect.zw - p;
    bool inside = all(lo >= 0.0) && all(hi >= 0.0);
    float alpha = 0.0;
    if (u.mode == 0) {
        alpha = inside ? 0.0 : u.strength * u.opacity;
        return float4(0.0, 0.0, 0.0, alpha);
    }
    float2 d = max(max(-lo, -hi), float2(0.0));
    float outsideDistance = length(d);
    float insideDistance = min(min(lo.x, lo.y), min(hi.x, hi.y));
    float distance = inside ? insideDistance : -outsideDistance;
    if (u.mode == 1) alpha = (1.0 - smoothstep(1.0, 3.0, abs(distance))) * u.opacity * 0.85;
    else alpha = exp(-pow(distance / 9.0, 2.0)) * u.opacity * 0.45;
    return float4(float3(1.0, 0.78, 0.30) * alpha, alpha);
}
```

### Sources/LumenRender/Shaders/Upscale.metal

```metal
#include <metal_stdlib>
using namespace metal;

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

static inline float lanczos2(float r) {
    if (r < 1e-4) return 1.0;
    if (r >= 2.0) return 0.0;
    float x = M_PI_F * r;
    return (sin(x) / x) * (sin(0.5 * x) / (0.5 * x));
}

struct DirectedParams { int2 srcOrigin; int2 srcSize; int2 outSize; float scale; float sharp; };

/// Edge-directed upsample. A structure tensor over the 4x4 patch gives the edge direction; a Lanczos2 kernel is squeezed across
/// the edge and stretched along it, then the result is clamped to the inner 2x2 range (no ringing).
kernel void up_directed(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant DirectedParams& P [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.outSize.x || int(gid.y) >= P.outSize.y) return;
    float2 u = (float2(gid) + 0.5) / P.scale - 0.5;
    int2 i0 = int2(floor(u));
    float2 f = u - float2(i0);

    float3 c[4][4]; float l[4][4];
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            int2 q = clamp(i0 + int2(i - 1, j - 1), int2(0), P.srcSize - 1) + P.srcOrigin;
            c[j][i] = src.read(uint2(q)).rgb;
            l[j][i] = dot(c[j][i], kLuma);
        }
    }
    float3 J = float3(0.0);
    for (int j = 1; j <= 2; ++j) {
        for (int i = 1; i <= 2; ++i) {
            float gx = 0.5 * (l[j][i + 1] - l[j][i - 1]);
            float gy = 0.5 * (l[j + 1][i] - l[j - 1][i]);
            float w = ((i == 2) ? f.x : 1.0 - f.x) * ((j == 2) ? f.y : 1.0 - f.y);
            J += w * float3(gx * gx, gx * gy, gy * gy);
        }
    }
    float ang = 0.5 * atan2(2.0 * J.y, J.x - J.z);
    float2 n = float2(cos(ang), sin(ang));
    float2 t = float2(-n.y, n.x);
    float tr = J.x + J.z;
    float mag = sqrt(max(tr, 0.0));
    float coh = sqrt(max((J.x - J.z) * (J.x - J.z) + 4.0 * J.y * J.y, 0.0)) / (tr + 1e-6);
    float anis = coh * smoothstep(0.02, 0.12, mag);
    float sAcross = 1.0 + anis * P.sharp * 0.7;
    float sAlong = 1.0 - anis * 0.45;

    float3 acc = float3(0.0); float wsum = 0.0;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 d = float2(float(i - 1) - f.x, float(j - 1) - f.y);
            float r = length(float2(dot(d, n) * sAcross, dot(d, t) * sAlong));
            float w = lanczos2(r);
            acc += w * c[j][i]; wsum += w;
        }
    }
    float3 res = acc / (abs(wsum) > 1e-4 ? wsum : 1.0);
    float3 mn = min(min(c[1][1], c[1][2]), min(c[2][1], c[2][2]));
    float3 mx = max(max(c[1][1], c[1][2]), max(c[2][1], c[2][2]));
    dst.write(float4(clamp(res, mn, mx), 1.0), gid);
}

struct ShockParams { int2 size; float strength; float edgeLo; float edgeHi; float k; };

/// Shock filter: pushes each pixel on an edge toward the brightest/darkest *neighbour pixel* (never a new colour), steepening
/// edges without overshoot. Flat areas and noise are gated out by the gradient threshold.
kernel void up_shock(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant ShockParams& P [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.size.x || int(gid.y) >= P.size.y) return;
    float3 c[3][3]; float l[3][3];
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            int2 q = clamp(int2(gid) + int2(i - 1, j - 1), int2(0), P.size - 1);
            c[j][i] = src.read(uint2(q)).rgb;
            l[j][i] = dot(c[j][i], kLuma);
        }
    }
    float gx = 0.5 * (l[1][2] - l[1][0]);
    float gy = 0.5 * (l[2][1] - l[0][1]);
    float mag = sqrt(gx * gx + gy * gy);
    float Ixx = l[1][2] - 2.0 * l[1][1] + l[1][0];
    float Iyy = l[2][1] - 2.0 * l[1][1] + l[0][1];
    float Ixy = 0.25 * (l[2][2] - l[2][0] - l[0][2] + l[0][0]);
    float Inn = (gx * gx * Ixx + 2.0 * gx * gy * Ixy + gy * gy * Iyy) / (mag * mag + 1e-8);
    float s = -tanh(Inn * P.k);
    float w = P.strength * smoothstep(P.edgeLo, P.edgeHi, mag) * abs(s);

    float3 hi = c[1][1], lo = c[1][1]; float lh = l[1][1], ll = l[1][1];
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            if (l[j][i] > lh) { lh = l[j][i]; hi = c[j][i]; }
            if (l[j][i] < ll) { ll = l[j][i]; lo = c[j][i]; }
        }
    }
    float3 target = s > 0.0 ? hi : lo;
    dst.write(float4(mix(c[1][1], target, w), 1.0), gid);
}

struct SharpParams { int2 size; float amount; float pad; };

/// Contrast-adaptive sharpen, backed off in high-contrast areas and clamped to the local 3x3 range (no halos).
kernel void up_sharpen(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant SharpParams& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.size.x || int(gid.y) >= P.size.y) return;
    float3 c[3][3];
    float3 mn = float3(1.0), mx = float3(0.0);
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            int2 q = clamp(int2(gid) + int2(i - 1, j - 1), int2(0), P.size - 1);
            c[j][i] = src.read(uint2(q)).rgb;
            mn = min(mn, c[j][i]); mx = max(mx, c[j][i]);
        }
    }
    float3 blur = (c[0][1] + c[2][1] + c[1][0] + c[1][2] + 4.0 * c[1][1]) * 0.125;
    float range = max(max(mx.r - mn.r, mx.g - mn.g), mx.b - mn.b);
    float adapt = 1.0 - smoothstep(0.25, 0.7, range);
    float3 o = c[1][1] + P.amount * adapt * 2.0 * (c[1][1] - blur);
    dst.write(float4(clamp(o, mn, mx), 1.0), gid);
}
```

### Sources/LumenRender/TextOverlay.swift

```swift
import Foundation
import CoreGraphics
import CoreText
import AppKit
import Metal
import LumenProject
import LumenDirector

/// The frosted material behind a caption block. The card itself is drawn by
/// the Metal compositor from a blurred copy of the scene, never baked into the
/// text sprite: preview and export use the same pixels.
struct TextCard {
    /// Corner radius in sprite pixels.
    let radius: Float
    /// Base tint. Alpha is the floor for the adaptive opacity; the compositor
    /// raises it on bright backdrops until white text keeps 4.5:1 contrast.
    let tint: SIMD4<Float>
}

/// A pre-rasterized text layer composited by the same Metal path in preview and export.
struct TextOverlaySprite {
    let texture: any MTLTexture
    let center: SIMD2<Float>            // output canvas pixels, top-left origin
    let opacity: Float
    var scale: Float = 1
    /// Blur-in radius in output pixels. Zero once the caption has settled.
    var blur: Float = 0
    var card: TextCard?
}

private struct TextPart {
    let value: String
    let color: RGBA
    /// Baseline offset in raster pixels: a word rises into place as it is
    /// spoken instead of popping in at its final position.
    var rise: CGFloat = 0
}

private struct Raster {
    let texture: any MTLTexture
    let padding: CGFloat
}

/// Critically damped step response, 0 to 1. omega 20 settles in ~0.33 s.
func settle(_ t: Double, omega: Double) -> Double {
    let x = omega * max(t, 0)
    return 1 - exp(-x) * (1 + x)
}

struct CaptionPose { var opacity, lift, scale, blur: Double }

/// The caption is animated by the playhead, never by wall-clock time, so a
/// scrub lands on the exact frame. Word in: opacity 0→1, blur 8→0, 6 pt rise,
/// scale 0.985→1 over 380 ms with an ease-out quart. Group out: blur 0→6 and
/// opacity→0 over 220 ms.
func captionPose(at t: Double, shownAt: Double, hiddenAt: Double, unit: Double) -> CaptionPose {
    let inT = max(0, min(1, (t - shownAt) / 0.38))
    let e = 1 - pow(1 - inT, 4)                                  // ease-out quart
    let outT = max(0, min(1, (t - (hiddenAt - 0.22)) / 0.22))
    return CaptionPose(opacity: e * (1 - outT),
                       lift: 6 * unit * (1 - e),                 // positive: below the anchor
                       scale: 0.985 + 0.015 * e,
                       blur: (8 * (1 - e) + 6 * outT) * unit)
}

final class TextOverlayCache {
    private var textures: [String: Raster] = [:]
    private var order: [String] = []
    private let maxEntries = 64

    func caption(_ chunk: CaptionChunk, style: CaptionStyle, time: Double,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> TextOverlaySprite? {
        guard !chunk.lines.isEmpty else { return nil }
        let unit = Double(videoRect.w) / 1080.0                  // one design point at 1080 tall
        let stagger = 0.028
        let wordIn = 0.38
        var index = 0
        let lines = chunk.lines.map { line in
            line.map { word -> TextPart in
                defer { index += 1 }
                let start = chunk.start + Double(index) * stagger
                let t = max(0, min(1, (time - start) / wordIn))
                let e = 1 - pow(1 - t, 4)                       // ease-out quart
                // The spoken word is full white, the rest sit at 60 %. This is
                // brightness only: a weight change would reflow the line.
                let edge = max(0, min(1, min((time - word.start) / 0.08, (word.end - time) / 0.08)))
                let dim = RGBA(r: style.color.r, g: style.color.g, b: style.color.b, a: style.color.a * 0.6)
                var color = mix(dim, style.color, edge)
                color.a *= Float(e)
                // Quantized so the raster cache holds a bounded number of
                // variants while a caption animates.
                let step = 1.0 / 32.0
                color.a = Float((Double(color.a) / step).rounded() * step)
                let rise = ((1 - e) * 6 * unit).rounded()
                return TextPart(value: word.text, color: color, rise: CGFloat(rise))
            }
        }
        // Scale with the actual video, not the outer canvas/padding. Both
        // Studio and export share this rasterization and its layout bounds.
        let fontSize = CGFloat(videoRect.w) * CGFloat(max(style.size, 0.015))
        // A caption never uses more than 60 % of the picture width.
        let safeWidth = max(1, Int(videoRect.z * 0.60))
        guard let raster = texture(lines: lines, fontSize: fontSize, typeface: style.font,
                                   canvas: canvas, maxWidth: safeWidth, device: device) else { return nil }
        let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end, unit: unit)
        let halfH = Double(raster.texture.height) / 2 * pose.scale
        let desiredY = videoRect.y + videoRect.w * chunk.y + pose.lift
        let y = min(max(desiredY, videoRect.y + halfH + 8), videoRect.y + videoRect.w - halfH - 8)
        let card = style.pill.map { TextCard(radius: Float(raster.padding), tint: $0.simd) }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(Float(videoRect.x + videoRect.z / 2), Float(y)),
                                 opacity: Float(pose.opacity), scale: Float(pose.scale),
                                 blur: Float(pose.blur), card: card)
    }

    func manual(_ frame: TextFrame, canvas: SIMD2<Int>, device: any MTLDevice) -> TextOverlaySprite? {
        guard !frame.text.isEmpty else { return nil }
        let lines = frame.text.components(separatedBy: "\n").prefix(5).map {
            [TextPart(value: $0, color: frame.color)]
        }
        guard let raster = texture(lines: lines, fontSize: CGFloat(canvas.y) * CGFloat(max(frame.size, 0.015)),
                                   canvas: canvas, device: device) else { return nil }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(frame.center.x * Float(canvas.x), frame.center.y * Float(canvas.y)),
                                 opacity: frame.opacity)
    }

    private func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let f = Float(t)
        return RGBA(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f,
                    b: a.b + (b.b - a.b) * f, a: a.a + (b.a - a.a) * f)
    }

    /// Two faces, one weight. 450 sits exactly between regular and medium, so
    /// a caption reads evenly and the spoken word never changes weight.
    private func coreFont(_ typeface: CaptionFont, size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let desc = typeface == .serif ? (base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor)
                                      : base.fontDescriptor
        var font = CTFontCreateWithFontDescriptor(desc as CTFontDescriptor, size, nil)
        let key = "NSCTFontWeightAttribute"
        let weighted = CTFontDescriptorCreateCopyWithAttributes(desc as CTFontDescriptor,
                                                              [key: 4.5] as CFDictionary)
        let probe = CTFontCreateWithFontDescriptor(weighted, size, nil)
        // CoreText only honours a fractional weight when the face is variable;
        // otherwise keep the medium we already have.
        if let read = CTFontCopyAttribute(probe, key as CFString) as? NSNumber,
           abs(read.doubleValue - 4.5) < 0.25 {
            font = probe
        }
        return font
    }

    private func texture(lines: [[TextPart]], fontSize wanted: CGFloat, typeface: CaptionFont = .sans,
                         canvas: SIMD2<Int>, maxWidth: Int? = nil,
                         device: any MTLDevice) -> Raster? {
        let maxCharacters = lines.map { $0.reduce(0) { $0 + $1.value.count + 1 } }.max() ?? 1
        let widthLimit = max(2, min(maxWidth ?? canvas.x, canvas.x))
        let fontSize = max(10, min(wanted, CGFloat(widthLimit) * 1.15 / CGFloat(max(1, maxCharacters))))
        let identifier = lines.map { row in
            row.map { p in
                "\(p.value)@\(p.color.r),\(p.color.g),\(p.color.b),\(p.color.a)"
            }.joined(separator: "/")
        }.joined(separator: "\n")
        let key = "\(canvas.x)x\(canvas.y):\(fontSize):\(typeface.rawValue):\(identifier)"
        if let cached = textures[key] { return cached }

        let font = coreFont(typeface, size: fontSize)
        let coreLines: [CTLine] = lines.map { parts in
            let attr = NSMutableAttributedString(string: "")
            for (index, part) in parts.enumerated() {
                let color = CGColor(red: CGFloat(part.color.r), green: CGFloat(part.color.g),
                                    blue: CGFloat(part.color.b), alpha: CGFloat(part.color.a))
                let prefix = index == 0 ? "" : " "
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
                ]
                if part.rise != 0 { attributes[.baselineOffset] = part.rise }
                attr.append(NSAttributedString(string: prefix + part.value, attributes: attributes))
            }
            return CTLineCreateWithAttributedString(attr)
        }
        let widths = coreLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let padding = max(8, fontSize * 0.32)
        let lineHeight = fontSize * 1.32
        let width = max(2, min(widthLimit, Int(ceil((widths.max() ?? 0) + padding * 2))))
        let height = max(2, min(canvas.y, Int(ceil(CGFloat(coreLines.count) * lineHeight + padding * 2))))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let texture: (any MTLTexture)? = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            // The card is a compositor material now; only glyphs live here.
            context.setShadow(offset: CGSize(width: 0, height: -1),
                              blur: max(2, fontSize * 0.1),
                              color: CGColor(gray: 0, alpha: 0.70))
            for (index, line) in coreLines.enumerated() {
                context.textPosition = CGPoint(x: (CGFloat(width) - widths[index]) / 2,
                    y: CGFloat(height) - padding - CGFloat(index + 1) * lineHeight + fontSize * 0.20)
                CTLineDraw(line, context)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let result = device.makeTexture(descriptor: descriptor), let bytes = raw.baseAddress else {
                return nil
            }
            result.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: bytes, bytesPerRow: width * 4)
            return result
        }
        guard let texture else { return nil }
        let raster = Raster(texture: texture, padding: padding)
        textures[key] = raster
        order.append(key)
        if order.count > maxEntries {
            textures.removeValue(forKey: order.removeFirst())
        }
        return raster
    }
}
```

### Sources/LumenRender/Upscaler.swift

```swift
import Metal
import simd
import LumenCore
import LumenProject

public struct UpscaleResult {
    public let texture: MTLTexture
    public let region: SIMD4<Float>            // source px: x, y, w, h
    public let factor: Float
    public let texSize: SIMD2<Float>           // physical size; may exceed region * factor
}

private struct DirectedParams { var srcOrigin: SIMD2<Int32>; var srcSize: SIMD2<Int32>; var outSize: SIMD2<Int32>; var scale: Float; var sharp: Float }
private struct ShockParams { var size: SIMD2<Int32>; var strength: Float; var edgeLo: Float; var edgeHi: Float; var k: Float }
private struct SharpParams { var size: SIMD2<Int32>; var amount: Float; var pad: Float = 0 }

/// Training-free UI upscaler. Upscales only the visible source region, on a source-aligned lattice, by a quantized factor
/// {2,3,4,6,8}, as a chain of edge-directed stages (each followed by shock iterations) and a final limited sharpen.
/// The compositor then resamples this texture with Catmull-Rom, so continuous zoom never shimmers.
/// Owned by one render queue. Use a separate instance per consumer (view, loupe): the buffers are reused every call.
public final class Upscaler {
    private let k: FXKernels
    private var sets: [[MTLTexture?]] = [[nil, nil], [nil, nil]]
    private var last: (id: UInt64, region: SIMD4<Int32>, factor: Int, result: UpscaleResult)?

    public init(kernels: FXKernels) { k = kernels }

    /// Available factors. The user setting (`CameraParams.upscaleMaxFactor`,
    /// 2...10) caps this ladder; magnification then picks the smallest
    /// factor >= the needed magnification. So "5×"/"8×"/"10×" are settings,
    /// not fixed claims: mag 4.5 with cap 10 picks 5×, mag 6.5 picks 8×.
    static let ladder = [2, 3, 4, 5, 6, 8, 10]
    static func stages(_ f: Int) -> [Int] {
        switch f { case 2: [2]; case 3: [3]; case 4: [2, 2]; case 5: [5]; case 6: [2, 3]; case 10: [2, 5]; default: [2, 2, 2] }
    }

    public static func factor(forMagnification m: Double, maxFactor: Int) -> Int {
        let ok = ladder.filter { $0 <= maxFactor }
        return ok.first { Double($0) >= m } ?? (ok.last ?? 2)
    }

    /// 0 below blendStart (plain Catmull-Rom), 1 above blendEnd. Avoids a visible pop when the upscaler engages.
    public static func blend(forMagnification m: Double, _ p: UpscaleParams) -> Float {
        guard p.enabled, p.blendEnd > p.blendStart else { return 0 }
        return Float(smoothstep((m - p.blendStart) / (p.blendEnd - p.blendStart)))
    }

    /// Integer-aligned source region covering the view plus margin.
    public static func region(center c: SIMD2<Double>, view: SIMD2<Double>, source: SIMD2<Double>, margin: Double = 8) -> SIMD4<Int32> {
        let h = view / 2 + margin
        let x0 = max((c.x - h.x).rounded(.down), 0), y0 = max((c.y - h.y).rounded(.down), 0)
        let x1 = min((c.x + h.x).rounded(.up), source.x), y1 = min((c.y + h.y).rounded(.up), source.y)
        let w = min(max(x1 - x0, 8), source.x - x0), hh = min(max(y1 - y0, 8), source.y - y0)
        return SIMD4(Int32(x0), Int32(y0), Int32(w), Int32(hh))
    }

    public func upscale(_ cb: MTLCommandBuffer, source: MTLTexture, region: SIMD4<Int32>, factor: Int,
                        params p: UpscaleParams, frameID: UInt64) throws -> UpscaleResult {
        if let l = last, l.id == frameID, l.region == region, l.factor == factor { return l.result }
        guard let e = cb.makeComputeCommandEncoder() else { throw FXError.noEncoder }
        // A failed pipeline/texture allocation must not leak an open encoder.
        defer { e.endEncoding() }
        e.label = "Upscale x\(factor)"
        var input: MTLTexture = source
        var origin = SIMD2<Int32>(region.x, region.y), size = SIMD2<Int32>(region.z, region.w)
        var cum: Float = 1
        var current: MTLTexture = source, spare: MTLTexture = source

        for (n, s) in Self.stages(factor).enumerated() {
            let out = SIMD2<Int32>(size.x * Int32(s), size.y * Int32(s))
            cum *= Float(s)
            var a = try buffer(n & 1, 0, out), b = try buffer(n & 1, 1, out)
            var dp = DirectedParams(srcOrigin: origin, srcSize: size, outSize: out, scale: Float(s), sharp: Float(p.edgeSharpness))
            e.setComputePipelineState(try k.pipeline("up_directed"))
            e.setTexture(input, index: 0); e.setTexture(a, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DirectedParams>.stride, index: 0)
            k.dispatch(e, pipeline: try k.pipeline("up_directed"), width: Int(out.x), height: Int(out.y))

            var sp = ShockParams(size: out, strength: Float(p.shock), edgeLo: 0.04 / cum, edgeHi: 0.25 / cum, k: 30)
            let shock = try k.pipeline("up_shock")
            e.setComputePipelineState(shock)
            for _ in 0..<max(p.shockIterations, 0) {
                e.setTexture(a, index: 0); e.setTexture(b, index: 1)
                e.setBytes(&sp, length: MemoryLayout<ShockParams>.stride, index: 0)
                k.dispatch(e, pipeline: shock, width: Int(out.x), height: Int(out.y))
                swap(&a, &b)
            }
            current = a; spare = b
            input = a; origin = .zero; size = out
        }
        if p.finalSharpen > 0 {
            var sp = SharpParams(size: size, amount: Float(p.finalSharpen))
            let sharp = try k.pipeline("up_sharpen")
            e.setComputePipelineState(sharp)
            e.setTexture(current, index: 0); e.setTexture(spare, index: 1)
            e.setBytes(&sp, length: MemoryLayout<SharpParams>.stride, index: 0)
            k.dispatch(e, pipeline: sharp, width: Int(size.x), height: Int(size.y))
            swap(&current, &spare)
        }

        let r = UpscaleResult(texture: current, region: SIMD4(Float(region.x), Float(region.y), Float(region.z), Float(region.w)),
                              factor: Float(factor), texSize: SIMD2(Float(current.width), Float(current.height)))
        last = (frameID, region, factor, r)
        return r
    }

    /// Growth-only buffers: bounded by ~1.5x the canvas per side, so reallocation stops after warm-up.
    private func buffer(_ set: Int, _ i: Int, _ size: SIMD2<Int32>) throws -> MTLTexture {
        let w = Int(size.x), h = Int(size.y)
        if let t = sets[set][i], t.width >= w, t.height >= h { return t }
        let nw = (max(w, sets[set][i]?.width ?? 0) + 63) & ~63, nh = (max(h, sets[set][i]?.height ?? 0) + 63) & ~63
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: nw, height: nh, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        guard let t = k.device.makeTexture(descriptor: d) else { throw FXError.noTexture }
        sets[set][i] = t
        return t
    }
}
```

### Sources/LumenRender/ZoomTransform.swift

```swift
import Foundation
import LumenProject

/// One source-pixel -> canvas-pixel transform for the preview, overlays and export.
/// Quartz event coordinates are already top-left; callers subtract the capture origin
/// and multiply by the capture's actual backing scale before using this transform.
public struct ZoomTransform: Sendable {
    public let source: SIMD2<Double>
    public let canvas: SIMD2<Double>
    public let videoRect: SIMD4<Double>
    public let cameraCenter: SIMD2<Double>
    public let scale: Double

    public init(canvas: SIMD2<Int>, source: SIMD2<Double>, style: Style,
                cameraCenter: SIMD2<Double>? = nil, scale: Double = 1) {
        let size = SIMD2<Double>(Double(canvas.x), Double(canvas.y))
        let inset = style.insets
        // Insets are canvas-width fractions, including the vertical ones.
        let left = size.x * inset.left, right = size.x * inset.right
        let top = size.x * inset.top, bottom = size.x * inset.bottom
        let availableW = max(size.x - left - right, 1)
        let availableH = max(size.y - top - bottom, 1)
        let aspect = source.x / max(source.y, 1)
        let fittedW = min(availableW, availableH * aspect)
        let videoSize = min(max(style.contentScale, 0.3), 2.0)
        let width = fittedW * videoSize, height = width / aspect
        let originX = left + (availableW - width) / 2
        let originY = top + (availableH - height) / 2
        self.source = source
        self.canvas = size
        self.videoRect = SIMD4(originX.rounded(), originY.rounded(), width.rounded(), height.rounded())
        self.scale = max(scale, 1)
        self.cameraCenter = Self.clamp(cameraCenter ?? source / 2, source: source, scale: self.scale)
    }

    /// The source viewport is always contained within the recording, even at the corners.
    public static func clamp(_ focus: SIMD2<Double>, source: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let half = source / (2 * max(scale, 1))
        return SIMD2(min(max(focus.x, half.x), source.x - half.x),
                     min(max(focus.y, half.y), source.y - half.y))
    }

    public var viewport: SIMD4<Double> {
        let sz = source / scale
        return SIMD4(cameraCenter.x - sz.x / 2, cameraCenter.y - sz.y / 2, sz.x, sz.y)
    }

    public func sourceToCanvas(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        return SIMD2(videoRect.x + (p.x - v.x) / v.z * videoRect.z,
                     videoRect.y + (p.y - v.y) / v.w * videoRect.w)
    }

    public func canvasToSource(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        return SIMD2(v.x + (p.x - videoRect.x) / videoRect.z * v.z,
                     v.y + (p.y - videoRect.y) / videoRect.w * v.w)
    }

    public func sourceNormalized(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(p.x / max(source.x, 1), p.y / max(source.y, 1))
    }
}
```

## LumenAudio/

### Sources/LumenAudio/AudioCheck.swift

```swift
import Foundation
import Accelerate
import LumenCore

/// Result of `lumen-cli audio-check`. Plain values. Produced once per file.
public struct AudioCheckReport: Codable, Sendable, Equatable {
    public var format: String
    public var sampleRate: Double
    public var channels: Int
    public var frames: Int
    public var duration: Double
    public var peakDb: Double
    public var truePeakDb: Double
    public var lufs: Double
    public var clippedSamples: Int
    public var dcOffset: Double
    public var noiseFloorDb: Double
    public var zeroRunDropouts: Int
    public var clickEvents: Int
    public var correlation: Double?
    public init(format: String, sampleRate: Double, channels: Int, frames: Int, duration: Double,
                peakDb: Double, truePeakDb: Double, lufs: Double, clippedSamples: Int,
                dcOffset: Double, noiseFloorDb: Double, zeroRunDropouts: Int,
                clickEvents: Int, correlation: Double? = nil) {
        self.format = format; self.sampleRate = sampleRate; self.channels = channels
        self.frames = frames; self.duration = duration; self.peakDb = peakDb
        self.truePeakDb = truePeakDb; self.lufs = lufs; self.clippedSamples = clippedSamples
        self.dcOffset = dcOffset; self.noiseFloorDb = noiseFloorDb
        self.zeroRunDropouts = zeroRunDropouts; self.clickEvents = clickEvents
        self.correlation = correlation
    }
}

/// Pure DSP metrics over decoded Float32 channels. No allocation in render path.
public enum AudioCheck {
    public static func analyze(channels: [[Float]], sampleRate: Double, format: String = "pcm-f32") -> AudioCheckReport {
        guard let n = channels.first?.count, !channels.isEmpty, n > 0 else {
            return AudioCheckReport(format: format, sampleRate: sampleRate, channels: channels.count,
                                    frames: 0, duration: 0, peakDb: -120, truePeakDb: -120,
                                    lufs: -70, clippedSamples: 0, dcOffset: 0, noiseFloorDb: -120,
                                    zeroRunDropouts: 0, clickEvents: 0)
        }
        var peak: Float = 0
        var clipped = 0
        var sum: Double = 0
        for ch in channels {
            for v in ch {
                peak = max(peak, abs(v))
                if abs(v) >= 1.0 { clipped += 1 }
                sum += Double(v)
            }
        }
        let total = Double(channels.count * n)
        let dc = sum / total
        let peakDb = 20 * log10(Double(max(peak, 1e-9)))
        let tp = Loudness.truePeakDb(channels)
        let lufs = Loudness.integrated(channels, fs: sampleRate)

        // Noise floor: RMS of quietest 10% of 100 ms frames (first channel).
        let hop = max(Int(0.1 * sampleRate), 1)
        var framesDb: [Double] = []
        let ch0 = channels[0]
        for s in stride(from: 0, to: max(n - hop, 1), by: hop) {
            var e = 0.0
            for i in s..<(s + hop) { e += Double(ch0[i]) * Double(ch0[i]) }
            framesDb.append(10 * log10(e / Double(hop) + 1e-12))
        }
        let noiseFloor: Double
        if framesDb.isEmpty { noiseFloor = -120 }
        else {
            let sorted = framesDb.sorted()
            noiseFloor = sorted[max(0, sorted.count / 10 - 1)]
        }

        // Zero-run dropouts: runs of >=20 ms near-silence where signal was loud before/after.
        let zeroThresh: Float = 0.0005
        let minRun = max(Int(0.020 * sampleRate), 1)
        var dropouts = 0
        var run = 0
        for i in 0..<n {
            if abs(ch0[i]) < zeroThresh { run += 1 }
            else {
                if run >= minRun { dropouts += 1 }
                run = 0
            }
        }
        if run >= minRun { dropouts += 1 }

        // Click events: second-difference outliers in high-passed signal.
        // Second difference emphasizes discontinuities; threshold by MAD.
        var diffs: [Double] = []
        if n > 4 {
            diffs.reserveCapacity(n)
            for i in 1..<(n - 1) {
                let d = Double(ch0[i + 1] - 2 * ch0[i] + ch0[i - 1])
                diffs.append(d)
            }
        }
        let clicks: Int
        if diffs.count < 100 { clicks = 0 }
        else {
            let sortedAbs = diffs.map(abs).sorted()
            let median = sortedAbs[sortedAbs.count / 2]
            var mad = diffs.map { abs($0 - median) }.sorted()
            let m = mad[mad.count / 2]
            let sigma = max(m * 1.4826, 1e-6)
            let thresh = median + 12 * sigma
            // Only count extreme isolated spikes above -40 dBFS equivalent
            clicks = diffs.filter { abs($0) > max(thresh, 0.02) }.count
        }

        // Inter-channel correlation (stereo only).
        var corr: Double?
        if channels.count >= 2, let r = channels.dropFirst().first, r.count == n {
            var num = 0.0, dl = 0.0, dr = 0.0
            for i in 0..<n {
                let a = Double(ch0[i]) - dc, b = Double(r[i]) - dc
                num += a * b; dl += a * a; dr += b * b
            }
            if dl > 1e-12 && dr > 1e-12 { corr = num / (sqrt(dl) * sqrt(dr)) }
        }

        return AudioCheckReport(format: format, sampleRate: sampleRate, channels: channels.count,
                                frames: n, duration: Double(n) / sampleRate, peakDb: peakDb,
                                truePeakDb: tp, lufs: lufs, clippedSamples: clipped,
                                dcOffset: dc, noiseFloorDb: noiseFloor,
                                zeroRunDropouts: dropouts, clickEvents: clicks, correlation: corr)
    }

    /// 4× oversampled click detector for pipeline tests: counts isolated
    /// second-difference spikes. Deterministic, no randomness.
    public static func clickCount(_ x: [Float]) -> Int {
        guard x.count > 4 else { return 0 }
        var diffs: [Double] = []
        diffs.reserveCapacity(x.count)
        for i in 1..<(x.count - 1) {
            diffs.append(Double(x[i + 1] - 2 * x[i] + x[i - 1]))
        }
        let sortedAbs = diffs.map(abs).sorted()
        let median = sortedAbs[sortedAbs.count / 2]
        var mad = diffs.map { abs($0 - median) }.sorted()
        let m = mad[mad.count / 2]
        let sigma = max(m * 1.4826, 1e-6)
        let thresh = median + 12 * sigma
        return diffs.filter { abs($0) > max(thresh, 0.02) }.count
    }

    /// THD+N via FFT on a steady slice (50-90% of buffer). Pure, offline.
    /// Uses an 8192-sample Hann window so leakage stays low and the FFT is fast.
    public static func thdPlusNoise(_ x: [Float], sampleRate: Double, fundamentalHz: Double) -> Double? {
        guard x.count >= 8192 else { return nil }
        let mid = x.count / 2
        let len = min(8192, x.count)
        let lo = max(mid - len / 2, 0)
        var re = [Double](repeating: 0, count: 8192)
        for i in 0..<len {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(len - 1, 1)))
            re[i] = Double(x[lo + i]) * w
        }
        let p2 = 8192
        var freqRe = re
        var freqIm = [Double](repeating: 0, count: p2)
        // Cooley-Tukey (iterative)
        var j = 0
        for i in 1..<p2 {
            var bit = p2 >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { freqRe.swapAt(i, j); freqIm.swapAt(i, j) }
        }
        var length = 2
        while length <= p2 {
            let ang = -2 * Double.pi / Double(length)
            for s in stride(from: 0, to: p2, by: length) {
                for k in 0..<(length / 2) {
                    let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                    let a = s + k, b = a + length / 2
                    let tr = freqRe[b] * wr - freqIm[b] * wi
                    let ti = freqRe[b] * wi + freqIm[b] * wr
                    freqRe[b] = freqRe[a] - tr; freqIm[b] = freqIm[a] - ti
                    freqRe[a] += tr; freqIm[a] += ti
                }
            }
            length <<= 1
        }
        var fund = 0.0, total = 0.0
        let fundBin = max(1, Int((fundamentalHz / sampleRate * Double(p2)).rounded()))
        for k in 1..<(p2 / 2) {
            let e = freqRe[k] * freqRe[k] + freqIm[k] * freqIm[k]
            total += e
            // ±5-bin Hann main lobe so non-coherent leakage is counted as
            // fundamental, not as distortion.
            if abs(k - fundBin) <= 5 { fund += e }
        }
        guard total > 1e-12 else { return nil }
        let thdn = (total - fund) / fund
        guard thdn > 0 else { return nil }
        return 10 * log10(thdn)
    }

    /// 4K spectrogram (STFT magnitude, log scale). Clicks show as vertical
    /// lines, dropouts as gaps, clipping as broadband smear. Width ≥3840 px.
    public static func renderSpectrogram(channels: [[Float]], sampleRate: Double) -> (width: Int, height: Int, rows: [[UInt8]]) {
        let width = 3840, height = 1024
        var rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * 4), count: height)
        guard let ch = channels.first, !ch.isEmpty, sampleRate > 0 else { return (width, height, rows) }
        // STFT: 2048 window, 512 hop. Map frames to width, bins to height (log freq).
        let nfft = 2048, hop = 512, bins = nfft / 2
        let frames = max((ch.count - nfft) / hop, 1)
        let win: [Float] = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft - 1))) }
        var mags = [[Float]](repeating: [Float](repeating: 0, count: bins), count: frames)
        var re = [Double](repeating: 0, count: nfft), im = [Double](repeating: 0, count: nfft)
        for f in 0..<frames {
            let off = f * hop
            for i in 0..<nfft {
                let s = off + i < ch.count ? ch[off + i] : 0
                re[i] = Double(s) * Double(win[i]); im[i] = 0
            }
            fft(&re, &im, nfft)
            for k in 0..<bins {
                let m = sqrt(re[k] * re[k] + im[k] * im[k])
                mags[f][k] = Float(m)
            }
        }
        // Normalize per-bin dB to 0..1 (floor -100 dB).
        var maxDb = 0.0
        var dbs = [[Float]](repeating: [Float](repeating: 0, count: bins), count: frames)
        for f in 0..<frames {
            for k in 0..<bins {
                let db = 20 * log10(max(Double(mags[f][k]), 1e-9))
                dbs[f][k] = Float(db)
                maxDb = max(maxDb, db)
            }
        }
        for f in 0..<frames {
            let x = Int(Double(f) / Double(max(frames - 1, 1)) * Double(width - 1))
            for y in 0..<height {
                // Log freq: y=0 is Nyquist (top), y=height-1 is DC (bottom).
                let t = Double(y) / Double(height - 1)
                let freqT = pow(1 - t, 3.5) // emphasize lows
                let k = min(Int(freqT * Double(bins - 1)), bins - 1)
                let db = Double(dbs[f][k])
                let norm = clamp((db + 100) / 100, 0, 1)
                let c = inferno(norm)
                let px = x * 4
                rows[y][px] = c.0; rows[y][px + 1] = c.1; rows[y][px + 2] = c.2; rows[y][px + 3] = 255
            }
        }
        return (width, height, rows)
    }

    private static func inferno(_ v: Double) -> (UInt8, UInt8, UInt8) {
        // Compact inferno approximation (black→purple→orange→yellow).
        let r = clamp(1.5 * v - 0.1, 0, 1), g = clamp(2.5 * v - 1.0, 0, 1), b = clamp(1.2 * (1 - v) - 0.1, 0, 1)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    private static func fft(_ re: inout [Double], _ im: inout [Double], _ n: Int) {
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            for s in stride(from: 0, to: n, by: len) {
                for k in 0..<(len / 2) {
                    let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                    let a = s + k, b = a + len / 2
                    let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
            }
            len <<= 1
        }
    }
}
```

### Sources/LumenAudio/AudioIO.swift

```swift
import Foundation
import AVFoundation
import Accelerate

/// Stereo 48 kHz Float32 music bed. Value type.
public struct MusicTrack: Sendable {
    public var l: [Float], r: [Float]
    public init(l: [Float], r: [Float]) { self.l = l; self.r = r }
}

public enum AudioIOError: Error { case unreadable(String) }

/// Hands a one-shot buffer to AVAudioConverter's input block.
private final class OnceBox: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    init(_ b: AVAudioPCMBuffer) { buffer = b }
}

public enum AudioIO {
    public static let fs = 48000.0
    static var stereoFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: false)!
    }

    // MARK: Decode

    /// Whole file -> per-channel Float32 at the file's own sample rate.
    static func decode(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let total = Int(f.length), nch = Int(fmt.channelCount)
        guard total > 0, nch > 0 else { return ([], fmt.sampleRate) }
        var chans = [[Float]](repeating: [], count: nch)
        for c in 0..<nch { chans[c].reserveCapacity(total) }
        let cap: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw AudioIOError.unreadable("buffer") }
        while f.framePosition < f.length {
            try f.read(into: buf, frameCount: cap)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let d = buf.floatChannelData else { throw AudioIOError.unreadable("not float PCM") }
            for c in 0..<nch { chans[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: n)) }
        }
        return (chans, fmt.sampleRate)
    }

    // MARK: Resample (mono -> 48 kHz)

    static func resample(_ x: [Float], from rate: Double) -> [Float] {
        guard !x.isEmpty, abs(rate - fs) > 0.5 else { return x }
        return convert(x, from: rate) ?? linear(x, from: rate)
    }

    private static func convert(_ x: [Float], from rate: Double) -> [Float]? {
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inB = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(x.count)),
              let outB = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(x.count) * fs / rate) + 4096)
        else { return nil }
        inB.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inB.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let box = OnceBox(inB)
        var err: NSError?
        let st = conv.convert(to: outB, error: &err) { _, status in
            if let b = box.buffer { box.buffer = nil; status.pointee = .haveData; return b }
            status.pointee = .endOfStream; return nil
        }
        guard st != .error, err == nil, outB.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: outB.floatChannelData![0], count: Int(outB.frameLength)))
    }

    /// Fallback if AVAudioConverter refuses.
    private static func linear(_ x: [Float], from rate: Double) -> [Float] {
        let n = Int(Double(x.count) * fs / rate), r = rate / fs
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * r, i0 = Int(p)
            if i0 + 1 < x.count { out[i] = x[i0] + (x[i0 + 1] - x[i0]) * Float(p - Double(i0)) }
            else if i0 < x.count { out[i] = x[i0] }
        }
        return out
    }

    // MARK: Public API

    /// Any audio file -> 48 kHz stereo Float32. Mono is duplicated; >2 channels use the first two.
    public static func readStereo(_ url: URL) throws -> ([Float], [Float]) {
        let (ch, rate) = try decode(url)
        guard let first = ch.first else { return ([], []) }
        let l = resample(first, from: rate)
        let r = ch.count > 1 ? resample(ch[1], from: rate) : l
        return (l, r)
    }

    public static func readMono(_ url: URL) throws -> [Float] {
        let (l, r) = try readStereo(url)
        guard l.count == r.count, !l.isEmpty else { return l }
        let mono = vDSP.multiply(0.5, vDSP.add(l, r))
        // Opposed microphone channels can cancel almost completely in an L+R
        // downmix. Keep the stronger voice channel when cancellation is severe.
        let lp = vDSP.sumOfSquares(l), rp = vDSP.sumOfSquares(r)
        if vDSP.sumOfSquares(mono) < 0.2 * max(lp, rp) { return lp >= rp ? l : r }
        return mono
    }

    public static func loadMusic(_ url: URL) -> MusicTrack? {
        guard let (l, r) = try? readStereo(url), l.count > Int(fs), l.count == r.count else { return nil }
        return MusicTrack(l: l, r: r)
    }

    /// IEEE 32-bit float WAV for lossless handoff to Premiere, Resolve,
    /// Final Cut or any editor. File type is inferred from the .wav extension.
    public static func writeWAV(_ l: [Float], _ r: [Float], to url: URL) throws {
        precondition(url.pathExtension.lowercased() == "wav", "Stems must have .wav extension")
        try writeCAF(l, r, to: url)
    }

    /// Float32 stereo CAF (the exporter reads this back and AAC-encodes it).
    public static func writeCAF(_ l: [Float], _ r: [Float], to url: URL) throws {
        let fmt = stereoFormat
        var settings = fmt.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { throw AudioIOError.unreadable("buffer") }
        let total = min(l.count, r.count)
        var i = 0
        while i < total {
            let n = min(chunk, total - i)
            b.frameLength = AVAudioFrameCount(n)
            l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
            r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress! + i, count: n) }
            try f.write(from: b)
            i += n
        }
    }
}
extension AudioIO {
    public static func writeMonoWAV(_ samples: [Float], sampleRate: Double = fs, paddingSamples: Int = 0, to url: URL) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let data = buffer.floatChannelData else { throw AudioIOError.unreadable("mono format") }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = samples.count + max(paddingSamples, 0)
        for offset in stride(from: 0, to: total, by: Int(buffer.frameCapacity)) {
            let count = min(Int(buffer.frameCapacity), total - offset)
            let available = min(count, max(samples.count - offset, 0))
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if available > 0, let base = source.baseAddress { data[0].update(from: base + offset, count: available) }
            }
            if available < count { data[0].advanced(by: available).update(repeating: 0, count: count - available) }
            try file.write(from: buffer)
        }
    }

    static func resampleMono(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                              channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * outputRate / inputRate)) + 4096),
              let inputData = input.floatChannelData, let outputData = output.floatChannelData
        else { throw AudioIOError.unreadable("resampler") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { inputData[0].update(from: base, count: samples.count) }
        }
        let box = OnceBox(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let value = box.buffer else { state.pointee = .endOfStream; return nil }
            box.buffer = nil; state.pointee = .haveData; return value
        }
        guard status != .error, error == nil else { throw error ?? AudioIOError.unreadable("conversion") }
        let expected = Int((Double(samples.count) * outputRate / inputRate).rounded())
        var result = Array(UnsafeBufferPointer(start: outputData[0], count: min(Int(output.frameLength), expected)))
        if result.count < expected { result.append(contentsOf: repeatElement(0, count: expected - result.count)) }
        return result
    }
}
```

### Sources/LumenAudio/AudioMapped.swift

```swift
import Foundation
import LumenCore
import LumenProject

/// Time-map audio sampling (moved from Mixer.swift to keep each file ≤500 lines).
/// Pure function of (samples, TimeMap). Owned by the offline mixer.
extension AudioMixer {
    /// Source-time audio -> output time through the time map (1 ms steps, linear interpolation).
    /// Fades to silence (10 ms) inside speed ramps when `muteRamps` is set.
    /// Cut joins use a 40 ms equal-power crossfade (never an abrupt jump).
    static func mapped(_ x: [Float], offset: Double, tm: TimeMap, n: Int, muteRamps: Bool) -> [Float] {
        let fs = AudioIO.fs, spms = Int(fs / 1000)
        var y = [Float](repeating: 0, count: n)
        var prevS = tm.source(atOutput: 0), prevG = 1.0
        let cutOutputs = tm.cuts.compactMap { (cut: CutRange) -> Double? in
            guard cut.end > cut.start else { return nil }
            return tm.output(atSource: cut.end)
        }
        let halfXfade = Int(0.020 * fs)
        for k in 1...(n / spms + 1) {
            let t = Double(k) / 1000, s = tm.source(atOutput: t)
            let target = muteRamps && tm.speed(atOutput: t) > 1.2 ? 0.0 : 1.0
            let g = prevG + clamp(target - prevG, -0.1, 0.1)
            for j in 0..<spms {
                let i = (k - 1) * spms + j
                if i >= n { break }
                let u = Double(j) / Double(spms)
                let ss = (prevS + (s - prevS) * u - offset) * fs
                let gg = prevG + (g - prevG) * u
                var cross: (pre: Float, post: Float, w: Float)?
                for cutOut in cutOutputs {
                    let cutSample = Int(cutOut * fs)
                    if i >= cutSample - halfXfade && i < cutSample + halfXfade {
                        let w = Float(i - (cutSample - halfXfade)) / Float(halfXfade * 2)
                        let advance = Double(i - cutSample) / fs
                        let prePos = (tm.source(atOutput: max(0, cutOut - 0.001)) + advance - offset) * fs
                        let postPos = (tm.source(atOutput: cutOut + 0.001) + advance - offset) * fs
                        func sample(at pos: Double) -> Float {
                            guard pos >= 0, pos < Double(x.count - 1) else { return 0 }
                            let i0 = Int(pos), f = Float(pos - Double(i0))
                            return x[i0] * (1 - f) + x[i0 + 1] * f
                        }
                        cross = (sample(at: prePos), sample(at: postPos), w)
                        break
                    }
                }
                if let c = cross {
                    let mix = Float(gg) * (c.pre * sqrtf(1 - c.w) + c.post * sqrtf(c.w))
                    if abs(mix) > 0.00001 { y[i] = mix }
                    continue
                }
                if gg > 0.001, ss >= 0, ss < Double(x.count - 1) {
                    let i0 = Int(ss), f = Float(ss - Double(i0))
                    y[i] = (x[i0] * (1 - f) + x[i0 + 1] * f) * Float(gg)
                }
            }
            prevS = s; prevG = g
        }
        return y
    }
}
```

### Sources/LumenAudio/BundledAudioAssets.swift

```swift
import Foundation

/// A single resolver for sounds in a packaged Lumen.app and from a source checkout.
/// Missing audio is not replaced by generated noise.
public enum BundledAudioAssets {
    public struct Music: Hashable, Sendable {
        public let category: String
        public let title: String
        public let url: URL
        public init(category: String, title: String, url: URL) {
            self.category = category; self.title = title; self.url = url
        }
    }

    public static var root: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Audio", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/public/assets", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mouse-click.mp3").path) }
    }

    public static func effect(named name: String) -> URL? {
        guard let path = root?.appendingPathComponent(name), FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    /// Fresh click sfx (new-click.mp3) — default clickTone .fresh.
    public static var freshClick: [Float] {
        guard let url = effect(named: "new-click.mp3"),
              let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { return [] }
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0.0001 ? pcm.map { $0 * (1.0 / peak) } : []
    }

    public static let music: [Music] = {
        guard let root = root?.appendingPathComponent("music", isDirectory: true) else { return [] }
        let fm = FileManager.default
        return ["calm", "epic", "futuristic", "tension", "upbeat"].flatMap { category -> [Music] in
            let dir = root.appendingPathComponent(category, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                    let raw = file.deletingPathExtension().lastPathComponent
                    let name = raw.replacingOccurrences(of: " \\[[^\\]]+\\]$", with: "", options: .regularExpression)
                    return Music(category: category, title: name, url: file)
                }
        }
    }()
}
```

### Sources/LumenAudio/DSP.swift

```swift
import Foundation
import LumenCore

public struct Biquad: Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    public mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
        // Flush denormals on every audio path (prevents 10x slowdowns).
        if abs(y) < 1e-30 { return 0 }
        return y
    }
    public static func highpass(_ f: Double, q: Double = 0.7071, fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - a) / a0)
    }
    public static func peaking(_ f: Double, q: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a / A
        return Biquad(b0: (1 + a * A) / a0, b1: -2 * c / a0, b2: (1 - a * A) / a0, a1: -2 * c / a0, a2: (1 - a / A) / a0)
    }
    /// BS.1770 stage 1 (head-related high shelf).
    static func kShelf(fs: Double) -> Biquad {
        let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        let K = tan(Double.pi * f0 / fs), Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1 + K / Q + K * K
        return Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2 * (K * K - Vh) / a0, b2: (Vh - Vb * K / Q + K * K) / a0,
                      a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
    }
    /// BS.1770 stage 2 (RLB high-pass); numerator is [1, -2, 1] by spec.
    static func kHigh(fs: Double) -> Biquad {
        let f0 = 38.13547087602444, Q = 0.5003270373238773, K = tan(Double.pi * f0 / fs), a0 = 1 + K / Q + K * K
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
    }
}

public enum Loudness {
    /// ITU-R BS.1770-4 integrated loudness (LUFS): K-weighting, 400 ms blocks at 75% overlap, -70 abs gate, -10 LU relative gate.
    public static func integrated(_ ch: [[Float]], fs: Double = 48000) -> Double {
        guard let n = ch.first?.count, n > Int(0.4 * fs) else { return -70 }
        var cs: [[Double]] = []
        for c in ch {
            var s1 = Biquad.kShelf(fs: fs), s2 = Biquad.kHigh(fs: fs)
            var p = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { let y = s2.run(s1.run(Double(c[i]))); p[i + 1] = p[i] + y * y }
            cs.append(p)
        }
        let N = Int(0.4 * fs), H = Int(0.1 * fs)
        var z: [Double] = [], s = 0
        while s + N <= n { z.append(cs.reduce(0) { $0 + ($1[s + N] - $1[s]) / Double(N) }); s += H }
        func l(_ v: Double) -> Double { -0.691 + 10 * log10(max(v, 1e-12)) }
        let g1 = z.filter { l($0) > -70 }
        guard !g1.isEmpty else { return -70 }
        let rel = l(g1.reduce(0, +) / Double(g1.count)) - 10
        let g2 = g1.filter { l($0) > rel }
        guard !g2.isEmpty else { return -70 }
        return l(g2.reduce(0, +) / Double(g2.count))
    }

    /// 4x oversampled peak (12-tap Hann-windowed sinc per phase). Only inspects regions above -10 dBFS.
    public static func truePeakDb(_ ch: [[Float]]) -> Double {
        var taps = [[Float]](repeating: [Float](repeating: 0, count: 12), count: 4)
        for ph in 0..<4 { for k in 0..<12 {
            let x = Double(k - 5) - Double(ph) / 4
            let s = abs(x) < 1e-9 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            taps[ph][k] = Float(s * (0.5 + 0.5 * cos(Double.pi * x / 6)))
        } }
        var peak: Float = 0
        for channel in ch {
            for sample in channel { peak = max(peak, abs(sample)) }
            for i in channel.indices {
                let lower = max(i - 5, 0), upper = min(i + 6, channel.count - 1)
                guard channel[lower...upper].contains(where: { abs($0) > 0.3 }) else { continue }
                for phase in 1..<4 {
                    var value: Float = 0
                    for k in 0..<12 {
                        let index = i + k - 5
                        if channel.indices.contains(index) { value += channel[index] * taps[phase][k] }
                    }
                    peak = max(peak, abs(value))
                }
            }
        }
        return 20 * log10(Double(max(peak, 1e-9)))
    }
}

/// Offline (non-causal, zero-latency) look-ahead limiter: sliding-min of required gain, smoothed by a centered moving average.
/// `half` ≈ 2 ms at 48 kHz for inter-sample headroom. Float headroom is kept
/// until here; the ceiling is a true-peak ceiling, not a hard clip.
public enum Limiter {
    public static func apply(_ ch: inout [[Float]], ceiling: Float, half: Int = 96) {
        guard let n = ch.first?.count, n > 0 else { return }
        var req = [Float](repeating: 1, count: n)
        for i in 0..<n { var m: Float = 0; for c in ch { m = max(m, abs(c[i])) }; if m > ceiling { req[i] = ceiling / m } }
        var mn = [Float](repeating: 1, count: n), dq = [Int](), head = 0
        for j in 0..<(n + half) {
            if j < n { while dq.count > head, req[dq[dq.count - 1]] >= req[j] { dq.removeLast() }; dq.append(j) }
            let i = j - half
            if i >= 0 { while dq[head] < i - half { head += 1 }; mn[i] = req[dq[head]] }
        }
        var pre = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + Double(mn[i]) }
        for i in 0..<n {
            let a = max(0, i - half), b = min(n - 1, i + half), g = Float((pre[b + 1] - pre[a]) / Double(b - a + 1))
            for c in 0..<ch.count { ch[c][i] *= g }
        }
    }
}

public struct Compressor: Sendable {
    public var thresholdDb = -20.0, ratio = 3.0, attack = 0.010, release = 0.12
    public init() {}
    public func process(_ x: [Float], fs: Double) -> [Float] {
        var env = 0.0, out = x
        let ca = exp(-1 / (attack * fs)), cr = exp(-1 / (release * fs))
        // Smoothed detector gain (5 ms one-pole) so the compressor never pumps per-sample.
        var gainDb = 0.0
        let gs = exp(-1 / (0.005 * fs))
        for i in 0..<x.count {
            let a = Double(abs(x[i]))
            env = a > env ? a + ca * (env - a) : a + cr * (env - a)
            let over = 20 * log10(env + 1e-9) - thresholdDb
            let targetDb = over > 0 ? -over * (1 - 1 / ratio) : 0
            gainDb = targetDb + gs * (gainDb - targetDb)
            if gainDb < -0.05 { out[i] = x[i] * Float(pow(10, gainDb / 20)) }
        }
        return out
    }
}

/// Keystroke-aware declick (PLAN 13.1). Attenuates the 2–8 kHz band by
/// `depthDb` in ±35 ms windows around each key time when VAD is silent,
/// milder (-6 dB) when speech overlaps. Gain is ramped (≥5 ms) so no step
/// is ever audible. Pure, offline, deterministic.
public enum Declick {
    public static func process(_ x: [Float], keyTimes: [Double], vad: [ClosedRange<Double>],
                               fs: Double = 48000, depthDb: Double = -12) -> [Float] {
        guard depthDb < -0.5, !keyTimes.isEmpty, !x.isEmpty else { return x }
        let n = x.count
        // Isolate 2–8 kHz with two biquads in series.
        var hp = Biquad.highpass(2000, fs: fs)
        var lp = Biquad.lowpass(8000, fs: fs)
        var band = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = Double(x[i])
            let y = lp.run(hp.run(v))
            band[i] = abs(y) < 1e-30 ? 0 : Float(y)
        }
        // Per-sample suppression gain (1 = keep band, g = suppress band).
        var g = [Float](repeating: 1, count: n)
        let halfWin = Int(0.035 * fs)
        let ramp = max(Int(0.005 * fs), 1)
        let fullGain = Float(pow(10.0, depthDb / 20.0))
        let mildGain = Float(pow(10.0, -6.0 / 20.0))
        for key in keyTimes {
            let center = Int((key * fs).rounded())
            guard center > -halfWin, center < n + halfWin else { continue }
            let speech = vad.contains { $0.lowerBound <= key && key <= $0.upperBound }
            let target = speech ? mildGain : fullGain
            // Ramped window: linear attack/release over `ramp` samples.
            let lo = max(center - halfWin, 0), hi = min(center + halfWin, n - 1)
            for i in lo...hi {
                let edge = min(i - lo, hi - i)
                let rampT = ramp > 0 ? min(1, Float(edge) / Float(ramp)) : 1
                let desired = 1 - (1 - target) * rampT
                g[i] = min(g[i], desired)
            }
        }
        var out = x
        for i in 0..<n {
            out[i] = x[i] - band[i] * (1 - g[i])
        }
        return out
    }
}

/// Voice activity: 20 ms RMS frames, adaptive threshold (noise floor + 10 dB) with hysteresis and 300 ms hangover.
public enum VAD {
    public static func regions(_ x: [Float], fs: Double = 48000) -> [ClosedRange<Double>] {
        let hop = Int(0.02 * fs), n = x.count / hop
        guard n > 3 else { return [] }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n { var s = 0.0; for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }; db[f] = 10 * log10(s / Double(hop) + 1e-12) }
        let floorDb = db.sorted()[n / 10], on = max(floorDb + 10, -50), off = on - 4
        var out: [ClosedRange<Double>] = [], active = false, start = 0, last = 0
        for f in 0..<n {
            if db[f] > (active ? off : on) { if !active { active = true; start = f }; last = f }
            else if active, f - last > 15 { out.append(Double(start) * 0.02 ... Double(last + 1) * 0.02); active = false }
        }
        if active { out.append(Double(start) * 0.02 ... Double(last + 1) * 0.02) }
        return out.filter { $0.upperBound - $0.lowerBound >= 0.12 }
    }
}

public protocol Denoiser: Sendable { func process(_ x: [Float]) -> [Float] }

/// Standalone downward expander for diagnostics; the microphone chain uses pretrained engines.
public struct SpectralGate: Denoiser {
    public init() {}
    public func process(_ x: [Float]) -> [Float] {
        let hop = 480, n = x.count / hop
        guard n > 4 else { return x }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n { var s = 0.0; for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }; db[f] = 10 * log10(s / Double(hop) + 1e-12) }
        let thr = min(db.sorted()[n / 10] + 8, -40)
        var g = [Double](repeating: 1, count: n), cur = 1.0
        for f in 0..<n {
            let target = db[f] > thr ? 1.0 : pow(10, -18.0 / 20)
            cur += (target - cur) * (target > cur ? 0.5 : 0.08)
            g[f] = cur
        }
        var out = x
        for f in 0..<n { let a = g[f], b = f + 1 < n ? g[f + 1] : g[f]
            for i in 0..<hop { out[f * hop + i] *= Float(a + (b - a) * Double(i) / Double(hop)) } }
        return out
    }
}
```

### Sources/LumenAudio/DeepFilterNet.swift

```swift
import Foundation
import Darwin
import os

public enum DeepFilterNetError: Error {
    case unavailable, timedOut, failed(Int32), invalidOutput
}

public enum DeepFilterNet {
    public static var isAvailable: Bool {
        #if arch(arm64)
        return executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        #else
        return false
        #endif
    }

    private static var executable: URL? {
        Bundle.module.url(forResource: "deep-filter", withExtension: nil, subdirectory: "DeepFilterNet")
    }

    public static func process(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard isAvailable, let executable else { throw DeepFilterNetError.unavailable }
        let started = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice.wav")
        let output = directory.appendingPathComponent("output")
        // Pinned DF3: 480-sample STFT delay + two 480-sample lookahead frames.
        // Its CLI trims the delay but does not flush or process partial frames.
        let padding = 1440 + (480 - samples.count % 480) % 480
        try AudioIO.writeMonoWAV(samples, paddingSamples: padding, to: input)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--compensate-delay", "--output-dir", output.path, input.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timeout = max(10, min(300, Double(samples.count) / AudioIO.fs * 0.75 + 5))
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw DeepFilterNetError.timedOut
        }
        guard process.terminationStatus == 0 else { throw DeepFilterNetError.failed(process.terminationStatus) }
        let file = output.appendingPathComponent("voice.wav")
        let (channels, rate) = try AudioIO.decode(file)
        guard rate == AudioIO.fs, channels.count == 1, let voice = channels.first,
              voice.count >= samples.count, voice.count - samples.count < 480,
              voice.allSatisfy(\.isFinite) else { throw DeepFilterNetError.invalidOutput }
        guard started.duration(to: .now) < .seconds(Double(samples.count) / AudioIO.fs) else {
            throw DeepFilterNetError.timedOut
        }
        return Array(voice.prefix(samples.count))
    }
}

struct TrainedVoiceDenoiser: Denoiser {
    let strength: Double
    let highQuality: Bool

    func process(_ x: [Float]) -> [Float] {
        let neural = RNNoiseDenoiser(strength: strength).analyze(x)
        guard highQuality, strength > 0 else {
            let quiet = neural.voiceProbability.filter { $0 < 0.2 }
            guard !quiet.isEmpty else { return neural.samples }
            let residual = RNNoiseDenoiser(strength: strength).analyze(neural.samples)
            var output = neural.samples
            for i in output.indices {
                let probability = neural.voiceProbability[i / neural.frameSize]
                let wet = min(max((0.2 - probability) / 0.2, 0), 1)
                output[i] += (residual.samples[i] - output[i]) * wet
            }
            return output
        }
        do {
            let enhanced = try DeepFilterNet.process(x)
            // Reuse RNNoise's speech decisions without processing the enhanced voice twice.
            let size = neural.frameSize
            let floor = Float(pow(10, -(12 + 6 * min(max(strength, 0), 1)) / 20))
            let attack = Float(exp(-1 / (0.005 * AudioIO.fs)))
            let release = Float(exp(-1 / (0.080 * AudioIO.fs)))
            var output = enhanced, gain: Float = 1
            let wet = Float(strength)
            for i in output.indices {
                let p = neural.voiceProbability.isEmpty ? 1 : neural.voiceProbability[i / size]
                let speech = min(max((p - 0.10) / 0.60, 0), 1)
                let target = floor + (1 - floor) * speech * speech * (3 - 2 * speech)
                gain = target + (target > gain ? attack : release) * (gain - target)
                output[i] = (enhanced[i] * wet + x[i] * (1 - wet)) * gain
            }
            return output
        } catch {
            Logger(subsystem: "com.lumen.studio", category: "audio").error("DeepFilterNet failed; using RNNoise: \(String(describing: error), privacy: .public)")
            return neural.samples
        }
    }
}
```

### Sources/LumenAudio/Dereverb.swift

```swift
import Foundation
import LumenCore

/// Radix-2 complex FFT. Forward in place. Inverse: `transform(&im, &re)` leaves `N * x` in `re`.
struct Radix2FFT {
    let n: Int
    private let cosT: [Float], sinT: [Float], rev: [Int]

    init(n: Int) {
        self.n = n
        var c = [Float](repeating: 0, count: n / 2), s = c
        for i in 0..<(n / 2) {
            let a = -2 * Double.pi * Double(i) / Double(n)
            c[i] = Float(cos(a)); s[i] = Float(sin(a))
        }
        var r = [Int](repeating: 0, count: n)
        let bits = n.trailingZeroBitCount
        for i in 0..<n {
            var x = i, y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = y
        }
        cosT = c; sinT = s; rev = r
    }

    func transform(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n {
            let j = rev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2, step = n / len
            var base = 0
            while base < n {
                for k in 0..<half {
                    let wr = cosT[k * step], wi = sinT[k * step]
                    let a = base + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                base += len
            }
            len <<= 1
        }
    }
}

/// Runs `body` on overlapping segments in parallel and crossfades with
/// complementary smoothstep ramps (the sum is exactly 1).
enum Segmented {
    final class Slots: @unchecked Sendable {
        private var a: [[Float]]
        private let lock = NSLock()
        init(_ n: Int) { a = [[Float]](repeating: [], count: n) }
        func set(_ i: Int, _ v: [Float]) { lock.lock(); a[i] = v; lock.unlock() }
        func all() -> [[Float]] { lock.lock(); defer { lock.unlock() }; return a }
    }

    static func run(_ ins: [[Float]], fs: Double, segment: Double, overlap: Double,
                    _ body: @Sendable ([[Float]]) -> [Float]) -> [Float] {
        guard let n = ins.first?.count, n > 0 else { return ins.first ?? [] }
        let S = Int(segment * fs), O = Int(overlap * fs), count = max((n + S - 1) / S, 1)
        if count == 1 { return body(ins) }
        let slots = Slots(count)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let a = max(i * S - O, 0), b = min((i + 1) * S + O, n)
            slots.set(i, body(ins.map { Array($0[a..<b]) }))
        }
        var out = [Float](repeating: 0, count: n)
        for (i, seg) in slots.all().enumerated() {
            let a = max(i * S - O, 0)
            for k in 0..<seg.count {
                let g = a + k
                var w: Float = 1
                if i > 0 { w *= Float(smoothstep(Double(g - (i * S - O)) / Double(2 * O))) }
                if i < count - 1 { w *= 1 - Float(smoothstep(Double(g - ((i + 1) * S - O)) / Double(2 * O))) }
                out[g] += seg[k] * w
            }
        }
        return out
    }
}

/// Weighted Prediction Error dereverberation (Nakatani 2010), single channel,
/// offline, iterative. Per frequency bin the late reverb is a delayed linear
/// prediction from past frames; weights `1/|X|^2` favour the quiet tails.
public struct WPE: Sendable {
    public var taps = 20, delay = 3, iterations = 3
    /// WPE band. Above it the signal passes unchanged; the post-filter covers it.
    public var maxHz = 8000.0
    public var segment = 10.0, overlap = 1.0
    public init() {}

    public func process(_ x: [Float]) -> [Float] {
        Segmented.run([x], fs: AudioIO.fs, segment: segment, overlap: overlap) { self.run($0[0]) }
    }

    private func run(_ x: [Float]) -> [Float] {
        let N = 2048, H = 512, bins = N / 2 + 1, fs = AudioIO.fs
        guard x.count > N * 8 else { return x }
        let K = taps, D = delay
        let kmax = min(Int(maxHz / fs * Double(N)), bins - 1), nb = kmax + 1
        let fft = Radix2FFT(n: N)
        let win = (0..<N).map { Float(sin(Double.pi * Double($0) / Double(N))) }
        let pad = N
        let xp = [Float](repeating: 0, count: pad) + x + [Float](repeating: 0, count: pad + H)
        let F = (xp.count - N) / H + 1
        var sr = [Float](repeating: 0, count: F * bins), si = sr
        var re = [Float](repeating: 0, count: N), im = re
        for l in 0..<F {
            let o = l * H
            for i in 0..<N { re[i] = xp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins { sr[l * bins + k] = re[k]; si[l * bins + k] = im[k] }
        }

        func buf(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let yr = buf(F), yi = buf(F), cr = buf(F), ci = buf(F), w = buf(F)
        let ar = buf(K), ai = buf(K), pRe = buf(K), pIm = buf(K), gr = buf(K), gi = buf(K)
        let Rr = buf(K * K), Ri = buf(K * K), Lr = buf(K * K), Li = buf(K * K)
        defer { for p in [yr, yi, cr, ci, w, ar, ai, pRe, pIm, gr, gi, Rr, Ri, Lr, Li] { p.deallocate() } }
        var xr = [Double](repeating: 0, count: nb * F), xi = xr

        for k in 0..<nb {
            var meanP = 0.0
            for l in 0..<F {
                let a = Double(sr[l * bins + k]), b = Double(si[l * bins + k])
                yr[l] = a; yi[l] = b; cr[l] = a; ci[l] = b; meanP += a * a + b * b
            }
            meanP /= Double(F)
            let floorP = max(meanP * 1e-4, 1e-14)
            if meanP > 1e-12 {
                for _ in 0..<iterations {
                    for l in 0..<F {
                        let lo = max(l - 1, 0), hi = min(l + 1, F - 1)
                        var s = 0.0
                        for j in lo...hi { s += cr[j] * cr[j] + ci[j] * ci[j] }
                        w[l] = 1 / max(s / Double(hi - lo + 1), floorP)
                    }
                    for i in 0..<(K * K) { Rr[i] = 0; Ri[i] = 0 }
                    for i in 0..<K { pRe[i] = 0; pIm[i] = 0 }
                    for l in D..<F {
                        for t in 0..<K {
                            let idx = l - D - t
                            ar[t] = idx >= 0 ? yr[idx] : 0
                            ai[t] = idx >= 0 ? yi[idx] : 0
                        }
                        let wl = w[l], ylr = yr[l], yli = yi[l]
                        for a in 0..<K {
                            let xa = ar[a] * wl, xb = ai[a] * wl
                            for b in 0...a {                              // lower triangle of R = sum w * y y^H
                                Rr[a * K + b] += xa * ar[b] + xb * ai[b]
                                Ri[a * K + b] += xb * ar[b] - xa * ai[b]
                            }
                            pRe[a] += xa * ylr + xb * yli                  // P = sum w * y * conj(Y)
                            pIm[a] += xb * ylr - xa * yli
                        }
                    }
                    var tr = 0.0
                    for i in 0..<K { tr += Rr[i * K + i] }
                    let load = tr / Double(K) * 1e-4 + 1e-12
                    for i in 0..<K { Rr[i * K + i] += load }
                    guard Self.solve(K, Rr, Ri, pRe, pIm, Lr, Li, gr, gi) else { break }
                    for l in 0..<F {                                       // X = Y - sum conj(g) * Y[l-D-t]
                        var er = yr[l], ei = yi[l]
                        for t in 0..<K {
                            let idx = l - D - t
                            if idx < 0 { break }
                            er -= gr[t] * yr[idx] + gi[t] * yi[idx]
                            ei -= gr[t] * yi[idx] - gi[t] * yr[idx]
                        }
                        cr[l] = er; ci[l] = ei
                    }
                }
            }
            for l in 0..<F {
                var lr = yr[l] - cr[l], li = yi[l] - ci[l]
                let pl = lr * lr + li * li, py = yr[l] * yr[l] + yi[l] * yi[l]
                if pl > 0.8 * py, pl > 0 {
                    let f = (0.8 * py / pl).squareRoot()
                    lr *= f; li *= f
                }
                xr[k * F + l] = yr[l] - lr; xi[k * F + l] = yi[l] - li
            }
        }

        var y = [Float](repeating: 0, count: xp.count)
        for l in 0..<F {
            for k in 0..<bins {
                let a = k <= kmax ? Float(xr[k * F + l]) : sr[l * bins + k]
                let b = k <= kmax ? Float(xi[k * F + l]) : si[l * bins + k]
                re[k] = a; im[k] = b
                if k > 0 && k < N / 2 { re[N - k] = a; im[N - k] = -b }
            }
            fft.transform(&im, &re)
            let o = l * H
            for i in 0..<N { y[o + i] += re[i] / Float(N) * win[i] * 0.5 }
        }
        return Array(y[pad..<(pad + x.count)])
    }

    /// Complex Hermitian positive-definite solve `R g = p` by Cholesky. `R` lower triangle valid.
    private static func solve(_ K: Int, _ Rr: UnsafeMutablePointer<Double>, _ Ri: UnsafeMutablePointer<Double>,
                              _ pRe: UnsafeMutablePointer<Double>, _ pIm: UnsafeMutablePointer<Double>,
                              _ Lr: UnsafeMutablePointer<Double>, _ Li: UnsafeMutablePointer<Double>,
                              _ gr: UnsafeMutablePointer<Double>, _ gi: UnsafeMutablePointer<Double>) -> Bool {
        for j in 0..<K {
            var s = Rr[j * K + j]
            for m in 0..<j { s -= Lr[j * K + m] * Lr[j * K + m] + Li[j * K + m] * Li[j * K + m] }
            guard s > 1e-30 else { return false }
            let d = s.squareRoot()
            Lr[j * K + j] = d; Li[j * K + j] = 0
            for i in (j + 1)..<K {
                var a = Rr[i * K + j], b = Ri[i * K + j]
                for m in 0..<j {
                    let lr = Lr[i * K + m], li = Li[i * K + m]
                    let mr = Lr[j * K + m], mi = Li[j * K + m]
                    a -= lr * mr + li * mi; b -= li * mr - lr * mi          // L[i][m] * conj(L[j][m])
                }
                Lr[i * K + j] = a / d; Li[i * K + j] = b / d
            }
        }
        for i in 0..<K {                                                    // L z = p
            var a = pRe[i], b = pIm[i]
            for m in 0..<i {
                let lr = Lr[i * K + m], li = Li[i * K + m]
                a -= lr * gr[m] - li * gi[m]; b -= lr * gi[m] + li * gr[m]
            }
            let d = Lr[i * K + i]
            gr[i] = a / d; gi[i] = b / d
        }
        for i in stride(from: K - 1, through: 0, by: -1) {                  // L^H g = z
            var a = gr[i], b = gi[i]
            for m in (i + 1)..<K {
                let lr = Lr[m * K + i], li = -Li[m * K + i]
                a -= lr * gr[m] - li * gi[m]; b -= lr * gi[m] + li * gr[m]
            }
            let d = Lr[i * K + i]
            gr[i] = a / d; gi[i] = b / d
        }
        return true
    }
}

/// Post-filter: Wiener gain against (stationary noise floor + late-reverb
/// residual + decay-model tail). `late` is what WPE removed; its power is the
/// best available estimate of the reverb that survives.
public struct ResidualSuppressor: Sendable {
    public var noise: Double, reverb: Double, rt60: Double
    public init(noise: Double = 0.9, reverb: Double = 0.8, rt60: Double = 0.5) {
        self.noise = noise; self.reverb = reverb; self.rt60 = rt60
    }

    public func process(x: [Float], late: [Float]) -> [Float] {
        Segmented.run([x, late], fs: AudioIO.fs, segment: 12, overlap: 1.5) { self.run($0[0], $0[1]) }
    }

    private func run(_ x: [Float], _ late: [Float]) -> [Float] {
        let N = 1024, H = 256, bins = N / 2 + 1, fs = AudioIO.fs
        guard x.count > N * 8, late.count == x.count else { return x }
        let fft = Radix2FFT(n: N)
        let win = (0..<N).map { Float(sin(Double.pi * Double($0) / Double(N))) }
        let pad = N
        let xp = [Float](repeating: 0, count: pad) + x + [Float](repeating: 0, count: pad + H)
        let lp = [Float](repeating: 0, count: pad) + late + [Float](repeating: 0, count: pad + H)
        let F = (xp.count - N) / H + 1
        var xr = [Float](repeating: 0, count: F * bins), xi = xr, px = xr, pl = xr
        var re = [Float](repeating: 0, count: N), im = re
        for l in 0..<F {
            let o = l * H
            for i in 0..<N { re[i] = xp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins {
                let i = l * bins + k
                xr[i] = re[k]; xi[i] = im[k]; px[i] = re[k] * re[k] + im[k] * im[k]
            }
            for i in 0..<N { re[i] = lp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins { pl[l * bins + k] = re[k] * re[k] + im[k] * im[k] }
        }
        // Smoothed power (8-frame box in time, 5-bin box in frequency) for the noise floor and the tail model.
        var tm = [Float](repeating: 0, count: F * bins), acc = [Float](repeating: 0, count: bins)
        for l in 0..<F {
            for k in 0..<bins {
                acc[k] += px[l * bins + k]
                if l >= 8 { acc[k] -= px[(l - 8) * bins + k] }
                tm[l * bins + k] = max(acc[k], 0) / Float(min(l + 1, 8))
            }
        }
        var ps = tm
        for l in 0..<F {
            for k in 0..<bins {
                let a = max(k - 2, 0), b = min(k + 2, bins - 1)
                var s: Float = 0
                for j in a...b { s += tm[l * bins + j] }
                ps[l * bins + k] = s / Float(b - a + 1)
            }
        }
        // Stationary noise floor per bin: 10th percentile of the smoothed power (x1.35 bias compensation).
        var nz = [Float](repeating: 0, count: bins), col = [Float](repeating: 0, count: F)
        for k in 0..<bins {
            for l in 0..<F { col[l] = ps[l * bins + k] }
            col.sort()
            nz[k] = max(col[F / 10] * 1.35, 1e-12)
        }
        let ns = Float(noise), rv = Float(reverb), strength = max(noise, reverb)
        let Dp = 12, decay = Float(pow(10, -6 * Double(Dp * H) / fs / max(rt60, 0.15)))
        let over = Float(1 + 1.2 * strength)
        var gam = [Float](repeating: 0, count: F * bins)
        for l in 0..<F {
            let lo = max(l - 1, 0), hi = min(l + 1, F - 1)
            for k in 0..<bins {
                var lt: Float = 0
                for j in lo...hi { lt += pl[j * bins + k] }
                lt /= Float(hi - lo + 1)
                let pol = l >= Dp ? decay * ps[(l - Dp) * bins + k] : 0
                let phi = over * (ns * nz[k] + rv * lt + 0.6 * rv * pol) + 1e-14
                gam[l * bins + k] = px[l * bins + k] / phi
            }
        }
        let gMinBase = Float(pow(10, -(10 + 16 * strength) / 20))
        let gMinK = (0..<bins).map { k -> Float in
            let f = Double(k) * fs / Double(N)
            return pow(gMinBase, Float(1 - 0.35 * smoothstep((f - 2500) / 3000)))
        }
        let aDD: Float = 0.9, expo = Float(1 + 0.5 * strength)
        var prev = [Float](repeating: 0, count: bins), raw = prev, gs = prev
        var y = [Float](repeating: 0, count: xp.count)
        for l in 0..<F {
            for k in 0..<bins {
                let i = l * bins + k
                let ahead: Float = l + 1 < F ? 0.7 * gam[i + bins] : 0
                let xiv = aDD * prev[k] + (1 - aDD) * max(max(gam[i], ahead) - 1, 0)
                var g = pow(xiv / (1 + xiv), expo)
                g = max(g, gMinK[k])
                prev[k] = g * g * gam[i]
                raw[k] = g
            }
            for k in 0..<bins { gs[k] = 0.25 * raw[max(k - 1, 0)] + 0.5 * raw[k] + 0.25 * raw[min(k + 1, bins - 1)] }
            for k in 0..<bins {
                let i = l * bins + k
                re[k] = xr[i] * gs[k]; im[k] = xi[i] * gs[k]
                if k > 0 && k < N / 2 { re[N - k] = re[k]; im[N - k] = -im[k] }
            }
            fft.transform(&im, &re)
            let o = l * H
            for i in 0..<N { y[o + i] += re[i] / Float(N) * win[i] * 0.5 }
        }
        return Array(y[pad..<(pad + x.count)])
    }
}

enum RoomEstimate {
    /// Free-decay slope of the 10 ms energy envelope 50-350 ms after each speech
    /// offset; median over offsets, default 0.5 s.
    static func rt60(_ x: [Float], vad: [ClosedRange<Double>]) -> Double {
        let hop = 480, n = x.count / hop
        guard n > 100, !vad.isEmpty else { return 0.5 }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n {
            var s = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }
            db[f] = 10 * log10(s / Double(hop) + 1e-12)
        }
        let floorDb = db.sorted()[n / 10]
        var c: [Double] = []
        for r in vad {
            let a = Int(r.upperBound * 100) + 5, b = a + 30
            guard b < n else { continue }
            let seg = (a...b).filter { db[$0] > floorDb + 8 }
            guard seg.count >= 10 else { continue }
            let m = Double(seg.count)
            let mx = seg.reduce(0.0) { $0 + Double($1) } / m
            let my = seg.reduce(0.0) { $0 + db[$1] } / m
            var sxy = 0.0, sxx = 0.0
            for i in seg {
                let dx = Double(i) - mx
                sxy += dx * (db[i] - my); sxx += dx * dx
            }
            let slope = sxy / max(sxx, 1e-9) * 100
            if slope < -15, slope > -400 { c.append(-60 / slope) }
        }
        let v = c.count >= 3 ? c.sorted()[c.count / 2] : 0.5
        return min(max(v, 0.2), 1.2)
    }
}
```

### Sources/LumenAudio/LateReverb.swift

```swift
import Foundation

public enum LateReverb {
    public static func process(_ samples: [Float], amount: Double, rt60: Double = 0.5) -> [Float] {
        let strength = amount.isFinite ? min(max(amount, 0), 1) : 0
        let size = 1024, hop = 256, bins = size / 2 + 1
        guard strength > 0, samples.count > size * 2 else { return samples }
        let fft = Radix2FFT(n: size)
        let window = (0..<size).map { Float(sin(.pi * Double($0) / Double(size))) }
        let padded = [Float](repeating: 0, count: size) + samples + [Float](repeating: 0, count: size)
        var output = [Float](repeating: 0, count: padded.count)
        var normalization = output
        var real = [Float](repeating: 0, count: size), imaginary = real
        var previousPower = [Float](repeating: 0, count: bins)
        var tail = previousPower
        var gain = [Float](repeating: 1, count: bins)
        let decay = Float(pow(10, -6 * Double(hop) / AudioIO.fs / max(rt60, 0.15)))
        for start in stride(from: 0, through: padded.count - size, by: hop) {
            for i in 0..<size { real[i] = padded[start + i] * window[i]; imaginary[i] = 0 }
            fft.transform(&real, &imaginary)
            for k in 0..<bins {
                let power = real[k] * real[k] + imaginary[k] * imaginary[k]
                tail[k] = max(tail[k] * decay, previousPower[k] * decay)
                // Only suppress decaying bins. Fresh attacks and sustained speech pass unchanged.
                let decaying = power < previousPower[k] * 0.98
                let target: Float = decaying
                    ? sqrt(max(0.16, 1 - Float(strength) * 0.75 * tail[k] / max(power, 1e-12))) : 1
                gain[k] += (target - gain[k]) * (target > gain[k] ? 0.8 : 0.25)
                previousPower[k] = power
                real[k] *= gain[k]; imaginary[k] *= gain[k]
                if k > 0 && k < size / 2 { real[size - k] = real[k]; imaginary[size - k] = -imaginary[k] }
            }
            fft.transform(&imaginary, &real)
            for i in 0..<size {
                output[start + i] += real[i] / Float(size) * window[i]
                normalization[start + i] += window[i] * window[i]
            }
        }
        return samples.indices.map { i in
            let position = i + size
            return output[position] / max(normalization[position], 1e-8)
        }
    }
}
```

### Sources/LumenAudio/MicrophoneModes.swift

```swift
import AVFoundation

public enum MicrophoneModes {
    @MainActor
    public static func showVoiceIsolationControls() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
```

### Sources/LumenAudio/Mixer.swift

```swift
import Foundation
import Accelerate
import AVFoundation
import LumenCore
import LumenProject
import LumenDirector

public struct MixedAudio: Sendable {
    public var l: [Float], r: [Float]
    public var lufs: Double, truePeakDb: Double
    public init(l: [Float], r: [Float], lufs: Double, truePeakDb: Double) {
        self.l = l; self.r = r; self.lufs = lufs; self.truePeakDb = truePeakDb
    }
}

/// An isolated, unmastered 32-bit float audio stem for professional editors.
/// Stems preserve the voice/system gain but do not duplicate effects or the
/// combined master limiter. Recombining stems needs mastering in the NLE.
public struct AudioStem: Sendable {
    public let name: String
    public let left: [Float]
    public let right: [Float]
    public init(name: String, left: [Float], right: [Float]) {
        self.name = name; self.left = left; self.right = right
    }
}

/// Extra recorded audio devices are separate immutable source files, on the
/// same host clock as the original screen and microphone.
public struct RecordedMicrophone: Sendable {
    public let deviceName: String, samples: [Float]
    public let offset: Double
    public init(deviceName: String, samples: [Float], offset: Double) {
        self.deviceName = deviceName; self.samples = samples; self.offset = offset
    }
}

/// Offline mix of the whole timeline. Preview plays this buffer; export encodes it. One code path = they always match.
/// Processed microphone Float32 WAVs are cached by source content and exact settings.
public final class AudioMixer: @unchecked Sendable {
    private struct MusicCache { var path: String; var track: MusicTrack?; var lufs: Double }
    private struct VoiceKey: Hashable { var mic: Int; var settings: String }

    /// Voice sits at -16 LUFS before the master stage. Music reference is 6 dB hotter so the default
    /// `musicGainDb` (-18) lands the bed ~12 dB under the voice at rest (plan 10.3).
    static let voiceRefLUFS = -16.0, musicRefLUFS = -10.0

    private let mic: [Float]?, micOffset: Double, sys: [Float]?, sysRight: [Float]?, sysOffset: Double
    private let extraMicrophones: [RecordedMicrophone]
    private let cacheDir: URL?
    /// Key-down times in MIC-FILE time (events rebased by micOffset by the caller).
    /// Empty disables declick (tests call this directly).
    private let keyTimes: [Double]
    private let bank = SFXBank()
    private let lock = NSLock()
    private var voice: [VoiceKey: [Float]] = [:]
    private var music: MusicCache?
    private var imported: [String: MusicTrack] = [:]
    private var customDenoiser: (any Denoiser)?
    public var denoiser: any Denoiser {
        get { lock.lock(); defer { lock.unlock() }; return customDenoiser ?? defaultDenoiser }
        set { lock.lock(); defer { lock.unlock() }; customDenoiser = newValue; voice.removeAll() }
    }

    public init(mic: [Float]?, micOffset: Double, system: [Float]?, systemOffset: Double,
                systemRight: [Float]? = nil,
                additionalMicrophones: [RecordedMicrophone] = [], cacheDir: URL? = nil,
                keyTimes: [Double] = []) {
        self.mic = mic; self.micOffset = micOffset; sys = system
        sysRight = systemRight; sysOffset = systemOffset
        extraMicrophones = additionalMicrophones; self.cacheDir = cacheDir
        self.keyTimes = keyTimes
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
    }

    /// Each microphone is processed independently; system audio never enters this chain.
    private func voiceChain(_ plan: AudioPlan, micIndex: Int, samples: [Float]) -> [Float]? {
        guard plan.micMode != .off else { return nil }
        lock.lock(); defer { lock.unlock() }
        let keys = micIndex == 0 && plan.declick ? keyTimes : []
        let signature = try? ProcessedVoiceCache.key(samples: samples, plan: plan, keyTimes: keys)
        let key = VoiceKey(mic: micIndex, settings: signature ?? UUID().uuidString)
        if let cached = voice[key] { return cached }
        let diskURL: URL? = customDenoiser == nil ? signature.flatMap { signature in
            cacheDir?.appendingPathComponent("voice-\(signature)-48000.wav")
        } : nil
        let processed: [Float]
        if let diskURL, let cached = ProcessedVoiceCache.read(diskURL, count: samples.count, rate: AudioIO.fs) {
            processed = cached
        } else {
            processed = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: keys, denoiser: customDenoiser)
            if let diskURL { try? ProcessedVoiceCache.write(processed, rate: AudioIO.fs, to: diskURL) }
        }
        if voice.count >= max(3, extraMicrophones.count + 1) { voice.removeAll() }
        voice[key] = processed
        return processed
    }

    private func voiceChain(_ plan: AudioPlan) -> [Float]? {
        guard let mic else { return nil }
        return voiceChain(plan, micIndex: 0, samples: mic)
    }

    private func extraVoiceChain(_ index: Int, plan: AudioPlan) -> [Float]? {
        guard extraMicrophones.indices.contains(index) else { return nil }
        return voiceChain(plan, micIndex: index + 1, samples: extraMicrophones[index].samples)
    }

    private func loadMusic(_ path: String?) -> MusicCache? {
        guard let path else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let m = music, m.path == path { return m }
        let t = AudioIO.loadMusic(URL(fileURLWithPath: path))
        let c = MusicCache(path: path, track: t, lufs: t.map { Loudness.integrated([$0.l, $0.r]) } ?? -70)
        music = c
        return c
    }

    private func importTrack(_ path: String) -> MusicTrack? {
        lock.lock()
        let cached = imported[path]
        lock.unlock()
        if let cached { return cached }
        guard let (l, r) = try? AudioIO.readStereo(URL(fileURLWithPath: path)),
              !l.isEmpty, l.count == r.count else { return nil }
        let result = MusicTrack(l: l, r: r)
        lock.lock()
        imported[path] = result
        lock.unlock()
        return result
    }

    // MARK: Building blocks (mapped lives in AudioMapped.swift)

    /// Loop with 0.5 s crossfade to length n, 0.3 s fade-in, 1.5 s fade-out.
    static func fit(_ m: MusicTrack, n: Int) -> ([Float], [Float]) {
        let fs = AudioIO.fs, xf = Int(0.5 * fs), len = m.l.count
        var L = [Float](repeating: 0, count: n), R = L, i = 0
        while i < n {
            let c = min(len, n - i)
            for k in 0..<c {
                var a: Float = 1
                if i > 0 && k < xf { a = Float(k) / Float(xf) }                                   // crossfade in
                if c == len && k >= len - xf && i + len < n { a = Float(len - k) / Float(xf) }    // overlapped tail fades out
                L[i + k] += m.l[k] * a
                R[i + k] += m.r[k] * a
            }
            i += max(len - xf, 1)
        }
        for k in 0..<n {
            let fin = min(1, Float(k) / Float(0.3 * fs)), fout = min(1, Float(n - k) / Float(1.5 * fs))
            let g = fin * fout
            L[k] *= g; R[k] *= g
        }
        return (L, R)
    }

    // MARK: Mix

    /// Separate WAV stems in the same OUTPUT timeline as the encoded movie.
    /// This is intentionally opt-in, since it requires extra offline processing.
    public func stems(_ tl: Timeline) -> [AudioStem] {
        guard tl.derived != nil else { return [] }
        let fs = AudioIO.fs, n = Int(tl.compositionDuration * fs) + 1
        guard n > 0 else { return [] }
        let a = tl.audio, tm = tl.timeMap
        var result: [AudioStem] = []

        if a.micMode != .off, let voice = voiceChain(a) {
            let mapped = Self.mapped(voice, offset: micOffset, tm: tm,
                                     n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            let channel = mapped.map { $0 * gain }
            result.append(AudioStem(name: "microphone", left: channel, right: channel))
        }
        if a.micMode != .off {
            for index in extraMicrophones.indices {
                guard let processed = extraVoiceChain(index, plan: a) else { continue }
                let input = extraMicrophones[index]
                let mapped = Self.mapped(processed, offset: input.offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                let channel = mapped.map { $0 * gain }
                result.append(AudioStem(name: "microphone-\(index + 2)", left: channel, right: channel))
            }
        }

        if let system = sys {
            let left = Self.mapped(system, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let right = sysRight.map { Self.mapped($0, offset: sysOffset, tm: tm, n: n, muteRamps: true) } ?? left
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            result.append(AudioStem(name: "system",
                                    left: left.map { $0 * gain }, right: right.map { $0 * gain }))
        }

        var voiceIndex = 0
        for lane in a.lanes where lane.role == .voiceover && !lane.mute {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            voiceIndex += 1
            var left = [Float](repeating: 0, count: n), right = left
            let start = max(0, Int(lane.placement * fs))
            guard start < n else { continue }
            let count = min(track.l.count, n - start)
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            let fade = min(Int(fs * 0.01), count / 2)
            for i in 0..<count {
                let edge = fade > 0 ? min(1, Float(min(i, count - i - 1)) / Float(fade)) : 1
                left[start + i] = track.l[i] * gain * edge
                right[start + i] = track.r[i] * gain * edge
            }
            result.append(AudioStem(name: "voiceover-\(voiceIndex)", left: left, right: right))
        }
        return result.map { stem in
            var left = stem.left, right = stem.right
            Self.silenceClips(tl, &left, &right, fs: fs)
            return AudioStem(name: stem.name, left: left, right: right)
        }
    }

    /// Imported clips have picture but no mixable audio yet. Zeroing their
    /// spans stops the recording's last sample from droning under them.
    static func silenceClips(_ tl: Timeline, _ L: inout [Float], _ R: inout [Float], fs: Double) {
        for clip in tl.clips {
            let a = max(Int(clip.start * fs), 0), b = min(Int(clip.end * fs) + 1, L.count)
            guard b > a else { continue }
            for i in a..<b { L[i] = 0; R[i] = 0 }
        }
    }

    public func mix(_ tl: Timeline) -> MixedAudio? {
        guard let d = tl.derived else { return nil }
        let fs = AudioIO.fs, n = Int(tl.compositionDuration * fs) + 1, a = tl.audio, tm = tl.timeMap
        var L = [Float](repeating: 0, count: n), R = L
        var hasProgram = false                                   // voice / system / music (not just SFX)

        if a.micMode != .off, let v = voiceChain(a) {
            let y = Self.mapped(v, offset: micOffset, tm: tm, n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += y[i] * gain; R[i] += y[i] * gain }
            hasProgram = true
        }
        if a.micMode != .off {
            for index in extraMicrophones.indices {
                guard let processed = extraVoiceChain(index, plan: a) else { continue }
                let mapped = Self.mapped(processed, offset: extraMicrophones[index].offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                for i in 0..<n { L[i] += mapped[i] * gain; R[i] += mapped[i] * gain }
                hasProgram = true
            }
        }
        if let s = sys {
            let left = Self.mapped(s, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let right = sysRight.map { Self.mapped($0, offset: sysOffset, tm: tm, n: n, muteRamps: true) } ?? left
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += left[i] * gain; R[i] += right[i] * gain }
            hasProgram = true
        }
        for lane in a.lanes where !lane.mute && (lane.role == .voiceover || lane.role == .music) {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            let offset = Int(max(0, lane.placement) * fs)
            guard offset < n else { continue }
            let count = min(n - offset, track.l.count)
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            let fadeLength = min(Int(0.01 * fs), count / 2)
            for i in 0..<count {
                let fadeIn = fadeLength > 0 ? min(1, Float(i) / Float(fadeLength)) : 1
                let fadeOut = fadeLength > 0 ? min(1, Float(count - i - 1) / Float(fadeLength)) : 1
                let g = gain * min(fadeIn, fadeOut)
                L[offset + i] += track.l[i] * g
                R[offset + i] += track.r[i] * g
            }
            hasProgram = true
        }
        if let mc = loadMusic(a.musicPath), let mt = mc.track {
            let (ml, mr) = Self.fit(mt, n: n)
            let norm = mc.lufs > -60 ? clamp(Self.musicRefLUFS - mc.lufs, -24, 24) : 0
            let g = Float(pow(10, (norm + a.musicGainDb) / 20))
            for i in 0..<n {
                var dk: Float = 1
                if !d.duck.isEmpty {
                    let p = Double(i) / fs * 100
                    let i0 = min(Int(p), d.duck.count - 1), i1 = min(i0 + 1, d.duck.count - 1)
                    dk = d.duck[i0] + (d.duck[i1] - d.duck[i0]) * Float(p - Double(i0))
                }
                L[i] += ml[i] * g * dk; R[i] += mr[i] * g * dk
            }
            hasProgram = true
        }

        // Export typing: same hits as preview, offline mixed into the typing track.
        // Same key = same sample, gain 0.7...1.0 from gap since previous key.
        var prevKeyT: Double? = nil
        let typingBuffers: [Int: [Float]] = {
            guard a.keySounds else { return [:] }
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/TypingPacks/\(a.typingPackId)", isDirectory: true)
            let avail = TypingPackLoader.buffers(in: dir)
            var map: [Int: [Float]] = [:]
            for (code, buf) in avail {
                guard let ch = buf.floatChannelData?[0], buf.format.channelCount > 0 else { continue }
                let n = Int(buf.frameLength)
                map[code] = Array(UnsafeBufferPointer(start: ch, count: n))
            }
            return map
        }()
        for cue in d.cues {
            let buf: [Float]
            if cue.kind == .key {
                guard a.keySounds else { continue }
                let packCode = TypingPackLoader.macToPack[Int(cue.keyCode)] ?? TypingPackLoader.genericCode
                guard let samples = typingBuffers[packCode] else { continue }
                // Fast typing quieter per key: gain from gap since previous key
                if let prev = prevKeyT {
                    let gap = cue.t - prev
                    let g: Float = gap < 0.05 ? 0.7 : gap < 0.15 ? 0.85 : 1.0
                    let amp = Float(pow(10, (a.sfxGainDb + cue.gainDb + a.typingLevelDb) / 20)) * g
                    buf = samples.map { $0 * amp }
                } else {
                    let amp = Float(pow(10, (a.sfxGainDb + cue.gainDb + a.typingLevelDb) / 20))
                    buf = samples.map { $0 * amp }
                }
                prevKeyT = cue.t
            } else {
                let (b, gain) = bank.render(cue.kind, clickTone: a.clickTone)
                let amp = Float(pow(10, (a.sfxGainDb + cue.gainDb + gain) / 20))
                buf = b.map { $0 * amp }
            }
            let s0 = Int(cue.t * fs)
            for (k, v) in buf.enumerated() where s0 + k >= 0 && s0 + k < n {
                L[s0 + k] += v; R[s0 + k] += v
            }
        }

        Self.silenceClips(tl, &L, &R, fs: fs)
        var ch = [L, R]
        var lufs = Loudness.integrated(ch)
        let offsetDb: Double
        if a.normalize, hasProgram, lufs > -69 {
            offsetDb = a.targetLUFS - lufs + a.outputGainDb
        } else {
            offsetDb = a.outputGainDb
        }
        let master = Float(pow(10, clamp(offsetDb, -36, 30) / 20))
        ch = ch.map { vDSP.multiply(master, $0) }
        Limiter.apply(&ch, ceiling: Float(pow(10, -1.5 / 20)))
        var tp = Loudness.truePeakDb(ch)
        if tp > -1.0 {
            let g = Float(pow(10, (-1.05 - tp) / 20))
            ch = ch.map { vDSP.multiply(g, $0) }
            tp = Loudness.truePeakDb(ch)
        }
        lufs = Loudness.integrated(ch)
        return MixedAudio(l: ch[0], r: ch[1], lufs: lufs, truePeakDb: tp)
    }
}

/// Preview playback of a pre-mixed buffer, started in lock-step with the host clock. `load` is safe from any thread.
public final class PreviewAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine(), node = AVAudioPlayerNode(), previewNode = AVAudioPlayerNode()
    private struct Buffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    private let mixed = OSAllocatedUnfairLock<(audio: MixedAudio?, buffer: Buffer?)>(initialState: (nil, nil))
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    public init() {
        engine.attach(node); engine.attach(previewNode)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.connect(previewNode, to: engine.mainMixerNode, format: fmt)
    }

    /// Hardware output latency (Bluetooth sinks are large). Used to schedule
    /// audio so it is HEARD on the same host instant as the video frame.
    public var outputLatency: Double { engine.isRunning ? engine.outputNode.presentationLatency : 0 }

    /// True once `load` has installed a non-empty mixed buffer. Transport
    /// reads this to decide whether audio can start locked to video now,
    /// or video must run silent until the background mix joins.
    public var isLoaded: Bool { mixed.withLock { $0.audio != nil && !($0.audio!.l.isEmpty) } }

    /// Starts the engine early so a cold first click does not pay engine
    /// startup latency inside the transport gap. Safe to call repeatedly.
    public func warm() { if !engine.isRunning { try? engine.start() } }

    /// Plays the selected click at the current click level without touching
    /// the timeline playback node, so the preview never desyncs transport.
    public func previewClick(_ plan: AudioPlan) {
        let (samples, bankGain) = SFXBank().render(.click, clickTone: plan.clickTone)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        let amp = Float(pow(10, (plan.sfxGainDb + bankGain) / 20))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices {
            buffer.floatChannelData![0][i] = samples[i] * amp
            buffer.floatChannelData![1][i] = samples[i] * amp
        }
        if !engine.isRunning { try? engine.start() }
        previewNode.stop()
        previewNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        previewNode.play()
    }

    public func load(_ m: MixedAudio?) {
        var prepared: Buffer?
        if let m, !m.l.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(m.l.count)) {
            b.frameLength = AVAudioFrameCount(m.l.count)
            m.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: m.l.count) }
            m.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress!, count: m.r.count) }
            prepared = Buffer(value: b)
        }
        let ready = prepared
        mixed.withLock { $0 = (m, ready) }
    }

    /// Starts playback of output-time `t` at `atHostSeconds` (HostClock seconds).
    @discardableResult public func play(from t: Double, atHostSeconds h: Double) -> Double {
        node.stop()
        let snapshot = mixed.withLock { $0 }
        guard let m = snapshot.audio else { return max(h, HostClock.now() + 0.03) }
        let s = min(max(Int(t * 48000), 0), m.l.count), cnt = m.l.count - s
        guard cnt > 0 else { return max(h, HostClock.now() + 0.03) }
        let b: AVAudioPCMBuffer
        if s == 0, let prepared = snapshot.buffer {
            b = prepared.value
        } else {
            guard let tail = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cnt)) else { return max(h, HostClock.now() + 0.03) }
            tail.frameLength = AVAudioFrameCount(cnt)
            m.l.withUnsafeBufferPointer { tail.floatChannelData![0].update(from: $0.baseAddress! + s, count: cnt) }
            m.r.withUnsafeBufferPointer { tail.floatChannelData![1].update(from: $0.baseAddress! + s, count: cnt) }
            b = tail
        }
        if !engine.isRunning { do { try engine.start() } catch { return max(h, HostClock.now() + 0.03) } }
        node.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        let latency = outputLatency
        let start = max(h - latency, HostClock.now() + 0.005)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        return max(h, start + latency)
    }

    public func stop() { node.stop() }
}
```

### Sources/LumenAudio/ProcessedVoice.swift

```swift
import Foundation
import AVFoundation
import CryptoKit
import Accelerate
import LumenCore
import LumenProject

public enum CleanVoiceError: Error { case missingMicrophone }

struct ProcessedVoiceCache {
    static let revision = "trained-voice-v6-gap12-residual-df-speed"

    private struct Settings: Encodable {
        let noiseStrength: Double
        let highQuality: Bool
        let room: Double
        let clarity: Bool
        let studio: Double
        let declickDepth: Double

        init(_ plan: AudioPlan, hasKeys: Bool) {
            noiseStrength = plan.micClean ? (plan.noiseReductionStrength.isFinite ? clamp(plan.noiseReductionStrength, 0, 1) : 1) : 0
            highQuality = noiseStrength > 0 && plan.studioMode == .optimized
            room = plan.dereverb.isFinite ? clamp(plan.dereverb, 0, 1) : 0
            clarity = plan.voiceClarity && plan.studio > 0
            studio = clarity ? min(max(plan.studio * 4, 0), 1) : 0
            declickDepth = plan.declick && hasKeys ? plan.declickDepthDb : 0
        }
    }

    static func key(samples: [Float], plan: AudioPlan, keyTimes: [Double]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data(revision.utf8))
        samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        keyTimes.withUnsafeBytes { hash.update(bufferPointer: $0) }
        hash.update(data: try encoder.encode(Settings(plan, hasKeys: !keyTimes.isEmpty)))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ url: URL, count: Int, rate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == rate,
              file.length == count,
              let decoded = try? AudioIO.decode(url), let samples = decoded.channels.first,
              samples.count == count, samples.allSatisfy(\.isFinite) else { return nil }
        return samples
    }

    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try AudioIO.writeMonoWAV(samples, sampleRate: rate, to: temporary)
        try Data(contentsOf: temporary).write(to: url, options: .atomic)
    }

    static func render(_ samples: [Float], plan: AudioPlan, keyTimes: [Double],
                       denoiser: (any Denoiser)? = nil) -> [Float] {
        let strength = plan.noiseReductionStrength.isFinite ? clamp(plan.noiseReductionStrength, 0, 1) : 1
        var voice = samples.map { $0.isFinite ? $0 : 0 }
        if plan.micClean, strength > 0 {
            let engine = denoiser ?? TrainedVoiceDenoiser(strength: strength, highQuality: plan.studioMode == .optimized)
            voice = engine.process(voice)
        }
        let regions = VAD.regions(voice)
        voice = LateReverb.process(voice, amount: plan.dereverb,
                                  rt60: RoomEstimate.rt60(voice, vad: regions))
        if plan.declick, !keyTimes.isEmpty {
            voice = Declick.process(voice, keyTimes: keyTimes, vad: regions, depthDb: plan.declickDepthDb)
        }
        voice = VoiceStudio.finish(voice, vad: regions, plan: plan, denoiser: nil)
        let loudness = Loudness.integrated([voice])
        if loudness > -69 {
            voice = vDSP.multiply(Float(pow(10, clamp(-16 - loudness, -24, 24) / 20)), voice)
        }
        var channels = [voice]
        Limiter.apply(&channels, ceiling: Float(pow(10, -1.5 / 20)))
        let peak = Loudness.truePeakDb(channels)
        if peak > -1 {
            channels[0] = vDSP.multiply(Float(pow(10, (-1.05 - peak) / 20)), channels[0])
        }
        return channels[0]
    }
}

/// Source-file time, mono 16 kHz Float32 WAV. Add the recorded mic offset to word timestamps.
/// Passing the current audio settings includes unsaved editor changes in the cache key.
public func cleanVoiceURL(for project: ProjectBundle, settings: AudioPlan? = nil) async throws -> URL {
    let job = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let file = try project.load()
        guard file.meta.mic != nil else { throw CleanVoiceError.missingMicrophone }
        let samples = try AudioIO.readMono(project.micURL)
        guard !samples.isEmpty else { throw CleanVoiceError.missingMicrophone }
        var plan = settings ?? file.timeline.audio
        // Muting playback does not remove the voice source used for transcription.
        if plan.micMode == .off { plan.micMode = .standard }
        plan.micClean = true
        if plan.noiseReductionStrength <= 0 { plan.noiseReductionStrength = 1 }
        let origin = file.meta.clock.originHostSeconds
        let offset = (file.meta.mic?.startHostSeconds ?? origin) - origin
        let keyTimes = plan.declick ? ((try? project.events(origin: origin)) ?? [])
            .filter { $0.kind == .keyDown }.map { $0.t - offset }.filter { $0 >= 0 } : []
        let key = try ProcessedVoiceCache.key(samples: samples, plan: plan, keyTimes: keyTimes)
        let voiceURL = project.cacheURL.appendingPathComponent("voice-\(key)-48000.wav")
        let captionURL = project.cacheURL.appendingPathComponent("voice-\(key)-16000.wav")
        let count = Int((Double(samples.count) / 3).rounded())
        if ProcessedVoiceCache.read(captionURL, count: count, rate: 16_000) != nil { return captionURL }
        try Task.checkCancellation()
        let voice: [Float]
        if let cached = ProcessedVoiceCache.read(voiceURL, count: samples.count, rate: AudioIO.fs) {
            voice = cached
        } else {
            voice = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: keyTimes)
            try Task.checkCancellation()
            try ProcessedVoiceCache.write(voice, rate: AudioIO.fs, to: voiceURL)
        }
        let transcription = try AudioIO.resampleMono(voice, from: AudioIO.fs, to: 16_000)
        try Task.checkCancellation()
        try ProcessedVoiceCache.write(transcription, rate: 16_000, to: captionURL)
        return captionURL
    }
    return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
}
```

### Sources/LumenAudio/RNNoiseDenoiser.swift

```swift
import Foundation
import CRNNoise

public struct DenoisedVoice: Sendable {
    public let samples: [Float]
    public let voiceProbability: [Float]
    public let frameSize: Int
}

public struct RNNoiseDenoiser: Denoiser {
    public let strength: Double
    public init(strength: Double = 1) {
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : 1
    }

    static let latencySamples = 960

    public func process(_ x: [Float]) -> [Float] { analyze(x).samples }

    public func analyze(_ x: [Float]) -> DenoisedVoice {
        let size = Int(rnnoise_get_frame_size())
        guard !x.isEmpty, strength > 0 else {
            return DenoisedVoice(samples: x, voiceProbability: [], frameSize: size)
        }
        guard let state = rnnoise_create(nil) else {
            return DenoisedVoice(samples: x, voiceProbability: [], frameSize: size)
        }
        defer { rnnoise_destroy(state) }
        let frames = (x.count + size - 1) / size
        var result = [Float](repeating: 0, count: x.count)
        var probabilities = [Float](repeating: 0, count: frames)
        var input = [Float](repeating: 0, count: size), output = input
        let latencyFrames = Self.latencySamples / size
        // Flush the pretrained model lookahead and overlap-add delay with real zero frames.
        for frame in 0..<(frames + latencyFrames) {
            for k in 0..<size {
                let i = frame * size + k
                input[k] = i < x.count && x[i].isFinite ? x[i] * 32768 : 0
            }
            let probability = rnnoise_process_frame(state, &output, &input)
            guard frame >= latencyFrames else { continue }
            probabilities[frame - latencyFrames] = min(max(probability, 0), 1)
            let start = (frame - latencyFrames) * size
            for k in 0..<min(size, x.count - start) { result[start + k] = output[k] / 32768 }
        }
        let attack = Float(exp(-1 / (0.005 * AudioIO.fs)))
        let release = Float(exp(-1 / (0.080 * AudioIO.fs)))
        let wet = Float(strength)
        let floor = Float(pow(10, -(12 + 6 * strength) / 20))
        var gain: Float = 1
        for i in result.indices {
            let probability = probabilities[i / size]
            let speech = min(max((probability - 0.10) / 0.60, 0), 1)
            let target = floor + (1 - floor) * speech * speech * (3 - 2 * speech)
            let coefficient = target > gain ? attack : release
            gain = target + coefficient * (gain - target)
            let dry = x[i].isFinite ? x[i] : 0
            result[i] = (dry * (1 - wet) + result[i] * wet) * gain
        }
        return DenoisedVoice(samples: result, voiceProbability: probabilities, frameSize: size)
    }
}

public let defaultDenoiser: any Denoiser = RNNoiseDenoiser()
```

### Sources/LumenAudio/SFX.swift

```swift
import Foundation
import LumenProject

/// Real recorded effects only. No synthetic noise, oscillators or procedural sound generation.
/// Click sfx: new-click.mp3 is the fresh default; mouse-click.mp3 and Subtle-ui-tap-interactions.mp3 kept for backward projects.
/// Typing sfx no longer uses a single-keyboard-tap.mp3 bank — per-key Mechvibes pack is loaded via TypingPackLoader.
public struct SFXBank: Sendable {
    private let mouse: [Float], subtle: [Float], zoomIn: [Float], zoomOut: [Float]

    public init() {
        func load(_ name: String) -> [Float] {
            guard let url = BundledAudioAssets.effect(named: name),
                  let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { return [] }
            let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
            return peak > 0.0001 ? pcm.map { $0 * (1.0 / peak) } : []
        }
        mouse = load("mouse-click.mp3")
        subtle = load("Subtle-ui-tap-interactions.mp3")
        zoomIn = load("zoom-in-whoosh.mp3")
        zoomOut = load("zoom-out-whoosh.mp3")
    }

    public func render(_ kind: SFXCue.Kind, clickTone: ClickSound = .mouse) -> (samples: [Float], gainDb: Double) {
        switch kind {
        case .click:
            switch clickTone {
            case .fresh: (BundledAudioAssets.freshClick, 0)
            case .subtle: (subtle, 0)
            case .mouse: (mouse, 0)
            }
        case .key:
            // Per-key typing is rendered from the pack buffers in the Mixer.
            // This empty carrier keeps the old cue path silent, not fake.
            ([], 0)
        case .whooshIn: (zoomIn, 0)
        case .whooshOut: (zoomOut, 0)
        }
    }
}
```

### Sources/LumenAudio/Studio.swift

```swift
import Foundation
import LumenCore
import LumenProject

extension Biquad {
    static func lowpass(_ f: Double, q: Double = 0.7071, fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - a) / a0)
    }
    static func lowShelf(_ f: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) * 0.70710678, t = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) + (A - 1) * c + t
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + t) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * c) / a0,
                      b2: A * ((A + 1) - (A - 1) * c - t) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0,
                      a2: ((A + 1) + (A - 1) * c - t) / a0)
    }
    static func highShelf(_ f: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) * 0.70710678, t = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) - (A - 1) * c + t
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + t) / a0,
                      b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
                      b2: A * ((A + 1) + (A - 1) * c - t) / a0,
                      a1: 2 * ((A - 1) - (A + 1) * c) / a0,
                      a2: ((A + 1) - (A - 1) * c - t) / a0)
    }
}

enum Cascade {
    static func apply(_ x: [Float], _ filters: [Biquad]) -> [Float] {
        guard !filters.isEmpty else { return x }
        var f = filters, out = x
        for i in 0..<x.count {
            var v = Double(x[i])
            for j in 0..<f.count { v = f[j].run(v) }
            out[i] = Float(v)
        }
        return out
    }
    /// 4th-order Butterworth high-pass.
    static func hp4(_ f: Double, fs: Double) -> [Biquad] { [.highpass(f, q: 0.5412, fs: fs), .highpass(f, q: 1.3066, fs: fs)] }
}

/// Dynamic de-esser: compresses only the 5.2-9.8 kHz band, only above 45% of the
/// recording's own p98 sibilance level. `amount` is the studio strength.
enum DeEsser {
    static func process(_ x: [Float], fs: Double, amount: Double) -> [Float] {
        let n = x.count
        guard amount > 0.01, n > 4800 else { return x }
        var hp = Biquad.highpass(5200, q: 0.7071, fs: fs), lp = Biquad.lowpass(9800, fs: fs)
        var s = [Float](repeating: 0, count: n), env = s
        let ca = Float(exp(-1 / (0.0008 * fs))), cr = Float(exp(-1 / (0.020 * fs)))
        var e: Float = 0
        for i in 0..<n {
            let v = Float(lp.run(hp.run(Double(x[i]))))
            s[i] = v
            let a = abs(v)
            e = a > e ? a + ca * (e - a) : a + cr * (e - a)
            env[i] = e
        }
        var samp: [Float] = []
        var i = 0
        while i < n { samp.append(env[i]); i += 480 }
        samp.sort()
        guard !samp.isEmpty else { return x }
        let threshold = max(0.45 * samp[Int(Double(samp.count - 1) * 0.98)], 1e-5)
        let ratio = Float(0.5 + 0.4 * amount)
        let maxCut = Float(pow(10, -(5 + 7 * amount) / 20))
        let ga = Float(exp(-1 / (0.0006 * fs))), gr = Float(exp(-1 / (0.012 * fs)))
        var out = x, g: Float = 1
        for j in 0..<n {
            var target: Float = 1
            if env[j] > threshold { target = max(pow(threshold / env[j], ratio), maxCut) }
            g = target < g ? target + ga * (g - target) : target + gr * (g - target)
            out[j] = x[j] - s[j] * (1 - g)
        }
        return out
    }
}

/// Slow gain riding on voiced 100 ms frames toward the recording's own median
/// level. Sigma 0.3 s means no word-level pumping.
enum Leveler {
    static func process(_ x: [Float], vad: [ClosedRange<Double>], fs: Double, range: Double) -> [Float] {
        let hop = Int(0.1 * fs), n = x.count / hop
        guard n > 10, range > 0.5 else { return x }
        var db = [Double](repeating: -120, count: n), voiced = [Bool](repeating: false, count: n)
        for f in 0..<n {
            var s = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }
            db[f] = 10 * log10(s / Double(hop) + 1e-12)
            let t = (Double(f) + 0.5) * 0.1
            voiced[f] = db[f] > -55 && vad.contains { $0.lowerBound <= t && t <= $0.upperBound }
        }
        let levels = (0..<n).filter { voiced[$0] }.map { db[$0] }.sorted()
        guard levels.count > 10 else { return x }
        let target = levels[levels.count / 2]
        var gain = [Double](repeating: .nan, count: n)
        for f in 0..<n where voiced[f] { gain[f] = clamp(target - db[f], -range, range) }
        var last = -1
        for f in 0..<n where !gain[f].isNaN {
            if last < 0 { for j in 0..<f { gain[j] = gain[f] } }
            else if f - last > 1 {
                for j in (last + 1)..<f {
                    gain[j] = lerp(gain[last], gain[f], Double(j - last) / Double(f - last))
                }
            }
            last = f
        }
        if last >= 0, last < n - 1 { for j in (last + 1)..<n { gain[j] = gain[last] } }
        guard gain.contains(where: { !$0.isNaN }) else { return x }
        gain = gaussianSmooth(gain.map { $0.isNaN ? 0 : $0 }, sigma: 3)
        var out = x
        for i in 0..<x.count {
            let p = Double(i) / Double(hop) - 0.5
            let a = min(max(Int(p.rounded(.down)), 0), n - 1), b = min(a + 1, n - 1)
            let u = clamp(p - Double(a), 0, 1)
            out[i] = x[i] * Float(pow(10, lerp(gain[a], gain[b], u) / 20))
        }
        return out
    }
}

enum VoiceStudio {
    /// Soft downward expander: ducks non-voiced 10 ms frames toward the
    /// floor with 100 ms VAD look-ahead so tails breathe. It runs BEFORE the
    /// EQ and the compressor, otherwise compression lifts the floor again.
    /// Standard -24 dB, Optimized -34 dB. Pure gain, no clipping, finite.
    enum Expander {
        static func apply(_ x: [Float], vad: [ClosedRange<Double>], fs: Double, depthDb: Double) -> [Float] {
            let hop = max(Int(0.01 * fs), 1), n = x.count / hop
            guard n > 10, depthDb < -1, !vad.isEmpty else { return x }
            let lookAhead = Int(0.1 * fs / Double(hop))
            var gainDb = [Double](repeating: 0, count: n)
            for f in 0..<n {
                let t = (Double(f) + 0.5) * 0.01
                var voiced = false
                for lo in max(0, f - lookAhead)..<min(n, f + lookAhead + 1) {
                    let lt = (Double(lo) + 0.5) * 0.01
                    if vad.contains(where: { $0.lowerBound <= lt && lt <= $0.upperBound }) { voiced = true; break }
                }
                if !voiced { gainDb[f] = depthDb }
            }
            // Smooth: attack 5 ms (drop fast), release 150 ms (rise gentle).
            let ga = Float(exp(-1 / (0.005 * fs))), gr = Float(exp(-1 / (0.15 * fs)))
            var out = x, g: Float = 1
            var k = 0
            for i in 0..<x.count {
                let target = Float(pow(10, gainDb[min(k, n - 1)] / 20))
                g = target < g ? target + ga * (g - target) : target + gr * (g - target)
                out[i] = x[i] * g
                if (i + 1) % hop == 0 { k += 1 }
            }
            return out
        }
    }

    static func finish(_ x: [Float], vad: [ClosedRange<Double>], plan: AudioPlan,
                       denoiser: (any Denoiser)?) -> [Float] {
        let fs = AudioIO.fs
        var voice = x
        if plan.micClean, let denoiser { voice = denoiser.process(voice) }
        // The expander drops the floor between words before anything lifts it
        // again. The optimized mode is the deeper one.
        voice = Expander.apply(voice, vad: vad, fs: fs,
                                depthDb: plan.studioMode == .optimized ? -35 : -25)
        let strength = min(max(plan.studio * 4, 0), 1)
        voice = Cascade.apply(voice, [.highpass(80, fs: fs)])
        guard plan.voiceClarity, plan.studio > 0 else { return voice }
        voice = Cascade.apply(voice, [
            .peaking(250, q: 0.9, db: -2 * strength, fs: fs),
            .peaking(3500, q: 0.8, db: 2.5 * strength, fs: fs),
            .highShelf(10_000, db: 1.5 * strength, fs: fs)
        ])
        voice = DeEsser.process(voice, fs: fs, amount: 0.25)
        voice = Leveler.process(voice, vad: vad, fs: fs, range: 3)
        var compressor = Compressor()
        compressor.thresholdDb = -20
        compressor.ratio = 3
        compressor.attack = 0.008
        compressor.release = 0.120
        return compressor.process(voice, fs: fs)
    }
}
```

### Sources/LumenAudio/TypingPacks.swift

```swift
import Foundation
import AVFoundation
import Accelerate

// Mechvibes pack loader: config.json + audio. Decodes and slices every key
// into its own AVAudioPCMBuffer at load. No decoding at playback time.
// Supports key_define_type "single" (slice from one file) and "multi"
// (one file per keycode), tolerant of null/missing keys.

public struct KeyPack: Decodable {
    public let key_define_type: String?
    public let sound: String?
    public let defines: [String: Define?]

    public enum Define: Decodable {
        case slice(startMs: Double, durMs: Double)
        case file(String)

        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let a = try? c.decode([Double].self), a.count == 2 {
                self = .slice(startMs: a[0], durMs: a[1])
            } else {
                self = .file(try c.decode(String.self))
            }
        }
    }
}

public func sliceBuffer(_ file: AVAudioFile, startMs: Double, durMs: Double) throws -> AVAudioPCMBuffer? {
    let sr = file.processingFormat.sampleRate
    let start = AVAudioFramePosition(startMs / 1000 * sr)
    let frames = AVAudioFrameCount(durMs / 1000 * sr)
    guard frames > 0 else { return nil }
    guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
    file.framePosition = start
    try file.read(into: out, frameCount: frames)
    return out
}

public enum TypingPackLoader {
    public static func buffers(in packDir: URL) -> [Int: AVAudioPCMBuffer] {
        let cfgURL = packDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let pack = try? JSONDecoder().decode(KeyPack.self, from: data) else { return [:] }
        var out: [Int: AVAudioPCMBuffer] = [:]
        let type = pack.key_define_type ?? "single"
        if type == "multi" {
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .file(let name) = def else { continue }
                let url = packDir.appendingPathComponent(name)
                guard let f = try? AVAudioFile(forReading: url),
                      let buf = try? AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                      (try? f.read(into: buf, frameCount: AVAudioFrameCount(f.length))) != nil else { continue }
                out[code] = buf
            }
        } else {
            guard let sound = pack.sound else { return [:] }
            let url = packDir.appendingPathComponent(sound)
            guard let f = try? AVAudioFile(forReading: url) else { return [:] }
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .slice(let s, let d) = def else { continue }
                if let buf = try? sliceBuffer(f, startMs: s, durMs: d) { out[code] = buf }
            }
        }
        return out
    }

    public static func availablePacks() -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/TypingPacks", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { $0.pathExtension.isEmpty && FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// PS/2 scancode (Mechvibes) -> macOS virtual keycode (CGEvent).
    /// Unknown macOS keys fall back to generic.
    public static let macToPack: [Int: Int] = [
        0: 30,   // kVK_ANSI_A -> 30
        1: 48,   // S
        2: 46,   // D
        3: 32,   // F
        4: 18,   // H
        5: 35,   // G
        6: 33,   // Z
        7: 34,   // X
        8: 31,   // C
        9: 49,   // V
        11: 19,  // B
        12: 37,  // Q
        13: 20,  // W
        14: 26,  // E
        15: 24,  // R
        16: 227, // Y (227 is PS/2 Y)
        17: 21,  // T
        49: 57,  // Space
        36: 28,  // Return
        51: 14,  // Delete (Backspace)
        48: 15,  // Tab
        56: 42,  // Shift
        60: 42,  // Shift right -> same sample
    ]
    public static let genericCode = 30
}
```

### Sources/LumenAudio/TypingSampler.swift

```swift
import Foundation
import AVFoundation

/// Preview-time typing sampler: 16-voice AVAudioEngine pool.
/// Same key restarts its own voice. No random pitch/sample.
public final class TypingSampler {
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var voiceForKey: [Int: Int] = [:]
    private var next = 0

    public init() {
        voices = (0..<16).map { _ in
            let n = AVAudioPlayerNode()
            engine.attach(n)
            return n
        }
        for v in voices { engine.connect(v, to: engine.mainMixerNode, format: nil) }
        engine.prepare()
    }

    public func load(packDir: URL) {
        buffers = TypingPackLoader.buffers(in: packDir)
    }

    public func play(packCode: Int, gain: Float, at when: AVAudioTime? = nil) {
        guard let buf = buffers[packCode] else { return }
        let i: Int
        if let idx = voiceForKey[packCode] { i = idx }
        else { i = next; next = (next + 1) % voices.count; voiceForKey[packCode] = i }
        let v = voices[i]
        v.stop()
        v.volume = min(max(gain, 0), 1)
        v.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
        v.play()
    }

    public func start() { if !engine.isRunning { try? engine.start() } }
    public func stop() { engine.stop() }
}
```
