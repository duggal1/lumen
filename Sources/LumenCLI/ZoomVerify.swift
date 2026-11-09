import Foundation
import ArgumentParser
import AVFoundation
import CoreVideo
import Vision
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenExport

// zoom-verify <project> --video <export.mp4> [--out report.md]
// Measures the VIDEO, never events-vs-events:
//   RAW pass on screen.mov: first magenta-marker frame per click event
//     -> latency (frameT - event.t) and posErr in source px (A11/A12).
//   EXPORT pass on the export: marker viewport position (A6), arrival
//     fraction via apparent marker size (A4), caret bar positions (A7),
//     Vision OCR of the omnibox burst (A8), camera lz in hover spans (A1).
struct ZoomVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "zoom-verify", abstract: "Measure zoom acceptance on the exported video")
    @Argument var project: String
    @Option var video: String
    @Option var out: String?
    @Option var dumpDir: String?

    func run() async throws {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: project))
        let (session, tl0) = try await openProject(project)
        _ = await session.analyze(tl0)   // loads cached typing traces into input
        let tl = session.derive(tl0, revision: 1)
        let events = session.input.events
        let clicks = events.filter { $0.kind == .down && $0.button == 0 }.sorted { $0.t < $1.t }
        let bursts = events.typingBursts()
        let derived = tl.derived
        let cam = derived?.camera
        let src = session.meta.source
        let srcSize = SIMD2(Double(src.width), Double(src.height))

        // ---- RAW pass: latency + posErr per click ----
        var latencies: [Double] = [], posErrs: [Double] = []
        var rawLines: [String] = []
        var rawClicked: [Double] = []
        for c in clicks {
            if let dumpDir {
                if let pb = try? await frameBuffer(url: bundle.screenURL, at: c.t) {
                    try? FrameImage.writePNG(pb, to: URL(fileURLWithPath: "\(dumpDir)/raw-\(String(format: "%.2f", c.t)).png"))
                }
            }
            if let hit = try await firstMarker(url: bundle.screenURL, from: max(0, c.t - 0.05), to: c.t + 0.6,
                                               near: SIMD2(Double(c.x), Double(c.y))) {
                rawClicked.append(c.t)
                let lat = hit.t - c.t
                let err = hypot(hit.c.x - Double(c.x), hit.c.y - Double(c.y))
                latencies.append(lat); posErrs.append(err)
                rawLines.append(String(format: "click t=%.3f lat=%.3fs posErr=%.1fpx at=(%.0f,%.0f) ev=(%d,%d)", c.t, lat, err, hit.c.x, hit.c.y, c.x, c.y))
            } else {
                rawLines.append(String(format: "click t=%.3f marker NOT FOUND", c.t))
            }
        }
        let medLat = latencies.sorted().get(at: latencies.count / 2) ?? 0
        let p95Lat = latencies.sorted().get(at: Int(Double(latencies.count) * 0.95)) ?? 0
        let maxErr = posErrs.max() ?? -1

        // ---- EXPORT pass ----
        let exportURL = URL(fileURLWithPath: video)
        let asset = AVURLAsset(url: exportURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ValidationError("export has no video") }
        let nat = try await track.load(.naturalSize)
        let exportSize = SIMD2<Int>(abs(Int(nat.width)), abs(Int(nat.height)))
        // Scene starts: auto segments with no predecessor within zoomOutGap.
        let autoSorted = tl.zoom.filter { $0.origin == .auto }.sorted { $0.start < $1.start }
        let gap = max(tl.camera.zoomOutGap, 0)
        var sceneStarts: [Double] = []
        for (i, s) in autoSorted.enumerated() {
            if i == 0 || s.start - autoSorted[i - 1].end > gap { sceneStarts.append(s.start) }
        }
        var exportLines: [String] = []
        var arrival: [Double] = []
        var viewportOK = true
        var excluded = [String]()
        for c in clicks {
            // A click with no fixture marker anywhere (not on the fixture tab)
            // cannot be measured on video; report and exclude it explicitly.
            if !rawClicked.contains(where: { abs($0 - c.t) < 0.01 }) {
                excluded.append(String(format: "click t=%.3f excluded: no marker in raw video (not on fixture page)", c.t))
                continue
            }
            let ot = tl.timeMap.output(atSource: c.t)
            if let dumpDir {
                if let pb = try? await frameBuffer(url: exportURL, at: ot) {
                    try? FrameImage.writePNG(pb, to: URL(fileURLWithPath: "\(dumpDir)/export-\(String(format: "%.2f", c.t)).png"))
                }
            }
            let idx = min(Int(ot * gridRate), (cam?.lz.count ?? 1) - 1)
            let scale = exp(Double(cam?.lz[max(idx, 0)] ?? 0))
            let center = SIMD2(Double(cam?.nx[max(idx, 0)] ?? 0.5) * srcSize.x, Double(cam?.ny[max(idx, 0)] ?? 0.5) * srcSize.y)
            let tr = ZoomTransform(canvas: exportSize, source: srcSize, style: tl.style, cameraCenter: center, scale: scale)
            let expected = tr.sourceToCanvas(SIMD2(Double(c.x), Double(c.y)))
            guard let hit = try await firstMarkerInExport(url: exportURL, from: max(0, ot - 0.1), span: 2.2, expected: expected, tol: 450) else {
                exportLines.append(String(format: "click t=%.3f export marker NOT FOUND", c.t)); viewportOK = false; continue
            }
            let srcPt = tr.canvasToSource(hit.c)
            let v = tr.viewport
            let nx = (srcPt.x - v.x) / v.z, ny = (srcPt.y - v.y) / v.w
            let isSceneStart = sceneStarts.contains { abs($0 - c.t) < 0.05 }
            let lo: Double = isSceneStart ? 0.20 : 0.12, hi: Double = isSceneStart ? 0.80 : 0.88
            let inside = nx >= lo && nx <= hi && ny >= 0.08 && ny <= 0.92
            if !inside { viewportOK = false }
            // Arrival: apparent marker width now vs +1 s later, only when the
            // later marker is the same one (isolated, not a typing bar).
            var frac = 0.0
            if let later = try await markerInWindow(url: exportURL, at: hit.t + 1.0),
               let l = later.min(by: { a, b in hypot(a.c.x - hit.c.x, a.c.y - hit.c.y) < hypot(b.c.x - hit.c.x, b.c.y - hit.c.y) }),
               hypot(l.c.x - hit.c.x, l.c.y - hit.c.y) < 80 {
                frac = Double(hit.width) / Double(max(l.width, 1))
                arrival.append(frac)
            } else {
                exportLines.append("  (arrival skipped: marker overlapped at +1s)")
            }
            exportLines.append(String(format: "click t=%.3f sceneStart=%d viewport=(%.2f,%.2f) inBand=%d arrival=%.2f",
                                      c.t, isSceneStart ? 1 : 0, nx, ny, inside ? 1 : 0, frac))
        }
        let minArrival = arrival.min() ?? 0

        // ---- A1: lz in the pre-first-click hover span (excluding the lead-in approach) ----
        let firstClick = clicks.first?.t ?? tl.timeMap.trimEnd
        var maxLzPre = 0.0
        if let cam {
            let upto = max(0.3, firstClick - 1.0)
            let n = min(Int(upto * gridRate), cam.lz.count)
            if n > 1 { maxLzPre = cam.lz[..<n].map { Double($0.magnitude) }.max() ?? 0 }
        }

        // ---- A7: caret bar viewport x at keystroke frames; retargets per burst ----
        var caretLines: [String] = []
        var caretOK = true
        caretLines.append("bursts=\(bursts.map { String(format: "%.2f-%.2f", $0.t0, $0.t1) }.joined(separator: ",")) keyDowns=\(events.filter { $0.kind == .keyDown }.count)")
        let traces = session.input.typing
        for b in bursts {
            let keysInBurst = events.filter { $0.kind == .keyDown && $0.t >= b.t0 - 0.01 && $0.t <= b.t1 + 0.01 }
            var xs: [Double] = []
            var checked = 0
            for k in keysInBurst where checked < 8 {
                let ot = tl.timeMap.output(atSource: k.t)
                let tr2 = traces.first { $0.t0 <= b.t1 && $0.t1 >= b.t0 }
                let expSrc: SIMD2<Double>
                if let tr2, let smp = tr2.samples.last(where: { $0.t <= k.t }) {
                    expSrc = SIMD2(smp.x, smp.y)
                } else {
                    expSrc = SIMD2(srcSize.x / 2, 120)   // omnibox / input fallback
                }
                let idx = min(Int(ot * gridRate), (cam?.lz.count ?? 1) - 1)
                let scale = exp(Double(cam?.lz[max(idx, 0)] ?? 0))
                let center = SIMD2(Double(cam?.nx[max(idx, 0)] ?? 0.5) * srcSize.x, Double(cam?.ny[max(idx, 0)] ?? 0.5) * srcSize.y)
                let tr = ZoomTransform(canvas: exportSize, source: srcSize, style: tl.style, cameraCenter: center, scale: scale)
                let expected = tr.sourceToCanvas(expSrc)
                if let hit = try await firstMarkerInExport(url: exportURL, from: max(0, ot - 0.1), span: 1.2, expected: expected, tol: 500) {
                    let srcPt = tr.canvasToSource(hit.c)
                    let v = tr.viewport
                    xs.append((srcPt.x - v.x) / v.z)
                    checked += 1
                }
            }
            let retargets = tl.zoom.filter { $0.origin == .auto && $0.start > b.t0 + 0.05 && $0.start < b.t1 }.count
            let inBand = xs.allSatisfy { $0 >= 0.10 && $0 <= 0.90 }
            if !xs.isEmpty && !inBand { caretOK = false }
            caretLines.append("burst t=\(String(format: "%.2f", b.t0))-\(String(format: "%.2f", b.t1)) caretX=[\(xs.map { String(format: "%.2f", $0) }.joined(separator: ","))] retargets=\(retargets)")
        }

        // ---- A8: OCR every burst at t1+0.2..+2.2 (omnibox has no click anchor) ----
        var ocrLines: [String] = []
        for b in bursts {
            let ot = tl.timeMap.output(atSource: b.t1 + 0.2)
            var found: [OCRHit] = []
            for dt in stride(from: 0.0, through: 2.0, by: 0.4) {
                guard let pb = try await frameBuffer(url: exportURL, at: ot + dt) else { continue }
                let texts = recognize(pb)
                if let h = texts.first(where: { $0.text.contains("example") }) { found = texts; _ = h; break }
                found = texts
            }
            if let h = found.first(where: { $0.text.contains("example") }) {
                // Vision boxes are bottom-left origin; convert to top-origin.
                let topY = 1 - h.y - h.h
                let central = h.x >= 0.10 && h.x + h.w <= 0.90 && topY >= 0.10 && topY + h.h <= 0.90
                ocrLines.append("burst \(String(format: "%.2f", b.t0)): found '\(h.text)' bbox=(\(String(format: "%.2f", h.x)),\(String(format: "%.2f", 1 - h.y - h.h))) central80=\(central ? 1 : 0)")
            } else {
                ocrLines.append("burst \(String(format: "%.2f", b.t0)): example NOT FOUND; texts=[\(found.prefix(6).map(\.text).joined(separator: "|"))]")
            }
        }
        let ocrLine = ocrLines.isEmpty ? "omnibox OCR: no typing burst" : ocrLines.joined(separator: "\n")

        // ---- Zoom-in count (from rest) ----
        let autoSegs = tl.zoom.filter { $0.origin == .auto }.sorted { $0.start < $1.start }
        var zoomIns = 0
        for (a, b2) in zip(autoSegs, autoSegs.dropFirst()) {
            if b2.start - a.end > 0.05 { zoomIns += 1 }
        }
        if !autoSegs.isEmpty { zoomIns += 1 }

        // ---- A10: camera smoothness at gridRate from derived.camera ----
        var smoothLine = "A10: no camera"
        if let cam, cam.lz.count > 2 {
            let rate = gridRate
            func maxDelta(_ a: [Float]) -> Double {
                var m = 0.0
                for i in 1..<a.count { m = max(m, abs(Double(a[i]) - Double(a[i - 1]))) }
                return m
            }
            let dvz = maxDelta(cam.vz), dvx = maxDelta(cam.vx)
            let mvz = cam.vz.map { Double($0.magnitude) }.max() ?? 0
            // Δa = Δv again (v already derived); ratio to max |v|
            let ratioZ = mvz > 0 ? dvz / mvz : 0
            var hf = 0.0, tot = 0.0   // crude HF energy: |Δ²x| above Nyquist proxy
            for i in 1..<cam.nx.count {
                let d2 = abs(Double(cam.nx[i]) - 2 * Double(cam.nx[i - 1]) + Double(cam.nx[i - 2]))
                hf += d2 * d2
                let d1 = abs(Double(cam.nx[i]) - Double(cam.nx[i - 1]))
                tot += d1 * d1
            }
            let hfFrac = tot > 0 ? hf / tot : 0
            smoothLine = String(format: "A10: maxΔv/max|v| z=%.4f x=%.4f (needs <= 0.02), HF frac=%.5f", ratioZ, mvz > 0 ? dvx / mvz : 0, hfFrac)
        }

        let report = """
        # Zoom acceptance — measured on real video

        RAW screen.mov (event↔video):
        \(rawLines.joined(separator: "\n"))
        latency median=\(String(format: "%.3f", medLat))s p95=\(String(format: "%.3f", p95Lat))s
        max posErr=\(String(format: "%.1f", maxErr))px (A12 needs <= 2px)

        EXPORT \(video):
        \(exportLines.joined(separator: "\n"))
        min arrival=\(String(format: "%.2f", minArrival)) (A4 needs >= 0.93)

        A1 pre-first-click max|lz|=\(String(format: "%.3f", maxLzPre)) (needs <= 0.01)
        A2 zoom-ins=\(zoomIns) (needs 3 +/- 1)
        A6 viewportOK=\(viewportOK ? 1 : 0) (scene-start [0.20,0.80], others [0.12,0.88])
        A7 caretOK=\(caretOK ? 1 : 0)
        \(smoothLine)
        \(excluded.joined(separator: "\n"))
        \(caretLines.joined(separator: "\n"))
        \(ocrLine)
        """
        print(report)
        if let out { try report.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8) }
        _ = tl0
    }
}

private extension Array {
    func get(at i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

private struct MarkerHit { var t: Double; var c: SIMD2<Double>; var width: Int }

private func isMagenta(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> Bool {
    // Tolerant: survives H.264 chroma + 50%-faded marker over white.
    let m = min(r, b)
    return m > 180 && Int(m) - Int(g) > 60
}

/// Magenta clusters over a frame. Each hit is one cluster (one click marker
/// or one caret bar): centroid + apparent width. Separate markers never merge
/// unless they overlap, which is exactly the ambiguity we must not hide.
private func markerClusters(_ base: UnsafePointer<UInt8>, w: Int, h: Int, rowBytes: Int, cell: Int) -> [MarkerHit] {
    let cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
    var hit = [Bool](repeating: false, count: cols * rows)
    for cy in 0..<rows {
        for cx in 0..<cols {
            var found = false
            outer: for y in stride(from: cy * cell, to: min((cy + 1) * cell, h), by: 2) {
                let row = base + y * rowBytes
                for x in stride(from: cx * cell, to: min((cx + 1) * cell, w), by: 2) {
                    let q = row + x * 4
                    if isMagenta(q[0], q[1], q[2]) { found = true; break outer }
                }
            }
            hit[cy * cols + cx] = found
        }
    }
    var seen = [Bool](repeating: false, count: cols * rows)
    var out: [MarkerHit] = []
    for s in hit.indices where hit[s] && !seen[s] {
        var stack = [s]
        seen[s] = true
        var n = 0, sx = 0.0, sy = 0.0
        var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
        while let i = stack.popLast() {
            let cx = i % cols, cy = i / cols
            n += 1; sx += Double(cx * cell); sy += Double(cy * cell)
            minX = min(minX, cx * cell); maxX = max(maxX, cx * cell)
            minY = min(minY, cy * cell); maxY = max(maxY, cy * cell)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < cols, ny >= 0, ny < rows else { continue }
                let j = ny * cols + nx
                if hit[j] && !seen[j] { seen[j] = true; stack.append(j) }
            }
        }
        if n >= 8 {
            // Weighted centroid over the bbox (magenta-ness weights): robust
            // to H.264 edge ringing, unlike the raw bbox center.
            var sx = 0.0, sy = 0.0, sw = 0.0
            for y in minY...maxY {
                let row = base + y * rowBytes
                for x in minX...maxX {
                    let q = row + x * 4
                    if isMagenta(q[0], q[1], q[2]) {
                        let wgt = Double(min(q[2], q[0])) - Double(q[1])
                        sx += Double(x) * wgt; sy += Double(y) * wgt; sw += wgt
                    }
                }
            }
            let c = sw > 0 ? SIMD2(sx / sw + 0.0, sy / sw + 0.0) : SIMD2(Double(minX + maxX) / 2, Double(minY + maxY) / 2)
            out.append(MarkerHit(t: 0, c: c, width: maxX - minX))
        }
    }
    return out
}

private func firstMarker(url: URL, from a: Double, to b: Double, near event: SIMD2<Double>) async throws -> MarkerHit? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    guard reader.canAdd(out) else { return nil }
    reader.add(out)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
    guard reader.startReading() else { return nil }
    var points: [(t: Double, c: SIMD2<Double>)] = []
    var width = 0
    while let s = out.copyNextSampleBuffer() {
        let t = CMSampleBufferGetPresentationTimeStamp(s).seconds
        guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { continue }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let clusters = markerClusters(base, w: w, h: h, rowBytes: rb, cell: 6)
        if let hit = clusters.min(by: { a, b in hypot(a.c.x - event.x, a.c.y - event.y) < hypot(b.c.x - event.x, b.c.y - event.y) }),
           hypot(hit.c.x - event.x, hit.c.y - event.y) < 60, hit.width >= 40 {
            points.append((t, hit.c))
            width = max(width, hit.width)
        }
    }
    guard let first = points.first else { return nil }
    // The marker is a static square: median centroid over its full-opacity
    // early frames is the robust estimate (later faded frames leak the
    // background text through and bias the centroid).
    let early = points.filter { $0.t <= first.t + 0.35 }
    let xs = early.map(\.c.x).sorted(), ys = early.map(\.c.y).sorted()
    let med = SIMD2(xs[xs.count / 2], ys[ys.count / 2])
    return MarkerHit(t: first.t, c: med, width: width)
}

private func frameBuffer(url: URL, at t: Double) async throws -> CVPixelBuffer? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    guard reader.canAdd(out) else { return nil }
    reader.add(out)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - 0.05), preferredTimescale: 600),
                                   end: CMTime(seconds: t + 0.05, preferredTimescale: 600))
    guard reader.startReading() else { return nil }
    while let s = out.copyNextSampleBuffer() {
        let st = CMSampleBufferGetPresentationTimeStamp(s).seconds
        if st >= t - 0.02, let pb = CMSampleBufferGetImageBuffer(s) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            // Copy out: the reader owns the buffer.
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            var copy: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &copy) == kCVReturnSuccess,
                  let out2 = copy else { return nil }
            CVPixelBufferLockBaseAddress(out2, [])
            defer { CVPixelBufferUnlockBaseAddress(out2, []) }
            guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self),
                  let dst = CVPixelBufferGetBaseAddress(out2)?.assumingMemoryBound(to: UInt8.self) else { return out2 }
            let rb = CVPixelBufferGetBytesPerRow(pb), drb = CVPixelBufferGetBytesPerRow(out2)
            for y in 0..<h { memcpy(dst + y * drb, base + y * rb, min(rb, drb)) }
            return out2
        }
    }
    return nil
}

private func markerInWindow(url: URL, at t: Double, maxHits: Int = 4) async throws -> [MarkerHit]? {
    guard let pb = try await frameBuffer(url: url, at: t) else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
    let hits = markerClusters(base, w: w, h: h, rowBytes: rb, cell: 4)
    return hits.isEmpty ? nil : hits
}

/// First exported frame in [t, t+span] whose nearest magenta cluster to the
/// expected canvas position is within tol canvas px.
private func firstMarkerInExport(url: URL, from t: Double, span: Double, expected: SIMD2<Double>, tol: Double = 220) async throws -> MarkerHit? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    guard reader.canAdd(out) else { return nil }
    reader.add(out)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), end: CMTime(seconds: t + span, preferredTimescale: 600))
    guard reader.startReading() else { return nil }
    while let s = out.copyNextSampleBuffer() {
        let st = CMSampleBufferGetPresentationTimeStamp(s).seconds
        guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { continue }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let clusters = markerClusters(base, w: w, h: h, rowBytes: rb, cell: 4)
        if let hit = clusters.min(by: { a, b in hypot(a.c.x - expected.x, a.c.y - expected.y) < hypot(b.c.x - expected.x, b.c.y - expected.y) }),
           hypot(hit.c.x - expected.x, hit.c.y - expected.y) < tol {
            return MarkerHit(t: st, c: hit.c, width: hit.width)
        }
    }
    return nil
}

private struct OCRHit { var text: String; var x: Double, y: Double, w: Double, h: Double }

private func recognize(_ pb: CVPixelBuffer) -> [OCRHit] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
    try? handler.perform([request])
    return (request.results ?? []).compactMap { obs -> OCRHit? in
        guard let cand = obs.topCandidates(1).first, !cand.string.isEmpty else { return nil }
        let b = obs.boundingBox
        return OCRHit(text: cand.string, x: b.minX, y: b.minY, w: b.width, h: b.height)
    }
}
