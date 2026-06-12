import AppKit
import Darwin
import Foundation
import Metal
import QuartzCore

@MainActor
final class MaruMetalTerminalView: NSView, @preconcurrency NSTextInputClient {
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
        updateTrackingAreas()
    }

    // Cmd+hover URL 하이라이트용 mouseMoved 추적. 보이는 영역 전체를 따라가게 inVisibleRect로 둔다.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.handleHover(event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.clearHover()
    }

    // Cmd 키를 누르거나 떼는 순간에도 (마우스를 안 움직여도) hover 상태를 재평가한다. 키 이벤트라
    // locationInWindow가 무효이므로 controller가 창의 현재 포인터 위치를 쓴다.
    override func flagsChanged(with event: NSEvent) {
        controller?.handleModifierHover(event, in: self)
        super.flagsChanged(with: event)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        // backing scale이 바뀌면 dev session에 새 scale로 resize를 다시 보내, glyph가 device
        // 해상도로 rasterize되고 cell 메트릭이 갱신되게 한다(런치 후 Retina 정착 등).
        controller?.handleBackingScaleChange()
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
        let newSize = CGSize(width: width, height: height)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
            // drawable이 새 크기로 재할당됐으니 generation이 그대로여도 다시 그려야 한다.
            controller?.markMetalNeedsRedraw()
        }
    }

    // 조합 중(marked) 텍스트 — NSTextInputClient 프로토콜 응답(hasMarkedText/markedRange)용.
    // 표시·판정 상태의 단일 출처는 Zig(core.preedit + IME 트랜잭션)다.
    private var markedTextBuffer: String = ""

    // IME 콜백 진단 트레이스(MARU_IME_DEBUG=1). 입력기가 실제로 보내는 콜백 순서/인자를
    // 그대로 찍어, 한글 조합/삭제의 실측 시퀀스로 버그를 잡는다(추측 금지).
    private static let imeDebug = ProcessInfo.processInfo.environment["MARU_IME_DEBUG"] != nil
    private func imeLog(_ label: String, _ text: String? = nil, keyCode: UInt16? = nil) {
        guard Self.imeDebug else { return }
        var line = "[IME] \(label)"
        if let text {
            let hex = text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            line += " text=\"\(text)\" [\(hex)] len=\(text.utf16.count)"
        }
        if let keyCode { line += " keyCode=\(keyCode)" }
        fputs(line + "\n", stderr)
    }

    // IME(텍스트 합성)를 거치지 않고 바로 인코딩 경로로 보낼 특수 키의 물리 키코드(kVK_*). 화살표
    // (123~126)는 일부러 제외 — 한글 확정 후 커서 이동 replay가 IME 트랜잭션 경로에서 일어난다.
    private static let directEncodeKeyCodes: Set<UInt16> = [
        115, 119, 116, 121, 117, 114, // Home, End, PageUp, PageDown, ForwardDelete, Help(Insert)
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1~F12
    ]

    override func keyDown(with event: NSEvent) {
        let m = event.modifierFlags
        let mods = "\(m.contains(.command) ? "Cmd " : "")\(m.contains(.control) ? "Ctrl " : "")\(m.contains(.option) ? "Opt " : "")\(m.contains(.shift) ? "Shift " : "")"
        imeLog("keyDown mods=[\(mods)]", event.characters, keyCode: event.keyCode)
        // Control+Command+Space(이모지 & 기호 피커)는 시스템 character palette를 연다. 우리가
        // Ctrl/Cmd 조합을 전부 가로채면 이 피커가 안 떠서 명시적으로 처리한다(keyCode 49 = Space).
        // 피커에서 고른 이모지는 입력기의 insertText로 들어와 PTY로 전송된다.
        let exactChord = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if exactChord == [.command, .control], event.keyCode == 49 {
            NSApp.orderFrontCharacterPalette(self)
            return
        }
        // Ctrl/Cmd/Option 조합은 입력기에 보내지 않고 바로 단축키/인코딩 경로로 — 한글 입력
        // 모드에서도 Ctrl+B(tmux prefix)나 Cmd+C가 동작하고(레이아웃 독립 매칭은 Zig가 물리
        // 키코드로 한다), Option+글자는 특수문자 입력이 아니라 기존 meta-ESC 인코딩을 유지한다.
        let chord = event.modifierFlags.intersection([.command, .control, .option])
        if !chord.isEmpty {
            controller?.handleKeyDown(event)
            return
        }
        // 특수 비-텍스트 키(편집/네비/기능: Home/End/PageUp/PageDown/ForwardDelete/Insert/F1~F12)는
        // IME 텍스트가 아니다 — interpretKeyEvents→doCommand→ime_end 경로에 맡기면 안정적으로
        // 인코딩되지 않는다(편집/스크롤 selector라 입력기가 텍스트로 안 만든다). 바로 인코딩/단축키
        // 경로(handleKeyDown)로 보낸다. handleKeyDown이 Shift+PageUp/Down 스크롤백과 plain 키
        // 인코딩(sendKeyEvent → ABI → encodeKey)을 가른다. 화살표는 제외한다 — 한글 확정 후 커서
        // 이동 replay(ime_end의 shouldReplayAfterCommit)가 화살표를 IME 트랜잭션에서 받아야 한다.
        if Self.directEncodeKeyCodes.contains(event.keyCode) {
            controller?.handleKeyDown(event)
            return
        }
        // 그 외(일반 타이핑·Shift)는 입력기(IME)를 거친다 — 한글 조합이 여기서 일어난다.
        // 판정(확정 전송/조합 조작 무시/일반 키 인코딩)은 전부 Zig의 IME 트랜잭션이 한다:
        // begin -> interpretKeyEvents(입력기 콜백이 insert/marked로 쌓음) -> end(일괄 판정).
        // Swift에는 IME 분기 로직이 없다 — 입력기의 비동기/다중 콜백에서도 이중 전송이
        // 구조적으로 불가능하고, 판정 규칙은 Zig unit으로 고정된다.
        controller?.imeKeyTransaction(event) {
            self.interpretKeyEvents([event])
        }
    }

    // 입력기가 텍스트로 만들지 않은 키의 편집 명령. 여기서 아무것도 하지 않는다(시스템 비프
    // 방지용 오버라이드만) — 그 키의 전송 여부는 Zig의 ime_end가 일괄 판정한다(확정 텍스트가
    // 없고 조합 변화도 없으면 일반 키로 인코딩).
    override func doCommand(by selector: Selector) {
        imeLog("doCommand:\(NSStringFromSelector(selector))")
        // deleteBackward는 Zig 트랜잭션에 기록한다 — 한글 마지막 자모 백스페이스에서 입력기가
        // insertText(조합 글자) + deleteBackward를 함께 보내면 둘이 상쇄돼야 한다(글자가 PTY에
        // 박히지 않게). 그 외 편집 명령(insertNewline 등)은 ime_end가 일반 키로 인코딩한다.
        if selector == #selector(NSStandardKeyBindingResponding.deleteBackward(_:)) {
            controller?.imeDeleteBackward()
        }
    }

    // ── NSTextInputClient — 입력기(IME) 통합. 조합 의미론은 macOS 입력기가, 확정 텍스트의
    // 인코딩/전달은 Zig가 소유한다(여기는 이벤트 캡처와 전달만).

    // 입력기가 텍스트를 확정했다(한글 음절, 영문 일반 타이핑 모두 여기로 온다).
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedTextBuffer = ""
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        imeLog("insertText", text)
        controller?.imeMarked("") // 조합 표시 제거(전송 판정은 Zig ime_end가)
        controller?.imeInsert(text)
    }

    // 조합 중 텍스트(예: 'ㅇ' -> '아' -> '안'). 표시는 Zig가 커서 위치에 합성한다.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedTextBuffer = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        imeLog("setMarkedText", markedTextBuffer)
        controller?.imeMarked(markedTextBuffer)
    }

    func unmarkText() {
        imeLog("unmarkText")
        markedTextBuffer = ""
        controller?.imeMarked("")
    }

    // 포커스 변화는 Zig에 전달만 한다 — 조합 중 텍스트의 확정(커밋)은 Zig setFocused가 소유
    // (Terminal.app/Ghostty 의미론, unit 검증). 여기선 입력기 세션 정리만(재포커스 후 입력기
    // 상태와 화면이 어긋나지 않게).
    func commitComposition() {
        markedTextBuffer = ""
        controller?.imeFocus(false)
        inputContext?.discardMarkedText()
    }

    override func resignFirstResponder() -> Bool {
        commitComposition()
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        controller?.imeFocus(true)
        return super.becomeFirstResponder()
    }

    // 앱/창 전환은 view의 resignFirstResponder를 부르지 않는다 — window key 상실 알림에서도
    // 같은 커밋을 해야 조합 상태가 입력기와 어긋난 채 남지 않는다.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let old = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowLostKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
        }
    }

    @objc private func windowLostKey(_ note: Notification) {
        commitComposition()
    }

    func hasMarkedText() -> Bool {
        return !markedTextBuffer.isEmpty
    }

    // NSNotFound가 아니라 빈 NSRange를 돌려준다(Ghostty와 동일). NSNotFound를 주면 입력기가
    // "이 클라이언트는 marked 교체를 지원하지 않는다"로 보고 보수적으로 동작해 — 한국어 조합의
    // 마지막 자모에서 Backspace가 자모 삭제 대신 확정(insertText)으로 처리돼 삭제에 키가 한 번
    // 더 들었다(라이브: 가ㄴ -> BS -> 가ㄴ -> BS -> 가).
    func markedRange() -> NSRange {
        return markedTextBuffer.isEmpty
            ? NSRange()
            : NSRange(location: 0, length: markedTextBuffer.utf16.count)
    }

    func selectedRange() -> NSRange {
        return NSRange()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    // 입력기 후보창 위치. 아직 커서 셀 좌표를 노출하지 않아 view 좌하단 기준으로 둔다(후보창이
    // 창 근처에 뜨는 정도 — 커서 위치 정밀 배치는 preedit 렌더와 함께 다음 단계).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        // Zig가 커서 셀 사각형을 backing px(좌상단 원점)로 준다. view points(y-flip) -> window
        // -> screen으로 변환해 입력기 후보창이 커서 위치에 뜨게 한다.
        guard let (x, y, w, h) = controller?.imeCursorRectPx() else {
            return window.convertToScreen(convert(NSRect(x: 0, y: 0, width: 1, height: 16), to: nil))
        }
        let scale = window.backingScaleFactor
        let viewW = w / scale
        let viewH = h / scale
        // backing px의 y는 위에서 아래로(좌상단 원점). view 좌표는 아래에서 위로 증가하므로
        // 셀 하단(y+h)을 기준으로 뒤집어 후보창이 글자 아래에 뜨게 한다.
        let local = NSRect(
            x: x / scale,
            y: bounds.height - (y / scale) - viewH,
            width: viewW,
            height: viewH
        )
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.handleScroll(event)
    }

    // 마우스 선택: raw 좌표만 backing 픽셀(좌상단 원점)로 바꿔 Zig에 넘긴다 — 셀 변환·선택 모델은
    // Zig가 소유한다(네이티브 최소화). NSView 좌표는 좌하단 원점이라 y를 뒤집는다.
    override func mouseDown(with event: NSEvent) {
        // Cmd+클릭 = 그 위치의 URL 열기(선택하지 않음). URL 인식은 Zig가 한다.
        if event.modifierFlags.contains(.command) {
            controller?.handleCommandClick(event, in: self)
            return
        }
        // 더블클릭=단어 선택(4), 트리플클릭=논리 줄 선택(5). 선택 의미론은 Zig가 소유한다.
        let kind: Int32 = event.clickCount >= 3 ? 5 : (event.clickCount == 2 ? 4 : 1)
        controller?.handleMouse(event, kind: kind, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.handleMouse(event, kind: 2, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.handleMouse(event, kind: 3, in: self)
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
    // surface(drawableSize/backing-scale) 변경 시 generation이 그대로여도 다시 그려야 한다.
    private var metalNeedsRedraw = false
    // tick summary가 알려주는 metal generation(u32). 이 값이 그대로면 metalFrame() ABI 호출과
    // draw를 idle tick에서 건너뛴다.
    private var lastSeenMetalGeneration: UInt32 = 0
    // renderer가 알려준 cell 픽셀 크기. resize가 같은 메트릭으로 cols/rows를 계산하도록 캐시한다.
    private var lastCellWidthPx: UInt32 = 0
    private var lastCellHeightPx: UInt32 = 0
    // dev session에 마지막으로 보낸 backing scale. 런치 후 backingScaleFactor가 늦게 Retina로
    // 정착하면(콜백이 dev session 생성 전에 발화한 경우) tick이 변화를 감지해 재-resize한다.
    // (같은 size+scale 중복 resize 방지는 Zig dev session이 담당한다.)
    private var lastSentBackingScale: CGFloat = 0
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

        // 첫 tick(startDevSession 안)이 cell 메트릭을 캐시했으니, 창 크기에 맞춰 cols/rows를
        // 한 번 맞춘다(80×24 기본에서 실제 창 grid로). smoke는 자체 scripted resize를 쓴다.
        if !smokeMode {
            resizeDevSessionFromWindow()
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
        // drawableSize를 창에 맞춰 즉시 갱신한다(setFrameSize 경로에만 의존하지 않는다). 이게
        // 늦으면 CAMetalLayer가 옛 크기 drawable을 새 창에 스케일해 글자가 늘어나 보인다.
        metalTerminalView?.updateDrawableSize()
        // 라이브 드래그 중에는 grid resize(+PTY SIGWINCH)를 보류한다. 매 단계 SIGWINCH를 보내면
        // zsh는 상대 커서 이동(\e[A)으로 redraw하는데 reflow를 한 박자씩 못 따라와, 명령이 여러 줄로
        // 늘어나는 좁은 폭에서 프롬프트가 중복된다. 드래그가 끝나면(windowDidEndLiveResize) 최종
        // 크기로 한 번만 resize해 zsh가 한 번 redraw하게 한다(단일 resize는 reflow가 Ghostty와 일치).
        // 비-라이브(프로그램/스모크) resize는 즉시 적용한다.
        if metalTerminalView?.inLiveResize == true { return }
        resizeDevSessionFromWindow()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        _ = notification
        metalTerminalView?.updateDrawableSize()
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
        // 새 frame(generation 변경)일 때뿐 아니라, drawableSize/backing-scale 변경 등 surface가
        // 무효화돼 다시 칠해야 할 때(metalNeedsRedraw)도 그린다. generation만 보면 한가한 셸이
        // 리사이즈/디스플레이 전환 후 stale/blank로 남는다.
        let newFrame = frame.generation != lastDrawnGeneration
        if !newFrame && !metalNeedsRedraw {
            return
        }
        // atlas slot은 누적된다(같은 크기면 새 glyph delta만 올린다). 새 generation일 때만
        // 업로드하면 되고, surface-only 재칠은 기존 atlas를 그대로 쓴다.
        if newFrame {
            _ = maru_metal_renderer_set_atlas(
                renderer,
                frame.atlas_width_px,
                frame.atlas_height_px,
                frame.raster_uploads,
                frame.raster_upload_count,
                frame.raster_pixels,
                frame.raster_pixel_count
            )
        }
        // cols/rows는 u32이지만 grid 좌표(cell.col/row)는 u16이다. 비현실적으로 큰 값은
        // truncate-wrap(0이 되면 draw가 거부됨) 대신 u16 상한으로 클램프한다.
        let cols = UInt16(min(frame.cols, UInt32(UInt16.max)))
        let rows = UInt16(min(frame.rows, UInt32(UInt16.max)))
        // 제목줄 진단(MARU_DEBUG)에 쓰도록 cell 픽셀 크기를 기록한다. grid 계산은 Zig dev
        // session이 하므로 Swift는 이 값을 resize에 쓰지 않는다(진단 표시 전용).
        if frame.cell_width_px > 0 { lastCellWidthPx = frame.cell_width_px }
        if frame.cell_height_px > 0 { lastCellHeightPx = frame.cell_height_px }
        let drew = maru_metal_renderer_draw(
            renderer,
            metalLayer,
            cols,
            rows,
            frame.cell_width_px,
            frame.cell_height_px,
            frame.cells,
            frame.cell_count
        )
        if drew {
            lastDrawnGeneration = frame.generation
            metalNeedsRedraw = false
            metalFramesDrawn += 1
        }
    }

    // view가 drawableSize/backing-scale 변경을 알리면, 다음 tick이 generation 변화가 없어도
    // 현재 frame을 새 surface에 다시 그리게 표시한다.
    func markMetalNeedsRedraw() {
        metalNeedsRedraw = true
    }

    // backing scale(Retina) 변경 시 dev session에 resize를 다시 보낸다. 그래야 dev session이
    // 새 scale로 glyph를 rasterize하고 cell 메트릭을 device 해상도에 맞춘다. 런치 시점에
    // backingScaleFactor가 아직 1.0이고 창이 Retina로 정착하며 바뀌는 경우를 잡는다.
    func handleBackingScaleChange() {
        guard !smokeMode else { return }
        resizeDevSessionFromWindow()
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
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer 콜백은 main run loop(main thread)에서 실행되고 이 controller는 @MainActor다.
            // Task로 감싸면 매 tick(30/sec)마다 async hop과 할당이 생기므로 main에서 바로 호출한다.
            MainActor.assumeIsolated {
                self?.tickDevSession()
            }
        }
        // .common 모드로 등록해야 창 live-resize(.eventTracking) 중에도 tick이 멈추지 않는다.
        // 기본 scheduledTimer(.default)는 드래그 리사이즈 동안 발화하지 않아, 옛 drawable이
        // 새 창 크기로 스케일되며 글자가 늘어나 보인다.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARU_DEBUG=1일 때만 켜지는 진단. 렌더링/스케일 문제를 추적할 때 창 제목에 live
    // scale/cell/drawable 값을 띄운다(summary 파일·launch 방식과 무관하게 제목줄만 보면 됨).
    private let debugEnabled = ProcessInfo.processInfo.environment["MARU_DEBUG"] != nil

    private func updateDiagnosticTitle() {
        guard debugEnabled, let window else { return }
        let scr = NSScreen.main?.backingScaleFactor ?? -1
        let win = window.backingScaleFactor
        let drawW = Int(metalTerminalView?.metalLayer?.drawableSize.width ?? -1)
        window.title = "Maru  scr:\(scr) win:\(win) cell:\(lastCellWidthPx)x\(lastCellHeightPx) draw:\(drawW)"
    }

    private func tickDevSession() {
        guard let devSession else {
            return
        }
        updateDiagnosticTitle()

        // backing scale이 런치 후 늦게 정착/변경되면(콜백이 dev session 생성 전 발화한 경우 등)
        // dev session의 device_scale이 옛 값에 머문다. 변했을 때만 resize를 다시 보낸다(매 tick
        // float 비교 하나라 싸고, resize는 실제 변화 시에만 일어난다).
        if !smokeMode, let window {
            let scale = window.backingScaleFactor
            if scale != lastSentBackingScale {
                resizeDevSessionFromWindow()
            }
        }

        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_tick(devSession, &summary)
        devSessionStatus = status
        if status == Self.statusOK {
            latestFrameSummary = summary
            // metal frame이 바뀌었거나(generation) surface 재칠이 필요할 때만 그린다. idle tick은
            // metalFrame() ABI 호출 자체를 건너뛴다(tick이 준 summary의 metal_generation으로 판단).
            if summary.metal_generation != lastSeenMetalGeneration || metalNeedsRedraw {
                lastSeenMetalGeneration = summary.metal_generation
                drawMetalFrame()
            }
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
        // Cmd만 눌린 조합인지(Shift/Option/Control 동반 아님). 이렇게 정확히 봐야 Cmd+Shift+C 같은
        // 조합이 복사/붙여넣기로 삼켜지지 않고 키 인코더(향후 별도 바인딩)로 흘러간다.
        // 키 비교는 글자가 아니라 물리 키코드다(kVK_ANSI_C=8, V=9) — 한글 입력 모드('ㅊ'/'ㅍ')
        // 에서도 Cmd+C/V가 동작한다(레이아웃 독립 단축키 정책).
        let chordMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Cmd+C는 선택 텍스트 복사(클립보드는 OS 소유라 여기서 처리). 선택 추출은 Zig가 한다.
        if chordMods == .command, event.keyCode == 8 {
            copySelectionToPasteboard()
            return
        }
        // Cmd+V: NSPasteboard의 텍스트를 Zig에 넘긴다 — 개행 정규화·bracketed paste 감싸기는
        // Zig가 한다(클립보드 읽기만 OS 소유).
        if chordMods == .command, event.keyCode == 9 {
            pastePasteboardText()
            return
        }
        // Shift+PageUp/Down는 PTY로 보내지 않고 스크롤백 뷰포트를 한 화면씩 스크롤한다. page 크기
        // (rows-1) 계산은 권위 있는 rows를 가진 Zig가 하고, 여기선 방향(위 +1 / 아래 -1)만 넘긴다.
        if event.modifierFlags.contains(.shift), let session = devSession {
            if event.keyCode == 116 { // PageUp -> 과거(위)
                _ = maru_macos_app_dev_session_scroll_page(session, 1)
                markMetalNeedsRedraw()
                return
            }
            if event.keyCode == 121 { // PageDown -> 현재(아래)
                _ = maru_macos_app_dev_session_scroll_page(session, -1)
                markMetalNeedsRedraw()
                return
            }
        }
        // Cmd+↑/↓: OSC 133 프롬프트 블록으로 점프(이전/다음 명령의 프롬프트로 뷰포트 이동). 분류·이동은
        // Zig core가 하고 여기선 방향만 넘긴다. 셸 통합이 없으면 core가 false라 아무 일도 안 일어난다.
        if chordMods == .command, let session = devSession {
            if event.keyCode == 126 { // Up -> 이전(과거) 프롬프트
                _ = maru_macos_app_dev_session_jump_prompt(session, -1)
                markMetalNeedsRedraw()
                return
            }
            if event.keyCode == 125 { // Down -> 다음(최근) 프롬프트
                _ = maru_macos_app_dev_session_jump_prompt(session, 1)
                markMetalNeedsRedraw()
                return
            }
        }
        guard let keyEvent = normalizedKeyEvent(from: event) else {
            return
        }
        sendKeyEvent(keyEvent)
    }

    // 마우스 휠/트랙패드 스크롤 -> 뷰포트 스크롤. raw NSEvent 값(델타 포인트 + 정밀 델타 여부)만
    // 넘기고, 줄 수 환산(셀 높이·clamp·NaN 가드)은 Zig가 실제 메트릭으로 한다(네이티브 최소화).
    // scrollingDeltaY>0이면 위(과거)로 본다 — 표준 터미널 방향.
    func handleScroll(_ event: NSEvent) {
        guard let session = devSession else { return }
        _ = maru_macos_app_dev_session_scroll_wheel(
            session,
            Double(event.scrollingDeltaY),
            event.hasPreciseScrollingDeltas ? 1 : 0
        )
        markMetalNeedsRedraw()
    }

    // 마우스 좌표를 backing 픽셀(좌상단 원점)로 환산해 Zig 선택 모델에 넘긴다(kind 1=down/2=drag/3=up).
    func handleMouse(_ event: NSEvent, kind: Int32, in view: NSView) {
        guard let session = devSession else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale) // NSView는 좌하단 원점 — 위가 0이 되게 뒤집는다
        _ = maru_macos_app_dev_session_mouse(session, kind, xPx, yPx)
        markMetalNeedsRedraw()
    }

    // Cmd+C: Zig가 추출한 선택 텍스트(UTF-8, Zig 소유 버퍼)를 NSPasteboard에 쓴다 — 클립보드는
    // OS API라 Swift가 소유하는 경계다. 선택이 없으면 아무것도 하지 않는다(셸에 ^C를 보내지 않는
    // 것은 macOS 터미널 관례와 동일 — 인터럽트는 Ctrl+C).
    // Cmd+hover: Zig가 URL 여부를 판정(+밑줄 투영)하고, 여기선 마우스 커서만 바꾼다.
    // mouseMoved는 event.locationInWindow가 유효하므로 그대로 쓴다.
    func handleHover(_ event: NSEvent, in view: NSView) {
        updateHover(atWindowPoint: event.locationInWindow, cmdHeld: event.modifierFlags.contains(.command), in: view)
    }

    // Cmd 키를 누르거나 떼는 순간의 재평가. flagsChanged(키 이벤트)의 locationInWindow는 정의되지
    // 않으므로 쓰지 않고, 창의 현재 포인터 위치(mouseLocationOutsideOfEventStream)를 권위 있는
    // 좌표로 쓴다.
    func handleModifierHover(_ event: NSEvent, in view: NSView) {
        guard let point = view.window?.mouseLocationOutsideOfEventStream else { return }
        updateHover(atWindowPoint: point, cmdHeld: event.modifierFlags.contains(.command), in: view)
    }

    private func updateHover(atWindowPoint windowPoint: NSPoint, cmdHeld: Bool, in view: NSView) {
        guard let session = devSession else { return }
        let local = view.convert(windowPoint, from: nil)
        // 포인터가 view 밖(타이틀바·다른 뷰 위)이면 hover를 강제하지 않는다 — 시스템/이웃 커서를
        // iBeam으로 덮어쓰지 않게. 밑줄도 해제한다.
        guard view.bounds.contains(local) else {
            clearHover()
            return
        }
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        var isUrl: Int32 = 0
        guard maru_macos_app_dev_session_hover(session, xPx, yPx, cmdHeld ? 1 : 0, &isUrl) == Self.statusOK else { return }
        if isUrl == 1 {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    func clearHover() {
        guard let session = devSession else { return }
        var isUrl: Int32 = 0
        _ = maru_macos_app_dev_session_hover(session, 0, 0, 0, &isUrl)
        NSCursor.arrow.set()
    }

    // Cmd+클릭: Zig가 인식한 URL을 기본 브라우저로 연다(NSWorkspace는 OS 소유 경계).
    func handleCommandClick(_ event: NSEvent, in view: NSView) {
        guard let session = devSession else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_dev_session_url_at(session, xPx, yPx, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func pastePasteboardText() {
        guard let session = devSession,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_dev_session_paste_text(session, buf.baseAddress, buf.count)
        }
    }

    private func copySelectionToPasteboard() {
        guard let session = devSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_dev_session_copy_text(session, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sendSmokeDevEvents() {
        // 자동 smoke는 물리 키보드나 사용자의 resize 동작을 기다릴 수 없다. 대신 같은 C ABI를
        // 직접 호출해 key/resize event가 Zig dev session까지 내려가는 최소 E2E 신호를 남긴다.
        // grid는 dev session이 backing 픽셀에서 계산하므로 픽셀 크기만 보낸다.
        resizeDevSession(widthPx: 1_200, heightPx: 720)
        let keyEvent = MaruAppHostKeyEvent(
            codepoint: UInt32(UnicodeScalar("a").value),
            key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
            modifier_shift: 0,
            modifier_control: 0,
            modifier_option: 0,
            modifier_command: 0,
            is_repeat: 0,
            raw_key_code: 0
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
            raw_key_code: 0
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
        let scale = window.backingScaleFactor
        // grid(cols/rows)는 Zig dev session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다.
        // Swift는 창의 backing 픽셀만 모아 넘긴다(cell 크기·floor·placeholder 계산을 들고 있지
        // 않으므로, 메트릭이 준비되기 전 placeholder로 grid를 잘못 잡는 일이 없다).
        let widthPx = clampedUInt32(bounds.width * scale)
        let heightPx = clampedUInt32(bounds.height * scale)
        resizeDevSession(widthPx: widthPx, heightPx: heightPx)
    }

    private func resizeDevSession(widthPx: UInt32, heightPx: UInt32) {
        guard let devSession else {
            return
        }

        let scaleMilli = clampedUInt32((window?.backingScaleFactor ?? 1.0) * 1_000)
        // 같은 size+scale 중복 resize 방지(SIGWINCH storm)와 grid 계산 모두 Zig dev session이
        // 한 곳에서 처리한다. Swift는 매번 backing 픽셀+scale만 보내고, dev session이 변화 없으면
        // 비싼 재작업을 건너뛴다. tick의 scale-변화 감지용으로 보낸 backing scale만 기록한다.
        lastSentBackingScale = window?.backingScaleFactor ?? 1.0

        // cols/rows는 dev session이 무시하고 backing 픽셀에서 계산하므로 0으로 둔다.
        var event = MaruAppHostResizeEvent(
            width_px: widthPx,
            height_px: heightPx,
            scale_milli: scaleMilli,
            cols: 0,
            rows: 0,
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

    // IME 키 트랜잭션: begin -> 입력기 해석(클로저) -> end. 판정은 전부 Zig가 한다.
    func imeKeyTransaction(_ event: NSEvent, interpret: () -> Void) {
        guard let session = devSession else { return }
        _ = maru_macos_app_dev_session_ime_begin(session)
        interpret()
        // ime_end는 정규화 실패(codepoint/keyCode 없음)에도 반드시 호출한다 — 안 그러면 ime_begin
        // 후 트랜잭션이 안 닫혀 누적 텍스트가 유실되고 ime_active가 박힌다. 키가 없으면 nil 전달.
        if var keyEvent = normalizedKeyEvent(from: event) {
            _ = maru_macos_app_dev_session_ime_end(session, &keyEvent)
        } else {
            _ = maru_macos_app_dev_session_ime_end(session, nil)
        }
    }

    func imeInsert(_ text: String) {
        guard let session = devSession else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_dev_session_ime_insert(session, buf.baseAddress, buf.count)
        }
    }

    func imeMarked(_ text: String) {
        guard let session = devSession else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_dev_session_ime_marked(session, buf.baseAddress, buf.count)
        }
    }

    func imeDeleteBackward() {
        guard let session = devSession else { return }
        _ = maru_macos_app_dev_session_ime_delete_backward(session)
    }

    func imeFocus(_ focused: Bool) {
        guard let session = devSession else { return }
        _ = maru_macos_app_dev_session_set_focus(session, focused ? 1 : 0)
    }

    // IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). 화면 좌표 변환은 view가 한다.
    func imeCursorRectPx() -> (Double, Double, Double, Double)? {
        guard let session = devSession else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        guard maru_macos_app_dev_session_ime_cursor_rect(session, &x, &y, &w, &h) == Self.statusOK else { return nil }
        return (x, y, w, h)
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
        // PC-style 기능키(kVK_* 물리 키코드). 인코딩·바인딩은 Zig가 한다 — 여기선 캡처만.
        // 명시적으로 잡지 않으면 default가 F키의 private-use 문자(NSF1FunctionKey=0xF704 등)를
        // codepoint로 넘겨 엉뚱하게 인코딩된다. Shift+PageUp/Down 스크롤백은 handleKeyDown에서
        // 먼저 소비되므로(plain PageUp만 여기 도달) 충돌하지 않는다.
        case 115:
            keyCode = UInt32(MaruAppHostKeyCodeHome.rawValue)
        case 119:
            keyCode = UInt32(MaruAppHostKeyCodeEnd.rawValue)
        case 116:
            keyCode = UInt32(MaruAppHostKeyCodePageUp.rawValue)
        case 121:
            keyCode = UInt32(MaruAppHostKeyCodePageDown.rawValue)
        case 117:
            keyCode = UInt32(MaruAppHostKeyCodeDelete.rawValue) // forward delete
        case 114:
            keyCode = UInt32(MaruAppHostKeyCodeInsert.rawValue) // Help/Insert(확장 키보드)
        case 122:
            keyCode = UInt32(MaruAppHostKeyCodeF1.rawValue)
        case 120:
            keyCode = UInt32(MaruAppHostKeyCodeF2.rawValue)
        case 99:
            keyCode = UInt32(MaruAppHostKeyCodeF3.rawValue)
        case 118:
            keyCode = UInt32(MaruAppHostKeyCodeF4.rawValue)
        case 96:
            keyCode = UInt32(MaruAppHostKeyCodeF5.rawValue)
        case 97:
            keyCode = UInt32(MaruAppHostKeyCodeF6.rawValue)
        case 98:
            keyCode = UInt32(MaruAppHostKeyCodeF7.rawValue)
        case 100:
            keyCode = UInt32(MaruAppHostKeyCodeF8.rawValue)
        case 101:
            keyCode = UInt32(MaruAppHostKeyCodeF9.rawValue)
        case 109:
            keyCode = UInt32(MaruAppHostKeyCodeF10.rawValue)
        case 103:
            keyCode = UInt32(MaruAppHostKeyCodeF11.rawValue)
        case 111:
            keyCode = UInt32(MaruAppHostKeyCodeF12.rawValue)
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
            raw_key_code: UInt32(event.keyCode)
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
        var summary = """
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

        // 진단 필드는 MARU_DEBUG일 때만 붙인다. 평소엔 summary 계약을 안정적으로 유지하고,
        // 스케일/레이아웃을 디버깅할 때만 화면/창 scale·cell·drawable 값을 남긴다.
        if debugEnabled {
            summary += """
            diag_last_sent_backing_scale=\(lastSentBackingScale)
            diag_cell_width_px=\(lastCellWidthPx)
            diag_cell_height_px=\(lastCellHeightPx)
            diag_screen_scale=\(NSScreen.main?.backingScaleFactor ?? -1)
            diag_window_scale=\(window?.backingScaleFactor ?? -1)
            diag_window_screen_scale=\(window?.screen?.backingScaleFactor ?? -1)
            diag_layer_contents_scale=\(metalTerminalView?.metalLayer?.contentsScale ?? -1)
            diag_drawable_w=\(metalTerminalView?.metalLayer?.drawableSize.width ?? -1)
            diag_drawable_h=\(metalTerminalView?.metalLayer?.drawableSize.height ?? -1)

            """
        }

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
