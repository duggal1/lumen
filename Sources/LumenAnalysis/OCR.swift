import Foundation
import AVFoundation
import Vision
import CoreImage
import os
import LumenCore
import LumenProject

public enum OCRAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, projectSalt: UInt64, customPatterns: [String] = [],
                              entropyThreshold: Double = 3.5, fps: Double = 4,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [OCRDetection] {
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = OCRJob(asset: asset, track: track, offset: offset, salt: projectSalt, patterns: customPatterns,
                         entropyThreshold: entropyThreshold, fps: fps, progress: progress)
        return try await withTaskCancellationHandler {
            try await job.value()
        } onCancel: { job.cancel() }
    }
}

private struct OCRRequestHandle: @unchecked Sendable { let request: VNRecognizeTextRequest }

private final class OCRJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let salt: UInt64
    private let patterns: [String]
    private let entropyThreshold: Double
    private let fps: Double
    private let progress: @Sendable (Double) -> Void
    private let completion = OSAllocatedUnfairLock<(continuation: CheckedContinuation<[OCRDetection], Error>?, result: Result<[OCRDetection], Error>?)>(uncheckedState: (nil, nil))
    private let requestLock = OSAllocatedUnfairLock<OCRRequestHandle?>(uncheckedState: nil)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, salt: UInt64, patterns: [String], entropyThreshold: Double, fps: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.asset = asset; self.track = track; self.offset = offset; self.salt = salt; self.patterns = patterns
        self.entropyThreshold = entropyThreshold; self.fps = fps; self.progress = progress
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
        requestLock.withLock { $0?.request.cancel() }
        resolve(.failure(CancellationError()))
    }

    func value() async throws -> [OCRDetection] {
        try await withCheckedThrowingContinuation { continuation in
            let prior = completion.withLock { state -> Result<[OCRDetection], Error>? in
                if let result = state.result { return result }
                state.continuation = continuation; return nil
            }
            if let prior { continuation.resume(with: prior); return }
            DispatchQueue.global(qos: .utility).async { [self] in
                do { resolve(.success(try run())) } catch { resolve(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.completion.withLock({ $0.result == nil }) else { return }
                self.resolve(.failure(NSError(domain: "Lumen.Privacy", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Text scanning exceeded two minutes. Retry the scan or use manual masks."])))
                self.cancel()
            }
        }
    }

    private func resolve(_ result: Result<[OCRDetection], Error>) {
        let continuation = completion.withLock { state -> CheckedContinuation<[OCRDetection], Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation; state.continuation = nil; return continuation
        }
        continuation?.resume(with: result)
    }

    func run() throws -> [OCRDetection] {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        var nextTrack = 0.0
        let tracker = VNSequenceRequestHandler()
        var next = 0.0
        var priorGrid: [UInt8]?
        var lastDetections: [OCRDetection] = []
        var detections: [OCRDetection] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if time + 0.0001 < next {
                if time >= nextTrack, !lastDetections.isEmpty {
                    nextTrack = time + 1.0 / 15
                    lastDetections = try track(lastDetections, buffer: buffer, time: time + offset, handler: tracker)
                    detections.append(contentsOf: lastDetections)
                }
                continue
            }
            next = time + 1 / max(fps, 0.5)
            let grid = try lumaGrid(buffer)
            let changed = priorGrid.map { changeRatio($0, grid) > 0 } ?? true
            priorGrid = grid
            progress(min(max(time / max(asset.duration.seconds, 0.001), 0), 0.99))
            if !changed, !lastDetections.isEmpty {
                detections.append(contentsOf: lastDetections.map { detection in
                    var held = detection; held.t = time + offset; return held
                })
                continue
            }
            // Confidence gate: sub-0.3 candidates are jitter, not text. The
            // bridge in MaskTracks holds masks through single dropouts.
            lastDetections = try detect(in: buffer, at: time + offset)
            detections.append(contentsOf: lastDetections)
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        progress(1)
        return deduplicate(detections)
    }

    private func track(_ detections: [OCRDetection], buffer: CVPixelBuffer, time: Double,
                       handler: VNSequenceRequestHandler) throws -> [OCRDetection] {
        let requests = detections.map { detection in
            let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: detection.x,
                y: 1 - detection.y - detection.h, width: detection.w, height: detection.h))
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .fast
            return request
        }
        try handler.perform(requests, on: buffer)
        return zip(detections, requests).map { prior, request in
            var result = prior; result.t = time
            if let observation = request.results?.first, observation.confidence >= 0.3 {
                let rect = observation.boundingBox
                result.x = rect.minX; result.y = 1 - rect.maxY; result.w = rect.width; result.h = rect.height
            }
            return result
        }
    }

    private func detect(in buffer: CVPixelBuffer, at time: Double) throws -> [OCRDetection] {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let full = context.createCGImage(image, from: image.extent) else { throw AnalysisError.pixelBuffer }
        let width = full.width, height = full.height, tile = 1536, step = 1408
        var observations: [(VNRecognizedTextObservation, CGRect)] = []
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                if cancelled.withLock({ $0 }) { throw CancellationError() }
                let rect = CGRect(x: x, y: y, width: min(tile, width - x), height: min(tile, height - y))
                guard let crop = full.cropping(to: rect) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0
                let requestHandle = OCRRequestHandle(request: request)
                requestLock.withLock { $0 = requestHandle }
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                requestLock.withLock { $0 = nil }
                for observation in request.results ?? [] {
                    let box = observation.boundingBox
                    let mapped = CGRect(x: (rect.minX + box.minX * rect.width) / Double(width),
                        y: (rect.minY + (1 - box.maxY) * rect.height) / Double(height),
                        width: box.width * rect.width / Double(width), height: box.height * rect.height / Double(height))
                    observations.append((observation, mapped))
                }
            }
        }
        var output: [OCRDetection] = []
        let confidence = Float(min(max((entropyThreshold - 3) * 0.2 + 0.15, 0.1), 0.5))
        for (observation, mappedBox) in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= confidence else { continue }
            for hit in SensitivePatterns.scan(candidate.string, custom: patterns, entropyThreshold: entropyThreshold) {
                let value = String(candidate.string[hit.range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let start = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.lowerBound))
                let end = Double(candidate.string.distance(from: candidate.string.startIndex, to: hit.range.upperBound))
                let count = Double(max(candidate.string.count, 1)), box = mappedBox
                let left = max(Double(box.minX) + Double(box.width) * start / count - Double(box.width) * 0.04, 0)
                let right = min(Double(box.minX) + Double(box.width) * end / count + Double(box.width) * 0.04, 1)
                output.append(OCRDetection(t: time, x: left, y: Double(box.minY), w: max(right - left, 0.001),
                                           h: Double(box.height), category: hit.category,
                                           hash: fnv1a64(value.lowercased(), salt: salt), confidence: candidate.confidence))
            }
        }
        for (label, box) in observations {
            guard let text = label.topCandidates(1).first?.string,
                  text.range(of: "password|passcode|cvv|card number|ssn", options: .regularExpression.union(.caseInsensitive)) != nil else { continue }
            let neighbors = observations.map(\.1).filter { candidate in
                candidate != box && ((candidate.minX >= box.maxX && abs(candidate.midY - box.midY) < box.height * 2)
                    || (candidate.minY >= box.maxY && candidate.minY - box.maxY < 0.08 && abs(candidate.midX - box.midX) < 0.25))
            }
            let nearest = neighbors.min { hypot($0.midX - box.midX, $0.midY - box.midY) < hypot($1.midX - box.midX, $1.midY - box.midY) }
            let field = nearest ?? CGRect(x: box.minX, y: box.maxY, width: max(box.width, 0.18), height: max(box.height * 2, 0.025))
            let region = box.union(field).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            output.append(OCRDetection(t: time, x: region.minX, y: region.minY, w: region.width, h: region.height,
                category: .envSecret, hash: fnv1a64(text.lowercased(), salt: salt), confidence: 1))
        }
        return output
    }

    private func lumaGrid(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        let cols = 256, rows = 144
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
