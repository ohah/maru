// 격리 앱에 실제 HID 키를 보낸다. 전역 입력기는 기존 복원 기록 계약으로 되돌린다.
import AppKit
import CoreGraphics
let pid = pid_t(CommandLine.arguments[1])!
let root = URL(fileURLWithPath: CommandLine.arguments[2])
func waitFor(_ name: String) throws {
    let end = Date().addingTimeInterval(12)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
        if Date() > end { throw NSError(domain: "IME", code: 1) }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
func post(_ code: CGKeyCode) throws {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int != 1,
          let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else { throw NSError(domain: "IME", code: 2) }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
}
do {
    try waitFor("physical-ready")
    guard CGPreflightPostEventAccess(), let app = NSRunningApplication(processIdentifier: pid) else { throw NSError(domain: "IME", code: 3) }
    app.activate(options: [.activateIgnoringOtherApps])
    Thread.sleep(forTimeInterval: 0.3)
    let record = root.appendingPathComponent("input-source-restore.json")
    let original = try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL: record)
    defer { print("source_restore=\(SessionHostInputSourcePolicy.restore(recordURL: record)) original=\(original)") }
    Thread.sleep(forTimeInterval: 0.3)
    for code: CGKeyCode in [5, 40, 1, 15, 46, 3] { try post(code) }
    try waitFor("ime-marked.ppm")
    try post(36)
    print("physical_keys=6 enter=1 transport=cghidEventTap")
} catch {
    print("physical_error=\(error)")
    exit(1)
}
