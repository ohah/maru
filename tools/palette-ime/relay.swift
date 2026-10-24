// External HID authority. The private app requests bounded fixture keys but cannot
// post events itself; every event rechecks foreground, source and fresh view state.
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedPID = pid_t(CommandLine.arguments[2])!
func require(_ value: Bool, _ reason: String) throws {
    if !value { throw NSError(domain: reason, code: 1) }
}
func row(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as! [String: Any]
}
var last = 0
let deadline = ProcessInfo.processInfo.systemUptime + 110
do {
    try require(CGPreflightPostEventAccess(), "relay_event_permission")
    while ProcessInfo.processInfo.systemUptime < deadline {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) { exit(0) }
        guard let request = try? row("hid-request.json"), let id = request["id"] as? Int, id > last else {
            Thread.sleep(forTimeInterval: 0.02); continue
        }
        let state = try row("keyboard-state.json")
        let now = ProcessInfo.processInfo.systemUptime
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID, "foreground_changed")
        try require((request["pid"] as? Int ?? -1) == Int(expectedPID) && (state["pid"] as? Int ?? -1) == Int(expectedPID) && state["first_responder"] as? Bool == true, "view_owner")
        try require(now - (state["time"] as? Double ?? 0) < 1 && now - (request["time"] as? Double ?? 0) < 1, "stale_request")
        try require(state["generation"] as? String == request["generation"] as? String, "generation_changed")
        let code = request["keycode"] as! UInt16
        let flags = request["flags"] as! UInt64
        try require([UInt16(5), 40, 1, 36, 53, 44].contains(code) && (flags == 0 || (code == 36 && flags == CGEventFlags.maskAlternate.rawValue)), "unbounded_request")
        if request["korean"] as? Bool == true {
            try require(state["view_source"] as? String == SessionHostInputSourcePolicy.korean2SetSourceID &&
                SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID, "source_changed")
        } else { try require(code == 44 && flags == 0, "non_korean_request") }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { throw NSError(domain: "event", code: 1) }
            // Remove producer-side translated text: the target OS must interpret
            // the virtual keycode. An explicit ASCII payload bypasses Korean IME.
            if [UInt16(5), 40, 1].contains(code) {
                var empty: UniChar = 0
                withUnsafePointer(to: &empty) { event.keyboardSetUnicodeString(stringLength: 0, unicodeString: $0) }
            }
            event.flags = CGEventFlags(rawValue: flags); event.post(tap: .cghidEventTap)
        }
        // A PNG/OCR capture can exhaust the app timer's original delay. Do not
        // acknowledge merely posting: allow the target's event queue to run first.
        Thread.sleep(forTimeInterval: 0.4)
        last = id
        try JSONSerialization.data(withJSONObject: ["id": id, "passed": true]).write(to: root.appendingPathComponent("hid-ack.json"), options: .atomic)
        print("delivered id=\(id) code=\(code) flags=\(flags)")
    }
    throw NSError(domain: "relay_timeout", code: 1)
} catch {
    try? JSONSerialization.data(withJSONObject: ["id": last + 1, "passed": false, "failure": String(describing: error)]).write(to: root.appendingPathComponent("hid-ack.json"), options: .atomic)
    fputs("relay failed: \(error)\n", stderr); exit(1)
}
