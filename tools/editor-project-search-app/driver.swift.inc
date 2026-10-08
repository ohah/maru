// 실제 AppKit 입력과 제품 Metal 읽기 경로를 사용한다.
@_silgen_name("maru_editor_project_search_probe") private func editorProjectSearchProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_project_search_action") private func editorProjectSearchAction(_ stage: UInt32)
@_silgen_name("maru_editor_project_search_coordinate") private func editorProjectSearchCoordinate(_ axis: UInt32) -> Double
@_silgen_name("maru_editor_project_search_field_coordinate") private func editorProjectSearchFieldCoordinate(_ byte: UInt32, _ axis: UInt32) -> Double
@MainActor private enum EditorProjectSearchRun {
    static var stage: UInt32 = 0
    static var next = 0.0
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
        let labels = ["before", "query", "results", "navigated", "bottom-scrolled", "disk-navigated", "cancelled"]
        guard editorProjectSearchCapture(labels[Int(stage)]) else { finish(false); return }
        let unicode = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_UNICODE"] == "1"
        switch stage {
        case 1: view.insertText(unicode ? "한글🙂x" : "sample", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 2:
            guard editorProjectSearchSelectQuery(unicode: unicode), editorProjectSearchCapture("query-selection") else { finish(false); return }
            guard editorProjectSearchClick(0) else { finish(false); return }
        case 4:
            if Int(ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_DISK_FILES"] ?? "0") ?? 0 > 0 {
                guard editorProjectSearchClick(0) else { finish(false); return }
            } else {
                editorProjectSearchAction(4)
                EditorProjectSearchRun.stage = 5
            }
        case 5: editorProjectSearchAction(4)
        case 6: finish(true); return
        default: editorProjectSearchAction(stage)
        }
        EditorProjectSearchRun.stage += 1
        EditorProjectSearchRun.next = now + 0.7
    }
}
