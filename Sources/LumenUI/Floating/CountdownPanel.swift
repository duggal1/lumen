import SwiftUI
import AppKit
import Observation

/// The countdown: one centred glass card, one numeral, three cells draining.
/// It is driven by a single monotonic clock in `AppModel`, so a slow prepare
/// can never make it stutter, repeat a number, or skip.
@MainActor final class CountdownController {
    private var panel: GlassPanel?
    private let model = CountdownModel()
    private var transitionTask: Task<Void, Never>?

    func show(on screen: NSScreen?, number: Int) {
        transitionTask?.cancel()
        let target: GlassPanel
        if let panel {
            target = panel
        } else {
            model.visible = false
            let panel = GlassPanel(radius: 28, level: .screenSaver)
            panel.install(CountdownView(model: model))
            panel.setContentSize(CGSize(width: 208, height: 196))
            let targetScreen = screen ?? NSScreen.main
            if let frame = targetScreen?.frame {
                panel.setFrameOrigin(CGPoint(x: frame.midX - 104, y: frame.midY - 98))
            }
            self.panel = panel
            target = panel
        }
        let wasHidden = !target.isVisible
        if wasHidden { target.alphaValue = 0 }
        target.orderFrontRegardless()
        model.number = number
        withAnimation(reduceMotion ? nil : Motion.floatingTransition) { model.visible = true }
        if reduceMotion {
            target.alphaValue = 1
        } else if wasHidden {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                target.animator().alphaValue = 1
            }
        }
        set(number)
    }

    func set(_ number: Int) { model.number = number }

    func hide() {
        guard let panel else { return }
        transitionTask?.cancel()
        withAnimation(reduceMotion ? nil : Motion.floatingTransition) { model.visible = false }
        let duration = reduceMotion ? 0.0 : 0.32
        if duration == 0 {
            panel.orderOut(nil)
            self.panel = nil
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        transitionTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }
            panel.orderOut(nil)
            self.panel = nil
            self.transitionTask = nil
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

@MainActor @Observable private final class CountdownModel {
    var number = 3
    var visible = false
}

private struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        VStack(spacing: 6) {
            Text("\(model.number)")
                .font(.system(size: 84, weight: .medium).monospacedDigit())
                .foregroundStyle(Tok.floatingText)
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.floatingTransition, value: model.number)
                .frame(height: 96)
            Text("Recording starts")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tok.floatingText)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < model.number ? Tok.accent : Tok.controlPressed)
                        .frame(width: 22, height: 3)
                }
            }
            .padding(.top, 2)
        }
        .frame(width: 208, height: 196)
        .opacity(model.visible ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(model.number)")
    }
}
