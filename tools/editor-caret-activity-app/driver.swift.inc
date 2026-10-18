// 실제 앱의 keyDown → 제품 라우팅과 Metal readback을 검사한다. 물리 HID 입력은 아니다.
@_silgen_name("maru_editor_caret_activity_probe") private func editorCaretActivityProbe(_ expected: UInt32) -> Int32
@_silgen_name("maru_editor_caret_activity_prepare") private func editorCaretActivityPrepare() -> Bool
@MainActor private enum EditorCaretActivityRun {
    static var stage: UInt32 = 0
    static var busy = false
    static var deadline = 0.0
}
extension MaruAppHostController {
    private func editorCaretActivityCapture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EDITOR_CARET_ACTIVITY_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard !FileManager.default.fileExists(atPath: path), maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunEditorCaretActivity() {
        guard ProcessInfo.processInfo.environment["MARU_EDITOR_CARET_ACTIVITY_CAPTURE"] == "1",
              EditorCaretActivityRun.stage < 99, !EditorCaretActivityRun.busy,
              let surface = primary, let window = surface.window, let view = surface.view, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if EditorCaretActivityRun.deadline == 0 { EditorCaretActivityRun.deadline = now + 20 }
        func finish(_ passed: Bool) {
            EditorCaretActivityRun.stage = 99
            NSLog("EDITOR_CARET_ACTIVITY_FINISH passed=%@", passed ? "true" : "false")
            self.bypassQuitConfirm = true
            NSApp.terminate(nil)
        }
        if now > EditorCaretActivityRun.deadline { finish(false); return }
        EditorCaretActivityRun.busy = true
        defer { EditorCaretActivityRun.busy = false }
        if EditorCaretActivityRun.stage == 0 {
            guard editorCaretActivityPrepare() else { return }
            EditorCaretActivityRun.stage = 1
            return
        }
        // 타이머가 스스로 숨기는 순간을 기다린다. 렌더가 주기를 매번 초기화하면 timeout으로 실패한다.
        guard editorCaretActivityProbe(0) == 1 else { return }
        let stage = EditorCaretActivityRun.stage
        if stage == 4 {
            guard editorCaretActivityCapture("idle-hidden") else { finish(false); return }
            finish(true)
            return
        }
        guard editorCaretActivityCapture("hidden-\(stage)") else { finish(false); return }
        let flags: NSEvent.ModifierFlags = stage == 2 ? [.option, .command] : stage == 3 ? [.shift] : []
        let keyCode: UInt16 = stage == 2 ? 125 : 124
        let chars = stage == 2 ? "\u{F701}" : "\u{F703}"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: now, windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { finish(false); return }
        view.keyDown(with: event)
        guard editorCaretActivityProbe(stage == 1 ? 1 : 2) == 1,
              editorCaretActivityCapture(stage == 1 ? "moved-visible" : stage == 2 ? "multi-visible" : "selection-visible") else { finish(false); return }
        EditorCaretActivityRun.stage += 1
    }
}
