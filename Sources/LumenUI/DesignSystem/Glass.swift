import SwiftUI

/// Editor chrome only.
///
/// The caption card, the click ripple and the privacy mosaic are content: they
/// are drawn by the Metal compositor so the preview and the exported video are
/// byte-for-byte the same look. SwiftUI materials sample the live window
/// backdrop, which does not exist in an exported frame, so they must never be
/// used for content. Floating editor surfaces may use them.
///
/// macOS 26 gets real Liquid Glass. Older systems get the system's thin
/// material, which is the same native vibrancy blur, with a hairline edge so a
/// floating panel still separates from a busy backdrop.
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            fallback(content, shape: shape)
        }
        #else
        fallback(content, shape: shape)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                if let tint { shape.fill(tint) }
            }
            .overlay { shape.strokeBorder(Tok.washStrong, lineWidth: 1) }
    }
}

extension View {
    /// Native editor-chrome material. Never use it for compositor content.
    func glassSurface(radius: CGFloat = Radius.card, tint: Color? = nil) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint))
    }
}
