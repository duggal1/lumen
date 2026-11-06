import Foundation
import LumenSpeech

/// Isolated networking helper for fetching Moonshine model files. LumenSpeech itself stays network-free.
enum ModelDownloader {
    static let files = ["adapter.ort", "cross_kv.ort", "decoder_kv.ort", "encoder.ort",
                        "frontend.model.ort", "frontend.weights.ort", "streaming_config.json", "tokenizer.bin"]

    static func baseURL(for size: MoonshineSize) -> URL {
        URL(string: "https://download.moonshine.ai/model/\(size.rawValue)-streaming-en/quantized_26_11_02")!
    }

    static func download(size: MoonshineSize, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let dir = ModelStore.directory(size)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Double(files.count)
        for (i, name) in files.enumerated() {
            let url = baseURL(for: size).appendingPathComponent(name)
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            progress?(Double(i + 1) / total)
        }
    }
}
