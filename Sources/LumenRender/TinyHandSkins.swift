import AppKit
import LumenProject

/// The Tiny Hand coat.
///
/// Catalog ids, titles and inks are ported from Tiny Hand's `PointerStyle`
/// (MIT, Kamran Ahmed). The artwork itself ships beside this file in
/// `Resources/Cursors`; `LICENSE-tinyhand.txt` is copied with it. A skin is a
/// real illustrated pointer, not a recolored arrow, so the toolbar chooser and
/// the render atlas both draw exactly these pixels.
public enum TinyHandSkins {
    public struct Skin: Hashable, Sendable, Identifiable {
        public let pack: CursorPack
        public let title: String
        public let asset: String
        public let ink: UInt32
        public var id: CursorPack { pack }
    }

    /// The 25 illustrated hands that are genuinely new skins. Tiny Hand's
    /// color-only ink ids (lavender, coral, sky, …) already exist in Lumen as
    /// vector ink packs and keep their shape-preserving art; `pixel` stays the
    /// 1-bit vector arrow. Every entry here replaces the pointer with the real
    /// Tiny Hand artwork in the chooser, the atlas and the export.
    public static let catalog: [Skin] = [
        Skin(pack: .glove, title: "Cursor glove", asset: "hand_glove", ink: 0x8754F2),
        Skin(pack: .plush, title: "Plush", asset: "hand_plush", ink: 0x2F86F0),
        Skin(pack: .robot, title: "Robot", asset: "hand_robot", ink: 0x16A87A),
        Skin(pack: .holo, title: "Holo", asset: "hand_holo", ink: 0x8754F2),
        Skin(pack: .fuzzy, title: "Fuzzy", asset: "hand_fuzzy", ink: 0x8754F2),
        Skin(pack: .marble, title: "Marble", asset: "hand_marble", ink: 0x6B7380),
        Skin(pack: .terrazzo, title: "Terrazzo", asset: "hand_terrazzo", ink: 0xF0561D),
        Skin(pack: .glass, title: "Glass", asset: "hand_glass", ink: 0x1597E5),
        Skin(pack: .jelly, title: "Jelly", asset: "hand_jelly", ink: 0xA33FE6),
        Skin(pack: .pastel, title: "Pastel", asset: "hand_pastel", ink: 0xEE4F98),
        Skin(pack: .lowpoly, title: "Low poly", asset: "hand_lowpoly", ink: 0x8754F2),
        Skin(pack: .knit, title: "Knit", asset: "hand_knit", ink: 0x8754F2),
        Skin(pack: .skeleton, title: "Skeleton", asset: "hand_skeleton", ink: 0x9A5E2C),
        Skin(pack: .astro, title: "Astronaut", asset: "hand_astro", ink: 0x2F86F0),
        Skin(pack: .space, title: "Space", asset: "hand_space", ink: 0xFF2920),
        Skin(pack: .monster, title: "Monster", asset: "hand_monster", ink: 0x3E9E2E),
        Skin(pack: .water, title: "Water", asset: "hand_water", ink: 0x1597E5),
        Skin(pack: .lava, title: "Lava", asset: "hand_lava", ink: 0xF0561D),
        Skin(pack: .cactus, title: "Cactus", asset: "hand_cactus", ink: 0x3E9E2E),
        Skin(pack: .choco, title: "Chocolate", asset: "hand_choco", ink: 0x9A5E2C),
        Skin(pack: .cloud, title: "Cloud", asset: "hand_cloud", ink: 0x2F86F0),
        Skin(pack: .mech, title: "Mech", asset: "hand_mech", ink: 0xF0561D),
        Skin(pack: .neon, title: "Neon", asset: "hand_neon", ink: 0xE0309A),
        Skin(pack: .leaf, title: "Leaf", asset: "hand_leaf", ink: 0x3E9E2E),
        Skin(pack: .cookie, title: "Gingerbread", asset: "hand_cookie", ink: 0x9A5E2C),
    ]

    private static let byPack: [CursorPack: Skin] = Dictionary(
        uniqueKeysWithValues: catalog.map { ($0.pack, $0) })

    public static func skin(for pack: CursorPack) -> Skin? { byPack[pack] }
    public static func isCoat(_ pack: CursorPack) -> Bool { byPack[pack] != nil }

    public static func title(for pack: CursorPack) -> String {
        byPack[pack]?.title ?? pack.rawValue.capitalized
    }

    // MARK: Artwork

    private static let cache = SkinCache()

    /// The same image the atlas rasterizes. Loaded once per skin, never per cell.
    public static func image(for pack: CursorPack) -> NSImage? {
        guard let skin = byPack[pack] else { return nil }
        return cache.image(skin)
    }

    /// Draws the hand into the atlas' 32 pt box (the context is already scaled
    /// 8x with a top-left origin) and returns the hotspot in points. The tip of
    /// the pointer is measured from the PNG's alpha, the way Tiny Hand's
    /// `HandAsset.measure` finds it, so a click lands where the finger points.
    public static func draw(_ pack: CursorPack, in c: CGContext) -> SIMD2<Double>? {
        guard let skin = byPack[pack], let cg = cache.cg(skin), let geom = cache.geometry(skin) else { return nil }
        let rect = CGRect(x: geom.x0, y: geom.y0, width: geom.w, height: geom.h)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.28))
        c.draw(cg, in: rect)
        c.restoreGState()
        return SIMD2(Double(geom.hotX), Double(geom.hotY))
    }

    private struct Geometry {
        let x0: CGFloat, y0: CGFloat, w: CGFloat, h: CGFloat
        let hotX: CGFloat, hotY: CGFloat
    }

    private final class SkinCache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CursorPack: NSImage] = [:]
        private var cgs: [CursorPack: CGImage] = [:]
        private var geometry: [CursorPack: Geometry] = [:]

        func image(_ skin: Skin) -> NSImage? {
            lock.lock(); defer { lock.unlock() }
            if let hit = images[skin.pack] { return hit }
            guard let url = resourceURL(skin.asset), let image = NSImage(contentsOf: url) else { return nil }
            images[skin.pack] = image
            return image
        }

        func cg(_ skin: Skin) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let hit = cgs[skin.pack] { return hit }
            guard let image = images[skin.pack] ?? NSImage(contentsOf: resourceURL(skin.asset) ?? URL(fileURLWithPath: "")),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            cgs[skin.pack] = cg
            geometry[skin.pack] = measure(cg)
            return cg
        }

        func geometry(_ skin: Skin) -> Geometry? {
            lock.lock(); defer { lock.unlock() }
            return geometry[skin.pack]
        }

        /// Bundle.module keeps `.copy("Resources/Cursors")` under that folder;
        /// a flattened resource root is accepted too so a repackaged app works.
        private func resourceURL(_ name: String) -> URL? {
            for sub in ["Cursors", "Resources/Cursors", nil] {
                if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: sub) { return url }
            }
            return nil
        }

        /// Alpha-scans the PNG (top-left origin after the flip) for the pointer
        /// tip, then maps it through the fit rect into the 32 pt atlas box.
        private func measure(_ cg: CGImage) -> Geometry? {
            let w = cg.width, h = cg.height
            guard w > 0, h > 0 else { return nil }
            var alpha = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            var tipRow: Int?
            var tipX = w / 2
            outer: for y in 0..<h {
                var lo = -1, hi = -1
                let row = y * w
                for x in 0..<w where alpha[row + x] > 128 {
                    if lo < 0 { lo = x }
                    hi = x
                }
                if lo >= 0 {
                    tipRow = y
                    tipX = (lo + hi) / 2
                    break outer
                }
            }
            let tipY = tipRow ?? 0
            let box = CGFloat(32)
            let scale = min(box / CGFloat(w), box / CGFloat(h))
            let drawW = CGFloat(w) * scale, drawH = CGFloat(h) * scale
            let x0 = (box - drawW) / 2, y0 = (box - drawH) / 2
            return Geometry(x0: x0, y0: y0, w: drawW, h: drawH,
                            hotX: x0 + CGFloat(tipX) * scale,
                            hotY: y0 + CGFloat(tipY) * scale)
        }
    }
}
