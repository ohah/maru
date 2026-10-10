// 실제 AppKit 입력과 제품 Metal 읽기 경로를 사용한다.
@_silgen_name("maru_editor_project_search_probe") private func editorProjectSearchProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_project_search_action") private func editorProjectSearchAction(_ stage: UInt32)
@_silgen_name("maru_editor_project_search_coordinate") private func editorProjectSearchCoordinate(_ axis: UInt32) -> Double
@_silgen_name("maru_editor_project_search_field_coordinate") private func editorProjectSearchFieldCoordinate(_ byte: UInt32, _ axis: UInt32) -> Double
@MainActor private enum EditorProjectSearchRun {
    static var stage: UInt32 = 0
    static var next = 0.0
    static var markedCaptured = false
    static var heldPoint: NSPoint? = nil
    static var tinyResized = false
}
extension MaruAppHostController {
    private func editorProjectSearchClick(_ index: UInt32, disclosure: Bool = false, releaseOutside: Bool = false) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return false }
        let scale = archiveSmokeRenderScale(window)
        let x = editorProjectSearchCoordinate(0) / scale
        let y = editorProjectSearchCoordinate(1) / scale
        guard x >= 0, y >= 0 else { return false }
        let point = view.convert(NSPoint(x: x, y: view.bounds.height - y), to: nil)
        let outside = view.convert(NSPoint(x: 1, y: view.bounds.height - 1), to: nil)
        let events: [NSEvent.EventType] = releaseOutside ? [.leftMouseDown, .leftMouseDragged, .leftMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in events {
            let location = releaseOutside && type != .leftMouseDown ? outside : point
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else if type == .leftMouseDragged { view.mouseDragged(with: event) }
            else { view.mouseUp(with: event) }
        }
        return true
    }
    private func editorProjectSearchHold(_ down: Bool) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return false }
        if down {
            let scale = archiveSmokeRenderScale(window)
            let x = editorProjectSearchCoordinate(0) / scale
            let y = editorProjectSearchCoordinate(1) / scale
            guard x >= 0 && y >= 0 else { return false }
            EditorProjectSearchRun.heldPoint = view.convert(NSPoint(x: x, y: view.bounds.height - y), to: nil)
        }
        guard let point = EditorProjectSearchRun.heldPoint,
              let event = NSEvent.mouseEvent(with: down ? .leftMouseDown : .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: down ? 1 : 0) else { return false }
        if down { view.mouseDown(with: event) } else { view.mouseUp(with: event); EditorProjectSearchRun.heldPoint = nil }
        return true
    }
    private func editorProjectSearchSelectQuery(unicode: Bool) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return false }
        let scale = archiveSmokeRenderScale(window)
        let y = editorProjectSearchFieldCoordinate(0, 1) / scale
        let start = editorProjectSearchFieldCoordinate(unicode ? 3 : 2, 0) / scale
        let end = editorProjectSearchFieldCoordinate(unicode ? 10 : 5, 0) / scale
        guard y >= 0, start >= 0, end >= start else { return false }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let x = type == .leftMouseDown ? start : end
            let point = view.convert(NSPoint(x: x, y: view.bounds.height - y), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else if type == .leftMouseDragged { view.mouseDragged(with: event) }
            else { view.mouseUp(with: event) }
        }
        return editorProjectSearchProbe(100) == 1
    }
    private func editorProjectSearchCapture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard !FileManager.default.fileExists(atPath: path), maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunEditorProjectSearch() {
        guard ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_CAPTURE"] == "1", EditorProjectSearchRun.stage < 99,
              let surface = primary, let window = surface.window, let view = surface.view, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorProjectSearchRun.next else { return }
        let stage = EditorProjectSearchRun.stage
        let tiny = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_TINY"] == "1"
        if stage == 1 && tiny && !EditorProjectSearchRun.tinyResized {
            guard editorProjectSearchProbe(103) == 1, editorProjectSearchCapture("geometry-hidden") else {
                exitCode = 1; NSApp.terminate(nil); return
            }
            window.setContentSize(NSSize(width: 640, height: 480))
            EditorProjectSearchRun.tinyResized = true
            EditorProjectSearchRun.next = now + 0.3
            return
        }
        if stage == 1 && tiny { editorProjectSearchAction(0) }

        let physical = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_PHYSICAL"] == "1"
        if physical && stage == 2 && !EditorProjectSearchRun.markedCaptured && editorProjectSearchProbe(101) == 1 {
            guard editorProjectSearchCapture("ime-marked") else { return }
            EditorProjectSearchRun.markedCaptured = true
        }
        let ready = editorProjectSearchProbe(stage)
        if ready == 0 { return }
        func finish(_ success: Bool) {
            EditorProjectSearchRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(success) transport=AppKit-local\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard ready == 1 else { finish(false); return }
        let matrix = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_MATRIX"] == "1"
        let labels = ["before", "query", "results", "navigated", "bottom-scrolled", "disk-navigated", "cancelled", "shared", "independent", "zero-override", "root-changed", "stale-release", "replace-input", "replace-results", "replace-file", "replace-conflict", "replace-single", "replace-disk", "right-replace-disk", "right-replace-file", "right-replace-conflict", "search-pane", "search-pane-navigated", "pane-preview-results", "pane-preview-ready", "preview-pane", "replace-applied-saved", "replace-undo", "replace-undo-saved", "batch-results", "right-batch-preview", "bottom-batch-preview", "bottom-batch-saved", "right-batch-saved", "batch-undo", "batch-undo-saved"]
        let refusing = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_REPLACE_IME_REFUSE"] == "1"
        let label = refusing && stage == 26 ? "replace-verifying" : refusing && stage == 27 ? "replace-ime-conflict" : labels[Int(stage)]
        guard editorProjectSearchCapture(label) else { finish(false); return }
        let unicode = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_UNICODE"] == "1"
        switch stage {
        case 1:
            if physical {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                NSApp.activate(ignoringOtherApps: true)
                let root = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_OUTPUT"]!
                try? Data("ready".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("physical-ready"))
            } else {
                view.insertText(unicode ? "한글🙂x" : "sample", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case 2:
            if physical {
                guard EditorProjectSearchRun.markedCaptured && editorProjectSearchProbe(102) == 1 else { finish(false); return }
                FileHandle.standardError.write(Data("PHYSICAL_IME accepted=true\n".utf8))
            } else if !editorProjectSearchSelectQuery(unicode: unicode) { finish(false); return }
            guard editorProjectSearchCapture("query-selection") else { finish(false); return }
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 4:
            if Int(ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_DISK_FILES"] ?? "0") ?? 0 > 0 {
                guard editorProjectSearchClick(0) else { finish(false); return }
            } else {
                editorProjectSearchAction(4)
                EditorProjectSearchRun.stage = 5
            }
        case 5: editorProjectSearchAction(4)
        case 6:
            if ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_REPLACE_PREVIEW"] == "1" {
                editorProjectSearchAction(12)
                EditorProjectSearchRun.stage = 12
                return
            }
            if !matrix { finish(true); return }
            editorProjectSearchAction(6)
        case 8:
            editorProjectSearchAction(8)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else { finish(false); return }
            view.keyDown(with: event)
            view.insertText("no results", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 9:
            guard editorProjectSearchHold(true) else { finish(false); return }
            editorProjectSearchAction(9)
        case 10:
            guard editorProjectSearchHold(false) else { finish(false); return }
        case 12:
            guard editorProjectSearchClick(0) else { finish(false); return }
            guard editorProjectSearchClick(0) else { finish(false); return }
            view.insertText("renamed", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 13:
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 14, 15, 16, 17, 18, 19: editorProjectSearchAction(stage)
        case 20:
            editorProjectSearchAction(20)
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 21: editorProjectSearchAction(21)
        case 22, 23: editorProjectSearchAction(stage)
        case 24:
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 25:
            if ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_REPLACE_APPLY"] != "1" { finish(true); return }
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 26, 27:
            if refusing {
                if stage == 26 { editorProjectSearchAction(26) }
                else { finish(true); return }
                break
            }
            let saving = stage == 27
            // 완료 알림의 닫기 키는 기존 계약대로 소비된다. 실제 Esc를 보낸 뒤 Undo/Save를 확인한다.
            if stage == 26 {
                guard let dismiss = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { finish(false); return }
                view.keyDown(with: dismiss)
            }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: saving ? "s" : "z", charactersIgnoringModifiers: saving ? "s" : "z", isARepeat: false, keyCode: saving ? 1 : 6) else { finish(false); return }
            view.keyDown(with: event)
        case 28:
            if ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_REPLACE_BATCH"] == "1" { editorProjectSearchAction(28) }
            else { finish(true); return }
        case 29, 31:
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 30, 32, 33, 34: editorProjectSearchAction(stage)
        case 35: finish(true); return
        case 11: finish(true); return
        default: editorProjectSearchAction(stage)
        }
        EditorProjectSearchRun.stage += 1
        EditorProjectSearchRun.next = now + 0.7
    }
}
