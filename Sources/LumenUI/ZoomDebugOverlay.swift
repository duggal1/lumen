import SwiftUI
import LumenProject
import LumenRender

/// Diagnostics only. Shows the actual click on the canvas and the camera viewport
/// within a tiny source-frame map. Never reaches the Metal export.
struct ZoomDebugOverlay: View {
    let model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            if let d = model.timeline.derived {
                let state = model.timeline.evaluate(at: model.playhead)
                let source = d.sourceSize
                let transform = ZoomTransform(canvas: SIMD2(max(2, Int(geometry.size.width)),
                                                             max(2, Int(geometry.size.height))),
                                              source: source, style: model.timeline.style,
                                              cameraCenter: SIMD2(Double(state.cameraCenter.x), Double(state.cameraCenter.y)),
                                              scale: Double(state.cameraScale))
                let click = d.clicks.last(where: { $0.t <= model.playhead && model.playhead - $0.t < 0.75 })
                Canvas { ctx, size in
                    let cam = transform.sourceToCanvas(transform.cameraCenter)
                    cross(&ctx, at: CGPoint(x: cam.x, y: cam.y), color: Tok.text)
                    if let click {
                        let point = transform.sourceToCanvas(SIMD2(Double(click.x), Double(click.y)))
                        cross(&ctx, at: CGPoint(x: point.x, y: point.y), color: Tok.accent)
                    }
                    let width: CGFloat = 128
                    let height = width * CGFloat(source.y / max(source.x, 1))
                    let map = CGRect(x: 12, y: 12, width: width, height: height)
                    ctx.fill(Path(map), with: .color(Tok.well))
                    ctx.stroke(Path(map), with: .color(Tok.text2), lineWidth: 1)
                    let v = transform.viewport
                    let viewport = CGRect(x: map.minX + CGFloat(v.x / source.x) * width,
                                          y: map.minY + CGFloat(v.y / source.y) * height,
                                          width: CGFloat(v.z / source.x) * width,
                                          height: CGFloat(v.w / source.y) * height)
                    ctx.stroke(Path(viewport), with: .color(Tok.accent), lineWidth: 2)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func cross(_ ctx: inout GraphicsContext, at p: CGPoint, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: p.x - 8, y: p.y))
        path.addLine(to: CGPoint(x: p.x + 8, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - 8))
        path.addLine(to: CGPoint(x: p.x, y: p.y + 8))
        ctx.stroke(path, with: .color(color), lineWidth: 1)
    }
}
