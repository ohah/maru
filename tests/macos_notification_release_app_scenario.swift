import Darwin
import Foundation

@main
private struct NotificationReleaseAppScenarioTests {
    private static let nonce = "123e4567-e89b-42d3-a456-426614174000"
    private static let request = "maru-00000000000000000000000000000001-00000000000000000000000000000002-7"

    static func main() throws {
        try validLaunchIsClosedAndParserOwned()
        absentModeIsOrdinaryLaunchButPartialModeFails()
        isolationAndDescriptorInputsFailClosed()
        try runnerRootMustBeOwnedDirectoryWithExactMode()
        try receiptSinkUsesOneInheritedPipeExactlyOnce()
        exactNotificationCleanupTouchesOnlyOneIdentifier()
    }

    private static func exactNotificationCleanupTouchesOnlyOneIdentifier() {
        var pending: [[String]] = []
        var delivered: [[String]] = []
        let cleanup = NotificationExactCleanup(
            removePending: { pending.append($0) },
            removeDelivered: { delivered.append($0) }
        )
        precondition(cleanup.remove(requestIdentifier: request))
        precondition(pending == [[request]])
        precondition(delivered == [[request]])

        for invalid in ["", "bad\nrequest", String(repeating: "x", count: 192)] {
            precondition(!cleanup.remove(requestIdentifier: invalid))
        }
        precondition(pending == [[request]])
        precondition(delivered == [[request]])
    }

    private static func validEnvironment() -> [String: String] {
        let root = "/private/tmp/mn-\(nonce.replacingOccurrences(of: "-", with: ""))"
        return [
            "MARU_SESSION_HOST_NOTIFICATION_APP_SCENARIO": "maru-release-v1",
            "MARU_SESSION_HOST_NOTIFICATION_SCENARIO": "gui-zero",
            "MARU_SESSION_HOST_NOTIFICATION_REQUEST": request,
            "MARU_SESSION_HOST_NOTIFICATION_HOST_ID": "00000000000000000000000000000001",
            "MARU_SESSION_HOST_NOTIFICATION_RUNTIME_ID": "00000000000000000000000000000002",
            "MARU_SESSION_HOST_NOTIFICATION_EVENT_ID": "7",
            "MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS": "1000",
            "MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD": "9",
            "MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE": nonce,
            "MARU_SESSION_HOST_NOTIFICATION_RUNNER_ROOT": root,
            "MARU_SESSION_HOST_ROOT": root + "/s",
            "HOME": root + "/h",
            "CFFIXED_USER_HOME": root + "/h",
        ]
    }

    private static func validLaunchIsClosedAndParserOwned() throws {
        var parserCalls = 0
        let result = NotificationReleaseAppScenarioConfiguration.load(environment: validEnvironment()) {
            requestIdentifier, host, runtime, event in
            parserCalls += 1
            precondition(requestIdentifier == request)
            precondition(host == "00000000000000000000000000000001")
            precondition(runtime == "00000000000000000000000000000002")
            precondition(event == "7")
            return (0, 1, 0, 2, 7)
        }
        guard case .armed(let config) = result else { preconditionFailure("valid mode rejected") }
        precondition(parserCalls == 1)
        precondition(config.expectation.scenario == .guiZero)
        precondition(config.receiptFileDescriptor == 9)
        precondition(config.runnerNonce == nonce)
        let longestSocket = config.runnerRoot + "/s/sh/00000000000000000000000000000000.sock"
        precondition(longestSocket.utf8.count + 1 <= 104)
    }

    private static func absentModeIsOrdinaryLaunchButPartialModeFails() {
        let absent = NotificationReleaseAppScenarioConfiguration.load(environment: [:]) { _, _, _, _ in nil }
        guard case .ordinary = absent else { preconditionFailure("ordinary launch armed") }

        var partial = validEnvironment()
        partial.removeValue(forKey: "MARU_SESSION_HOST_NOTIFICATION_REQUEST")
        guard case .invalid = NotificationReleaseAppScenarioConfiguration.load(environment: partial, routeParser: { _, _, _, _ in nil })
        else { preconditionFailure("partial launch did not fail") }
    }

    private static func isolationAndDescriptorInputsFailClosed() {
        for mutation in [
            ("MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD", "1"),
            ("MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD", "+9"),
            ("MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE", "not-a-uuid"),
            ("MARU_SESSION_HOST_ROOT", "/Users/example/Library/Application Support/maru/session-host"),
            ("HOME", "/Users/example"),
            ("MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS", "0"),
            ("MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS", "01000"),
        ] {
            var environment = validEnvironment()
            environment[mutation.0] = mutation.1
            guard case .invalid = NotificationReleaseAppScenarioConfiguration.load(environment: environment, routeParser: { _, _, _, _ in (0, 1, 0, 2, 7) })
            else { preconditionFailure("unsafe environment accepted: \(mutation.0)") }
        }
    }

    private static func runnerRootMustBeOwnedDirectoryWithExactMode() throws {
        let dynamicNonce = UUID().uuidString.lowercased()
        let root = "/private/tmp/mn-\(dynamicNonce.replacingOccurrences(of: "-", with: ""))"
        precondition(Darwin.mkdir(root, 0o700) == 0)
        defer { precondition(Darwin.rmdir(root) == 0) }
        precondition(notificationReleaseValidateRunnerRoot(root))
        precondition(Darwin.chmod(root, 0o755) == 0)
        precondition(!notificationReleaseValidateRunnerRoot(root))
        precondition(!notificationReleaseValidateRunnerRoot("/private/tmp"))
    }

    private static func receiptSinkUsesOneInheritedPipeExactlyOnce() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        precondition(Darwin.pipe(&descriptors) == 0)
        defer { _ = Darwin.close(descriptors[0]) }
        let sink = try NotificationReleaseReceiptSink(fileDescriptor: descriptors[1])
        try sink.publish("{\"schema\":\"receipt\"}")
        do {
            try sink.publish("duplicate")
            preconditionFailure("duplicate publication succeeded")
        } catch NotificationReleaseAppScenarioError.alreadyPublished {}

        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptors[0], &bytes, bytes.count)
        precondition(count == 20)
        precondition(String(decoding: bytes[0..<Int(count)], as: UTF8.self) == "{\"schema\":\"receipt\"}")

        do {
            _ = try NotificationReleaseReceiptSink(fileDescriptor: 1)
            preconditionFailure("stdout accepted")
        } catch NotificationReleaseAppScenarioError.invalidFileDescriptor {}
    }
}
