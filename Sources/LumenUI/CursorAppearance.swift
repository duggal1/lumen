import SwiftUI
import LumenProject
import LumenRender

/// The previews use the same arrow artwork and colors as the renderer.
struct CursorAppearance: View {
    let model: EditorModel
    /// Every skin, grouped by what it changes. Ink packs recolor the real
    /// pointer; shape packs replace the pointer outright. One accent, no
    /// decorative fills — the selected skin wears the corner brackets.
    private static let inks: [CursorPack] = [.lavender, .coral, .sky, .mint, .lemon, .pink, .wood, .chrome, .grass, .ember]
    private static let shapes: [CursorPack] = [.dot, .ring, .pixel, .outline, .holiday]
    private static let all: [CursorPack] = [.system] + inks + shapes + [.mono]
    private static let previews = Dictionary(uniqueKeysWithValues: all.compactMap { skin in
        CursorAtlas.previewImage(pack: skin).map { (skin, $0) }
    })

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cursor appearance").font(AppType.label).foregroundStyle(Tok.text)
            skinRow(label: "Default", packs: [.system], columns: 6)
            skinRow(label: "Ink", packs: Self.inks, columns: 5)
            skinRow(label: "Shape", packs: Self.shapes + [.mono], columns: 3)
        }.card(padding: 16)
    }

    private func skinRow(label: String, packs: [CursorPack], columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(AppType.caption).foregroundStyle(Tok.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(packs, id: \.self) { skin in
                    tile(skin)
                }
            }
        }
    }

    private func tile(_ skin: CursorPack) -> some View {
        let selected = model.timeline.cursor.pack == skin
        return Button {
            model.edit { $0.cursor.pack = skin }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well)
                if let image = Self.previews[skin] {
                    Image(nsImage: image).interpolation(.high).resizable().frame(width: 30, height: 30)
                }
                if selected { RoundedRectangle(cornerRadius: Radius.field).fill(Tok.accentSoft) }
            }
            .frame(height: 46)
            .overlay(alignment: .bottom) {
                Text(Self.title(skin))
                    .font(AppType.caption)
                    .foregroundStyle(selected ? Tok.text : Tok.text2)
                    .lineLimit(1)
                    .padding(.bottom, 3)
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel("\(Self.title(skin)) cursor")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func title(_ skin: CursorPack) -> String {
        switch skin {
        case .system: "Default"
        case .mono: "Ink"
        default: skin.rawValue.capitalized
        }
    }
}