// 실제 AppKit 마우스 입력으로 제품의 down/up 라우팅을 통과시킨다.
@_silgen_name("maru_editor_outline_probe") private func editorOutlineProbe(_ stage: UInt32) -> Int32
@_silgen_name("maru_editor_outline_action") private func editorOutlineAction(_ stage: UInt32)
@_silgen_name("maru_editor_outline_coordinate") private func editorOutlineCoordinate(_ index: UInt32, _ disclosure: Bool, _ axis: UInt32) -> Double
@_silgen_name("maru_editor_outline_cancel_probe") private func editorOutlineCancelProbe() -> Bool
@MainActor private enum EditorOutlineRun {
    static var stage: UInt32 = 0
    static var next = 0.0
}
extension MaruAppHostController {
    private func editorOutlineClick(_ index: UInt32, disclosure: Bool = false, releaseOutside: Bool = false) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view else { return false }
        let scale = archiveSmokeRenderScale(window)
        let x = editorOutlineCoordinate(index, disclosure, 0) / scale
        let y = editorOutlineCoordinate(index, disclosure, 1) / scale
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
    private func editorOutlineCapture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EDITOR_OUTLINE_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard !FileManager.default.fileExists(atPath: path), maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunEditorOutline() {
        guard ProcessInfo.processInfo.environment["MARU_EDITOR_OUTLINE_CAPTURE"] == "1", EditorOutlineRun.stage < 99,
              let surface = primary, let window = surface.window, let view = surface.view, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= EditorOutlineRun.next else { return }
        let stage = EditorOutlineRun.stage
        let ready = editorOutlineProbe(stage)
        if ready == 0 { return }
        func finish(_ success: Bool) {
            EditorOutlineRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("EDITOR_OUTLINE_FINISH passed=\(success) transport=AppKit-local\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard ready == 1 else { finish(false); return }
        let labels = ["before", "outline", "navigated", "collapsed", "edited", "split", "shared-edit", "original-view", "bottom-scrolled", "empty"]
        guard editorOutlineCapture(labels[Int(stage)]) else { finish(false); return }
        switch stage {
        case 1:
            guard editorOutlineClick(2, releaseOutside: true), editorOutlineCancelProbe(),
                  editorOutlineCapture("cancelled-drag") else { finish(false); return }
            guard editorOutlineClick(2) else { finish(false); return }
        case 2:
            guard editorOutlineClick(0, disclosure: true) else { finish(false); return }
        case 3:
            view.insertText("renamed_", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 5:
            view.insertText("shared_", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 9: finish(true); return
        default: editorOutlineAction(stage)
        }
        EditorOutlineRun.stage += 1
        EditorOutlineRun.next = now + 0.7
    }
}
