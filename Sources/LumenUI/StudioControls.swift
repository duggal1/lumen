import SwiftUI
import AppKit
import ImageIO
import LumenCore
import LumenProject
import LumenRender

enum StudioInk {
    static let rail = Color(hex: 0x090909), panel = Color(hex: 0x0C0C0C), well = Color(hex: 0x121212)
    static let hover = Color(hex: 0x181818), selected = Color(hex: 0x202020), pressed = Color(hex: 0x262626)
    static let text = Color(hex: 0xF5F5F5), secondary = Color(hex: 0xA3A3A3)
    static let blue = Color(hex: 0x599CFF), orange = Color(hex: 0xFF8E3B), violet = Color(hex: 0xA373FF)
    static let cyan = Color(hex: 0x55D3F1), pink = Color(hex: 0xF267B0), green = Color(hex: 0x6FDB73), rose = Color(hex: 0xF05448)
    static let spectrum = [blue, cyan, green, orange, pink, violet]
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
}
private struct StudioHueKey: EnvironmentKey { static let defaultValue = StudioInk.orange }
extension EnvironmentValues { var studioHue: Color { get { self[StudioHueKey.self] } set { self[StudioHueKey.self] = newValue } } }

struct StudioDitherMark: View {
    let tint: Color
    var body: some View {
        Canvas { c, size in
            let step = min(size.width, size.height) / 5
            for y in 0..<5 { for x in 0..<5 where (x + y) % 2 == 0 || (x > 0 && x < 4 && y > 0 && y < 4) {
                c.fill(Path(CGRect(x: CGFloat(x)*step, y: CGFloat(y)*step, width: step-1, height: step-1)), with: .color(tint), style: FillStyle(antialiased: false))
            }}
        }.accessibilityHidden(true)
    }
}
struct StudioRailItem: View {
    let icon: String, title: String, selected: Bool, accent: Color
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        Button(action: action) {
            Image(systemName: IconSymbols.resolve(icon)).font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? accent : StudioInk.secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? StudioInk.selected : hover ? StudioInk.hover : .clear))
        }.buttonStyle(.plain).onHover { hover = $0 }.clickable().focusRing()
            .help(title).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
            .animation(reduce ? nil : StudioInk.ease(0.12), value: hover)
            .animation(reduce ? nil : StudioInk.ease(0.17), value: selected)
    }
}
struct StudioSection<Content: View>: View {
    let title: String; @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioInk.text).padding(.bottom, 4)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct StudioRow<C: View>: View {
    let label: String; @ViewBuilder var control: C
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(label).font(AppType.body).foregroundStyle(StudioInk.secondary).fixedSize()
                Spacer(minLength: 4)
                control.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(AppType.body).foregroundStyle(StudioInk.secondary)
                control.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.frame(minHeight: 32)
    }
}
struct StudioControlStyle: ButtonStyle {
    var selected = false; var primary = false
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, selected: selected, primary: primary) }
    private struct Face: View {
        let configuration: Configuration; let selected: Bool; let primary: Bool
        @State private var hover = false
        @Environment(\.accessibilityReduceMotion) private var reduce
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7).fill(primary ? StudioInk.orange : configuration.isPressed ? StudioInk.pressed : selected ? StudioInk.selected : hover ? StudioInk.hover : StudioInk.well))
                .scaleEffect(configuration.isPressed && !reduce ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
                .animation(reduce ? nil : StudioInk.ease(0.11), value: hover)
                .animation(reduce ? nil : StudioInk.ease(0.16), value: configuration.isPressed)
        }
    }
}
struct StudioButton: View {
    let title: String; var icon: String?; var kind: LKind = .secondary; var height: CGFloat = 30; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: IconSymbols.resolve(icon)).font(.system(size: 12, weight: .medium)) }
                Text(title).font(AppType.label).lineLimit(1)
            }.foregroundStyle(kind == .primary ? StudioInk.rail : StudioInk.text)
                .padding(.horizontal, 9).frame(minHeight: height)
        }.buttonStyle(StudioControlStyle(primary: kind == .primary)).clickable().focusRing().help(title)
    }
}
struct StudioPicker<T: Hashable>: View {
    @Binding var sel: T; let options: [(value: T, title: String, icon: String)]
    @Environment(MenuHost.self) private var host
    @State private var anchor = CGRect.zero
    var body: some View {
        Button {
            host.show(options.map { o in .init(title: o.title, icon: o.icon, checked: o.value == sel, action: { sel = o.value }) }, anchor: anchor, minWidth: anchor.width)
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == sel }?.title ?? "Custom").lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioInk.secondary)
            }.font(AppType.body).foregroundStyle(StudioInk.text).padding(.horizontal, 8).frame(height: 29)
        }.buttonStyle(StudioControlStyle()).clickable().focusRing()
        .background(GeometryReader { g in
            Color.clear.onAppear { anchor = g.frame(in: .named("root")) }.onChange(of: g.frame(in: .named("root"))) { _, v in anchor = v }
        })
    }
}
struct StudioSegments<T: Hashable>: View {
    @Binding var sel: T; let items: [(T, String)]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.0) { value, title in
                Button { sel = value } label: {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(sel == value ? StudioInk.text : StudioInk.secondary)
                        .lineLimit(1).frame(maxWidth: .infinity).frame(height: 26)
                }.buttonStyle(StudioControlStyle(selected: sel == value)).accessibilityAddTraits(sel == value ? .isSelected : [])
            }
        }
    }
}
struct StudioToggle: View {
    @Binding var on: Bool; let label: String
    @Environment(\.studioHue) private var hue
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 6).fill(on ? hue.opacity(0.22) : StudioInk.well)
                StudioDitherMark(tint: on ? hue : StudioInk.secondary).frame(width: 13, height: 13).padding(4)
            }.frame(width: 36, height: 22)
        }.buttonStyle(.plain).clickable().focusRing()
            .animation(reduce ? nil : StudioInk.ease(0.17), value: on)
            .accessibilityLabel(label).accessibilityValue(on ? "On" : "Off")
    }
}
struct StudioToggleRow: View {
    let label: String; @Binding var on: Bool
    var body: some View { StudioRow(label: label) { StudioToggle(on: $on, label: label) } }
}
struct StudioSliderRow: View {
    let label: String; @Binding var v: Double; let range: ClosedRange<Double>
    var fmt: (Double) -> String = { String(format: "%.2f", $0) }
    var live = false
    @GestureState private var drag: Double?
    @Environment(\.studioHue) private var hue
    var body: some View {
        let shown = drag ?? v
        let unit = range.upperBound > range.lowerBound ? min(max((shown - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1) : 0
        VStack(spacing: 0) {
            HStack {
                Text(label).font(AppType.body).foregroundStyle(StudioInk.secondary)
                Spacer()
                Text(fmt(shown)).font(AppType.mono).foregroundStyle(StudioInk.text)
            }
            GeometryReader { g in
                Canvas { c, size in
                    let n = max(1, Int(size.width / 4))
                    let filled = Int((unit.isFinite ? unit : 0) * Double(n))
                    for i in 0..<n {
                        let height: CGFloat = i < filled ? 9 : 4
                        c.fill(Path(CGRect(x: CGFloat(i)*4, y: (size.height-height)/2, width: 2, height: height)), with: .color(i < filled ? hue : StudioInk.pressed), style: FillStyle(antialiased: false))
                    }
                    let x = CGFloat(unit.isFinite ? unit : 0) * max(size.width-2, 0)
                    c.fill(Path(CGRect(x: x.rounded(), y: 2, width: 2, height: size.height-4)), with: .color(StudioInk.text))
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).updating($drag) { event, state, _ in
                        state = range.lowerBound + Double(min(max(event.location.x / max(g.size.width, 1), 0), 1)) * (range.upperBound-range.lowerBound)
                    }.onChanged { event in
                        if live { v = range.lowerBound + Double(min(max(event.location.x / max(g.size.width, 1), 0), 1)) * (range.upperBound-range.lowerBound) }
                    }.onEnded { event in
                        v = range.lowerBound + Double(min(max(event.location.x / max(g.size.width, 1), 0), 1)) * (range.upperBound-range.lowerBound)
                    })
            }.frame(height: 19).accessibilityRepresentation { Slider(value: $v, in: range).accessibilityLabel(label) }
        }.frame(minHeight: 36)
    }
}
struct StudioColorSwatches: View {
    let selected: RGBA?; let choose: (RGBA) -> Void
    private let colors: [UInt32] = [0xFFFFFF,0x171717,0x599CFF,0x55D3F1,0x6FDB73,0xFF8E3B,0xF267B0,0xA373FF]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                Button { choose(RGBA(hex)) } label: {
                    StudioDitherMark(tint: Color(hex: hex)).frame(width: 18, height: 18)
                        .padding(3).background(RoundedRectangle(cornerRadius: 5).fill(selected == RGBA(hex) ? StudioInk.selected : StudioInk.well))
                }.buttonStyle(.plain).help(String(format: "#%06X", hex)).accessibilityLabel(String(format: "Color #%06X", hex))
            }
        }
    }
}
struct StudioCursorTile: View {
    let pack: CursorPack; let selected: Bool; let ink: RGBA?; let action: () -> Void
    @State private var image: NSImage?
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let image { Image(nsImage: image).resizable().interpolation(pack == .pixel ? .none : .high).scaledToFit() }
                    else { Image(systemName: "cursorarrow").font(.system(size: 20)) }
                }.frame(width: 34, height: 34)
                Text(pack.studioTitle).font(.system(size: 11))
                StudioDitherMark(tint: selected ? StudioInk.violet : StudioInk.pressed).frame(width: 11, height: 11)
            }.foregroundStyle(selected ? StudioInk.text : StudioInk.secondary).padding(.vertical, 8).frame(maxWidth: .infinity)
        }.buttonStyle(StudioControlStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: ink) { image = CursorAtlas.previewImage(pack: pack, ink: ink) }
    }
}
struct StudioExportProgress: View {
    let value: Double
    var body: some View {
        Canvas { c, size in
            let cols = max(1, Int(size.width / 4)), rows = max(1, Int(size.height / 4))
            let n = Int(min(max(value.isFinite ? value : 0, 0), 1) * Double(cols))
            for x in 0..<cols { for y in 0..<rows {
                let hue = StudioInk.spectrum[min(StudioInk.spectrum.count-1, x * StudioInk.spectrum.count / cols)]
                let filled = x < n
                c.fill(Path(CGRect(x: x*4, y: y*4, width: 3, height: 3)), with: .color(filled ? hue.opacity((x+y)%2 == 0 ? 1 : 0.75) : StudioInk.pressed), style: FillStyle(antialiased: false))
            }}
        }.frame(height: 20)
    }
}
actor StudioThumbnailCache {
    static let shared = StudioThumbnailCache()
    private var images: [URL: CGImage] = [:]
    private var order: [URL] = []
    func thumbnail(_ url: URL) -> CGImage? {
        if let image = images[url] { return image }
        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        images[url] = image; order.append(url)
        if order.count > 48 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}
