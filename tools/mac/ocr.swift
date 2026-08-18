// ocr — read the text out of a screenshot with the Vision framework, so a
// GUI test can assert on what the user can actually see rather than on
// the state the program believes it is in.
//
//   ocr <image.png> [--boxes]
//
// Prints one recognized line per line of output. With --boxes, each line
// is prefixed with "<x> <y> <w> <h>\t" in pixels, top-left origin.
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: ocr <image.png> [--boxes]\n".data(using: .utf8)!)
    exit(2)
}
let boxes = args.contains("--boxes")
guard let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("ocr: cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write("ocr: \(error)\n".data(using: .utf8)!)
    exit(1)
}
let w = Double(cg.width), h = Double(cg.height)
for observation in (request.results ?? []) {
    guard let candidate = observation.topCandidates(1).first else { continue }
    if boxes {
        let b = observation.boundingBox      // normalized, bottom-left origin
        let x = Int(b.minX * w), y = Int((1 - b.maxY) * h)
        print("\(x) \(y) \(Int(b.width * w)) \(Int(b.height * h))\t\(candidate.string)")
    } else {
        print(candidate.string)
    }
}
