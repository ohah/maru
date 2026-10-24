// 물리 HID와 compositor present를 재는 것이 아니라 실제 AppKit dispatch→renderTick 반환을 잰다.
@_silgen_name("maru_ew2_wake") private func ew2BackendWake()
@_silgen_name("maru_ew2_stamp") private func ew2Stamp()
@_silgen_name("maru_ew2_prepare") private func ew2Prepare() -> Bool
@_silgen_name("maru_ew2_ready") private func ew2Ready() -> Bool
@_silgen_name("maru_ew2_due_ns") private func ew2DueNS() -> Int64
@_silgen_name("maru_ew2_validate") private func ew2Validate() -> Bool
@_silgen_name("maru_ew2_inserted_bytes") private func ew2InsertedBytes() -> Int64
@_silgen_name("maru_ew2_mode") private func ew2Mode() -> UInt32
@MainActor private enum EW2GUI {
    static var stableSince = 0.0
    static var started = false
    static var done = false
    static var busy = false
    static var epoch = 0.0
    static var lastStart = 0.0
    static var lastEnd = 0.0
    static var index = 0
    static var wakeMaxMS = 0.0
    static var records: [[String: Double]] = []
}
extension MaruAppHostController {
    private func ew2Capture(_ name: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EW2_GUI_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard maru_metal_renderer_request_test_capture(renderer, path) else { return false }
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        return FileManager.default.fileExists(atPath: path)
    }
    private func maybeRunEW2GUI() {
        guard ProcessInfo.processInfo.environment["MARU_EW2_GUI"] == "1", !EW2GUI.started,
              !EW2GUI.done, !EW2GUI.busy, primary?.window?.isVisible == true else { return }
        if ProcessInfo.processInfo.environment["MARU_EW2_GUI_FOREGROUND"] == "1",
           let window = primary?.window, (!NSApp.isActive || !window.isKeyWindow) {
            EW2GUI.stableSince = 0
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 창 활성화 뒤 늦게 도착하는 시작 이벤트를 입력 표본에 섞지 않는다.
        let now = ProcessInfo.processInfo.systemUptime
        if EW2GUI.stableSince == 0 {
            EW2GUI.stableSince = now
            // 유휴 창은 새 프레임이 없을 수 있으므로 준비 재시도도 명시적으로 깨운다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.maybeRunEW2GUI() }
            return
        }
        guard now - EW2GUI.stableSince >= 1 else { return }
        ew2Stamp()
        guard ew2Prepare() else { return }
        EW2GUI.started = true
        EW2GUI.busy = true
        _ = ew2Capture("before")
        EW2GUI.busy = false
        EW2GUI.epoch = ProcessInfo.processInfo.systemUptime + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.ew2SendKey() }
    }
    private func ew2SendKey() {
        guard !EW2GUI.done, let surface = primary, let window = surface.window, let view = surface.view else { return }
        let intervalMS = Double(ProcessInfo.processInfo.environment["MARU_EW2_GUI_INTERVAL_MS"] ?? "50") ?? 50
        let target = EW2GUI.epoch + Double(EW2GUI.index) * intervalMS / 1000
        let start = ProcessInfo.processInfo.systemUptime
        ew2Stamp()
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: start,
              windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
              isARepeat: false, keyCode: 49) else { return }
        EW2GUI.busy = true
        view.keyDown(with: event)
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        EW2GUI.busy = false
        let end = ProcessInfo.processInfo.systemUptime
        EW2GUI.lastStart = start
        EW2GUI.lastEnd = end
        EW2GUI.records.append(["inserted_bytes": Double(ew2InsertedBytes()), "foreground": NSApp.isActive && window.isKeyWindow ? 1 : 0, "queue_ms": max(0,start-target)*1000, "service_ms": (end-start)*1000,
                               "target_to_render_return_ms": (end-target)*1000])
        EW2GUI.index += 1
        let generation = EW2GUI.index
        if EW2GUI.index < 20 {
            let next = EW2GUI.epoch + Double(EW2GUI.index) * intervalMS / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0,next-end)) { self.ew2SendKey() }
        }
        ew2Wake(generation)
    }
    private func ew2Wake(_ generation: Int) {
        guard !EW2GUI.done, generation == EW2GUI.index else { return }
        ew2Stamp()
        if ew2Ready() {
            if EW2GUI.index == 20 { ew2Finish() }
            return
        }
        let delay = max(0.001,Double(ew2DueNS())/1e9)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !EW2GUI.done, generation == EW2GUI.index, let surface = self.primary else { return }
            ew2BackendWake()
            let start = ProcessInfo.processInfo.systemUptime
            EW2GUI.busy = true
            self.withSurface(surface) { self.metalNeedsRedraw = true; _ = self.renderTick() }
            EW2GUI.busy = false
            EW2GUI.wakeMaxMS = max(EW2GUI.wakeMaxMS,(ProcessInfo.processInfo.systemUptime-start)*1000)
            self.ew2Wake(generation)
        }
    }
    private func ew2Finish() {
        guard !EW2GUI.done, let root = ProcessInfo.processInfo.environment["MARU_EW2_GUI_OUTPUT"] else { return }
        EW2GUI.done = true
        let now = ProcessInfo.processInfo.systemUptime
        let valid = ew2Validate()
        let report: [String: Any] = ["mode": ew2Mode(), "valid": valid, "inserted_bytes": ew2InsertedBytes(), "events": EW2GUI.records,
            "fresh_after_last_key_start_ms": (now-EW2GUI.lastStart)*1000,
            "fresh_after_last_key_service_ms": max(0,now-EW2GUI.lastEnd)*1000,
            "wake_max_ms": EW2GUI.wakeMaxMS,
            "scope": "AppKit synthetic keyDown and product renderTick; not physical HID or compositor present"]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            try data.write(to: URL(fileURLWithPath: root).appendingPathComponent("events.json"))
        } catch { NSLog("EW2_GUI_REPORT_FAILED %@", String(describing:error)) }
        _ = ew2Capture("after")
        NSLog(valid ? "EW2_GUI_FINISH" : "EW2_GUI_VALIDATION_FAILED")
        bypassQuitConfirm = true
        NSApp.terminate(nil)
    }
}
