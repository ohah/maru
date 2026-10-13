// The copied app owns only its own visible window. Quit uses the real AppKit path.
@_silgen_name("maru_remote_restart_ready")
private func remoteRestartReady() -> Int32
@MainActor private enum RemoteRestartRun { static var started = false; static var captured = false }
extension MaruAppHostController {
    private func maybeRunRemoteRestart() {
        guard let phase = ProcessInfo.processInfo.environment["MARU_REMOTE_RESTART_PHASE"],
              let root = ProcessInfo.processInfo.environment["MARU_REMOTE_RESTART_OUTPUT"],
              !RemoteRestartRun.started else { return }
        RemoteRestartRun.started = true
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let surface = self.primary, let window = surface.window, window.isVisible else { return }
                let ready = remoteRestartReady()
                if ready > 0 {
                    if !RemoteRestartRun.captured, let renderer = surface.metalRenderer {
                        let capture = root + "/frame.ppm"
                        if maru_metal_renderer_request_test_capture(renderer, capture) {
                            self.withSurface(surface) { self.metalNeedsRedraw = true; _ = self.renderTick() }
                            RemoteRestartRun.captured = FileManager.default.fileExists(atPath: capture)
                        }
                        if let marker = ProcessInfo.processInfo.environment["MARU_REMOTE_RESTART_NOTICE_ID"] {
                            UNUserNotificationCenter.current().getNotificationSettings { settings in
                                UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                                    let ours = notifications.filter { $0.request.content.body.contains(marker) }
                                    let result: [String: Any] = ["authorization": settings.authorizationStatus.rawValue,
                                                               "owned_delivered": ours.map { $0.request.content.body }]
                                    if let data = try? JSONSerialization.data(withJSONObject: result) {
                                        try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("notifications.json"))
                                    }
                                }
                            }
                        }
                    }
                    FileHandle.standardError.write(Data("REMOTE_RESTART_GUI phase=\(phase) visible=true ready=\(ready)\n".utf8))
                    try? Data("ready\n".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("ready"))
                }
                if FileManager.default.fileExists(atPath: root + "/quit") {
                    timer.invalidate()
                    // Accept the actual product Quit confirmation. Skipping it would also skip
                    // the product's keep-alive policy snapshot and terminate the runtime.
                    guard let session = surface.appSession else { return }
                    maru_macos_app_session_request_app_quit(session)
                    self.withSurface(surface) {
                        self.sendKeyEvent(MaruAppHostKeyEvent(codepoint: 0, base_codepoint: 0,
                            key_code: UInt32(MaruAppHostKeyCodeEnter.rawValue), modifier_shift: 0,
                            modifier_control: 0, modifier_option: 0, modifier_command: 0,
                            is_repeat: 0, is_release: 0, raw_key_code: 36))
                    }
                }
            }
        }
    }
}
