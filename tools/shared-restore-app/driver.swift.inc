// 이 파일은 검증용 사본의 MaruAppHost.swift에만 붙인다. 실제 창/렌더/종료 경로를 사용한다.
@_silgen_name("maru_shared_restore_fixture_step")
private func sharedRestoreFixtureStep(_ command: UInt32) -> Int32

@MainActor
private enum SharedRestoreRun {
    static var stage = 0
    static var next = 0.0
    static var splitDispatched = false
}

extension MaruAppHostController {
    private func invokeSharedSplit(window: NSWindow) -> Bool {
        guard let view = primary?.view, let mainMenu = NSApp.mainMenu else { return false }
        var items: [String: (NSMenu, Int)] = [:]
        func collect(_ menu: NSMenu) {
            for (index, item) in menu.items.enumerated() {
                if let key = item.representedObject as? String, key.hasPrefix("split_editor_") {
                    items[key] = (menu, index)
                    // 전역 메뉴 keyEquivalent가 편집기 컨텍스트 밖의 키를 가로채지 않아야 한다.
                    if !item.keyEquivalent.isEmpty { items.removeValue(forKey: key) }
                }
                if let child = item.submenu { collect(child) }
            }
        }
        collect(mainMenu)
        guard Set(items.keys) == Set(["split_editor_right", "split_editor_left", "split_editor_down", "split_editor_up"]),
              captureSharedRestore("before-split") else { return false }
        func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code) else { return false }
            if !view.performKeyEquivalent(with: event) { view.keyDown(with: event) }
            return true
        }
        let entry = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_SPLIT_ENTRY"] ?? "keyboard"
        switch entry {
        case "menu":
            guard let (menu, index) = items["split_editor_right"] else { return false }
            menu.performActionForItem(at: index)
        case "palette":
            guard key(35, "P", [.command, .shift]) else { return false }
            view.insertText("Editor: Split Right", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard captureSharedRestore("split-palette"), key(36, "\r", []) else { return false }
        case "keyboard":
            guard key(42, "\\", [.command]) else { return false }
        default: return false
        }
        FileHandle.standardError.write(Data("SHARED_SPLIT_ENTRY entry=\(entry) transport=AppKit-local\n".utf8))
        return true
    }

    private func captureSharedRestore(_ label: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(label + ".ppm")
        guard !FileManager.default.fileExists(atPath: path.path),
              maru_metal_renderer_request_test_capture(renderer, path.path) else { return false }
        withSurface(surface) {
            metalNeedsRedraw = true
            _ = renderTick()
        }
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func finishSharedRestore(_ success: Bool) {
        if !success { exitCode = 1 }
        SharedRestoreRun.stage = 99
        FileHandle.standardError.write(Data("SHARED_RESTORE_FINISH success=\(success)\n".utf8))
        bypassQuitConfirm = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Local AppKit chords deliberately use the same bypass as existing conflict smokes.
    /// This is separate from the real Korean HID round trip, not a physical Escape assertion.
    private func runSharedClose(window: NSWindow, now: TimeInterval) {
        guard now >= SharedRestoreRun.next, let view = primary?.view else { return }
        func key(_ code: UInt16, _ text: String) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
            view.keyDown(with: event)
            return true
        }
        var ok = true
        switch SharedRestoreRun.stage {
        case 0:
            let ready = sharedRestoreFixtureStep(50)
            if ready == 0 { return }
            if ready == 2 {
                // Recovery notice consumes the first key; dismiss it explicitly before closing.
                if !key(53, "\u{1b}") { finishSharedRestore(false); return }
                SharedRestoreRun.next = now + 0.5
                return
            }
            ok = ready == 1 && captureSharedRestore("before-close") && key(13, "w")
        case 1:
            ok = sharedRestoreFixtureStep(51) == 1 && captureSharedRestore("one-closed")
        case 2:
            // The independent parent checks the backup before any last-view close or save.
            guard let output = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_OUTPUT"],
                  FileManager.default.fileExists(atPath: output + "/one-close-verified") else { return }
            ok = key(13, "w")
        case 3:
            ok = sharedRestoreFixtureStep(52) == 1 && captureSharedRestore("last-prompt") && key(53, "\u{1b}")
        case 4:
            ok = sharedRestoreFixtureStep(53) == 1 && captureSharedRestore("cancelled") && key(1, "s")
        case 5:
            ok = sharedRestoreFixtureStep(54) == 1 && captureSharedRestore("saved") && key(13, "w")
        default:
            ok = sharedRestoreFixtureStep(55) == 1 && captureSharedRestore("last-closed")
            finishSharedRestore(ok)
            return
        }
        if !ok { finishSharedRestore(false); return }
        SharedRestoreRun.stage += 1
        SharedRestoreRun.next = now + 0.5
    }

    private func maybeRunSharedRestore() {
        guard let phase = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_PHASE"],
              phase != "ime", SharedRestoreRun.stage < 99,
              let window = primary?.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if phase == "close" { runSharedClose(window: window, now: now); return }
        if phase == "seed" || phase == "move-refusal" {
            if SharedRestoreRun.stage == 0 {
                let ready = sharedRestoreFixtureStep(1)
                if ready < 0 { finishSharedRestore(false); return }
                if ready == 0 { return }
                if ready == 2 {
                    if !SharedRestoreRun.splitDispatched {
                        SharedRestoreRun.splitDispatched = true
                        if !invokeSharedSplit(window: window) { finishSharedRestore(false) }
                    }
                    return
                }
                SharedRestoreRun.stage = 1
                SharedRestoreRun.next = now + 0.5
                return
            }
            guard now >= SharedRestoreRun.next else { return }
            if phase == "move-refusal" {
                let ok = sharedRestoreFixtureStep(40) == 1 && captureSharedRestore("move-refusal")
                finishSharedRestore(ok)
                return
            }
            let ok = sharedRestoreFixtureStep(10) == 1 && captureSharedRestore("seed")
            finishSharedRestore(ok)
            return
        }
        if SharedRestoreRun.stage == 0 {
            let ready = sharedRestoreFixtureStep(20)
            if ready == 0 { return }
            guard ready == 1, captureSharedRestore("restored") else { finishSharedRestore(false); return }
            SharedRestoreRun.stage = 1
            SharedRestoreRun.next = now + 0.8
            return
        }
        guard now >= SharedRestoreRun.next else { return }
        switch SharedRestoreRun.stage {
        case 1:
            guard sharedRestoreFixtureStep(2) == 1 else { return }
            guard sharedRestoreFixtureStep(21) == 1, captureSharedRestore("settled") else { finishSharedRestore(false); return }
            window.setContentSize(NSSize(width: 640, height: 480))
            SharedRestoreRun.stage = 2
        case 2:
            guard sharedRestoreFixtureStep(22) == 1, captureSharedRestore("narrow") else { finishSharedRestore(false); return }
            window.setContentSize(NSSize(width: 1200, height: 800))
            SharedRestoreRun.stage = 3
        default:
            let ok = sharedRestoreFixtureStep(23) == 1 && captureSharedRestore("wide")
            finishSharedRestore(ok)
        }
        SharedRestoreRun.next = now + 0.6
    }
}
