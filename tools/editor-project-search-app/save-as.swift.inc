// 실제 NSEvent로 명령을 보내고 제품 NSSavePanel을 그대로 조작한다.
@_silgen_name("maru_editor_save_as_probe") private func editorSaveAsProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_save_as_setup") private func editorSaveAsSetup()
@_silgen_name("maru_editor_save_as_history") private func editorSaveAsHistory() -> Int32
@MainActor private enum EditorSaveAsRun {
    static var stage: UInt32 = 0
    static var next = 0.0
    static var timer: Timer?
    static var confirming = false
    static var editedDuringWrite = false
    static var imeStarted = false
}
extension MaruAppHostController {
    private func maybeRunSaveAsCommand() {
        guard !EditorSaveAsRun.confirming, EditorProjectSearchRun.stage < 99 else { return }
        if EditorSaveAsRun.timer == nil {
            // 저장 sheet가 열린 뒤 제품 프레임이 쉬어도 검증 단계는 계속 진행한다.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.maybeRunSaveAsCommand() }
            }
            EditorSaveAsRun.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        guard let surface = primary, let window = surface.window, let view = surface.view else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorSaveAsRun.next else { return }
        let stage = EditorSaveAsRun.stage
        if stage == 4 && !editorSaveAsPanels.isEmpty {
            EditorSaveAsRun.next = now + 0.05
            return
        }
        func finish(_ success: Bool, _ reason: String = "none") {
            EditorSaveAsRun.timer?.invalidate()
            EditorSaveAsRun.timer = nil
            EditorProjectSearchRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(success) transport=AppKit-local save-as=true\n".utf8))
            FileHandle.standardError.write(Data("SAVE_AS_FINISH stage=\(stage) reason=\(reason) screen_capture_permission=\(CGPreflightScreenCaptureAccess())\n".utf8))
            if ProcessInfo.processInfo.environment["MARU_EDITOR_SAVE_AS_PHYSICAL_IME"] == "1",
               let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] {
                try? Data().write(to: URL(fileURLWithPath: root).appendingPathComponent("save-as-ime-finished"), options: .atomic)
            }
            bypassQuitConfirm = true
            // 실패한 sheet가 남으면 AppKit이 종료를 보류해 원래 실패를 timeout으로 가린다.
            // 검증용 정리도 제품의 취소 callback을 통해 요청을 정산한다.
            DispatchQueue.main.async {
                for panel in Array(self.editorSaveAsPanels.values) {
                    if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
                    panel.orderOut(nil)
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        if stage == 4, ProcessInfo.processInfo.environment["MARU_EDITOR_SAVE_AS_SCENARIO"] == "edit-during-write",
           !EditorSaveAsRun.editedDuringWrite {
            guard let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] else { finish(false, "writer_root"); return }
            let directory = URL(fileURLWithPath: root)
            let entered = directory.appendingPathComponent("save-as-writer-entered")
            guard FileManager.default.fileExists(atPath: entered.path) else { EditorSaveAsRun.next = now + 0.02; return }
            guard (try? Data(contentsOf: entered)) == Data("foo!".utf8), editorSaveAsProbe(5) == 1 else { finish(false, "writer_admission"); return }
            EditorSaveAsRun.editedDuringWrite = true
            view.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard editorProjectSearchCapture("save-as-edit-pending") else { finish(false, "writer_edit_capture"); return }
            do { try Data().write(to: directory.appendingPathComponent("save-as-writer-release"), options: .atomic) }
            catch { finish(false, "writer_release"); return }
            EditorSaveAsRun.next = now + 0.05
            return
        }
        if stage == 1, ProcessInfo.processInfo.environment["MARU_EDITOR_SAVE_AS_PHYSICAL_IME"] == "1" {
            guard let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] else { finish(false, "ime_root"); return }
            if !EditorSaveAsRun.imeStarted {
                guard editorSaveAsProbe(1) == 1 else { finish(false, "ime_initial_model"); return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(view)
                EditorSaveAsRun.imeStarted = true
                do { try Data().write(to: URL(fileURLWithPath: root).appendingPathComponent("save-as-physical-ready"), options: .atomic) }
                catch { finish(false, "ime_ready"); return }
                return
            }
            guard view.hasMarkedText(), view.markedRange().length == 1, editorSaveAsProbe(6) == 1 else { EditorSaveAsRun.next = now + 0.05; return }
            guard editorProjectSearchCapture("save-as-ime-marked"), editorProjectSearchCapture("save-as-before"),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "S", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)
            else { finish(false, "ime_capture"); return }
            FileHandle.standardError.write(Data("SAVE_AS_IME marked=true length=1\n".utf8))
            // 중첩 AppKit 이벤트가 같은 명령을 재전송하지 않게 먼저 단계를 이동한다.
            EditorSaveAsRun.stage = 2
            EditorSaveAsRun.next = now + 0.3
            view.keyDown(with: event)
            return
        }
        let ready = editorSaveAsProbe(stage)
        if ready == 0 { EditorSaveAsRun.next = now + 0.02; return }
        guard ready == 1 else { finish(false, "model_probe"); return }
        switch stage {
        case 0: editorSaveAsSetup()
        case 1:
            view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard editorProjectSearchCapture("save-as-before"), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: now, windowNumber: window.windowNumber, context: nil, characters: "S", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { finish(false); return }
            view.keyDown(with: event)
        case 2:
            guard let panel = editorSaveAsPanels.values.first else { EditorSaveAsRun.next = now + 0.02; return }
            guard panel.nameFieldStringValue == "save-as-source.txt" else { finish(false, "panel_name"); return }
            guard panel.sheetParent === window else { finish(false, "panel_owner"); return }
            guard let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] else { finish(false, "output_directory"); return }
            if ProcessInfo.processInfo.environment["MARU_NATIVE_PANEL_CAPTURE_EXTERNAL"] == "1" {
                let directory = URL(fileURLWithPath: root)
                let request = directory.appendingPathComponent("save-as-panel-request.json")
                if !FileManager.default.fileExists(atPath: request.path) {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: ["window_id": window.windowNumber, "panel_id": panel.windowNumber])
                        try data.write(to: request, options: .atomic)
                    } catch { finish(false, "panel_capture_request"); return }
                }
                let image = directory.appendingPathComponent("save-as-panel.png")
                guard FileManager.default.fileExists(atPath: image.path) else {
                    EditorSaveAsRun.next = now + 0.05
                    return
                }
                guard let data = try? Data(contentsOf: image), let bitmap = NSBitmapImageRep(data: data), let pixels = bitmap.bitmapData,
                      bitmap.pixelsWide > 100, bitmap.pixelsHigh > 100,
                      Set(Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)).count > 8
                else { finish(false, "external_panel_bitmap"); return }
            } else {
            guard let content = panel.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { finish(false, "panel_bitmap_allocation"); return }
            content.displayIfNeeded()
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let pixels = bitmap.bitmapData else { finish(false, "panel_bitmap_missing"); return }
            guard Set(Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)).count > 8 else { finish(false, "panel_bitmap_uniform"); return }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { finish(false, "panel_png_encoding"); return }
            do { try png.write(to: URL(fileURLWithPath: root).appendingPathComponent("save-as-panel.png")) } catch { finish(false, "panel_png_write"); return }
            }

        case 3:
            if ProcessInfo.processInfo.environment["MARU_NATIVE_PANEL_CAPTURE_EXTERNAL"] == "1",
               let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] {
                let directory = URL(fileURLWithPath: root)
                let request = directory.appendingPathComponent("save-as-confirm-request")
                if !FileManager.default.fileExists(atPath: request.path) {
                    do { try Data().write(to: request, options: .atomic) }
                    catch { finish(false, "confirm_request"); return }
                }
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("save-as-confirm-sent").path) else {
                    EditorSaveAsRun.next = now + 0.05
                    return
                }
                EditorSaveAsRun.stage = 4
                EditorSaveAsRun.next = now + 0.3
                return
            }
            guard let panel = editorSaveAsPanels.values.first else { finish(false); return }
            panel.nameFieldStringValue = "save-as-destination.txt"
            // ok의 중첩 이벤트에서 아직 미접수인 요청을 완료로 검사하지 않는다.
            EditorSaveAsRun.confirming = true
            panel.ok(nil)
            EditorSaveAsRun.confirming = false
            EditorSaveAsRun.stage = 4
            EditorSaveAsRun.next = ProcessInfo.processInfo.systemUptime + 0.3
            FileHandle.standardError.write(Data("SAVE_AS stage=3 verified=true\n".utf8))
            return
        case 4:
            if ProcessInfo.processInfo.environment["MARU_EDITOR_SAVE_AS_PHYSICAL_IME"] == "1", view.hasMarkedText() {
                finish(false, "ime_not_committed"); return
            }
            guard editorSaveAsHistory() == 1, editorSaveAsProbe(4) == 1 else { finish(false, "undo_redo"); return }
            guard editorProjectSearchCapture("save-as-after") else { finish(false); return }
            finish(true); return
        default: finish(false); return
        }
        FileHandle.standardError.write(Data("SAVE_AS stage=\(stage) verified=true\n".utf8))
        EditorSaveAsRun.stage += 1
        EditorSaveAsRun.next = now + 0.3
    }
}
