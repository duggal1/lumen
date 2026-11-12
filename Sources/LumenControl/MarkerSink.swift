import Foundation
import LumenCore
import LumenActuator

/// Forwards markers from a script run into the running recording.
final class EngineMarkerSink: MarkerSink, @unchecked Sendable {
    let engine: Engine
    init(engine: Engine) { self.engine = engine }

    func record(marker: CaptureMarker) async {
        try? await engine.addMarker(marker)
    }
}
