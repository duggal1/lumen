import SwiftUI
import AppKit

// MARK: Button

enum LKind { case primary, secondary, quiet }

struct LButtonStyle: ButtonStyle {
    var kind: LKind, height: CGFloat
    func makeBody(configuration: Configuration) -> some View { Inner(c: configuration, kind: kind, height: height) }
    private struct Inner: View {
        let c: Configuration, kind: LKind, height: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let off = !enabled
            let bg: Color = switch kind {
            case .primary: off ? Tok.control : c.isPressed ? Tok.accentPressed : hover ? Tok.accentHover : Tok.accent
            case .secondary: c.isPressed ? Tok.controlPressed : hover ? Tok.controlHover : Tok.control
            case .quiet: hover || c.isPressed ? Tok.wash : .clear
            }
            let fg: Color = kind == .primary ? (off ? Tok.text2 : Tok.onAccent) : kind == .quiet && !hover ? Tok.text2 : Tok.text
            c.label.font(AppType.label).foregroundStyle(fg).padding(.horizontal, 12).frame(height: height)
                .background {
                    if kind == .quiet {
                        Capsule().fill(bg)
                    } else {
                        Capsule().fill(.regularMaterial)
                        Capsule().fill(bg.opacity(kind == .primary ? 0.94 : 0.42))
                    }
                }
                .scaleEffect(c.isPressed ? 0.98 : 1).opacity(kind != .primary && off ? 0.4 : 1)
                .onHover { hover = $0 }.pointerStyle(enabled ? .link : .default)
                .animation(reduceMotion ? nil : (hover ? Motion.hoverIn : Motion.hoverOut), value: hover)
                .animation(reduceMotion ? nil : Motion.hoverIn, value: c.isPressed)
        }
    }
}

struct LButton: View {
    let title: String; var icon: String?; var kind: LKind = .secondary; var height: CGFloat = 28; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12)) }
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }.buttonStyle(LButtonStyle(kind: kind, height: height)).accessibilityLabel(title)
    }
}

struct LIconButton: View {
    let icon: String, label: String; let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Tok.controlHover : .clear)) }
            .buttonStyle(.plain).foregroundStyle(Tok.text).onHover { hover = $0 }
            .animation(reduceMotion ? nil : (hover ? Motion.hoverIn : Motion.hoverOut), value: hover)
            .pointerStyle(.link).accessibilityLabel(label)
    }
}

// MARK: Controls

struct LToggle: View {
    @Binding var on: Bool; let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Tok.accent : Tok.controlPressed)
                Circle().fill(.white).frame(width: 20, height: 20).padding(2)
            }.frame(width: 40, height: 24).animation(reduceMotion ? nil : Motion.toggle, value: on)
        }.buttonStyle(.plain).pointerStyle(.link).accessibilityLabel(label).accessibilityValue(on ? "On" : "Off")
    }
}

/// Track = 2x4 pt ticks on a 4 pt pitch; passed ticks rise to 8 pt in the accent ramp; thumb = 2 pt white scan line.
struct LSlider: View {
    @Binding var value: Double; let range: ClosedRange<Double>; var step: Double = 0; var width: CGFloat = 150
    @State private var dragging = false
    var body: some View {
        let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        Canvas { c, size in
            let n = Int(size.width / 4), lit = Int(frac * Double(n))
            for i in 0..<n {
                let on = i < lit, h: CGFloat = on ? 8 : 4
                c.fill(Path(CGRect(x: CGFloat(i) * 4, y: (size.height - h) / 2, width: 2, height: h)),
                       with: .color(on ? Ramp.o[3] : Tok.controlPressed), style: FillStyle(antialiased: false))
            }
            c.fill(Path(CGRect(x: CGFloat(lit) * 4, y: (size.height - 16) / 2, width: 2, height: 16)), with: .color(Tok.text), style: FillStyle(antialiased: false))
        }
        .frame(width: width, height: 24).contentShape(Rectangle())
        .pointerStyle(dragging ? .grabActive : .grabIdle)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                dragging = true
                var v = range.lowerBound + min(max(g.location.x / width, 0), 1) * (range.upperBound - range.lowerBound)
                if step > 0 { v = (v / step).rounded() * step }
                if v != value { value = v }
            }
            .onEnded { _ in dragging = false })
        .accessibilityRepresentation { Slider(value: $value, in: range) }
    }
}

struct LSegmented<T: Hashable>: View {
    @Binding var sel: T; let items: [(T, String)]
    var track: Color = Tok.well
    var thumb: Color = Tok.control
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { v, title in
                Button { sel = v } label: {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(sel == v ? Tok.text : Tok.text2)
                        .lineLimit(1).frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if sel == v {
                                Capsule().fill(.thinMaterial).matchedGeometryEffect(id: "thumb", in: ns)
                                Capsule().fill(thumb.opacity(0.38))
                            }
                        }
                }.buttonStyle(.plain).pointerStyle(.link)
                .accessibilityLabel(title)
                .accessibilityAddTraits(sel == v ? .isSelected : [])
            }
        }.padding(2)
            .background(.regularMaterial, in: Capsule())
            .animation(reduceMotion ? nil : Motion.slide, value: sel)
    }
}

// MARK: Menus (custom panels, never system glass)

@MainActor @Observable final class MenuHost {
    struct Item: Identifiable {
        let id = UUID(); var title: String; var icon: String; var checked = false; var destructive = false; var gapBefore = false
        var disabled = false; var action: () -> Void
    }
    var items: [Item] = []
    var anchor = CGRect.zero
    var minWidth: CGFloat = 0
    var hl = 0
    var isOpen = false
    func show(_ items: [Item], anchor: CGRect, minWidth: CGFloat) {
        self.items = items; self.anchor = anchor; self.minWidth = minWidth
        hl = items.firstIndex(where: \.checked) ?? 0; isOpen = true
    }
    func close() { isOpen = false }
    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        var i = hl
        for _ in 0..<items.count { i = (i + d + items.count) % items.count; if !items[i].disabled { hl = i; return } }
    }
    func fire() {
        guard isOpen, items.indices.contains(hl), !items[hl].disabled else { return }
        let a = items[hl].action; close(); a()
    }
}

struct MenuLayer: View {
    @Environment(MenuHost.self) private var host
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { g in
            if host.isOpen {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).onTapGesture { host.close() }
                    panel(g.size)
                }
            }
        }
    }
    private func panel(_ size: CGSize) -> some View {
        let w = menuWidth()
        var ys: [CGFloat] = [], y0: CGFloat = 4
        for it in host.items { y0 += it.gapBefore ? 8 : 0; ys.append(y0); y0 += 32 }
        let h = y0 + 4
        let x = min(max(host.anchor.maxX - w, 8), size.width - w - 8)
        var y = host.anchor.maxY + 6
        if y + h > size.height - 8 { y = host.anchor.minY - 6 - h }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Tok.controlHover)
            if host.items.indices.contains(host.hl) {
                RoundedRectangle(cornerRadius: 8).fill(Tok.controlPressed).frame(width: w - 8, height: 32)
                    .offset(x: 4, y: ys[host.hl]).animation(.smooth(duration: 0.18), value: host.hl)
            }
            ForEach(Array(host.items.enumerated()), id: \.element.id) { i, it in
                let col = it.destructive ? Tok.statusBad : Tok.text
                Button { host.close(); it.action() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: it.icon).font(.system(size: 14)).frame(width: 20)
                        Text(it.title).font(AppType.label).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 16)
                        Image(systemName: "checkmark").font(.system(size: 12)).foregroundStyle(Tok.accentText).frame(width: 20).opacity(it.checked ? 1 : 0)
                    }.padding(.horizontal, 12).frame(width: w - 8, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(col).opacity(it.disabled ? 0.4 : 1).disabled(it.disabled)
                .onHover { if $0 && !it.disabled { host.hl = i } }.offset(x: 4, y: ys[i])
            }
        }
        .frame(width: w, height: h).offset(x: x, y: y).transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
        .focusable().focused($focused).focusEffectDisabled().onAppear { focused = true }
        .onKeyPress(.downArrow) { host.move(1); return .handled }
        .onKeyPress(.upArrow) { host.move(-1); return .handled }
        .onKeyPress(.return) { host.fire(); return .handled }
        .onKeyPress(.escape) { host.close(); return .handled }
        .animation(.smooth(duration: 0.20), value: host.isOpen)
    }

    /// Width = max(trigger, longest title + 12 + 20 + 8 + 16 + 20 + 12 + 8). Titles never wrap.
    private func menuWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let longest = host.items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(host.minWidth, longest + 12 + 20 + 8 + 16 + 20 + 12 + 8)
    }
}

struct MenuRoot<Content: View>: View {
    @State private var host = MenuHost()
    @ViewBuilder var content: Content
    var body: some View { content.coordinateSpace(name: "root").environment(host).overlay { MenuLayer().environment(host) }.focusEffectDisabled() }
}

struct LDropdown<T: Hashable>: View {
    @Binding var sel: T; let options: [(value: T, title: String, icon: String)]
    @Environment(MenuHost.self) private var host
    @State private var frame = CGRect.zero
    var body: some View {
        Button {
            host.show(options.map { o in .init(title: o.title, icon: o.icon, checked: o.value == sel, action: { sel = o.value }) },
                      anchor: frame, minWidth: frame.width)
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == sel }?.title ?? "").font(AppType.body).foregroundStyle(Tok.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Tok.text2)
            }.padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(host.isOpen ? Tok.controlPressed : Tok.control))
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .background(GeometryReader { g in
            Color.clear.onAppear { frame = g.frame(in: .named("root")) }.onChange(of: g.frame(in: .named("root"))) { _, f in frame = f }
        })
    }
}

// MARK: Rows

struct Row<C: View>: View {
    let label: String; var icon: String?; @ViewBuilder var control: C
    var body: some View {
        HStack(spacing: 12) {
            if let icon { Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Tok.text2).frame(width: 20) }
            Text(label).font(AppType.label).foregroundStyle(Tok.text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            control
        }.frame(minHeight: 48)
    }
}
struct SliderRow: View {
    let label: String; @Binding var v: Double; let range: ClosedRange<Double>; var fmt: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        Row(label: label) {
            HStack(spacing: 8) { LSlider(value: $v, range: range, width: 100)
                Text(fmt(v)).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2).frame(width: 40, alignment: .trailing) }
        }
    }
}
struct ToggleRow: View {
    let label: String; @Binding var on: Bool
    var body: some View { Row(label: label) { LToggle(on: $on, label: label) } }
}

// MARK: Action menu trigger

/// 12 pt ellipsis in a 28 target. Every menu item carries a prefix icon.
struct LActionMenuButton: View {
    var label = "More"
    let items: [MenuHost.Item]
    @Environment(MenuHost.self) private var host
    @State private var hover = false
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            host.show(items, anchor: frame, minWidth: 200)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.field).fill(hover || host.isOpen ? Tok.controlHover : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tok.text)
        .onHover { hover = $0 }
        .pointerStyle(.link)
        .accessibilityLabel(label)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named("root")) }
                .onChange(of: g.frame(in: .named("root"))) { _, f in frame = f }
        })
    }
}

// MARK: Dialog (480 wide, lens, real Cancel and confirm)

struct LDialog<Content: View>: View {
    let title: String
    var subtitle: String?
    let confirmTitle: String
    var confirmEnabled = true
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder var content: Content
    @State private var shown = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Tok.modalScrim.ignoresSafeArea().onTapGesture { }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    PixelLens(cell: 2).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
                        if let subtitle { Text(subtitle).font(AppType.caption).foregroundStyle(Tok.text2) }
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 16) { content }.padding(.top, 24)
                HStack(spacing: 8) {
                    Spacer()
                    LButton(title: "Cancel", kind: .secondary, height: 32, action: cancel)
                    LButton(title: confirmTitle, kind: .primary, height: 32, action: confirm)
                        .disabled(!confirmEnabled)
                }.padding(.top, 24)
            }
            .padding(24)
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
            .scaleEffect(shown ? 1 : 0.97)
            .offset(y: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(.return) { if confirmEnabled { confirm() }; return .handled }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: Toast (system glass capsule, 40 tall, one quiet action)

struct UndoToast: View {
    let text: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(AppType.body).foregroundStyle(Tok.text)
            Button(action: action) {
                Text(actionTitle).font(AppType.label).foregroundStyle(Tok.text)
                    .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Tok.washStrong))
            }.buttonStyle(.plain).pointerStyle(.link)
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: Page bar (52 tall, one primary action, title baseline at y = 60)

struct PageBar<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s4) {
            PageTitle(text: title)
            Spacer(minLength: Space.s4)
            action
        }
        .padding(.horizontal, Metrics.pagePad)
        .padding(.bottom, 8)
        .frame(height: Metrics.pageBar + 8, alignment: .bottom)
    }
}

// MARK: Chip

struct LChip: View {
    let text: String
    var mono = true
    var body: some View {
        Text(text)
            .font(mono ? AppType.mono : AppType.body)
            .foregroundStyle(Tok.text)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Tok.control))
    }
}
