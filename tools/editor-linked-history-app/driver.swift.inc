// 앱의 keyDown·mouseDown 경계를 통과한다. 물리 HID/OS IME 검증으로 해석하지 않는다.
@_silgen_name("maru_editor_linked_history_probe") private func editorLinkedHistoryProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_linked_history_coordinate") private func editorLinkedHistoryCoordinate(_ current: Bool, _ axis: UInt32) -> Double
@MainActor private enum EditorLinkedHistoryRun {
    static var stage: UInt32 = 0
    static var next = 0.0
}
extension MaruAppHostController {
    private func editorLinkedHistoryKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
        view.keyDown(with: event)
        return true
    }
    private func editorLinkedHistoryClick(_ current: Bool) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return false }
        let scale = archiveSmokeRenderScale(window)
        let x = editorLinkedHistoryCoordinate(current, 0) / scale
        let y = editorLinkedHistoryCoordinate(current, 1) / scale
        guard x >= 0, y >= 0 else { return false }
        let point = view.convert(NSPoint(x: x, y: view.bounds.height - y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        return true
    }
    private func editorLinkedHistoryCapture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EDITOR_LINKED_HISTORY_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard !FileManager.default.fileExists(atPath: path), maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunEditorLinkedHistory() {
        guard ProcessInfo.processInfo.environment["MARU_EDITOR_LINKED_HISTORY_CAPTURE"] == "1", EditorLinkedHistoryRun.stage < 99,
              let surface = primary, let window = surface.window, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorLinkedHistoryRun.next else { return }
        let stage = EditorLinkedHistoryRun.stage
        let ready = editorLinkedHistoryProbe(stage)
        if ready == 0 { return }
        func finish(_ success: Bool) {
            EditorLinkedHistoryRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_LINKED_HISTORY_FINISH passed=\(success) transport=AppKit-local\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard ready == 1 else { finish(false); return }
        let labels = ["edited", "undo-confirm", "cancelled", "undone", "redo-confirm", "redone", "current-confirm", "current-only"]
        guard editorLinkedHistoryCapture(labels[Int(stage)]) else { finish(false); return }
        let ok: Bool
        switch stage {
        case 0, 5: ok = editorLinkedHistoryKey("z", code: 6, modifiers: .command)
        case 2: ok = editorLinkedHistoryKey("z", code: 6, modifiers: .command) && editorLinkedHistoryClick(false)
        case 1: ok = editorLinkedHistoryKey("\u{1b}", code: 53)
        case 3: ok = editorLinkedHistoryKey("z", code: 6, modifiers: [.command, .shift])
        case 4: ok = editorLinkedHistoryKey("\r", code: 36)
        case 6: ok = editorLinkedHistoryClick(true)
        case 7: finish(true); return
        default: ok = editorLinkedHistoryClick(false)
        }
        guard ok else { finish(false); return }
        EditorLinkedHistoryRun.stage += 1
        EditorLinkedHistoryRun.next = now + 0.7
    }
}
