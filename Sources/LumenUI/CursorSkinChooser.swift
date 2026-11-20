import SwiftUI
import AppKit
import LumenProject
import LumenRender

/// The cursor chooser. It lives in the Studio toolbar, not in the inspector:
/// the right side no longer has a cursor page. Every illustrated tile is the
/// same Tiny Hand artwork the render atlas rasterizes, and the active pack
/// wears a pixel check. No strokes, no cards-in-cards, no modal sheet.
struct CursorSkinChooser: View {
    let model: EditorModel
    let close: () -> Void

    private static let pointer: [CursorPack] = [.system, .minimal, .dot, .ring, .outline, .pixel, .pro, .holiday]
    private static let ink: [CursorPack] = [.lavender, .coral, .sky, .mint, .lemon, .pink, .wood, .chrome, .grass, .ember, .mono]
    private static let coat: [CursorPack] = TinyHandSkins.catalog.map(\.pack)

    private static func preview(_ pack: CursorPack) -> NSImage? {
        TinyHandSkins.isCoat(pack) ? TinyHandSkins.image(for: pack) : CursorAtlas.previewImage(pack: pack)
    }

    private static let previews: [CursorPack: NSImage] = Dictionary(
        uniqueKeysWithValues: (pointer + ink + coat).compactMap { pack in
            preview(pack).map { (pack, $0) }
        })

    private static func title(_ pack: CursorPack) -> String {
        TinyHandSkins.isCoat(pack) ? TinyHandSkins.title(for: pack) : pack.rawValue.capitalized
    }

    var body: some View {
        ZStack {
            Tok.modalScrim.ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("Pointer", packs: Self.pointer, columns: 6)
                        section("Color", packs: Self.ink, columns: 6)
                        section("Tiny Hand", packs: Self.coat, columns: 5)
                        controls
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
                footer
            }
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(width: 560, height: 620)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.escape) { close(); return .handled }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            PixelLens(cell: 2).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cursor skins.").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
                Text("Tiny Hand artwork renders in the export.").font(AppType.caption).foregroundStyle(Tok.text2)
            }
            Spacer(minLength: 8)
            LIconButton(icon: "xmark", label: "Close cursor skins") { close() }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func section(_ name: String, packs: [CursorPack], columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(AppType.caption).foregroundStyle(Tok.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(packs, id: \.self) { pack in tile(pack) }
            }
        }
    }

    private func tile(_ pack: CursorPack) -> some View {
        let selected = model.timeline.cursor.pack == pack
        return Button { model.edit { $0.cursor.pack = pack } } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.field).fill(selected ? Tok.accentSoft : Tok.well)
                    if let image = Self.previews[pack] {
                        Image(nsImage: image)
                            .resizable().aspectRatio(contentMode: .fit)
                            .padding(6).frame(height: 48)
                    }
                    if selected {
                        PixelBitmap(rows: Bitmap.check, cell: 1, color: Tok.accentText)
                            .frame(width: 10, height: 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(5)
                    }
                }
                .frame(height: 56)
                Text(Self.title(pack))
                    .font(AppType.caption)
                    .foregroundStyle(selected ? Tok.accentText : Tok.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .clickable()
        .focusRing()
        .accessibilityLabel("\(Self.title(pack)) cursor skin")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var controls: some View {
        VStack(spacing: 0) {
            SliderRow(label: "Size", v: model.bind(\.cursor.size), range: 0.5...2.0,
                      fmt: { String(format: "%.1f×", $0) })
            SliderRow(label: "Smoothing", v: model.bind(\.cursor.smoothingSigma), range: 0...0.12,
                      fmt: { "\(Int($0 * 1000)) ms" })
            Row(label: "Click effect") {
                LDropdown(sel: model.bind(\.cursor.clickEffect),
                          options: ClickEffect.allCases.map { ($0, $0.rawValue.capitalized, "cursorarrow") })
                    .frame(width: 130)
            }
        }
        .card(padding: 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            LButton(title: "Done", kind: .primary, height: 32, action: close)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}
