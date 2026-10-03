import Foundation

// A banner can outlive its app process. These cases call the product parser with persisted
// payloads and prove that a reused window/surface pair never becomes cross-launch authority.
@main struct NotificationLocalRouteTests {
    static func main() {
        let current = "D18B9B6F-65E4-4E55-B148-C086367D6895"
        let old = "16C866E2-1283-4416-9749-428EC49A4C95"
        let valid: [AnyHashable: Any] = ["ae": current, "wt": NSNumber(value: 1), "sid": NSNumber(value: 2)]
        var count = 0
        func check(_ ok: Bool, _ name: String) {
            guard ok else { print("FAIL \(name)"); exit(1) }
            count += 1
        }
        check(NotificationLocalRoute.parse(valid, expectedEpoch: current) == NotificationLocalRoute(token: 1, surfaceId: 2), "current launch exact route")
        var changed = valid; changed["ae"] = old
        check(NotificationLocalRoute.parse(changed, expectedEpoch: current) == nil, "previous launch reused identifiers")
        changed.removeValue(forKey: "ae")
        check(NotificationLocalRoute.parse(changed, expectedEpoch: current) == nil, "legacy missing epoch")
        changed = valid; changed["ae"] = NSNumber(value: 1)
        check(NotificationLocalRoute.parse(changed, expectedEpoch: current) == nil, "malformed epoch")
        for key in ["wt", "sid"] {
            for bad: Any in [NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: 0), "1"] {
                changed = valid; changed[key] = bad
                check(NotificationLocalRoute.parse(changed, expectedEpoch: current) == nil, "invalid \(key) scalar \(bad)")
            }
            changed = valid; changed[key] = NSNumber(value: UInt64.max)
            let fullWidthRoute = NotificationLocalRoute(
                token: key == "wt" ? UInt64.max : 1,
                surfaceId: key == "sid" ? UInt64.max : 2
            )
            // Accepting a wide id is insufficient: narrowing it can silently select another surface.
            check(NotificationLocalRoute.parse(changed, expectedEpoch: current) == fullWidthRoute, "full-width exact \(key)")
        }
        let route = NotificationLocalRoute(token: 1, surfaceId: 42)
        var visits: [UInt64] = []
        func resolve(_ route: NotificationLocalRoute, _ owners: [UInt64], target: UInt64?) -> UInt64? {
            visits = []
            return route.activateOwner(among: owners.map { (token: $0, owner: $0) }) { owner, sid in
                visits.append(owner)
                return sid == 42 && owner == target
            }
        }
        check(resolve(route, [1, 2], target: 1) == 1 && visits == [1], "current hint owner")
        check(resolve(route, [1, 2], target: 2) == 2 && visits == [1, 2], "surface moved to another window")
        check(resolve(route, [2], target: 2) == 2 && visits == [2], "source window closed after move")
        check(resolve(route, [1, 2], target: nil) == nil && visits == [1, 2], "closed surface has no owner")
        check(resolve(NotificationLocalRoute(token: 2, surfaceId: 42), [1, 2], target: 2) == 2 && visits == [2], "hint before window ordering")
        check(resolve(route, [1, 2, 3], target: 3) == 3 && visits == [1, 2, 3], "quick panel destination")
        guard count == 22 else { print("FAIL exact case count"); exit(1) }
        print("All \(count) local notification route checks passed.")
    }
}
