import AppKit
import CoreGraphics
import Foundation
import Security

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

    struct Snapshot: Codable {
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
        guard status == 0 else { throw Failure.rejected(status) }
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
