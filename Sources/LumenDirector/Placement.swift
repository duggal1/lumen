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
                      vad: [ClosedRange<Double>], outDur: Double) -> PlacementTrack {
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

        /// Cursor in canvas-normalized space through the live camera; z = cursor opacity.
        func cursorCanvas(_ t: Double) -> SIMD3<Double>? {
            guard !cursor.x.isEmpty, !cam.nx.isEmpty else { return nil }
            let i = min(max(Int(t * gridRate), 0), cursor.x.count - 1), ci = min(i, cam.nx.count - 1)
            let z = exp(Double(cam.lz[ci])), vw = src.x / z, vh = src.y / z
            let cx = Double(cam.nx[ci]) * src.x, cy = Double(cam.ny[ci]) * src.y
            let nx = (Double(cursor.x[i]) - (cx - vw / 2)) / vw, ny = (Double(cursor.y[i]) - (cy - vh / 2)) / vh
            return SIMD3(content.x + nx * content.z, content.y + ny * content.w, Double(cursor.opacity[i]))
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

        var cur = 0, badSince: Double? = nil, lastSwitch = -10.0, vis = 1.0, lastVoice = -10.0
        var corner = [UInt8](repeating: 0, count: n), visible = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let t = Double(i) * dt
            if voice[i] { lastVoice = t }
            let isNear = near(cur, t), isBehind = behind(cur, t)
            if isNear { if badSince == nil { badSince = t } } else { badSince = nil }
            let dwell = (isBehind && s.behindFace == .move) ? 0.25 : s.snapDwell        // hysteresis: only move after a real dwell
            if let b = badSince, t - b >= dwell, t - lastSwitch >= 0.8 {
                var best = cur
                for k in 0..<4 where k != cur && !near(k, t) { best = k; break }
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