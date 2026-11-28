import SwiftUI
import LumenCore

/// Whole-program seek surface independent of the zoomed editing viewport.
/// Pointer and clock agree exactly; only decorative emphasis eases.
struct StudioSeekBar: View {
    let model: EditorModel
    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let duration = max(model.duration, 0.001)
        let paused = model.playhead
        let playing = model.isPlaying
        GeometryReader { g in
            TimelineView(.animation(paused: !playing)) { _ in
                let time = playing ? model.clock.time(at: HostClock.now()) : paused
                let progress = time.isFinite ? min(max(time / duration, 0), 1) : 0
                let usable = max(g.size.width - 4, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(StudioInk.well).frame(height: 4)
                    Capsule().fill(StudioInk.blue).frame(width: max(g.size.width, 0) * CGFloat(progress), height: 4)
                    Capsule().fill(StudioInk.text)
                        .frame(width: 4, height: dragging || hovering ? 14 : 10)
                        .animation(reduce ? nil : (hovering ? Motion.hoverIn : Motion.hoverOut), value: hovering)
                        .animation(reduce ? nil : (dragging ? Motion.press : Motion.release), value: dragging)
                        .offset(x: usable * CGFloat(progress))
                }.frame(maxHeight: .infinity)
            }.id(playing)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if !dragging { dragging = true; model.beginScrub() }
                    model.scrub(to: duration * Double(min(max(event.location.x / max(g.size.width, 1), 0), 1)))
                }
                .onEnded { event in
                    model.scrub(to: duration * Double(min(max(event.location.x / max(g.size.width, 1), 0), 1)))
                    dragging = false
                    model.endScrub()
                })
        }.frame(height: 20)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { model.playhead }, set: { model.seek($0) }), in: 0...duration)
                .accessibilityLabel("Playback position")
        }
        .onDisappear { if dragging { model.endScrub() } }
    }
}
