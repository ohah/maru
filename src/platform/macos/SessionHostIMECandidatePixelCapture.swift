import AppKit
import CryptoKit
import ScreenCaptureKit
import Security

/// CR6d-v2b1의 opt-in adapter. Candidate selection remains in Zig; this type can only capture
/// the exact window ID returned by that reducer and never falls back to a display screenshot.
enum SessionHostIMECandidatePixelCapture {
    struct Evidence: Codable {
        let window_id: UInt32
        let owner_pid: Int32
        let bundle_id: String
        let signing_id: String
        let apple_signed: Bool
        let layer: Int32
        let bounds: SessionHostIMECandidateObservation.Bounds
        let pixel_width: Int
        let pixel_height: Int
        let capture_sha256: String
        let capture_complete: Bool
    }

    enum Failure: Error {
        case windowMissing
        case identityDrift
        case geometryDrift
        case emptyCapture
    }

    @available(macOS 14.0, *)
    static func capture(
        request: SessionHostIMECandidateObservation.CaptureRequest
    ) async throws -> Evidence {
        let beforeContent = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let before = try exactWindow(in: beforeContent, request: request)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(before.frame.width.rounded(.up)))
        configuration.height = max(1, Int(before.frame.height.rounded(.up)))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: before)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        guard image.width > 0, image.height > 0,
              let provider = image.dataProvider, let bytes = provider.data,
              CFDataGetLength(bytes) > 0 else { throw Failure.emptyCapture }

        let afterContent = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        _ = try exactWindow(in: afterContent, request: request)
        let digest = SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
        guard digest.count == 64 else { throw Failure.emptyCapture }
        return Evidence(
            window_id: request.windowID,
            owner_pid: request.owner.pid,
            bundle_id: request.owner.bundle_id,
            signing_id: request.owner.signing_id,
            apple_signed: request.owner.apple_signed,
            layer: request.layer,
            bounds: request.bounds,
            pixel_width: image.width,
            pixel_height: image.height,
            capture_sha256: digest,
            capture_complete: true
        )
    }

    @available(macOS 14.0, *)
    private static func exactWindow(
        in content: SCShareableContent,
        request: SessionHostIMECandidateObservation.CaptureRequest
    ) throws -> SCWindow {
        guard let window = content.windows.first(where: { $0.windowID == request.windowID }),
              window.isOnScreen,
              let application = window.owningApplication,
              application.processID == request.owner.pid else { throw Failure.windowMissing }
        let identity = ownerIdentity(pid: application.processID)
        guard request.owner.apple_signed, identity.appleSigned,
              identity.bundleID == request.owner.bundle_id,
              identity.signingID == request.owner.signing_id else { throw Failure.identityDrift }
        guard window.windowLayer == Int(request.layer),
              Double(window.frame.origin.x) == request.bounds.x,
              Double(window.frame.origin.y) == request.bounds.y,
              Double(window.frame.width) == request.bounds.w,
              Double(window.frame.height) == request.bounds.h else { throw Failure.geometryDrift }
        return window
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
