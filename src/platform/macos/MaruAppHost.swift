import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import Metal
import QuartzCore
import UniformTypeIdentifiers // NSOpenPanel.allowedContentTypes = [.png] (배경 이미지 파일 선택, v81)
import UserNotifications

// MARK: - CGS 비공개 API (창 뒤 배경 블러, F3-1)
//
// macOS에서 "창 뒤(데스크톱) 블러"는 공개 API가 없다 — Metal은 backdrop 픽셀을 못 읽으므로 GPU로 못 하고,
// WindowServer가 창 뒤를 합성해줘야 한다. 그 길은 (1) NSVisualEffectView(vibrancy, 우리 Metal layer와 충돌)
// 또는 (2) 비공개 CGS API `CGSSetWindowBackgroundBlurRadius`뿐이다. Ghostty·Terminal.app을 포함한 사실상
// 모든 터미널이 (2)를 쓴다(references/ghostty/src/apprt/embedded.zig:2106 참조). maru는 App Store 배포가
// 아니라 Ghostty와 같은 선택을 한다. "언제·얼마나" 블러할지(opacity 게이트·반경)는 Zig 단일 출처
// (windowBlurRadius/ABI window_blur_radius)가 정하고, 여기선 OS에 싣기만 한다(platform 어댑터의 macOS 구현 —
// 추후 Windows=DwmSetWindowAttribute·Linux=컴포지터 속성이 같은 자리를 채운다).
typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
func CGSSetWindowBackgroundBlurRadius(_ connection: CGSConnectionID, _ windowNumber: Int, _ radius: Int) -> Int32

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
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL, .png, .tiff]

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
        controller?.handleModifierFlags(event) // 단축키 힌트 HUD 홀드 감지(KH-4)
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

    // 조합(marked text) 중에 '텍스트 입력이 아닌' 사용자 상호작용이 오면 먼저 조합을 확정한다. 안 그러면
    // AppKit 입력기 세션(hasMarkedText)과 Zig preedit가 안 비워진 채 그 상호작용이 실행돼, 이후 입력이
    // stale한 조합에 이어 붙는다 — 예: 'ㅈ' 조합 중 다른 탭으로 가면 그 'ㅈ' 세션이 살아남아 새 탭의 첫
    // 입력이 'ㅈ'부터 이어진다(사용자 보고). 키보드(keyDown: 단축키/특수키 우회), 포인터(handleMouse
    // kind==1: 사이드바 카드·탭 바 클릭의 탭/Term 전환은 버튼 무관 kind==1 게이트라 좌·중·우 다운 모두),
    // 메뉴(runCatalogAction: next/previous_tab 등 — 키 단축키로 와도 keyDown을 안 거친다) 세 입력 모달리티가
    // 이 한 규칙('비-텍스트 조작이면 조합 확정')을 공유한다. 커밋은 전환 '전'에 일어나므로 조합 글자는
    // 떠나는(현재) 터미널로 들어가고 새 터미널은 빈 상태로 시작한다.
    //
    // 왜 Zig switchTab/focusTerm(전환의 단일 chokepoint)이 아니라 Swift 입력 경계에서 하나 — AppKit 입력기
    // 세션 종료(inputContext.discardMarkedText)는 NSView만 할 수 있다. Zig가 preedit를 커밋해도 그걸 못 부르면
    // marked 세션이 살아 다음 입력이 'ㅈ'부터 이어진다(누수의 실제 출처가 AppKit 세션이라 Zig만으론 못 막는다).
    func commitMarkedTextIfComposing() {
        guard hasMarkedText() else { return }
        controller?.imeCommit()            // core preedit 커밋(조합 글자 PTY로)
        inputContext?.discardMarkedText()  // AppKit 입력기의 marked 상태 정리(콜백 없이)
        markedTextBuffer = ""               // hasMarkedText() = false 로 동기화
    }

    // 세팅 등 오버레이/keybind 녹음 중이면 메뉴바 keyEquivalent(⌘T 등)를 가로채지 않고 keyDown 경로로 보낸다 —
    // handleKeyEvent의 모달 입력 차단·녹음 캡처가 그 키를 처리한다. 안 그러면 ⌘조합이 메뉴바 keyEquivalent에 먼저
    // 먹혀(performKeyEquivalent → runCatalogAction) handleKeyEvent의 모달/녹음 가드를 통째로 우회해, 세팅 중 ⌘T가
    // 새거나 녹음할 chord가 캡처되지 않는다(근본 수정). 오버레이가 아니면 super가 기존 메뉴 단축키를 처리한다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.anyOverlayOpen == true {
            controller?.handleKeyDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        controller?.cancelKeyHintHold() // 실제 키 입력 = 단축키 실행 → 보류 홀드 취소·표시 중이면 숨김(KH-4 — 깜빡임 방지)
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
        // 키코드로 한다). Option은 config input.option-as-meta가 가른다: true(기본)면 Option도 우회해
        // 기존 meta-ESC 인코딩 유지, false면 Option-단독 키를 입력기 조합 경로로 보내 macOS 특수문자
        // (Option+b=∫ 등)를 조합하게 하고 Cmd/Ctrl 동반 Option만 우회한다(라이브 config 값을 ABI로 읽음).
        let optionAsMeta = controller?.optionAsMeta ?? true
        let bypassMods: NSEvent.ModifierFlags = optionAsMeta ? [.command, .control, .option] : [.command, .control]
        let chord = event.modifierFlags.intersection(bypassMods)
        // 이 키가 IME를 우회해(단축키 조합 또는 특수키) handleKeyDown으로 직행하는가.
        let bypassesIME = !chord.isEmpty || Self.directEncodeKeyCodes.contains(event.keyCode)
        // 조합(marked text) 중에 우회 키가 오면 '먼저 조합을 확정'한다 — 안 그러면 Swift의 marked
        // text(hasMarkedText)와 Zig의 preedit가 안 비워진 채 PageUp이 화면을 옮겨, 이후 입력이 stale한
        // marked range에 박혀 위치가 어긋나거나 안 먹거나 안 지워진다(특수키 우회의 누락된 처리).
        if bypassesIME {
            commitMarkedTextIfComposing()
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

    // fullSizeContentView로 콘텐츠가 창 top까지 차오르면, mouseDownCanMoveWindow 기본값(레이어 백드 뷰는 YES일 수
    // 있다)일 때 터미널 본문 '어디서나' 드래그가 '창 이동'으로 가로채여 텍스트 선택이 안 되고 창이 끌려간다(드래그 중
    // window.title "Maru"도 뜬다 — 사용자 보고). 터미널/사이드바 콘텐츠는 자체 마우스(선택·hit-test·드래그 재정렬)를
    // 쓰므로 콘텐츠 영역에선 창 이동을 막는다. 창 이동은 상단 신호등 타이틀바 영역(AppKit이 소유)에서만 한다.
    override var mouseDownCanMoveWindow: Bool { false }

    // 마우스 선택: raw 좌표만 backing 픽셀(좌상단 원점)로 바꿔 Zig에 넘긴다 — 셀 변환·선택 모델은
    // Zig가 소유한다(네이티브 최소화). NSView 좌표는 좌하단 원점이라 y를 뒤집는다.
    override func mouseDown(with event: NSEvent) {
        // 사이드바 헤더 빈 영역(maru "타이틀바")이면 네이티브 타이틀바처럼: 더블클릭=창 확대(zoom), 단일 down=창 이동
        // (performDrag). 아이콘·검색·터미널 본문은 false라 아래 일반 처리로 흐른다. mouseDownCanMoveWindow=false라
        // AppKit 자동 드래그가 없어 여기서 명시적으로 한다(드래그 영역 hit-test 단일 출처는 Zig).
        if controller?.handleWindowChromeMouseDown(event, in: self) == true { return }
        // (config 수식키)+클릭 = 그 위치의 URL 열기(선택하지 않음). 수식키 판정·URL 인식 모두 Zig가 한다
        // (input.url-click-modifier). 열렸으면 클릭 소비, 아니면 아래 일반 선택으로 흐른다.
        if controller?.handleUrlClick(event, in: self) == true { return }
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

    // 시스템 라이트/다크 외관이 바뀌면(System Settings 토글·자동 야간) 모든 세션에 알린다 — Zig가 theme.follow-system이
    // 켜졌으면 preset-light/dark로 테마를 교체한다(F2-9). NSView가 외관 변경마다 이걸 부른다(초기는 tick이 1회 적용).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.applySystemAppearanceToAllSessions()
    }
}

// MARK: - Phase 4b-2: 모달 오버레이 Metal 뷰 (컨테이너 맨 위, 투명)
//
// 터미널 레이어 위에 합성되는 **별도 물리 CAMetalLayer**. isOpaque=false·평소 clear(투명)라 아래 터미널
// (+미래 WKWebView, 4c)이 비치고, 모달(command palette·find·confirm·settings) 열림 시에만 렌더러가 이
// layer에 그림자·over quad·모달 텍스트·caret을 그린다. **입력은 안 받는다** — hitTest=nil로 마우스가 아래
// 터미널 뷰로 통과하고 acceptsFirstResponder=false로 키/IME는 터미널 뷰가 계속 소유한다(IME 전이·WKWebView
// 포커스 경합은 4d로 연기, 지금은 기계적 배선만). drawableSize만 자기 layer에서 관리하고 세션 resize는 안
// 건드린다(그건 터미널 뷰가 단일 소유). docs/web-panel.md §2 (b)·§10 4b.
@MainActor
final class MaruMetalOverlayView: NSView {
    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        // 색 관리는 터미널 레이어와 동일하게 sRGB로 태그(모달 색이 wide-gamut에서 과장되지 않게).
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = true
        // 핵심: 투명 오버레이. 모달이 없는 영역은 (0,0,0,0) clear라 아래 레이어가 비친다.
        metalLayer.isOpaque = false
        return metalLayer
    }

    var metalLayer: CAMetalLayer? {
        return layer as? CAMetalLayer
    }

    // 오버레이는 입력 대상이 아니다 — 마우스는 아래 터미널 뷰로 통과, 키/IME는 터미널이 firstResponder.
    override var acceptsFirstResponder: Bool { return false }
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

    // 터미널 뷰와 동일한 backing-px drawableSize 계산(단, 세션 resize는 트리거하지 않는다). 렌더러가 두 레이어의
    // drawableSize를 present 직전 lockstep으로 한 번 더 맞추지만(모달 NDC 정합), 뷰 레벨에서도 추종해 둔다.
    func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0
        let width = max(1.0, bounds.width * scale)
        let height = max(1.0, bounds.height * scale)
        let newSize = CGSize(width: width, height: height)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
        }
    }
}

// MARK: - Phase 4b-2: contentView 컨테이너 뷰 (3겹 합성 호스트)
//
// window.contentView를 단일 터미널 뷰에서 **컨테이너**로 재편한다. 자식: 터미널 뷰(맨 아래, layer isOpaque는
// window.opacity 따라감) + 모달 오버레이 뷰(맨 위, 투명). **미래 WKWebView(4c)가 그 사이**에 본문 rect로 낀다.
// 두 자식은 컨테이너를 꽉 채우고(autoresizing) 창 리사이즈를 함께 따라간다. 오버레이 hitTest=nil이라 입력은
// 터미널 뷰가 계속 처리한다(모달 keyDown/anyOverlayOpen 현행 그대로 — IME 전이는 4d).
@MainActor
final class MaruTerminalContainerView: NSView {
    let terminalView: MaruMetalTerminalView
    let overlayView: MaruMetalOverlayView

    init(frame frameRect: NSRect, controller: MaruAppHostController) {
        terminalView = MaruMetalTerminalView(frame: frameRect)
        overlayView = MaruMetalOverlayView(frame: frameRect)
        super.init(frame: frameRect)
        terminalView.controller = controller
        // wantsLayer=true가 각 뷰의 makeBackingLayer()로 CAMetalLayer를 즉시 만들게 한다.
        terminalView.wantsLayer = true
        overlayView.wantsLayer = true
        terminalView.autoresizingMask = [.width, .height]
        overlayView.autoresizingMask = [.width, .height]
        // 오버레이 CAMetalLayer는 터미널과 **같은 MTLDevice**여야 두 drawable을 한 command buffer에서 present할 수
        // 있다(MTLCreateSystemDefaultDevice는 호출마다 다른 인스턴스를 줄 수 있으므로 명시적으로 공유한다).
        if let dev = terminalView.metalLayer?.device {
            overlayView.metalLayer?.device = dev
        }
        addSubview(terminalView) // 맨 아래(터미널·사이드바·chrome)
        addSubview(overlayView)  // 맨 위(모달 오버레이 — 미래 WKWebView는 이 둘 사이 4c)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MaruTerminalContainerView는 coder 초기화 미지원") }
}

// 한 터미널 세션의 per-session 상태 — 창/PTY(appSession)/Metal 렌더러 + 렌더 캐시 메트릭을 묶는다.
// 컨트롤러가 메인 창을 `primary`로 들고, quick terminal(후속)이 두 번째 인스턴스가 된다. 세션별 로직은
// 컨트롤러 메서드가 이 surface의 상태를 읽고 쓰며 수행한다(상태만 여기 — 두 세션이 같은 메서드를 공유).
@MainActor
final class TerminalSurface {
    var window: NSWindow?
    var appSession: OpaquePointer?
    var metalRenderer: OpaquePointer?

    // 데스크톱 알림 클릭 라우팅용 창(세션) 식별 토큰. surface.id는 M0a 이후 앱 전역으로 유일하지만(창 간
    // 중복 없음 — docs/window-surface-mobility.md §8), 알림 userInfo에 (token, surface_id) 쌍을 실어 token으로
    // 대상 창/세션을 먼저 빠르게 고른 뒤 그 세션에서 surface_id로 (탭·panel·Term)을 역조회한다(token=위치
    // 메타데이터, id 충돌 방지용 복합키 아님). makeTerminalSurface가 단조 증가로 채번한다(0=미설정 sentinel —
    // parseNotificationRoute가 거른다).
    var token: UInt64 = 0

    // 렌더 캐시(세션별). 의미는 컨트롤러의 drawMetalFrame/tickAppSession 주석 참조.
    var lastDrawnGeneration: UInt64 = 0
    var lastSeenMetalGeneration: UInt32 = 0
    var lastCellWidthPx: UInt32 = 0
    var lastCellHeightPx: UInt32 = 0
    var lastSentBackingScale: CGFloat = 0
    var metalNeedsRedraw = false
    var metalFramesDrawn = 0
    var metalRendererCreated = false
    // 마지막으로 OS에 적용한 창 뒤 배경 블러 반경(window.blur, F3-1). -1=미적용 sentinel — 값이 바뀔 때만
    // CGSSetWindowBackgroundBlurRadius를 호출해(매 frame WindowServer 호출 방지) reload·opacity 변화를 반영한다.
    var lastAppliedBlurRadius: Int = -1
    var latestFrameSummary = MaruAppHostFrameSummary()
    var appSessionStatus: Int32 = 0
    var lastWindowTitle = ""

    // Metal terminal view = 창 컨테이너(contentView)의 터미널 자식 뷰(Phase 4b-2). window가 살아 있는 동안 유효.
    var view: MaruMetalTerminalView? {
        return (window?.contentView as? MaruTerminalContainerView)?.terminalView
    }

    // 모달 오버레이 자식 뷰(컨테이너 맨 위, 투명). 렌더러 draw가 터미널 layer와 함께 이 layer에 그린다.
    var overlayView: MaruMetalOverlayView? {
        return (window?.contentView as? MaruTerminalContainerView)?.overlayView
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
final class MaruAppHostController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
    // 알림 클릭 라우팅 토큰 채번기(makeTerminalSurface가 단조 증가로 부여 — 창마다 유일). 0은 미설정 sentinel이라 1부터.
    private var nextSurfaceToken: UInt64 = 1
    // 앱-전역 "메인/첫 일반 창" 별칭(= windows.first). 앱 요약·종료처럼 특정 한 창이 기준일 때 쓴다. 창별
    // 타게팅 세분화(key 창 기준 메뉴/포커스)는 W4. TerminalSurface는 reference라 `primary?.field = x` 변형은
    // 객체를 통해 그대로 동작한다(컬렉션 재대입이 아님).
    private var primary: TerminalSurface? { windows.first }
    // quick terminal(별도 세션 오버레이 패널)의 surface. 첫 토글에서 lazy 생성. 없거나 숨김이면 입력/렌더는 primary.
    private var quick: TerminalSurface?
    // quick 패널의 슬라이드 인/아웃 애니메이션이 진행 중인지. 포커스 잃음 자동 숨김이 애니메이션 도중·직후
    // (orderOut 시 resignKey)에 재진입해 이중 숨김하지 않게 가드한다.
    private var quickAnimating = false
    // quick terminal 표시/동작 옵션. **표시 직전 토글마다 config를 라이브로 다시 읽어**(quickPanelFrames는 Zig
    // ABI가 매 호출 현재 config로 사각형을 계산) 설정 GUI 변경을 즉시 반영한다 — 예전처럼 첫 생성 때 스냅샷을
    // 캐시하지 않는다. auto_hide/screen만 Swift가 들고 있으면 되고(패널 크기·위치·center 여부는 ABI가 계산),
    // screen은 'mouse'면 show마다 현재 마우스가 있는 화면으로 해석하므로 모드만 저장한다.
    private var quickAutoHide = true
    private var quickScreenMode: UInt32 = UInt32(MaruAppHostQuickTerminalScreenMain.rawValue)
    // quick 세션 생성 시점의 chrome/minimal_tabs — 이 둘은 세션 생성 인자로 박혀 라이브로 못 바꾼다. 토글에서
    // 현재 config와 비교해 달라졌으면 기존 quick 세션을 내려 새 chrome으로 재생성한다(라이브 반영의 유일한 예외).
    private var quickCreatedChrome: UInt32 = UInt32(MaruAppHostQuickTerminalChromeFull.rawValue)
    private var quickCreatedMinimalTabs: UInt32 = 0
    // 표시 시점에 계산한 (숨김 사각형, center 여부). 숨김 애니메이션이 이 값을 써, 표시 이후 마우스/화면/설정이
    // 바뀌어도 패널이 있던 화면·위치 그대로 되빠지게 한다(재계산 겨냥 오류 방지). teardown에서 nil로.
    private var quickHideFrame: (rect: NSRect, centered: Bool)?
    // tick이 특정 surface를 명시적으로 대상 지정할 때 쓴다(이벤트가 아니라 타이머 구동이라 key 창으로 못 고름).
    // nil이면 입력 이벤트는 key 창 기준으로 surface를 고른다(이벤트는 key 창의 first responder로 전달되므로).
    private var explicitSurface: TerminalSurface?
    // theme.follow-system 초기 외관을 한 번 적용했는지(F2-9). 세션 생성 직후 첫 tick에서 현재 NSAppearance를 알린다 —
    // 이후 변경은 viewDidChangeEffectiveAppearance가 처리한다. tick은 세션이 확실히 있는 시점이라 초기 적용에 안전하다.
    private var didApplyInitialAppearance = false
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

    /// 주어진 알림 라우팅 토큰(makeTerminalSurface 채번)의 surface. 일반 창 컬렉션을 먼저 보고, 없으면 quick 패널을
    /// 본다(quick도 토큰을 가짐). 알림 클릭(didReceive)이 발신 창/세션을 고를 때 쓰는 token 조회 단일 출처 —
    /// surfaceForWindow/surfaceForView와 같은 lookup 패턴.
    private func surfaceForToken(_ token: UInt64) -> TerminalSurface? {
        if let surface = windows.first(where: { $0.token == token }) { return surface }
        if let quick, quick.token == token { return quick }
        return nil
    }

    private var window: NSWindow? {
        get { activeSurface?.window }
        set { activeSurface?.window = newValue }
    }
    private var appSession: OpaquePointer? {
        get { activeSurface?.appSession }
        set { activeSurface?.appSession = newValue }
    }
    // macOS Option을 Meta로 쓰는지(config input.option-as-meta). 활성 세션의 라이브 값을 ABI로 읽어 view.keyDown이
    // Option-단독 키를 입력기 조합 경로(false)/meta 인코딩(true=현행)으로 가른다. 세션 없으면 현행 meta 폴백(true).
    var optionAsMeta: Bool {
        guard let session = appSession else { return true }
        return maru_macos_app_session_option_as_meta(session) != 0
    }
    // 세팅 등 chrome 오버레이/keybind 녹음 중인지(라이브 ABI). view.performKeyEquivalent·handleKeyDown이 true면 메뉴바
    // keyEquivalent(⌘T 등)·OS 단축키(Cmd+C/V 등) 가로채기를 건너뛰고 키를 keyDown→handleKeyEvent로 보낸다 —
    // 모달 입력 차단·chord 녹음이 거기서 처리되게(누수·녹음 누락 방지).
    var anyOverlayOpen: Bool {
        guard let session = appSession else { return false }
        return maru_macos_app_session_any_overlay_open(session) != 0
    }
    // 단축키 힌트 HUD(KH-4) — 홀드 감지의 **OS 타이머 clock만** Swift가 쥔다(native 최소). gesture 정책(enabled·단독성·
    // 트리거 모디파이어·표시 여부)은 전부 Zig 홀드 머신(keyhint_hold.zig)이 단일 출처로 판정한다. flagsChanged·timer
    // fire·keyDown/blur를 머신에 흘리고 돌아온 Action으로 이 타이머와 redraw만 관리한다(visible은 머신이 chrome_host에 적용).
    private var keyHintTimer: Timer?
    // config keyhint.delay(라이브 ABI read) — 홀드 지연 ms. Swift는 타이머 간격에만 쓴다(enabled/modifier 판정은 머신).
    // 세션 없거나 실패면 nil. enabled/modifier out-param은 ABI가 채우지만 Swift는 무시한다.
    private var keyHintDelayMs: UInt32? {
        guard let session = appSession else { return nil }
        var enabled: UInt32 = 0
        var delayMs: UInt32 = 0
        var modifier: UInt32 = 0
        guard maru_macos_app_session_key_hints_config(session, &enabled, &delayMs, &modifier) == Self.statusOK else { return nil }
        return delayMs
    }
    private var tickTimer: Timer?
    private var frameLoopRateHz: UInt32 = 0
    // 세션 컨트롤 플레인 라이브 서버(A2b)가 떴는지. Zig가 앱 전역 소켓 + accept 스레드를 소유하고, 여긴 (1) 시작 시
    // start 1회, (2) 매 tick drain(살아있는 세션 목록 전달 — §2 열거), (3) 종료 시 stop만 부른다. bind 실패는
    // 비치명(false로 남고 컨트롤 플레인만 꺼짐). 단일 출처: docs/control-plane.md §2·§5.
    private var controlServerStarted = false
    // smoke 자동 종료용 one-shot timer. 창이 먼저 닫혀도 run loop에 남아 teardown 뒤
    // NSApp.terminate를 다시 부르지 않도록 저장해 두고 종료 시 invalidate한다.
    private var smokeTimer: Timer?
    private var smokeMode = false
    // Cmd+Q 종료 확인 모달이 떠 결정을 기다리는 중(applicationShouldTerminate가 .terminateLater 반환). 다음 tick
    // FrameSummary.quit_decision으로 결정이 오면 NSApp.reply로 종료를 진행/취소하고 false로 되돌린다. 중복 Cmd+Q 무시용.
    private var quitConfirmPending = false
    // 창 닫기로 인한 종료(마지막 창을 Cmd+W/빨간 버튼으로 닫아 windowWillClose/closeWindowOrQuit이 NSApp.terminate를
    // 부른 경우)는 이미 자기 게이트를 거쳤으므로 applicationShouldTerminate가 종료 확인을 다시 띄우지 않게 하는 래치.
    private var bypassQuitConfirm = false
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
    private var lastAppliedBlurRadius: Int {
        get { activeSurface?.lastAppliedBlurRadius ?? -1 }
        set { activeSurface?.lastAppliedBlurRadius = newValue }
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
        cleanupPasteImages() // 이전 세션이 남긴 임시 paste 이미지 청소(누적 방지 — 정상/비정상 종료 모두 커버).

        // 메인 창의 per-session 상태를 담을 surface를 가장 먼저 만든다 — 아래 window/appSession/렌더러
        // 대입이 전부 이 첫 창(primary = windows.first)으로 forwarding되므로(forwarder setter), 창이 없으면
        // 그 대입이 사라진다. New Window(W2)는 같은 컬렉션에 surface를 추가한다.
        self.windows.append(makeTerminalSurface())

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
        focusTerminalView(window)
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

        // 알림 클릭/포그라운드 콜백(didReceive·willPresent)을 받으려면 delegate가 **launch 완료 전에** 걸려 있어야
        // 한다(Apple 요구사항) — 앱이 꺼진 상태에서 알림 클릭으로 켜진 경우의 첫 didReceive를 놓치지 않으려면 첫 tick의
        // ensureNotificationAuthorization(lazy)이 아니라 여기서 등록해야 한다. 번들 ID가 없으면(smoke 등)
        // UNUserNotificationCenter를 못 써 건너뛴다(권한 요청은 여전히 첫 tick에서 lazy로).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        startFrameLoopTicks()

        // 세션 컨트롤 플레인 라이브 서버(A2b): 앱 전역 소켓 + accept 스레드를 띄운다. 이 뒤로 tickAppSession이 매
        // tick drain하고(살아있는 세션 목록), applicationWillTerminate가 stop한다. bind 실패는 비치명(컨트롤 플레인만
        // 꺼짐 — maru sessions list가 "인스턴스 없음"으로 접힌다). 소켓·스레드·collector·dispatch·auth는 전부 Zig.
        controlServerStarted = (maru_macos_control_server_start() == Self.statusOK)

        if smokeMode {
            sendSmokeDevEvents()
        }

        if let smokeDuration {
            smokeTimer = Timer.scheduledTimer(withTimeInterval: Double(smokeDuration) / 1000.0, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    // Cmd+Q/메뉴 "Quit maru"/Dock·로그아웃에 의한 앱 전체 종료. AppKit terminate:는 windowShouldClose를 거치지
    // 않으므로 여기서 가로채, 활성 창 세션에 "maru를 종료할까요?" 확인 모달을 띄우고 .terminateLater로 보류한다.
    // 모달 결정은 다음 tick FrameSummary.quit_decision으로 와 drainQuitDecision이 NSApp.reply로 종료를 진행/취소한다.
    // 창 닫기와 달리 실행 중 명령 유무와 무관하게 항상 묻는다(사용자 결정 2026-06). 단일 출처: docs/macos-app-host-boundary.md.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        if smokeMode { return .terminateNow } // smoke 자동 종료는 무인이라 모달에 막히면 hang
        if bypassQuitConfirm { return .terminateNow } // 창 닫기로 인한 종료 — 이미 처리됨, 재확인 안 함
        if quitConfirmPending { return .terminateLater } // 이미 모달이 떠 결정 대기 중 — 중복 요청 무시
        // frame-loop tick이 아직 안 도는 런치 초기 에러(tickTimer==nil)거나 세션이 없으면, 모달을 띄워도 결정이
        // 돌아올 수 없으므로 즉시 종료한다.
        guard tickTimer != nil, let session = activeSurface?.appSession else { return .terminateNow }
        quitConfirmPending = true
        maru_macos_app_session_request_app_quit(session) // 항상 모달(실행 중 명령 무관)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        tickTimer?.invalidate()
        tickTimer = nil
        smokeTimer?.invalidate()
        smokeTimer = nil
        // 컨트롤 플레인 서버를 세션 teardown '전에' 멈춘다 — accept 스레드를 join하고 대기 중 요청을 cancel해, 이후
        // shutdownAppSession이 세션을 해제할 때 accept 스레드가 (marshal 큐 밖에서) 세션을 만지지 않게 한다. tick은
        // 이미 멈춰(위) 더 이상 drain되지 않는다. idempotent(미시작이면 무동작).
        if controlServerStarted {
            maru_macos_control_server_stop()
            controlServerStarted = false
        }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 빨간 닫기 버튼/창 단위 닫기 요청. 닫힐 창(세션)에 실행 중인 명령이 있으면 Zig가 확인 모달을 열고 1을
        // 돌려준다 → false로 닫기를 보류한다(데이터 손실 방지 — iTerm2/Terminal.app/Ghostty 관례). 모달 확정 시
        // tick의 session-ended가 closeWindowOrQuit으로 실제 창을 닫는다 — 그건 프로그래밍적 close()라 이 델리게이트가
        // 다시 안 불려 재확인 루프가 없다. 실행 중 명령이 없으면 true(평소 닫기 → windowWillClose가 terminate/
        // teardown). session이 없으면(quick 창 등 delegate 미사용 경로) 평소대로 닫는다.
        guard let surface = surfaceForWindow(sender), let session = surface.appSession else { return true }
        return maru_macos_app_session_request_window_close(session) == 0
    }

    func windowWillClose(_ notification: Notification) {
        // 닫히는 창의 일반-창 surface(quick은 delegate를 안 써 여기 안 옴). 마지막 일반 창이면 앱 종료
        // (정리·요약은 applicationWillTerminate — primary가 살아 있어야 요약이 그 세션 기준. 원래 단일 창 동작
        // 보존). 마지막이 아니면 그 창 세션만 닫고 앱은 계속한다(window는 AppKit이 이미 닫는 중).
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        if windows.count <= 1 {
            bypassQuitConfirm = true // 명시적 창 닫기에 따른 종료 — applicationShouldTerminate가 재확인하지 않게
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
        let resigning = surfaceForWindow(notification.object as? NSWindow)
        // 단축키 힌트 HUD를 닫는다(KH-4 — 앱 전환 등으로 떼는 flagsChanged가 안 올 수 있음). **떠나는 창의 surface로**
        // 취소한다 — 활성 surface로 보내면 멀티 윈도우에서 이미 새 키 창(idle 머신)을 건드리고 떠나는 창 배지가 켜진 채
        // 남는다(리뷰 #1063 지적). 단일 윈도우는 resigning==활성이라 동작 불변.
        cancelKeyHintHold(for: resigning)
        guard let surface = resigning, let session = surface.appSession else { return }
        _ = maru_macos_app_session_focus_changed(session, 0)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 사용자가 앱으로 돌아오면 "놓친 벨" Dock 배지(bell.dock-badge)를 지운다 — 배지는 앱 전역(dockTile)이라 여기서
        // 한 번에 클리어한다(어느 창을 포커스하든). 배지를 안 띄웠으면 빈 라벨 대입은 무해.
        _ = notification
        NSApp.dockTile.badgeLabel = nil
    }

    // macOS 시스템 외관이 다크인지(NSAppearance). NSApp 전역 외관을 light/dark 중 가까운 쪽으로 매칭한다(F2-9).
    private var isSystemDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // 모든 세션(창·quick)에 현재 시스템 외관(light/dark)을 알린다 — Zig가 theme.follow-system이 켜졌으면 preset-light/dark로
    // 교체한다(꺼졌으면 무시). 외관 변경(viewDidChangeEffectiveAppearance)·초기 1회(tick)에 호출. 외관 판정은 OS, 색은 Zig.
    func applySystemAppearanceToAllSessions() {
        let dark: Int32 = isSystemDark ? 1 : 0
        for surface in windows {
            if let session = surface.appSession {
                _ = maru_macos_app_session_set_system_appearance(session, dark)
            }
        }
        if let session = quick?.appSession {
            _ = maru_macos_app_session_set_system_appearance(session, dark)
        }
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
        // 창 제목(window.title)은 updateWindowTitle이 매 tick OSC 0/2·cwd·"Maru"로 갱신한다(Window 메뉴·Mission
        // Control용). titleVisibility=.hidden이라 타이틀바엔 안 보이고, 드래그 중 "Maru"가 떠 보이던 건 콘텐츠 뷰가
        // 창을 끌던 탓이라 MaruMetalTerminalView.mouseDownCanMoveWindow=false로 막았다(여기서 title을 비울 필요 없음).
        // 네이티브 타이틀바를 숨기고 신호등(닫기·최소화·확대)만 좌상단에 남긴다: 타이틀바 투명 + 제목 숨김 +
        // fullSizeContentView로 콘텐츠(사이드바)가 창 top까지 차오르게 한다. 사이드바 헤더 chrome이 신호등 영역에
        // 정렬한다(maru Zig+GPU chrome 전략 — 네이티브 뷰 없이 직접 그림). 베이스: 모던 macOS 표준 패턴. 외부
        // 터미널은 동작 형태만 참고했고 산출물은 Maru 독립 설계다(docs/macos-app-host-boundary.md).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)

        // Phase 4b-2: contentView를 컨테이너로 재편한다 — 터미널 뷰(맨 아래) + 모달 오버레이 뷰(맨 위). 미래 WKWebView(4c)가 그 사이.
        let container = MaruTerminalContainerView(
            frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 600),
            controller: self
        )
        window.contentView = container

        return window
    }

    // Phase 4b-2: contentView 컨테이너의 터미널/오버레이 자식 뷰 접근자.
    private var metalTerminalView: MaruMetalTerminalView? {
        return (window?.contentView as? MaruTerminalContainerView)?.terminalView
    }

    private var metalOverlayView: MaruMetalOverlayView? {
        return (window?.contentView as? MaruTerminalContainerView)?.overlayView
    }

    // 창/패널 컨테이너의 터미널 자식 뷰를 firstResponder로 만든다(입력·IME는 터미널 뷰가 소유 — 4d 전 기계적 배선).
    private func focusTerminalView(_ window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder((window.contentView as? MaruTerminalContainerView)?.terminalView)
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
        // Phase 4b-2: 컨테이너의 터미널 layer(맨 아래) + 오버레이 layer(맨 위, 투명)를 함께 렌더러에 넘긴다.
        guard let appSession, let renderer = metalRenderer,
              let view = metalTerminalView, let metalLayer = view.metalLayer,
              let overlayLayer = metalOverlayView?.metalLayer else {
            return
        }
        var frame = MaruAppHostMetalFrame()
        guard maru_macos_app_session_metal_frame(appSession, &frame) == Self.statusOK else {
            return
        }
        // 창 배경 투명도(window.opacity): opacity<1이면 터미널 layer·window를 비불투명으로 만들어 clear color의 낮은
        // alpha가 뒤(데스크톱/다른 창)를 비추게 하고, 1이면 불투명 유지(합성 비용·창 그림자 보존). 매 frame 멱등 —
        // 값이 바뀔 때만 실제 set한다. **오버레이 layer는 항상 투명(isOpaque=false 고정)** — 모달만 그리므로 window.opacity와
        // 무관하게 아래 터미널이 비쳐야 한다. clear color alpha 자체는 renderer가 window_opacity_milli로 터미널에만 적용.
        let opaqueWindow = frame.window_opacity_milli >= 1000
        if metalLayer.isOpaque != opaqueWindow { metalLayer.isOpaque = opaqueWindow }
        if let win = view.window, win.isOpaque != opaqueWindow {
            win.isOpaque = opaqueWindow
            win.backgroundColor = opaqueWindow ? .windowBackgroundColor : .clear
            win.hasShadow = opaqueWindow // 투명 창은 그림자 끔(투명 영역 그림자가 어색)
        }
        // 창 뒤(데스크톱) 배경 블러(window.blur, F3-1). 유효 반경(opacity<1 게이트 포함)은 Zig 단일 출처
        // (windowBlurRadius)가 정하고, 여기선 그 값을 OS 창 속성에 싣기만 한다 — 블러는 GPU가 아니라 WindowServer가
        // 창 뒤를 합성하는 거라 Metal 렌더러로는 못 한다(Ghostty·Terminal.app도 동일한 비공개 CGS API 사용). 값이
        // 바뀔 때만 호출(매 frame WindowServer 왕복 방지). 추후 Windows=DwmSetWindowAttribute·Linux=컴포지터 속성으로
        // 같은 자리를 채운다(platform 어댑터).
        let blurRadius = Int(maru_macos_app_session_window_blur_radius(appSession))
        if blurRadius != lastAppliedBlurRadius, let win = view.window {
            _ = CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), win.windowNumber, blurRadius)
            lastAppliedBlurRadius = blurRadius
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
            metalLayer,    // 터미널 물리 레이어(맨 아래)
            overlayLayer,  // 모달 오버레이 물리 레이어(맨 위, 투명)
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
            frame.modal_clip_x_px,        // C4b 모달 클리핑(px, w==0=없음 — renderer가 모달 셀 draw에 scissor; 패스스루)
            frame.modal_clip_y_px,
            frame.modal_clip_w_px,
            frame.modal_clip_h_px,
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
            frame.terminal_bg,            // 화면 clear color(OSC 11 배경 set 또는 theme.background; 0=기본 clear)
            frame.titlebar_strip_px,      // 상단 타이틀바 띠 높이 — 접힘 펼치기 토글(◧)을 띠 안 세로 중앙(신호등 정렬)
            frame.window_opacity_milli,   // 창 배경 투명도 ×1000 — clear color alpha(default 배경만 투명)
            frame.sidebar_scroll_offset_px, // 사이드바 세로 스크롤량(px) — 카드를 위로 밀고 헤더 아래로 scissor 클립
            frame.divider_thickness_px,   // pane divider(reserved 30/31) 두께(px) — config split.divider-thickness(패스스루)
            frame.cursor_cells,           // 커서 blink 페이드: 커서 overlay suffix 길이(본문서 제외·별도 pass; 패스스루)
            frame.cursor_fade_milli       // 커서 overlay 불투명도 ×1000 — blink 페이드 위상(cursor.blink-fade-ms; 패스스루)
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

    /// TerminalSurface 생성의 단일 출처 — 알림 클릭 라우팅 토큰(token)을 단조 증가로 채번한다. 초기 창·New Window·
    /// quick 패널이 모두 이 팩토리를 거쳐, 어느 경로로 만든 창이든 알림이 정확히 그 창으로 돌아온다(채번 누락 방지).
    private func makeTerminalSurface() -> TerminalSurface {
        let surface = TerminalSurface()
        surface.token = nextSurfaceToken
        nextSurfaceToken += 1
        return surface
    }

    /// 새 일반 창(+세션+렌더러)을 만든다. 성공하면 **생성된 surface**를 반환하고, 실패하면 nil(만든 것을 정리한 뒤).
    /// 복원할 창이면 (전체 텍스트, 창 인덱스)를 받아 세션 생성 직후 그 인덱스의 창을 적용해 탭/split/Term을 복원한다
    /// (R4b) — 포맷 파싱은 Zig ABI가 소유한다(Swift는 'window ' 경계를 분할하지 않음). 반환값은 복원 loop가 블록
    /// 인덱스 → 실제 창 매핑을 만들어(M3e 활성 창 focus) 창별 spawn 실패로 windows 배열이 compact돼도 정확한 창을
    /// 고를 수 있게 한다.
    @discardableResult
    private func createTerminalWindow(applyingWorkspace ws: (text: String, index: Int)?) -> TerminalSurface? {
        let surface = makeTerminalSurface()
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
            focusTerminalView(window)
            setupMetalRenderer()
            guard createSessionForActiveSurface(smokeMode: false) else { return }
            if let ws {
                applyWorkspaceWindow(ws.text, ws.index) // 복원: 기본 탭을 이 창의 탭/split/Term으로 교체
                // M3f: 저장된 창 위치·크기·모니터로 복원(없으면 위 cascade 유지). resize 전에 setFrame해 아래 resize가
                // 복원된 크기를 세션에 전달하게 한다.
                applyRestoredWindowFrame(window, text: ws.text, index: ws.index)
            }
            resizeAppSessionFromWindow()
            // 새 창 세션에 현재 시스템 외관을 즉시 알린다(theme.follow-system 라이브 적용) — viewDidChangeEffectiveAppearance는
            // 창 표시 중 세션 생성 **전**에 발화해 이 새 세션을 놓치고, didApplyInitialAppearance는 앱-전역 1회뿐이라
            // 두 번째 창부터 못 닿는다(리뷰 B). 첫 paint 전에 호출해 시작 프레임부터 올바른 프리셋이 보이게 한다.
            applySystemAppearanceToAllSessions()
            _ = renderTick() // 즉시 첫 paint(다음 timer tick을 안 기다림)
            ok = true
        }
        if !ok {
            // 실패: 세션/렌더러 정리 + 창 닫기 + 컬렉션 제거(delegate를 끊어 windowWillClose 재진입 방지).
            teardownWindowSurface(surface)
            surface.window?.delegate = nil
            surface.window?.close()
            surface.window = nil
            return nil
        }
        return surface
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

    /// (M3f) 저장된 workspace에서 window_index 창의 frame(전역 스크린 좌표)을 읽어, 화면 안이면 그대로·아니면 main
    /// 화면으로 clamp한 뒤 setFrame한다. frame이 없으면(옛 파일·부분 필드·parse 실패) 무동작 → 호출자가 만든 현행
    /// 기본(cascade) 위치를 유지한다. 포맷 파싱은 Zig가 소유한다(Swift는 xywh 정수만 받는다). session은 forwarder
    /// 대상(현재 surface)의 것을 쓴다 — 파싱은 어느 세션 allocator든 되고, 창 index로 정확한 창 frame을 뽑는다.
    private func applyRestoredWindowFrame(_ window: NSWindow, text: String, index: Int) {
        guard let session = appSession else { return }
        let bytes = Array(text.utf8)
        var x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0
        let present = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_workspace_window_frame(session, buf.baseAddress, buf.count, index, &x, &y, &w, &h)
        }
        guard present == 1 else { return } // 0=없음/-1=parse실패 → 현행 기본(cascade) 유지
        let saved = NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        window.setFrame(clampFrameToVisibleScreens(saved), display: false)
    }

    /// (M3f) 저장 frame을 **항상 화면 안·타이틀바 잡힘**이 보장되게 clamp한다(pre-M3f "창은 늘 화면 안" 불변식 복원).
    /// 저장 frame과 **가장 많이 겹치는** NSScreen을 고르고(전역 좌표가 모니터를 인코딩 — 그 모니터가 아직 붙어 있으면
    /// 최대 겹침), 어떤 화면과도 안 겹치면(모니터 분리·레이아웃 변경) main 화면으로 폴백한 뒤, **그 화면 visibleFrame
    /// 안으로 frame을 clamp**한다: 화면보다 크면 축소하고, 가장자리를 넘으면 이동해 창이 완전히 화면 안에 오게 한다.
    /// 예전엔 "가시 면적이 임계 이상이면 그대로" 통과시켜 모니터 배치가 바뀌면 구석만 걸친 채 거의 화면 밖으로 복원됐다
    /// (타이틀바가 화면 위에 없어 드래그 불가). 이제 "겹치면 그대로"가 아니라 "항상 사용 가능하게 clamp"다. frame이
    /// 화면 안에 완전히 들어가면 clamp가 그대로 반환하므로(크기·위치 불변) 맞는 모니터의 사용자 리사이즈 크기는 보존된다.
    /// macOS constrainFrameRect(타이틀바를 화면에 남김)를 참고했으나 명시 clamp로 예측 가능하게. 화면이 없으면(비정상)
    /// 저장 frame 그대로.
    private func clampFrameToVisibleScreens(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        // 저장 frame과 가장 많이 겹치는 화면 = "그 창이 있던 모니터"(전역 좌표가 모니터를 인코딩). 어떤 화면과도 안
        // 겹치면 best=nil → main 화면 폴백.
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let inter = frame.intersection(screen.visibleFrame)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    best = screen
                }
            }
        }
        let vis = (best ?? NSScreen.main ?? screens[0]).visibleFrame
        // 그 화면 안으로 clamp: 크기는 화면보다 크면 줄이고(저장 w/h가 비정상 0/음수면 sane 폴백), 위치는 가장자리를
        // 넘으면 이동해 완전히 화면 안에 둔다. 이미 화면 안이면 그대로(크기·위치 보존).
        let w = min(frame.width > 0 ? frame.width : 960, vis.width)
        let h = min(frame.height > 0 ? frame.height : 600, vis.height)
        let x = max(vis.minX, min(frame.minX, vis.maxX - w))
        let y = max(vis.minY, min(frame.minY, vis.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// 시작 시 저장된 workspace를 복원한다(R4b). Zig가 창 개수를 세고(헤더·포맷 검증 겸함), 창 0을 primary에,
    /// 나머지를 새 창에 인덱스로 적용한다. 저장 없음·복원 off·smoke·손상(count<=0)이면 무동작(기본 단일 창 유지).
    ///
    /// 성능 주: 복원은 창마다 workspace 전체 텍스트를 재파싱한다(apply_workspace_window N + workspace_window_frame N +
    /// active_window 1 + count 1). frame·is_active read를 per-window apply에 fold해(out-params) 재파싱을 줄이는 최적화가
    /// 가능하나, 시작 1회·작은 파일·창 몇 개뿐이라 hot path가 아니고 fold는 3개 ABI 함수 시그니처 변경(cross-boundary
    /// churn)이라 도입하지 않는다(6차 리뷰 [5] cleanup — 문서 follow-up). 필요해지면 apply_workspace_window가 그 창
    /// frame(out)+is_active(flag)를 함께 반환하게 확장한다.
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
        // 블록 인덱스 → 생성된 창 매핑. `active-window`(활성 창 마커)는 workspace 텍스트의 **블록 인덱스**라, 라이브
        // `windows` 배열 인덱스와 도메인이 다르다: 중간 창이 spawn 실패하면 teardownWindowSurface가 windows를 compact해
        // 두 인덱스가 발산한다(그러면 windows[activeIndex]가 엉뚱한 창을 key로 만든다). 블록 인덱스로 직접 조회하려고
        // 매핑을 만든다 — 블록 0 = primary, 추가 창 i = createTerminalWindow가 성공 시 반환한 surface(실패 = 키 없음).
        var windowByBlock: [Int: TerminalSurface] = [:]
        if let primary { windowByBlock[0] = primary }
        var primaryApplied = false
        withSurface(primary) { primaryApplied = applyWorkspaceWindow(text, 0) }
        for i in 1..<Int(count) {
            if let created = createTerminalWindow(applyingWorkspace: (text, i)) {
                windowByBlock[i] = created
            }
        }
        if !primaryApplied {
            showNotice("저장된 작업 공간을 일부만 복원했습니다 — 기본 창으로 시작합니다.")
        }
        // 복원으로 grid·레이아웃이 바뀌었으니 primary를 창에 다시 맞추고 즉시 repaint한다 — 추가 창은
        // createTerminalWindow가 renderTick하지만 primary는 안 그래서, 기본 레이아웃이 한 프레임 깜빡이는 걸 막는다.
        // (showNotice의 metal_dirty도 이 renderTick이 그린다.)
        withSurface(primary) {
            // M3f: primary(창 0)도 저장된 창 frame으로 복원(없으면 현행 기본 위치). resize 전에 setFrame해 resize가
            // 복원 크기를 세션에 전달하게 한다(추가 창은 createTerminalWindow에서 동일 처리).
            if let w = primary?.window { applyRestoredWindowFrame(w, text: text, index: 0) }
            resizeAppSessionFromWindow()
            _ = renderTick()
        }
        // M3e: 저장 시점 활성(key)이던 창을 다시 focus한다(docs/window-surface-mobility.md §8A.8). Zig가 active-window=1
        // 마커가 있는 창의 **블록 인덱스**를 주고(없으면 -1 → 무동작, 현행 동작 = 마지막 생성 창 key 유지),
        // windowByBlock으로 그 블록에 해당하는 실제 창을 골라 key로 올린다(라이브 windows 배열에 직접 인덱싱하지
        // 않는다 — 위 매핑 주석의 도메인 발산 방지). createTerminalWindow가 각자 makeKeyAndOrderFront하므로 복원 loop
        // **뒤**(마지막)에 호출해야 활성 창이 최종 key가 된다. 그 블록 창이 spawn 실패로 없으면 건너뛴다(best-effort).
        let activeIndex = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_workspace_active_window(session, buf.baseAddress, buf.count)
        }
        if activeIndex >= 0, let keyWindowSurface = windowByBlock[Int(activeIndex)] {
            keyWindowSurface.window?.makeKeyAndOrderFront(nil)
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
            bypassQuitConfirm = true // 창 닫기/세션 종료에 따른 종료 — applicationShouldTerminate가 재확인하지 않게
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

    private func configuredFrameLoopRateHz() -> UInt32 {
        guard let session = (activeSurface ?? primary)?.appSession else { return 60 }
        return max(1, maru_macos_app_session_frame_rate_hz(session))
    }

    private func currentFrameLoopRateHz() -> UInt32 {
        if frameLoopRateHz > 0 { return frameLoopRateHz }
        return configuredFrameLoopRateHz()
    }

    private func restartFrameLoopTicksIfNeeded() {
        let hz = configuredFrameLoopRateHz()
        guard tickTimer != nil else {
            frameLoopRateHz = hz
            return
        }
        guard hz != frameLoopRateHz else { return }
        startFrameLoopTicks()
    }

    private func startFrameLoopTicks() {
        tickTimer?.invalidate()
        let hz = configuredFrameLoopRateHz()
        frameLoopRateHz = hz
        // Swift는 frame pacing만 정한다. PTY queue drain, SurfaceRuntime 적용,
        // RenderFrame 준비는 모두 Zig FrameLoop.tick이 소유한다.
        let timer = Timer(timeInterval: 1.0 / Double(hz), repeats: true) { [weak self] _ in
            // Timer 콜백은 main run loop(main thread)에서 실행되고 이 controller는 @MainActor다.
            // Task로 감싸면 매 tick마다 async hop과 할당이 생기므로 main에서 바로 호출한다.
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
        // 컨트롤 플레인 요청을 메인에서 drain한다(§5 단일 디스패치=메인 marshal). 살아있는 세션 목록(일반 창 + quick)을
        // 넘겨 Zig가 창마다 collectSessionInto로 스냅샷을 조립·auth·dispatch한다(§2 Swift는 열거만). 요청이 없으면 무동작.
        drainControlServer()
        restartFrameLoopTicksIfNeeded()
    }

    /// 컨트롤 플레인 라이브 서버 drain: 살아있는 세션(일반 창 + quick)을 collector 참조 배열로 모아 Zig에 넘긴다.
    /// window_id=창 토큰(위치 메타), window_kind: 0=일반, 1=quick. app_session 없는 창은 건너뛴다(§2 열거만 — 평탄화·
    /// auth·dispatch는 Zig). 서버 미시작이면 무동작. 매 tick 호출되지만 요청이 없으면 Zig가 즉시 반환한다.
    private func drainControlServer() {
        guard controlServerStarted else { return }
        // #4 값싼 게이트: 대기 요청이 없으면 refs 배열 힙 할당·창별 copy 없이 즉시 반환한다(매 tick 최대 120Hz 렌더
        // 핫패스에서 0-할당). drain 자체가 여전히 권위 있는 소비 지점 — 확인 직후 도착한 요청은 다음 tick에서 처리된다.
        guard maru_macos_control_server_has_pending() != 0 else { return }
        var refs: [MaruControlSessionRef] = []
        refs.reserveCapacity(windows.count + 1)
        for surface in windows {
            if let session = surface.appSession {
                refs.append(MaruControlSessionRef(app_session: session, window_id: surface.token, window_kind: 0, reserved: 0))
            }
        }
        if let quick, let session = quick.appSession {
            refs.append(MaruControlSessionRef(app_session: session, window_id: quick.token, window_kind: 1, reserved: 0))
        }
        refs.withUnsafeBufferPointer { buf in
            maru_macos_control_server_drain(buf.baseAddress, buf.count)
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

        // theme.follow-system 초기 외관 1회 적용 — 세션이 생성된 첫 tick에 현재 시스템 light/dark를 알린다(F2-9).
        // 위 guard let appSession 뒤라 세션 존재가 보장된다(applySystem...은 windows를 순회해 각 세션에 알림).
        if !didApplyInitialAppearance {
            didApplyInitialAppearance = true
            applySystemAppearanceToAllSessions()
        }

        var summary = MaruAppHostFrameSummary()
        let status = maru_macos_app_session_tick(appSession, currentFrameLoopRateHz(), &summary)
        appSessionStatus = status
        if status == Self.statusOK {
            latestFrameSummary = summary
            // metal frame이 바뀌었거나(generation) surface 재칠이 필요할 때만 그린다.
            if summary.metal_generation != lastSeenMetalGeneration || metalNeedsRedraw {
                lastSeenMetalGeneration = summary.metal_generation
                drawMetalFrame()
            }
            drainOsc52Clipboard() // OSC 52: 이번 tick에 셸이 보낸 클립보드 쓰기를 NSPasteboard에 반영(정책 gate는 Zig).
            drainNotificationAuthorizationRequest() // 세팅에서 데스크톱 알림 토글을 켰으면 macOS 알림 권한을 요청한다.
            drainNotification() // OSC 9/777: 이번 tick에 셸이 보낸 데스크톱 알림을 네이티브 알림으로 띄운다.
            drainBell() // G12 BEL: 이번 tick에 셸이 보낸 벨(0x07)을 시스템 벨로 울린다.
            drainBellBadge() // BEL이 언포커스 시 울렸으면 Dock 배지를 띄운다(config bell.dock-badge).
            drainMouseHide() // 타이핑(글자 입력) 중이면 마우스 커서를 숨긴다(config input.mouse-hide-while-typing).
            drainClipboardAction() // 우클릭(input.right-click=paste·menu)이 요청한 OS 클립보드 복사/붙여넣기를 실행한다.
            drainClipboardRead() // OSC 52 읽기(osc52.read=allow): 셸 프로그램의 `?` 쿼리에 시스템 클립보드를 base64로 응답.
            drainFilePick() // 세팅 window.background-image 행 활성: NSOpenPanel(PNG)을 열어 고른 경로를 config에 적용.
            drainColorSample() // HSV picker `i`(스포이드): NSColorSampler로 화면 색을 추출해 picker에 반영(비동기).
            drainSidebarConfig() // view options(⚙) 토글이 바뀌었으면 config 파일에 반영(persist).
            drainGlobalHotkeys() // 글로벌 핫키가 라이브로 바뀌었으면(녹음/해제·reload·reset) OS에 재등록(unregister 후 register).
            drainMenuDirty() // 커맨드 카탈로그가 재빌드됐으면(rebind/unbind·reload·reset 확정) 메뉴바 keyEquivalent 다시 빌드.
            drainQuitDecision(summary) // Cmd+Q 종료 확인 모달이 확정/취소됐으면 NSApp.reply로 종료를 진행/취소한다.
        }
        return status
    }

    // Cmd+Q 종료 확인 모달의 결정을 host로 한 번 전달받아 처리한다(one-shot). applicationShouldTerminate가
    // .terminateLater로 보류한 종료를, 사용자가 모달에서 "종료"/"취소"하면 다음 tick FrameSummary.quit_decision
    // (1=accepted·2=cancelled)으로 와 NSApp.reply(toApplicationShouldTerminate:)로 종료를 마무리한다. 종료 확인이
    // 떠 있는 활성 세션의 tick만 비-0을 싣고(다른 세션은 0), quitConfirmPending 가드가 단 한 번만 reply하게 한다.
    private func drainQuitDecision(_ summary: MaruAppHostFrameSummary) {
        guard quitConfirmPending else { return }
        switch summary.quit_decision {
        case 1: // accepted — 종료 진행
            quitConfirmPending = false
            bypassQuitConfirm = true // reply(true)가 부를 후속 terminate 경로에서 재확인 방지
            NSApp.reply(toApplicationShouldTerminate: true)
        case 2: // cancelled — 종료 취소, 앱 유지
            quitConfirmPending = false
            NSApp.reply(toApplicationShouldTerminate: false)
        default: // 0 = 아직 대기
            break
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        // Cmd만 눌린 조합인지(Shift/Option/Control 동반 아님). 이렇게 정확히 봐야 Cmd+Shift+C 같은
        // 조합이 복사/붙여넣기로 삼켜지지 않고 키 인코더(향후 별도 바인딩)로 흘러간다.
        // 키 비교는 글자가 아니라 물리 키코드다(kVK_ANSI_C=8, V=9) — 한글 입력 모드('ㅊ'/'ㅍ')
        // 에서도 Cmd+C/V가 동작한다(레이아웃 독립 단축키 정책).
        // 세팅 등 오버레이/keybind 녹음 중이면 OS 단축키 가로채기(Cmd+C/V 복사·붙여넣기, Shift+PageUp 스크롤,
        // Cmd+↑↓ 프롬프트 점프)를 전부 건너뛰고 키를 그대로 코어(sendKeyEvent → handleKeyEvent)로 보낸다 — 모달
        // 입력 차단·chord 녹음이 거기서 처리되게 한다(안 그러면 녹음할 ⌘C가 복사로 새거나 모달 위에서 단축키가 먹는다).
        if !anyOverlayOpen {
            // Cmd만 눌린 조합인지(Shift/Option/Control 동반 아님). 키 비교는 글자가 아니라 물리 키코드(kVK_ANSI_C=8, V=9).
            let chordMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Cmd+C는 선택 텍스트 복사(클립보드는 OS 소유라 여기서 처리). 선택 추출은 Zig가 한다.
            if chordMods == .command, event.keyCode == 8 {
                copySelectionToPasteboard()
                return
            }
            // Cmd+V: NSPasteboard의 텍스트를 Zig에 넘긴다 — 개행 정규화·bracketed paste 감싸기는 Zig가 한다.
            if chordMods == .command, event.keyCode == 9 {
                pastePasteboardText()
                return
            }
            // Shift+PageUp/Down는 PTY로 보내지 않고 스크롤백 뷰포트를 한 화면씩 스크롤한다(방향만 넘김, page 크기는 Zig).
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
            // Cmd+↑/↓: OSC 133 프롬프트 블록으로 점프(분류·이동은 Zig core, 여기선 방향만).
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

    // NSEvent 모디파이어 → xterm mods 비트(4=shift, 8=opt/meta, 16=ctrl, 32=command). mouse reporting(handleMouse·
    // handleMouseMotion) 공용. command(32)는 사이드바 그룹 드래그 "Cmd=중첩/없으면 형제" 판정에 쓰이고, 터미널 마우스
    // 리포트 경로로 갈 때는 Zig(app_session.mouse·mouseMoved)가 32비트를 마스킹해 뺀다(command=32이 SGR motion 비트 32와
    // 충돌해 리포트가 오염되므로 — input_report.zig reportMouse의 cb=button+mods+motion). urlModsBits(command=32)와 동형.
    private func modsBits(_ event: NSEvent) -> Int32 {
        var mods: Int32 = 0
        if event.modifierFlags.contains(.shift) { mods |= 4 }
        if event.modifierFlags.contains(.option) { mods |= 8 }
        if event.modifierFlags.contains(.control) { mods |= 16 }
        if event.modifierFlags.contains(.command) { mods |= 32 }
        return mods
    }

    // 사이드바 헤더 빈 영역(maru "타이틀바")에서의 down을 네이티브 타이틀바처럼 처리한다 — 더블클릭=zoom(시스템
    // 설정의 타이틀바 더블클릭 동작), 단일=performDrag(창 이동). 처리하면 true(호출자는 일반 마우스 처리를 건너뛴다).
    // 빈 영역 판정은 Zig(is_window_drag_region)가 단일 출처 — 아이콘·검색·터미널이면 0이라 false.
    func handleWindowChromeMouseDown(_ event: NSEvent, in view: NSView) -> Bool {
        guard let session = appSession, let window else { return false }
        let (xPx, yPx) = backingPx(view.convert(event.locationInWindow, from: nil), in: view)
        guard maru_macos_app_session_is_window_drag_region(session, xPx, yPx) != 0 else { return false }
        if event.clickCount == 2 {
            // 시스템 설정(데스크탑 및 Dock > "윈도우 제목 막대를 두 번 클릭하여")을 따른다 — 네이티브 타이틀바를 숨겨
            // AppKit 자동 처리가 안 되므로 직접 읽는다. AppleActionOnDoubleClick: Maximize(=zoom, 기본)·Minimize·None.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
        return true
    }

    // 마우스 좌표를 backing 픽셀(좌상단 원점)로 환산해 Zig 선택 모델에 넘긴다(kind 1=down/2=drag/3=up).
    func handleMouse(_ event: NSEvent, kind: Int32, in view: NSView) {
        guard let session = appSession else { return }
        // 마우스 다운(kind==1)은 텍스트 입력이 아니다 — 조합 중이면 Zig로 넘기기 '전'에 확정한다. 좌·중·우
        // 다운이 모두 여기로 모이고(rightMouseDown/otherMouseDown 포함), 사이드바 카드·탭 바의 탭/Term 전환은
        // 버튼이 아니라 kind==1로만 게이트되므로(app_session.zig mouse) 중간 클릭 전환도 이 한 곳에서 덮인다.
        if kind == 1 { (view as? MaruMetalTerminalView)?.commitMarkedTextIfComposing() }
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
    // NSEvent 수식키 플래그를 hover/url_at ABI의 mods 비트(xterm 규약: shift=4, alt/option=8, control=16,
    // command=32)로 변환한다. modifier '정책'(어느 키가 URL 활성인지)은 Zig가 config로 판정하고, Swift는 순수
    // 변환만 한다(네이티브 최소·이식성 — v71). command 비트는 URL 판정 전용(mouse reporting과 별개).
    static func urlModsBits(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= 4 }
        if flags.contains(.option) { m |= 8 }
        if flags.contains(.control) { m |= 16 }
        if flags.contains(.command) { m |= 32 }
        return m
    }

    // NSEvent 수식키를 단축키 힌트 머신(key_hint_on_flags)의 mods_bits로 변환 — command_catalog.mod_*와 동일 인코딩
    // (shift=1·control=2·option=4·command=8). urlModsBits(xterm 규약)와 인코딩이 다르므로 별도. 순수 변환만(정책=Zig).
    static func hintModsBits(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= 1 }
        if flags.contains(.control) { m |= 2 }
        if flags.contains(.option) { m |= 4 }
        if flags.contains(.command) { m |= 8 }
        return m
    }

    func handleHover(_ event: NSEvent, in view: NSView) {
        updateHover(atWindowPoint: event.locationInWindow, mods: Self.urlModsBits(event.modifierFlags), in: view)
    }

    // 수식키를 누르거나 떼는 순간의 재평가. flagsChanged(키 이벤트)의 locationInWindow는 정의되지
    // 않으므로 쓰지 않고, 창의 현재 포인터 위치(mouseLocationOutsideOfEventStream)를 권위 있는
    // 좌표로 쓴다. 어느 수식키든 바뀌면 재평가한다(URL 활성 키는 Zig config가 정함).
    func handleModifierHover(_ event: NSEvent, in view: NSView) {
        guard let point = view.window?.mouseLocationOutsideOfEventStream else { return }
        updateHover(atWindowPoint: point, mods: Self.urlModsBits(event.modifierFlags), in: view)
    }

    // 단축키 힌트 홀드 감지(KH-4) — view.flagsChanged가 부른다. 현재 눌린 modifier 비트만 Zig 홀드 머신에 흘리고,
    // 단독성·취소·표시 판정은 머신이 한다(단일 출처). flagsChanged는 keyCode 없이 modifierFlags만 주므로 머신은 현재
    // 플래그가 정확히 트리거 하나인지로 arm/cancel을 정한다.
    func handleModifierFlags(_ event: NSEvent) {
        guard let session = appSession else { return }
        let action = maru_macos_app_session_key_hint_on_flags(session, Self.hintModsBits(event.modifierFlags))
        applyKeyHintAction(action)
    }

    // 실제 키 입력(= 단축키 실행)·포커스 상실 시 호출 — 머신에 취소를 흘린다(대기 중이면 cancel, 표시 중이면 hide).
    // 정상 ⌘+키가 HUD를 깜빡이지 않게(keyDown이 대기 타이머를 깸) + 단축키를 누르면 HUD가 사라지게 한다.
    //
    // `surface`는 **어느 창의 홀드를 취소할지** 고른다. 홀드 머신·배지 visible은 surface(AppSession)별이므로, 멀티
    // 윈도우에서 떠나는 창의 배지를 끄려면 **그 창의 surface**로 취소해야 한다 — nil이면 활성 surface(keyDown은 키
    // 창=활성이라 기본값으로 충분, windowDidResignKey는 떠나는 창을 명시로 넘긴다). 타이머는 컨트롤러-전역(키 창만
    // arm)이라 session 해석과 무관하게 **항상 무효화**한다(session nil인 teardown에도 댕글링 타이머가 안 남게).
    func cancelKeyHintHold(for surface: TerminalSurface? = nil) {
        keyHintTimer?.invalidate()
        keyHintTimer = nil
        guard let session = (surface ?? activeSurface)?.appSession else { return }
        applyKeyHintAction(maru_macos_app_session_key_hint_cancel(session))
    }

    // 머신 Action(app_host_abi v88: 0=none·1=arm_timer·2=cancel·3=show·4=hide)을 OS 부수효과로 매핑한다 — gesture 정책·
    // visible 토글은 머신이 이미 했고, Swift는 OS 타이머 clock과 redraw만 책임진다. arm_timer는 delay 만큼 one-shot 타이머를
    // 걸고 만료 시 머신에 on_timer를 흘린다; cancel/hide는 대기 타이머를 무효화; show/hide는 다음 프레임 redraw.
    private func applyKeyHintAction(_ action: Int32) {
        switch action {
        case 1: // arm_timer (머신이 재-arm을 막으므로 keyHintTimer는 이미 nil — 추가 invalidate는 불필요)
            // keyHintDelayMs 읽기 실패(arm 직후 session nil) 시 fallback은 config 기본값 keyhint.delay(400ms, theme.zig)와
            // 일치시킨다 — SSOT 드리프트 방지(머신이 arm을 냈다는 건 session이 있었다는 뜻이라 실제로는 거의 안 쓰임).
            let delay = TimeInterval(keyHintDelayMs ?? 400) / 1000.0
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let session = self.appSession else { return }
                    self.keyHintTimer = nil
                    // 만료 — 글로벌 modifier를 다시 안 읽는다(루트커즈 수정). 머신이 armed면 show, 취소됐으면 none.
                    self.applyKeyHintAction(maru_macos_app_session_key_hint_on_timer(session))
                }
            }
            RunLoop.main.add(timer, forMode: .common) // live-resize 중에도 안 멈추게(tickTimer와 같은 .common 모드)
            keyHintTimer = timer
        case 2, 4: // cancel, hide
            keyHintTimer?.invalidate()
            keyHintTimer = nil
            if action == 4 { markMetalNeedsRedraw() } // hide → 배지 사라진 프레임
        case 3: // show
            markMetalNeedsRedraw() // visible은 머신이 켰음 → 배지 그린 프레임
        default: // 0 none
            break
        }
    }

    private func updateHover(atWindowPoint windowPoint: NSPoint, mods: Int32, in view: NSView) {
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
        // mods는 Zig가 config url-click-modifier와 비교해 URL 밑줄을 켜는 데 쓴다.
        var cursorKind: Int32 = 1
        guard maru_macos_app_session_hover(session, xPx, yPx, mods, &cursorKind) == Self.statusOK else { return }
        Self.cursor(for: cursorKind).set()
    }

    // CursorKind(app_host_abi.h: 0=arrow, 1=iBeam, 2=pointingHand, 3=resizeLeftRight, 4=resizeUpDown, 5=openHand) → NSCursor.
    private static func cursor(for kind: Int32) -> NSCursor {
        switch kind {
        case 0: return .arrow
        case 2: return .pointingHand
        case 3: return .resizeLeftRight
        case 4: return .resizeUpDown
        case 5: return .openHand // pane grip 호버(드래그 손잡이)
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

    // (config 수식키)+클릭: Zig가 인식한 URL을 기본 브라우저로 연다(NSWorkspace는 OS 소유 경계). modifier 판정은
    // Zig가(url_at에 mods 전달 — url-click-modifier 불일치면 빈 반환). URL을 열었으면 true(클릭 소비), 아니면 false
    // (호출자가 일반 선택으로 진행). 일반 좌클릭마다 호출되지만 Zig가 수식키 불일치 시 즉시 빈 반환이라 가볍다.
    func handleUrlClick(_ event: NSEvent, in view: NSView) -> Bool {
        guard let session = appSession else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        let xPx = Double(local.x * scale)
        let yPx = Double((view.bounds.height - local.y) * scale)
        let mods = Self.urlModsBits(event.modifierFlags)
        var ptr: UnsafePointer<UInt8>? = nil
        var len: size_t = 0
        var kind: Int32 = 0
        guard maru_macos_app_session_url_at(session, xPx, yPx, mods, &ptr, &len, &kind) == Self.statusOK,
              let bytes = ptr, len > 0 else { return false }
        let text = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        // kind==1=파일 경로(Zig가 cwd/$HOME로 resolve·존재 확인한 절대 경로) → URL(fileURLWithPath:)로 공백·비ASCII
        // 경로를 무손실 처리(URL(string:)은 그런 경로에 nil). 그 외(웹/스킴 URL)는 URL(string:). 둘 다 기본 앱/브라우저로.
        let url: URL? = (kind == 1) ? URL(fileURLWithPath: text) : URL(string: text)
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func pastePasteboardText() {
        // Cmd+V 붙여넣기. 베이스/결정: Ghostty getOpinionatedStringContents 동작(동작 비교만 — 코드 표현은 옮기지
        // 않은 독립 구현). NSURL이 있으면 **파일 URL은 경로를 셸 이스케이프**(셸이 공백에서 단어를 쪼개지 않게),
        // **그 외(웹) URL은 absoluteString 그대로**(이스케이프하면 붙여넣은 URL이 깨진다), URL 표현이 없으면 평문
        // 텍스트. 이스케이프 '메커니즘'은 Zig(app_session.shellEscapeJoin)가 소유한다 — Swift는 pasteboard 타입으로
        // "이스케이프 대상인지"만 판정해 NUL 구분 토큰(escapeItems: true) 또는 raw(false)로 넘긴다. 드래그
        // (handleDrop)는 사용자 제스처라 웹 URL도 이스케이프하는 별도 판정(pasteboardDropPayload)이라 분리한다.
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            if urls.allSatisfy({ $0.isFileURL }) {
                // 파일 경로(들) — Zig가 각 경로를 셸 이스케이프 후 공백 join(공백 든 경로가 안 쪼개지게).
                sendPasteText(urls.map { $0.path }.joined(separator: "\u{0}"), escapeItems: true)
            } else {
                // 웹 URL 포함 — absoluteString 그대로(이스케이프하면 ?,&,= 등이 깨진다). 파일+웹 혼합은 한
                // 클립보드에 사실상 안 나오므로(파일 복사=파일들, 링크 복사=웹) 웹 분기로 단순화한다.
                sendPasteText(urls.map { $0.absoluteString }.joined(separator: " "), escapeItems: false)
            }
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendPasteText(text, escapeItems: false)
            return
        }
        if let pngData = clipboardImagePng(pb) {
            // 비트맵 이미지(스크린샷·복사, 파일 아님) — URL·text가 없을 때만(리치 콘텐츠는 텍스트 우선해 의도치
            // 않은 이미지 삽입 방지). 원격 maru ssh면 PNG 바이트를 control socket으로 업로드하고(Zig가 판정,
            // true면 끝), 로컬이면 임시 PNG로 저장해 경로를 붙인다(escapeItems=true → bracketed paste로
            // claude/codex가 [Image] 인식). 둘 다 같은 PNG로 정규화해 넘기므로 원격 저장 파일(pasted-<pid>-N.png)도
            // 확장자/내용이 일치한다(스크린샷은 흔히 TIFF로만 와서, raw로 .png 저장하면 디코드가 깨진다).
            if sendDropImage(pngData) { return }
            if let imagePath = saveTempPng(pngData) {
                sendPasteText(imagePath, escapeItems: true)
            }
        }
    }

    /// 드롭된 pasteboard 내용(경로/URL/텍스트)을 삽입한다 — 뷰(MaruMetalTerminalView.performDragOperation)가 위임한다.
    /// 드롭은 사용자 제스처라 URL/파일을 모두 이스케이프한다(Cmd+V paste는 웹 URL을 이스케이프하지 않는 별도 판정 —
    /// pastePasteboardText). 전송은 **paste 경로**(sendPasteText)다 — Ghostty도 드래그를 completeClipboardPaste로
    /// 보내 터미널이 DECSET 2004를 켜면(Claude Code 등 TUI) bracketed paste로 감싸지고, 그래야 경로가 한-덩어리로
    /// 인식돼 [Image]로 첨부된다. 2004를 안 켠 일반 셸에선 raw(개행만 \r)라 escape된 경로가 안전하다. 삽입할 게 있으면 true.
    func handleDrop(_ pb: NSPasteboard) -> Bool {
        // 파일 드롭은 Zig에 위임한다 — maru ssh 원격 세션이면 control socket으로 업로드 후 원격 경로를
        // paste하고, 로컬이면 경로를 셸 이스케이프해 paste한다(분기는 Zig handleDroppedFiles). 웹 URL·평문은
        // 원격에 올릴 게 아니라 기존 paste 경로 그대로다(이미지 드롭 over SSH 3단계).
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty,
           urls.allSatisfy({ $0.isFileURL }) {
            return sendDropFiles(urls.map { $0.path }.joined(separator: "\u{0}"))
        }
        guard let payload = pasteboardDropPayload(pb) else { return false }
        sendPasteText(payload.text, escapeItems: payload.escape)
        return true
    }

    /// 드래그에서 삽입할 내용 + 셸 이스케이프 여부를 뽑는다. 우선순위는 Ghostty 드롭과 동일하다(베이스):
    /// URL > 파일 URL(경로들) > 평문(이스케이프 안 함 — 실행할 명령일 수 있음). escape=true면 text는 NUL('\0')
    /// 구분 토큰이고 Zig가 각 토큰을 셸 이스케이프 후 공백 join한다(이스케이프 메커니즘은 Zig 단일 출처).
    private func pasteboardDropPayload(_ pb: NSPasteboard) -> (text: String, escape: Bool)? {
        if let url = pb.string(forType: .URL) {
            return (url, true) // 드래그된 URL — 단일 토큰, 이스케이프
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return (urls.map { $0.path }.joined(separator: "\u{0}"), true) // 파일 경로들 — 각 이스케이프 후 공백 join
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            return (text, false)
        }
        if let pngData = clipboardImagePng(pb), let imagePath = saveTempPng(pngData) {
            // 비트맵 이미지(URL·파일·텍스트가 없을 때만) — 임시 PNG 경로(이스케이프). tiff+텍스트 리치 드래그는 위 텍스트 우선.
            return (imagePath, true)
        }
        return nil
    }

    /// 클립보드/드래그 pasteboard의 이미지 비트맵을 **PNG 데이터로 정규화**해 돌려준다(없으면 nil). PNG가 있으면
    /// 그대로, 없고 TIFF면 NSBitmapImageRep로 PNG 변환 — 원격 업로드(sendDropImage)와 로컬 임시저장(saveTempPng)이
    /// 같은 PNG 바이트를 쓰게 해, 원격 저장 파일명(pasted-<pid>-N.png)의 확장자/내용이 일치하도록 한다(스크린샷 ⌃⌘⇧4은
    /// 흔히 TIFF로만 온다). 스크린샷·브라우저 이미지 복사처럼 파일이 아니라 비트맵으로 온 이미지를 claude/codex가
    /// [Image]로 인식하게 하는 토대 — iTerm2의 "비트맵→임시파일→경로" 동작 참고(코드 표현은 옮기지 않은 독립 구현).
    private func clipboardImagePng(_ pb: NSPasteboard) -> Data? {
        if let p = pb.data(forType: .png) { return p }
        // PNG가 없으면 TIFF·JPEG 등 비트맵을 NSBitmapImageRep로 PNG 정규화(스크린샷은 TIFF, 일부 앱은 JPEG로 복사).
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let d = pb.data(forType: type), let rep = NSBitmapImageRep(data: d) {
                return rep.representation(using: .png, properties: [:])
            }
        }
        return nil
    }

    /// PNG 데이터를 pasteImageDir에 UUID 이름으로 **atomic** 저장하고 경로를 돌려준다(로컬 이미지 paste/drop용 —
    /// claude/codex가 경로로 [Image] 인식). atomic write로 부분 파일 노출을 막는다. 실패 시 nil(호출자 폴백). 누적
    /// 파일은 앱 시작 시 cleanupPasteImages가 비운다(paste 직후엔 claude 읽기 타이밍을 몰라 못 지움).
    private func saveTempPng(_ data: Data) -> String? {
        let dir = Self.pasteImageDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// 이미지 paste/drop이 비트맵을 저장하는 임시 PNG 디렉터리(단일 출처 — clipboardImageTempPath·cleanupPasteImages 공유).
    private static var pasteImageDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("maru-paste", isDirectory: true)
    }

    /// 앱 시작 시 이전 세션이 남긴 임시 paste 이미지를 통째로 비운다. paste 직후엔 claude/codex가 경로를 언제 읽을지
    /// 몰라 못 지우므로(읽기 전에 사라지면 [Image]가 깨짐) 누적되는데, 다음 실행 시작에서 청소한다. best-effort(실패 무시).
    private func cleanupPasteImages() {
        try? FileManager.default.removeItem(at: Self.pasteImageDir)
    }

    /// 텍스트를 paste 경로로 PTY에 보낸다 — **bracketed paste**(DECSET 2004) 감싸기·개행 정규화·셸 이스케이프는
    /// 모두 Zig 소유. Cmd+V paste와 드래그앤드롭 공용(Ghostty도 드래그를 paste 경로 completeClipboardPaste로 보낸다).
    /// escapeItems가 true면 text를 NUL('\0') 구분 토큰으로 보고 Zig가 각 토큰을 셸 이스케이프 후 공백 join한다
    /// (드래그된 파일 경로·URL). 평문·Cmd+V 웹 URL은 false(raw).
    private func sendPasteText(_ text: String, escapeItems: Bool) {
        guard let session = appSession, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_paste_text(session, buf.baseAddress, buf.count, escapeItems ? 1 : 0)
        }
    }

    /// 드롭된 파일 경로들(NUL 구분)을 Zig로 보낸다. Zig가 maru ssh 원격 여부로 업로드/로컬 paste를 가른다.
    private func sendDropFiles(_ pathsNul: String) -> Bool {
        guard let session = appSession, !pathsNul.isEmpty else { return false }
        let bytes = Array(pathsNul.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_drop_files(session, buf.baseAddress, buf.count)
        }
        return true
    }

    /// 클립보드 이미지 바이트를 Zig로 보낸다. 원격 maru ssh면 업로드+경로 paste 후 true, 로컬이면 false.
    private func sendDropImage(_ data: Data) -> Bool {
        guard let session = appSession, !data.isEmpty else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            return maru_macos_app_session_drop_image(session, base.assumingMemoryBound(to: UInt8.self), raw.count) != 0
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

    // OSC 9/777·앱 시작: 알림 권한을 앱 실행 중 한 번만 선요청한다(번들 ID가 있을 때만 — bare 실행 파일은
    // UNUserNotificationCenter가 못 떠서 graceful skip). 아직 결정 전이면 macOS 권한 팝업이 뜨고, 이미 결정됐으면
    // (허용/거부) requestAuthorization은 UI 없이 즉시 반환한다. 거부 상태에서 사용자가 세팅으로 다시 켜려는 명시 동작은
    // requestNotificationAuthorizationFromSettings가 따로 처리한다(시작 요청이 1회성 팝업을 이미 소비했으므로 재요청은
    // 무력 — 시스템 설정 창을 연다).
    private var notificationAuthRequested = false
    private func ensureNotificationAuthorization() {
        guard !notificationAuthRequested, Bundle.main.bundleIdentifier != nil else { return }
        notificationAuthRequested = true
        // delegate는 applicationDidFinishLaunching에서 launch 완료 전에 이미 등록했다(콜드 런치 클릭 누락 방지) —
        // 여기선 권한만 요청한다(거부돼도 add는 무해히 무시되므로 결과는 안 본다).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // 세팅 GUI에서 notifications.agent-complete/osc를 켠 경우, 사용자가 지금 데스크톱 알림을 원한다고 명시한 것이다.
    // 단순히 requestAuthorization를 다시 부르면 안 된다 — 시작 시 ensureNotificationAuthorization이 매 tick 선요청하며
    // OS의 1회성 권한 팝업을 이미 소비했으므로, 거부 상태의 사용자에겐 UI 없이 false만 돌아와 무력하다. 그래서 현재
    // 권한 상태를 먼저 보고(getNotificationSettings) 분기한다: notDetermined면 요청(팝업), denied면 macOS가 재팝업을
    // 안 띄우므로 시스템 알림 설정 창을 열어 직접 켤 경로를 주고, 이미 허용됐으면 무동작. 어떤 config 키가 대상인지는
    // Zig가 정하고 Swift는 OS 권한 API만 호출한다(경계: 정책=Zig, OS 표시/설정 열기=Swift).
    private func drainNotificationAuthorizationRequest() {
        guard let session = appSession else { return }
        guard maru_macos_app_session_take_notification_authorization_request(session) != 0 else { return }
        guard Bundle.main.bundleIdentifier != nil else { return } // bare 실행 파일은 알림 API 사용 불가 — skip
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // 완료 콜백은 백그라운드 큐로 온다 — UI성 호출(requestAuthorization 팝업·NSWorkspace)은 main으로 hop한다.
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                switch status {
                case .notDetermined:
                    // 아직 OS 결정 전(시작 요청이 안 돌았거나 사용자가 팝업을 안 닫음) — 권한 팝업을 띄운다.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                case .denied:
                    // 거부됨 — requestAuthorization 재호출은 macOS가 UI 없이 무시한다. 시스템 알림 설정 창으로 안내한다.
                    Self.openSystemNotificationSettings()
                default:
                    break // authorized/provisional/ephemeral — 이미 켜져 있어 무동작.
                }
            }
        }
    }

    // macOS 시스템 설정의 '알림' 창을 연다(Ventura+ 패널 ID). 거부된 알림 권한을 사용자가 직접 다시 켤 유일한 경로다 —
    // macOS는 설치당 권한 팝업을 한 번만 띄우므로 앱이 재요청해도 UI가 안 뜬다. NSWorkspace는 OS 소유 경계(URL 열기와 동형).
    private nonisolated static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notification-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // OSC 9/777·에이전트 완료: 코어가 모은 데스크톱 알림(title/body/surface_id)을 활성 세션에서 drain해 네이티브
    // 알림으로 띄운다(매 tick). 알림이 없으면 Zig가 has=0을 줘 아무 것도 안 한다. OSC 9는 title이 없어(빈 문자열) 앱
    // 이름으로 폴백한다. 번들 ID가 없으면(app shell 일부) UNUserNotificationCenter를 못 써 조용히 건너뛴다(GUI 수동
    // 검증은 제품 앱). userInfo에 (창 토큰, surface_id)를 실어 클릭 시 didReceive가 발신 터미널로 점프하게 한다.
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
        var surfaceId: UInt64 = 0
        var foreground: UInt32 = 0
        guard maru_macos_app_session_pending_notification(session, &has, &titlePtr, &titleLen, &bodyPtr, &bodyLen, &surfaceId, &foreground) == Self.statusOK,
              has != 0 else { return }
        guard Bundle.main.bundleIdentifier != nil else { return } // 번들 없으면 알림 API 사용 불가 — skip
        let title = titleLen > 0 ? String(decoding: UnsafeBufferPointer(start: titlePtr!, count: titleLen), as: UTF8.self) : ""
        let body = bodyLen > 0 ? String(decoding: UnsafeBufferPointer(start: bodyPtr!, count: bodyLen), as: UTF8.self) : ""
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "maru" : title // OSC 9는 title 없음 → 앱 이름
        content.body = body
        // drainNotification은 tickAppSession이 explicitSurface로 이 창을 고른 컨텍스트에서 돈다 — activeSurface가 곧
        // 발신 창이다. 그 token과 surface_id를 실어, 클릭 시 token으로 창/세션을, surface_id로 그 안의 Term을 찾는다.
        // fg=전면 배너 여부(Zig 결정) — willPresent가 읽어 자기 화면 OSC 알림 배너 노이즈를 억제한다.
        content.userInfo = ["wt": activeSurface?.token ?? 0, "sid": surfaceId, "fg": foreground]
        // identifier는 UUID 유지(알림 dedup 식별자 — (token, surface_id)를 identifier에 쓰면 같은 터미널의 연속 알림이
        // 서로 덮어써 사라진다). 라우팅 정보는 userInfo로 분리한다.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 알림 userInfo에서 (창 토큰, surface_id)를 꺼낸다(drainNotification이 실은 ["wt","sid"]를 역으로 읽는다).
    /// token이 양수일 때만 유효 — 0(미설정 sentinel)이거나 외부/레거시 알림이면 nil이라 클릭이 무시된다. 순수 함수라
    /// AppKit 의존이 없어 라우팅 파싱을 단위로 검증할 수 있다(세션 내 역조회는 Zig activate_surface가 소유 — 네이티브 최소).
    nonisolated static func parseNotificationRoute(_ userInfo: [AnyHashable: Any]) -> (token: UInt64, surfaceId: UInt64)? {
        guard let wt = (userInfo["wt"] as? NSNumber)?.uint64Value, wt != 0,
              let sid = (userInfo["sid"] as? NSNumber)?.uint64Value else { return nil }
        return (token: wt, surfaceId: sid)
    }

    // 알림 클릭 → 발신 터미널로 점프. userInfo의 (token, surface_id)에서 token으로 정확한 창(세션)을 고르고(surface.id는
    // 세션-로컬이라 token 없이 id만으론 창 간 오활성화가 난다), 창을 키로 올린 뒤 surface_id를 activate_surface로 넘겨
    // Zig가 탭/pane/Term을 활성화한다(경계: 창 활성화=Swift AppKit, 세션 내 역조회/포커스=Zig). 창/Term이 이미 닫혔으면
    // 무동작(창만 활성화). completionHandler는 모든 경로에서 호출한다(누락 시 OS 경고).
    // UNUserNotificationCenterDelegate 요구사항은 nonisolated라 메서드도 nonisolated로 선언하고, 실제 작업은
    // MainActor에서 한다 — 이 콜백은 메인 스레드로 오므로 assumeIsolated로 동기 진입한다(코드베이스 공통 패턴).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            defer { completionHandler() } // 누락 시 OS 경고 — 모든 경로에서 보장.
            guard let route = Self.parseNotificationRoute(response.notification.request.content.userInfo) else { return }
            guard let surface = surfaceForToken(route.token) else { return } // 창이 닫혔으면 무동작.
            if surface === quick, let panel = surface.window {
                // quick 패널은 숨김 시 화면 밖(frames.hidden)에 있어, 그냥 makeKeyAndOrderFront하면 보이지 않는 창이
                // 키를 가져간다. 숨김 상태면 정식 show 경로(슬라이드/페이드 + grid + 상태)를 태우고, 이미 보이면 키만 올린다.
                if panel.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    showQuickTerminalAnimated(panel) // 내부에서 makeKeyAndOrderFront + NSApp.activate 수행
                }
            } else {
                surface.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if let session = surface.appSession {
                _ = maru_macos_app_session_activate_surface(session, route.surfaceId)
            }
        }
    }

    // 앱이 전면일 때 배너를 띄울지 결정한다. fg(Zig foreground_banner): 1=에이전트 완료(지금 안 보는 탭, !is_current
    // 게이트)는 전면에서도 배너+소리로 알려야 유용 / 0=OSC 9·777(활성 surface가 보내 사용자가 보고 있을 수 있음)은
    // 배너 없이 알림 센터 목록에만(.list) — 자기 화면 알림 노이즈 억제. fg 누락(외부/레거시 알림)은 보수적으로 배너.
    // "전면 배너 여부"는 알림 종류가 정하는 정책이라 Zig가, 표시 스타일 적용은 OS 표면이라 Swift가 한다(경계).
    // self 접근이 없어 assumeIsolated 없이 nonisolated 본문에서 바로 completionHandler를 호출한다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let fg = (notification.request.content.userInfo["fg"] as? NSNumber)?.uint32Value ?? 1
        completionHandler(fg != 0 ? [.banner, .sound] : [.list])
    }

    // G12 BEL: 코어가 모은 벨(0x07)을 활성 세션에서 drain해 시스템 벨을 울린다(매 tick, 한 tick 1회로 합쳐짐).
    // 벨이 없으면 Zig가 0을 줘 아무 것도 안 한다.
    private func drainBell() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_bell(session) != 0 {
            NSSound.beep()
        }
    }

    // BEL이 창 포커스 없을 때 울렸으면(config bell.dock-badge) Dock 아이콘에 ● 배지를 띄운다(놓친 알림 표시). Zig가
    // 언포커스 판정·1회성 신호를 소유하고(take_bell_badge), 배지는 OS Dock 리소스라 Swift가 띄운다. 포커스 복귀 시
    // applicationDidBecomeActive가 지운다(아래). dockTile.badgeLabel은 앱 전역이라 어느 창이든 포커스되면 사라진다.
    private func drainBellBadge() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_bell_badge(session) != 0 {
            NSApp.dockTile.badgeLabel = "●"
        }
    }

    // 우클릭(input.right-click=paste·menu)이 요청한 OS 클립보드 동작을 실행한다(매 tick). Zig가 pending_clipboard_action을
    // 세우면 1=복사·2=붙여넣기. 클립보드는 OS 소유라 여기서 실행하고, "언제" 할지는 Zig가 정한다(Cmd+C/V와 같은 경로 재사용).
    private func drainClipboardAction() {
        guard let session = appSession else { return }
        switch maru_macos_app_session_take_clipboard_action(session) {
        case 1: copySelectionToPasteboard()
        case 2: pastePasteboardText()
        default: break
        }
    }

    // OSC 52 읽기(input.osc52.read=allow): 셸 프로그램이 `OSC 52 ; <Pc> ; ? ST`로 클립보드를 물으면, Zig가 정책을
    // 통과시킨 경우(take_clipboard_read_request==1)에만 여기서 NSPasteboard 텍스트를 읽어 provide_clipboard_read로
    // 넘긴다 — Zig가 base64 OSC 52 응답을 PTY로 보낸다. **deny면 1을 안 줘 클립보드를 읽지도 않는다**(탈취 방지). 텍스트가
    // 없으면 빈 응답(len 0)을 보낸다(쿼리 자체엔 응답 — 일부 프로그램이 빈 응답을 기대). 클립보드는 OS 소유라 read만 여기서.
    private func drainClipboardRead() {
        guard let session = appSession else { return }
        guard maru_macos_app_session_take_clipboard_read_request(session) != 0 else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_provide_clipboard_read(session, buf.baseAddress, buf.count)
        }
    }

    // 타이핑(글자 입력) 중 마우스 숨김(config input.mouse-hide-while-typing): Zig가 이번 tick에 글자 입력을 PTY로
    // 보냈으면 플래그를 세운다 — drain해 1이면 NSCursor.setHiddenUntilMouseMoves(true)로 커서를 숨긴다. 복원(다음
    // 마우스 이동에서 다시 보임)은 AppKit이 자동으로 하므로 별도 unhide 핸들러가 필요 없다(F1-6).
    private func drainMouseHide() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_mouse_hide(session) != 0 {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // 세팅 window.background-image 행 활성(input 타이핑 대신 파일 선택창 — 사용자 요청): Zig가 file_pick_pending을 세우면
    // 여기서 NSOpenPanel(PNG)을 열어, 고른 파일의 절대경로를 provide_picked_file로 Zig에 넘긴다(Zig가 config 적용·라이브
    // 반영·영속). 취소면 무동작(pending은 이미 비웠으니 재시도 없음 — 사용자가 다시 활성화). 모달은 사용자 행동이라 tick
    // 블로킹이 허용된다(메인 스레드 runModal — Open Config·표준 패턴).
    private func drainFilePick() {
        guard let session = appSession else { return }
        guard maru_macos_app_session_take_file_pick_request(session) != 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png] // maru 내장 디코더는 PNG만(F2-1)
        panel.message = "배경 이미지로 쓸 PNG를 고르세요"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let bytes = Array(path.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_provide_picked_file(session, buf.baseAddress, buf.count)
        }
    }

    // NSColorSampler를 show 동안 살려둔다(비동기 콜백까지 retain — 지역 변수면 콜백 전에 해제될 수 있음).
    private var colorSampler: NSColorSampler?

    // HSV picker `i`(스포이드): Zig가 color_sample_pending을 세우면 NSColorSampler(OS 화면 색 추출기 — 돋보기로 화면 픽셀
    // 클릭)를 연다. show는 비동기라 콜백에서 고른 색(sRGB로 변환해 0~255 RGB)을 provide_sampled_color로 되돌린다. 취소면
    // nil(무동작). picker가 그 사이 닫혔으면 Zig측 setPickerRgb가 무시한다. session은 콜백 시점에 재취득(중간 변경 대비).
    private func drainColorSample() {
        guard let session = appSession else { return }
        guard maru_macos_app_session_take_color_sample_request(session) != 0 else { return }
        let sampler = NSColorSampler()
        colorSampler = sampler
        // show 콜백은 메인 스레드에서 호출된다(AppKit) — assumeIsolated로 main-actor 상태(appSession)에 안전 접근(다른
        // 콜백들과 같은 패턴). picked=nil(취소)이면 무동작. session은 콜백 시점 재취득(중간 변경 대비).
        sampler.show { [weak self] picked in
            MainActor.assumeIsolated {
                defer { self?.colorSampler = nil }
                guard let self, let s = self.appSession, let color = picked else { return }
                let srgb = color.usingColorSpace(.sRGB) ?? color
                let r = UInt32(max(0.0, min(255.0, (srgb.redComponent * 255.0).rounded())))
                let g = UInt32(max(0.0, min(255.0, (srgb.greenComponent * 255.0).rounded())))
                let b = UInt32(max(0.0, min(255.0, (srgb.blueComponent * 255.0).rounded())))
                _ = maru_macos_app_session_provide_sampled_color(s, r, g, b)
            }
        }
    }

    // view options(⚙) 메뉴에서 사이드바 표시 토글(show-branch/show-folder)을 바꾸면 Zig가 dirty 플래그를 세운다 —
    // tick마다 drain해 1이면 config 파일에 반영(persist)한다(앱→config). 변경 없으면 Zig가 0을 줘 파일을 안 건드린다.
    private func drainSidebarConfig() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_sidebar_config_dirty(session) != 0 {
            persistSidebarConfig()
        }
    }

    // 글로벌 핫키가 라이브로 바뀌면(세팅 GUI 녹음/해제·reload·reset → Zig가 global_hotkeys 재빌드 + dirty) tick마다 drain해
    // 1이면 OS 등록을 다시 깐다 — unregisterGlobalHotkeys(기존 핸들/핫키 해제, idempotent) 후 registerGlobalHotkeys(새
    // descriptor를 global_hotkeys ABI로 읽어 RegisterEventHotKey). 앱 시작 register와 같은 smoke 게이트(smoke는 자동 종료라 미등록).
    private func drainGlobalHotkeys() {
        guard let session = appSession, !smokeMode else { return }
        if maru_macos_app_session_take_global_hotkeys_dirty(session) != 0 {
            unregisterGlobalHotkeys()
            registerGlobalHotkeys()
        }
    }

    // 커맨드 카탈로그가 런타임에 재빌드되면(keybind rebind/unbind·reload·reset → Zig가 command_catalog_dirty) tick마다
    // drain해 1이면 메뉴바를 다시 빌드한다(NSMenu keyEquivalent를 새 카탈로그로). reset은 확인 모달-확정 후 tick에서
    // 갱신되므로 동기 호출이 아니라 이 신호가 단일 경로다 — 인앱 rebind·멀티창 활성 세션도 같이 커버한다(buildMainMenu는
    // activeSurface 카탈로그를 읽는다). take_global_hotkeys_dirty(drainGlobalHotkeys)와 같은 1회성 신호 패턴.
    private func drainMenuDirty() {
        guard let session = appSession, !smokeMode else { return }
        if maru_macos_app_session_take_command_catalog_dirty(session) != 0 {
            buildMainMenu()
        }
    }

    // MARK: - 메뉴바 (NSMenu)

    /// "Merge Window Into" 서브메뉴(M3d-2b) — 열 때 대상 창 목록을 동적으로 채운다(menuNeedsUpdate). buildMainMenu가
    /// 매 재빌드마다 새 NSMenu로 재생성하므로 weak(부모 메뉴가 강참조, 재빌드 시 이전 것은 해제되고 이 ref가 새 것으로 갱신).
    private weak var moveToWindowMenu: NSMenu?

    /// "Move Workspace to Window" 서브메뉴(M3d-2b 단일 카드 이동) — merge와 같은 대상 창 열거를 쓰되, 키 창의 **활성**
    /// 워크스페이스 하나만 옮긴다(move_workspace_to). 수명·갱신은 moveToWindowMenu와 동일(weak, menuNeedsUpdate 동적).
    private weak var moveWorkspaceMenu: NSMenu?

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
    /// minimize/zoom·fullscreen은 OS 동작이라 네이티브 셀렉터. 시작 시 빌드하고, keybind가 바뀌면(rebind/unbind·reload·
    /// reset → Zig가 command_catalog_dirty) 다음 tick의 drainMenuDirty가 다시 빌드해 keyEquivalent를 갱신한다 — 더는 세션-
    /// 불변이 아니다(매번 새 NSMenu 재배정). 카탈로그는 activeSurface(활성 창) 세션에서 읽는다(멀티창 정합).
    private func buildMainMenu() {
        // 카탈로그를 [action_key: (제목, keyEquivalent, modifier)]로 읽어 둔다. **활성 세션(activeSurface)**에서 읽는다 —
        // keybind는 세션마다 다를 수 있으므로(멀티창에서 한 창만 reload하면 분기), 메뉴바는 사용자가 보는 활성 창의 카탈로그를
        // 반영해야 한다. 활성이 없으면(시작 직후 등) primary로 폴백. 재빌드는 drainMenuDirty가 command_catalog_dirty로 트리거.
        var catalog: [String: (title: String, keyEquiv: String, mods: NSEvent.ModifierFlags)] = [:]
        if let session = (activeSurface ?? primary)?.appSession {
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
        // Open Config… — config 파일을 기본 편집기로 연다(경로는 Zig가 소유). ⌘,는 세팅 화면(toggle_settings)에
        // 양보했다(config-gui §10) — keyEquivalent 없이 메뉴 클릭 전용. ⌘,는 keyDown → Zig 키바인드 resolver가 처리.
        app.addItem(nativeMenuItem("Open Config…", #selector(menuOpenConfig(_:)), key: "", target: self))
        // Reload Config — config 파일 편집을 재시작 없이 반영(Zig가 파일 재로드·재적용). Reset to Defaults — 모든 설정을
        // 기본값으로(확인 모달 후 config 파일 덮어쓰기, Zig requestResetAll). 둘 다 단축키 없음 — 메뉴 클릭 전용, 발견성용.
        app.addItem(nativeMenuItem("Reload Config", #selector(menuReloadConfig(_:)), key: "", target: self))
        app.addItem(nativeMenuItem("Reset to Defaults", #selector(menuResetDefaults(_:)), key: "", target: self))
        // Reset Terminal(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus·mouse·kitty keyboard)만 끈다. ssh가 비정상
        // 종료해 정리 못 한 모드가 raw 셸 입력을 오염시키는 증상(포커스마다 ^[[I·비프)의 수동 회복 — 셸 통합
        // 자동 리셋이 안 닿는 타 셸·hang 복구 직후용. 화면·스크롤백은 보존(Reset to Defaults=전체 설정 초기화와 다르다 — 입력 모드만 끈다).
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
        window.addItem(.separator())
        // Merge Window Into(M3d-2b) — 현재(키) 창의 모든 워크스페이스를 다른 창으로 병합(merge_window, docs §4 "Window all")
        // 하고 비워진 이 창을 닫는다. 대상 창 목록은 창 수가 런타임에 바뀌므로 열 때 동적으로 채운다(menuNeedsUpdate).
        // 정책·라이브 트리 수술은 Zig, NSWindow focus/close만 Swift(경계). 단축키 없음 — 발견성용(실수 시 큰 변형, docs §4).
        let moveMenu = NSMenu(title: "Merge Window Into")
        moveMenu.delegate = self
        self.moveToWindowMenu = moveMenu
        let moveItem = NSMenuItem(title: "Merge Window Into", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        window.addItem(moveItem)
        // Move Workspace to Window(M3d-2b 단일 카드 이동) — 키 창의 **활성** 워크스페이스 하나만 다른 창으로 옮긴다
        // (move_workspace_to). merge와 달리 src에 워크스페이스가 남으면 src 창은 유지된다. 대상 목록도 동적(menuNeedsUpdate).
        let moveOneMenu = NSMenu(title: "Move Workspace to Window")
        moveOneMenu.delegate = self
        self.moveWorkspaceMenu = moveOneMenu
        let moveOneItem = NSMenuItem(title: "Move Workspace to Window", action: nil, keyEquivalent: "")
        moveOneItem.submenu = moveOneMenu
        window.addItem(moveOneItem)
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
        // 메뉴 액션은 keyDown을 안 거친다 — next/previous_tab은 keyEquivalent가 달려 키 단축키로 와도
        // 메뉴가 가로채 여기로 온다. 조합 중이면 먼저 확정해, 탭 전환으로 입력기 세션이 새 탭으로 새지 않게 한다.
        activeSurface?.view?.commitMarkedTextIfComposing()
        let bytes = Array(key.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_run_action(session, buf.baseAddress, buf.count)
        }
    }

    // MARK: - Cross-window workspace 이동(M3d-2b)

    /// "Merge Window Into"/"Move Workspace to Window" 서브메뉴를 열 때 대상 창 목록을 동적으로 채운다(창 수는 런타임에
    /// 변하므로 정적 빌드가 아닌 open 시점 갱신). 소스 = 현재 키(활성) 일반 창, 대상 = 그 외 모든 일반 창(quick은
    /// `windows`에 없어 자동 제외 — docs §4 quick 이동 제외). 대상이 없으면(단일 창·키 창 없음) 비활성 안내 항목. 두 메뉴는
    /// 대상 열거가 동일하고 항목의 action selector(전체 merge vs 단일 이동)만 다르다. self는 이 두 서브메뉴에만 delegate라
    /// 다른 메뉴엔 안 불리지만, 방어적으로 우리 서브메뉴만 처리한다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let action: Selector
        if menu === moveToWindowMenu {
            action = #selector(mergeIntoWindowAction(_:))
        } else if menu === moveWorkspaceMenu {
            action = #selector(moveWorkspaceToWindowAction(_:))
        } else {
            return
        }
        menu.removeAllItems()
        let source = windows.first(where: { $0.window?.isKeyWindow == true })
        let targets = source == nil ? [] : windows.filter { $0 !== source }
        guard !targets.isEmpty else {
            let empty = NSMenuItem(title: "No Other Windows", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (i, target) in targets.enumerated() {
            let title = target.window?.title ?? "Window \(i + 1)"
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = NSNumber(value: target.token) // 대상 창 = 알림 라우팅 토큰(창마다 유일)으로 역조회
            item.target = self
            menu.addItem(item)
        }
    }

    /// 두 cross-window 이동 액션(merge/move)이 공유하는 (src, dst) 해석 — 창 수명 로직이 두 곳에서 발산하지 않게
    /// 한 곳으로 모은다([6]). smoke 아님 + representedObject 토큰 역조회로 대상(dst) + 소스(src) = 현재 키(활성) 창 +
    /// src≠dst. 하나라도 불충족이면 nil(무동작). 소스는 **클릭 시점에** 다시 키 창으로 해석한다(메뉴 트래킹 중엔 키
    /// 창이 안 바뀐다).
    private func resolveMoveEndpoints(_ sender: NSMenuItem) -> (src: TerminalSurface, dst: TerminalSurface)? {
        guard !smokeMode,
              let token = (sender.representedObject as? NSNumber)?.uint64Value,
              let dst = surfaceForToken(token),
              let src = windows.first(where: { $0.window?.isKeyWindow == true }),
              src !== dst else { return nil }
        return (src, dst)
    }

    /// merge/move 완료 공통 마무리([6]) — dst로 포커스를 먼저 착지시키고(src close 전에 키로 — AppKit이 임의 창을
    /// 키로 안 고르게) repaint한 뒤, 비워진 src 창을 닫는다(§8A.2 source_window_closed=1). close()는 emptied source
    /// (0탭)에서 안전하다(app_session이 activeSurface 접근을 가드) — 그래서 라이브 창 확인 게이트인 request_window_close가
    /// 아니라 closeWindowOrQuit(직접 teardown+close, delegate 끊어 재진입 방지)를 쓴다. src는 마지막 창이 아니라(dst
    /// 존재) closeWindowOrQuit의 else 경로. src가 남으면(=0) 호출자가 별도 처리한다(merge는 항상 1이라 무관, move는 src repaint).
    private func finishCrossWindowMove(_ result: MaruAppHostMoveResult, from src: TerminalSurface, into dst: TerminalSurface) {
        dst.window?.makeKeyAndOrderFront(nil)
        withSurface(dst) { _ = renderTick() } // 이동된 워크스페이스 즉시 repaint(다음 timer tick 안 기다림)
        if result.source_window_closed == 1 {
            closeWindowOrQuit(src)
        }
    }

    /// "Merge Window Into ▸ <창>" 선택 — 키(소스) 창의 모든 워크스페이스를 대상 창으로 병합한다.
    @objc private func mergeIntoWindowAction(_ sender: NSMenuItem) {
        guard let (src, dst) = resolveMoveEndpoints(sender) else { return }
        mergeWindow(from: src, into: dst)
    }

    /// src 세션의 모든 워크스페이스를 dst 세션으로 병합하고(merge_window — 정책·라이브 트리 수술·무재시작은 Zig),
    /// dst로 포커스를 착지시킨 뒤 비워진 src 창을 닫는다(finishCrossWindowMove — merge는 source_window_closed 항상 1).
    /// 이동 거부(move_failed — 그룹/pinned 워크스페이스는 M3d-2a-ii 범위, OOM)면 세션·창을 둘 다 그대로 둔다(무시).
    private func mergeWindow(from src: TerminalSurface, into dst: TerminalSurface) {
        guard let srcSession = src.appSession, let dstSession = dst.appSession else { return }
        var result = MaruAppHostMoveResult()
        guard maru_macos_app_session_merge_window(srcSession, dstSession, &result) == Self.statusOK else { return }
        finishCrossWindowMove(result, from: src, into: dst)
    }

    /// "Move Workspace to Window ▸ <창>" 선택 — 키(소스) 창의 **활성** 워크스페이스 하나만 대상 창으로 옮긴다. 소스·대상
    /// 해석은 merge 액션과 동일(resolveMoveEndpoints 공유) — 이동 단위(활성 카드 1개 vs 전체)만 다르다.
    @objc private func moveWorkspaceToWindowAction(_ sender: NSMenuItem) {
        guard let (src, dst) = resolveMoveEndpoints(sender) else { return }
        moveWorkspace(from: src, into: dst)
    }

    /// src 세션의 **활성** 워크스페이스 하나를 dst 세션으로 옮기고(move_workspace_to — 정책·라이브 트리 수술·무재시작은
    /// Zig), dst로 포커스를 착지시킨다(finishCrossWindowMove 공유). 활성 인덱스는 Zig getter로 읽는다(sentinel=UInt32.max면
    /// 세션 미초기화·탭 전무 → 무동작). 이동 후 src가 비었으면(source_window_closed=1 — 마지막 워크스페이스였음) 비워진
    /// src 창을 닫고(finishCrossWindowMove), 남았으면(=0) src 창은 유지하고 repaint만 한다(활성 재선택은 Zig가 이미 함).
    /// 이동 거부(move_failed — 그룹/pinned 워크스페이스는 M3d-2a-ii 범위·OOM)면 세션·창을 둘 다 그대로 둔다(무시).
    private func moveWorkspace(from src: TerminalSurface, into dst: TerminalSurface) {
        guard let srcSession = src.appSession, let dstSession = dst.appSession else { return }
        let idx = maru_macos_app_session_active_workspace_index(srcSession)
        guard idx != UInt32.max else { return } // surface 미초기화·탭 전무 sentinel — 무동작
        var result = MaruAppHostMoveResult()
        guard maru_macos_app_session_move_workspace_to(srcSession, dstSession, Int(idx), &result) == Self.statusOK else { return }
        finishCrossWindowMove(result, from: src, into: dst)
        if result.source_window_closed != 1 {
            withSurface(src) { _ = renderTick() } // src에 워크스페이스 남음 — 사이드바·활성 재계산은 Zig가 함, src 창 repaint만.
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
        // reload가 keybind를 바꾸면 Zig가 rebuildCommandCatalog로 command_catalog_dirty를 세운다 → 다음 tick의 drainMenuDirty가
        // 메뉴바를 다시 빌드한다(여기서 동기 호출하지 않는다 — reset/인앱 경로와 단일 경로로 통일, 멀티창 활성 세션 정합).
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

    /// Reset to Defaults — 모든 config를 내장 기본값으로 되돌리고 config 파일을 기본 상태로 덮어쓴다(Zig resetAllSettings 단일 함수 —
    /// 커맨드 팝업 "Reset All Settings to Defaults"와 같은 동작). 여기선 활성 세션에 호출만 한다.
    @objc private func menuResetDefaults(_ sender: Any?) {
        _ = sender
        guard let session = appSession else { return }
        _ = maru_macos_app_session_reset_defaults(session)
        // reset_defaults는 확인 모달만 연다(즉시 reset 아님). 사용자가 확정하면 다음 tick에 resetAllSettings가 카탈로그를
        // 재빌드해 command_catalog_dirty를 세우고, drainMenuDirty가 메뉴바를 갱신한다 — 여기서 동기 호출하면 모달 확정 전
        // 옛 카탈로그를 읽어 no-op이 되므로 호출하지 않는다(리뷰: 동기 buildMainMenu가 reset에선 무효였음).
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
        // 키패드(numpad) Enter(kVK_ANSI_KeypadEnter=76). 메인 Return과 똑같이 Enter로 매핑해 codepoint=0으로
        // 넘긴다 — 안 잡으면 default가 NSEnterCharacter(0x03)를 codepoint로 흘려 Zig가 `.char`로 해석한다(터미널엔
        // raw 0x03, chrome 모달엔 y/n 아닌 글자라 무시 → 키패드 Enter로 확인 모달이 안 닫힘). keypad 여부는
        // raw_key_code(76)→keycode.isKeypad로 따로 보존되어, application keypad 모드의 SS3(`ESC O M`)도 유지된다.
        case 76:
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
        focusTerminalView(window)
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
        // 표시 직전 config를 라이브로 **한 번** 읽어 설정 변경을 반영한다(auto_hide/screen; 사각형은 quickPanelFrames가
        // 매번 ABI로 계산). chrome/minimal_tabs는 세션 생성 시 박히므로, 바뀌었으면 기존 quick 세션을 내려
        // ensureQuickTerminal이 새 chrome으로 재생성하게 한다(스크래치 셸은 초기화됨 — 라이브 반영의 유일한 예외).
        // 읽은 cfg를 그대로 ensureQuickTerminal에 넘겨 생성 경로가 config를 다시 읽지 않게 한다(단일 로드).
        let cfg = loadQuickTerminalConfig()
        if let cfg {
            quickAutoHide = cfg.auto_hide != 0
            quickScreenMode = cfg.screen
            if quick != nil, cfg.chrome != quickCreatedChrome || cfg.minimal_tabs != quickCreatedMinimalTabs {
                tearDownQuickTerminal()
            }
        }
        ensureQuickTerminal(cfg)
        guard let panel = quick?.window else { return }
        showQuickTerminalAnimated(panel)
    }

    /// quick terminal surface를 lazy 생성한다(첫 토글). 두 번째 app session(대화형 셸) + borderless 패널 +
    /// Metal 뷰/렌더러를 만든다. 세션 생성 실패면 quick은 nil로 남고 토글은 무동작(앱은 정상). config(cfg)는
    /// 유일한 호출자 toggleQuickTerminal이 이미 로드해 넘긴다 — 여기서 다시 읽지 않는다(토글당 config 로드 1회).
    private func ensureQuickTerminal(_ cfg: MaruAppHostQuickTerminalConfig?) {
        guard quick == nil else { return }
        let surface = makeTerminalSurface()

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

        // Phase 4b-2: quick 패널도 동형 컨테이너(터미널 + 모달 오버레이 뷰)로 재편한다.
        let container = MaruTerminalContainerView(
            frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 300),
            controller: self
        )
        panel.contentView = container
        surface.window = panel

        // Metal 렌더러: 이 패널 터미널 뷰의 CAMetalLayer로(메인과 별도 인스턴스). 렌더러 pipeline은 터미널 layer의
        // pixelFormat로 만들고, 오버레이 layer도 같은 bgra8Unorm·같은 device라 한 command buffer에서 함께 present된다.
        if let metalLayer = container.terminalView.metalLayer, let device = metalLayer.device {
            container.terminalView.updateDrawableSize()
            container.overlayView.updateDrawableSize()
            surface.metalRenderer = maru_metal_renderer_create(device, metalLayer.pixelFormat)
            surface.metalRendererCreated = surface.metalRenderer != nil
        }

        // chrome/minimal_tabs는 세션 생성 인자로 박히므로 create '전에' 정한다. 토글이 넘긴 cfg를 그대로 쓴다
        // (auto_hide/screen은 토글이 이미 세팅 — 여기선 재조회·재대입 없음, 중복 출처 제거). 패널 크기·위치·center
        // 여부도 캐시하지 않는다 — quickPanelFrames가 매 표시마다 Zig ABI로 현재 config에서 계산해 라이브 반영한다.
        var chromeMinimal: UInt32 = 0
        var minimalTabs: UInt32 = 0
        if let cfg {
            chromeMinimal = (cfg.chrome == UInt32(MaruAppHostQuickTerminalChromeMinimal.rawValue)) ? 1 : 0
            minimalTabs = cfg.minimal_tabs // minimal에서 탭 허용 여부(Zig가 dispatch에서 게이트)
            // 생성 시점 스냅샷 — 다음 토글에서 chrome/tabs가 바뀌면 재생성 판정에 쓴다.
            quickCreatedChrome = cfg.chrome
            quickCreatedMinimalTabs = cfg.minimal_tabs
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
        // quick 세션에도 현재 시스템 외관을 즉시 알린다(theme.follow-system 라이브 적용 — 새 창과 같은 이유, 리뷰 B).
        applySystemAppearanceToAllSessions()

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

    /// quick 패널을 띄울 화면. screen=mouse면 현재 마우스 포인터가 있는 화면(없으면 주 디스플레이 폴백), 아니면
    /// 주 디스플레이. **주 디스플레이는 메뉴 막대가 있는 원점(0,0) 화면 = NSScreen.screens.first**다 — NSScreen.main은
    /// '키보드 포커스를 가진 창의 화면'이라 멀티 모니터에서 주 디스플레이와 다를 수 있어 쓰지 않는다(퀵터미널은 글로벌
    /// 핫키라 다른 앱이 전면일 때 뜨는 경우가 많아 NSScreen.main이면 그 앱이 있는 화면으로 새어 config `screen=main`의
    /// '주 디스플레이' 의도와 어긋난다).
    private func quickTargetScreen() -> NSScreen? {
        let primaryScreen = NSScreen.screens.first ?? NSScreen.main
        if quickScreenMode == UInt32(MaruAppHostQuickTerminalScreenMouse.rawValue) {
            let loc = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(loc) } ?? primaryScreen
        }
        return primaryScreen
    }

    /// quick 패널의 보임/숨김 사각형 + center 여부. 대상 화면 visibleFrame을 Zig ABI에 넘겨 세션의 **현재** config로
    /// 계산받는다(quick_terminal_frames는 매 호출 라이브 — 설정 GUI에서 위치·두께를 바꾸면 세션-불변 캐시 없이 다음
    /// 표시에서 바로 반영). 위치별 기하(가장자리 슬라이드 방향·center 페이드, 보임/숨김이 슬라이드 축만 다르고 크기
    /// 동일)는 Zig quick_terminal_geometry.compute가 단일 출처. config는 primary 세션에서 읽는다(설정 GUI 라이브 적용
    /// 대상이자 항상 존재). 세션/화면 정보를 못 구하면 nil(호출자가 애니메이션 없이 폴백).
    private func quickPanelFrames() -> (shown: NSRect, hidden: NSRect, centered: Bool)? {
        guard let screen = quickTargetScreen(), let session = primary?.appSession else { return nil }
        let vf = screen.visibleFrame
        var out = MaruAppHostQuickTerminalFrames()
        guard maru_macos_app_session_quick_terminal_frames(
            session, Double(vf.minX), Double(vf.minY), Double(vf.width), Double(vf.height), &out
        ) == Self.statusOK else { return nil }
        return (NSRect(x: out.shown_x, y: out.shown_y, width: out.shown_w, height: out.shown_h),
                NSRect(x: out.hidden_x, y: out.hidden_y, width: out.hidden_w, height: out.hidden_h),
                out.is_centered != 0)
    }

    /// quick 패널을 숨김 위치(가장자리 바깥)에서 보임 위치(가장자리에 붙음)로 슬라이드한다. 크기는 처음부터
    /// 최종값이라(숨김/보임이 슬라이드 축만 다름) makeKey 직후 세션 grid를 한 번 맞추고 위치만 애니메이션한다.
    private func showQuickTerminalAnimated(_ panel: NSWindow) {
        guard let frames = quickPanelFrames() else {
            // 화면 정보를 못 구하면 애니메이션 없이 그냥 띄운다(폴백). 이 위치엔 대응하는 숨김 사각형이 없으므로
            // stale 캐시를 비운다 — 안 그러면 다음 hide가 직전 show의 다른 화면 사각형으로 엉뚱하게 빠진다.
            quickHideFrame = nil
            panel.makeKeyAndOrderFront(nil)
            focusTerminalView(panel)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let centered = frames.centered
        // 숨김 애니메이션이 같은 화면/위치로 되빠지도록 지금 사각형을 캐시한다 — 표시 이후 마우스/화면/설정이
        // 바뀌어도(mouse 모드 멀티 모니터, 라이브 위치 변경) 패널이 있던 그대로 슬라이드 아웃한다(재계산 겨냥 오류 방지).
        quickHideFrame = (frames.hidden, centered)
        panel.setFrame(frames.hidden, display: false)
        if centered { panel.alphaValue = 0 } // 중앙은 투명에서 시작해 페이드 인(가장자리 슬라이드가 없음)
        panel.makeKeyAndOrderFront(nil)
        focusTerminalView(panel)
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

    /// quick 패널을 보임 위치에서 숨김 위치(가장자리 바깥)로 슬라이드한 뒤 orderOut으로 숨긴다(완료 시). 표시
    /// 시점에 캐시한 숨김 사각형(quickHideFrame)을 써 패널이 있던 화면/위치 그대로 되빠진다 — 재계산으로 다른
    /// 화면을 겨냥하지 않는다(mouse 모드 멀티 모니터·라이브 위치 변경 안전). 캐시가 없으면(방어) 그냥 내린다.
    private func hideQuickTerminalAnimated(_ panel: NSWindow) {
        guard let hide = quickHideFrame else {
            panel.orderOut(nil)
            return
        }
        let centered = hide.centered
        quickAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            // 가장자리는 위치 슬라이드로 빠지고, center는 제자리 페이드 아웃.
            if centered {
                panel.animator().alphaValue = 0
            } else {
                panel.animator().setFrame(hide.rect, display: true)
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
        quickHideFrame = nil // 재생성 시 stale 숨김 사각형이 새 패널에 새지 않게
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
    /// 안전한 Double→Int32 변환(saveWorkspace 창 frame 저장용). `Int32(x.rounded())`는 **trapping** 변환이라 비유한
    /// (NaN/inf)·Int32 범위 초과에서 크래시하는데, saveWorkspace는 applicationWillTerminate에서 불려 여기서 크래시하면
    /// **전체 창/탭/pane 상태가 저장되지 않아 소실**된다(치명적). 그래서 비유한이면 nil(그 창 frame 저장 스킵 →
    /// has_frame=0 → cascade), 유한하지만 범위를 넘으면 Int32 범위로 clamp, 아니면 반올림한다. [[no-defensive-code-without-consult]]의
    /// 예외 = 실제 trap 가드(추측 아님 — Int32(Double)이 실제로 trap하고 결과가 전체 상태 소실이라 방어 근거 충분).
    private func safeInt32(_ value: CGFloat) -> Int32? {
        guard value.isFinite else { return nil }
        let r = value.rounded()
        if r >= CGFloat(Int32.max) { return Int32.max }
        if r <= CGFloat(Int32.min) { return Int32.min }
        return Int32(r)
    }

    private func saveWorkspace() {
        guard !smokeMode, !windows.isEmpty else { return }
        // 복원을 끈 사용자(MARU_NO_WORKSPACE_RESTORE)는 저장도 막는다 — 안 그러면 복원 안 한 기본 단일 창이 종료 시
        // 저장 파일을 덮어써 사용자가 보존하려던 멀티 창 레이아웃이 사라진다(데이터 손실). 플래그=persistence 자체 off.
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return }
        var blocks = ""
        for surface in windows {
            guard let session = surface.appSession else { continue }
            // 저장 시점 key(활성) 창을 active-window=1 마커로 기록한다 — 재시작 복원이 그 창을 다시 focus(M3e).
            // 최대 하나의 창만 isKeyWindow라 마커도 최대 하나. 옵션-키라 비활성 창은 키가 생략된다(옛 파일 flat 동일).
            let isActive: UInt32 = (surface.window?.isKeyWindow == true) ? 1 : 0
            // M3f: 창 frame(전역 스크린 좌표, bottom-left 원점)을 저장해 재시작 시 위치·크기·모니터를 복원한다. 절대
            // frame이라 어느 모니터인지 자동 인코딩된다(display ID 불필요). 점 단위 정수로 반올림(픽셀 아님 — backing
            // scale 무관). 창이 없으면 hasFrame=0(win-* 생략 → cascade).
            var hasFrame: UInt32 = 0
            var fx: Int32 = 0, fy: Int32 = 0, fw: Int32 = 0, fh: Int32 = 0
            // 전체화면(native `.fullScreen`) 창은 frame이 **화면 전체**라, 저장하면 복원 시 clamp를 통과해 타이틀바
            // 달린 거대 windowed 창으로 뜬다(전체화면 아님 = 회귀). 전체화면이면 frame 저장을 스킵한다(hasFrame=0 →
            // win-* 생략 → 복원은 cascade 기본 위치). zoomed(green button)는 frame이 유효한 windowed 크기라 저장 OK
            // (전체화면만 대상). 전체화면 상태 자체의 복원(window-fullscreen 마커+toggleFullScreen)은 timing 위험이 커
            // 스킵-저장만으로 회귀를 제거한다(최소 안전) — 후속(docs/workspace-restore.md·window-surface-mobility.md).
            if let window = surface.window, !window.styleMask.contains(.fullScreen) {
                // Int32(Double) trap 방어: 비유한 좌표면 그 창 frame 저장 스킵(hasFrame=0), 범위 초과는 clamp([3]).
                let f = window.frame
                if let sx = safeInt32(f.origin.x), let sy = safeInt32(f.origin.y),
                    let sw = safeInt32(f.size.width), let sh = safeInt32(f.size.height) {
                    hasFrame = 1
                    fx = sx
                    fy = sy
                    fw = sw
                    fh = sh
                }
            }
            var ptr: UnsafePointer<UInt8>? = nil
            var len: size_t = 0
            guard maru_macos_app_session_serialize_workspace(session, &ptr, &len, isActive, hasFrame, fx, fy, fw, fh) == Self.statusOK,
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
