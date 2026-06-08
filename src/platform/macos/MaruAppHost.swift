import AppKit
import Darwin
import Foundation
import Metal
import QuartzCore

@MainActor
final class MaruMetalTerminalView: NSView {
    weak var controller: MaruAppHostController?

    override var acceptsFirstResponder: Bool {
        return true
    }

    // CAMetalLayer를 backing layer로 쓴다. Zig dev session이 만든 RenderFrame을 제품 Metal
    // renderer가 이 layer의 drawable에 그린다.
    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        return metalLayer
    }

    var metalLayer: CAMetalLayer? {
        return layer as? CAMetalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    // drawableSize는 point가 아니라 backing pixel이어야 nextDrawable이 올바른 크기를 준다.
    func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0
        let width = max(1.0, bounds.width * scale)
        let height = max(1.0, bounds.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: width, height: height)
    }

    override func keyDown(with event: NSEvent) {
        controller?.handleKeyDown(event)
    }
}

@main
@MainActor
final class MaruAppHostController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retainedDelegate: MaruAppHostController?
    private static let statusOK = Int32(MaruAppHostStatusOk.rawValue)
    // PTY 셸이 정상 종료했다는 신호. fault가 아니라 우아한 종료 대상이다.
    private static let statusSessionEnded = Int32(MaruAppHostStatusSessionEnded.rawValue)

    private let artifactDirectory = "zig-out/maru-macos-app-dev"
    private let summaryPath = "zig-out/maru-macos-app-dev/app-dev.summary.txt"
    private let placeholderCellWidthPx: CGFloat = 12
    private let placeholderCellHeightPx: CGFloat = 24
    private var capabilities = MaruAppHostCapabilities()
    private var window: NSWindow?
    private var devSession: OpaquePointer?
    private var tickTimer: Timer?
    // smoke 자동 종료용 one-shot timer. 창이 먼저 닫혀도 run loop에 남아 teardown 뒤
    // NSApp.terminate를 다시 부르지 않도록 저장해 두고 종료 시 invalidate한다.
    private var smokeTimer: Timer?
    private var latestFrameSummary = MaruAppHostDevFrameSummary()
    private var devSessionStatus = MaruAppHostController.statusOK
    private var smokeMode = false
    private var exitCode: Int32 = 0
    // 제품 Metal renderer(maru_metal_renderer.h). dev session의 metal-frame DTO를 창의
    // CAMetalLayer에 그린다. generation이 바뀐 frame에서만 atlas 갱신/draw한다.
    private var metalRenderer: OpaquePointer?
    private var lastDrawnGeneration: UInt64 = 0
    private var metalFramesDrawn = 0
    // create 성공 여부를 영구 기록한다. metalRenderer는 shutdown에서 nil이 되므로 summary가
    // 종료 후 쓰일 때 "생성됐었다"를 잃지 않게 별도 플래그로 둔다.
    private var metalRendererCreated = false

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
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)

        // dev session의 첫 tick(startDevSession 안)이 바로 그릴 수 있도록 renderer를 먼저 만든다.
        setupMetalRenderer()

        if !startDevSession(smokeMode: smokeMode) {
            writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }

        startFrameLoopTicks()
        if smokeMode {
            sendSmokeDevEvents()
        }

        if let smokeDuration {
            smokeTimer = Timer.scheduledTimer(withTimeInterval: Double(smokeDuration) / 1000.0, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        tickTimer?.invalidate()
        tickTimer = nil
        smokeTimer?.invalidate()
        smokeTimer = nil
        // 종료 중에는 추가 tick을 돌리지 않는다. tick은 session_ended에서 NSApp.terminate를
        // 부르므로, 여기서 다시 tick하면 재진입 terminate가 된다. 마지막 counter는
        // shutdownDevSession의 close()가 summary에 담는다.
        shutdownDevSession()
        writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return true
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        shutdownDevSession()
        writeSummary(visibleUI: true, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        resizeDevSessionFromWindow()
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

        let content = MaruMetalTerminalView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 600))
        content.controller = self
        // wantsLayer를 켜면 NSView가 makeBackingLayer()로 만든 CAMetalLayer를 backing layer로 쓴다.
        content.wantsLayer = true
        window.contentView = content

        return window
    }

    private var metalTerminalView: MaruMetalTerminalView? {
        return window?.contentView as? MaruMetalTerminalView
    }

    private func setupMetalRenderer() {
        guard let view = metalTerminalView, let metalLayer = view.metalLayer, let device = metalLayer.device else {
            return
        }
        view.updateDrawableSize()
        metalRenderer = maru_metal_renderer_create(device, metalLayer.pixelFormat)
        metalRendererCreated = metalRenderer != nil
    }

    // dev session이 노출한 최신 Metal frame을 창의 CAMetalLayer에 그린다. generation이 바뀐
    // frame(새 output/resize)에서만 atlas를 갱신하고 다시 그린다. idle tick은 마지막으로
    // present한 frame을 그대로 둔다.
    private func drawMetalFrame() {
        guard let devSession, let renderer = metalRenderer,
              let view = metalTerminalView, let metalLayer = view.metalLayer else {
            return
        }
        var frame = MaruAppHostDevMetalFrame()
        guard maru_macos_app_dev_session_metal_frame(devSession, &frame) == Self.statusOK else {
            return
        }
        if frame.generation == lastDrawnGeneration {
            return
        }
        // atlas slot은 누적된다. 같은 크기면 새 glyph delta만 올리고, 크기가 바뀌면 renderer가
        // texture를 새로 만든다.
        _ = maru_metal_renderer_set_atlas(
            renderer,
            frame.atlas_width_px,
            frame.atlas_height_px,
            frame.raster_uploads,
            frame.raster_upload_count,
            frame.raster_pixels,
            frame.raster_pixel_count
        )
        let drew = maru_metal_renderer_draw(
            renderer,
            metalLayer,
            UInt16(truncatingIfNeeded: frame.cols),
            UInt16(truncatingIfNeeded: frame.rows),
            frame.cells,
            frame.cell_count
        )
        if drew {
            lastDrawnGeneration = frame.generation
            metalFramesDrawn += 1
        }
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
            // Timer 콜백은 이 timer를 스케줄한 main run loop(main thread)에서 실행되고 이
            // controller는 @MainActor다. Task로 감싸면 매 tick(30/sec)마다 async hop과 할당이
            // 생기고 key/resize 동기 ABI 호출과 순서가 흔들린다. main에서 바로 호출한다.
            MainActor.assumeIsolated {
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
            drawMetalFrame()
            if summary.frame_loop_ticks <= 1 {
                writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            }
        } else if status == Self.statusSessionEnded {
            // PTY 셸이 정상 종료했다. fault가 아니므로 죽은 세션을 무한 tick하지 않고 frame loop를
            // 멈춘 뒤 마지막 summary를 남기고 우아하게(exitCode 0) 내려간다.
            latestFrameSummary = summary
            tickTimer?.invalidate()
            tickTimer = nil
            smokeTimer?.invalidate()
            smokeTimer = nil
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            NSApp.terminate(nil)
        } else {
            // tick_failed 등 세션 자체 fault만 비정상 종료로 처리한다.
            exitCode = 1
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            NSApp.terminate(nil)
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        guard let keyEvent = normalizedKeyEvent(from: event) else {
            return
        }
        sendKeyEvent(keyEvent)
    }

    private func sendSmokeDevEvents() {
        // 자동 smoke는 물리 키보드나 사용자의 resize 동작을 기다릴 수 없다. 대신 같은 C ABI를
        // 직접 호출해 key/resize event가 Zig dev session까지 내려가는 최소 E2E 신호를 남긴다.
        resizeDevSession(cols: 100, rows: 30, widthPx: 1_200, heightPx: 720)
        let keyEvent = MaruAppHostKeyEvent(
            codepoint: UInt32(UnicodeScalar("a").value),
            key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
            modifier_shift: 0,
            modifier_control: 0,
            modifier_option: 0,
            modifier_command: 0,
            is_repeat: 0,
            reserved: 0
        )
        sendKeyEvent(keyEvent)
        let enterEvent = MaruAppHostKeyEvent(
            codepoint: 0,
            key_code: UInt32(MaruAppHostKeyCodeEnter.rawValue),
            modifier_shift: 0,
            modifier_control: 0,
            modifier_option: 0,
            modifier_command: 0,
            is_repeat: 0,
            reserved: 0
        )
        sendKeyEvent(enterEvent)
    }

    private func sendKeyEvent(_ event: MaruAppHostKeyEvent) {
        guard let devSession else {
            return
        }

        var keyEvent = event
        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_key_down(devSession, &keyEvent, &summary)
        devSessionStatus = status
        // 한 key event의 실패(닫힌 pane의 late input, 변환 거부 등)는 세션 fault가 아니다.
        // 앱을 죽이지 않고 status만 기록한다. 종료 자체는 tick 경로의 session_ended가 처리한다.
        if status == Self.statusOK {
            latestFrameSummary = summary
        }
    }

    private func resizeDevSessionFromWindow() {
        guard let window, let contentView = window.contentView else {
            return
        }

        let bounds = contentView.bounds
        // placeholder 단계에는 CoreText font metrics가 아직 Swift view에 없다. 그래서 실제 제품
        // cell 계산이 아니라 dev smoke용 추정 cell size로 resize ABI 경로만 검증한다.
        let cols = max(UInt32(1), clampedUInt32(floor(bounds.width / placeholderCellWidthPx)))
        let rows = max(UInt32(1), clampedUInt32(floor(bounds.height / placeholderCellHeightPx)))
        resizeDevSession(
            cols: cols,
            rows: rows,
            widthPx: clampedUInt32(bounds.width),
            heightPx: clampedUInt32(bounds.height)
        )
    }

    private func resizeDevSession(cols: UInt32, rows: UInt32, widthPx: UInt32, heightPx: UInt32) {
        guard let devSession else {
            return
        }

        var event = MaruAppHostResizeEvent(
            width_px: widthPx,
            height_px: heightPx,
            scale_milli: clampedUInt32((window?.backingScaleFactor ?? 1.0) * 1_000),
            cols: cols,
            rows: rows,
            reserved: 0
        )
        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_resize(devSession, &event, &summary)
        devSessionStatus = status
        // 한 resize event의 실패(닫히는 창의 late resize 등)도 세션 fault가 아니므로 앱을
        // 죽이지 않고 status만 기록한다.
        if status == Self.statusOK {
            latestFrameSummary = summary
        }
    }

    private func normalizedKeyEvent(from event: NSEvent) -> MaruAppHostKeyEvent? {
        var codepoint: UInt32 = 0
        var keyCode = UInt32(MaruAppHostKeyCodeUnknown.rawValue)

        switch event.keyCode {
        case 36:
            keyCode = UInt32(MaruAppHostKeyCodeEnter.rawValue)
        case 53:
            keyCode = UInt32(MaruAppHostKeyCodeEscape.rawValue)
        case 48:
            keyCode = UInt32(MaruAppHostKeyCodeTab.rawValue)
        case 51:
            keyCode = UInt32(MaruAppHostKeyCodeBackspace.rawValue)
        case 126:
            keyCode = UInt32(MaruAppHostKeyCodeArrowUp.rawValue)
        case 125:
            keyCode = UInt32(MaruAppHostKeyCodeArrowDown.rawValue)
        case 123:
            keyCode = UInt32(MaruAppHostKeyCodeArrowLeft.rawValue)
        case 124:
            keyCode = UInt32(MaruAppHostKeyCodeArrowRight.rawValue)
        default:
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
                return nil
            }
            codepoint = scalar.value
        }

        let flags = event.modifierFlags
        return MaruAppHostKeyEvent(
            codepoint: codepoint,
            key_code: keyCode,
            modifier_shift: flags.contains(.shift) ? 1 : 0,
            modifier_control: flags.contains(.control) ? 1 : 0,
            modifier_option: flags.contains(.option) ? 1 : 0,
            modifier_command: flags.contains(.command) ? 1 : 0,
            is_repeat: event.isARepeat ? 1 : 0,
            reserved: 0
        )
    }

    private func clampedUInt32(_ value: CGFloat) -> UInt32 {
        if !value.isFinite || value <= 0 {
            return 0
        }
        return UInt32(min(value, CGFloat(UInt32.max)))
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

        if let renderer = metalRenderer {
            maru_metal_renderer_destroy(renderer)
            metalRenderer = nil
        }
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
        terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer
        metal_renderer_created=\(metalRendererCreated)
        metal_frames_drawn=\(metalFramesDrawn)
        dev_session_status=\(devSessionStatus)
        frame_loop_ticks=\(latestFrameSummary.frame_loop_ticks)
        frame_loop_last_tick_index=\(latestFrameSummary.last_tick_index)
        output_events=\(latestFrameSummary.output_events)
        exit_events=\(latestFrameSummary.exit_events)
        key_events=\(latestFrameSummary.key_events)
        terminal_input_events=\(latestFrameSummary.terminal_input_events)
        terminal_input_bytes=\(latestFrameSummary.terminal_input_bytes)
        app_key_events=\(latestFrameSummary.app_key_events)
        ignored_key_events=\(latestFrameSummary.ignored_key_events)
        resize_events=\(latestFrameSummary.resize_events)
        close_events=\(latestFrameSummary.close_events)
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
