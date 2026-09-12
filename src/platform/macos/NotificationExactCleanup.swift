import Foundation

/// Removes one notification request from both Notification Center stores without enumerating or
/// exposing any unrelated request. The live adapter supplies the two UserNotifications syscalls;
/// release verification reuses this product leaf instead of owning a second cleanup policy.
struct NotificationExactCleanup {
    typealias Remove = (_ identifiers: [String]) -> Void

    private let removePending: Remove
    private let removeDelivered: Remove

    init(removePending: @escaping Remove, removeDelivered: @escaping Remove) {
        self.removePending = removePending
        self.removeDelivered = removeDelivered
    }

    @discardableResult
    func remove(requestIdentifier: String) -> Bool {
        guard !requestIdentifier.isEmpty,
              requestIdentifier.utf8.count <= 191,
              !requestIdentifier.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else { return false }
        let exact = [requestIdentifier]
        removePending(exact)
        removeDelivered(exact)
        return true
    }
}
