import Foundation

enum NotificationReleaseScenario: String {
    case guiZero = "gui-zero"
    case guiLiveThenQuit = "gui-live-then-quit"
}

enum NotificationReleaseAttachKind: String {
    case bound
    case recovered
}

struct NotificationReleaseScenarioExpectation {
    let scenario: NotificationReleaseScenario
    let requestIdentifier: String
    let hostIdHigh: UInt64
    let hostIdLow: UInt64
    let runtimeIdHigh: UInt64
    let runtimeIdLow: UInt64
    let eventId: UInt64
    let deadlineNs: UInt64
}

/// Owns the two facts that only the product app can observe: the real notification delegate
/// callback and the attach path that callback actually completed. The UI helper cannot create
/// either fact, and this owner never invokes a callback or an attach itself.
final class NotificationReleaseScenarioReceiptOwner {
    private static let schema = "maru.session-host-notification-app-receipt.v1"

    private let expectation: NotificationReleaseScenarioExpectation
    private var callbackAtNs: UInt64?
    private var attachAtNs: UInt64?
    private var attachKind: NotificationReleaseAttachKind?
    private(set) var failed = false

    init(expectation: NotificationReleaseScenarioExpectation) {
        self.expectation = expectation
        if expectation.eventId == 0 || expectation.deadlineNs == 0 || !Self.safeRequestScalar(expectation.requestIdentifier) ||
            (expectation.hostIdHigh == 0 && expectation.hostIdLow == 0) ||
            (expectation.runtimeIdHigh == 0 && expectation.runtimeIdLow == 0) {
            failed = true
        }
    }

    @discardableResult
    func observeCallback(
        requestIdentifier: String,
        hostIdHigh: UInt64,
        hostIdLow: UInt64,
        runtimeIdHigh: UInt64,
        runtimeIdLow: UInt64,
        eventId: UInt64,
        atNs: UInt64
    ) -> Bool {
        // The app delegate sees every Maru notification. A foreign request is unrelated, while an
        // exact request identifier carrying a different parsed route is evidence corruption.
        guard requestIdentifier == expectation.requestIdentifier else { return false }
        guard !failed, callbackAtNs == nil, attachAtNs == nil,
              atNs > 0, atNs < expectation.deadlineNs,
              hostIdHigh == expectation.hostIdHigh,
              hostIdLow == expectation.hostIdLow,
              runtimeIdHigh == expectation.runtimeIdHigh,
              runtimeIdLow == expectation.runtimeIdLow,
              eventId == expectation.eventId else {
            failed = true
            return false
        }
        callbackAtNs = atNs
        return true
    }

    @discardableResult
    func observeAttach(_ kind: NotificationReleaseAttachKind, atNs: UInt64) -> Bool {
        guard !failed, attachAtNs == nil, attachKind == nil,
              let callbackAtNs, atNs > callbackAtNs, atNs < expectation.deadlineNs else {
            failed = true
            return false
        }
        attachAtNs = atNs
        attachKind = kind
        return true
    }

    func receipt() -> String? {
        guard !failed, let callbackAtNs, let attachAtNs, let attachKind else { return nil }
        return "{\"schema\":\"\(Self.schema)\",\"scenario\":\"\(expectation.scenario.rawValue)\",\"request_identifier\":\"\(expectation.requestIdentifier)\",\"host_id\":\"\(Self.hex128(high: expectation.hostIdHigh, low: expectation.hostIdLow))\",\"runtime_id\":\"\(Self.hex128(high: expectation.runtimeIdHigh, low: expectation.runtimeIdLow))\",\"event_id\":\(expectation.eventId),\"callback_at_ns\":\(callbackAtNs),\"attach_at_ns\":\(attachAtNs),\"attach_kind\":\"\(attachKind.rawValue)\"}"
    }

    private static func hex128(high: UInt64, low: UInt64) -> String {
        String(format: "%016llx%016llx", high, low)
    }

    private static func safeRequestScalar(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || byte == 45
        }
    }
}
