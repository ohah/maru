import Foundation

@main
private struct NotificationCenterHelperPolicyTests {
    static func main() {
        let uuid = "123e4567-e89b-42d3-a456-426614174000"
        precondition(canonicalNotificationNonce(uuid + "-gui-zero"))
        precondition(canonicalNotificationNonce(uuid + "-gui-live-then-quit"))
        precondition(!canonicalNotificationNonce(uuid + "-gui-live"))
        precondition(!canonicalNotificationNonce("123e4567-e89b-32d3-a456-426614174000-gui-zero"))
        precondition(!canonicalNotificationNonce("123e4567-e89b-42d3-c456-426614174000-gui-zero"))
        precondition(!canonicalNotificationNonce("123E4567-e89b-42d3-a456-426614174000-gui-zero"))
        precondition(!canonicalNotificationNonce(uuid + "-gui-zero-extra"))
        precondition(encodedResult(nonce: uuid + "-gui-zero", observedNs: 41, clickedNs: 42) ==
            "{\"schema\":\"maru.session-host-notification-center-helper.v1\",\"result\":\"clicked\",\"visible_nonce\":\"123e4567-e89b-42d3-a456-426614174000-gui-zero\",\"observed_at_ns\":41,\"clicked_at_ns\":42}")
    }
}
