import AppKit
import CoreGraphics
import Foundation
import Security
import CryptoKit
import Vision
import ImageIO

/// CR6d-v2b0b의 WindowServer 생산자다. 창을 고르는 판단은 Zig reducer만 소유하고,
/// 이 타입은 title 없는 bounded inventory를 한 실행의 메모리에만 보존한다.
final class SessionHostIMECandidateObservation {
    static let requiredObservationCount = 5
    static let maximumWindowCount = 256
    private static let maximumTranscriptBytes = 1_048_576

    struct Counters: Codable {
        let pty_input_bytes: UInt64
        let committed_text_callbacks: UInt64
        let base_screen_generation: UInt64
    }

    struct Bounds: Codable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    struct Owner: Codable {
        let pid: Int32
        let bundle_id: String
        let signing_id: String
        let apple_signed: Bool
    }

    struct Window: Codable {
        let id: UInt32
        let owner: Owner
        let layer: Int32
        let bounds: Bounds
        let on_screen: Bool
    }

    struct Display: Codable {
        let id: UInt32
        let appkit_frame: Bounds
        let quartz_bounds: Bounds
    }

    struct AppCapture: Codable {
        let window_id: UInt32
        let capture_basename: String
        let sha256: String
        let width: UInt32
        let height: UInt32
        let hanja_rows: UInt32
    }

    struct Snapshot: Codable {
        var app_captures: [AppCapture] = []
        let windows: [Window]
        let counters: Counters
        let anchor_appkit: Bounds
        let displays: [Display]
    }

    struct Row: Codable {
        let before: Snapshot
        let opened: Snapshot
        let closed: Snapshot
    }

    private struct Transcript: Codable {
        let schema: String
        let app_pid: Int32
        let source_id: String
        let rows: [Row]
    }

    private(set) var rows: [Row] = []

    enum Failure: Error {
        case windowServerUnavailable
        case inventoryTooLarge
        case malformedWindow
        case invalidOutput
        case transcriptTooLarge
        case rejected(UInt32)
    }

    func capture(counters: Counters, anchor: CGRect) throws -> Snapshot {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { throw Failure.windowServerUnavailable }
        guard raw.count <= Self.maximumWindowCount else { throw Failure.inventoryTooLarge }
        var windows: [Window] = []
        windows.reserveCapacity(raw.count)
        for entry in raw {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDictionary) else {
                throw Failure.malformedWindow
            }
            let pid = ownerPID.int32Value
            let identity = Self.ownerIdentity(pid: pid)
            windows.append(Window(
                id: number.uint32Value,
                owner: Owner(
                    pid: pid,
                    bundle_id: identity.bundleID,
                    signing_id: identity.signingID,
                    apple_signed: identity.appleSigned
                ),
                layer: layer.int32Value,
                bounds: Bounds(
                    x: Double(rect.origin.x), y: Double(rect.origin.y),
                    w: Double(rect.size.width), h: Double(rect.size.height)
                ),
                on_screen: true
            ))
        }
        let displays = try NSScreen.screens.map { screen -> Display in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw Failure.malformedWindow
            }
            let displayID = number.uint32Value
            let quartz = CGDisplayBounds(displayID)
            return Display(
                id: displayID,
                appkit_frame: Self.bounds(screen.frame),
                quartz_bounds: Self.bounds(quartz)
            )
        }
        return Snapshot(
            windows: windows,
            counters: counters,
            anchor_appkit: Self.bounds(anchor),
            displays: displays
        )
    }

    private static func bounds(_ rect: CGRect) -> Bounds {
        Bounds(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            w: Double(rect.size.width), h: Double(rect.size.height)
        )
    }

    /// Capture only a new app-owned window from the complete inventory. The reducer still
    /// rejects ambiguity; no title, favourable geometry, or producer prefilter chooses a winner.
    func captureAppCandidate(before: Snapshot, opened: Snapshot) throws -> Snapshot {
        let oldIDs = Set(before.windows.map { $0.id })
        let fresh = opened.windows.filter { !oldIDs.contains($0.id) }
        guard fresh.count == 1, let window = fresh.first, window.owner.pid == getpid() else { return opened }
        guard window.layer == 20, CGPreflightScreenCaptureAccess(),
              let rawRoot = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT"] else { throw Failure.invalidOutput }
        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
        let name = "candidate-\(rows.count)-\(window.id).png"
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.invalidOutput }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.id), url.path]
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); throw Failure.invalidOutput }
        guard process.terminationStatus == 0 else { throw Failure.invalidOutput }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.invalidOutput }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Classify the Hanja column; Korean-first OCR misreads these glyphs as Hangul.
        request.recognitionLanguages = ["zh-Hant"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let rowsWithHanja = (request.results ?? []).filter { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return false }
            return candidate.string.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        }
        // Three separately recognised rows reject blank windows and ordinary one-line tooltips.
        let expected = Set("韓漢寒汗翰恨閑限罕邯".unicodeScalars)
        let recognised = rowsWithHanja.compactMap { $0.topCandidates(1).first?.string }.joined()
        let distinctRows = Set(rowsWithHanja.map { Int($0.boundingBox.midY * 100) })
        guard rowsWithHanja.count >= 3, distinctRows.count >= 3,
              recognised.unicodeScalars.contains(where: { expected.contains($0) }) else { throw Failure.invalidOutput }
        var result = opened
        result.app_captures = [AppCapture(window_id: window.id, capture_basename: name,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            width: UInt32(image.width), height: UInt32(image.height), hanja_rows: UInt32(rowsWithHanja.count))]
        return result
    }

    func append(before: Snapshot, opened: Snapshot, closed: Snapshot) throws {
        guard rows.count < Self.requiredObservationCount else { throw Failure.inventoryTooLarge }
        rows.append(Row(before: before, opened: opened, closed: closed))
    }

    func publish(sourceID: String, outputURL: URL) throws {
        guard rows.count == Self.requiredObservationCount,
              outputURL.isFileURL,
              !FileManager.default.fileExists(atPath: outputURL.path) else { throw Failure.invalidOutput }
        let transcript = Transcript(
            schema: "maru.session-host-cr6d-ime-candidate-transcript.v1",
            app_pid: getpid(), source_id: sourceID, rows: rows
        )
        let data = try JSONEncoder().encode(transcript)
        guard data.count <= Self.maximumTranscriptBytes else { throw Failure.transcriptTooLarge }
        let status: UInt32 = data.withUnsafeBytes { bytes in
            outputURL.path.utf8CString.withUnsafeBufferPointer { path in
                maru_macos_session_host_ime_candidate_observation_publish(
                    bytes.bindMemory(to: UInt8.self).baseAddress, data.count,
                    path.baseAddress, path.count - 1
                )
            }
        }
        guard status == 0 else {
            // Keep rejected evidence separate from the accepted artifact. Without the original
            // bounded snapshots, an ownership exclusion and a missing window look identical.
            // Exclusive creation also preserves the first failure instead of replacing it.
            let rejectedURL = outputURL.deletingPathExtension()
                .appendingPathExtension("rejected-transcript.json")
            do { try data.write(to: rejectedURL, options: .withoutOverwriting) }
            catch {
                FileHandle.standardError.write(Data("session_host_ime_candidate_rejected_transcript_write_failed=true\n".utf8))
            }
            throw Failure.rejected(status)
        }
    }

    private static func ownerIdentity(pid: Int32) -> (bundleID: String, signingID: String, appleSigned: Bool) {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return (bundleID, "", false) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return (bundleID, "", false) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let signingID = dictionary[kSecCodeInfoIdentifier as String] as? String else {
            return (bundleID, "", false)
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return (bundleID, signingID, false) }
        return (bundleID, signingID, SecCodeCheckValidity(code, [], requirement) == errSecSuccess)
    }
}
