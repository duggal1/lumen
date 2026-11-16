import AppKit
import AVFoundation
import SwiftUI

/// The camera bubble: a white glass circle with the live camera inside, shown
/// only while recording and only when "Show camera preview" is on. It is never
/// captured: the recording gets its own webcam track.
@MainActor final class CameraBubbleController {
    static let shared = CameraBubbleController()
    private var panel: GlassPanel?
    private let preview = CameraPreviewView()

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        guard panel == nil else { return }
        let size = CGSize(width: 176, height: 176)
        let panel = GlassPanel(radius: 88, level: .statusBar)
        panel.hasShadow = true
        panel.install(CameraPreviewView())
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 24,
                                         y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A preview layer inside the bubble. Its own capture session is independent
/// of the recorder's webcam track.
struct CameraPreviewView: View {
    var body: some View {
        CameraLayerView()
            .frame(width: 176, height: 176)
            .clipShape(Circle())
    }
}

private struct CameraLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraLayerNSView { CameraLayerNSView() }
    func updateNSView(_ nsView: CameraLayerNSView, context: Context) {}

    final class CameraLayerNSView: NSView {
        private let session = AVCaptureSession()
        private let preview = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            layer = preview
            configure()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            session.commitConfiguration()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let running = session
            if window == nil {
                DispatchQueue.global(qos: .utility).async { running.stopRunning() }
            } else if !running.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { running.startRunning() }
            }
        }
    }
}
