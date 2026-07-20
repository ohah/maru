import CryptoKit
import Darwin
import Foundation

/// Reads the bundled Mermaid program through one no-follow descriptor and accepts only the
/// build-time digest embedded in the signed helper executable. Path metadata is not an authority:
/// the bytes, both identity checks, and the digest all belong to the same open file description.
enum MermaidScriptLoader {
    static func load(url: URL, maxBytes: Int, expectedSHA256: [UInt8]) -> String? {
        guard expectedSHA256.count == SHA256.byteCount else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var before = Darwin.stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0,
              before.st_size <= maxBytes else { return nil }

        let byteCount = Int(before.st_size)
        var data = Data(count: byteCount)
        let readSucceeded = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(descriptor, base.advanced(by: offset), byteCount - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard readSucceeded else { return nil }

        var after = Darwin.stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_mode == before.st_mode,
              after.st_size == before.st_size,
              Array(SHA256.hash(data: data)) == expectedSHA256 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
