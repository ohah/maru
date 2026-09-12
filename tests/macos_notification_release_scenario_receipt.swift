import Foundation

@main
private struct NotificationReleaseScenarioReceiptTests {
    static let expected = NotificationReleaseScenarioExpectation(
        scenario: .guiZero,
        requestIdentifier: "maru-00000000000000000000000000000001-00000000000000000000000000000002-7",
        hostIdHigh: 0,
        hostIdLow: 1,
        runtimeIdHigh: 0,
        runtimeIdLow: 2,
        eventId: 7,
        deadlineNs: 100
    )

    static func main() {
        successIsExactAndCanonical()
        liveScenarioAndBoundAttachAreDistinct()
        wrongOrDuplicateCallbackFailsClosed()
        attachOrderingAndDeadlineFailClosed()
        invalidExpectationCannotEmitJSON()
    }

    private static func successIsExactAndCanonical() {
        let owner = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(owner.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(owner.observeAttach(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            kind: .recovered,
            atNs: 60
        ))
        precondition(owner.receipt() == "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"maru-00000000000000000000000000000001-00000000000000000000000000000002-7\",\"host_id\":\"00000000000000000000000000000001\",\"runtime_id\":\"00000000000000000000000000000002\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":60,\"attach_kind\":\"recovered\"}")
    }

    private static func liveScenarioAndBoundAttachAreDistinct() {
        let live = NotificationReleaseScenarioExpectation(
            scenario: .guiLiveThenQuit,
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            deadlineNs: 100
        )
        let owner = NotificationReleaseScenarioReceiptOwner(expectation: live)
        precondition(owner.observeCallback(
            requestIdentifier: live.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(owner.receipt() == nil)
        precondition(owner.observeAttach(
            requestIdentifier: live.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            kind: .bound,
            atNs: 60
        ))
        precondition(owner.receipt()?.contains("\"scenario\":\"gui-live-then-quit\"") == true)
        precondition(owner.receipt()?.contains("\"attach_kind\":\"bound\"") == true)
        precondition(!owner.observeAttach(
            requestIdentifier: live.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            kind: .bound,
            atNs: 70
        ))
        precondition(owner.failed && owner.receipt() == nil)
    }

    private static func wrongOrDuplicateCallbackFailsClosed() {
        let wrong = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(!wrong.observeCallback(
            requestIdentifier: expected.requestIdentifier + "-foreign",
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(!wrong.failed && wrong.receipt() == nil)
        precondition(!wrong.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 9,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(wrong.failed && wrong.receipt() == nil)

        let duplicate = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(duplicate.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(!duplicate.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 41
        ))
        precondition(duplicate.failed && duplicate.receipt() == nil)
    }

    private static func attachOrderingAndDeadlineFailClosed() {
        let early = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(!early.observeAttach(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            kind: .bound,
            atNs: 20
        ))
        precondition(early.failed)

        let wrongRoute = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(wrongRoute.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 40
        ))
        precondition(!wrongRoute.observeAttach(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 9,
            eventId: 7,
            kind: .recovered,
            atNs: 60
        ))
        precondition(wrongRoute.failed && wrongRoute.receipt() == nil)

        let late = NotificationReleaseScenarioReceiptOwner(expectation: expected)
        precondition(!late.observeCallback(
            requestIdentifier: expected.requestIdentifier,
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            atNs: 100
        ))
        precondition(late.failed)
    }

    private static func invalidExpectationCannotEmitJSON() {
        let injected = NotificationReleaseScenarioExpectation(
            scenario: .guiLiveThenQuit,
            requestIdentifier: "maru-\"foreign",
            hostIdHigh: 0, hostIdLow: 1,
            runtimeIdHigh: 0, runtimeIdLow: 2,
            eventId: 7,
            deadlineNs: 100
        )
        let owner = NotificationReleaseScenarioReceiptOwner(expectation: injected)
        precondition(owner.failed && owner.receipt() == nil)
    }

}
