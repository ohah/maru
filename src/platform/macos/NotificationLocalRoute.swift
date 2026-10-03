import Foundation
import CoreFoundation

/// Local notification identifiers only name surfaces within one app launch. A persisted
/// Notification Center row must never give authority to a later launch that reuses those numbers.
struct NotificationLocalRoute: Equatable {
    let token: UInt64
    let surfaceId: UInt64

    static func parse(_ userInfo: [AnyHashable: Any], expectedEpoch: String) -> Self? {
        guard let epoch = userInfo["ae"] as? String, epoch == expectedEpoch,
              !expectedEpoch.isEmpty,
              let token = positiveInteger(userInfo["wt"]),
              let surfaceId = positiveInteger(userInfo["sid"]) else { return nil }
        return Self(token: token, surfaceId: surfaceId)
    }
    // The window token is a location hint; a live surface keeps its id when moved.
    func activateOwner<Owner>(among owners: [(token: UInt64, owner: Owner)],
                              activate: (Owner, UInt64) -> Bool) -> Owner? {
        if let hint = owners.first(where: { $0.token == token }), activate(hint.owner, surfaceId) {
            return hint.owner
        }
        for candidate in owners where candidate.token != token {
            if activate(candidate.owner, surfaceId) { return candidate.owner }
        }
        return nil
    }

    private static func positiveInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              let integer = UInt64(number.stringValue), integer != 0 else { return nil }
        return integer
    }
}
