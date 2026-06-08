import AppKit
import Darwin
import Foundation

@main
@MainActor
final class MaruAppHostController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retainedDelegate: MaruAppHostController?
    private static let statusOK = Int32(MaruAppHostStatusOk.rawValue)

    private let artifactDirectory = "zig-out/maru-macos-app-dev"
    private let summaryPath = "zig-out/maru-macos-app-dev/app-dev.summary.txt"
    private var capabilities = MaruAppHostCapabilities()
    private var window: NSWindow?
    private var devSession: OpaquePointer?
    private var tickTimer: Timer?
    private var latestFrameSummary = MaruAppHostDevFrameSummary()
    private var devSessionStatus = MaruAppHostController.statusOK
    private var smokeMode = false
    private var exitCode: Int32 = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = MaruAppHostController()

        // NSApplication의 delegate 수명은 제품 앱 전체 수명과 같아야 한다. 지역 변수만
        // 두면 future refactor에서 delegate가 일찍 해제될 수 있으므로 명시적으로 잡아 둔다.
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        Darwin.exit(delegate.exitCode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        let abiReady = validateZigBoundary()
        let smokeDuration = smokeDurationMs()
        smokeMode = smokeDuration != nil

        if !abiReady {
            exitCode = 1
            writeSummary(visibleUI: false, abiReady: false, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }

        let window = makePlaceholderWindow()
        self.window = window
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !startDevSession(smokeMode: smokeMode) {
            writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }

        startFrameLoopTicks()

        if let smokeDuration {
            Timer.scheduledTimer(withTimeInterval: Double(smokeDuration) / 1000.0, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        tickTimer?.invalidate()
        tickTimer = nil
        tickDevSession()
        shutdownDevSession()
        writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return true
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        NSApp.terminate(nil)
    }

    private func validateZigBoundary() -> Bool {
        // Swift 제품 host가 시작할 때 Zig ABI version과 ownership capability를 먼저 본다.
        // 이 확인이 없으면 Swift 쪽 앱 lifecycle이 오래된 Zig static library를 링크해도
        // 조용히 실행되어 input/close event shape가 어긋날 수 있다.
        let status = maru_macos_app_host_capabilities(&capabilities)
        return status == Self.statusOK &&
            capabilities.abi_version == MARU_MACOS_APP_HOST_ABI_VERSION &&
            capabilities.swift_owns_ns_application == 1 &&
            capabilities.zig_owns_frame_loop == 1
    }

    private func validateCachedCapabilities() -> Bool {
        return capabilities.abi_version == MARU_MACOS_APP_HOST_ABI_VERSION &&
            capabilities.swift_owns_ns_application == 1 &&
            capabilities.zig_owns_frame_loop == 1
    }

    private func makePlaceholderWindow() -> NSWindow {
        // 아직 Metal terminal view는 붙이지 않는다. Zig 쪽 shell surface와 FrameLoop는
        // 살아 있지만, 화면은 placeholder로 남겨 UI lifecycle과 runtime lifecycle 실패를
        // 분리해서 볼 수 있게 한다.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maru"

        let content = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 600))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1.0).cgColor
        window.contentView = content

        return window
    }

    private func startDevSession(smokeMode: Bool) -> Bool {
        var config = MaruAppHostDevSessionConfig(
            abi_version: MARU_MACOS_APP_HOST_ABI_VERSION,
            cols: 80,
            rows: 24,
            queue_capacity: 16,
            command_kind: UInt32(
                smokeMode
                    ? MaruAppHostDevCommandControlledSmoke.rawValue
                    : MaruAppHostDevCommandInteractiveShell.rawValue
            ),
            reserved: 0
        )
        var session: OpaquePointer?
        let status = maru_macos_app_dev_session_create(&config, &session)
        devSessionStatus = status
        guard status == Self.statusOK, let created = session else {
            exitCode = 1
            devSession = nil
            return false
        }

        devSession = created
        tickDevSession()
        return true
    }

    private func startFrameLoopTicks() {
        tickTimer?.invalidate()
        // Swift는 frame pacing만 정한다. PTY queue drain, SurfaceRuntime 적용,
        // RenderFrame 준비는 모두 Zig FrameLoop.tick이 소유한다.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickDevSession()
            }
        }
    }

    private func tickDevSession() {
        guard let devSession else {
            return
        }

        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_tick(devSession, &summary)
        devSessionStatus = status
        if status == Self.statusOK {
            latestFrameSummary = summary
            if summary.frame_loop_ticks <= 1 {
                writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            }
        } else {
            exitCode = 1
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            NSApp.terminate(nil)
        }
    }

    private func shutdownDevSession() {
        guard let devSession else {
            return
        }

        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_close(devSession, &summary)
        devSessionStatus = status
        if status == Self.statusOK {
            latestFrameSummary = summary
        } else {
            exitCode = 1
        }
        maru_macos_app_dev_session_destroy(devSession)
        self.devSession = nil
    }

    private func smokeDurationMs() -> UInt32? {
        guard let raw = ProcessInfo.processInfo.environment["MARU_MACOS_APP_DEV_SMOKE_MS"] else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UInt32(trimmed), parsed > 0 else {
            return 1500
        }

        // 수동 확인용으로 길게 둘 수는 있지만, 오타가 앱을 오래 붙잡지 않도록 smoke 상한을 둔다.
        return min(parsed, 600_000)
    }

    private func writeSummary(visibleUI: Bool, abiReady: Bool, smokeDurationMs: UInt32?) {
        let smokeMode = smokeDurationMs != nil
        let duration = smokeDurationMs ?? 0
        let terminalSurface = latestFrameSummary.terminal_surface != 0
        let framePrepared = latestFrameSummary.frame_prepared != 0
        let frameConsistent = latestFrameSummary.frame_consistent != 0
        let glyphUvReady = latestFrameSummary.glyph_uv_ready != 0
        let glyphRasterReady = latestFrameSummary.glyph_raster_ready != 0
        let frameEnded = latestFrameSummary.ended != 0
        let summary = """
        maru.macos-app-dev.v1
        visible_ui=\(visibleUI)
        swift_host=true
        abi_ready=\(abiReady)
        placeholder_window=true
        terminal_surface=\(terminalSurface)
        terminal_surface_note=zig_runtime_attached_placeholder_view_no_metal_surface
        dev_session_status=\(devSessionStatus)
        frame_loop_ticks=\(latestFrameSummary.frame_loop_ticks)
        frame_loop_last_tick_index=\(latestFrameSummary.last_tick_index)
        output_events=\(latestFrameSummary.output_events)
        exit_events=\(latestFrameSummary.exit_events)
        process_state=\(latestFrameSummary.process_state)
        frame_prepared=\(framePrepared)
        frame_consistent=\(frameConsistent)
        glyph_uv_ready=\(glyphUvReady)
        glyph_raster_ready=\(glyphRasterReady)
        glyph_count=\(latestFrameSummary.glyph_count)
        draw_cells=\(latestFrameSummary.draw_cells)
        atlas_entries=\(latestFrameSummary.atlas_entries)
        surface_cols=\(latestFrameSummary.cols)
        surface_rows=\(latestFrameSummary.rows)
        final_frame_ended=\(frameEnded)
        smoke_mode=\(smokeMode)
        smoke_duration_ms=\(duration)

        """

        do {
            try FileManager.default.createDirectory(atPath: artifactDirectory, withIntermediateDirectories: true)
            try summary.write(toFile: summaryPath, atomically: true, encoding: .utf8)
            print(summary, terminator: "")
            print("artifacts written to \(artifactDirectory)/")
        } catch {
            exitCode = 1
            fputs("failed to write \(summaryPath): \(error)\n", stderr)
        }
    }
}
