import SwiftUI
import LumenProject
import LumenRender

/// One focused interaction: drag a screen area to protect it from the current
/// playhead onward. The stored rectangle is in SOURCE pixels, not preview
/// pixels. Existing masks remain independent and independently removable.
struct ManualMaskOverlay: View {
    let model: EditorModel
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let start, let current {
                    let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                      width: abs(current.x - start.x), height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Tok.accentSoft)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    start = value.startLocation
                    current = value.location
                }
                .onEnded { value in
                    defer {
                        start = nil
                        current = nil
                        model.maskEditing = false
                    }
                    guard let d = model.timeline.derived,
                          geometry.size.width > 0, geometry.size.height > 0 else { return }
                    let state = model.timeline.evaluate(at: model.playhead)
                    let transform = ZoomTransform(
                        canvas: SIMD2(max(Int(geometry.size.width), 2), max(Int(geometry.size.height), 2)),
                        source: d.sourceSize, style: model.timeline.style,
                        cameraCenter: SIMD2(Double(state.cameraCenter.x), Double(state.cameraCenter.y)),
                        scale: Double(state.cameraScale))
                    func source(_ p: CGPoint) -> SIMD2<Double> {
                        let converted = transform.canvasToSource(SIMD2(Double(p.x), Double(p.y)))
                        return SIMD2(min(max(converted.x, 0), d.sourceSize.x),
                                     min(max(converted.y, 0), d.sourceSize.y))
                    }
                    let p0 = source(value.startLocation), p1 = source(value.location)
                    let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                      width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                    model.addManualMask(sourceRect: rect)
                })
        }
        .accessibilityLabel("Draw sensitive-data mask")
        .accessibilityHint("Drag a region of the recording to cover it from this point to the end.")
    }
}
