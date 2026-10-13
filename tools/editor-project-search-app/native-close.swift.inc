// 닫기·확정·추가 편집은 제품 AppKit 입력으로 보내고, 쓰기 대기는 격리 writer에서만 주입한다.
@_silgen_name("maru_editor_native_close_probe") private func editorNativeCloseProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_native_close_action") private func editorNativeCloseAction(_ action: UInt32)
@MainActor private enum EditorNativeCloseRun {
    static var stage: UInt32 = 0
    static var next = 0.0
}
extension MaruAppHostController {
    private func maybeRunNativeCloseSave() {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorNativeCloseRun.next else { return }
        let stage = EditorNativeCloseRun.stage
        func finish(_ success: Bool) {
            EditorProjectSearchRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(success) transport=AppKit-local native-close=true\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        func key(_ text: String, code: UInt16, command: Bool = false) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
            view.keyDown(with: event)
            return true
        }
        let ready = editorNativeCloseProbe(stage)
        if ready == 0 { EditorNativeCloseRun.next = now + 0.02; return }
        guard ready == 1 else { finish(false); return }
        var nextDelay = 0.3
        switch stage {
        case 0: editorNativeCloseAction(0)
        case 1, 6, 11:
            view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard key("w", code: 13, command: true) else { finish(false); return }
        case 2, 7, 12:
            if stage == 2, !editorProjectSearchCapture("native-close-confirm") { finish(false); return }
            guard key("\r", code: 36) else { finish(false); return }
            nextDelay = 0.01
        case 3:
            guard editorProjectSearchCapture("native-close-saving") else { finish(false); return }
        case 4:
            guard editorProjectSearchCapture("native-close-saved") else { finish(false); return }
        case 5: editorNativeCloseAction(1)
        case 8:
            view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 9:
            guard editorProjectSearchCapture("native-close-edit-kept") else { finish(false); return }
        case 10:
            guard key("\u{1b}", code: 53) else { finish(false); return }
            editorNativeCloseAction(2)
        case 13: editorNativeCloseAction(10)
        case 14:
            guard editorProjectSearchCapture("native-close-conflict-kept") else { finish(false); return }
            finish(true)
            return
        default: finish(false); return
        }
        FileHandle.standardError.write(Data("NATIVE_CLOSE stage=\(stage) verified=true\n".utf8))
        EditorNativeCloseRun.stage += 1
        EditorNativeCloseRun.next = now + nextDelay
    }
}
