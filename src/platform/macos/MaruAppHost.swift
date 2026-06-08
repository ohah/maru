import AppKit
import Darwin
import Foundation

@main
@MainActor
final class MaruAppHostController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retainedDelegate: MaruAppHostController?

    private let artifactDirectory = "zig-out/maru-macos-app-dev"
    private let summaryPath = "zig-out/maru-macos-app-dev/app-dev.summary.txt"
    private var capabilities = MaruAppHostCapabilities()
    private var window: NSWindow?
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

        writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)

        if let smokeDuration {
            Timer.scheduledTimer(withTimeInterval: Double(smokeDuration) / 1000.0, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
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
        return status == MaruAppHostStatusOk.rawValue &&
            capabilities.abi_version == MARU_MACOS_APP_HOST_ABI_VERSION &&
            capabilities.swift_owns_ns_application == 1 &&
            capabilities.zig_owns_frame_loop == 1
    }

    private func makePlaceholderWindow() -> NSWindow {
        // 아직 terminal surface는 붙이지 않는다. 제품 NSApplication/window lifecycle만 먼저
        // 실제 executable로 검증해, 다음 PR에서 PTY/render loop 실패와 Swift launch 실패를
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
        let summary = """
        maru.macos-app-dev.v1
        visible_ui=\(visibleUI)
        swift_host=true
        abi_ready=\(abiReady)
        placeholder_window=true
        terminal_surface=false
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
