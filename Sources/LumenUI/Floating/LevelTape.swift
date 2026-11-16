import SwiftUI
import Observation

/// The one live input level the recorder reads. Written by the capture poll,
/// read by the tape; never a second smoothing stage.
@MainActor @Observable final class RecordingMeter {
    var level: Float = 0
}

/// Rolling microphone level rendered as a 24-column, seven-row pixel tape.
/// The 60 Hz sampler eases real meter samples into the grid and pause freezes it.
struct LevelTape: View {
    let meter: RecordingMeter
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Double] = []
    @State private var smoothedLevel = 0.0

    private let columns = 24
    private let pitch: CGFloat = 3
    private let cell: CGFloat = 2
    private let rows = 7

    var body: some View {
        Canvas { context, size in
            for column in 0..<columns {
                let index = levels.count - columns + column
                let value = index >= 0 && index < levels.count ? levels[index] : 0
                let x = CGFloat(column) * pitch
                let magnitude = Int((value * 3).rounded(.up))
                for row in 0..<rows {
                    let distance = abs(row - rows / 2)
                    let active = magnitude > 0 && distance < magnitude * 2 - 1
                    let rect = CGRect(x: x, y: CGFloat(row) * pitch, width: cell, height: cell)
                    if active {
                        context.fill(Path(rect), with: .color(Tok.accent), style: FillStyle(antialiased: false))
                    }
                }
            }
        }
        .frame(width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch - 1)
        .task(id: "\(paused)-\(reduceMotion)") {
            if paused { return }
            var last = ContinuousClock.now
            while !Task.isCancelled {
                let now = ContinuousClock.now
                let elapsed = last.duration(to: now)
                last = now
                let seconds = max(min(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, 0.2), 0.001)
                let target = Self.normalize(meter.level)
                let rate = target > smoothedLevel ? 26.0 : 10.0
                smoothedLevel += (target - smoothedLevel) * (1 - exp(-seconds * rate))
                levels.append(smoothedLevel)
                if levels.count > columns { levels.removeFirst(levels.count - columns) }
                try? await Task.sleep(for: reduceMotion ? .milliseconds(100) : .microseconds(16_667))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(paused ? "Paused" : meter.level > 0.002 ? "Sound detected" : "Quiet")
    }

    /// dBFS on a −72…−12 window, with 2 pt of headroom at silence so dust and
    /// sound are different shapes rather than different colors.
    private static func normalize(_ level: Float) -> Double {
        let value = Double(level)
        guard value > 0, value.isFinite else { return 0 }
        let db = 20 * log10(value)
        guard db > -72 else { return 0 }
        return min(max((db + 72) / 60, 0), 1)
    }
}
