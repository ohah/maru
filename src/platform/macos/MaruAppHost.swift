import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import Metal
import QuartzCore
import UserNotifications

@MainActor
final class MaruMetalTerminalView: NSView, @preconcurrency NSTextInputClient {
    weak var controller: MaruAppHostController?

    override var acceptsFirstResponder: Bool {
        return true
    }

    // CAMetalLayer를 backing layer로 쓴다. Zig app session이 만든 RenderFrame을 제품 Metal
    // renderer가 이 layer의 drawable에 그린다.
    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        // 색 정확도: 레이어 픽셀을 sRGB로 색관리되게 태그한다. 미설정(nil)이면 macOS가 색 관리를 하지 않아,
        // sRGB 기준으로 만든 색(테마 #RRGGBB·ANSI 팔레트)이 wide-gamut(Display P3) 디스플레이에서 native gamut으로
        // 직접 표시돼 채도가 과장되고 색조가 어긋난다. sRGB 태그를 주면 macOS가 디스플레이로 정확히 색 변환한다.
        // 베이스/결정: Ghostty도 Metal 레이어 colorspace를 명시한다(references/ghostty/src/renderer/metal/Target.zig —
        // 레이어는 displayP3, window-colorspace 기본 srgb). maru는 색 값이 sRGB 기준이라 레이어를 sRGB로 태그하는 게
        // 가장 단순·정확하다(P3 gamut 확장은 후속 옵션). 셀 색 packing/셰이더는 그대로 — 표시 단계 색관리만 바로잡는다.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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
        // 파일/이미지/텍스트 드래그를 받으려면 타입을 등록해야 한다 — 등록하지 않으면 OS가 드래그 이벤트를
        // 뷰에 전달조차 하지 않는다(드래그가 무반응이던 원인).
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    // MARK: 드래그앤드롭 (파일/이미지/URL/텍스트를 드래그 → 경로/텍스트 삽입)
    //
    // 베이스/결정: Ghostty 드롭 동작을 베이스로 한다(references/ghostty/.../SurfaceView_AppKit.swift) — 우선순위
    // URL > 파일 URL(각각 셸 이스케이프 후 공백으로 join) > 평문(이스케이프 안 함 — 실행할 명령일 수 있음). 코드
    // 표현은 옮기지 않고 maru 독립 구현이다. 이미지를 인라인으로 그리지는 않는다(경로만 — 그래픽 프로토콜은 별도).
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy // copy 아이콘으로 드롭 가능함을 표시
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // 내용 추출·삽입은 paste 로직을 가진 controller에 위임한다(클립보드 paste와 같은 경로 재사용 — keyDown이
        // handleKeyDown에 위임하는 것과 동형). 세션/PTY 접근은 controller가 소유한다.
        return controller?.handleDrop(sender.draggingPasteboard) ?? false
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
        controller?.handleHover(event, in: self)        // Cmd+링크 밑줄·커서 모양
        controller?.handleMouseMotion(event, in: self)  // mouse reporting(DECSET 1003) — Zig가 트래킹 확인 후 리포트
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
        // backing scale이 바뀌면 app session에 새 scale로 resize를 다시 보내, glyph가 device
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
        // 모드에서도 Ctrl+B(멀티플렉서 prefix)나 Cmd+C가 동작하고(레이아웃 독립 매칭은 Zig가 물리
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

    // right/middle 버튼도 reporting용으로 라우팅(handleMouse가 buttonNumber→xterm 변환). tracking이 꺼졌으면
    // Zig가 button!=0을 무시한다(셀렉션은 left만, context 메뉴 없음). down/drag/up = kind 1/2/3.
    override func rightMouseDown(with event: NSEvent) { controller?.handleMouse(event, kind: 1, in: self) }
    override func rightMouseDragged(with event: NSEvent) { controller?.handleMouse(event, kind: 2, in: self) }
    override func rightMouseUp(with event: NSEvent) { controller?.handleMouse(event, kind: 3, in: self) }
    override func otherMouseDown(with event: NSEvent) { controller?.handleMouse(event, kind: 1, in: self) }
    override func otherMouseDragged(with event: NSEvent) { controller?.handleMouse(event, kind: 2, in: self) }
    override func otherMouseUp(with event: NSEvent) { controller?.handleMouse(event, kind: 3, in: self) }
}

// 한 터미널 세션의 per-session 상태 — 창/PTY(appSession)/Metal 렌더러 + 렌더 캐시 메트릭을 묶는다.
// 컨트롤러가 메인 창을 `primary`로 들고, quick terminal(후속)이 두 번째 인스턴스가 된다. 세션별 로직은
// 컨트롤러 메서드가 이 surface의 상태를 읽고 쓰며 수행한다(상태만 여기 — 두 세션이 같은 메서드를 공유).
@MainActor
final class TerminalSurface {
    var window: NSWindow?
    var appSession: OpaquePointer?
    var metalRenderer: OpaquePointer?

    // 렌더 캐시(세션별). 의미는 컨트롤러의 drawMetalFrame/tickAppSession 주석 참조.
    var lastDrawnGeneration: UInt64 = 0
    var lastSeenMetalGeneration: UInt32 = 0
    var lastCellWidthPx: UInt32 = 0
    var lastCellHeightPx: UInt32 = 0
    var lastSentBackingScale: CGFloat = 0
    var metalNeedsRedraw = false
    var metalFramesDrawn = 0
    var metalRendererCreated = false
    var latestFrameSummary = MaruAppHostFrameSummary()
    var appSessionStatus: Int32 = 0
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

    private let artifactDirectory = "zig-out/maru-macos-app"
    private let summaryPath = "zig-out/maru-macos-app/app.summary.txt"
    private var capabilities = MaruAppHostCapabilities()
    // 일반 터미널 창들의 per-session 상태(단일 출처). 현재는 launch에 1개만 만들지만(동작 불변), New Window가
    // 여기에 append한다 — W1은 `primary` 단일 필드를 컬렉션으로 일반화하는 소유권 seam이다(split PR2a의
    // "Tab→tree seam, 단일 leaf, 동작 불변"과 같은 결). 창별 라우팅(surfaceForView/activeSurface)은 이
    // 컬렉션에서 view/key 창으로 고른다. quick terminal이 별도(특수) surface다. 아래 계산 프로퍼티들은
    // 기존 세션별 메서드가 코드 변경 없이 "활성 surface"의 상태를 읽고 쓰게 하는 forwarder다(상태만 분리).
    private var windows: [TerminalSurface] = []
    // 앱-전역 "메인/첫 일반 창" 별칭(= windows.first). 앱 요약·종료처럼 특정 한 창이 기준일 때 쓴다. 창별
    // 타게팅 세분화(key 창 기준 메뉴/포커스)는 W4. TerminalSurface는 reference라 `primary?.field = x` 변형은
    // 객체를 통해 그대로 동작한다(컬렉션 재대입이 아님).
    private var primary: TerminalSurface? { windows.first }
    // quick terminal(별도 세션 오버레이 패널)의 surface. 첫 토글에서 lazy 생성. 없거나 숨김이면 입력/렌더는 primary.
    private var quick: TerminalSurface?
    // quick 패널의 슬라이드 인/아웃 애니메이션이 진행 중인지. 포커스 잃음 자동 숨김이 애니메이션 도중·직후
    // (orderOut 시 resignKey)에 재진입해 이중 숨김하지 않게 가드한다.
    private var quickAnimating = false
    // quick terminal 표시 옵션(config에서). ensureQuickTerminal이 채운다. screen은 'mouse'면 show마다
    // 현재 마우스가 있는 화면으로 해석하므로 모드만 저장한다.
    private var quickAutoHide = true
    private var quickHeightFraction: CGFloat = 0.45
    // center 가로 비율. 0이면 미설정 → quickHeightFraction을 따라간다(정사각). center 외 위치는 안 쓴다.
    private var quickWidthFraction: CGFloat = 0
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
        // key인 일반 창을 고르고, 없으면 첫 창(primary). 단일 창에선 둘 다 그 창이라 동작 불변, 멀티 창에선
        // 입력/draw가 자연히 key 창으로 간다(이벤트는 key 창의 first responder로 오므로).
        return windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first
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
        // 그 뷰가 속한 일반 창의 surface(멀티 창이면 정확히 그 창). 단일 창에선 그 창=primary라 동작 불변.
        return windows.first(where: { $0.window === view.window }) ?? primary
    }

    /// 주어진 NSWindow의 일반-창 surface(notification.object 기준 delegate 콜백용). quick 패널은 컨트롤러를
    /// window-delegate로 쓰지 않으므로(알림 관찰) windowWillClose/Resize는 일반 창에서만 fire한다 — 컬렉션에서만 찾는다.
    private func surfaceForWindow(_ window: NSWindow?) -> TerminalSurface? {
        guard let window else { return nil }
        return windows.first(where: { $0.window === window })
    }

    private var window: NSWindow? {
        get { activeSurface?.window }
        set { activeSurface?.window = newValue }
    }
    private var appSession: OpaquePointer? {
        get { activeSurface?.appSession }
        set { activeSurface?.appSession = newValue }
    }
    private var tickTimer: Timer?
    // smoke 자동 종료용 one-shot timer. 창이 먼저 닫혀도 run loop에 남아 teardown 뒤
    // NSApp.terminate를 다시 부르지 않도록 저장해 두고 종료 시 invalidate한다.
    private var smokeTimer: Timer?
    private var smokeMode = false
    private var exitCode: Int32 = 0
    private var latestFrameSummary: MaruAppHostFrameSummary {
        get { activeSurface?.latestFrameSummary ?? MaruAppHostFrameSummary() }
        set { activeSurface?.latestFrameSummary = newValue }
    }
    private var appSessionStatus: Int32 {
        get { activeSurface?.appSessionStatus ?? Self.statusOK }
        set { activeSurface?.appSessionStatus = newValue }
    }
    // 제품 Metal renderer(maru_metal_renderer.h). app session의 metal-frame DTO를 창의 CAMetalLayer에
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
    // app session에 마지막으로 보낸 backing scale. 런치 후 backingScaleFactor가 늦게 Retina로
    // 정착하면(콜백이 app session 생성 전에 발화한 경우) tick이 변화를 감지해 재-resize한다.
    // (같은 size+scale 중복 resize 방지는 Zig app session이 담당한다.)
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

        // 메인 창의 per-session 상태를 담을 surface를 가장 먼저 만든다 — 아래 window/appSession/렌더러
        // 대입이 전부 이 첫 창(primary = windows.first)으로 forwarding되므로(forwarder setter), 창이 없으면
        // 그 대입이 사라진다. New Window(W2)는 같은 컬렉션에 surface를 추가한다.
        self.windows.append(TerminalSurface())

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

        // app session의 첫 tick(startAppSession 안)이 바로 그릴 수 있도록 renderer를 먼저 만든다.
        setupMetalRenderer()

        if !startAppSession(smokeMode: smokeMode) {
            writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }

        // 저장된 workspace를 복원한다(R4b) — 첫 블록을 primary에 적용하고 나머지 블록마다 새 창. 저장 없음·복원
        // off·smoke·빈 블록이면 무동작(방금 만든 기본 단일 창 유지). startAppSession이 세션을 세운 '뒤'에.
        restoreWorkspace()

        // 표준 메뉴바를 세운다(커맨드 카탈로그에서 액션 항목·단축키를 읽어). smoke에서도 빌드해 구성 경로를
        // CI가 구동한다(메뉴는 OS-global 부수효과가 없어 hotkey 등록과 달리 게이트 불요).
        buildMainMenu()

        // 첫 tick(startAppSession 안)이 cell 메트릭을 캐시했으니, 창 크기에 맞춰 cols/rows를
        // 한 번 맞춘다(80×24 기본에서 실제 창 grid로). smoke는 자체 scripted resize를 쓴다.
        if !smokeMode {
            resizeAppSessionFromWindow()
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
        // workspace를 '정상 종료'에 저장한다 — applicationWillTerminate는 크래시에선 안 불리므로(자동 충족),
        // 마지막 정상 세션만 디스크에 남는다(다음 실행이 그걸 복원, R4). shutdown '전에'(세션이 아직 살아 있을 때).
        saveWorkspace()
        // 종료 중에는 추가 tick을 돌리지 않는다. tick은 session_ended에서 NSApp.terminate를
        // 부르므로, 여기서 다시 tick하면 재진입 terminate가 된다. 마지막 counter는
        // shutdownAppSession의 close()가 summary에 담는다.
        // 종료 요약 기준 surface(메인=첫 창)를 shutdown '전에' 잡는다 — shutdownAppSession이 컬렉션을 비우므로
        // 그 뒤엔 primary(=windows.first)가 nil이 된다. surface 객체는 캡처로 살아 있어 close가 채운 요약을 읽는다.
        let mainSurface = windows.first
        shutdownAppSession()
        if let mainSurface {
            // quick 패널이 key인 채 종료해도 forwarder가 quick으로 새지 않게 메인 창을 명시 대상으로.
            withSurface(mainSurface) {
                writeSummary(visibleUI: mainSurface.window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            }
        } else {
            writeSummary(visibleUI: false, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
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
        // 닫히는 창의 일반-창 surface(quick은 delegate를 안 써 여기 안 옴). 마지막 일반 창이면 앱 종료
        // (정리·요약은 applicationWillTerminate — primary가 살아 있어야 요약이 그 세션 기준. 원래 단일 창 동작
        // 보존). 마지막이 아니면 그 창 세션만 닫고 앱은 계속한다(window는 AppKit이 이미 닫는 중).
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        if windows.count <= 1 {
            NSApp.terminate(nil)
        } else {
            teardownWindowSurface(surface)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // 그 창(notification.object)의 surface를 명시 대상으로 — 멀티 창에서 다른 창/quick이 key여도 이 창을 리사이즈.
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        withSurface(surface) {
            // drawableSize를 창에 맞춰 즉시 갱신한다(setFrameSize 경로에만 의존하지 않는다). 이게
            // 늦으면 CAMetalLayer가 옛 크기 drawable을 새 창에 스케일해 글자가 늘어나 보인다.
            metalTerminalView?.updateDrawableSize()
            // 라이브 드래그 중에는 grid resize(+PTY SIGWINCH)를 보류한다. 매 단계 SIGWINCH를 보내면
            // zsh는 상대 커서 이동(\e[A)으로 redraw하는데 reflow를 한 박자씩 못 따라와, 명령이 여러 줄로
            // 늘어나는 좁은 폭에서 프롬프트가 중복된다. 드래그가 끝나면(windowDidEndLiveResize) 최종
            // 크기로 한 번만 resize해 zsh가 한 번 redraw하게 한다(단일 resize는 reflow가 Ghostty와 일치).
            // 비-라이브(프로그램/스모크) resize는 즉시 적용한다.
            if metalTerminalView?.inLiveResize == true { return }
            resizeAppSessionFromWindow()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 창 포커스 획득 → 그 창 surface에 focus reporting(DECSET 1004 켜졌으면 CSI I). 멀티 창에서 그 창만(notification.object).
        guard let surface = surfaceForWindow(notification.object as? NSWindow), let session = surface.appSession else { return }
        _ = maru_macos_app_session_focus_changed(session, 1)
    }

    func windowDidResignKey(_ notification: Notification) {
        // 창 포커스 상실 → CSI O(focus reporting 켜졌으면). 뷰의 windowLostKey(IME 조합 커밋)와는 별개 경로/목적.
        guard let surface = surfaceForWindow(notification.object as? NSWindow), let session = surface.appSession else { return }
        _ = maru_macos_app_session_focus_changed(session, 0)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // 그 창(notification.object)의 surface를 명시 대상으로(위 windowDidResize와 같은 이유).
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        withSurface(surface) {
            metalTerminalView?.updateDrawableSize()
            resizeAppSessionFromWindow()
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
        // ARC가 NSWindow를 단독 소유하게 한다(기본 isReleasedWhenClosed=true면 close 시 AppKit이 한 번 더
        // release해, surface.window 강참조를 ARC가 release할 때 over-release 크래시가 난다). 단일 창은 close가
        // 곧 앱 종료라 안 드러났지만, 멀티 창에서 한 창만 닫으면(앱 유지) 터진다. quick 패널과 같은 가드.
        window.isReleasedWhenClosed = false
        // 창 제목을 빈 문자열로 둔다 — titleVisibility=.hidden이어도 창을 드래그(이동)하면 AppKit이 제목 텍스트를
        // 잠깐 띄우는데(특히 fullSizeContentView에서 콘텐츠 위로), 사이드바 헤더 chrome과 겹쳐 "Maru"가 떠 보였다.
        // 제목 자체를 비워 드래그 중에도 안 뜨게 한다(앱 이름은 Info.plist가 소유 — 메뉴/Dock엔 영향 없음).
        window.title = ""
        // 네이티브 타이틀바를 숨기고 신호등(닫기·최소화·확대)만 좌상단에 남긴다: 타이틀바 투명 + 제목 숨김 +
        // fullSizeContentView로 콘텐츠(사이드바)가 창 top까지 차오르게 한다. 사이드바 헤더 chrome이 신호등 영역에
        // 정렬한다(maru Zig+GPU chrome 전략 — 네이티브 뷰 없이 직접 그림). 베이스: 모던 macOS 표준 패턴. 외부
        // 터미널은 동작 형태만 참고했고 산출물은 Maru 독립 설계다(docs/macos-app-host-boundary.md).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)

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

    // app session이 노출한 최신 Metal frame을 창의 CAMetalLayer에 그린다. generation이 바뀐
    // frame(새 output/resize)에서만 atlas를 갱신하고 다시 그린다. idle tick은 마지막으로
    // present한 frame을 그대로 둔다.
    private func drawMetalFrame() {
        guard let appSession, let renderer = metalRenderer,
              let view = metalTerminalView, let metalLayer = view.metalLayer else {
            return
        }
        var frame = MaruAppHostMetalFrame()
        guard maru_macos_app_session_metal_frame(appSession, &frame) == Self.statusOK else {
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
        // 제목줄 진단(MARU_DEBUG)에 쓰도록 cell 픽셀 크기를 기록한다. grid 계산은 Zig app
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
            frame.sidebar_slot_height_px, // 탭 슬롯 높이(≈2.5×cell) — 사이드바 셀 세로 배치
            frame.sidebar_header_height_px, // 상단 헤더(검색바·아이콘) 높이 — 사이드바 셀을 이만큼 아래로
            frame.gpu_quads,              // C4b: chrome rich 둥근 사각형(tui면 NULL — Swift는 패스스루만)
            frame.gpu_quad_count,
            frame.modal_cells_start,      // C4b 모달: over quad를 모달 텍스트 앞에 끼우는 분할점(패스스루)
            frame.gpu_shadows,            // C4b: chrome 그림자(tui/모달 닫힘이면 NULL — 패스스루만)
            frame.gpu_shadow_count,
            frame.gpu_images,             // kitty graphics(K2): 이미지 placement(없으면 NULL — 패스스루만)
            frame.gpu_image_count,
            frame.image_uploads,          // kitty graphics(K2): 텍스처 업로드(generation 바뀐 것만)
            frame.image_upload_count,
            frame.image_pixels,           // kitty graphics(K2): 업로드 픽셀 연속 버퍼
            frame.image_pixel_count,
            frame.live_image_ids,         // kitty graphics(K4c): 살아있는 이미지 id 집합(없는 텍스처 evict)
            frame.live_image_id_count,
            frame.terminal_bg             // 화면 clear color(OSC 11 배경 set 또는 theme.background; 0=기본 clear)
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

    // backing scale(Retina) 변경 시 app session에 resize를 다시 보낸다. 그래야 app session이
    // 새 scale로 glyph를 rasterize하고 cell 메트릭을 device 해상도에 맞춘다. 런치 시점에
    // backingScaleFactor가 아직 1.0이고 창이 Retina로 정착하며 바뀌는 경우를 잡는다.
    func handleBackingScaleChange(in view: NSView) {
        guard !smokeMode else { return }
        // backing scale 변경은 그 변경이 일어난 '뷰의' 창(=surface)을 대상으로 resize해야 한다 — quick 뷰가
        // fire했는데 primary가 key면(또는 반대) activeSurface가 엉뚱한 surface를 고를 수 있으므로 명시한다.
        withSurface(surfaceForView(view)) {
            resizeAppSessionFromWindow()
        }
    }

    /// 활성 surface(forwarder 대상)에 app session을 만들어 붙인다 — 앱-전역 tick은 안 부른다(호출자가 정한다:
    /// launch는 startAppSession이 tickAppSession을, New Window 팩토리는 그 창만 renderTick). 일반 창은 full chrome.
    private func createSessionForActiveSurface(smokeMode: Bool) -> Bool {
        // 셸 PTY를 처음부터 실제 창 크기로 띄우도록 backing px+scale을 넘긴다(80×24 기본 spawn→resize 핸드셰이크
        // 제거 → zsh 첫 프롬프트 PROMPT_EOL_MARK % 잔상 방지). 창이 아직 레이아웃 전이면 (0,0,0)이라 Zig가 cols/rows로
        // 폴백한다(smoke는 자체 scripted resize라 0으로 두고 80×24 유지). cols/rows는 0 폴백 시 winsize·grid 단일 출처.
        let m = smokeMode ? (widthPx: UInt32(0), heightPx: UInt32(0), scaleMilli: UInt32(0)) : spawnMetricsForCurrentWindow()
        var config = MaruAppHostSessionConfig(
            abi_version: MARU_MACOS_APP_HOST_ABI_VERSION,
            cols: 80,
            rows: 24,
            queue_capacity: 16,
            command_kind: UInt32(
                smokeMode
                    ? MaruAppHostCommandControlledSmoke.rawValue
                    : MaruAppHostCommandInteractiveShell.rawValue
            ),
            chrome_minimal: 0, // 일반 창은 항상 full chrome(사이드바·탭 바)
            minimal_tabs: 0, // full이라 무시됨(탭은 항상 동작)
            width_px: m.widthPx,
            height_px: m.heightPx,
            scale_milli: m.scaleMilli
        )
        var session: OpaquePointer?
        let status = maru_macos_app_session_create(&config, &session)
        appSessionStatus = status
        guard status == Self.statusOK, let created = session else {
            appSession = nil
            return false
        }
        appSession = created
        return true
    }

    private func startAppSession(smokeMode: Bool) -> Bool {
        guard createSessionForActiveSurface(smokeMode: smokeMode) else {
            exitCode = 1 // launch 경로의 세션 생성 실패는 비정상 종료(New Window 팩토리 실패는 exitCode를 더럽히지 않음)
            return false
        }
        tickAppSession()
        return true
    }

    /// 새 일반 터미널 창(+ 세션 + 렌더러)을 만든다 — File > New Window / ⌘N. quick 생성 경로와 같은 패턴이지만
    /// 일반 창(titled, full chrome, 컨트롤러가 window-delegate). 컬렉션에 append하고 즉시 한 번 그린다. smoke는
    /// 단일 창이라 무동작. 세션 생성 실패면 만든 창/렌더러를 정리한다.
    @objc private func newTerminalWindow(_ sender: Any?) {
        _ = sender
        guard !smokeMode else { return }
        _ = createTerminalWindow(applyingWorkspace: nil)
    }

    /// 새 일반 창(+세션+렌더러)을 만든다. 성공하면 true. 실패 시 만든 것을 정리한다. 복원할 창이면 (전체 텍스트,
    /// 창 인덱스)를 받아 세션 생성 직후 그 인덱스의 창을 적용해 탭/split/Term을 복원한다(R4b) — 포맷 파싱은
    /// Zig ABI가 소유한다(Swift는 'window ' 경계를 분할하지 않음).
    @discardableResult
    private func createTerminalWindow(applyingWorkspace ws: (text: String, index: Int)?) -> Bool {
        let surface = TerminalSurface()
        windows.append(surface)
        var ok = false
        withSurface(surface) {
            let window = makePlaceholderWindow()
            self.window = window // forwarder → surface(명시 대상)
            window.delegate = self
            window.center()
            // 여러 창이 정확히 겹치지 않게 생성 순서대로 살짝 cascade.
            let offset = CGFloat((windows.count - 1) * 26)
            window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            setupMetalRenderer()
            guard createSessionForActiveSurface(smokeMode: false) else { return }
            if let ws { applyWorkspaceWindow(ws.text, ws.index) } // 복원: 기본 탭을 이 창의 탭/split/Term으로 교체
            resizeAppSessionFromWindow()
            _ = renderTick() // 즉시 첫 paint(다음 timer tick을 안 기다림)
            ok = true
        }
        if !ok {
            // 실패: 세션/렌더러 정리 + 창 닫기 + 컬렉션 제거(delegate를 끊어 windowWillClose 재진입 방지).
            teardownWindowSurface(surface)
            surface.window?.delegate = nil
            surface.window?.close()
            surface.window = nil
        }
        return ok
    }

    /// 활성 surface(forwarder 대상)의 세션에 workspace **전체 텍스트**의 window_index번째 창을 적용한다 — 헤더
    /// 포함 전체를 그대로 ABI에 넘긴다(창 경계 분할은 Zig가 소유). best-effort라 실패해도 세션은 기본 단일 탭을
    /// 유지하지만, **적용 성공 여부를 반환**해 호출자가 사용자에게 알릴 수 있게 한다(파싱은 됐어도 spawn 실패 등).
    @discardableResult
    private func applyWorkspaceWindow(_ text: String, _ index: Int) -> Bool {
        guard let session = appSession else { return false }
        let bytes = Array(text.utf8)
        let status = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_apply_workspace_window(session, buf.baseAddress, buf.count, index)
        }
        return status == Self.statusOK
    }

    /// 시작 시 저장된 workspace를 복원한다(R4b). Zig가 창 개수를 세고(헤더·포맷 검증 겸함), 창 0을 primary에,
    /// 나머지를 새 창에 인덱스로 적용한다. 저장 없음·복원 off·smoke·손상(count<=0)이면 무동작(기본 단일 창 유지).
    private func restoreWorkspace() {
        guard !smokeMode else { return }
        // 끄기(임시): config 토글은 후속. 기본은 ON. 이 플래그는 saveWorkspace도 막는다 — 복원을 끈 사용자의 저장
        // 파일을 종료 시 덮어쓰지 않게(persistence 자체 off).
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return }
        guard let session = primary?.appSession, let text = loadWorkspaceText() else { return }
        let bytes = Array(text.utf8)
        let count = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_workspace_window_count(session, buf.baseAddress, buf.count)
        }
        if count < 0 {
            // -1=파싱 실패(헤더 불일치·직렬화 포맷 변경·손상). 저장 파일을 복원할 수 없으니 **조용히 기본 단일 창으로
            // 시작**한다(notice 안 띄움 — 사용자 결정). 특히 직렬화 포맷이 바뀌면(하위호환 미고려 정책) 이전 버전의
            // 저장 파일이 이 경로로 떨어지는데, 이를 '손상' 모달로 알리면 업데이트 후 첫 실행마다 키를 막는 중앙
            // 팝업이 떠 UX가 나쁘다(복원 불가는 사용자 잘못이 아니다). 저장본은 종료 시 saveWorkspace가 새 포맷으로
            // 덮어쓸 때까지 보존된다(self-heal). 빈 workspace(count==0)와 동일하게 조용히 기본 창으로 시작한다.
            return
        }
        guard count > 0 else { return } // 0=빈 workspace → 기본 단일 창(알림 없음)
        // primary(창 0) 적용 성공 여부를 잡는다 — count>0이라 헤더는 파싱됐어도 창 블록이 spawn 실패 등으로 적용
        // 안 될 수 있다(손상 count<0과 다른 실패 모드). 실패하면 아래에서 Notice로 알린다(예전엔 상태값을 버려 무알림).
        var primaryApplied = false
        withSurface(primary) { primaryApplied = applyWorkspaceWindow(text, 0) }
        for i in 1..<Int(count) {
            createTerminalWindow(applyingWorkspace: (text, i))
        }
        if !primaryApplied {
            showNotice("저장된 작업 공간을 일부만 복원했습니다 — 기본 창으로 시작합니다.")
        }
        // 복원으로 grid·레이아웃이 바뀌었으니 primary를 창에 다시 맞추고 즉시 repaint한다 — 추가 창은
        // createTerminalWindow가 renderTick하지만 primary는 안 그래서, 기본 레이아웃이 한 프레임 깜빡이는 걸 막는다.
        // (showNotice의 metal_dirty도 이 renderTick이 그린다.)
        withSurface(primary) {
            resizeAppSessionFromWindow()
            _ = renderTick()
        }
    }

    /// chrome Notice 모달(손상 알림 등)을 primary 세션에 띄운다. 메시지는 UTF-8로 Zig에 넘긴다(세션이 복사 소유라
    /// 호출 뒤 bytes는 해제돼도 안전). 다음 renderTick이 최상위 오버레이로 그린다. 세션 없으면 무동작.
    private func showNotice(_ message: String) {
        guard let session = primary?.appSession else { return }
        let bytes = Array(message.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_show_notice(session, buf.baseAddress, buf.count)
        }
    }

    /// workspace.v1 raw 텍스트를 읽는다(관대 UTF-8 디코드 — 깨진 바이트는 U+FFFD). 없으면 nil. 헤더 검증·창 분할은
    /// Zig ABI가 한다(파싱 권위 단일화) — 여기선 포맷을 파싱하지 않는다.
    private func loadWorkspaceText() -> String? {
        guard let url = workspaceFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 한 일반 창의 세션·렌더러를 닫고(요약은 surface.latestFrameSummary에 남긴다) 컬렉션에서 뺀다. NSWindow는
    /// 건드리지 않는다 — windowWillClose는 이미 닫히는 중이고, 그 외 경로(tick 셸 종료·팩토리 실패)는 호출자가
    /// delegate를 끊고 window를 닫는다(재진입 없이). 앱 quit에선 shutdownAppSession이 남은 창마다 순회 호출.
    private func teardownWindowSurface(_ surface: TerminalSurface) {
        if let session = surface.appSession {
            var summary = MaruAppHostFrameSummary()
            let status = maru_macos_app_session_close(session, &summary)
            surface.appSessionStatus = status
            if status == Self.statusOK { surface.latestFrameSummary = summary } else { exitCode = 1 }
            maru_macos_app_session_destroy(session)
            surface.appSession = nil
        }
        if let renderer = surface.metalRenderer {
            maru_metal_renderer_destroy(renderer)
            surface.metalRenderer = nil
        }
        windows.removeAll { $0 === surface }
    }

    /// 셸 종료/fault로 한 창을 닫는다(tick 경로). 마지막 일반 창이면 앱 종료(정리·요약은 applicationWillTerminate —
    /// 원래 단일 창 동작 보존), 아니면 그 창만 정리하고 닫는다(앱은 계속).
    private func closeWindowOrQuit(_ surface: TerminalSurface) {
        if windows.count <= 1 {
            // 마지막 창 → 앱 종료. 추가 tick이 재진입 terminate를 부르지 않게 타이머를 먼저 멈춘다(정리·요약은
            // applicationWillTerminate가 — primary가 살아 있어야 요약이 그 세션 기준. 원래 SessionEnded 경로의 안전장치).
            tickTimer?.invalidate()
            tickTimer = nil
            smokeTimer?.invalidate()
            smokeTimer = nil
            NSApp.terminate(nil)
        } else {
            teardownWindowSurface(surface)
            surface.window?.delegate = nil // close가 windowWillClose를 다시 부르지 않게
            surface.window?.close()
            surface.window = nil
        }
    }

    private func startFrameLoopTicks() {
        tickTimer?.invalidate()
        // Swift는 frame pacing만 정한다. PTY queue drain, SurfaceRuntime 적용,
        // RenderFrame 준비는 모두 Zig FrameLoop.tick이 소유한다.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Timer 콜백은 main run loop(main thread)에서 실행되고 이 controller는 @MainActor다.
            // Task로 감싸면 매 tick(30/sec)마다 async hop과 할당이 생기므로 main에서 바로 호출한다.
            MainActor.assumeIsolated {
                self?.tickAppSession()
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
        guard !debugEnabled, let window, let session = appSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_session_window_title(session, &ptr, &len) == Self.statusOK else { return }
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
    // explicitSurface로 지정해, 세션별 forwarder(window/appSession/메트릭/draw)가 그 surface를 대상으로 돈다.
    private func tickAppSession() {
        guard !windows.isEmpty else { return }

        // 일반 창들을 순회 tick(컬렉션 변형은 루프 뒤에서 — closeWindowOrQuit이 windows를 바꾸므로). 셸이 정상
        // 종료(SessionEnded)/fault면 그 창을 닫되, 마지막 일반 창이면 앱 종료(D4 — closeWindowOrQuit이 판정).
        let snapshot = windows
        var toClose: [TerminalSurface] = []
        for surface in snapshot {
            explicitSurface = surface
            let status = renderTick()
            explicitSurface = nil
            if status == Self.statusOK {
                // 첫(메인) 창의 첫 tick에 launch 진단 요약을 한 번 남긴다.
                if surface === windows.first, surface.latestFrameSummary.frame_loop_ticks <= 1 {
                    withSurface(surface) {
                        writeSummary(visibleUI: surface.window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
                    }
                }
                continue
            }
            // SessionEnded는 우아한 종료(exitCode 0 유지), 그 외(tick_failed 등)는 세션 fault라 exitCode 1.
            if status != Self.statusSessionEnded { exitCode = 1 }
            toClose.append(surface)
        }
        // 닫을 창 처리(마지막 창이면 앱 종료 — 그 경우 아래 quick tick은 건너뛴다).
        for surface in toClose { closeWindowOrQuit(surface) }
        if windows.isEmpty { return }

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
    // explicitSurface로 대상을 정한다. 앱-전역 정책(SessionEnded 종료·summary)은 호출자(tickAppSession)가 한다.
    private func renderTick() -> Int32 {
        guard let appSession else { return Self.statusOK }
        updateDiagnosticTitle()
        updateWindowTitle() // 비-debug일 때 OSC 0/2 제목 또는 cwd basename을 제목줄에 반영

        // backing scale이 런치 후 늦게 정착/변경되면 device_scale이 옛 값에 머문다. 변했을 때만 resize.
        if !smokeMode, let window {
            let scale = window.backingScaleFactor
            if scale != lastSentBackingScale {
                resizeAppSessionFromWindow()
            }
        }

        var summary = MaruAppHostFrameSummary()
        let status = maru_macos_app_session_tick(appSession, &summary)
        appSessionStatus = status
        if status == Self.statusOK {
            latestFrameSummary = summary
            // metal frame이 바뀌었거나(generation) surface 재칠이 필요할 때만 그린다.
            if summary.metal_generation != lastSeenMetalGeneration || metalNeedsRedraw {
                lastSeenMetalGeneration = summary.metal_generation
                drawMetalFrame()
            }
            drainOsc52Clipboard() // OSC 52: 이번 tick에 셸이 보낸 클립보드 쓰기를 NSPasteboard에 반영(정책 gate는 Zig).
            drainNotification() // OSC 9/777: 이번 tick에 셸이 보낸 데스크톱 알림을 네이티브 알림으로 띄운다.
            drainBell() // G12 BEL: 이번 tick에 셸이 보낸 벨(0x07)을 시스템 벨로 울린다.
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
        if event.modifierFlags.contains(.shift), let session = appSession {
            if event.keyCode == 116 { // PageUp -> 과거(위)
                _ = maru_macos_app_session_scroll_page(session, 1)
                markMetalNeedsRedraw()
                return
            }
            if event.keyCode == 121 { // PageDown -> 현재(아래)
                _ = maru_macos_app_session_scroll_page(session, -1)
                markMetalNeedsRedraw()
                return
            }
        }
        // Cmd+↑/↓: OSC 133 프롬프트 블록으로 점프(이전/다음 명령의 프롬프트로 뷰포트 이동). 분류·이동은
        // Zig core가 하고 여기선 방향만 넘긴다. 셸 통합이 없으면 core가 false라 아무 일도 안 일어난다.
        if chordMods == .command, let session = appSession {
            if event.keyCode == 126 { // Up -> 이전(과거) 프롬프트
                _ = maru_macos_app_session_jump_prompt(session, -1)
                markMetalNeedsRedraw()
                return
            }
            if event.keyCode == 125 { // Down -> 다음(최근) 프롬프트
                _ = maru_macos_app_session_jump_prompt(session, 1)
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
    // scrollingDeltaY>0이면 위(과거)로 본다 — 표준 터미널 방향. scrollingDeltaX는 그 pane 탭 바 가로 스크롤(Zig가 셀 환산·라우팅).
    func handleScroll(_ event: NSEvent, in view: NSView) {
        guard let session = appSession else { return }
        // 마우스 위치를 backing 픽셀(좌상단 원점)로 — Zig가 커서 아래 panel로 스크롤을 라우팅한다(split).
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        _ = maru_macos_app_session_scroll_wheel(
            session,
            Double(event.scrollingDeltaY),
            Double(event.scrollingDeltaX),
            event.hasPreciseScrollingDeltas ? 1 : 0,
            xPx,
            yPx
        )
        markMetalNeedsRedraw()
    }

    // NSView 로컬 좌표(좌하단 원점)를 backing(device) 픽셀(좌상단 원점)로 환산한다 — Zig 좌표 규약.
    // scale·y 뒤집기 공식의 단일 출처(handleMouse·handleMouseMotion·updateHover 공용 — 규약이 바뀌면 여기만 고친다).
    private func backingPx(_ local: NSPoint, in view: NSView) -> (x: Double, y: Double) {
        let scale = window?.backingScaleFactor ?? 1.0
        return (Double(local.x * scale), Double((view.bounds.height - local.y) * scale))
    }

    // NSEvent 모디파이어 → xterm mods 비트(4=shift, 8=opt/meta, 16=ctrl). mouse reporting(handleMouse·handleMouseMotion) 공용.
    private func modsBits(_ event: NSEvent) -> Int32 {
        var mods: Int32 = 0
        if event.modifierFlags.contains(.shift) { mods |= 4 }
        if event.modifierFlags.contains(.option) { mods |= 8 }
        if event.modifierFlags.contains(.control) { mods |= 16 }
        return mods
    }

    // 마우스 좌표를 backing 픽셀(좌상단 원점)로 환산해 Zig 선택 모델에 넘긴다(kind 1=down/2=drag/3=up).
    func handleMouse(_ event: NSEvent, kind: Int32, in view: NSView) {
        guard let session = appSession else { return }
        let (xPx, yPx) = backingPx(view.convert(event.locationInWindow, from: nil), in: view)
        // macOS buttonNumber(0=L,1=R,2=M) → xterm(0=L,1=M,2=R).
        let button: Int32 = event.buttonNumber == 1 ? 2 : (event.buttonNumber == 2 ? 1 : 0)
        _ = maru_macos_app_session_mouse(session, kind, xPx, yPx, button, modsBits(event))
        markMetalNeedsRedraw()
    }

    // 버튼 없는 마우스 이동을 mouse reporting(DECSET 1003 any-event)으로 PTY에 흘린다. Zig가 트래킹 모드를
    // 확인해 1003일 때만 리포트하고(아니면 no-op) 같은 셀 반복은 스킵한다. handleHover(Cmd+링크)와 병행 호출된다.
    // markMetalNeedsRedraw는 부르지 않는다 — 리포트는 PTY로 나가고 화면 dirty는 앱 출력에 따라 Zig가 세운다.
    func handleMouseMotion(_ event: NSEvent, in view: NSView) {
        guard let session = appSession else { return }
        let (xPx, yPx) = backingPx(view.convert(event.locationInWindow, from: nil), in: view)
        maru_macos_app_session_mouse_moved(session, xPx, yPx, modsBits(event))
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
        guard let session = appSession else { return }
        let local = view.convert(windowPoint, from: nil)
        // 포인터가 view 밖(타이틀바·다른 뷰 위)이면 hover를 강제하지 않는다 — 시스템/이웃 커서를
        // iBeam으로 덮어쓰지 않게. 밑줄도 해제한다.
        guard view.bounds.contains(local) else {
            clearHover()
            return
        }
        let (xPx, yPx) = backingPx(local, in: view)
        // Zig가 위치별 커서 종류를 판정해 돌려준다(CursorKind). Swift는 그 값을 NSCursor로 매핑만 한다 —
        // 전부 iBeam이던 걸 영역별로(사이드바·탭 바=arrow, divider=resize, 터미널=iBeam, URL=pointingHand).
        var cursorKind: Int32 = 1
        guard maru_macos_app_session_hover(session, xPx, yPx, cmdHeld ? 1 : 0, &cursorKind) == Self.statusOK else { return }
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
        guard let session = appSession else { return }
        var cursorKind: Int32 = 0
        // 음수 좌표 sentinel: Zig가 사이드바 영역 밖(x<0)·터미널 셀 밖으로 보고 URL 밑줄과 사이드바 슬롯
        // 호버를 모두 해제한다((0,0)은 사이드바 슬롯 0으로 오인될 수 있어 못 쓴다). 커서는 arrow로(뷰 밖).
        _ = maru_macos_app_session_hover(session, -1, -1, 0, &cursorKind)
        NSCursor.arrow.set()
    }

    // Cmd+클릭: Zig가 인식한 URL을 기본 브라우저로 연다(NSWorkspace는 OS 소유 경계).
    func handleCommandClick(_ event: NSEvent, in view: NSView) {
        guard let session = appSession else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_session_url_at(session, xPx, yPx, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        guard let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func pastePasteboardText() {
        // Cmd+V 붙여넣기. 베이스/결정: Ghostty getOpinionatedStringContents 동작(동작 비교만 — 코드 표현은 옮기지
        // 않은 독립 구현). NSURL이 있으면 **파일 URL은 경로를 셸 이스케이프**(셸이 공백에서 단어를 쪼개지 않게),
        // **그 외(웹) URL은 absoluteString 그대로**(이스케이프하면 붙여넣은 URL이 깨진다), URL 표현이 없으면 평문
        // 텍스트. 이로써 텍스트·웹 URL·파일 클립보드가 모두 자연스럽게 붙는다. 드래그(handleDrop)는 사용자 제스처라
        // 웹 URL도 이스케이프하는 별도 정책(pasteboardDropContent)이라 분리한다.
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            var parts: [String] = []
            for url in urls {
                parts.append(url.isFileURL ? Self.shellEscape(url.path) : url.absoluteString)
            }
            sendPasteText(parts.joined(separator: " "))
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendPasteText(text)
        }
    }

    /// 드롭된 pasteboard 내용(경로/URL/텍스트)을 삽입한다 — 뷰(MaruMetalTerminalView.performDragOperation)가 위임한다.
    /// 드롭은 사용자 제스처라 URL/파일을 모두 이스케이프하는 pasteboardDropContent로 추출한다(Cmd+V paste는 웹 URL을
    /// 이스케이프하지 않는 별도 추출 — pastePasteboardText). 전송은 **paste 경로**(sendPasteText)다 — Ghostty도 드래그를
    /// completeClipboardPaste로 보내 터미널이 DECSET 2004를 켜면(Claude Code 등 TUI) bracketed paste로 감싸지고, 그래야
    /// 경로가 한-덩어리로 인식돼 [Image]로 첨부된다. 2004를 안 켠 일반 셸에선 raw(개행만 \r)라 escape된 경로가 안전하다. 삽입할 게 있으면 true.
    func handleDrop(_ pb: NSPasteboard) -> Bool {
        guard let content = pasteboardDropContent(pb) else { return false }
        sendPasteText(content)
        return true
    }

    /// 드래그/클립보드에서 삽입할 내용을 뽑는다. 우선순위는 Ghostty 드롭과 동일하다(베이스):
    /// URL > 파일 URL(각 경로를 셸 이스케이프 후 공백으로 join) > 평문(이스케이프 안 함 — 실행할 명령일 수 있음).
    private func pasteboardDropContent(_ pb: NSPasteboard) -> String? {
        if let url = pb.string(forType: .URL) {
            return Self.shellEscape(url)
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    /// 셸 버퍼에 경로를 넣을 때 셸이 공백 등에서 단어를 쪼개지 않게 메타문자 앞에 백슬래시를 붙인다(평문 paste·웹
    /// URL엔 적용 안 함). 대상 집합은 POSIX 셸 메타문자 기준이고, 동작은 Ghostty Shell.escape와 같다(동작 비교만 —
    /// 코드 표현은 옮기지 않는다). 원본을 한 번만 순회하며 메타문자면 백슬래시를 앞세워 새 문자열을 만든다 — 누적
    /// 결과를 재스캔하지 않아 중복 이스케이프·문자 순서 의존이 없다.
    private static let shellEscapeChars: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]
    private static func shellEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if shellEscapeChars.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// 텍스트를 paste 경로로 PTY에 보낸다 — **bracketed paste**(DECSET 2004) 감싸기·개행 정규화는 Zig 소유.
    /// Cmd+V paste와 드래그앤드롭 공용(Ghostty도 드래그를 paste 경로 completeClipboardPaste로 보낸다).
    private func sendPasteText(_ text: String) {
        guard let session = appSession, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_paste_text(session, buf.baseAddress, buf.count)
        }
    }

    private func copySelectionToPasteboard() {
        guard let session = appSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_session_copy_text(session, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // OSC 52: 코어가 디코드한 클립보드 쓰기 데이터를 활성 세션에서 drain해 NSPasteboard에 쓴다(매 tick).
    // write는 정책상 기본 allow(terminal-compatibility-policy.md §OSC52). 데이터 없으면 Zig가 len 0을 줘 무동작.
    // Cmd+C 복사(copySelectionToPasteboard)와 같은 NSPasteboard 경로.
    private func drainOsc52Clipboard() {
        guard let session = appSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_session_pending_clipboard(session, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // OSC 9/777: 알림 권한을 한 번만 요청한다(번들 ID가 있을 때만 — bare 실행 파일은 UNUserNotificationCenter가
    // 못 떠서 graceful skip). 권한이 거부돼도 add는 무해히 무시되므로 결과는 안 본다.
    private var notificationAuthRequested = false
    private func ensureNotificationAuthorization() {
        guard !notificationAuthRequested, Bundle.main.bundleIdentifier != nil else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // OSC 9/777: 코어가 파싱한 데스크톱 알림(title/body)을 활성 세션에서 drain해 네이티브 알림으로 띄운다(매 tick).
    // 알림이 없으면 Zig가 has=0을 줘 아무 것도 안 한다. OSC 9는 title이 없어(빈 문자열) 앱 이름으로 폴백한다.
    // 번들 ID가 없으면(app shell 일부) UNUserNotificationCenter를 못 써 조용히 건너뛴다(GUI 수동 검증은 제품 앱).
    private func drainNotification() {
        guard let session = appSession else { return }
        // 권한 팝업이 알림보다 먼저 떠야 첫 알림을 놓치지 않는다 — 세션이 사는 동안 선요청한다(내부 플래그로 실제 1회만).
        // 이전엔 has!=0(알림이 실제로 올 때) 게이트 뒤에서 요청해, 프로그램이 OSC 9/777을 한 번도 안 보내면 권한 팝업조차 안 떴다.
        ensureNotificationAuthorization()
        var has: UInt32 = 0
        var titlePtr: UnsafePointer<UInt8>? = nil
        var titleLen: size_t = 0
        var bodyPtr: UnsafePointer<UInt8>? = nil
        var bodyLen: size_t = 0
        guard maru_macos_app_session_pending_notification(session, &has, &titlePtr, &titleLen, &bodyPtr, &bodyLen) == Self.statusOK,
              has != 0 else { return }
        guard Bundle.main.bundleIdentifier != nil else { return } // 번들 없으면 알림 API 사용 불가 — skip
        let title = titleLen > 0 ? String(decoding: UnsafeBufferPointer(start: titlePtr!, count: titleLen), as: UTF8.self) : ""
        let body = bodyLen > 0 ? String(decoding: UnsafeBufferPointer(start: bodyPtr!, count: bodyLen), as: UTF8.self) : ""
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "maru" : title // OSC 9는 title 없음 → 앱 이름
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // G12 BEL: 코어가 모은 벨(0x07)을 활성 세션에서 drain해 시스템 벨을 울린다(매 tick, 한 tick 1회로 합쳐짐).
    // 벨이 없으면 Zig가 0을 줘 아무 것도 안 한다.
    private func drainBell() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_bell(session) != 0 {
            NSSound.beep()
        }
    }

    // MARK: - 메뉴바 (NSMenu)

    /// command_catalog의 modifier 비트마스크(shift=1,control=2,option=4,command=8)를 NSEvent.ModifierFlags로.
    private static func modifierFlags(_ mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & 1 != 0 { flags.insert(.shift) }
        if mask & 2 != 0 { flags.insert(.control) }
        if mask & 4 != 0 { flags.insert(.option) }
        if mask & 8 != 0 { flags.insert(.command) }
        return flags
    }

    /// 표준 macOS 메뉴바(maru/File/Edit/View/Window/Help)를 프로그래매틱하게 세운다. Zig 액션 항목은 커맨드
    /// 카탈로그(command_catalog ABI)에서 제목·단축키(keyEquivalent)를 읽어 만들고 선택 시 run_action으로
    /// 디스패치한다(네이티브는 NSMenu 구성만, 카탈로그·실행 결정은 Zig — 경계). copy/paste·about/hide/quit/
    /// minimize/zoom·fullscreen은 OS 동작이라 네이티브 셀렉터. 세션-불변이라 시작 시 한 번 빌드한다.
    private func buildMainMenu() {
        // 카탈로그를 [action_key: (제목, keyEquivalent, modifier)]로 읽어 둔다(세션-불변). primary에서 읽는다
        // (제목·단축키는 모든 세션 동일). 실제 디스패치는 runCatalogAction이 활성 세션(appSession)에 한다.
        var catalog: [String: (title: String, keyEquiv: String, mods: NSEvent.ModifierFlags)] = [:]
        if let session = primary?.appSession {
            var ptr: UnsafePointer<MaruAppHostCommand>?
            var count = 0
            if maru_macos_app_session_command_catalog(session, &ptr, &count) == Self.statusOK, let base = ptr {
                for i in 0..<count {
                    let c = base[i]
                    catalog[String(cString: c.action_key)] = (
                        String(cString: c.title),
                        String(cString: c.key_equivalent),
                        Self.modifierFlags(c.key_modifiers)
                    )
                }
            }
        }

        let mainMenu = NSMenu()

        // maru(App)
        let app = NSMenu()
        app.addItem(nativeMenuItem("About maru", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: "", mods: []))
        app.addItem(.separator())
        // Open Config(⌘,) — macOS Settings 관례 자리. config 파일을 기본 편집기로 연다(경로는 Zig가 소유).
        app.addItem(nativeMenuItem("Open Config…", #selector(menuOpenConfig(_:)), key: ",", target: self))
        // Reload Config — config 파일 편집을 재시작 없이 반영(Zig가 파일 재로드·재적용). Reset to Defaults — 런타임
        // 줌/여백 변경을 프로그램 처음 실행 설정으로 복원(둘 다 단축키 없음 — 메뉴 클릭 전용, 발견성용).
        app.addItem(nativeMenuItem("Reload Config", #selector(menuReloadConfig(_:)), key: "", target: self))
        app.addItem(nativeMenuItem("Reset to Defaults", #selector(menuResetDefaults(_:)), key: "", target: self))
        // Reset Terminal(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus·mouse·kitty keyboard)만 끈다. ssh가 비정상
        // 종료해 정리 못 한 모드가 raw 셸 입력을 오염시키는 증상(포커스마다 ^[[I·비프)의 수동 회복 — 셸 통합
        // 자동 리셋이 안 닿는 타 셸·hang 복구 직후용. 화면·스크롤백은 보존(Reset to Defaults와 대상이 다르다).
        app.addItem(nativeMenuItem("Reset Terminal", #selector(menuResetTerminal(_:)), key: "r", mods: [.command, .shift], target: self))
        app.addItem(.separator())
        app.addItem(nativeMenuItem("Hide maru", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(nativeMenuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option]))
        app.addItem(nativeMenuItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), key: "", mods: []))
        app.addItem(.separator())
        app.addItem(nativeMenuItem("Quit maru", #selector(NSApplication.terminate(_:)), key: "q"))
        attachSubmenu(mainMenu, "maru", app)

        // File — New Window(⌘N)는 네이티브(NSWindow 생성은 OS 소유라 Zig in-session 액션이 아니다). new_term/
        // new_tab은 Zig 카탈로그 액션(활성 세션 안의 Term/워크스페이스).
        let file = NSMenu()
        file.addItem(nativeMenuItem("New Window", #selector(newTerminalWindow(_:)), key: "n", target: self))
        file.addItem(.separator())
        file.addItem(catalogMenuItem("new_term", catalog))
        file.addItem(catalogMenuItem("new_tab", catalog))
        file.addItem(.separator())
        file.addItem(catalogMenuItem("close_term", catalog))
        attachSubmenu(mainMenu, "File", file)

        // Edit — Select All/Clear은 Zig 액션(카탈로그), Copy/Paste는 네이티브(NSPasteboard 소유).
        let edit = NSMenu()
        edit.addItem(catalogMenuItem("select_all", catalog))
        // Clear(⌘K) — 화면+스크롤백 비우기. 카탈로그 항목이라 catalogMenuItem이 ⌘K chord를 그대로 표시·dispatch한다.
        edit.addItem(catalogMenuItem("clear_screen", catalog))
        edit.addItem(.separator())
        edit.addItem(nativeMenuItem("Copy", #selector(menuCopy(_:)), key: "c", target: self))
        edit.addItem(nativeMenuItem("Paste", #selector(menuPaste(_:)), key: "v", target: self))
        edit.addItem(.separator())
        // Find 서브메뉴 — 발견성용(클릭 동작). 단축키 ⌘F/⌘G/⌘⇧G는 Zig 키바인딩(default_app_bindings)이 소유하므로
        // 메뉴엔 keyEquivalent를 안 단다(달면 macOS가 그 키를 가로채 키바인딩을 가린다 — 모달 토글은 ⌘⇧P처럼
        // 키바인딩 전용이 maru 관례). 클릭은 runAction으로 — Find 닫힘일 때 동작(열림 중엔 모달이 키를 가짐).
        let find = NSMenu()
        find.addItem(actionMenuItem("toggle_find", catalog))
        find.addItem(actionMenuItem("find_next", catalog))
        find.addItem(actionMenuItem("find_previous", catalog))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        edit.addItem(.separator())
        // Services — 표준 macOS(선택 텍스트를 시스템 Services로). NSApp.servicesMenu가 항목을 채운다.
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        edit.addItem(servicesItem)
        NSApp.servicesMenu = services
        attachSubmenu(mainMenu, "Edit", edit)

        // View
        let view = NSMenu()
        view.addItem(catalogMenuItem("split_horizontal", catalog))
        view.addItem(catalogMenuItem("split_vertical", catalog))
        view.addItem(.separator())
        view.addItem(catalogMenuItem("focus_pane_left", catalog))
        view.addItem(catalogMenuItem("focus_pane_right", catalog))
        view.addItem(catalogMenuItem("focus_pane_up", catalog))
        view.addItem(catalogMenuItem("focus_pane_down", catalog))
        view.addItem(.separator())
        // 런타임 폰트 크기 — Bigger(⌘+)/Smaller(⌘-)/Actual Size(⌘0). 카탈로그 항목이라 keyEquivalent는
        // 바인딩 chord를 그대로 표시한다(select_all과 같은 결 — runAction으로 dispatch).
        view.addItem(catalogMenuItem("increase_font_size", catalog))
        view.addItem(catalogMenuItem("decrease_font_size", catalog))
        view.addItem(catalogMenuItem("reset_font_size", catalog))
        view.addItem(.separator())
        view.addItem(nativeMenuItem("Toggle Full Screen", #selector(menuToggleFullScreen(_:)), key: "f", mods: [.control, .command], target: self))
        attachSubmenu(mainMenu, "View", view)

        // Window
        let window = NSMenu()
        window.addItem(nativeMenuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(nativeMenuItem("Zoom", #selector(NSWindow.performZoom(_:)), key: "", mods: []))
        window.addItem(.separator())
        window.addItem(catalogMenuItem("next_tab", catalog))
        window.addItem(catalogMenuItem("previous_tab", catalog))
        window.addItem(catalogMenuItem("next_term", catalog))
        window.addItem(catalogMenuItem("previous_term", catalog))
        let windowItem = attachSubmenu(mainMenu, "Window", window)
        NSApp.windowsMenu = window
        _ = windowItem

        // Help
        let help = NSMenu()
        help.addItem(nativeMenuItem("maru Help", #selector(NSApplication.showHelp(_:)), key: "?", target: nil))
        attachSubmenu(mainMenu, "Help", help)
        NSApp.helpMenu = help

        NSApp.mainMenu = mainMenu
    }

    /// 커맨드 카탈로그의 한 action_key를 NSMenuItem으로(제목·keyEquivalent·modifier는 카탈로그, 선택 시
    /// runCatalogAction → run_action). 카탈로그에 없으면(이론상) action_key를 제목으로 단축키 없이 만든다.
    private func catalogMenuItem(_ key: String, _ catalog: [String: (title: String, keyEquiv: String, mods: NSEvent.ModifierFlags)]) -> NSMenuItem {
        let info = catalog[key]
        let item = NSMenuItem(title: info?.title ?? key, action: #selector(runCatalogAction(_:)), keyEquivalent: info?.keyEquiv ?? "")
        item.keyEquivalentModifierMask = info?.mods ?? []
        item.representedObject = key
        item.target = self
        return item
    }

    /// 네이티브 셀렉터 메뉴 항목. target=nil이면 responder chain(terminate:/performMiniaturize: 등 표준 동작),
    /// target=self면 컨트롤러의 @objc 핸들러(copy/paste/fullscreen). 기본 modifier는 ⌘.
    private func nativeMenuItem(_ title: String, _ action: Selector, key: String, mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.target = target
        return item
    }

    /// 단축키 없이 Zig 액션(key)을 호출하는 메뉴 항목 — 발견성용(Find 등). 제목은 카탈로그(단일 출처)에서 읽어
    /// catalogMenuItem과 제목이 어긋나지 않게 한다. keyEquivalent를 비워 macOS가 키를 가로채지 않게 한다(단축키는
    /// Zig 키바인딩이 소유). 클릭 시 runCatalogAction → run_action.
    private func actionMenuItem(_ key: String, _ catalog: [String: (title: String, keyEquiv: String, mods: NSEvent.ModifierFlags)]) -> NSMenuItem {
        let item = NSMenuItem(title: catalog[key]?.title ?? key, action: #selector(runCatalogAction(_:)), keyEquivalent: "")
        item.representedObject = key
        item.target = self
        return item
    }

    @discardableResult
    private func attachSubmenu(_ mainMenu: NSMenu, _ title: String, _ submenu: NSMenu) -> NSMenuItem {
        submenu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
        return item
    }

    /// 메뉴에서 고른 Zig 액션을 활성 세션에 디스패치한다 — action_key(representedObject) 바이트를 run_action으로.
    /// appSession(활성 surface)에 적용해, quick terminal이 key면 그쪽에 동작한다(메뉴는 포커스된 터미널에 작용).
    @objc private func runCatalogAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let session = appSession else { return }
        let bytes = Array(key.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_run_action(session, buf.baseAddress, buf.count)
        }
    }

    @objc private func menuCopy(_ sender: Any?) {
        _ = sender
        copySelectionToPasteboard()
    }

    @objc private func menuPaste(_ sender: Any?) {
        _ = sender
        pastePasteboardText()
    }

    /// Open Config — config 파일 경로(Zig 소유, MARU_CONFIG·$HOME/.config/maru/config)를 받아 기본 편집기로 연다.
    /// 파일이 없으면 부모 디렉터리 + 빈 파일을 만들어(파일 I/O는 OS 동작) 편집기가 새 config를 열게 한다. 연결
    /// 앱이 없으면 Finder에 표시(fallback). 경로 규칙은 Zig loader가 단일 출처라 여기선 경로 계산을 안 한다.
    @objc private func menuOpenConfig(_ sender: Any?) {
        _ = sender
        guard let session = appSession else { return }
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        guard maru_macos_app_session_config_path(session, &ptr, &len) == Self.statusOK,
              let bytes = ptr, len > 0 else { return }
        let path = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url]) // 연결 앱 없음 → Finder에 표시
        }
    }

    /// Reload Config — config 파일을 재로드해 재시작 없이 반영한다(폰트·여백·테마·palette·scrollback·bell·page-keys).
    /// 파일 재로드·파싱·재적용은 Zig가 단일 출처로 한다(forgiving — 실패 시 무동작). 여기선 활성 세션에 호출만 한다.
    @objc private func menuReloadConfig(_ sender: Any?) {
        _ = sender
        guard let session = appSession else { return }
        _ = maru_macos_app_session_reload_config(session)
    }

    /// view options에서 sidebar 토글(show-branch/show-folder)을 바꿨을 때, 갱신된 config 텍스트를 받아 config
    /// 파일에 atomic write한다(앱→config 양방향). 직렬화·경로 해석·부분 갱신(주석 보존)은 Zig가 단일 출처다.
    /// best-effort — 실패해도 런타임 토글은 이미 반영됐다(Zig가 즉시 rebuildSidebar). config 토글 UI(view
    /// options 메뉴, P4)의 accept 핸들러에서 호출한다.
    func persistSidebarConfig() {
        guard let session = appSession else { return }
        var pathPtr: UnsafePointer<UInt8>? = nil
        var pathLen: size_t = 0
        guard maru_macos_app_session_config_path(session, &pathPtr, &pathLen) == Self.statusOK,
              let pathBytes = pathPtr, pathLen > 0 else { return }
        let path = String(decoding: UnsafeBufferPointer(start: pathBytes, count: pathLen), as: UTF8.self)
        var textPtr: UnsafePointer<UInt8>? = nil
        var textLen: size_t = 0
        guard maru_macos_app_session_serialize_sidebar_config(session, &textPtr, &textLen) == Self.statusOK,
              let textBytes = textPtr, textLen > 0 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: textBytes, count: textLen), as: UTF8.self)
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Reset to Defaults — 런타임 줌(⌘+/−)·여백 변경을 프로그램 처음 실행했던 설정으로 되돌린다(appearance만 — behavior는
    /// 런타임에 안 바뀌므로 대상 아님). 복원 기준·적용은 Zig가 단일 출처로 한다. 여기선 활성 세션에 호출만 한다.
    @objc private func menuResetDefaults(_ sender: Any?) {
        _ = sender
        guard let session = appSession else { return }
        _ = maru_macos_app_session_reset_defaults(session)
    }

    /// Reset Terminal(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus 1004·mouse·kitty keyboard)만 끈다. ssh 너머 TUI가
    /// SIGKILL로 죽어 정리 못 한 모드가 raw 셸 입력을 오염시키는 증상의 수동 회복. 화면은 보존(비파괴). Zig가 단일 출처.
    @objc private func menuResetTerminal(_ sender: Any?) {
        _ = sender
        guard let session = appSession else { return }
        _ = maru_macos_app_session_reset_input_modes(session)
    }

    @objc private func menuToggleFullScreen(_ sender: Any?) {
        _ = sender
        // 메인 터미널 창만 대상으로 한다. keyWindow를 쓰면 퀵터미널 오버레이 패널(borderless,
        // .fullScreenAuxiliary)이 key일 때 그 패널을 전체화면 토글해버린다 — 패널은 전체화면 대상이 아니다.
        primary?.window?.toggleFullScreen(nil)
    }

    private func sendSmokeDevEvents() {
        // 자동 smoke는 물리 키보드나 사용자의 resize 동작을 기다릴 수 없다. 대신 같은 C ABI를
        // 직접 호출해 key/resize event가 Zig app session까지 내려가는 최소 E2E 신호를 남긴다.
        // grid는 app session이 backing 픽셀에서 계산하므로 픽셀 크기만 보낸다.
        resizeAppSession(widthPx: 1_200, heightPx: 720)
        let keyEvent = MaruAppHostKeyEvent(
            codepoint: UInt32(UnicodeScalar("a").value),
            base_codepoint: UInt32(UnicodeScalar("a").value),
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
            base_codepoint: 0,
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
        guard let appSession else {
            return
        }

        var keyEvent = event
        var summary = MaruAppHostFrameSummary()
        let status = maru_macos_app_session_key_down(appSession, &keyEvent, &summary)
        appSessionStatus = status
        // 한 key event의 실패(닫힌 pane의 late input, 변환 거부 등)는 세션 fault가 아니다.
        // 앱을 죽이지 않고 status만 기록한다. 종료 자체는 tick 경로의 session_ended가 처리한다.
        if status == Self.statusOK {
            latestFrameSummary = summary
        }
    }

    /// 현재 창의 backing 픽셀 + scale(천분율) — 세션 생성 시 셸을 처음부터 실제 크기로 spawn하는 데 쓴다
    /// (resizeAppSessionFromWindow와 같은 contentView×backingScale 계산). 창이 없거나 아직 레이아웃 전(0)이면
    /// (0,0,0)을 줘 Zig가 cols/rows로 폴백하게 한다(잘못된 0칸 grid 방지).
    private func spawnMetricsForCurrentWindow() -> (widthPx: UInt32, heightPx: UInt32, scaleMilli: UInt32) {
        guard let window, let contentView = window.contentView else { return (0, 0, 0) }
        let bounds = contentView.bounds
        let scale = window.backingScaleFactor
        let w = clampedUInt32(bounds.width * scale)
        let h = clampedUInt32(bounds.height * scale)
        if w == 0 || h == 0 { return (0, 0, 0) } // 레이아웃 전 — 폴백(cols/rows)
        return (w, h, clampedUInt32(scale * 1_000))
    }

    private func resizeAppSessionFromWindow() {
        guard let window, let contentView = window.contentView else {
            return
        }

        let bounds = contentView.bounds
        let scale = window.backingScaleFactor
        // grid(cols/rows)는 Zig app session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다.
        // Swift는 창의 backing 픽셀만 모아 넘긴다(cell 크기·floor·placeholder 계산을 들고 있지
        // 않으므로, 메트릭이 준비되기 전 placeholder로 grid를 잘못 잡는 일이 없다).
        let widthPx = clampedUInt32(bounds.width * scale)
        let heightPx = clampedUInt32(bounds.height * scale)
        resizeAppSession(widthPx: widthPx, heightPx: heightPx)
    }

    private func resizeAppSession(widthPx: UInt32, heightPx: UInt32) {
        guard let appSession else {
            return
        }

        let scaleMilli = clampedUInt32((window?.backingScaleFactor ?? 1.0) * 1_000)
        // 같은 size+scale 중복 resize 방지(SIGWINCH storm)와 grid 계산 모두 Zig app session이
        // 한 곳에서 처리한다. Swift는 매번 backing 픽셀+scale만 보내고, app session이 변화 없으면
        // 비싼 재작업을 건너뛴다. tick의 scale-변화 감지용으로 보낸 backing scale만 기록한다.
        lastSentBackingScale = window?.backingScaleFactor ?? 1.0

        // cols/rows는 app session이 무시하고 backing 픽셀에서 계산하므로 0으로 둔다.
        var event = MaruAppHostResizeEvent(
            width_px: widthPx,
            height_px: heightPx,
            scale_milli: scaleMilli,
            cols: 0,
            rows: 0,
            reserved: 0
        )
        var summary = MaruAppHostFrameSummary()
        let status = maru_macos_app_session_resize(appSession, &event, &summary)
        appSessionStatus = status
        // 한 resize event의 실패(닫히는 창의 late resize 등)도 세션 fault가 아니므로 앱을
        // 죽이지 않고 status만 기록한다.
        if status == Self.statusOK {
            latestFrameSummary = summary
        }
    }

    // IME 키 트랜잭션: begin -> 입력기 해석(클로저) -> end. 판정은 전부 Zig가 한다.
    func imeKeyTransaction(_ event: NSEvent, interpret: () -> Void) {
        guard let session = appSession else { return }
        _ = maru_macos_app_session_ime_begin(session)
        interpret()
        // ime_end는 정규화 실패(codepoint/keyCode 없음)에도 반드시 호출한다 — 안 그러면 ime_begin
        // 후 트랜잭션이 안 닫혀 누적 텍스트가 유실되고 ime_active가 박힌다. 키가 없으면 nil 전달.
        if var keyEvent = normalizedKeyEvent(from: event) {
            _ = maru_macos_app_session_ime_end(session, &keyEvent)
        } else {
            _ = maru_macos_app_session_ime_end(session, nil)
        }
    }

    func imeInsert(_ text: String) {
        guard let session = appSession else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_ime_insert(session, buf.baseAddress, buf.count)
        }
    }

    func imeMarked(_ text: String) {
        guard let session = appSession else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_ime_marked(session, buf.baseAddress, buf.count)
        }
    }

    func imeDeleteBackward() {
        guard let session = appSession else { return }
        _ = maru_macos_app_session_ime_delete_backward(session)
    }

    func imeFocus(_ focused: Bool) {
        guard let session = appSession else { return }
        _ = maru_macos_app_session_set_focus(session, focused ? 1 : 0)
    }

    // 진행 중 IME 조합을 확정한다(IME 우회 특수키/단축키 직전). core preedit를 커밋·비운다.
    func imeCommit() {
        guard let session = appSession else { return }
        _ = maru_macos_app_session_commit_composition(session)
    }

    // IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). 화면 좌표 변환은 view가 한다.
    func imeCursorRectPx() -> (Double, Double, Double, Double)? {
        guard let session = appSession else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        guard maru_macos_app_session_ime_cursor_rect(session, &x, &y, &w, &h) == Self.statusOK else { return nil }
        return (x, y, w, h)
    }

    private func normalizedKeyEvent(from event: NSEvent) -> MaruAppHostKeyEvent? {
        var codepoint: UInt32 = 0
        var baseCodepoint: UInt32 = 0
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
            // kitty CSI u의 key code용 base-layout codepoint(shift 미반영). characters(byApplyingModifiers:[])는
            // 어떤 modifier도 안 누른 base 문자라, Ctrl+Shift+A에서 'A'가 아닌 'a'를 준다. dead key/조합 등
            // 다중 scalar는 0으로 둬 Zig가 codepoint로 폴백하게 한다.
            if let baseChars = event.characters(byApplyingModifiers: []),
               baseChars.unicodeScalars.count == 1,
               let baseScalar = baseChars.unicodeScalars.first {
                baseCodepoint = baseScalar.value
            }
        }

        let flags = event.modifierFlags
        return MaruAppHostKeyEvent(
            codepoint: codepoint,
            base_codepoint: baseCodepoint,
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
        guard let session = appSession else { return }
        var ptr: UnsafePointer<MaruAppHostGlobalHotkey>?
        var count = 0
        let status = maru_macos_app_session_global_hotkeys(session, &ptr, &count)
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
        // 슬라이드/페이드(0.12~0.16s) 중에는 토글을 무시한다 — 안 그러면 애니메이션이 겹쳐, 먼저 시작한 hide의
        // 완료 핸들러(orderOut)가 그 사이 새로 show한 패널을 닫아 버리는 race가 생긴다(애니메이션이 끝나
        // quickAnimating이 풀린 뒤 다시 토글하면 된다). quickTerminalLostKey(자동 숨김)의 가드와 같은 패턴.
        if quickAnimating { return }
        if let quick, quick.window?.isVisible == true {
            if let panel = quick.window { hideQuickTerminalAnimated(panel) }
            return
        }
        ensureQuickTerminal()
        guard let panel = quick?.window else { return }
        showQuickTerminalAnimated(panel)
    }

    /// quick terminal surface를 lazy 생성한다(첫 토글). 두 번째 app session(대화형 셸) + borderless 패널 +
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
        var minimalTabs: UInt32 = 0
        if let cfg = loadQuickTerminalConfig() {
            quickHeightFraction = max(0.1, min(1.0, CGFloat(cfg.height_milli) / 1000.0))
            quickWidthFraction = CGFloat(cfg.width_milli) / 1000.0 // 0이면 미설정(center에서 height로 폴백). Zig가 0.1~1.0 검증.
            quickAutoHide = cfg.auto_hide != 0
            quickScreenMode = cfg.screen
            quickPosition = cfg.position
            chromeMinimal = (cfg.chrome == UInt32(MaruAppHostQuickTerminalChromeMinimal.rawValue)) ? 1 : 0
            minimalTabs = cfg.minimal_tabs // minimal에서 탭 허용 여부(Zig가 dispatch에서 게이트)
        }

        // 두 번째 app session(대화형 셸) — 메인과 독립된 PTY. minimal이면 chrome_minimal=1로 사이드바·탭 바를 끄고,
        // minimal_tabs로 그 minimal 세션의 ⌘T/⌘⇧T 허용 여부를 정한다.
        var config = MaruAppHostSessionConfig(
            abi_version: MARU_MACOS_APP_HOST_ABI_VERSION,
            cols: 80,
            rows: 24,
            queue_capacity: 16,
            command_kind: UInt32(MaruAppHostCommandInteractiveShell.rawValue),
            chrome_minimal: chromeMinimal,
            minimal_tabs: minimalTabs,
            // quick 패널은 크기·배치가 특수(슬라이드 패널)라 0으로 두고 생성 직후 resize에 맡긴다(80×24→실제). 메인 창
            // 첫 프롬프트 % 잔상이 보고된 케이스라 거기만 spawn-크기를 채운다(quick은 회귀 없이 기존 동작 유지).
            width_px: 0,
            height_px: 0,
            scale_milli: 0
        )
        var session: OpaquePointer?
        guard maru_macos_app_session_create(&config, &session) == Self.statusOK, let created = session else {
            // 세션 생성 실패 — 렌더러를 정리하고 포기한다(quick = nil 유지, 토글은 무동작).
            if let renderer = surface.metalRenderer { maru_metal_renderer_destroy(renderer) }
            return
        }
        surface.appSession = created
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

    /// config의 quick terminal 옵션을 읽는다(높이·자동 숨김·화면). config는 모든 app session이 같은 파일을
    /// 로드하므로 primary 세션에서 읽는다(primary는 시작 시 항상 존재). 못 읽으면 nil(기본값 유지).
    private func loadQuickTerminalConfig() -> MaruAppHostQuickTerminalConfig? {
        guard let session = primary?.appSession else { return nil }
        var cfg = MaruAppHostQuickTerminalConfig()
        guard maru_macos_app_session_quick_terminal_config(session, &cfg) == Self.statusOK else { return nil }
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
            // 중앙: 세로=height_fraction, 가로=width_fraction(미설정 0이면 height로 폴백 → 정사각). 가장자리가 없어
            // 보임=숨김(페이드로 처리).
            let wfrac = quickWidthFraction > 0 ? quickWidthFraction : quickHeightFraction
            let w = (vf.width * wfrac).rounded()
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
        resizeAppSessionFromWindow()
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
        if let session = surface.appSession {
            var summary = MaruAppHostFrameSummary()
            _ = maru_macos_app_session_close(session, &summary)
            maru_macos_app_session_destroy(session)
            surface.appSession = nil
        }
        if let renderer = surface.metalRenderer {
            maru_metal_renderer_destroy(renderer)
            surface.metalRenderer = nil
        }
    }

    /// 저장된 workspace 파일 위치(~/Library/Application Support/maru/workspace.v1). R5 저장·R4 로드가 공유한다.
    private var workspaceFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("maru/workspace.v1")
    }

    /// 정상 종료 시 현재 멀티 창 workspace를 디스크에 저장한다(R5). 각 일반 창(세션)의 블록을 ABI로 받아
    /// `maru.workspace.v1` 헤더 하나 아래로 모은다. quick 패널은 transient라 제외. smoke·빈 창·쓰기 실패는
    /// best-effort로 건너뛴다(저장 실패가 종료를 막지 않는다). 크래시 가드는 호출처(applicationWillTerminate가
    /// 정상 종료에만 불림)가 보장 — 깨진 세션이 마지막 저장을 덮어쓰지 않는다.
    private func saveWorkspace() {
        guard !smokeMode, !windows.isEmpty else { return }
        // 복원을 끈 사용자(MARU_NO_WORKSPACE_RESTORE)는 저장도 막는다 — 안 그러면 복원 안 한 기본 단일 창이 종료 시
        // 저장 파일을 덮어써 사용자가 보존하려던 멀티 창 레이아웃이 사라진다(데이터 손실). 플래그=persistence 자체 off.
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return }
        var blocks = ""
        for surface in windows {
            guard let session = surface.appSession else { continue }
            var ptr: UnsafePointer<UInt8>? = nil
            var len: size_t = 0
            guard maru_macos_app_session_serialize_workspace(session, &ptr, &len) == Self.statusOK,
                  let bytes = ptr, len > 0 else { continue } // 캡처 실패한 창은 건너뜀
            blocks += String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        }
        guard !blocks.isEmpty, let url = workspaceFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (MARU_WORKSPACE_HEADER + "\n" + blocks).data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func shutdownAppSession() {
        // 전역 단축키를 먼저 OS에서 해제한다(세션이 사라져도 stale hot-key가 남지 않게). 이미 비었으면 no-op.
        unregisterGlobalHotkeys()
        // quick terminal(있으면)도 함께 정리한다.
        tearDownQuickTerminal()

        // 남은 모든 일반 창 세션·렌더러를 닫고 파괴한다(앱 종료 경로). 보통 비-마지막 창은 이미 닫혔고 마지막
        // 창/앱 종료에서 여기로 온다 — 멀티 창이면 한 번에 전부 정리한다(leak 방지). teardownWindowSurface가
        // 각 close/destroy + 컬렉션에서 제거(요약은 surface.latestFrameSummary에). 변형 중 순회를 피해 snapshot으로.
        let snapshot = windows
        for surface in snapshot {
            teardownWindowSurface(surface)
        }
    }

    private func smokeDurationMs() -> UInt32? {
        guard let raw = ProcessInfo.processInfo.environment["MARU_MACOS_APP_SMOKE_MS"] else {
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
        maru.macos-app.v1
        visible_ui=\(visibleUI)
        swift_host=true
        abi_ready=\(abiReady)
        placeholder_window=true
        terminal_surface=\(terminalSurface)
        terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer
        metal_renderer_created=\(metalRendererCreated)
        metal_frames_drawn=\(metalFramesDrawn)
        app_session_status=\(appSessionStatus)
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
