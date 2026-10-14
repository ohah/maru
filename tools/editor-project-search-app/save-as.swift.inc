// 실제 NSEvent로 명령을 보내고 제품 NSSavePanel을 그대로 조작한다.
@_silgen_name("maru_editor_save_as_probe") private func editorSaveAsProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_save_as_setup") private func editorSaveAsSetup()
@MainActor private enum EditorSaveAsRun { static var stage: UInt32 = 0; static var next = 0.0 }
extension MaruAppHostController {
    private func maybeRunSaveAsCommand() {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorSaveAsRun.next else { return }
        let stage = EditorSaveAsRun.stage
        func finish(_ success: Bool) {
            EditorProjectSearchRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(success) transport=AppKit-local save-as=true\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        let ready = editorSaveAsProbe(stage)
        if ready == 0 { EditorSaveAsRun.next = now + 0.02; return }
        guard ready == 1 else { finish(false); return }
        switch stage {
        case 0: editorSaveAsSetup()
        case 1:
            view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard editorProjectSearchCapture("save-as-before"), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "S", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { finish(false); return }
            view.keyDown(with: event)
        case 2:
            guard let panel = editorSaveAsPanels.values.first else { EditorSaveAsRun.next = now + 0.02; return }
            guard panel.nameFieldStringValue == "save-as-source.txt", panel.sheetParent === window,
                  let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] else { finish(false); return }
            guard let content = panel.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { finish(false); return }
            content.displayIfNeeded()
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let pixels = bitmap.bitmapData, Set(Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)).count > 8,
                  let png = bitmap.representation(using: .png, properties: [:]) else { finish(false); return }
            do { try png.write(to: URL(fileURLWithPath: root).appendingPathComponent("save-as-panel.png")) } catch { finish(false); return }

        case 3:
            guard let panel = editorSaveAsPanels.values.first else { finish(false); return }
            panel.nameFieldStringValue = "save-as-destination.txt"
            panel.ok(nil)
        case 4:
            guard editorProjectSearchCapture("save-as-after") else { finish(false); return }
            finish(true); return
        default: finish(false); return
        }
        FileHandle.standardError.write(Data("SAVE_AS stage=\(stage) verified=true\n".utf8))
        EditorSaveAsRun.stage += 1
        EditorSaveAsRun.next = now + 0.3
    }
}
