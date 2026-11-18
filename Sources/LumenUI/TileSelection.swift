import SwiftUI

/// Flat selection language for content tiles.
///
/// DESIGN.md §2.1 bans strokes and §3.1.7 / §2.20 reserve corner brackets for a
/// canvas crop or zoom region. A selected tile is one luminance step (an
/// `accentSoft` fill) plus an `accentText` label — no outline, no bracket, no
/// shadow. The trait still reaches VoiceOver at the call site.
enum TileSelection {
    static func fill(_ selected: Bool) -> Color { selected ? Tok.accentSoft : Color.clear }
    static func ink(_ selected: Bool) -> Color { selected ? Tok.accentText : Tok.text2 }
}

extension View {
    /// Marks a tile as selected without drawing a stroke or a bracket.
    func tileSelection(_ selected: Bool, radius: CGFloat = Radius.field) -> some View {
        self
            .padding(2)
            .background(RoundedRectangle(cornerRadius: radius).fill(TileSelection.fill(selected)))
    }
}
