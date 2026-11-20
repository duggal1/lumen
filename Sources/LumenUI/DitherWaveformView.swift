import AppKit
import SwiftUI

/// A dithered audio strip: the exact instrument used by the timeline, laid out
/// as one band. Peaks drive which cells light; the hot front rolls with the
/// playhead. Used by the music shelf and the export band.
/// The export band: six Clove hues in one dithered strip. Idle, every run is
/// lit; while exporting, the played front runs hot and the rest steps back.
struct DitherColorBandView: NSViewRepresentable {
    let progress: Double
    var height: CGFloat = 68

    func makeNSView(context: Context) -> TimelineDitherNSView {
        let view = TimelineDitherNSView()
        view.bandLayout = TimelineDitherRenderer.Layout(bands: 1, top: 0, bandHeight: height)
        view.snapshot = snapshot
        return view
    }

    func updateNSView(_ view: TimelineDitherNSView, context: Context) {
        view.bandLayout = TimelineDitherRenderer.Layout(bands: 1, top: 0, bandHeight: height)
        view.snapshot = snapshot
        view.wake()
    }

    static func dismantleNSView(_ view: TimelineDitherNSView, coordinator: ()) { view.stop() }

    private var snapshot: TimelineDitherRenderer.Frame {
        let cols = 200
        let hues = [0, 1, 2, 3, 4, 5]
        let spans = hues.enumerated().map { i, hue in
            TimelineDitherRenderer.Span(i * cols / hues.count, (i + 1) * cols / hues.count, hue)
        }
        let p = min(max(progress, 0), 1)
        let peaks = (0..<cols).map { c -> Float in
            if p <= 0 { return 1 }
            return Double(c) <= p * Double(cols) ? 1 : 0.32
        }
        return TimelineDitherRenderer.Frame(spans: [spans], peaks: peaks, clicks: [],
                                            head: p > 0 ? Int(p * Double(cols)) : -1,
                                            playing: false, reduced: false, dt: 0, t: 0)
    }
}

struct DitherWaveformView: NSViewRepresentable {
    let peaks: [Float]
    /// Index into `TimelineDitherRenderer.hues`: 4 voice/cyan, 5 music/pink, 2 zoom/orange, 3 violet.
    let hue: Int
    var height: CGFloat = 44
    var head: Int = -1

    func makeNSView(context: Context) -> TimelineDitherNSView {
        let view = TimelineDitherNSView()
        view.bandLayout = TimelineDitherRenderer.Layout(bands: 1, top: 0, bandHeight: height)
        view.snapshot = snapshot
        return view
    }

    func updateNSView(_ view: TimelineDitherNSView, context: Context) {
        view.bandLayout = TimelineDitherRenderer.Layout(bands: 1, top: 0, bandHeight: height)
        view.snapshot = snapshot
        view.wake()
    }

    static func dismantleNSView(_ view: TimelineDitherNSView, coordinator: ()) { view.stop() }

    private var snapshot: TimelineDitherRenderer.Frame {
        let span = TimelineDitherRenderer.Span(0, max(peaks.count, 1), hue)
        return TimelineDitherRenderer.Frame(spans: [[span]], peaks: peaks, clicks: [],
                                            head: head, playing: false,
                                            reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                            dt: 0, t: 0)
    }
}
