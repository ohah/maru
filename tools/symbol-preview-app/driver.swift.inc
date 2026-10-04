// 실제 AppKit 키 라우팅과 제품 Metal 캡처. 한국어는 명시적으로 NSTextInputClient 콜백 주입이다.
@_silgen_name("maru_symbol_preview_probe")
private func symbolPreviewProbe(_ stage: UInt32) -> Int32
@MainActor private enum SymbolPreviewRun {
    static var stage: UInt32 = 0
    static var next = 0.0
}
extension MaruAppHostController {
    private func symbolPreviewKey(_ code: UInt16, _ text: String, _ mods: NSEvent.ModifierFlags = []) -> Bool {
        guard let surface = primary, let window = surface.window, let view = surface.view,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
        if !view.performKeyEquivalent(with: event) { view.keyDown(with: event) }
        return true
    }
    private func symbolPreviewCapture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_SYMBOL_PREVIEW_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard !FileManager.default.fileExists(atPath: path), maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunSymbolPreview() {
        guard ProcessInfo.processInfo.environment["MARU_SYMBOL_PREVIEW_CAPTURE"] == "1", SymbolPreviewRun.stage < 99,
              let surface = primary, let window = surface.window, let view = surface.view, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= SymbolPreviewRun.next else { return }
        let stage = SymbolPreviewRun.stage
        let ready = symbolPreviewProbe(stage)
        if ready == 0 { return }
        func finish(_ success: Bool) {
            SymbolPreviewRun.stage = 99
            if !success { exitCode = 1 }
            FileHandle.standardError.write(Data("SYMBOL_PREVIEW_FINISH passed=\(success) transport=AppKit-local\n".utf8))
            bypassQuitConfirm = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard ready == 1 else { finish(false); return }
        let labels = ["before", "opened", "filtered", "next-symbol", "cancelled", "korean-query", "accepted"]
        guard symbolPreviewCapture(labels[Int(stage)]) else { finish(false); return }
        switch stage {
        case 0:
            guard symbolPreviewKey(31, "O", [.command, .shift]) else { finish(false); return }
        case 1:
            view.insertText("sample4", replacementRange: NSRange(location: NSNotFound, length: 0))
        case 2:
            guard symbolPreviewKey(125, "\u{F701}") else { finish(false); return }
        case 3:
            guard symbolPreviewKey(53, "\u{1b}") else { finish(false); return }
        case 4:
            guard symbolPreviewKey(31, "O", [.command, .shift]) else { finish(false); return }
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.unmarkText()
        case 5:
            guard symbolPreviewKey(53, "\u{1b}"), symbolPreviewKey(31, "O", [.command, .shift]) else { finish(false); return }
            view.insertText("sample40", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard symbolPreviewKey(36, "\r") else { finish(false); return }
        default: finish(true); return
        }
        SymbolPreviewRun.stage += 1
        SymbolPreviewRun.next = now + 0.7
    }
}
