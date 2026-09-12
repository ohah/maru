import AppKit
import ApplicationServices
import CoreGraphics
import Darwin.Mach
import Foundation

// This helper is a separate, signable executable because the app under test must not manufacture
// its own "actual click" authority. It prints only facts about the requested nonce and never logs
// text from unrelated notifications encountered while walking the AX tree.
private enum Exit: Int32 {
    case invalidInput = 64
    case notProvisionedAccessibility = 70
    case notProvisionedAqua = 71
    case targetUnavailable = 72
    case ambiguousTarget = 73
    case pressFailed = 74
}

private let helperSchema = "maru.session-host-notification-center-helper.v1"
private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let maximumFutureBudgetNs: UInt64 = 60_000_000_000
private let maximumNodes = 1_024
private let maximumDepth = 12
private let maximumChildren = 128

private func continuousNanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 0 }
    let ticks = mach_continuous_time()
    let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(info.numer))
    guard !overflow else { return 0 }
    return product / UInt64(info.denom)
}

func canonicalNotificationNonce(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count > 36 else { return false }
    let suffix = String(decoding: bytes[36...], as: UTF8.self)
    guard suffix == "-gui-zero" || suffix == "-gui-live-then-quit" else { return false }
    let uuid = Array(bytes[..<36])
    guard uuid[8] == 45, uuid[13] == 45, uuid[18] == 45, uuid[23] == 45,
          uuid[14] == 52, [56, 57, 97, 98].contains(uuid[19]) else { return false }
    for (index, byte) in uuid.enumerated() {
        if [8, 13, 18, 23].contains(index) { continue }
        guard (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) else { return false }
    }
    return true
}

private func aquaReady() -> Bool {
    guard let raw = CGSessionCopyCurrentDictionary() as? [String: Any],
          let onConsole = raw[kCGSessionOnConsoleKey as String] as? Bool,
          let loginDone = raw[kCGSessionLoginDoneKey as String] as? Bool
    else { return false }
    return onConsole && loginDone
}

private func accessibilityReady() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

private func exactTextMatch(_ element: AXUIElement, nonce: String) -> Bool {
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let text = attribute(element, name as CFString) as? String, text == nonce { return true }
    }
    return false
}

private func supportsPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let actions = names as? [String] else { return false }
    return actions.contains(kAXPressAction as String)
}

private struct Node {
    let element: AXUIElement
    let ancestors: [AXUIElement]
    let depth: Int
}

private func matchingPressTargets(root: AXUIElement, nonce: String) -> [AXUIElement] {
    var queue = [Node(element: root, ancestors: [], depth: 0)]
    var cursor = 0
    var visited = 0
    var matches: [AXUIElement] = []
    while cursor < queue.count && visited < maximumNodes {
        let node = queue[cursor]
        cursor += 1
        visited += 1
        if exactTextMatch(node.element, nonce: nonce) {
            if supportsPress(node.element) {
                matches.append(node.element)
            } else if let target = node.ancestors.reversed().first(where: supportsPress) {
                matches.append(target)
            }
        }
        guard node.depth < maximumDepth,
              let children = attribute(node.element, kAXChildrenAttribute as CFString) as? [AXUIElement]
        else { continue }
        let bounded = children.prefix(maximumChildren)
        let ancestors = node.ancestors + [node.element]
        for child in bounded { queue.append(Node(element: child, ancestors: ancestors, depth: node.depth + 1)) }
    }
    // One banner can expose the same actionable ancestor through title and body descendants.
    var unique: [AXUIElement] = []
    for candidate in matches where !unique.contains(where: { CFEqual($0, candidate) }) { unique.append(candidate) }
    return unique
}

func encodedResult(nonce: String, observedNs: UInt64, clickedNs: UInt64) -> String {
    // Nonce grammar excludes JSON metacharacters, so this fixed projection needs no general encoder.
    return "{\"schema\":\"\(helperSchema)\",\"result\":\"clicked\",\"visible_nonce\":\"\(nonce)\",\"observed_at_ns\":\(observedNs),\"clicked_at_ns\":\(clickedNs)}"
}

private func writeResult(nonce: String, observedNs: UInt64, clickedNs: UInt64) {
    print(encodedResult(nonce: nonce, observedNs: observedNs, clickedNs: clickedNs))
}

private func fail(_ value: Exit) -> Never {
    Darwin.exit(value.rawValue)
}

#if !MARU_HELPER_TEST
@main
private struct NotificationCenterHelper {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == "click", canonicalNotificationNonce(arguments[2]),
              let deadline = UInt64(arguments[3]) else { fail(.invalidInput) }
        let nonce = arguments[2]
        let start = continuousNanoseconds()
        guard start > 0, deadline > start, deadline - start <= maximumFutureBudgetNs else { fail(.invalidInput) }
        guard aquaReady() else { fail(.notProvisionedAqua) }
        guard accessibilityReady() else { fail(.notProvisionedAccessibility) }

        while continuousNanoseconds() < deadline {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID)
            if applications.count == 1 {
                let root = AXUIElementCreateApplication(applications[0].processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.5)
                let targets = matchingPressTargets(root: root, nonce: nonce)
                if targets.count > 1 { fail(.ambiguousTarget) }
                if let target = targets.first {
                    let observed = continuousNanoseconds()
                    guard observed > 0, observed < deadline,
                          AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
                    else { fail(.pressFailed) }
                    let clicked = continuousNanoseconds()
                    guard clicked > observed, clicked < deadline else { fail(.pressFailed) }
                    writeResult(nonce: nonce, observedNs: observed, clickedNs: clicked)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        fail(.targetUnavailable)
    }
}
#endif
