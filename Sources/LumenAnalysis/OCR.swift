import Foundation
import AVFoundation
import Vision
import CoreImage
import os
import LumenCore
import LumenProject

public enum OCRAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, projectSalt: UInt64, customPatterns: [String] = [],
                              entropyThreshold: Double = 3.5, fps: Double = 4, duration: Double = 0, firstFrameOnly: Bool = false,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [OCRDetection] {
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let job = OCRJob(asset: asset, track: track, offset: offset, salt: projectSalt, patterns: customPatterns,
                         entropyThreshold: entropyThreshold, fps: fps, duration: duration, firstFrameOnly: firstFrameOnly, progress: progress)
        return try await withTaskCancellationHandler {
            try await job.value()
        } onCancel: { job.cancel() }
    }
}

struct PartialScan: Error, Sendable { let detections: [OCRDetection] }
private struct OCRImage: @unchecked Sendable { let image: CGImage }
private struct OCRLine: @unchecked Sendable { let observation: VNRecognizedTextObservation; let box: CGRect; let tile: CGRect }

private struct OCRRequestHandle: @unchecked Sendable { let request: VNRecognizeTextRequest }

private final class OCRJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let salt: UInt64
    private let patterns: [String]
    private let entropyThreshold: Double
    private let fps: Double
    private let duration: Double
    private let firstFrameOnly: Bool
    private let progress: @Sendable (Double) -> Void
    private let completion = OSAllocatedUnfairLock<(continuation: CheckedContinuation<[OCRDetection], Error>?, result: Result<[OCRDetection], Error>?)>(uncheckedState: (nil, nil))
    private let requestLock = OSAllocatedUnfairLock<[OCRRequestHandle]>(uncheckedState: [])
    private let partial = OSAllocatedUnfairLock<[OCRDetection]>(initialState: [])
    private var trackingRequests: [VNTrackObjectRequest] = []
    private var trackingBuffer: CVPixelBuffer?
    private let trackingHandler = VNSequenceRequestHandler()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, salt: UInt64, patterns: [String], entropyThreshold: Double, fps: Double, duration: Double, firstFrameOnly: Bool, progress: @escaping @Sendable (Double) -> Void) {
        self.asset = asset; self.track = track; self.offset = offset; self.salt = salt; self.patterns = patterns
        self.entropyThreshold = entropyThreshold; self.fps = fps; self.duration = duration; self.firstFrameOnly = firstFrameOnly; self.progress = progress
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
        requestLock.withLock { $0.forEach { $0.request.cancel() } }
        let found = partial.withLock { $0 }
        resolve(.failure(found.isEmpty ? CancellationError() : PartialScan(detections: deduplicate(found))))
    }

    func value() async throws -> [OCRDetection] {
        try await withCheckedThrowingContinuation { continuation in
            let prior = completion.withLock { state -> Result<[OCRDetection], Error>? in
                if let result = state.result { return result }
                state.continuation = continuation; return nil
            }
            if let prior { continuation.resume(with: prior); return }
            DispatchQueue.global(qos: .utility).async { [self] in
                do { resolve(.success(try run())) }
                catch {
                    let found = partial.withLock { $0 }
                    resolve(.failure(found.isEmpty ? error : PartialScan(detections: deduplicate(found))))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(180, duration * 2)) { [weak self] in
                guard let self, self.completion.withLock({ $0.result == nil }) else { return }
                self.resolve(.failure(PartialScan(detections: self.deduplicate(self.partial.withLock { $0 }))))
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
        defer { retireTrackers() }
        var next = 0.0
        var lastDetections: [OCRDetection] = []
        var detections: [OCRDetection] = []
        var previousTiles: LumaTiles?
        var previousSignatures: [UInt64]?
        var trackingActive = false
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let previous = lastDetections.first, time + offset - previous.t > 0.5 {
                for held in stride(from: previous.t + 0.25, to: time + offset, by: 0.25) {
                    detections.append(contentsOf: lastDetections.map { var value = $0; value.t = held; return value })
                }
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if time + 0.0001 < next {
                if trackingActive, time >= nextTrack, !lastDetections.isEmpty {
                    nextTrack = time + 1.0 / 15
                    lastDetections = try track(lastDetections, buffer: buffer, time: time + offset, handler: trackingHandler)
                    detections.append(contentsOf: lastDetections)
                }
                continue
            }
            next = time + 1 / max(fps, 0.5)
            progress(min(max(time / max(duration, asset.duration.seconds, 0.001), 0), 0.99))
            retireTrackers()
            let snapshot = try lumaSnapshot(buffer)
            let tiles = snapshot.tiles
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let changed = DirtyRects.between(previousTiles, tiles, previousSignatures: previousSignatures, signatures: snapshot.signatures)
                .map { $0.intersection(extent) }.filter { !$0.isEmpty }
            let protected = lastDetections.map { detection in
                CGRect(x: detection.x * Double(width), y: detection.y * Double(height),
                    width: detection.w * Double(width), height: detection.h * Double(height))
            }
            let dirty = DirtyRects.covering(changed, protected: protected, extent: extent)
            previousTiles = tiles
            previousSignatures = snapshot.signatures
            trackingActive = dirty.reduce(0) { $0 + $1.width * $1.height } > extent.width * extent.height * 0.4
            let kept = lastDetections.filter { detection in
                let rect = CGRect(x: detection.x * Double(width), y: detection.y * Double(height),
                    width: detection.w * Double(width), height: detection.h * Double(height))
                return !dirty.contains { $0.intersects(rect) }
            }.map { detection in var value = detection; value.t = time + offset; return value }
            let fresh = dirty.isEmpty ? [] : try detect(in: buffer, regions: dirty, at: time + offset)
            lastDetections = kept + fresh
            detections.append(contentsOf: lastDetections)
            let accumulated = detections
            partial.withLock { $0 = accumulated }
            if firstFrameOnly { reader.cancelReading(); break }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        if let previous = lastDetections.first {
            let end = max(duration, asset.duration.seconds) + offset
            for held in stride(from: previous.t + 0.25, through: end, by: 0.25) {
                detections.append(contentsOf: lastDetections.map { var value = $0; value.t = held; return value })
            }
        }
        progress(1)
        return deduplicate(detections)
    }

    private func retireTrackers() {
        guard !trackingRequests.isEmpty else { return }
        for request in trackingRequests { request.isLastFrame = true }
        if let buffer = trackingBuffer { try? trackingHandler.perform(trackingRequests, on: buffer) }
        trackingRequests.removeAll(); trackingBuffer = nil
    }

    private func track(_ detections: [OCRDetection], buffer: CVPixelBuffer, time: Double,
                       handler: VNSequenceRequestHandler) throws -> [OCRDetection] {
        trackingBuffer = buffer
        if trackingRequests.isEmpty {
            trackingRequests = detections.map { detection in
                let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: detection.x,
                    y: 1 - detection.y - detection.h, width: detection.w, height: detection.h))
                let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                request.trackingLevel = .fast
                return request
            }
        }
        try handler.perform(trackingRequests, on: buffer)
        return zip(detections, trackingRequests).map { prior, request in
            var result = prior; result.t = time
            if let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence >= 0.3 {
                request.inputObservation = observation
                let rect = observation.boundingBox
                result.x = rect.minX; result.y = 1 - rect.maxY; result.w = rect.width; result.h = rect.height
            }
            return result
        }
    }

    private func detect(in buffer: CVPixelBuffer, regions: [CGRect], at time: Double) throws -> [OCRDetection] {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let full = context.createCGImage(image, from: image.extent) else { throw AnalysisError.pixelBuffer }
        let width = full.width, height = full.height, tile = 1536, step = 1408
        var tiles: [CGRect] = []
        for region in regions {
            for y in stride(from: Int(region.minY), to: Int(region.maxY.rounded(.up)), by: step) {
                for x in stride(from: Int(region.minX), to: Int(region.maxX.rounded(.up)), by: step) {
                    tiles.append(CGRect(x: x, y: y, width: min(tile, Int(region.maxX.rounded(.up)) - x),
                        height: min(tile, Int(region.maxY.rounded(.up)) - y)))
                }
            }
        }
        let work = tiles, source = OCRImage(image: full)
        let collected = OSAllocatedUnfairLock<[OCRLine]>(uncheckedState: [])
        let failures = OSAllocatedUnfairLock<[Error]>(uncheckedState: [])
        let workers = min(3, work.count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: work.count, by: max(workers, 1)) {
                if self.cancelled.withLock({ $0 }) { return }
                let rect = work[index]
                guard let crop = source.image.cropping(to: rect) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.minimumTextHeight = 0
                let requestHandle = OCRRequestHandle(request: request)
                self.requestLock.withLock { $0.append(requestHandle) }
                defer { self.requestLock.withLock { $0.removeAll { $0.request === requestHandle.request } } }
                do {
                    try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                    let lines = (request.results ?? []).map { observation in
                        OCRLine(observation: observation, box: Self.normalized(observation.boundingBox, tile: rect, width: width, height: height), tile: rect)
                    }
                    collected.withLock { $0.append(contentsOf: lines) }
                } catch { failures.withLock { $0.append(error) } }
            }
        }
        if let error = failures.withLock({ $0.first }) { throw error }
        let observations = collected.withLock { $0 }
        var output: [OCRDetection] = []
        let confidence = Float(min(max((entropyThreshold - 3) * 0.2 + 0.15, 0.1), 0.5))
        for line in observations {
            let observation = line.observation
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= confidence else { continue }
            for hit in SensitivePatterns.scan(candidate.string, custom: patterns, entropyThreshold: entropyThreshold) {
                let value = String(candidate.string[hit.range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let tight = try? candidate.boundingBox(for: hit.range)
                let box = tight.map { Self.normalized($0.boundingBox, tile: line.tile, width: width, height: height) }
                let safeBox = box.flatMap { $0.isEmpty ? nil : $0 } ?? line.box
                output.append(OCRDetection(t: time, x: safeBox.minX, y: safeBox.minY, w: safeBox.width, h: safeBox.height,
                    category: hit.category, hash: fnv1a64(value.lowercased(), salt: salt), confidence: candidate.confidence))
            }
        }
        for line in observations {
            let label = line.observation, box = line.box
            guard let text = label.topCandidates(1).first?.string,
                  text.range(of: "password|passcode|cvv|card number|ssn", options: .regularExpression.union(.caseInsensitive)) != nil else { continue }
            let neighbors = observations.map(\.box).filter { candidate in
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

    private static func normalized(_ rect: CGRect, tile: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: (tile.minX + rect.minX * tile.width) / Double(width),
            y: (tile.minY + (1 - rect.maxY) * tile.height) / Double(height),
            width: rect.width * tile.width / Double(width), height: rect.height * tile.height / Double(height))
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
