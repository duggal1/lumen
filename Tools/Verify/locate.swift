// locate — OCR a screenshot and print text bounding boxes in screen points.
// Build: swiftc -O -o Tools/Verify/locate Tools/Verify/locate.swift -framework Vision -framework AppKit
import Foundation
import AppKit
import Vision

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: locate <png> [needle]\n", stderr); exit(2) }
guard let image = NSImage(contentsOfFile: args[1]) else { fputs("cannot read image\n", stderr); exit(2) }
var rect = CGRect(origin: .zero, size: image.size)
guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { exit(2) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([request])
let W = Double(cg.width), H = Double(cg.height)
let scale = 2.0                      // screenshot is Retina; points = pixels / 2
for obs in (request.results ?? []) {
    guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { continue }
    let b = obs.boundingBox
    let x = b.minX * W / scale, y = (1 - b.maxY) * H / scale
    let w = b.width * W / scale, h = b.height * H / scale
    print(String(format: "%.1f %.1f %.1f %.1f  %@", x, y, w, h, text))
}
