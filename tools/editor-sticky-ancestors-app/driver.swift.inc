// AppKit 앱의 제품 Metal 결과를 읽는다. 물리 키 입력이나 외부 화면 녹화 검증은 아니다.
@_silgen_name("maru_sticky_ancestor_prepare") private func stickyAncestorPrepare(_ stage: UInt32) -> Bool
@_silgen_name("maru_sticky_ancestor_probe") private func stickyAncestorProbe(_ stage: UInt32) -> Int32
@MainActor private enum StickyAncestorCapture {
    static var stage: UInt32 = 0
    static var prepared = false
    static var waitUntil = 0.0
}
extension MaruAppHostController {
    private func maybeRunStickyAncestorCapture() {
        guard ProcessInfo.processInfo.environment["MARU_EDITOR_STICKY_CAPTURE"] == "1",
              StickyAncestorCapture.stage < 2, let surface = primary,
              surface.window?.isVisible == true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let stage = StickyAncestorCapture.stage
        if !StickyAncestorCapture.prepared {
            guard stickyAncestorPrepare(stage) else { return }
            StickyAncestorCapture.prepared = true
            StickyAncestorCapture.waitUntil = now + 0.5
            return
        }
        guard now >= StickyAncestorCapture.waitUntil, stickyAncestorProbe(stage) > 0,
              let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_EDITOR_STICKY_OUTPUT"] else { return }
        let name = stage == 0 ? "past-wrapped-body" : "active-nested-body"
        let path = URL(fileURLWithPath: root).appendingPathComponent(name + ".ppm").path
        guard maru_metal_renderer_request_test_capture(renderer, path) else { return }
        // 먼저 상태를 진행시켜 중첩 renderTick의 재진입을 막는다.
        StickyAncestorCapture.stage += 1
        StickyAncestorCapture.prepared = false
        withSurface(surface) { metalNeedsRedraw = true; _ = renderTick() }
        guard FileManager.default.fileExists(atPath: path) else { return }
        if StickyAncestorCapture.stage == 2 {
            NSLog("STICKY_CAPTURE_FINISH")
            bypassQuitConfirm = true
            NSApp.terminate(nil)
        }
    }
}
