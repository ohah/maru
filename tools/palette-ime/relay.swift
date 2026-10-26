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
let projectSearch = Int(ProcessInfo.processInfo.environment["MARU_PROJECT_FIELD"] ?? "").map { (0...3).contains($0) } ?? false
let deadline = ProcessInfo.processInfo.systemUptime + (projectSearch ? 190 : 110)
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
        if request["kind"] as? String == "pointer" {
            // Compare to WindowServer's actual app window, not just producer bounds.
            guard let number = state["window_number"] as? Int,
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let own = windows.first(where: { ($0[kCGWindowNumber as String] as? Int) == number && ($0[kCGWindowOwnerPID as String] as? Int) == Int(expectedPID) }),
                  let rawBounds = own[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { throw NSError(domain:"pointer_window",code:1) }
            let path = try IMEPointerPolicy.events(request:request,state:state,window:bounds,pid:expectedPID,now:now)
            var pressed: CGPoint?
            defer {
                // On interrupted drags release only the owned app's capture;
                // never deliver cleanup to a different foreground application.
                if let point = pressed {
                    CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left)?.postToPid(expectedPID)
                }
            }
            for item in path {
                try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID, "pointer_foreground_changed")
                if request["action"] as? String == "drag" {
                    let fresh = try row("keyboard-state.json")
                    try require(fresh["generation"] as? String == request["generation"] as? String && fresh["window_key"] as? Bool == true, "pointer_generation_changed")
                }
                guard let event = CGEvent(mouseEventSource:nil,mouseType:item.type,mouseCursorPosition:item.point,mouseButton:.left) else { throw NSError(domain:"pointer_event",code:1) }
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState,value:1)
                event.post(tap:.cghidEventTap)
                pressed = item.type == .leftMouseUp ? nil : item.point
                Thread.sleep(forTimeInterval:0.02)
            }
            Thread.sleep(forTimeInterval:0.4)
            last = id
            try JSONSerialization.data(withJSONObject:["id":id,"passed":true,"kind":"pointer","action":request["action"]!,"target":request["target"]!,"generation":request["generation"]!,"events":path.count,"pid":Int(expectedPID)]).write(to:root.appendingPathComponent("hid-ack.json"),options:.atomic)
            print("delivered pointer id=\(id) action=\(request["action"]!) events=\(path.count)")
            continue
        }
        try require((request["pid"] as? Int ?? -1) == Int(expectedPID) && (state["pid"] as? Int ?? -1) == Int(expectedPID) && state["first_responder"] as? Bool == true, "view_owner")
        try require(now - (state["time"] as? Double ?? 0) < 1 && now - (request["time"] as? Double ?? 0) < 1, "stale_request")
        try require(state["generation"] as? String == request["generation"] as? String, "generation_changed")
        let code = request["keycode"] as! UInt16
        let flags = request["flags"] as! UInt64
        let addressSelection = state["address_pointer_mode"] as? Bool == true && code == 124 && flags == CGEventFlags.maskShift.rawValue &&
            (UInt64(state["generation"] as? String ?? "") ?? 0) > (1 << 62) && (UInt64(state["generation"] as? String ?? "") ?? 0) < (1 << 63)
        let findTab = state["find_mode"] as? Bool == true && code == 48 && flags == 0 &&
            (UInt64(state["generation"] as? String ?? "") ?? 0) > (1 << 59) && (UInt64(state["generation"] as? String ?? "") ?? 0) < (1 << 60)
        let projectTab = state["project_mode"] as? Bool == true && code == 48 && flags == 0 &&
            (UInt64(state["generation"] as? String ?? "") ?? 0) > (1 << 58) && (UInt64(state["generation"] as? String ?? "") ?? 0) < (1 << 59)
        try require(([UInt16(5), 40, 1, 36, 53, 44].contains(code) && (flags == 0 || (code == 36 && flags == CGEventFlags.maskAlternate.rawValue))) || addressSelection || findTab || projectTab, "unbounded_request")
        if request["korean"] as? Bool == true {
            try require(state["view_source"] as? String == SessionHostInputSourcePolicy.korean2SetSourceID &&
                SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID, "source_changed")
        } else { try require((code == 44 && flags == 0) || addressSelection, "non_korean_request") }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { throw NSError(domain: "event", code: 1) }
            // Remove producer-side translated text: the target OS must interpret
            // the virtual keycode. An explicit ASCII payload bypasses Korean IME.
            if [UInt16(5), 40, 1].contains(code) {
                var empty: UniChar = 0
                withUnsafePointer(to: &empty) { event.keyboardSetUnicodeString(stringLength: 0, unicodeString: $0) }
            }
            // Tag only the admitted private Project Search Tab, so its receiver can
            // distinguish OS event handling from this relay merely posting it.
            if projectTab { event.setIntegerValueField(.eventSourceUserData, value: Int64(id)) }
            event.flags = CGEventFlags(rawValue: flags); event.post(tap: .cghidEventTap)
        }
        // A PNG/OCR capture can exhaust the app timer's original delay. Do not
        // acknowledge merely posting: allow the target's event queue to run first.
        Thread.sleep(forTimeInterval: 0.4)
        last = id
        try JSONSerialization.data(withJSONObject: ["id": id, "passed": true, "kind": addressSelection ? "selection_key" : "key", "generation": request["generation"]!, "events": 2, "pid": Int(expectedPID), "keycode": code, "flags": flags]).write(to: root.appendingPathComponent("hid-ack.json"), options: .atomic)
        print("\(projectTab ? "posted" : "delivered") id=\(id) code=\(code) flags=\(flags)")
    }
    throw NSError(domain: "relay_timeout", code: 1)
} catch {
    try? JSONSerialization.data(withJSONObject: ["id": last + 1, "passed": false, "failure": String(describing: error)]).write(to: root.appendingPathComponent("hid-ack.json"), options: .atomic)
    fputs("relay failed: \(error)\n", stderr); exit(1)
}
