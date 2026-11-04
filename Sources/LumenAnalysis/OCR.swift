import Foundation
import AVFoundation
import Vision
import os
import LumenCore
import LumenProject

public enum OCRAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, projectSalt: UInt64, customPatterns: [String] = [],
                              entropyThreshold: Double = 3.5, fps: Double = 2) async throws -> [OCRDetection] {
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = OCRJob(asset: asset, track: track, offset: offset, salt: projectSalt, patterns: customPatterns,
                         entropyThreshold: entropyThreshold, fps: fps)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class OCRJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let salt: UInt64
    private let patterns: [String]
    private let entropyThreshold: Double
    private let fps: Double
    private let readerLock = OSAllocatedUnfairLock<AVAssetReader?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, salt: UInt64, patterns: [String], entropyThreshold: Double, fps: Double) {
        self.asset = asset; self.track = track; self.offset = offset; self.salt = salt; self.patterns = patterns
        self.entropyThreshold = entropyThreshold; self.fps = fps
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.cancelReading() }
    }

    func run() throws -> [OCRDetection] {
        let reader = try AVAssetReader(asset: asset)
        readerLock.withLock { $0 = reader }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        var next = 0.0, lastRecognized = -Double.infinity
        var priorGrid: [UInt8]?
        var detections: [OCRDetection] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + 1 / max(fps, 0.5)
            let grid = try lumaGrid(buffer)
            let changed = priorGrid.map { changeRatio($0, grid) >= 0.003 } ?? true
            priorGrid = grid
            guard changed || time - lastRecognized >= 2 else { continue }
            lastRecognized = time
            detections.append(contentsOf: try detect(in: buffer, at: time + offset))
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        return deduplicate(detections)
    }

    private func detect(in buffer: CVPixelBuffer, at time: Double) throws -> [OCRDetection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
        var output: [OCRDetection] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for hit in SensitivePatterns.scan(candidate.string, custom: patterns, entropyThreshold: entropyThreshold) {
                let value = String(candidate.string[hit.range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let start = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.lowerBound))
                let end = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.upperBound))
                let count = Double(max(candidate.string.count, 1)), box = observation.boundingBox
                let left = max(Double(box.minX) + Double(box.width) * start / count - Double(box.width) * 0.04, 0)
                let right = min(Double(box.minX) + Double(box.width) * end / count + Double(box.width) * 0.04, 1)
                output.append(OCRDetection(t: time, x: left, y: 1 - Double(box.maxY), w: max(right - left, 0.001),
                                           h: Double(box.height), category: hit.category,
                                           hash: fnv1a64(value.lowercased(), salt: salt), confidence: candidate.confidence))
            }
        }
        return output
    }

    private func lumaGrid(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        let cols = 32, rows = 18
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var grid = [UInt8](repeating: 0, count: cols * rows)
        for y in 0..<rows {
            let py = min(y * height / rows, height - 1)
            for x in 0..<cols {
                let px = min(x * width / cols, width - 1), i = py * stride + px * 4
                grid[y * cols + x] = UInt8((29 * Int(base[i]) + 150 * Int(base[i + 1]) + 77 * Int(base[i + 2])) >> 8)
            }
        }
        return grid
    }

    private func changeRatio(_ old: [UInt8], _ new: [UInt8]) -> Double {
        let changed = zip(old, new).reduce(into: 0) { count, pair in
            if abs(Int(pair.0) - Int(pair.1)) >= 18 { count += 1 }
        }
        return Double(changed) / Double(max(old.count, 1))
    }

    private func deduplicate(_ detections: [OCRDetection]) -> [OCRDetection] {
        var seen: Set<String> = []
        return detections.sorted { $0.t < $1.t }.filter { detection in
            let cellX = Int((detection.x * 80).rounded()), cellY = Int((detection.y * 80).rounded())
            let cellT = Int((detection.t * 2).rounded())
            return seen.insert("\(detection.hash):\(cellT):\(cellX):\(cellY)").inserted
        }
    }
}
