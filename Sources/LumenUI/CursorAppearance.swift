import SwiftUI
import LumenProject
import LumenRender

/// The previews use the same arrow artwork and colors as the renderer.
struct CursorAppearance: View {
    let model: EditorModel
    private static let skins: [CursorPack] = [.system, .lavender, .coral, .sky, .mint, .lemon, .pink, .wood, .chrome, .grass]
    private static let previews = Dictionary(uniqueKeysWithValues: skins.compactMap { skin in
        CursorAtlas.previewImage(pack: skin).map { (skin, $0) }
    })
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cursor appearance").font(AppType.label).foregroundStyle(Tok.text)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 12) {
                ForEach(Self.skins, id: \.self) { skin in
                    Button {
                        model.edit { $0.cursor.pack = skin }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Tok.control)
                            if let image = Self.previews[skin] {
                                Image(nsImage: image).interpolation(.high).resizable().frame(width: 32, height: 32)
                            }
                            if model.timeline.cursor.pack == skin { CornerBrackets().padding(-3) }
                        }.frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(skin == .system ? "Default" : skin.rawValue.capitalized) cursor")
                    .accessibilityAddTraits(model.timeline.cursor.pack == skin ? .isSelected : [])
                }
            }
        }.card(padding: 16)
    }
}
