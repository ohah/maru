import AppKit
import Carbon.HIToolbox
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
        controller?.handleBackingScaleChange(in: self)
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
        // 이 키가 IME를 우회해(단축키 조합 또는 특수키) handleKeyDown으로 직행하는가.
        let bypassesIME = !chord.isEmpty || Self.directEncodeKeyCodes.contains(event.keyCode)
        // 조합(marked text) 중에 우회 키가 오면 '먼저 조합을 확정'한다 — 안 그러면 Swift의 marked
        // text(hasMarkedText)와 Zig의 preedit가 안 비워진 채 PageUp이 화면을 옮겨, 이후 입력이 stale한
        // marked range에 박혀 위치가 어긋나거나 안 먹거나 안 지워진다(특수키 우회의 누락된 처리).
        if bypassesIME, hasMarkedText() {
            controller?.imeCommit()            // core preedit 커밋(조합 글자 PTY로)
            inputContext?.discardMarkedText()  // AppKit 입력기의 marked 상태 정리(콜백 없이)
            markedTextBuffer = ""               // hasMarkedText() = false 로 동기화
        }
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
        controller?.handleScroll(event, in: self)
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

// 한 터미널 세션의 per-session 상태 — 창/PTY(devSession)/Metal 렌더러 + 렌더 캐시 메트릭을 묶는다.
// 컨트롤러가 메인 창을 `primary`로 들고, quick terminal(후속)이 두 번째 인스턴스가 된다. 세션별 로직은
// 컨트롤러 메서드가 이 surface의 상태를 읽고 쓰며 수행한다(상태만 여기 — 두 세션이 같은 메서드를 공유).
@MainActor
final class TerminalSurface {
    var window: NSWindow?
    var devSession: OpaquePointer?
    var metalRenderer: OpaquePointer?

    // 렌더 캐시(세션별). 의미는 컨트롤러의 drawMetalFrame/tickDevSession 주석 참조.
    var lastDrawnGeneration: UInt64 = 0
    var lastSeenMetalGeneration: UInt32 = 0
    var lastCellWidthPx: UInt32 = 0
    var lastCellHeightPx: UInt32 = 0
    var lastSentBackingScale: CGFloat = 0
    var metalNeedsRedraw = false
    var metalFramesDrawn = 0
    var metalRendererCreated = false
    var latestFrameSummary = MaruAppHostDevFrameSummary()
    var devSessionStatus: Int32 = 0
    var lastWindowTitle = ""

    // Metal terminal view = 창의 contentView. window가 살아 있는 동안 유효(window가 강참조).
    var view: MaruMetalTerminalView? {
        return window?.contentView as? MaruMetalTerminalView
    }
}

// quick terminal용 떠 있는 패널. borderless NSWindow/NSPanel은 기본적으로 key가 될 수 없어 타이핑을 못
// 받는다 — quick terminal은 입력을 받아야 하므로 canBecomeKey/Main을 강제한다.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    // 메인 창의 per-session 상태. quick terminal이 두 번째 surface(quick)다. 아래 계산 프로퍼티들은
    // 기존 세션별 메서드가 코드 변경 없이 "활성 surface"의 상태를 읽고 쓰게 하는 forwarder다(상태만 분리).
    private var primary: TerminalSurface?
    // quick terminal(별도 세션 오버레이 패널)의 surface. 첫 토글에서 lazy 생성. 없거나 숨김이면 입력/렌더는 primary.
    private var quick: TerminalSurface?
    // quick 패널의 슬라이드 인/아웃 애니메이션이 진행 중인지. 포커스 잃음 자동 숨김이 애니메이션 도중·직후
    // (orderOut 시 resignKey)에 재진입해 이중 숨김하지 않게 가드한다.
    private var quickAnimating = false
    // quick terminal 표시 옵션(config에서). ensureQuickTerminal이 채운다. screen은 'mouse'면 show마다
    // 현재 마우스가 있는 화면으로 해석하므로 모드만 저장한다.
    private var quickAutoHide = true
    private var quickHeightFraction: CGFloat = 0.45
    private var quickScreenMode: UInt32 = UInt32(MaruAppHostQuickTerminalScreenMain.rawValue)
    private var quickPosition: UInt32 = UInt32(MaruAppHostQuickTerminalPositionTop.rawValue)
    // center 위치인가 — 가장자리가 없어 슬라이드(setFrame) 대신 알파 페이드로 보임/숨김을 애니메이션한다.
    private var quickIsCentered: Bool { quickPosition == UInt32(MaruAppHostQuickTerminalPositionCenter.rawValue) }
    // tick이 특정 surface를 명시적으로 대상 지정할 때 쓴다(이벤트가 아니라 타이머 구동이라 key 창으로 못 고름).
    // nil이면 입력 이벤트는 key 창 기준으로 surface를 고른다(이벤트는 key 창의 first responder로 전달되므로).
    private var explicitSurface: TerminalSurface?
    // 세션별 forwarder의 대상. tick 중에는 explicitSurface, 그 외(입력/IME/hover)에는 key 창의 surface
    // (quick 패널이 key면 quick, 아니면 primary). 앱-전역으로 "메인 창"이 필요한 곳은 primary를 직접 쓴다.
    private var activeSurface: TerminalSurface? {
        if let explicitSurface { return explicitSurface }
        if let quick, quick.window?.isKeyWindow == true { return quick }
        return primary
    }

    /// 주어진 surface를 강제 대상으로 클로저를 실행한다(그동안 forwarder가 그 surface를 가리킨다). primary 창의
    /// delegate 콜백(windowDidResize 등)·앱 요약처럼 "특정 창"이 대상이어야 하는데, 그 순간 quick 패널이 key라
    /// activeSurface의 key-창 기준이 엉뚱한 surface를 고를 수 있는 경우에 쓴다(tick이 explicitSurface를 쓰는 것과 같은 메커니즘).
    private func withSurface(_ surface: TerminalSurface?, _ body: () -> Void) {
        let previous = explicitSurface
        explicitSurface = surface
        defer { explicitSurface = previous }
        body()
    }

    /// 주어진 뷰가 속한 surface(그 뷰의 창으로 판정). 뷰에서 비롯된 콜백(backing scale 변경 등)이 key 창이 아니라
    /// '그 뷰의' surface를 대상으로 하게 한다 — quick 뷰가 fire했는데 primary가 key면 quick을 골라야 한다.
    private func surfaceForView(_ view: NSView) -> TerminalSurface? {
        if let quick, view.window === quick.window { return quick }
        return primary
    }

    private var window: NSWindow? {
        get { activeSurface?.window }
        set { activeSurface?.window = newValue }
    }
    private var devSession: OpaquePointer? {
        get { activeSurface?.devSession }
        set { activeSurface?.devSession = newValue }
    }
    private var tickTimer: Timer?
    // smoke 자동 종료용 one-shot timer. 창이 먼저 닫혀도 run loop에 남아 teardown 뒤
    // NSApp.terminate를 다시 부르지 않도록 저장해 두고 종료 시 invalidate한다.
    private var smokeTimer: Timer?
    private var smokeMode = false
    private var exitCode: Int32 = 0
    private var latestFrameSummary: MaruAppHostDevFrameSummary {
        get { activeSurface?.latestFrameSummary ?? MaruAppHostDevFrameSummary() }
        set { activeSurface?.latestFrameSummary = newValue }
    }
    private var devSessionStatus: Int32 {
        get { activeSurface?.devSessionStatus ?? Self.statusOK }
        set { activeSurface?.devSessionStatus = newValue }
    }
    // 제품 Metal renderer(maru_metal_renderer.h). dev session의 metal-frame DTO를 창의 CAMetalLayer에
    // 그린다. generation이 바뀐 frame에서만 atlas 갱신/draw한다.
    private var metalRenderer: OpaquePointer? {
        get { activeSurface?.metalRenderer }
        set { activeSurface?.metalRenderer = newValue }
    }
    private var lastDrawnGeneration: UInt64 {
        get { activeSurface?.lastDrawnGeneration ?? 0 }
        set { activeSurface?.lastDrawnGeneration = newValue }
    }
    private var metalFramesDrawn: Int {
        get { activeSurface?.metalFramesDrawn ?? 0 }
        set { activeSurface?.metalFramesDrawn = newValue }
    }
    // surface(drawableSize/backing-scale) 변경 시 generation이 그대로여도 다시 그려야 한다.
    private var metalNeedsRedraw: Bool {
        get { activeSurface?.metalNeedsRedraw ?? false }
        set { activeSurface?.metalNeedsRedraw = newValue }
    }
    // tick summary가 알려주는 metal generation(u32). 이 값이 그대로면 metalFrame() ABI 호출과
    // draw를 idle tick에서 건너뛴다.
    private var lastSeenMetalGeneration: UInt32 {
        get { activeSurface?.lastSeenMetalGeneration ?? 0 }
        set { activeSurface?.lastSeenMetalGeneration = newValue }
    }
    // renderer가 알려준 cell 픽셀 크기. resize가 같은 메트릭으로 cols/rows를 계산하도록 캐시한다.
    private var lastCellWidthPx: UInt32 {
        get { activeSurface?.lastCellWidthPx ?? 0 }
        set { activeSurface?.lastCellWidthPx = newValue }
    }
    private var lastCellHeightPx: UInt32 {
        get { activeSurface?.lastCellHeightPx ?? 0 }
        set { activeSurface?.lastCellHeightPx = newValue }
    }
    // dev session에 마지막으로 보낸 backing scale. 런치 후 backingScaleFactor가 늦게 Retina로
    // 정착하면(콜백이 dev session 생성 전에 발화한 경우) tick이 변화를 감지해 재-resize한다.
    // (같은 size+scale 중복 resize 방지는 Zig dev session이 담당한다.)
    private var lastSentBackingScale: CGFloat {
        get { activeSurface?.lastSentBackingScale ?? 0 }
        set { activeSurface?.lastSentBackingScale = newValue }
    }
    // create 성공 여부를 영구 기록한다. metalRenderer는 shutdown에서 nil이 되므로 summary가
    // 종료 후 쓰일 때 "생성됐었다"를 잃지 않게 별도 플래그로 둔다.
    private var metalRendererCreated: Bool {
        get { activeSurface?.metalRendererCreated ?? false }
        set { activeSurface?.metalRendererCreated = newValue }
    }
    // 전역(OS) 단축키: Zig가 준 descriptor를 Carbon RegisterEventHotKey로 등록한 ref들과, 각 hot-key
    // id → action(0=toggle,1=show) 맵. 핸들러(비캡처 C 함수 포인터)가 id로 action을 되찾는다. 종료 시
    // UnregisterEventHotKey + RemoveEventHandler로 정리한다.
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyActions: [UInt32: UInt32] = [:]
    private var hotKeyEventHandler: EventHandlerRef?

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

        // 메인 창의 per-session 상태를 담을 surface를 가장 먼저 만든다 — 아래 window/devSession/렌더러
        // 대입이 전부 이 primary로 forwarding되므로(forwarder setter), primary가 없으면 그 대입이 사라진다.
        self.primary = TerminalSurface()

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
            // 전역(OS) 단축키를 OS에 등록한다(앱이 비활성이어도 동작). smoke는 자동 종료라 등록하지 않는다.
            registerGlobalHotkeys()
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
        // 종료 요약은 메인 세션(primary) 기준 — quick 패널이 key인 채 종료해도 forwarder가 quick으로 새지 않게.
        withSurface(primary) {
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        // false: 메인 창을 화면에서 내려도(orderOut — 전역 단축키 toggle_window의 "숨김") 앱이 종료되면 안 된다.
        // true면 마지막 창이 화면에서 사라질 때 AppKit이 앱을 종료시켜, 숨기자마자 quit돼 다시 띄울 수 없다.
        // 명시적 창 닫기(빨간 버튼 등)에 따른 종료는 windowWillClose가 NSApp.terminate로 담당한다(단일 출처).
        return false
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        shutdownDevSession()
        // 컨트롤러는 primary 창의 delegate라 이 콜백은 항상 primary 것. 요약도 primary 기준으로(그 순간 quick
        // 패널이 key여도 forwarder가 quick으로 새지 않게).
        withSurface(primary) {
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
        }
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        // 컨트롤러는 primary 창의 delegate라(quick 패널은 알림 관찰을 씀) 이 resize는 항상 primary 창 것이다.
        // primary를 명시 대상으로 한다 — 안 그러면 그 순간 quick 패널이 key일 때 forwarder가 quick을 리사이즈한다.
        withSurface(primary) {
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
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        _ = notification
        withSurface(primary) { // primary 창의 delegate 콜백 — primary를 명시 대상으로(위 windowDidResize와 같은 이유).
            metalTerminalView?.updateDrawableSize()
            resizeDevSessionFromWindow()
        }
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
            frame.cell_count,
            frame.terminal_origin_x_px, // 세로 사이드바 폭(터미널 origin offset)
            frame.sidebar_bg,           // 사이드바 배경색(0=안 그림)
            frame.sidebar_cells,        // 사이드바 셀(탭 엔트리) — origin 0에 그림
            frame.sidebar_cell_count,
            frame.sidebar_slot_height_px // 탭 슬롯 높이(≈2.5×cell) — 사이드바 셀 세로 배치
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
    func handleBackingScaleChange(in view: NSView) {
        guard !smokeMode else { return }
        // backing scale 변경은 그 변경이 일어난 '뷰의' 창(=surface)을 대상으로 resize해야 한다 — quick 뷰가
        // fire했는데 primary가 key면(또는 반대) activeSurface가 엉뚱한 surface를 고를 수 있으므로 명시한다.
        withSurface(surfaceForView(view)) {
            resizeDevSessionFromWindow()
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
            chrome_minimal: 0 // 메인 창은 항상 full chrome(사이드바·탭 바)
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

    // 마지막으로 설정한 창 제목(매 tick 같은 값을 재설정하지 않으려는 캐시). 세션별이라 surface가 든다.
    private var lastWindowTitle: String {
        get { activeSurface?.lastWindowTitle ?? "" }
        set { activeSurface?.lastWindowTitle = newValue }
    }

    // 창 제목을 셸/앱 상태에서 갱신한다 — OSC 0/2 제목이 있으면 그것, 없으면 OSC 7 cwd basename,
    // 둘 다 없으면 앱 이름("Maru"). 우선순위 로직은 Zig(core.windowTitle)가 소유하고 여기선 받아서
    // 빈값 폴백만 한다. debugEnabled면 진단 제목(updateDiagnosticTitle)이 제목줄을 쓰므로 건너뛴다
    // (상호 배타). 변했을 때만 window.title을 써서 매 tick 불필요한 setter 호출을 막는다.
    private func updateWindowTitle() {
        guard !debugEnabled, let window, let session = devSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_dev_session_window_title(session, &ptr, &len) == Self.statusOK else { return }
        let title: String
        if let bytes = ptr, len > 0 {
            title = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        } else {
            title = "Maru" // 제목·cwd 둘 다 없으면 앱 이름
        }
        if title != lastWindowTitle {
            window.title = title
            lastWindowTitle = title
        }
    }

    // 타이머가 매 frame 부른다 — primary(메인 창)를 먼저 tick하고(셸 종료/fault는 앱-전역 종료로),
    // quick terminal이 보이면 그것도 tick한다(quick 셸 종료/fault는 quick만 닫고 앱은 계속). 각 surface를
    // explicitSurface로 지정해, 세션별 forwarder(window/devSession/메트릭/draw)가 그 surface를 대상으로 돈다.
    private func tickDevSession() {
        guard let primary else { return }

        explicitSurface = primary
        let status = renderTick()
        if status == Self.statusOK {
            // 첫 tick에 summary를 한 번 남긴다(launch 경로 진단). primary 기준.
            if latestFrameSummary.frame_loop_ticks <= 1 {
                writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            }
            explicitSurface = nil
        } else if status == Self.statusSessionEnded {
            // 메인 PTY 셸이 정상 종료 → frame loop 멈추고 우아하게(exitCode 0) 내려간다.
            tickTimer?.invalidate()
            tickTimer = nil
            smokeTimer?.invalidate()
            smokeTimer = nil
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            explicitSurface = nil
            NSApp.terminate(nil)
            return
        } else {
            // tick_failed 등 세션 자체 fault만 비정상 종료(exitCode 1).
            exitCode = 1
            writeSummary(visibleUI: window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            explicitSurface = nil
            NSApp.terminate(nil)
            return
        }

        // quick terminal — 보일 때만 tick. 그 셸이 종료/fault면 quick만 정리한다(앱은 계속 산다).
        if let quick, quick.window?.isVisible == true {
            explicitSurface = quick
            let quickStatus = renderTick()
            explicitSurface = nil
            if quickStatus != Self.statusOK {
                tearDownQuickTerminal()
            }
        }
    }

    // 현재 activeSurface(= explicitSurface)를 한 번 tick하고 그린다. 세션별 forwarder만 쓰므로 호출자가
    // explicitSurface로 대상을 정한다. 앱-전역 정책(SessionEnded 종료·summary)은 호출자(tickDevSession)가 한다.
    private func renderTick() -> Int32 {
        guard let devSession else { return Self.statusOK }
        updateDiagnosticTitle()
        updateWindowTitle() // 비-debug일 때 OSC 0/2 제목 또는 cwd basename을 제목줄에 반영

        // backing scale이 런치 후 늦게 정착/변경되면 device_scale이 옛 값에 머문다. 변했을 때만 resize.
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
            // metal frame이 바뀌었거나(generation) surface 재칠이 필요할 때만 그린다.
            if summary.metal_generation != lastSeenMetalGeneration || metalNeedsRedraw {
                lastSeenMetalGeneration = summary.metal_generation
                drawMetalFrame()
            }
        }
        return status
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
    func handleScroll(_ event: NSEvent, in view: NSView) {
        guard let session = devSession else { return }
        // 마우스 위치를 backing 픽셀(좌상단 원점)로 — Zig가 커서 아래 panel로 스크롤을 라우팅한다(split).
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        _ = maru_macos_app_dev_session_scroll_wheel(
            session,
            Double(event.scrollingDeltaY),
            event.hasPreciseScrollingDeltas ? 1 : 0,
            xPx,
            yPx
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
        // Zig가 위치별 커서 종류를 판정해 돌려준다(CursorKind). Swift는 그 값을 NSCursor로 매핑만 한다 —
        // 전부 iBeam이던 걸 영역별로(사이드바·탭 바=arrow, divider=resize, 터미널=iBeam, URL=pointingHand).
        var cursorKind: Int32 = 1
        guard maru_macos_app_dev_session_hover(session, xPx, yPx, cmdHeld ? 1 : 0, &cursorKind) == Self.statusOK else { return }
        Self.cursor(for: cursorKind).set()
    }

    // CursorKind(app_host_abi.h: 0=arrow, 1=iBeam, 2=pointingHand, 3=resizeLeftRight, 4=resizeUpDown) → NSCursor.
    private static func cursor(for kind: Int32) -> NSCursor {
        switch kind {
        case 0: return .arrow
        case 2: return .pointingHand
        case 3: return .resizeLeftRight
        case 4: return .resizeUpDown
        default: return .iBeam // 1(text) 및 미지값
        }
    }

    func clearHover() {
        guard let session = devSession else { return }
        var cursorKind: Int32 = 0
        // 음수 좌표 sentinel: Zig가 사이드바 영역 밖(x<0)·터미널 셀 밖으로 보고 URL 밑줄과 사이드바 슬롯
        // 호버를 모두 해제한다((0,0)은 사이드바 슬롯 0으로 오인될 수 있어 못 쓴다). 커서는 arrow로(뷰 밖).
        _ = maru_macos_app_dev_session_hover(session, -1, -1, 0, &cursorKind)
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

    // 진행 중 IME 조합을 확정한다(IME 우회 특수키/단축키 직전). core preedit를 커밋·비운다.
    func imeCommit() {
        guard let session = devSession else { return }
        _ = maru_macos_app_dev_session_commit_composition(session)
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

    // MARK: - 전역(OS) 단축키 (Carbon RegisterEventHotKey)

    /// Carbon hot-key 이벤트 핸들러(비캡처 C 함수 포인터). userData로 받은 controller에서 눌린 hot-key
    /// id로 action을 되찾아 수행한다. RegisterEventHotKey 이벤트는 메인 run loop(메인 스레드)에서 전달된다.
    private static let globalHotkeyHandler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard err == noErr else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<MaruAppHostController>.fromOpaque(userData).takeUnretainedValue()
        let id = hotKeyID.id
        // 핸들러는 메인 스레드에서 호출되므로 @MainActor controller를 바로 부른다(tick 콜백과 동일 패턴).
        MainActor.assumeIsolated {
            controller.handleGlobalHotkey(id: id)
        }
        return noErr
    }

    /// Zig가 준 전역 단축키 descriptor를 Carbon에 등록한다. 핸들러를 한 번 설치하고(userData=self), 각
    /// descriptor를 RegisterEventHotKey로 등록한다. hot-key id = descriptor 배열 인덱스라 핸들러가
    /// 그 id로 action(hotKeyActions)을 되찾는다. descriptor가 없으면(빈 config) 아무것도 등록하지 않는다.
    private func registerGlobalHotkeys() {
        guard let session = devSession else { return }
        var ptr: UnsafePointer<MaruAppHostGlobalHotkey>?
        var count = 0
        let status = maru_macos_app_dev_session_global_hotkeys(session, &ptr, &count)
        guard status == Self.statusOK, let base = ptr, count > 0 else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.globalHotkeyHandler,
            1,
            &spec,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else { return }
        hotKeyEventHandler = handlerRef

        let signature = OSType(0x4d61_7275) // 'Maru'
        for index in 0..<count {
            let descriptor = base[index]
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index))
            let regStatus = RegisterEventHotKey(
                descriptor.virtual_key_code,
                descriptor.carbon_modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if regStatus == noErr, let ref {
                hotKeyRefs.append(ref)
                hotKeyActions[UInt32(index)] = descriptor.action
            }
        }
    }

    /// 등록한 전역 단축키와 핸들러를 OS에서 해제한다(idempotent — 이미 비었으면 no-op).
    private func unregisterGlobalHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyActions.removeAll()
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    /// 눌린 전역 단축키 id의 action을 수행한다(핸들러가 메인 스레드에서 호출).
    func handleGlobalHotkey(id: UInt32) {
        guard let action = hotKeyActions[id] else { return }
        performGlobalAction(action)
    }

    /// 전역 action 수행. window 동작은 앱-전역이라 forwarder가 아니라 메인 창(primary)을 직접 대상으로 한다.
    /// 토글은 Maru가 앞+창이 보이면 숨기고(orderOut), 아니면 보이고 앞으로(show+activate).
    private func performGlobalAction(_ action: UInt32) {
        switch action {
        case UInt32(MaruAppHostGlobalActionToggleWindow.rawValue):
            guard let window = primary?.window else { return }
            if window.isVisible && NSApp.isActive {
                window.orderOut(nil)
            } else {
                showAndActivateWindow(window)
            }
        case UInt32(MaruAppHostGlobalActionShowWindow.rawValue):
            guard let window = primary?.window else { return }
            showAndActivateWindow(window)
        case UInt32(MaruAppHostGlobalActionToggleQuickTerminal.rawValue):
            toggleQuickTerminal()
        default:
            break
        }
    }

    private func showAndActivateWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - quick terminal (별도 세션 오버레이 패널)

    /// quick terminal을 토글한다 — 보이면 위로 슬라이드해 숨기고, 아니면 (없으면 lazy 생성) 상단에서 내려와 key로.
    private func toggleQuickTerminal() {
        if let quick, quick.window?.isVisible == true {
            if let panel = quick.window { hideQuickTerminalAnimated(panel) }
            return
        }
        ensureQuickTerminal()
        guard let panel = quick?.window else { return }
        showQuickTerminalAnimated(panel)
    }

    /// quick terminal surface를 lazy 생성한다(첫 토글). 두 번째 dev session(대화형 셸) + borderless 패널 +
    /// Metal 뷰/렌더러를 만든다. 세션 생성 실패면 quick은 nil로 남고 토글은 무동작(앱은 정상).
    private func ensureQuickTerminal() {
        guard quick == nil else { return }
        let surface = TerminalSurface()

        // borderless 떠 있는 패널 — 타이틀바 없이 화면 상단에서 내려오는 드롭다운. QuickTerminalPanel은
        // borderless여도 key가 될 수 있어 타이핑을 받는다. 화면 전환/전체화면 위에서도 보이게 collectionBehavior.
        let panel = QuickTerminalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = MaruMetalTerminalView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 300))
        content.controller = self
        content.wantsLayer = true
        panel.contentView = content
        surface.window = panel

        // Metal 렌더러: 이 패널 뷰의 CAMetalLayer로(메인과 별도 인스턴스).
        if let metalLayer = content.metalLayer, let device = metalLayer.device {
            content.updateDrawableSize()
            surface.metalRenderer = maru_metal_renderer_create(device, metalLayer.pixelFormat)
            surface.metalRendererCreated = surface.metalRenderer != nil
        }

        // config 옵션(높이·자동 숨김·화면·가장자리·chrome)을 먼저 읽어 둔다. 세션 동안 불변이라 생성 시 한 번.
        // primary 세션이 같은 config 파일을 로드하므로 거기서 읽는다(primary는 시작 시 항상 존재). screen은
        // 모드만 저장하고(mouse면 show마다 현재 마우스 화면으로 해석), 높이는 0.1~1.0으로 클램프(방어적 — Zig도
        // 검증). chrome은 세션 생성 시 chrome_minimal로 넘겨야 하므로 create '전에' 읽는다.
        var chromeMinimal: UInt32 = 0
        if let cfg = loadQuickTerminalConfig() {
            quickHeightFraction = max(0.1, min(1.0, CGFloat(cfg.height_milli) / 1000.0))
            quickAutoHide = cfg.auto_hide != 0
            quickScreenMode = cfg.screen
            quickPosition = cfg.position
            chromeMinimal = (cfg.chrome == UInt32(MaruAppHostQuickTerminalChromeMinimal.rawValue)) ? 1 : 0
        }

        // 두 번째 dev session(대화형 셸) — 메인과 독립된 PTY. minimal이면 chrome_minimal=1로 사이드바·탭 바를 끈다.
        var config = MaruAppHostDevSessionConfig(
            abi_version: MARU_MACOS_APP_HOST_ABI_VERSION,
            cols: 80,
            rows: 24,
            queue_capacity: 16,
            command_kind: UInt32(MaruAppHostDevCommandInteractiveShell.rawValue),
            chrome_minimal: chromeMinimal
        )
        var session: OpaquePointer?
        guard maru_macos_app_dev_session_create(&config, &session) == Self.statusOK, let created = session else {
            // 세션 생성 실패 — 렌더러를 정리하고 포기한다(quick = nil 유지, 토글은 무동작).
            if let renderer = surface.metalRenderer { maru_metal_renderer_destroy(renderer) }
            return
        }
        surface.devSession = created
        self.quick = surface

        // 포커스 잃음 자동 숨김: 패널이 key를 잃으면 quickTerminalLostKey가 슬라이드로 숨긴다. 패널을 컨트롤러의
        // window-delegate로 잡으면 windowWillClose/Resize가 primary 경로와 섞이므로, delegate 대신 이 패널만
        // 겨냥한 알림 관찰을 쓴다(IME가 view에서 쓰는 패턴과 동일). teardown에서 해제한다.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickTerminalLostKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    /// config의 quick terminal 옵션을 읽는다(높이·자동 숨김·화면). config는 모든 dev session이 같은 파일을
    /// 로드하므로 primary 세션에서 읽는다(primary는 시작 시 항상 존재). 못 읽으면 nil(기본값 유지).
    private func loadQuickTerminalConfig() -> MaruAppHostQuickTerminalConfig? {
        guard let session = primary?.devSession else { return nil }
        var cfg = MaruAppHostQuickTerminalConfig()
        guard maru_macos_app_dev_session_quick_terminal_config(session, &cfg) == Self.statusOK else { return nil }
        return cfg
    }

    /// quick 패널을 띄울 화면. screen=mouse면 현재 마우스 포인터가 있는 화면(없으면 main 폴백), 아니면 주 디스플레이.
    private func quickTargetScreen() -> NSScreen? {
        if quickScreenMode == UInt32(MaruAppHostQuickTerminalScreenMouse.rawValue) {
            let loc = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main
        }
        return NSScreen.main
    }

    /// quick 패널의 "보임"(설정 가장자리에 붙은 위치)과 "숨김"(같은 크기로 그 가장자리 바깥으로 빠진 위치)
    /// 사각형. top/bottom은 전폭 + height_fraction 높이, left/right는 전고 + height_fraction 폭이다. 보임/숨김은
    /// **슬라이드 축(top/bottom=y, left/right=x)만 다르고** 폭·높이가 같다 — 슬라이드 중 콘텐츠 크기가 안 바뀌어
    /// drawable/grid 재계산이 필요 없다. center는 가장자리가 없어 화면 중앙에 width·height 둘 다 height_fraction
    /// 비율로 띄우고 **보임=숨김**(같은 사각형) — 슬라이드 대신 알파 페이드를 쓰므로 위치 차이가 없다.
    private func quickPanelFrames() -> (shown: NSRect, hidden: NSRect)? {
        guard let screen = quickTargetScreen() else { return nil }
        let vf = screen.visibleFrame
        switch quickPosition {
        case UInt32(MaruAppHostQuickTerminalPositionBottom.rawValue):
            let h = (vf.height * quickHeightFraction).rounded()
            return (NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: h),
                    NSRect(x: vf.minX, y: vf.minY - h, width: vf.width, height: h)) // 아래로 빠짐
        case UInt32(MaruAppHostQuickTerminalPositionLeft.rawValue):
            let w = (vf.width * quickHeightFraction).rounded()
            return (NSRect(x: vf.minX, y: vf.minY, width: w, height: vf.height),
                    NSRect(x: vf.minX - w, y: vf.minY, width: w, height: vf.height)) // 왼쪽으로 빠짐
        case UInt32(MaruAppHostQuickTerminalPositionRight.rawValue):
            let w = (vf.width * quickHeightFraction).rounded()
            return (NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height),
                    NSRect(x: vf.maxX, y: vf.minY, width: w, height: vf.height)) // 오른쪽으로 빠짐
        case UInt32(MaruAppHostQuickTerminalPositionCenter.rawValue):
            // 중앙: width·height 둘 다 height_fraction 비율. 가장자리가 없어 보임=숨김(페이드로 처리).
            let w = (vf.width * quickHeightFraction).rounded()
            let h = (vf.height * quickHeightFraction).rounded()
            let r = NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w, height: h)
            return (r, r)
        default: // top
            let h = (vf.height * quickHeightFraction).rounded()
            return (NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h),
                    NSRect(x: vf.minX, y: vf.maxY, width: vf.width, height: h)) // 위로 빠짐
        }
    }

    /// quick 패널을 숨김 위치(가장자리 바깥)에서 보임 위치(가장자리에 붙음)로 슬라이드한다. 크기는 처음부터
    /// 최종값이라(숨김/보임이 슬라이드 축만 다름) makeKey 직후 세션 grid를 한 번 맞추고 위치만 애니메이션한다.
    private func showQuickTerminalAnimated(_ panel: NSWindow) {
        guard let frames = quickPanelFrames() else {
            // 화면 정보를 못 구하면 애니메이션 없이 그냥 띄운다(폴백).
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let centered = quickIsCentered
        panel.setFrame(frames.hidden, display: false)
        if centered { panel.alphaValue = 0 } // 중앙은 투명에서 시작해 페이드 인(가장자리 슬라이드가 없음)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        NSApp.activate(ignoringOtherApps: true)
        // 크기는 최종값(frames.hidden은 보임과 폭·높이 동일)이라 지금 grid를 맞춘다 — 슬라이드/페이드 중 재계산 불필요.
        explicitSurface = quick
        resizeDevSessionFromWindow()
        explicitSurface = nil

        quickAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            // 가장자리(top/bottom/left/right)는 위치 슬라이드, center는 제자리 페이드 인.
            if centered {
                panel.animator().alphaValue = 1
            } else {
                panel.animator().setFrame(frames.shown, display: true)
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.quickAnimating = false }
        })
    }

    /// quick 패널을 보임 위치에서 숨김 위치(가장자리 바깥)로 슬라이드한 뒤 orderOut으로 숨긴다(완료 시).
    private func hideQuickTerminalAnimated(_ panel: NSWindow) {
        guard let frames = quickPanelFrames() else {
            panel.orderOut(nil)
            return
        }
        let centered = quickIsCentered
        quickAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            // 가장자리는 위치 슬라이드로 빠지고, center는 제자리 페이드 아웃.
            if centered {
                panel.animator().alphaValue = 0
            } else {
                panel.animator().setFrame(frames.hidden, display: true)
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                if centered { panel.alphaValue = 1 } // 다음 show를 위해 알파 복구(orderOut 후라 안 보임)
                self?.quickAnimating = false
            }
        })
    }

    /// quick 패널이 key를 잃으면(다른 창/앱 클릭) 숨긴다 — quick terminal의 표준 동작(클릭이 빠지면 사라짐).
    /// config에서 자동 숨김을 끄면(quickAutoHide=false) 토글로만 숨기고 여기선 무동작. 애니메이션 중(특히
    /// 숨김 완료 orderOut의 resignKey)에는 재진입을 막고, 보이는 상태일 때만 숨긴다.
    @objc private func quickTerminalLostKey(_ note: Notification) {
        guard quickAutoHide, !quickAnimating, let panel = quick?.window, panel.isVisible else { return }
        hideQuickTerminalAnimated(panel)
    }

    /// quick terminal을 닫고 정리한다(셸 종료/fault, 또는 앱 종료 시). 세션·렌더러를 해제하고 패널을 내린다.
    private func tearDownQuickTerminal() {
        guard let surface = quick else { return }
        self.quick = nil
        quickAnimating = false
        if let panel = surface.window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        }
        surface.window?.orderOut(nil)
        if let session = surface.devSession {
            var summary = MaruAppHostDevFrameSummary()
            _ = maru_macos_app_dev_session_close(session, &summary)
            maru_macos_app_dev_session_destroy(session)
            surface.devSession = nil
        }
        if let renderer = surface.metalRenderer {
            maru_metal_renderer_destroy(renderer)
            surface.metalRenderer = nil
        }
    }

    private func shutdownDevSession() {
        // 전역 단축키를 먼저 OS에서 해제한다(세션이 사라져도 stale hot-key가 남지 않게). 이미 비었으면 no-op.
        unregisterGlobalHotkeys()
        // quick terminal(있으면)도 함께 정리한다.
        tearDownQuickTerminal()

        // 메인 세션(primary)을 명시적으로 닫고 파괴한다(forwarder 라우팅이 아니라 primary 직접 — 종료 경로라 명확히).
        guard let surface = primary, let session = surface.devSession else {
            return
        }
        var summary = MaruAppHostDevFrameSummary()
        let status = maru_macos_app_dev_session_close(session, &summary)
        surface.devSessionStatus = status
        if status == Self.statusOK {
            surface.latestFrameSummary = summary
        } else {
            exitCode = 1
        }
        maru_macos_app_dev_session_destroy(session)
        surface.devSession = nil

        if let renderer = surface.metalRenderer {
            maru_metal_renderer_destroy(renderer)
            surface.metalRenderer = nil
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
