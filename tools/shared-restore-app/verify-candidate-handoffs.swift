// Independent pixel oracle. Reopens exactly the two selected captures and reruns OCR.
import Foundation
import CryptoKit
import Vision
import ImageIO

func require(_ condition: Bool, _ name: String) throws {
    if !condition { throw NSError(domain: "CandidateHandoff", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
}
func verify() throws {
    try require(CommandLine.arguments.count == 2, "artifact path required")
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let data = try Data(contentsOf: url)
    try require(data.count <= 1_048_576, "artifact bound")
    guard let artifact = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          artifact["schema"] as? String == "maru.editor-ime-candidate-handoff.v1",
          artifact["source_id"] as? String == "com.apple.inputmethod.Korean.2SetKorean",
          let rows = artifact["rows"] as? [[String: Any]], rows.count == 2 else { throw NSError(domain: "Artifact", code: 1) }
    var names = Set<String>()
    for (index, row) in rows.enumerated() {
        guard let proof = row["app_capture"] as? [String: Any], let name = proof["capture_basename"] as? String,
              let wid = row["window_id"] as? NSNumber, let proofID = proof["window_id"] as? NSNumber,
              let digest = proof["sha256"] as? String, let width = proof["width"] as? NSNumber,
              let height = proof["height"] as? NSNumber, let count = proof["hanja_rows"] as? NSNumber else { throw NSError(domain: "Capture", code: 1) }
        try require(wid == proofID && name == "candidate-\(index)-\(wid).png" && names.insert(name).inserted, "window/path binding")
        let imageURL = url.deletingLastPathComponent().appendingPathComponent(name)
        let info = try imageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        try require(info.isSymbolicLink != true && (info.fileSize ?? Int.max) <= 8 * 1024 * 1024, "capture file")
        let pixels = try Data(contentsOf: imageURL)
        try require(SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined() == digest, "capture SHA")
        guard let source = CGImageSourceCreateWithData(pixels as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "Image", code: 1) }
        try require(image.width == width.intValue && image.height == height.intValue, "capture dimensions")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let hanja = (request.results ?? []).filter {
            guard let text = $0.topCandidates(1).first, text.confidence >= 0.3 else { return false }
            return text.string.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        }
        let expected = Set("韓漢寒汗翰恨閑限罕邯".unicodeScalars)
        let recognised = hanja.compactMap { $0.topCandidates(1).first?.string }.joined()
        try require(hanja.count >= 3 && Set(hanja.map { Int($0.boundingBox.midY * 100) }).count >= 3 &&
                    recognised.unicodeScalars.contains(where: { expected.contains($0) }), "not a han candidate list")
        try require(hanja.count == count.intValue, "OCR count mismatch")
    }
    print("candidate_handoff_pixel_verifier=passed")
}
do { try verify() }
catch { FileHandle.standardError.write(Data("candidate_handoff_pixel_verifier=failed: \(error.localizedDescription)\n".utf8)); exit(1) }
