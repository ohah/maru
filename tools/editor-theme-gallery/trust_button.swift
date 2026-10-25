// Read an owned fixture's existing trust button; never synthesize a decision.
import Foundation
import Vision
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(2) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image).perform([request])
let observations = request.results ?? []
let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
guard text.lowercased().contains("run language servers for this workspace?") else { exit(3) }
// Startup can briefly paint the initial 80-column layout before the fixture's
// real-window resize. Accept only the lower button, after that resize settles.
// Vision sometimes combines both button labels into one observation. Ask for
// the word's own box rather than clicking the combined line's midpoint.
var boxes: [CGRect] = []
for observation in observations where observation.boundingBox.midY < 0.5 {
    guard let candidate = observation.topCandidates(1).first,
          candidate.string.hasPrefix("Run"),
          let range = candidate.string.range(of: "Run"),
          let word = try candidate.boundingBox(for: range) else { continue }
    boxes.append(word.boundingBox)
}
guard let button = boxes.min(by: { $0.midY < $1.midY }) else { exit(4) }
let point: [String: Double] = ["x": button.midX * Double(image.width),
                               "y": (1 - button.midY) * Double(image.height)]
let data = try JSONSerialization.data(withJSONObject: point, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
