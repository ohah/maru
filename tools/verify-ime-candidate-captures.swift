// Independent post-run oracle: re-open the selected window images instead of trusting the
// producer's OCR count. It has no window inventory or permission-changing responsibilities.
import Foundation
import CryptoKit
import Vision
import ImageIO

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "MaruCandidateCapture", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
}
func verify() throws {
    try require(CommandLine.arguments.count == 2, "artifact argument required")
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let data = try Data(contentsOf: url)
    try require(data.count <= 16 * 1024, "artifact size")
    let artifact = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let schema = artifact["schema"] as? String
    try require(schema == "maru.session-host-cr6d-ime-candidate-observation.v1" ||
                schema == "maru.session-host-cr6d-ime-candidate-observation.v2" || schema == "maru.editor-ime-wrapped-candidate.v1", "schema")
    try require(Set(artifact.keys) == Set(["schema", "source_id", "rows"]), "unexpected artifact fields")
    let artifactRows = artifact["rows"] as? [[String: Any]] ?? []
    try require(artifactRows.count == 5, "five observations required")
    if schema == "maru.session-host-cr6d-ime-candidate-observation.v1" {
        for row in artifactRows {
            try require(row["apple_signed"] as? Bool == true && (row["owner_pid"] as? NSNumber)?.intValue ?? 0 > 0 &&
                        !(row["bundle_id"] as? String ?? "").isEmpty && !(row["signing_id"] as? String ?? "").isEmpty,
                        "external Apple owner required")
            try require(row["app_capture"] == nil || row["app_capture"] is NSNull, "app proof in external schema")
        }
    }
    if schema == "maru.session-host-cr6d-ime-candidate-observation.v2" || schema == "maru.editor-ime-wrapped-candidate.v1" {
        try require(artifact["source_id"] as? String == "com.apple.inputmethod.Korean.2SetKorean", "input source")
        let rows = artifact["rows"] as? [[String: Any]] ?? []
        try require(rows.count == 5, "five observations required")
        var names = Set<String>()
        var ids = Set<UInt32>()
        for row in rows {
            guard let proof = row["app_capture"] as? [String: Any],
                  let name = proof["capture_basename"] as? String,
                  let windowID = row["window_id"] as? NSNumber,
                  let proofID = proof["window_id"] as? NSNumber else { throw NSError(domain: "MissingCapture", code: 1) }
            try require(windowID == proofID && ids.insert(windowID.uint32Value).inserted, "capture window binding")
            try require(name.hasPrefix("candidate-") && name.hasSuffix("-\(windowID).png") &&
                        !name.contains("/") && !name.contains("..") && names.insert(name).inserted, "capture path")
            if schema == "maru.editor-ime-wrapped-candidate.v1" {
                guard let anchor = row["anchor_quartz"] as? [String: Double], let bounds = row["bounds"] as? [String: Double],
                      let x = anchor["x"], let y = anchor["y"], let h = anchor["h"], let bx = bounds["x"], let by = bounds["y"], let bh = bounds["h"], let delta = row["wrapped_delta_y"] as? Double else { throw NSError(domain: "MissingWrappedGeometry", code: 1) }
                try require(h > 0 && delta >= h && abs(bx - x) <= h * 2 && max(0, max(by - (y + h), y - (by + bh))) <= h * 2, "wrapped candidate geometry")
            }
            let imageURL = url.deletingLastPathComponent().appendingPathComponent(name)
            let values = try imageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            try require(values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 8 * 1024 * 1024, "capture file")
            let pixels = try Data(contentsOf: imageURL)
            let digest = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
            try require(digest == proof["sha256"] as? String, "capture digest mismatch")
            guard let source = CGImageSourceCreateWithData(pixels as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "InvalidImage", code: 1) }
            try require(image.width == (proof["width"] as? NSNumber)?.intValue &&
                        image.height == (proof["height"] as? NSNumber)?.intValue, "capture dimensions")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Classify the Hanja column; Korean-first OCR misreads these glyphs as Hangul.
            request.recognitionLanguages = ["zh-Hant"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let hanjaRows = (request.results ?? []).filter { observation in
                guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return false }
                return text.string.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            }
            let expected = Set("韓漢寒汗翰恨閑限罕邯".unicodeScalars)
            let recognised = hanjaRows.compactMap { $0.topCandidates(1).first?.string }.joined()
            try require(Set(hanjaRows.map { Int($0.boundingBox.midY * 100) }).count >= 3 &&
                        recognised.unicodeScalars.contains(where: { expected.contains($0) }), "not a han candidate list")
            try require(hanjaRows.count >= 3 && hanjaRows.count == (proof["hanja_rows"] as? NSNumber)?.intValue,
                        "candidate rows not independently confirmed")
        }
    }
    print("candidate_capture_verifier=passed")
}

do { try verify() }
catch {
    FileHandle.standardError.write(Data("candidate_capture_verifier=failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
