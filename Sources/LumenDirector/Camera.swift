import Foundation
import LumenCore
import LumenProject

enum CameraSolver {
    private struct Shot {
        var start: Double
        var off: Double
        var logScale: Double
        var focus: Focus
        var ease: Double
        var isAuto: Bool
    }

    private struct Move {
        var start: Double
        var duration: Double
        var logScale: Double
        var pan: SIMD2<Double>
        var endVelocity = SIMD2<Double>.zero
        var endAcceleration = SIMD2<Double>.zero
        var followUntil: Double? = nil
    }

    private struct Channel {
        var move: QuinticMove

        init(_ value: Double) {
            move = QuinticMove(t0: 0, T: 1, x0: value, v0: 0, a0: 0, x1: value)
        }

        mutating func retarget(at time: Double, to target: Double, duration: Double,
                               start: (x: Double, v: Double, a: Double)? = nil,
                               endVelocity: Double = 0, endAcceleration: Double = 0) {
            let state = start ?? move.sample(time)
            move = QuinticMove(t0: time, T: duration, x0: state.x, v0: state.v, a0: state.a,
                               x1: target, v1: endVelocity, a1: endAcceleration)
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

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?) -> CameraTrack {
        _ = loop
        let rate = 240.0
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: rate)
        }
        let dt = 1 / rate
        let n = max(Int(outDur * rate) + 1, 2)
        var track = CameraTrack(count: n, rate: rate)
        let zoomIn = max(p.omegaZoom.isFinite ? p.omegaZoom : 1, 1)
        let zoomOut = zoomIn * 0.85
        let panOmega = max(p.omegaPan.isFinite ? p.omegaPan : 1, 1)
        let rest = SIMD2<Double>(repeating: 0.5)

        func index(_ time: Double) -> Int {
            min(max(Int((time * rate).rounded()), 0), n - 1)
        }
        func isFollow(_ focus: Focus) -> Bool {
            if case .follow = focus { return true }
            return false
        }

        let shots: [Shot] = zoom.compactMap { segment in
            let start = tm.output(atSource: segment.start)
            let off = tm.output(atSource: segment.end)
            guard start.isFinite, off.isFinite, off - start > 0.1,
                  segment.scale.isFinite, segment.scale > 1.001, start < outDur else { return nil }
            let rawEase = segment.easing?.omegaScale ?? 1
            let ease = max(rawEase.isFinite ? rawEase : 1, 0.2)
            return Shot(start: start, off: off, logScale: log(min(segment.scale, 16)),
                        focus: segment.focus, ease: ease, isAuto: segment.origin == .auto)
        }.sorted { $0.start < $1.start }

        let hasFollow = shots.contains { isFollow($0.focus) }
        var followX = [Double](repeating: 0.5, count: n)
        var followY = followX
        let cursorCount = min(cursor.x.count, cursor.y.count)
        if hasFollow, cursorCount > 0 {
            let halfZone = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            let followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            let rawX = (0..<n).map { i in
                let cursorIndex = min(Int(Double(i) * gridRate / rate), cursorCount - 1)
                return Double(cursor.x[cursorIndex]) / src.x
            }
            let rawY = (0..<n).map { i in
                let cursorIndex = min(Int(Double(i) * gridRate / rate), cursorCount - 1)
                return Double(cursor.y[cursorIndex]) / src.y
            }
            followX = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            followY = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }

        func targetCenter(_ shot: Shot, at sample: Int) -> SIMD2<Double> {
            var center: SIMD2<Double>
            switch shot.focus {
            case .fixed(let x, let y): center = SIMD2(x, y)
            case .element(let x, let y, let width, let height): center = SIMD2(x + width / 2, y + height / 2)
            case .follow: center = SIMD2(followX[sample], followY[sample])
            }
            let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
            center -= offset * exp(-shot.logScale)
            let half = 0.5 / exp(shot.logScale)
            return SIMD2(clamp(center.x, half, 1 - half), clamp(center.y, half, 1 - half))
        }

        func panCoordinate(for center: SIMD2<Double>, logScale: Double) -> SIMD2<Double> {
            let margin = max(0.5 - 0.5 * exp(-max(logScale, 0)), 1e-8)
            let pan = (center - rest) / margin
            return SIMD2(clamp(pan.x, -1, 1), clamp(pan.y, -1, 1))
        }

        func pathState(_ values: [Double], at time: Double) -> (x: Double, v: Double, a: Double) {
            guard !values.isEmpty else { return (0.5, 0, 0) }
            let lastTime = Double(values.count - 1) * dt
            func value(at sampleTime: Double) -> Double {
                let frame = clamp(sampleTime, 0, lastTime) * rate
                let low = min(Int(frame), values.count - 1)
                let high = min(low + 1, values.count - 1)
                return lerp(values[low], values[high], frame - Double(low))
            }
            let t = clamp(time, 0, lastTime)
            let before = max(t - dt, 0)
            let after = min(t + dt, lastTime)
            let x = value(at: t)
            guard before < t, after > t else { return (x, 0, 0) }
            let leftSpan = t - before, rightSpan = after - t
            let leftVelocity = (x - value(at: before)) / leftSpan
            let rightVelocity = (value(at: after) - x) / rightSpan
            return (x, (value(at: after) - value(at: before)) / (leftSpan + rightSpan),
                    2 * (rightVelocity - leftVelocity) / (leftSpan + rightSpan))
        }

        var moves: [Move] = []
        var previousLogScale = 0.0
        var previousCenter = rest
        var lastStart = -Double.infinity
        var previousIntentTime: Double?
        let arrivalLead = 1.0 / 60.0
        for shot in shots {
            let estimate = targetCenter(shot, at: index(shot.start))
            let scaleChange = abs(shot.logScale - previousLogScale)
            let panDistance = hypot(estimate.x - previousCenter.x, estimate.y - previousCenter.y)
                * exp(max(shot.logScale, previousLogScale))
            let panDuration = min(max((0.35 + 0.9 * panDistance) * (7 / panOmega) / shot.ease, 0.30), 1.2)
            let preferredDuration = scaleChange > 0.03
                ? max(5.5 / (zoomIn * shot.ease), 0.6 * panDuration)
                : panDuration
            let earliestStart = max(lastStart + 0.02, (previousIntentTime ?? -Double.infinity) + arrivalLead)
            let deadline = shot.start - arrivalLead
            let available = deadline - earliestStart
            let duration = shot.isAuto && available > 1e-3 ? min(preferredDuration, available) : preferredDuration
            let nominalStart = shot.isAuto
                ? shot.start - max(p.leadIn.isFinite ? p.leadIn : 0.6, duration + arrivalLead)
                : shot.start
            let start = max(nominalStart, earliestStart)
            let end = start + duration
            let endCenter = targetCenter(shot, at: index(end))
            let endPan = panCoordinate(for: endCenter, logScale: shot.logScale)
            var endVelocity = SIMD2<Double>.zero
            var endAcceleration = SIMD2<Double>.zero
            if isFollow(shot.focus) {
                let margin = max(0.5 - 0.5 * exp(-shot.logScale), 1e-8)
                let x = pathState(followX, at: end), y = pathState(followY, at: end)
                endVelocity = SIMD2(x.v / margin, y.v / margin)
                endAcceleration = SIMD2(x.a / margin, y.a / margin)
            }
            moves.append(Move(start: start, duration: duration, logScale: shot.logScale, pan: endPan,
                              endVelocity: endVelocity, endAcceleration: endAcceleration,
                              followUntil: isFollow(shot.focus) ? shot.off : nil))
            lastStart = start
            previousIntentTime = shot.start
            previousLogScale = shot.logScale
            previousCenter = endCenter
        }

        let entries = moves
        for (index, shot) in shots.enumerated() {
            if index + 1 < entries.count, entries[index + 1].start <= shot.off + 1e-3 { continue }
            moves.append(Move(start: shot.off, duration: 6.5 / (zoomOut * shot.ease), logScale: 0, pan: .zero))
        }
        moves.sort { $0.start < $1.start }

        var logScale = Channel(0)
        var panX = Channel(0), panY = Channel(0)
        var centersX = [Double](repeating: 0.5, count: n)
        var centersY = centersX
        var scales = [Double](repeating: 0, count: n)
        var moveIndex = 0
        var followMove: Move?

        for sample in 0..<n {
            let time = Double(sample) * dt
            while moveIndex < moves.count, moves[moveIndex].start <= time {
                let move = moves[moveIndex]
                moveIndex += 1
                var startX: (x: Double, v: Double, a: Double)?
                var startY: (x: Double, v: Double, a: Double)?
                if let current = followMove, let until = current.followUntil,
                   move.start >= current.start + current.duration, move.start <= until + 1e-9 {
                    let margin = max(0.5 - 0.5 * exp(-current.logScale), 1e-8)
                    let x = pathState(followX, at: move.start), y = pathState(followY, at: move.start)
                    startX = (panCoordinate(for: SIMD2(x.x, 0.5), logScale: current.logScale).x,
                              x.v / margin, x.a / margin)
                    startY = (panCoordinate(for: SIMD2(0.5, y.x), logScale: current.logScale).y,
                              y.v / margin, y.a / margin)
                }
                logScale.retarget(at: move.start, to: move.logScale, duration: move.duration)
                panX.retarget(at: move.start, to: move.pan.x, duration: move.duration, start: startX,
                              endVelocity: move.endVelocity.x, endAcceleration: move.endAcceleration.x)
                panY.retarget(at: move.start, to: move.pan.y, duration: move.duration, start: startY,
                              endVelocity: move.endVelocity.y, endAcceleration: move.endAcceleration.y)
                followMove = move.followUntil == nil ? nil : move
            }

            let zoom = max(logScale.move.sample(time).x, 0)
            var pan = SIMD2(panX.move.sample(time).x, panY.move.sample(time).x)
            if let current = followMove, let until = current.followUntil,
               time >= current.start + current.duration, time < until {
                let margin = max(0.5 - 0.5 * exp(-zoom), 1e-8)
                pan = SIMD2((followX[sample] - 0.5) / margin, (followY[sample] - 0.5) / margin)
            }
            pan = SIMD2(clamp(pan.x, -1, 1), clamp(pan.y, -1, 1))
            let margin = 0.5 - 0.5 * exp(-zoom)
            centersX[sample] = 0.5 + pan.x * margin
            centersY[sample] = 0.5 + pan.y * margin
            scales[sample] = zoom
        }

        func tangent(_ values: [Double]) -> [Float] {
            var result = [Float](repeating: 0, count: values.count)
            guard values.count > 1 else { return result }
            result[0] = Float((values[1] - values[0]) * rate)
            result[values.count - 1] = Float((values[values.count - 1] - values[values.count - 2]) * rate)
            if values.count > 2 {
                for i in 1..<(values.count - 1) {
                    let left = (values[i] - values[i - 1]) * rate
                    let right = (values[i + 1] - values[i]) * rate
                    if left * right > 0 { result[i] = Float(2 * left * right / (left + right)) }
                }
            }
            return result
        }

        track.nx = centersX.map(Float.init)
        track.ny = centersY.map(Float.init)
        track.lz = scales.map(Float.init)
        track.vx = tangent(centersX)
        track.vy = tangent(centersY)
        track.vz = tangent(scales)

        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawVelocity = 0.0
        var pitch = 0.0, pitchVelocity = 0.0
        func phase(_ channel: Int) -> Double {
            Double((p.tiltSeed >> UInt64(channel * 8)) & 255) / 255 * 2 * .pi
        }
        for sample in 0..<n {
            let time = Double(sample) * dt
            let scale = exp(scales[sample])
            var yawTarget = 0.0, pitchTarget = 0.0
            switch p.tilt {
            case .lean:
                yawTarget = clamp(Double(track.vx[sample]) * scale * 12, -p.maxYaw, p.maxYaw)
                pitchTarget = clamp(-Double(track.vy[sample]) * scale * 9, -p.maxPitch, p.maxPitch)
            case .float:
                yawTarget = p.floatDeg * (0.6 * sin(2 * .pi * 0.11 * time + phase(0)) + 0.4 * sin(2 * .pi * 0.07 * time + phase(1)))
                pitchTarget = p.floatDeg * (0.6 * sin(2 * .pi * 0.09 * time + phase(2)) + 0.4 * sin(2 * .pi * 0.05 * time + phase(3)))
            case .reveal, .off: break
            }
            springStep(&yaw, &yawVelocity, target: yawTarget, omega: p.omegaTilt, dt: dt)
            springStep(&pitch, &pitchVelocity, target: pitchTarget, omega: p.omegaTilt, dt: dt)
            track.yaw[sample] = Float(yaw)
            track.pitch[sample] = Float(pitch)
        }
        return track
    }
}
