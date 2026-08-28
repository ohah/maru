import AppKit
import Carbon.HIToolbox
import CoreServices
import Darwin
import Foundation
import Metal
import QuartzCore
import UniformTypeIdentifiers // NSOpenPanel.allowedContentTypes = [.png] (배경 이미지 파일 선택, v81)
import UserNotifications
import WebKit // Phase 4c: 빈 WKWebView를 pane 본문에 부착(터미널<웹뷰<오버레이 z-order). 콘텐츠·브리지·보안은 Phase 5.

/// CI는 실제 `NSScreen.backingScaleFactor`를 고를 수 없으므로, font/scale fixture만 동일한
/// drawable·resize·pointer projection scale을 주입한다. 일반 제품 경로와 다른 scenario는 반드시
/// 물리 window scale을 그대로 쓴다.
private func archiveSmokeRenderScale(_ window: NSWindow?) -> CGFloat {
    let physical = window?.backingScaleFactor ?? 1.0
    let environment = ProcessInfo.processInfo.environment
    guard environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE"] == "1",
          environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] == "font-scale-rects",
          let raw = environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_RENDER_SCALE_MILLI"],
          let milli = UInt32(raw), milli == 1_000 || milli == 2_000
    else { return physical }
    return CGFloat(milli) / 1_000.0
}

private let browserResultCopyCallback: @convention(c) (
    UnsafeMutableRawPointer?, UInt64, UInt64, UnsafeMutablePointer<UInt8>?, Int
) -> Int64 = { context, transferId, offset, destination, capacity in
    precondition(Thread.isMainThread && context != nil, "browser result copy callback must run on main thread with context")
    return MainActor.assumeIsolated {
        let registry = Unmanaged<BrowserResultTransferRegistry>.fromOpaque(context!).takeUnretainedValue()
        let copied = registry.copy(
            id: transferId,
            offset: offset,
            destination: destination.map(UnsafeMutableRawPointer.init),
            capacity: capacity
        )
        return Int64(copied)
    }
}

private let browserResultReleaseCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64) -> UInt32 = {
    context, transferId in
    precondition(Thread.isMainThread && context != nil, "browser result release callback must run on main thread with context")
    return MainActor.assumeIsolated {
        let registry = Unmanaged<BrowserResultTransferRegistry>.fromOpaque(context!).takeUnretainedValue()
        return registry.release(transferId) ? 1 : 2
    }
}

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
        // **드롭도 '비-텍스트 상호작용'이다**(commitMarkedTextIfComposing 주석의 규칙). 조합 중에 이미지를
        // 끌어다 놓으면 AppKit marked 세션과 Zig preedit가 살아남아 조합 글자가 화면에 잔상으로 남고, 그
        // 뒤 입력이 stale한 조합에 이어 붙는다(사용자 제보 2026-08-17). 키보드·포인터·메뉴가 이미 공유하는
        // 그 규칙에 드롭을 합류시킨다 — 확정은 삽입 **전**에 하므로 조합 글자가 드롭 내용보다 앞에 온다.
        commitMarkedTextIfComposing()
        // 내용 추출·삽입은 paste 로직을 가진 controller에 위임한다(클립보드 paste와 같은 경로 재사용 — keyDown이
        // handleKeyDown에 위임하는 것과 동형). 세션/PTY 접근은 controller가 소유한다. 드롭 지점(창 좌표)과 **이 뷰**를
        // 함께 넘긴다 — controller가 그 뷰의 창 surface로 스코프해 pane 라우팅(v115)까지 한 곳에서 처리한다.
        return controller?.handleDrop(sender.draggingPasteboard, at: sender.draggingLocation, in: self) ?? false
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
        let scale = archiveSmokeRenderScale(window)
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
    // 표시·판정 상태의 단일 출처는 Zig(Surface.preedit + IME 트랜잭션)다.
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
    // 메뉴(runCatalogAction: next/previous_tab 등 — 키 단축키로 와도 keyDown을 안 거친다), 그리고
    // **드롭(performDragOperation — 이미지·파일·URL)** 네 입력 모달리티가 이 한 규칙('비-텍스트 조작이면
    // 조합 확정')을 공유한다. 커밋은 전환 '전'에 일어나므로 조합 글자는 떠나는(현재) 터미널로 들어가고
    // 새 터미널은 빈 상태로 시작한다.
    //
    // 드롭이 뒤늦게 합류한 이유가 이 규칙의 성격을 보여 준다: 모달리티를 하나 더할 때마다 여기 합류시켜야
    // 하는 **열린 목록**이라, 빠뜨리면 그 경로에서만 조합 잔상이 남는다(드롭이 실제로 그랬다 — 2026-08-17).
    //
    // 왜 Zig switchTab/focusTerm(전환의 단일 chokepoint)이 아니라 Swift 입력 경계에서 하나 — AppKit 입력기
    // 세션 종료(inputContext.discardMarkedText)는 NSView만 할 수 있다. Zig가 preedit를 커밋해도 그걸 못 부르면
    // marked 세션이 살아 다음 입력이 'ㅈ'부터 이어진다(누수의 실제 출처가 AppKit 세션이라 Zig만으론 못 막는다).
    func commitMarkedTextIfComposing() {
        guard hasMarkedText() else { return }
        controller?.imeCommit()            // Surface preedit 커밋(조합 글자 PTY로)
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
        controller?.recordSessionHostInputSmokeInsert()
    }

    // 조합 중 텍스트(예: 'ㅇ' -> '아' -> '안'). 표시는 Zig가 커서 위치에 합성한다.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedTextBuffer = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        imeLog("setMarkedText", markedTextBuffer)
        controller?.imeMarked(markedTextBuffer)
        controller?.recordSessionHostInputSmokeMarked()
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
        let has = !markedTextBuffer.isEmpty
        imeLog("? hasMarkedText -> \(has)")
        return has
    }

    // NSNotFound가 아니라 빈 NSRange를 돌려준다(Ghostty와 동일). NSNotFound를 주면 입력기가
    // "이 클라이언트는 marked 교체를 지원하지 않는다"로 보고 보수적으로 동작해 — 한국어 조합의
    // 마지막 자모에서 Backspace가 자모 삭제 대신 확정(insertText)으로 처리돼 삭제에 키가 한 번
    // 더 들었다(라이브: 가ㄴ -> BS -> 가ㄴ -> BS -> 가).
    func markedRange() -> NSRange {
        let r = markedTextBuffer.isEmpty
            ? NSRange()
            : NSRange(location: 0, length: markedTextBuffer.utf16.count)
        imeLog("? markedRange -> loc=\(r.location) len=\(r.length)")
        return r
    }

    func selectedRange() -> NSRange {
        imeLog("? selectedRange -> (빈 NSRange — 터미널 구현)")
        return NSRange()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        imeLog("? attributedSubstring loc=\(range.location) len=\(range.length) -> nil")
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
        imeLog("? firstRect loc=\(range.location) len=\(range.length)")
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
        imeLog("? characterIndex(point) -> 0 (터미널 구현)")
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

    // MARK: 접근성 — 이 뷰는 그림 하나가 아니라 **줄들의 묶음**이다.
    //
    // Zig 가 발행 스냅숏에 실은 서술자를 controller 가 native element 로 투영한다(CIM §3 — 투영은
    // adapter 만 한다). 지금 서술자를 내는 것은 파일 탐색기 행뿐이고, 나머지 chrome 은 아직 없다.
    override func isAccessibilityElement() -> Bool { return false }

    override func accessibilityRole() -> NSAccessibility.Role? { return .group }

    override func accessibilityChildren() -> [Any]? {
        return controller?.accessibilityElements(in: self)
    }

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
// (+ 4c WKWebView가 있으면 그것)이 비치고, 모달(command palette·find·confirm·settings) 열림 시에만 렌더러가 이
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
        // device는 여기서 세팅하지 않는다 — 컨테이너(MaruTerminalContainerView.init)가 터미널 레이어와 **같은
        // MTLDevice**를 주입해야 두 drawable을 한 command buffer에서 present할 수 있다. 여기서 시스템 default를
        // 조회하면 그 값이 컨테이너 주입으로 즉시 덮여 낭비다(MTLCreateSystemDefaultDevice 1회 제거).
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
        let scale = archiveSmokeRenderScale(window)
        let width = max(1.0, bounds.width * scale)
        let height = max(1.0, bounds.height * scale)
        let newSize = CGSize(width: width, height: height)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
        }
    }
}


// MARK: - Phase 5b: 신뢰 웹 브리지 핸들러 (isolated WKContentWorld window.maru.*)
//
// 신뢰(markdown) 패널의 **page-world와 격리된 named isolated world**("MaruBridge")에만 등록되는 메시지 핸들러
// (WKScriptMessageHandlerWithReply — async reply, macOS 11+). page-world JS(md sanitizer 우회 mXSS 등)는 다른 JS
// global이라 window.maru에 못 닿는다(2026-06 spike 실측: isolated world만 접근). 단 **메시지 핸들러 등록은 world-scope
// 라 프레임/origin을 안 가리므로**, 핸들러 진입에서 `frameInfo.isMainFrame` + `securityOrigin` exact-pin을 검사한다
// (서브프레임 clickjacking·origin 위장 차단 — control-plane-security.md §8.1.1 ②). 통과한 요청만 Zig 정책 코어(5b-1
// dispatchBridge)로 넘긴다 — **정책=Zig, 어댑터=Swift**(world·핸들러·origin 검증·shim). browser(비신뢰) 패널엔 이
// 브리지를 애초에 미등록(§8.1 (c)). 5b 최소: maru.hello()→server_version. 실 window.maru.* API는 5d+/Phase 7.
@MainActor
final class MaruBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    // 신뢰 origin exact-pin(§8.1.1 ②): 5c가 신뢰 UI를 maru-app://app로 서빙하므로 정확히 그 scheme+host의 메인
    // 프레임 메시지만 받는다(scheme 수준 any maru-app:// 매칭이 아니라 exact host까지 — 위장 origin 차단).
    private let surfaceId: UInt64
    private weak var controller: MaruAppHostController?

    init(surfaceId: UInt64, controller: MaruAppHostController) {
        self.surfaceId = surfaceId
        self.controller = controller
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // ── 신뢰 게이트: 메인 프레임 + 정확한 신뢰 origin(scheme+host)만. 하나라도 불일치면 reply 에러(Promise reject). ──
        guard message.frameInfo.isMainFrame else { replyHandler(nil, "unauthorized: not main frame"); return }
        let origin = message.frameInfo.securityOrigin
        guard MaruAppSchemeHandler.originAllowed(
            scheme: origin.protocol,
            host: origin.host,
            hasExplicitPort: origin.port != 0,
            role: 0
        ) else {
            replyHandler(nil, "unauthorized: origin")
            return
        }
        // ── 요청(JS 객체) → JSON-RPC 한 줄 → Zig dispatchBridge(정책) → 응답 파싱해 Promise 해소. ──
        guard let body = message.body as? [String: Any],
              let reqData = try? JSONSerialization.data(withJSONObject: body),
              let replyBytes = callBridge(reqData, method: body["method"] as? String),
              let replyObj = try? JSONSerialization.jsonObject(with: replyBytes)
        else {
            replyHandler(nil, "bad request")
            return
        }
        if body["method"] as? String == "maru.file.renderMermaid",
           let reply = replyObj as? [String: Any],
           let result = reply["result"] as? [String: Any],
           let job = result["job_id"] as? NSNumber,
           let params = body["params"] as? [String: Any],
           let controller,
           controller.registerMermaidReply(
             surfaceId: surfaceId,
             jobId: job.uint64Value,
             requestId: body["id"] ?? NSNull(),
             params: params,
             replyHandler: replyHandler
           ) {
            return
        }
        if body["method"] as? String == "maru.file.revokeMermaid",
           let reply = replyObj as? [String: Any], reply["result"] != nil,
           let params = body["params"] as? [String: Any] {
            controller?.revokeMermaidReply(surfaceId: surfaceId, params: params)
        }
        replyHandler(replyObj, nil) // JSON-RPC 응답 객체로 Promise 해소(shim의 request()가 이걸 반환).
    }

    // Zig dispatchBridge C-ABI 마샬링(단일 출처). 요청 바이트 → 응답 바이트(nil=음수 코드=NULL/용량/OOM 실패).
    private func callBridge(_ req: Data, method: String?) -> Data? {
        let reqBytes = [UInt8](req)
        guard let session = controller?.bridgeSession(for: surfaceId) else { return nil }
        // write/dirty/openLink는 side effect라 size-query가 dispatch를 두 번 실행하면 안 된다. 응답은 작은 고정 JSON이므로
        // 단일 1 KiB fill 호출로 끝낸다. read/readAsset만 아래 query/fill 재계산 경로를 쓴다.
        if method == "maru.file.beginDocument" || method == "maru.file.write" || method == "maru.file.setDirty" || method == "maru.file.resolveExternalChange" || method == "maru.file.openLink" || method == "maru.file.renderMermaid" || method == "maru.file.revokeMermaid" || method == "maru.file.rendererReady" || method == "maru.menu.open" {
            var out = [UInt8](repeating: 0, count: 1024)
            let written = reqBytes.withUnsafeBufferPointer { rp in
                out.withUnsafeMutableBufferPointer { op in
                    maru_macos_app_session_bridge_dispatch(session, surfaceId, rp.baseAddress, rp.count, op.baseAddress, op.count)
                }
            }
            guard written > 0, written <= Int64(out.count) else { return nil }
            return Data(out[0 ..< Int(written)])
        }
        // 응답은 최대 8 MiB 파일(+base64)을 담으므로 고정 버퍼를 쓰지 않는다. query와 fill 사이 파일 변경으로 길이가
        // 늘 수 있어 최대 2회 재시도한다. 두 번째에도 변하면 요청을 실패시켜 무한 루프를 막는다.
        for _ in 0 ..< 2 {
            let needed = reqBytes.withUnsafeBufferPointer { rp in
                maru_macos_app_session_bridge_dispatch(session, surfaceId, rp.baseAddress, rp.count, nil, 0)
            }
            guard needed > 0, needed <= Int64(Int.max) else { return nil }
            var out = [UInt8](repeating: 0, count: Int(needed))
            let written = reqBytes.withUnsafeBufferPointer { rp in
                out.withUnsafeMutableBufferPointer { op in
                    maru_macos_app_session_bridge_dispatch(session, surfaceId, rp.baseAddress, rp.count, op.baseAddress, op.count)
                }
            }
            if written > 0, written <= Int64(out.count) {
                return Data(out[0 ..< Int(written)])
            }
            if written <= 0 { return nil }
        }
        return nil
    }

    // isolated world에 window.maru를 까는 shim(atDocumentStart, main frame only). WKScriptMessageHandlerWithReply라
    // postMessage가 **Promise를 반환**한다(핸들러 replyHandler로 해소). 로드되면 maru.hello() round-trip 결과를 공유
    // DOM(#bridge-status)에 적어 손 테스트로 브리지 도달을 눈으로 확인한다(page-world app.js는 window.maru 못 봄=격리).
    static let shim = """
    (function () {
      "use strict";
      if (window.maru) return;
      var __id = 0;
      window.maru = {
        request: function (method, params) {
          var msg = { jsonrpc: "2.0", id: ++__id, method: method };
          if (params !== undefined) { msg.params = params; }
          return window.webkit.messageHandlers.maru.postMessage(msg);
        },
        hello: function () { return window.maru.request("hello"); },
        file: {
          beginDocument: function (documentId) { return window.maru.request("maru.file.beginDocument", { document_id: documentId }); },
          read: function (editorEpoch) { return window.maru.request("maru.file.read", { editor_epoch: editorEpoch }); },
          readAsset: function (path) { return window.maru.request("maru.file.readAsset", { path: path }); },
          write: function (editorEpoch, content) { return window.maru.request("maru.file.write", { editor_epoch: editorEpoch, content: content }); },
          setDirty: function (dirty, editorEpoch, revision, requestId) {
            return window.maru.request("maru.file.setDirty", { dirty: dirty, editor_epoch: editorEpoch, revision: revision, request_id: requestId });
          },
          resolveExternalChange: function (editorEpoch, success) {
            return window.maru.request("maru.file.resolveExternalChange", { editor_epoch: editorEpoch, success: success });
          },
          openLink: function (editorEpoch, href, forceSystem) {
            return window.maru.request("maru.file.openLink", { editor_epoch: editorEpoch, href: href, forceSystem: forceSystem });
          },
          renderMermaid: function (request) {
            return window.maru.request("maru.file.renderMermaid", request);
          },
          revokeMermaid: function (request) {
            return window.maru.request("maru.file.revokeMermaid", request);
          },
          rendererReady: function (editorEpoch) {
            return window.maru.request("maru.file.rendererReady", { editor_epoch: editorEpoch });
          }
        },
        diff: {
          // E1: 인자가 없다 — 무엇을 비교할지는 그 Term의 entry가 정한다(docs/editor-surface-tooling.md §6).
          open: function () { return window.maru.request("maru.diff.open"); }
        },
        menu: {
          // §2.6: 메뉴는 native가 그린다 — web은 "어디서 무엇을 눌렀는지"만 올린다(모드는 안 보낸다).
          open: function (request) { return window.maru.request("maru.menu.open", request); }
        }
      };
      function flushFileRequests() {
        document.querySelectorAll('[data-maru-file-request="pending"]').forEach(function (node) {
          node.setAttribute("data-maru-file-request", "handling");
          var request;
          try { request = JSON.parse(node.textContent || "{}"); }
          catch (_) { node.textContent = JSON.stringify({ error: "invalid request" }); finish(node); return; }
          var promise;
          if (request.method === "beginDocument" && Number.isSafeInteger(request.document_id) && request.document_id > 0) {
            promise = window.maru.file.beginDocument(request.document_id);
          }
          else if (request.method === "read" && Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0) {
            promise = window.maru.file.read(request.editor_epoch);
          }
          else if (request.method === "diffOpen") {
            promise = window.maru.diff.open();
          }
          else if (request.method === "menuOpen" && Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                   typeof request.x === "number" && isFinite(request.x) &&
                   typeof request.y === "number" && isFinite(request.y) &&
                   (request.target === "text" || request.target === "link" || request.target === "image" || request.target === "empty") &&
                   typeof request.has_selection === "boolean" &&
                   typeof request.href === "string" && request.href.length <= 4096) {
            promise = window.maru.menu.open({
              editor_epoch: request.editor_epoch, x: request.x, y: request.y,
              target: request.target, has_selection: request.has_selection, href: request.href
            });
          }
          else if (request.method === "readAsset" && typeof request.path === "string" && request.path.length <= 4096) {
            promise = window.maru.file.readAsset(request.path);
          } else if (request.method === "write" && Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     typeof request.content === "string" && request.content.length <= 8388608) {
            promise = window.maru.file.write(request.editor_epoch, request.content);
          } else if (request.method === "setDirty" && typeof request.dirty === "boolean" &&
                     Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     Number.isSafeInteger(request.revision) && request.revision >= 0 &&
                     Number.isSafeInteger(request.request_id) && request.request_id >= 0) {
            promise = window.maru.file.setDirty(request.dirty, request.editor_epoch, request.revision, request.request_id);
          } else if (request.method === "resolveExternalChange" &&
                     Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     typeof request.success === "boolean") {
            promise = window.maru.file.resolveExternalChange(request.editor_epoch, request.success);
          } else if (request.method === "openLink" && Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     typeof request.href === "string" && request.href.length <= 4096 && typeof request.forceSystem === "boolean") {
            promise = window.maru.file.openLink(request.editor_epoch, request.href, request.forceSystem);
          } else if (request.method === "renderMermaid" &&
                     Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     Number.isSafeInteger(request.document_revision) && request.document_revision >= 0 &&
                     Number.isSafeInteger(request.projection_generation) && request.projection_generation > 0 &&
                     Number.isSafeInteger(request.widget_id) && request.widget_id > 0 &&
                     Number.isSafeInteger(request.widget_generation) && request.widget_generation > 0 &&
                     Number.isSafeInteger(request.renderer_instance) && request.renderer_instance > 0 &&
                     Number.isSafeInteger(request.fence_id) && request.fence_id > 0 &&
                     typeof request.source_hash === "string" && /^[0-9a-f]{64}$/.test(request.source_hash) &&
                     typeof request.source === "string" && request.source.length > 0 && request.source.length <= 32768) {
            promise = window.maru.file.renderMermaid({
              editor_epoch: request.editor_epoch,
              document_revision: request.document_revision,
              projection_generation: request.projection_generation,
              widget_id: request.widget_id,
              widget_generation: request.widget_generation,
              renderer_instance: request.renderer_instance,
              fence_id: request.fence_id,
              source_hash: request.source_hash,
              source: request.source
            });
          } else if (request.method === "revokeMermaid" &&
                     Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0 &&
                     Number.isSafeInteger(request.document_revision) && request.document_revision >= 0 &&
                     Number.isSafeInteger(request.projection_generation) && request.projection_generation > 0 &&
                     Number.isSafeInteger(request.widget_id) && request.widget_id > 0 &&
                     Number.isSafeInteger(request.widget_generation) && request.widget_generation > 0 &&
                     Number.isSafeInteger(request.renderer_instance) && request.renderer_instance > 0) {
            promise = window.maru.file.revokeMermaid({
              editor_epoch: request.editor_epoch,
              document_revision: request.document_revision,
              projection_generation: request.projection_generation,
              widget_id: request.widget_id,
              widget_generation: request.widget_generation,
              renderer_instance: request.renderer_instance
            });
          } else if (request.method === "rendererReady" &&
                     Number.isSafeInteger(request.editor_epoch) && request.editor_epoch > 0) {
            promise = window.maru.file.rendererReady(request.editor_epoch);
          } else {
            node.textContent = JSON.stringify({ error: "invalid request" });
            finish(node);
            return;
          }
          promise.then(function (reply) {
            node.textContent = JSON.stringify(reply);
            finish(node);
          }).catch(function (_) {
            node.textContent = JSON.stringify({ error: "file bridge failed" });
            finish(node);
          });
        });
      }
      function finish(node) {
        node.setAttribute("data-maru-file-request", "done");
        document.dispatchEvent(new Event("maru:file-response"));
      }
      document.addEventListener("maru:file-request", flushFileRequests);
      document.addEventListener("DOMContentLoaded", function () {
        var el = document.getElementById("bridge-status");
        window.maru.hello().then(function (r) {
          if (el) { el.textContent = "브리지 OK (isolated world) · server_version " + (r && r.result && r.result.server_version); }
        }).catch(function (e) {
          if (el) { el.textContent = "브리지 ERROR: " + e; }
        });
      });
    })();
    """
}

// MARK: - Phase 5d: browser.* 제어 코어 (WKWebView API 실행 — L4 어댑터)
//
// control-plane-browser.md §9.1 ④의 제어 코어를 실 WKWebView API로 채운다. web surface의 webView를 받아 §9 매핑대로 호출만
// 한다(라우팅·매핑·wire는 Zig control_browser). **정책=Zig, 어댑터=Swift**. 핵심 3개(navigate=`load`, getUrl=`.url`,
// executeScript=`evaluateJavaScript`); screenshot/back/forward/… 는 5f 후속. **라이브 배선 완료(5e-2b)**: 인가된 소켓
// browser.* 요청이 dispatchAuthenticated→browserOpFromRequest→§5-async marshal→Zig op 큐→`drainBrowserOps`가 매 tick
// 이 코어를 구동→completion서 complete_browser_op으로 응답한다(§8.5 browser=기본거부·실 cap 발급은 1e-confirm 후속,
// 현재는 test-only 주입). 5d fixture(smoke가 browser 패널을 직접 구동)는 이 코어를 라이브 배선 전 de-risk한 토대다.
enum BrowserControl {
    // browser.navigate → load(URLRequest). 유효 URL이면 로드 시작(완료는 navigationDelegate didFinish, async)하고 true.
    @MainActor static func navigate(_ webView: WKWebView, url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        webView.load(URLRequest(url: u))
        return true
    }

    // browser.getUrl → 현재 문서 URL(sync). 로드 전엔 nil.
    @MainActor static func currentUrl(_ webView: WKWebView) -> String? {
        webView.url?.absoluteString
    }

    // browser.executeScript → evaluateJavaScript(page world). async 콜백으로 결과(불투명 JSON 값)나 에러를 돌려준다.
    @MainActor static func executeScript(_ webView: WKWebView, _ script: String, completion: @escaping (Result<Any, Error>) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            if let error { completion(.failure(error)) } else { completion(.success(value ?? NSNull())) }
        }
    }

    /// Public browser.executeScript 전용: backend arg에서 script/cap을 읽고 page-process bounded wrapper만 실행한다.
    @MainActor static func executeScriptBounded(
        _ webView: WKWebView,
        _ arg: String,
        shouldStart: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<BrowserPageScriptResult, Error>) -> Void
    ) {
        do {
            guard let data = arg.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let script = object["script"] as? String,
                  let args = object["args"] as? [Any],
                  let maxBytes = object["max_result_bytes"] as? Int,
                  maxBytes > 0,
                  maxBytes <= BrowserResultTransferRegistry.defaultMaxEntryBytes else {
                throw CocoaError(.coderInvalidValue)
            }
            // 최대 request frame 크기의 source를 JSC에서 두 번 syntax-check하므로 main actor 밖에서 파싱한다.
            // webView는 weak 캡처해 surface close가 pending validation 때문에 WKWebView를 붙잡지 않게 한다.
            DispatchQueue.global(qos: .userInitiated).async { [weak webView] in
                let wrapper: String
                do {
                    wrapper = try BrowserResultTransferRegistry.boundedPageScript(script, maxBytes: maxBytes)
                } catch {
                    let payload = BrowserResultTransferRegistry.nativeScriptErrorPayload(error)
                    DispatchQueue.main.async { completion(.success(.scriptError(payload))) }
                    return
                }
                DispatchQueue.main.async {
                    guard shouldStart() else {
                        let payload = BrowserResultTransferRegistry.nativeScriptErrorPayload(
                            NSError(domain: "Maru.Browser.Navigation", code: 3), kind: "navigation"
                        )
                        completion(.success(.scriptError(payload)))
                        return
                    }
                    guard let webView else {
                        let payload = BrowserResultTransferRegistry.nativeScriptErrorPayload(
                            NSError(domain: "Maru.Browser.Navigation", code: 2), kind: "navigation"
                        )
                        completion(.success(.scriptError(payload)))
                        return
                    }
                    webView.callAsyncJavaScript(wrapper, arguments: ["args": args], in: nil, in: .page) { result in
                        switch result {
                        case .failure(let error):
                            completion(.success(.scriptError(BrowserResultTransferRegistry.nativeScriptErrorPayload(error))))
                            return
                        case .success(let value):
                        guard let pageText = value as? String else {
                            completion(.success(.scriptError(BrowserResultTransferRegistry.nativeScriptErrorPayload(NSError(domain: "Maru.Browser", code: 1)))))
                            return
                        }
                        // 최대 16 MiB String의 UTF-8 scan/Data 변환은 main actor/frame tick을 막지 않게 worker에서 수행한다.
                        // registry insert와 Zig terminal은 completion을 main으로 되돌린 뒤에만 실행된다.
                        DispatchQueue.global(qos: .userInitiated).async {
                            let decoded = BrowserResultTransferRegistry.decodeBoundedPageResult(pageText, maxBytes: maxBytes)
                            DispatchQueue.main.async { completion(.success(decoded)) }
                        }
                        }
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }

    // Phase 7e-3: 주소창 nav 버튼(back/forward/reload) 실행. 정책(활성 판정·surface 매핑)은 Zig(take_web_nav_action)가
    // 하고, 여기는 WKWebView 히스토리 API를 부르는 얇은 어댑터다. goBack/goForward는 히스토리가 없으면 WebKit이 no-op
    // (canGoBack/Forward가 false면 Zig가 애초에 pending을 안 세우지만, 이중 안전). reload는 로드된 페이지가 없으면 no-op.
    @MainActor static func goBack(_ webView: WKWebView) { webView.goBack() }
    @MainActor static func goForward(_ webView: WKWebView) { webView.goForward() }
    @MainActor static func reload(_ webView: WKWebView) { webView.reload() }

    // §8 슬라이스 ②: 페이지 내 찾기. WebKit이 검색·하이라이트·스크롤을 다 하고, 우리는 찾았는지만 되돌린다.
    // **JS를 주입하지 않는다** — markdown/browser 패널에는 bridge가 없다는 §7·§8 원칙 때문이다.
    // WKFindResult는 `matchFound`뿐이라 **매치 개수를 알 수 없다**(오버레이가 "n/m"을 못 쓰는 이유).
    @MainActor static func find(
        _ webView: WKWebView,
        query: String,
        backwards: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false // 터미널 find와 같은 대소문자 무시 규칙
        cfg.wraps = true          // 끝에서 처음으로 — ⌘G 반복이 막히지 않게
        webView.find(query, configuration: cfg) { result in
            completion(result.matchFound)
        }
    }

    // 5f-1: browser.screenshot → takeSnapshot으로 현재 표시 영역을 NSImage로 캡처한 뒤 **PNG Data**로 인코딩해 돌려준다
    // (async 콜백 — getCookies/executeScript와 동형). 실패(스냅샷 에러·비트맵/PNG 변환 실패)면 nil. 라우팅·chunk 분할·
    // metadata(IHDR)는 Zig, 여긴 WKWebView 스냅샷 API + PNG 인코딩 어댑터만(네이티브 최소). PNG 변환은 clipboardImagePng과
    // 같은 NSBitmapImageRep 경로.
    //
    // rect/scale(§9.5.7): arg가 `{rect?:{x,y,width,height}, scale?}` compact JSON(Zig serializeScreenshotArg). 둘 다 부재면
    // `{}`=전체 가시 뷰포트·기기 배율. rect=`config.rect`(CSS 포인트, 뷰 좌표계). scale=출력 배율 → `config.snapshotWidth`를
    // (rect 있으면 rect.width, 없으면 뷰 너비)×scale 포인트로 지정(WKWebKit이 비율 유지 리샘플). scale<=0/rect 형식 오류는
    // Zig(parseScreenshotOptParams)가 이미 걸러 여기 도달 arg는 유효 — 방어로 유한/양수만 반영, 아니면 무시(전체 캡처).
    //
    // **렌더 자원 상한은 여기서 클램프**(L2 파서는 형식[유한·양수]만 검증, 픽셀 버퍼 자원 한계는 WKWebView가
    // 실제 렌더하는 이 지점 소유 = 계층 정합). 에이전트 지정 rect 치수·scale이 거대 픽셀 버퍼를 요구하면(예: rect 1e12·scale 50)
    // 메모리 폭발 → rect 치수와 출력 폭을 `maxSnapshotPt`로 접는다. 실 디스플레이/페이지는 이 한계 미만이라 정상 사용엔 무영향.
    @MainActor static func takeSnapshot(_ webView: WKWebView, _ arg: String, completion: @escaping (Data?) -> Void) {
        let config = WKSnapshotConfiguration()
        let opts = arg.isEmpty ? nil : parseCookieArg(arg)
        let maxSnapshotPt: CGFloat = 8000 // 렌더 자원 상한(pt) — 실 화면/페이지 초과, 거대 rect/scale만 접음
        var captureWidth = webView.bounds.width
        if let r = opts?["rect"] as? [String: Any],
            let x = numberValue(r["x"]), let y = numberValue(r["y"]),
            let w = numberValue(r["width"]), let h = numberValue(r["height"]),
            w > 0, h > 0
        {
            let cw = min(CGFloat(w), maxSnapshotPt)
            let ch = min(CGFloat(h), maxSnapshotPt)
            config.rect = CGRect(x: x, y: y, width: cw, height: ch)
            captureWidth = cw
        }
        if let scale = numberValue(opts?["scale"]), scale.isFinite, scale > 0, captureWidth > 0 {
            config.snapshotWidth = NSNumber(value: min(Double(captureWidth) * scale, Double(maxSnapshotPt)))
        }
        webView.takeSnapshot(with: config) { image, error in
            guard error == nil, let image = image,
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else {
                completion(nil)
                return
            }
            completion(png)
        }
    }

    // JSON 수치(NSNumber로 파싱된 정수/실수)를 Double로. rect/scale 필드 공용. 문자열·null·부재 → nil(형식 오류로 무시).
    static func numberValue(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        // JS boolean(__NSCFBoolean)은 NSNumber 하위형 — 좌표/배율로 오독 금지(scriptResultString과 같은 방어).
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }

    // localStorage/act/wait 내부 evaluateJavaScript 결과를 **문자열 기반** helper 응답에 맞춘다(getLocalStorage=raw value·
    // act/wait=`{ok}`용 "true"/"false"). public browser.executeScript 성공은 이 함수를 **안 쓰고**
    // `BrowserResultTransferRegistry.encodeScriptResult`의 strict JSON Data 경로를 탄다 — 그래서 여긴 **JSON 인코딩이
    // 아니라 원문 매핑**을 유지해야 한다(한때 JSONSerialization으로 바꿔 getLocalStorage가 `"abc"`[따옴표]·없는
    // 키가 `"null"`로 새어 소비자가 손상된 값을 받던 회귀 수정). 이 함수는 그 보조 op들의 호환 어댑터만 소유한다.
    // 매핑: 문자열=그대로, 불리언="true"/"false", 숫자=NSNumber stringValue, null/undefined(NSNull)=빈 문자열, 그 외(배열·객체)=description.
    @MainActor static func scriptResultString(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // JS boolean(__NSCFBoolean)은 NSNumber 하위형이라 `as? NSNumber`가 먼저 잡는다 → boolean을 여기서 먼저
            // 가려내지 않으면 true/false가 "1"/"0"으로 나와 숫자 1/0과 구분 불가(에이전트가 페이지 boolean 상태 오독,
            // 17차 리뷰 [0]). CFBooleanGetTypeID로 진짜 boolean만 "true"/"false"로, 나머지 숫자는 stringValue.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return String(describing: value)
    }

    // 5f-4c: browser.getCookies → WKHTTPCookieStore.getAllCookies(async). **§9.4 D5 browser_storage scope**(base
    // browser로는 불인가 — authz가 거름). Zig serializeGetCookiesResult가 배열을 파싱해 `{"result":{"cookies":[...]}}`로 싣는다.
    // **범위 결정(clean-room, 22차 [0] 정정)**: 비신뢰 browser 패널들은 `browserDataStore`(static nonPersistent) **하나를
    // 공유**한다(탭 간 로그인 유지 — 라인 1005~1008). 따라서 getAllCookies는 **모든 패널 origin의 쿠키**를 준다 →
    // 대상 surface의 현재 문서 host로 **반드시 필터**해야 다른 패널(예: 은행 로그인 탭)의 세션 쿠키가 안 샌다(D5 교차-surface
    // 격리 = §8.3 권한상승 차단). WebDriver getCookies의 "현재 문서에 보이는 쿠키" 시맨틱 그대로. (초판은 "패널마다 격리
    // 항아리"라 전체 반환한다 했으나 그 전제가 **거짓** — store는 앱 전역 공유 — 이라 정정.) 잔여 한계: base browser+
    // browser_storage cap을 둘 다 쥔 에이전트가 자기 surface를 다른 host로 navigate하면 그 host 쿠키를 읽을 수 있으나,
    // 이는 공유 store + navigate cap의 성격이지 getCookies 유출이 아니다(별도 표면 — control-plane §9.4 D4/D5).
    @MainActor static func getCookies(_ webView: WKWebView, completion: @escaping (String) -> Void) {
        let host = webView.url?.host
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let visible = cookies.filter { Self.cookieVisibleToHost($0, host: host) }
            completion(serializeCookies(visible))
        }
    }

    // 22차 [0]: 쿠키가 `host`의 현재 문서에 보이는가(RFC 6265 domain-match). host nil/빈(data:/about:blank 등 opaque
    // origin)=문서 origin 없음=아무 쿠키도 안 보임(빈 결과 — 공유 store의 타 패널 쿠키를 안 흘림). cookie.domain의 선행
    // 점(`.example.com`=서브도메인 포함)을 벗기고 **exact 또는 부모 도메인(dot-suffix)** 매치. 대소문자 무시(도메인은 ASCII case-insensitive).
    static func cookieVisibleToHost(_ cookie: HTTPCookie, host: String?) -> Bool {
        return domainMatches(host, cookie.domain)
    }

    // 현재 문서 `host`가 `domain`으로 쿠키를 쓰거나 지울 수 있는가(RFC 6265 §5.3.6 domain-match) — host가
    // domain이거나 그 서브도메인일 때만. write(setCookie)·delete(deleteCookie) 격리 = read(getCookies) 격리 대칭이라
    // cookieVisibleToHost와 **같은 판정을 공유**(그건 cookie.domain을, 이건 인자 domain을 넘길 뿐). host nil/빈(opaque)=불가.
    static func hostMayUseDomain(_ host: String?, _ domain: String) -> Bool {
        return domainMatches(host, domain)
    }

    // domain-match 코어(선행 점 제거 후 exact 또는 부모 dot-suffix, ASCII case-insensitive). host/domain 빈=불가.
    private static func domainMatches(_ host: String?, _ domain: String) -> Bool {
        guard let host = host, !host.isEmpty else { return false }
        var d = domain
        if d.hasPrefix(".") { d.removeFirst() }
        if d.isEmpty { return false }
        let hl = host.lowercased()
        let dl = d.lowercased()
        return hl == dl || hl.hasSuffix("." + dl)
    }

    // 5f-4c: [HTTPCookie]를 JSON 배열 문자열로. 각 원소={name,value,domain,path,secure,httpOnly,expires?,sameSite?}
    // (WKHTTPCookie 프로퍼티 매핑 — 이 필드 스키마는 Swift가 단일 출처, control-plane §9.4 D4에 문서). JSONSerialization으로
    // 직렬화해 name/value의 따옴표·제어문자를 정확히 escape(수동 문자열 조립 금지). 실패(비정상)면 빈 배열 "[]".
    @MainActor static func serializeCookies(_ cookies: [HTTPCookie]) -> String {
        var arr: [[String: Any]] = []
        arr.reserveCapacity(cookies.count)
        for c in cookies {
            var obj: [String: Any] = [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure,
                "httpOnly": c.isHTTPOnly,
            ]
            if let exp = c.expiresDate { obj["expires"] = exp.timeIntervalSince1970 } // epoch 초(Double). 세션 쿠키=부재.
            if let ss = c.sameSitePolicy { obj["sameSite"] = ss.rawValue } // "Strict"/"Lax"(HTTPCookieStringPolicy raw).
            arr.append(obj)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // cookie write(§9.4 D4): argJson={name,value,domain?,path?,secure?}. domain 생략=대상 문서 host·path 생략="/".
    // HTTPCookie(properties:) 구성 후 WKHTTPCookieStore.setCookie(async 콜백). host·domain 둘 다 없으면 실패(어느 도메인?).
    // httpOnly는 HTTPCookiePropertyKey에 공개 키가 없어(Set-Cookie 헤더 전용) 주입 쿠키는 항상 non-HttpOnly(문서화 한계).
    @MainActor static func setCookie(_ webView: WKWebView, _ argJson: String, completion: @escaping (Bool) -> Void) {
        guard let obj = Self.parseCookieArg(argJson),
            let name = obj["name"] as? String,
            let value = obj["value"] as? String
        else {
            completion(false)
            return
        }
        let domain = (obj["domain"] as? String) ?? webView.url?.host
        guard let dom = domain, !dom.isEmpty else {
            completion(false)
            return
        } // 대상 도메인 없음(로드 전 opaque origin)
        // **교차-origin 쿠키 주입 차단**. 공유 store라 임의 domain을 쓰면 다른 패널(예: 은행 탭) origin에
        // 세션 쿠키를 심을 수 있다(session fixation). domain은 현재 문서 host이거나 그 부모여야만(RFC 6265 §5.3.6
        // domain-match) — getCookies의 host 필터(cookieVisibleToHost)와 대칭. 부적격이면 거부(write 격리 = read 격리).
        guard Self.hostMayUseDomain(webView.url?.host, dom) else {
            completion(false)
            return
        }
        let path = (obj["path"] as? String) ?? "/"
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: dom, .path: path]
        if (obj["secure"] as? Bool) == true { props[.secure] = "TRUE" }
        guard let cookie = HTTPCookie(properties: props) else {
            completion(false)
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { completion(true) }
    }

    // deleteCookie(§9.4 D4): argJson={name,domain?,path?}. getAllCookies서 name 쿠키를 찾아 delete. **대상 문서 host
    // 격리를 항상 적용**(getCookies와 동형); domain/path는 가시 쿠키 안에서 추가로 좁힌다(path 생략=`/`). 매치
    // 0이어도 성공(멱등 — 이미 없음).
    @MainActor static func deleteCookie(_ webView: WKWebView, _ argJson: String, completion: @escaping (Bool) -> Void) {
        guard let obj = Self.parseCookieArg(argJson), let name = obj["name"] as? String else {
            completion(false)
            return
        }
        let host = webView.url?.host
        let reqDomain = obj["domain"] as? String
        let reqPath = obj["path"] as? String
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let matches = cookies.filter { c in
                guard c.name == name else { return false }
                // 대상 문서 host 격리를 **항상** 적용(공유 store — 명시 domain이어도 타 origin[예: 은행 탭]
                // 쿠키 삭제 = 로그아웃 DoS 차단). 이전엔 명시 domain이면 host 체크를 건너뛰어 교차-surface 삭제가 가능했다.
                guard Self.cookieVisibleToHost(c, host: host) else { return false }
                // 명시 domain/path는 **가시 쿠키 안에서 추가로 좁힌다**(격리를 넘어서 넓히지 않음).
                if let rd = reqDomain, c.domain != rd && c.domain != "." + rd { return false }
                // path 생략=`/`(문서 §9.4 D4 계약·setCookie 대칭) — 이전엔 생략 시 모든 path를 지워 계약보다 넓었다.
                if c.path != (reqPath ?? "/") { return false }
                return true
            }
            let group = DispatchGroup()
            for c in matches {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { completion(true) }
        }
    }

    // cookie write op.arg JSON({name,value,domain?,...})을 dict로 파싱. 실패면 nil.
    static func parseCookieArg(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // localStorage(§9.4 D4 storage): WKWebView에 네이티브 localStorage API가 없어 **eval 백엔드**로 실행한다(exec와 같은
    // 도달=base browser scope, D5 laundering-hole 불변). key/value를 안전히 JS 문자열 리터럴로 만들어(jsStringLiteral)
    // getItem/setItem/removeItem을 호출한다. get은 executeScript 결과(문자열, null=빈)를 그대로 반환, set/remove는 {ok}.
    static func localStorageScript(_ obj: [String: Any], op: UInt8) -> String? {
        guard let key = obj["key"] as? String else { return nil }
        let k = jsStringLiteral(key)
        switch op {
        case 8: return "window.localStorage.getItem(\(k))" // get
        case 9: // set — value 필수
            guard let value = obj["value"] as? String else { return nil }
            return "window.localStorage.setItem(\(k), \(jsStringLiteral(value)))"
        case 10: return "window.localStorage.removeItem(\(k))" // remove
        default: return nil
        }
    }

    // act(5f-2·snapshot-2): selector 또는 ref로 요소를 찾아 click/type/scroll을 eval 스크립트로 만든다(base browser scope).
    // querySelector가 null이면 false(요소 미발견) 반환 → Zig가 {ok:false}로 실는다. type은 input/textarea면 .value, 아니면
    // textContent에 넣고 input/change 이벤트 발화(프레임워크 반응). scroll은 scrollIntoView(요소로 스크롤).
    // **locator(§9.5.4)**: selector면 그대로 querySelector; ref면 snapshot이 부여한 `[data-maru-ref]` 속성으로 해소한다
    // (ref는 wire 불투명 토큰이라 이 바인딩이 L4[엔진] 소관 — 미래 CDP 엔진은 같은 op을 backendNodeId로 해소). ref 값은
    // JSON.stringify로 CSS 속성 셀렉터 문자열에 안전 임베드(따옴표·역슬래시 escape — 조작된 ref는 미매치=ok:false로 정직 실패).
    // selector/text/ref는 jsStringLiteral로 JS 문자열 escape.
    static func actScript(_ obj: [String: Any], op: UInt8) -> String? {
        let locator: String
        if let selector = obj["selector"] as? String {
            locator = "document.querySelector(\(jsStringLiteral(selector)))"
        } else if let ref = obj["ref"] as? String {
            locator = "document.querySelector('[data-maru-ref='+JSON.stringify(\(jsStringLiteral(ref)))+']')"
        } else {
            return nil
        }
        switch op {
        case 12: // click
            return "(()=>{const e=\(locator);if(!e)return false;e.click();return true;})()"
        case 13: // type
            guard let text = obj["text"] as? String else { return nil }
            let txt = jsStringLiteral(text)
            return "(()=>{const e=\(locator);if(!e)return false;if(e.focus)e.focus();if('value'in e){e.value=\(txt);}else{e.textContent=\(txt);}e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;})()"
        case 14: // scroll
            return "(()=>{const e=\(locator);if(!e)return false;e.scrollIntoView();return true;})()"
        default: return nil
        }
    }

    // snapshot(§9.5.4): 페이지 ARIA 트리를 **read-only DOM walk**로 계산하는 eval 스크립트. 각 노드 {role,name,ref?,children?}.
    // role=명시 role 속성 또는 태그별 implicit role(W3C accname 정신 — 완전 구현은 후속). name=aria-label>aria-labelledby>
    // 연결 label>placeholder>alt>title>textContent. 상호작용 요소엔 임시 `data-maru-ref="eN"` 부여(ref act가 querySelector로
    // 해소) — **maru가 이미 executeScript/act로 주입하는 것과 같은 표면, read-only+maru-namespaced라 능력 부여 없음**(§8.1 정합).
    // interactive_only=상호작용 role만·max_depth=깊이 제한·selector=하위트리 루트. argJson은 Zig가 준 유효 JSON(그대로 IIFE 인자).
    static func snapshotScript(_ argJson: String) -> String {
        let body = """
        (function(opts){
          try {
            var root = opts.selector ? document.querySelector(opts.selector) : document.body;
            if (!root) return JSON.stringify({tree:[]});
            var interactiveOnly = opts.interactive_only === true;
            var maxDepth = (typeof opts.max_depth === 'number') ? opts.max_depth : -1;
            var old = document.querySelectorAll('[data-maru-ref]');
            for (var i=0;i<old.length;i++) old[i].removeAttribute('data-maru-ref');
            var seq = 0;
            var INTER = {button:1,link:1,textbox:1,checkbox:1,radio:1,combobox:1,listbox:1,menuitem:1,menuitemcheckbox:1,menuitemradio:1,option:1,searchbox:1,slider:1,switch:1,tab:1};
            function implicitRole(el){
              var tag = el.tagName.toLowerCase();
              if (tag==='button') return 'button';
              if (tag==='a') return el.hasAttribute('href') ? 'link' : null;
              if (tag==='input'){ var t=(el.getAttribute('type')||'text').toLowerCase();
                if (t==='checkbox') return 'checkbox'; if (t==='radio') return 'radio';
                if (t==='button'||t==='submit'||t==='reset') return 'button';
                if (t==='search') return 'searchbox'; if (t==='range') return 'slider';
                if (t==='hidden') return null; return 'textbox'; }
              if (tag==='textarea') return 'textbox';
              if (tag==='select') return 'combobox';
              if (tag==='img') return 'img';
              if (tag==='nav') return 'navigation';
              if (tag==='main') return 'main';
              if (tag==='ul'||tag==='ol') return 'list';
              if (tag==='li') return 'listitem';
              if (tag==='table') return 'table';
              if (tag==='form') return 'form';
              if (/^h[1-6]$/.test(tag)) return 'heading';
              return null;
            }
            function role(el){ return el.getAttribute('role') || implicitRole(el); }
            function accName(el){
              var n = el.getAttribute('aria-label'); if (n && n.trim()) return n.trim();
              var lb = el.getAttribute('aria-labelledby');
              if (lb){ var ps=[]; lb.split(/\\s+/).forEach(function(id){var e=document.getElementById(id); if(e) ps.push((e.textContent||'').trim());}); var joined=ps.join(' ').trim(); if (joined) return joined; }
              var tag = el.tagName.toLowerCase();
              if (tag==='input'||tag==='textarea'||tag==='select'){
                if (el.labels && el.labels.length){ var l=(el.labels[0].textContent||'').trim(); if(l) return l; }
                var ph = el.getAttribute('placeholder'); if (ph && ph.trim()) return ph.trim();
              }
              var alt = el.getAttribute('alt'); if (alt && alt.trim()) return alt.trim();
              var title = el.getAttribute('title'); if (title && title.trim()) return title.trim();
              var txt = (el.textContent||'').replace(/\\s+/g,' ').trim();
              if (txt.length>160) txt = txt.slice(0,160);
              return txt;
            }
            function visible(el){
              var s = window.getComputedStyle(el);
              if (!s || s.display==='none' || s.visibility==='hidden') return false;
              if (el.getAttribute('aria-hidden')==='true') return false;
              return true;
            }
            function walk(el, depth){
              if (el.nodeType!==1 || !visible(el)) return [];
              var r = role(el);
              var kids = [];
              if (maxDepth<0 || depth<maxDepth){
                var ch = el.children;
                for (var i=0;i<ch.length;i++){ var a = walk(ch[i], depth+1); for (var j=0;j<a.length;j++) kids.push(a[j]); }
              }
              var isInter = r && INTER[r];
              if (!r || (interactiveOnly && !isInter)) return kids;
              var node = { role: r, name: accName(el) };
              if (isInter){ var ref='e'+(++seq); el.setAttribute('data-maru-ref', ref); node.ref = ref; }
              if (kids.length) node.children = kids;
              return [node];
            }
            return JSON.stringify({ tree: walk(root, 0) });
          } catch (e) { return JSON.stringify({tree:[], error: String(e)}); }
        })
        """
        return body + "(" + argJson + ")"
    }

    // console(§9.5.9): document-start 주입 override. 페이지 월드에서 console.log/info/warn/debug/error를 wrap하고
    // window.onerror/unhandledrejection을 리슨해 각 항목을 bounded 페이지 ring `window.__maruConsole`(cap 200, oldest drop)에
    // {level,text}로 push한 뒤 **원 console을 그대로 호출**(페이지 로깅 무변). **메시지 핸들러 없음**(수신 능력 0인 in-page
    // override뿐 — §8.1(c) 유지, 페이지에 브리지 능력 안 줌). 콘솔 텍스트는 executeScript 결과와 같은 비신뢰 등급. host는
    // consoleDrainScript로 read-and-clear해 Swift 서버 버퍼로 옮긴다(proactive drain). 한 번만 설치(navigation마다 재실행돼도 멱등).
    static let consoleCaptureScript = """
    (function(){
      if (window.__maruConsoleInstalled) return;
      window.__maruConsoleInstalled = true;
      window.__maruConsole = [];
      var CAP = 200;
      function fmt(args){
        var parts = [];
        for (var i=0;i<args.length;i++){
          var a = args[i];
          try {
            if (typeof a === 'string') parts.push(a);
            else if (a instanceof Error) parts.push(a.stack || (a.name + ': ' + a.message));
            else { var s = JSON.stringify(a); parts.push(s === undefined ? String(a) : s); } // undefined/function/symbol은 stringify가 undefined 반환 → String 폴백(symbol은 throw→catch)
          } catch (e) { try { parts.push(String(a)); } catch (_) { parts.push('[unserializable]'); } }
        }
        return parts.join(' ');
      }
      function push(level, text){
        var b = window.__maruConsole;
        b.push({ level: level, text: String(text).slice(0, 8192) });
        if (b.length > CAP) b.splice(0, b.length - CAP);
      }
      var levels = ['log','info','warn','debug','error'];
      for (var i=0;i<levels.length;i++){
        (function(lv){
          var orig = console[lv];
          console[lv] = function(){
            try { push(lv, fmt(arguments)); } catch (e) {}
            if (orig) return orig.apply(console, arguments);
          };
        })(levels[i]);
      }
      window.addEventListener('error', function(ev){
        try { push('error', ev && ev.message ? (ev.message + (ev.filename ? (' (' + ev.filename + ':' + ev.lineno + ')') : '')) : 'error'); } catch (e) {}
      });
      window.addEventListener('unhandledrejection', function(ev){
        try { var r = ev ? ev.reason : null; push('error', 'Unhandled rejection: ' + (r && r.stack ? r.stack : String(r))); } catch (e) {}
      });
    })();
    """

    // console(§9.5.9): 페이지 ring을 read-and-clear해 `[{level,text},...]` 배열을 반환(evaluateJavaScript가 `[[String:Any]]`로
    // 준다). 아직 override 설치 전이면 빈 배열. Swift가 appendDrainedConsole로 서버 버퍼에 옮긴다.
    static let consoleDrainScript = """
    (function(){ var b = window.__maruConsole; if (!b || !b.length) return []; return b.splice(0, b.length); })()
    """

    // 문자열을 안전한 JS 문자열 리터럴로(JSON string은 valid JS 리터럴 — 따옴표·제어문자·유니코드 escape). 수동 조립 금지.
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
            let arr = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(arr.dropFirst().dropLast()) // ["..."] → "..."
    }

    // browser.wait(§9.4): 메인 액터에서 한 번에 하나의 evaluateJavaScript만 진행하는 100ms 직렬 polling coordinator.
    // selector는 **visible**(non-empty bounding box + display/visibility 허용)일 때 성공하고, load는 호출 시점의
    // WKWebView.isLoading이 false면 즉시 성공한다(다음 navigation을 기다리는 API가 아님). deadline은 wall clock 변경에
    // 영향받지 않는 systemUptime(monotonic). Zig active registry를 매 poll/콜백마다 확인해 surface close·grant revoke·
    // outer in-flight reap 뒤 DOM 평가와 늦은 completion을 중단한다.
    @MainActor private final class WaitCoordinator {
        private weak var webView: WKWebView?
        private let asyncId: UInt64
        private let condition: String
        private let selector: String?
        private let deadline: TimeInterval
        private let completion: (UInt32, String) -> Void
        private var deadlineWorkItem: DispatchWorkItem?
        private var completed = false
        private var hasPolled = false

        init(webView: WKWebView, asyncId: UInt64, condition: String, selector: String?, timeoutMs: UInt32,
             completion: @escaping (UInt32, String) -> Void)
        {
            self.webView = webView
            self.asyncId = asyncId
            self.condition = condition
            self.selector = selector
            self.deadline = ProcessInfo.processInfo.systemUptime + (Double(timeoutMs) / 1000.0)
            self.completion = completion
        }

        func start() {
            // selector evaluation callback 자체가 멎어도 요청 timeout은 독립적으로 끝나야 한다. main queue의
            // monotonic deadline task가 polling/callback과 같은 actor에서 단일 finish gate를 경합하므로 이중 완료가 없다.
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let item = DispatchWorkItem { [weak self] in self?.deadlineReached() }
            deadlineWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
            poll()
        }

        private func poll() {
            guard !completed else { return }
            guard maru_macos_control_browser_wait_is_active(asyncId) == 1 else {
                abandon()
                return
            }
            guard let webView = webView else {
                finish(4, "browser surface closed") // BrowserCompletionStatus.process_exited
                return
            }
            // 최초 호출은 이미 충족된 load를 즉시 성공시킨다. 그 뒤 재-poll은 deadline을 먼저 검사해, timeout 뒤
            // 조건이 바뀌었다고 늦게 성공시키지 않는다(100ms interval 때문에 최대 한 tick 뒤집히는 경계 회귀 방지).
            let firstPoll = !hasPolled
            hasPolled = true
            if !firstPoll && timedOut {
                finish(2, "")
                return
            }
            if condition == "load" {
                if !webView.isLoading {
                    finish(0, "")
                } else if timedOut {
                    finish(2, "")
                } else {
                    scheduleNext()
                }
                return
            }
            guard condition == "selector", let selector = selector, !selector.isEmpty else {
                finish(3, "Invalid wait params")
                return
            }
            let sel = BrowserControl.jsStringLiteral(selector)
            let script = "(()=>{try{const e=document.querySelector(\(sel));if(!e)return 'missing';const s=getComputedStyle(e),r=e.getBoundingClientRect();return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'?'visible':'missing';}catch(_){return 'invalid';}})()"
            webView.evaluateJavaScript(script) { [self] value, _ in
                guard !completed else { return }
                guard maru_macos_control_browser_wait_is_active(asyncId) == 1 else {
                    abandon()
                    return
                }
                let state = value as? String
                if state == "invalid" {
                    finish(3, "Invalid selector")
                } else if timedOut {
                    finish(2, "")
                } else if state == "visible" {
                    finish(0, "")
                } else {
                    scheduleNext()
                }
            }
        }

        private var timedOut: Bool { ProcessInfo.processInfo.systemUptime >= deadline }

        private func scheduleNext() {
            let interval = Double(MARU_BROWSER_WAIT_POLL_INTERVAL_MS) / 1000.0
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + min(interval, remaining)) { [self] in poll() }
        }

        private func deadlineReached() {
            guard !completed else { return }
            guard maru_macos_control_browser_wait_is_active(asyncId) == 1 else {
                abandon()
                return
            }
            finish(2, "")
        }

        private func finish(_ status: UInt32, _ message: String) {
            guard !completed else { return }
            completed = true
            deadlineWorkItem?.cancel()
            deadlineWorkItem = nil
            completion(status, message)
        }

        private func abandon() {
            guard !completed else { return }
            completed = true
            deadlineWorkItem?.cancel()
            deadlineWorkItem = nil
        }
    }

    @MainActor static func wait(_ webView: WKWebView, asyncId: UInt64, argJson: String,
                                completion: @escaping (UInt32, String) -> Void)
    {
        guard let obj = parseCookieArg(argJson),
              let condition = obj["condition"] as? String,
              let timeout = numberValue(obj["timeout_ms"]), timeout >= 1,
              timeout <= Double(MARU_BROWSER_WAIT_MAX_TIMEOUT_MS)
        else {
            completion(3, "Invalid wait params")
            return
        }
        let coordinator = WaitCoordinator(
            webView: webView,
            asyncId: asyncId,
            condition: condition,
            selector: obj["selector"] as? String,
            timeoutMs: UInt32(timeout),
            completion: completion)
        coordinator.start()
    }

    // clearStorage(§9.4 D4): 대상 문서 origin(host)의 쿠키+스토리지를 WKWebsiteDataStore로 comprehensive 삭제. host nil
    // (opaque origin)=대상 없음=아무것도 안 지움(전체 삭제 방지). displayName(도메인)으로 매치(getCookies host 필터와 동형).
    // 매치는 `hl == dn || hl.hasSuffix("."+dn)` — 대상 host이거나 **그 부모 도메인 레코드**만(getCookies의
    // cookieVisibleToHost와 대칭). 이전엔 `dn.hasSuffix("."+hl)` 역방향도 매치해 **자식/형제 서브도메인**(cdn.example.com
    // 등) 레코드까지 지웠다(교차-origin 과삭제). **잔여 한계(WebKit 모델)**: WKWebsiteDataRecord는 registrable-domain
    // (eTLD+1) 단위로 그룹돼 example.com 레코드 삭제가 그 도메인의 다른 서브도메인 데이터도 포함할 수 있다 — 부모 레코드를
    // 지우는 건 대상 host 데이터가 거기 있어 불가피(host 격리의 상한). 역방향 자식 삭제만 제거해 과삭제를 줄인다.
    @MainActor static func clearStorage(_ webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let host = webView.url?.host
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            guard let host = host, !host.isEmpty else {
                completion(true) // 대상 origin 없음 = 지울 것 없음(멱등, 전체 삭제 안 함)
                return
            }
            let hl = host.lowercased()
            let matches = records.filter { r in
                let dn = r.displayName.lowercased()
                return hl == dn || hl.hasSuffix("." + dn) // 대상 host이거나 그 부모 도메인만(역방향 자식 매치 제거)
            }
            store.removeData(ofTypes: types, for: matches) { completion(true) }
        }
    }
}

// 5e-2b-2(**테스트 전용 — 배경 스레드**): 앱 자신의 컨트롤 소켓에 붙어 `browser.navigate`/`browser.getUrl`을 **소켓 전
// 경로**(auth 프레임 → accept 스레드 → 메인 marshal → drainBrowserOps → BrowserControl → complete)로 자동 증명한다.
// 5d fixture가 BrowserControl을 **직접** 부른 것과 달리, 이건 인가(cap nonce)·wire·async marshal을 실제로 태운다.
// main-actor 상태를 안 건드리는 순수 C 소켓 I/O라 파일 스코프 nonisolated 자유 함수다(배경 큐에서 실행 — 메인 tick이
// 계속 돌며 marshal/complete해야 하므로 **메인을 블로킹하면 안 됨**). wire 포맷 단일 출처=Zig control_plane
// (serializeAuthSelf)·control_browser(browser.* params) — 여기 문자열은 그 계약을 미러링한 테스트 클라이언트다.
// 서버는 지속 세션(5f-0b-2b-1: auth 1회+요청 루프)을 지원하지만, 이 테스트 클라는 **단순성 위해 요청마다 새 연결**을 연다
// (한 요청 후 close → 서버 루프가 EOF로 그 연결 종료). 지속 연결 재사용은 후속(이 스모크엔 불요).
// 반환: (navigateOk="true"/진단, getUrl=data: URL 또는 진단). 실패(connect/타임아웃)는 진단 문자열로 남긴다(스모크는
// display 필요라 CI 비게이트 — 값 기록이 목적). socketPath=바인딩 경로, sid=web 패널 surface_id, nonceHex=cap nonce(64 hex).
private func runBrowserControlSmokeClient(socketPath: String, sid: UInt64, nonceHex: String, navigateURL: String) -> (navigateOk: String, getUrl: String) {
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid),\"cap_nonce\":\"\(nonceHex)\"}}"
    // 프레임 1 = auth.self(cap nonce), 프레임 2 = 요청. wire 포맷은 Zig serializeAuthSelf·browser.* params를 미러링.
    // url/hex는 제어문자 없는 data:/16진이라 raw 삽입 안전(테스트 고정 입력).
    let navReq = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":\(sid),\"url\":\"\(navigateURL)\"}}"
    let navResp = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: navReq)
    let navigateOk: String
    switch navResp {
    case .ok(let line): navigateOk = (browserCtlResult(line)?["ok"] as? Bool == true) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): navigateOk = why
    }

    // navigate는 async(load 시작만)라 data: URL 커밋을 **폴링**으로 기다린다(고정 sleep 대신 — 17차 [4]: 부하 시
    // false-negative 제거). 매 시도 새 연결로 getUrl을 보내 result.url이 채워지면 종료(최대 ~1.8s). 빈 문자열=아직
    // 커밋 전이라 재시도, 소켓 실패/형식 오류는 즉시 접는다(재시도 무의미).
    let getUrlReq = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.getUrl\",\"params\":{\"id\":\(sid)}}"
    var getUrl = "pending"
    for attempt in 0 ..< 30 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
        switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: getUrlReq) {
        case .ok(let line):
            guard let url = browserCtlResult(line)?["url"] as? String else { return (navigateOk, "unexpected:\(line.prefix(120))") }
            if !url.isEmpty { return (navigateOk, url) }
            getUrl = url // 빈 = 아직 커밋 전 → 재시도
        case .err(let why):
            return (navigateOk, why)
        }
    }
    return (navigateOk, getUrl)
}

// browser.wait 실 WKWebView/소켓 E2E: 처음부터 존재하지만 hidden인 요소를 첫 poll 150ms 뒤 visible로 바꿔 selector wait가
// **존재가 아니라 visible box**를 기다리는지, idle 문서의 load wait가 즉시 성공하는지, deadline 뒤 visible이 되는 요소가
// 늦은 성공 대신 전용 timeout(-32004)+data로 끝나는지, invalid CSS가 invalid_params인지
// 검증한다. 각 요청은 기존 smoke helper처럼 새 연결을 써 수명/인가/wire/ABI/Swift polling/응답 직렬화를 전부 탄다.
private func runBrowserWaitSmokeClient(socketPath: String, sid: UInt64, nonceHex: String) -> (selector: String, load: String, timeout: String, invalidSelector: String, selectorElapsedMs: String) {
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid),\"cap_nonce\":\"\(nonceHex)\"}}"
    // getUrl은 navigation commit만 뜻하므로 DOM fixture를 넣기 전에 현재 load idle을 먼저 보장한다.
    let loadReq = "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"load\",\"timeout_ms\":1000}}"
    let load: String
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: loadReq) {
    case .ok(let line): load = (browserCtlResult(line)?["ok"] as? Bool == true) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): load = why
    }
    guard load == "true" else { return (load, load, load, load, "0") }

    // 각 요소의 첫 getBoundingClientRect가 reveal timer를 arm한다. 즉 wait가 실제 첫 poll을 시작하기 전에는 timer도
    // 시작되지 않아 느린 머신에서도 fixture가 먼저 visible이 될 수 없고, 첫 poll은 반드시 hidden box를 관측한다.
    let prepScript = "(()=>{const add=(id,delay)=>{const e=document.createElement('div');e.id=id;e.style.cssText='display:none;width:1px;height:1px';document.body.appendChild(e);const rect=e.getBoundingClientRect.bind(e);let armed=false;e.getBoundingClientRect=()=>{if(!armed){armed=true;setTimeout(()=>{e.style.display='block'},delay);}return rect();};};add('maru-wait-ready',150);add('maru-wait-late',150);return true;})()"
    let prepEscaped = prepScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let prep = "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"browser.executeScript\",\"params\":{\"id\":\(sid),\"script\":\"\(prepEscaped)\"}}"
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: prep) {
    case .ok(let line):
        guard browserCtlResult(line)?["result"] as? Bool == true else {
            let why = "unexpected:\(line.prefix(120))"
            return (why, load, why, why, "0")
        }
    case .err(let why): return (why, why, why, why, "0")
    }

    let selectorReq = "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"selector\",\"selector\":\"#maru-wait-ready\",\"timeout_ms\":1000}}"
    let selectorStarted = ProcessInfo.processInfo.systemUptime
    let selectorResult = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: selectorReq)
    let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - selectorStarted) * 1000)
    let selector: String
    switch selectorResult {
    case .ok(let line): selector = (browserCtlResult(line)?["ok"] as? Bool == true && elapsedMs >= 100 && elapsedMs < 1000) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): selector = why
    }

    // 첫 poll이 timer를 arm하고 150ms 뒤 visible이 되지만 deadline은 125ms다. 조건-first 회귀라면 ~200ms에 성공하므로
    // 단순 미존재 selector보다 deadline 우선순위를 강하게 검증한다.
    let timeoutReq = "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"selector\",\"selector\":\"#maru-wait-late\",\"timeout_ms\":125}}"
    let timeout: String
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: timeoutReq) {
    case .ok(let line):
        let e = browserCtlError(line)
        let data = e?["data"] as? [String: Any]
        timeout = (e?["code"] as? Int == -32004 && data?["condition"] as? String == "selector" && data?["timeout_ms"] as? Int == 125) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): timeout = why
    }

    let invalidReq = "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"selector\",\"selector\":\"[\",\"timeout_ms\":1000}}"
    let invalidSelector: String
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: invalidReq) {
    case .ok(let line):
        invalidSelector = (browserCtlError(line)?["code"] as? Int == -32602) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): invalidSelector = why
    }
    return (selector, load, timeout, invalidSelector, String(elapsedMs))
}

// §9.5.9 console: 실제 WKWebView page world에서 console.log/error를 발화(executeScript)한 뒤 `browser.console` pull이
// 서버 버퍼로부터 [log]/[error] 항목을 회수하는지, clear=true 뒤 재-pull이 비는지 소켓 왕복으로 검증한다(GUI 입력 없이).
// 캡처=페이지 월드 override→page ring→pull 최종 drain→서버 버퍼→응답 파이프라인 전체를 자동 증명.
private func runBrowserConsoleSmokeClient(socketPath: String, sid: UInt64, nonceHex: String) -> (capture: String, clear: String) {
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid),\"cap_nonce\":\"\(nonceHex)\"}}"
    // 현재 load idle 보장(fixture 문서 커밋 완료 — override가 document-start에 설치된 상태).
    let loadReq = "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"load\",\"timeout_ms\":1000}}"
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: loadReq) {
    case .ok(let line): guard browserCtlResult(line)?["ok"] as? Bool == true else { let w = "unexpected-load:\(line.prefix(80))"; return (w, w) }
    case .err(let why): return (why, why)
    }
    // 페이지 월드에서 console.log/error 발화 → override가 window.__maruConsole ring에 push(executeScript도 page world라 가로채짐).
    let logScript = "(()=>{console.log('maru-console-smoke');console.error('boom');return true;})()"
    let logEscaped = logScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let logReq = "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"browser.executeScript\",\"params\":{\"id\":\(sid),\"script\":\"\(logEscaped)\"}}"
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: logReq) {
    case .ok(let line): guard browserCtlResult(line)?["result"] as? Bool == true else { let w = "unexpected-log:\(line.prefix(80))"; return (w, w) }
    case .err(let why): return (why, why)
    }
    // browser.console pull → console 배열에 [log] maru-console-smoke + [error] boom 회수 단언(pull이 최종 drain).
    let capture: String
    let pullReq = "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"browser.console\",\"params\":{\"id\":\(sid)}}"
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: pullReq) {
    case .ok(let line):
        let entries = browserCtlResult(line)?["console"] as? [[String: Any]] ?? []
        let hasLog = entries.contains { ($0["level"] as? String) == "log" && (($0["text"] as? String) ?? "").contains("maru-console-smoke") }
        let hasErr = entries.contains { ($0["level"] as? String) == "error" && (($0["text"] as? String) ?? "").contains("boom") }
        capture = (hasLog && hasErr) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): capture = why
    }
    // clear=true pull(반환 후 버퍼 비움) → 재-pull이 빈 배열(정적 fixture라 새 로그 없음). clear 동작 검증.
    _ = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"browser.console\",\"params\":{\"id\":\(sid),\"clear\":true}}")
    let clear: String
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: "{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"browser.console\",\"params\":{\"id\":\(sid)}}") {
    case .ok(let line):
        let entries = browserCtlResult(line)?["console"] as? [[String: Any]] ?? []
        clear = entries.isEmpty ? "true" : "unexpected:\(entries.count) left"
    case .err(let why): clear = why
    }
    return (capture, clear)
}

// 5f-5a: 실제 WKWebView page realm에서 bounded strict-JSON wrapper를 실행하고 소켓 응답까지 검증한다. 값 fidelity,
// user script가 serializer가 피해야 할 globals를 바꾸는 경우, escaped UTF-8 byte 경계, result-too-large, 실행/직렬화
// error taxonomy와 32 KiB 진단 frame, depth 128/129를 모두 GUI 입력 없이 자동화한다.
private func runBrowserBoundedResultSmokeClient(socketPath: String, sid: UInt64, nonceHex: String) -> (structured: String, awaitArgs: String, strictCsp: String, navigation: String, tamper: String, byteBoundary: String, tooLarge: String, executionError: String, serializationError: String, depth: String, stream: String) {
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid),\"cap_nonce\":\"\(nonceHex)\"}}"
    // WebPanel 자체 fixture가 cookie host 검증을 위해 data: 뒤 maru.test로 이동하므로 bounded suite 시작 직전에
    // strict-CSP data: 문서로 다시 이동하고 load 완료를 기다린다. 이 순서를 고정해야 다른 smoke와 레이스하지 않는다.
    // 기존 fixture와 다른 fragment를 쓰고 아래 CSP probe가 location.href exact-match까지 확인해 이번 navigation의
    // commit임을 증명한다. 단순 browser.wait(load)는 load 시작 전 isLoading=false를 보고 이전 문서에서 즉시 성공할 수 있다.
    let strictURL = MaruWebPanelView.browserFixtureURL + "#bounded-5f5c"
    let navObject: [String: Any] = ["jsonrpc": "2.0", "id": 29, "method": "browser.navigate", "params": ["id": sid, "url": strictURL]]
    let navData = try? JSONSerialization.data(withJSONObject: navObject)
    let navLine = navData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let navResponse = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: navLine)
    let waitLine = "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"browser.wait\",\"params\":{\"id\":\(sid),\"condition\":\"load\",\"timeout_ms\":2000}}"
    let waitResponse = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: waitLine)
    let strictNavigationOK = {
        guard case .ok(let nav) = navResponse, browserCtlResult(nav)?["ok"] as? Bool == true,
              case .ok(let wait) = waitResponse, browserCtlResult(wait)?["ok"] as? Bool == true else { return false }
        return true
    }()
    func request(_ id: Int, _ script: String, args: [Any] = [], maxBytes: Int = 1024 * 1024) -> BrowserCtlReqResult {
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "browser.executeScript",
            "params": ["id": sid, "script": script, "args": args, "max_result_bytes": maxBytes],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return .err("error:request-json") }
        return browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: line)
    }
    func line(_ response: BrowserCtlReqResult) -> String? {
        if case .ok(let value) = response { return value }
        return nil
    }
    func errorOK(_ response: BrowserCtlReqResult, code: Int, kind: String) -> Bool {
        guard let wire = line(response), let error = browserCtlError(wire), error["code"] as? Int == code,
              let data = error["data"] as? [String: Any], data["kind"] as? String == kind else { return false }
        return Data(wire.utf8).count <= 32 * 1024
    }

    var structured = "false"
    if let wire = line(request(31, "({n:null,b:true,x:1.5,s:'한글',a:[undefined,2],o:{u:undefined}})")),
       let value = browserCtlResult(wire)?["result"] as? [String: Any],
       value["n"] is NSNull, value["b"] as? Bool == true, value["x"] as? Double == 1.5,
       value["s"] as? String == "한글", let array = value["a"] as? [Any], array.count == 2,
       array[0] is NSNull, array[1] as? Int == 2, let object = value["o"] as? [String: Any], object["u"] is NSNull {
        structured = "true"
    }

    let awaitArgs: String
    if let wire = line(request(43, "Promise.resolve({sum:args[0]+args[1],nested:args[2].value})", args: [20, 22, ["value": "ok"]])),
       let value = browserCtlResult(wire)?["result"] as? [String: Any], value["sum"] as? Int == 42,
       value["nested"] as? String == "ok" { awaitArgs = "true" } else { awaitArgs = "false" }

    // fixture 자체가 script-src 'none'이다. host-compiled expression/await는 성공하지만 그 expression 안의 eval은
    // EvalError로 실패해야 CSP가 실제 활성이고 indirect-eval runner가 사라졌음을 동시에 증명한다.
    let cspMetaResponse = request(44, "({url:location.href,head:document.head.innerHTML})")
    let evalResponse = request(45, "eval('1+1')")
    let cspDocument = line(cspMetaResponse).flatMap { browserCtlResult($0)?["result"] as? [String: Any] }
    let cspHead = cspDocument?["head"] as? String ?? ""
    let strictCsp = strictNavigationOK && (cspDocument?["url"] as? String == strictURL) && cspHead.contains("script-src 'none'") && errorOK(evalResponse, code: -32006, kind: "execution") && awaitArgs == "true" ? "true" : "false"

    let tamperScript = "(()=>{const a=Array.isArray,k=Object.keys,f=Number.isFinite;JSON.stringify=()=>{throw 1};globalThis.TextEncoder=class{constructor(){throw 1}};Array.prototype.push=function(){this[0]='x'.repeat(1000000);return 1};Array.isArray=()=>false;Object.keys=()=>{throw 1};Number.isFinite=()=>false;const v={ok:true};Array.isArray=a;Object.keys=k;Number.isFinite=f;return v;})()"
    let tamper: String
    if let wire = line(request(32, tamperScript)), let value = browserCtlResult(wire)?["result"] as? [String: Any], value["ok"] as? Bool == true { tamper = "true" } else { tamper = "false" }

    let byteBoundary: String
    let exact = line(request(33, "'é'", maxBytes: 4)).flatMap { browserCtlResult($0)?["result"] as? String } == "é"
    let overWire = line(request(34, "'é'", maxBytes: 3))
    let over = overWire.flatMap { browserCtlError($0)?["code"] as? Int } == -32005
    byteBoundary = exact && over ? "true" : "false"

    let tooLargeResponse = request(35, "'xxxxxxxxxxxxxxxx'", maxBytes: 8)
    var tooLarge = "false"
    if let wire = line(tooLargeResponse), let error = browserCtlError(wire), error["code"] as? Int == -32005,
       let data = error["data"] as? [String: Any], data["limit_bytes"] as? Int == 8,
       data["observed_bytes_at_least"] as? Int == 9 { tooLarge = "true" }

    let executionResponse = request(36, "(()=>{throw new Error('x'.repeat(100000))})()")
    var executionError = errorOK(executionResponse, code: -32006, kind: "execution") ? "true" : "false"
    if let wire = line(executionResponse), let data = browserCtlError(wire)?["data"] as? [String: Any], data["diagnostics_truncated"] as? Bool != true { executionError = "false" }

    let serializationResponse = request(37, "(()=>{const x={};x.self=x;return x;})()")
    let serializationError = errorOK(serializationResponse, code: -32006, kind: "serialization") ? "true" : "false"

    let depth128 = "(()=>{let x=null;for(let i=0;i<128;i++)x=[x];return x;})()"
    let depth129 = "(()=>{let x=null;for(let i=0;i<129;i++)x=[x];return x;})()"
    let depthOK = line(request(38, depth128)).flatMap(browserCtlResult)?["result"] != nil
    let depthFail = errorOK(request(39, depth129), code: -32006, kind: "serialization")
    func streamRequest(_ id: Int, jsonBytes: Int) -> BrowserCtlStreamResult {
        let script = "'x'.repeat(\(jsonBytes - 2))"
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "browser.executeScript",
            "params": ["id": sid, "script": script, "max_result_bytes": jsonBytes],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let frame = String(data: data, encoding: .utf8) else {
            return BrowserCtlStreamResult(ok: false, transfer: "", bytes: 0, chunks: 0)
        }
        return browserCtlExecuteScriptStream(socketPath: socketPath, authFrame: auth, requestFrame: frame, requestId: id, expectedJsonBytes: jsonBytes)
    }
    let exactInline = streamRequest(40, jsonBytes: 512 * 1024)
    let firstChunked = streamRequest(41, jsonBytes: 512 * 1024 + 1)
    let maxChunked = streamRequest(42, jsonBytes: 16 * 1024 * 1024)
    print("browser bounded stream: inline=\(exactInline) first=\(firstChunked) max=\(maxChunked)")
    let stream = exactInline.ok && exactInline.transfer == "inline" && exactInline.chunks == 0
        && firstChunked.ok && firstChunked.transfer == "chunked" && firstChunked.chunks == 2
        && maxChunked.ok && maxChunked.transfer == "chunked" && maxChunked.chunks == 32
        ? "true" : "false"

    // 실행 중 top-level navigation이 시작되면 WebKit callback의 일반 failure보다 generation 변경을 우선해
    // kind=navigation으로 분류한다. 별도 연결에서 unresolved Promise를 기다리는 동안 새 data: 문서를 연다.
    let navigationBox = BrowserCtlReqBox()
    let navigationScriptObject: [String: Any] = [
        "jsonrpc": "2.0", "id": 46, "method": "browser.executeScript",
        "params": ["id": sid, "script": "(()=>{document.documentElement.dataset.maruExecStarted='46';return new Promise(()=>{})})()", "args": [], "max_result_bytes": 1024],
    ]
    let navigationScriptLine = (try? JSONSerialization.data(withJSONObject: navigationScriptObject)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    DispatchQueue.global(qos: .userInitiated).async {
        navigationBox.store(browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: navigationScriptLine))
    }
    var executionStarted = false
    for attempt in 0 ..< 20 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
        guard let wire = line(request(48, "document.documentElement.dataset.maruExecStarted==='46'")),
              browserCtlResult(wire)?["result"] as? Bool == true else { continue }
        executionStarted = true
        break
    }
    let replacementURL = MaruWebPanelView.browserFixtureURL + "%3Cp%3Enavigation%3C/p%3E"
    let replacementObject: [String: Any] = ["jsonrpc": "2.0", "id": 47, "method": "browser.navigate", "params": ["id": sid, "url": replacementURL]]
    let replacementLine = (try? JSONSerialization.data(withJSONObject: replacementObject)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let replacementResponse = browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: replacementLine)
    let replacementStarted = line(replacementResponse).flatMap(browserCtlResult)?["ok"] as? Bool == true
    let navigationResponse = navigationBox.wait(timeout: 3)
    let navigation = navigationResponse.map { executionStarted && replacementStarted && errorOK($0, code: -32006, kind: "navigation") ? "true" : "false" } ?? "false"
    return (structured, awaitArgs, strictCsp, navigation, tamper, byteBoundary, tooLarge, executionError, serializationError, depthOK && depthFail ? "true" : "false", stream)
}

// 1e-confirm-1c-2(테스트 전용 — 배경 스레드): **cap 없이** browser.navigate가 pane confirm-grant 흐름으로 성공하는지
// 자동 증명한다. auth.self는 **cap_nonce 없이** selector(=surface_id)만 보내 self-origin으로 인증하고, browser.navigate를
// 날린다 → 서버: 세션 cap 0 → needs_grant → handleNeedsGrant(env MARU_TEST_GRANT_DECISION 스텁) → approve면 grant 기록 +
// 재-dispatch → op → drainBrowserOps 실행 → complete. 반환="true"(응답 ok)·"unexpected:…"·"error:…". 요청마다 새 연결(5e 스모크와 동형).
private func runBrowserGrantSmokeClient(socketPath: String, sid: UInt64, navigateURL: String) -> String {
    // cap_nonce 없는 auth.self(selector만) — 무-cap 세션. wire는 Zig parseAuthFrame(cap_nonce optional)을 미러링.
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid)}}"
    let navReq = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.navigate\",\"params\":{\"id\":\(sid),\"url\":\"\(navigateURL)\"}}"
    switch browserCtlOneRequest(socketPath: socketPath, authFrame: auth, requestFrame: navReq) {
    case .ok(let line): return (browserCtlResult(line)?["ok"] as? Bool == true) ? "true" : "unexpected:\(line.prefix(120))"
    case .err(let why): return why
    }
}

// 5f-0b-3c/5f-3(테스트 전용): **지속 연결**로 subscribe→navigate(새 URL)→executeScript(alert)로 여러 이벤트 소스를 실제로
// 발화시키고, 서버-발신 `browser.*` notification이 오는지 **집합으로 수집**한다. url KVO=navigated·isLoading KVO=loadState·
// WKUIDelegate=dialog가 각 실 소스에서 pushEvent→outbound→writer→소켓 파이프라인을 타는지 자동 확인(3b 소켓·pushEvent
// 헤드리스에 더해 실 KVO/delegate까지). 반환=정렬된 이벤트 suffix 콤마결합("dialog,loadState,navigated")·"pending"·"error:".
// `SO_NOSIGPIPE`로 broken pipe가 앱을 안 죽인다. 지속 세션(2b-1)이라 한 연결로 auth 1회+요청 다수.
private func runBrowserEventSmokeClient(socketPath: String, sid: UInt64, nonceHex: String) -> String {
    guard let fd = connectControlSocket(socketPath, recvTimeoutSec: 3) else { return "error:connect" }
    defer { close(fd) }
    // auth(cap) + subscribe(전체 events) + navigate(새 URL=navigated+loadState 발화) + executeScript(alert=dialog 발화).
    // 지속 세션 = 한 연결. 5f-3: 여러 이벤트 종류가 실제로 흐르는지 집합으로 수집한다.
    let newUrl = "data:text/html,%3Ch1%3Eevt3c%3C/h1%3E"
    let auth = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\(sid),\"cap_nonce\":\"\(nonceHex)\"}}"
    let subReq = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"browser.subscribe\",\"params\":{\"id\":\(sid)}}" // events 생략=전체
    let navReq = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"browser.navigate\",\"params\":{\"id\":\(sid),\"url\":\"\(newUrl)\"}}"
    let jsReq = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"browser.executeScript\",\"params\":{\"id\":\(sid),\"script\":\"alert('e3c')\"}}"
    if !socketWriteLine(fd, auth) || !socketWriteLine(fd, subReq) || !socketWriteLine(fd, navReq) || !socketWriteLine(fd, jsReq) { return "error:write" }

    // 스트림을 읽으며 browser.* notification 메서드를 집합으로 모은다(응답·hello는 skip). navigated/loadState/dialog가
    // 각 KVO·delegate에서 발화돼 오는지 확인. 반환=정렬된 suffix 콤마 결합(예 "dialog,loadState,navigated")·"pending".
    var seen = Set<String>()
    var leftover = [UInt8]()
    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline {
        while let nl = leftover.firstIndex(of: 0x0A) {
            let lineBytes = Array(leftover[0 ..< nl])
            leftover.removeSubrange(0 ... nl)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                  let method = obj["method"] as? String, method.hasPrefix("browser.") else { continue }
            seen.insert(String(method.dropFirst("browser.".count))) // suffix만(navigated/loadState/dialog/…)
            if seen.contains("navigated"), seen.contains("loadState"), seen.contains("dialog") { break } // 3종 다 오면 조기 종료
        }
        if seen.contains("navigated"), seen.contains("loadState"), seen.contains("dialog") { break }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break } // 타임아웃/close
        leftover.append(contentsOf: buf[0 ..< n])
        if leftover.count > 64 * 1024 { return "error:overflow" }
    }
    return seen.isEmpty ? "pending" : seen.sorted().joined(separator: ",")
}

// 5e-2b-2(테스트 전용): JSON-RPC 응답 한 줄에서 `result` 객체를 파싱한다(hand-rolled 문자열 스캔 대신 — 17차 [5]:
// escape 따옴표 있는 URL도 정확). 파싱 불가·result 없음이면 nil.
private func browserCtlResult(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = obj["result"] as? [String: Any] else { return nil }
    return result
}

private func browserCtlError(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj["error"] as? [String: Any]
}

// 5f-3 [9]: 두 스모크 클라이언트 공통 소켓 헬퍼(중복 제거). connect + SO_NOSIGPIPE + SO_RCVTIMEO. 성공=연결된 fd(호출자가
// close)·실패=nil(내부서 close). SO_NOSIGPIPE로 서버가 닫힌 소켓에 write해도(broken pipe) 앱이 안 죽는다(write -1/EPIPE).
private func connectControlSocket(_ socketPath: String, recvTimeoutSec: Int) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let pathCap = MemoryLayout.size(ofValue: addr.sun_path) // 104
    if pathBytes.count >= pathCap { close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: pathCap) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[pathBytes.count] = 0
        }
    }
    let connRc = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connRc != 0 { close(fd); return nil }
    var tv = timeval(tv_sec: recvTimeoutSec, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

// ndjson 프레임(문자열 + 개행) 부분-write 처리 write. 실패=false.
private func socketWriteLine(_ fd: Int32, _ s: String) -> Bool {
    var bytes = Array(s.utf8); bytes.append(0x0A)
    return bytes.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

private enum BrowserCtlReqResult { case ok(String); case err(String) }
private final class BrowserCtlReqBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: BrowserCtlReqResult?

    func store(_ value: BrowserCtlReqResult) {
        lock.lock(); result = value; lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> BrowserCtlReqResult? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

// 5e-2b-2(테스트 전용): 컨트롤 소켓에 **한 번** 붙어 auth 프레임 + 요청 프레임을 보내고 응답 한 줄(hello notification
// 스킵)을 돌려준다. 이 함수는 요청 하나 = 연결 하나(테스트 단순성 — 서버는 지속 세션도 지원, 5f-0b-2b-1). `SO_NOSIGPIPE`로 broken pipe가 앱을
// 죽이지 않게 한다(write는 -1/EPIPE로 접힘). 수신 타임아웃 2s. 실패는 `.err(진단)`.
private func browserCtlOneRequest(socketPath: String, authFrame: String, requestFrame: String) -> BrowserCtlReqResult {
    guard let fd = connectControlSocket(socketPath, recvTimeoutSec: 2) else { return .err("error:connect") }
    defer { close(fd) }
    if !socketWriteLine(fd, authFrame) || !socketWriteLine(fd, requestFrame) { return .err("error:write") }

    // 응답 프레임(개행 종단, `"result"`/`"error"` 포함 = hello notification 아닌 응답)을 읽어 돌려준다. leftover로 프레임
    // 경계가 read 경계와 어긋나도 조립. 타임아웃/close/상한이면 .err.
    var leftover = [UInt8]()
    while true {
        while let nl = leftover.firstIndex(of: 0x0A) {
            let line = String(decoding: leftover[0 ..< nl], as: UTF8.self)
            leftover.removeSubrange(0 ... nl)
            if line.contains("\"result\"") || line.contains("\"error\"") { return .ok(line) }
            // hello 등 notification은 스킵하고 계속.
        }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return .err("error:no-response") } // 타임아웃(EAGAIN)·close
        leftover.append(contentsOf: buf[0 ..< n])
        if leftover.count > 64 * 1024 { return .err("error:overflow") } // 폭주 방어
    }
}

private struct BrowserCtlStreamResult {
    let ok: Bool
    let transfer: String
    let bytes: Int
    let chunks: Int
}

// 5f-5b 자동 smoke 전용: executeScript chunk notification을 전체 재조립하지 않고 id/seq/base64/final byte 수와
// 생성 fixture의 JSON string 모양을 streaming 검증한다. app client 메모리가 결과 크기만큼 늘어나는 것을 피한다.
private func browserCtlExecuteScriptStream(
    socketPath: String,
    authFrame: String,
    requestFrame: String,
    requestId: Int,
    expectedJsonBytes: Int
) -> BrowserCtlStreamResult {
    let failed = BrowserCtlStreamResult(ok: false, transfer: "", bytes: 0, chunks: 0)
    guard let fd = connectControlSocket(socketPath, recvTimeoutSec: 45) else { return failed }
    defer { close(fd) }
    guard socketWriteLine(fd, authFrame), socketWriteLine(fd, requestFrame) else { return failed }
    var leftover = [UInt8]()
    var resultId: Int?
    var nextSeq = 0
    var total = 0
    func validFixtureBytes(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, total + bytes.count <= expectedJsonBytes else { return false }
        if total == 0, bytes.first != 0x22 { return false }
        if total + bytes.count == expectedJsonBytes, bytes.last != 0x22 { return false }
        // 전체 16 MiB를 Swift -Onone client에서 다시 byte-scan하면 server writer 5초 timeout을 왜곡한다.
        // 경계와 각 chunk 중앙을 표본 검사하고, wire fidelity의 전수 검증은 Zig base64 round-trip unit이 맡는다.
        let sample = bytes[bytes.startIndex + bytes.count / 2]
        let samplePosition = total + bytes.count / 2
        if samplePosition != 0 && samplePosition != expectedJsonBytes - 1 && sample != 0x78 { return false }
        total += bytes.count
        return true
    }
    while true {
        while let nl = leftover.firstIndex(of: 0x0A) {
            let frame = Data(leftover[0 ..< nl])
            leftover.removeSubrange(0 ... nl)
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                print("browser stream malformed frame bytes=\(frame.count)")
                return failed
            }
            if object["method"] as? String == "browser.executeScriptChunk" {
                guard let params = object["params"] as? [String: Any], params["request_id"] as? Int == requestId,
                      let rid = params["result_id"] as? Int, rid >= 0,
                      params["seq"] as? Int == nextSeq, params["encoding"] as? String == "base64-json",
                      let encoded = params["data"] as? String, let decoded = Data(base64Encoded: encoded),
                      decoded.count <= BrowserResultTransferRegistry.maxCopyBytes,
                      resultId == nil || resultId == rid, validFixtureBytes(decoded)
                else {
                    print("browser stream invalid chunk seq=\(nextSeq) total=\(total) object=\(object)")
                    return failed
                }
                resultId = rid
                nextSeq += 1
                continue
            }
            if object["id"] as? Int == requestId, let error = object["error"] {
                print("browser stream server error request=\(requestId): \(error)")
                return failed
            }
            guard object["id"] as? Int == requestId, object["error"] == nil,
                  let result = object["result"] as? [String: Any], let transfer = result["transfer"] as? String
            else { continue } // hello 등 notification
            if transfer == "inline" {
                guard nextSeq == 0, let value = result["result"] as? String,
                      Data(value.utf8).count + 2 == expectedJsonBytes,
                      value.utf8.allSatisfy({ $0 == 0x78 }) else { return failed }
                return BrowserCtlStreamResult(ok: true, transfer: transfer, bytes: expectedJsonBytes, chunks: 0)
            }
            guard transfer == "chunked", let rid = result["result_id"] as? Int, rid == resultId,
                  result["seq_total"] as? Int == nextSeq, result["bytes"] as? Int == total,
                  total == expectedJsonBytes else { return failed }
            return BrowserCtlStreamResult(ok: true, transfer: transfer, bytes: total, chunks: nextSeq)
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            print("browser stream read ended request=\(requestId) seq=\(nextSeq) total=\(total) errno=\(errno)")
            return failed
        }
        leftover.append(contentsOf: buffer[0 ..< n])
        if leftover.count > 1024 * 1024 { return failed }
    }
}

// MARK: - Phase 4c/4d: 웹 패널 뷰 (빈 WKWebView 호스팅 래퍼 + 입력 전이 spike)
//
// 활성 pane 본문 rect에 붙는 **빈 WKWebView**를 감싸는 래퍼. WKWebView를 직접 컨테이너에 넣지 않고 이 래퍼로
// 감싸는 이유는 입력 라우팅(hitTest·performKeyEquivalent)을 한 곳에서 정책적으로 제어하기 위해서다.
//
// **4d(입력 responder 전이 spike, docs/web-panel.md §4)**: 4c는 hitTest→nil로 웹뷰를 완전 통과(입력 못 받음)
// 시켰지만, 4d는 웹뷰를 **focusable**로 바꾼다(클릭→WKWebView firstResponder→WebKit이 자체 keyDown/IME 소유).
// 단, maru 창 chrome을 위해 두 조건부 라우팅을 둔다:
//   1. **마우스(hitTest)**: 모달(palette/find/confirm/settings)이 **닫혀** 있으면 super.hitTest로 웹뷰가 클릭을
//      받아 포커스된다. 모달이 **열려** 있으면 nil을 반환해 클릭이 아래 터미널 뷰로 통과하고(overlay hitTest=nil
//      불변), Zig 모달 로직(바깥 클릭 dismiss·모달 요소 클릭)이 그대로 처리한다 — 웹뷰가 모달 위 클릭을 훔치지
//      않게(§4). 본문 rect 밖(탭 바·divider·grip)은 애초에 이 프레임에 없어 늘 터미널이 받는다.
//   2. **maru 키바인딩(performKeyEquivalent)**: 웹 포커스 중에는 ABI v146 typed WebKeyRoute를 조회한다. app_action은
//      같은 Zig resolver를 재평가하는 dispatchWebPanelAppAction이 현재 Action만 직접 실행하고, web_editor/pass-through는
//      WebKit·메뉴에 양보하며 consume_unbound/unknown은 소비한다. 범용 handleKeyDown의 terminal copy/paste·scroll·macro
//      전처리와 PTY write를 우회하고, route 뒤 config/mode가 달라졌으면 action 0회다. 웹이 포커스가 아니면 false만
//      반환해 터미널 IME/keyDown 경로는 손대지 않는다.
//
// **현행 범위**: browser와 file panel 실콘텐츠가 이 래퍼를 공유한다. Markdown live/source의 편집키는 WebKit, 앱 action과
// explicit consume은 Zig가 소유한다. WKWebView 내부 IME는 계속 WebKit 소유다. docs/web-panel.md §4, docs/file-panel.md §6.
/// FP10d 전용 제품 E2E coordinator. 제품 WebView host는 mode 적용·입력 전달만 맡고, smoke의 비동기
/// ready→edit→save→disk 관측 수명과 retry/epoch는 이 타입이 단독 소유한다. `isSmokeMode` didFinish에서만 시작된다.
@MainActor
final class FilePanelEditingSmokeProbe {
    weak var panel: MaruWebPanelView?
    var editor = "pending"
    var mermaidRequestState = "pending"
    // §2.3: 터미널 테마에서 파생한 syntax 색·선택 색·편집기 폰트 크기가 실제 문서에 주입됐는지(제품 경로 증거).
    var syntaxKeyword = "pending"
    var editorSelection = "pending"
    var editorFontSize = "pending"
    // 읽기 프리뷰 Mermaid 확인 뒤 소스 모드 전환을 한 번만 요청하기 위한 latch.
    private var requestedSourceMode = false
    var mermaidNavigationInFlight = "pending"
    var mermaidNavigationCancelled = "pending"
    var defaultMode = "pending"
    var edit = "pending"
    var cmdSRoute = "pending"
    var diskSaved = "pending"
    var write = "pending"

    private var navigationEpoch: UInt64 = 0
    private var saveStartedEpoch: UInt64?
    private var mermaidNavigationStarted = false
    private var observedEditorEpoch = 0
    nonisolated private static let marker = "FP10d actual Cmd+S marker"
    nonisolated private static let diskProbeTailBytes = 4096

    init(panel: MaruWebPanelView) {
        self.panel = panel
    }

    func invalidateNavigation() {
        navigationEpoch &+= 1
        saveStartedEpoch = nil
        // 탐색 취소 probe는 정상 편집·저장 E2E를 모두 끝낸 뒤 마지막에 실행한다. 그 reload는 editable
        // document recovery latch를 의도대로 세우므로, 직전 성공 증거를 지우거나 새 문서에서 편집을 재시작하지 않는다.
        if mermaidNavigationStarted { return }
        editor = "pending"
        mermaidRequestState = "pending"
        syntaxKeyword = "pending"
        editorSelection = "pending"
        editorFontSize = "pending"
        requestedSourceMode = false
        defaultMode = "pending"
        edit = "pending"
        cmdSRoute = "pending"
        diskSaved = "pending"
        write = "pending"
    }

    func start(requestedMode: Int32) {
        // didStartProvisionalNavigation이 실제 문서 수명 경계를 소유한다. 테스트용 직접 start도 stale
        // callback을 허용하지 않도록 navigation이 없었던 최초 호출만 같은 초기화를 수행한다.
        if navigationEpoch == 0 { invalidateNavigation() }
        let epoch = navigationEpoch
        defaultMode = requestedMode == Int32(MARU_FILE_PANEL_MODE_READ)
            ? "read" : "unexpected-\(requestedMode)"
        // A cold signed helper plus its bridge-free WKWebView may finish after the shell/editor is already
        // interactive. Keep the probe alive for the product smoke lifetime instead of declaring failure at 6 s.
        captureEditor(epoch: epoch, attemptsRemaining: 48)
    }

    private func captureEditor(epoch: UInt64, attemptsRemaining: Int) {
        guard epoch == navigationEpoch, let panel else { return }
        // 읽기 프리뷰가 render iframe 안에서 Mermaid 펜스를 실제 helper로 왕복시킨 뒤에야(mermaidRequest=ok)
        // 소스 모드로 전환해 CM6 편집·⌘S 저장을 검증한다. 두 모드를 한 스모크가 순서대로 지난다.
        let script = """
        JSON.stringify({
          editor: document.querySelector('.cm-content')?.textContent?.includes('FP4 viewer fixture') === true,
          previewImages: document.querySelectorAll('iframe').length,
          mermaidRequest: document.getElementById('viewer-status')?.dataset.mermaidRequest || 'pending',
          editorEpoch: Number(document.getElementById('viewer-status')?.dataset.editorEpoch || '0'),
          // §2.3 터미널 테마 syntax 색이 실제 문서에 주입됐는지. inline style만 읽으므로 app.css의 :root 폴백은
          // 잡히지 않는다 — 값이 있으면 native `applySyntaxThemeStyle`이 실제로 도달했다는 뜻이다.
          syntaxKeyword: document.documentElement.style.getPropertyValue('--maru-syntax-keyword').trim(),
          editorSelection: document.documentElement.style.getPropertyValue('--maru-editor-selection').trim(),
          editorFontSize: document.documentElement.style.getPropertyValue('--maru-editor-font-size').trim()
        })
        """
        panel.webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, epoch == self.navigationEpoch,
                  let raw = value as? String, let data = raw.data(using: .utf8),
                  let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let editorReady = probe["editor"] as? Bool ?? false
            let mermaidRequest = probe["mermaidRequest"] as? String ?? "pending"
            let editorEpoch = probe["editorEpoch"] as? Int ?? 0
            self.observedEditorEpoch = editorEpoch
            self.editor = String(editorReady)
            self.mermaidRequestState = mermaidRequest
            let syntaxKeyword = probe["syntaxKeyword"] as? String ?? ""
            if !syntaxKeyword.isEmpty { self.syntaxKeyword = syntaxKeyword }
            let editorSelection = probe["editorSelection"] as? String ?? ""
            if !editorSelection.isEmpty { self.editorSelection = editorSelection }
            let editorFontSize = probe["editorFontSize"] as? String ?? ""
            if !editorFontSize.isEmpty { self.editorFontSize = editorFontSize }
            if mermaidRequest == "ok", !self.requestedSourceMode {
                self.requestedSourceMode = true
                // Zig가 mode 권위다. Swift 로컬만 바꾸면 web은 소스 편집기를 띄우지만 ⌘S 라우팅 판정
                // (`Mode.isEditable`)은 여전히 read라 web_editor로 가지 않는다(실제로 wrong-route가 났다).
                if let session = panel.controller?.bridgeSession(for: panel.surfaceId) {
                    _ = maru_macos_app_session_set_file_panel_mode(
                        session, panel.surfaceId, UInt32(MARU_FILE_PANEL_MODE_SOURCE_EDIT))
                }
            }
            if editorReady, mermaidRequest == "ok" {
                self.startEditingSave(epoch: epoch)
                return
            }
            guard attemptsRemaining > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.captureEditor(epoch: epoch, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    /// 제품 isolated bridge에 실제 hang job을 등록하고 helper가 in-flight가 된 뒤 같은 WKWebView를 reload한다.
    /// didStartProvisionalNavigation이 pending Promise를 취소하고 exact Zig job을 revoke하는지를 실제 delegate 수명으로 잰다.
    private func startMermaidNavigationProbe(epoch: UInt64, editorEpoch: Int) {
        guard epoch == navigationEpoch, editorEpoch > 0, !mermaidNavigationStarted,
              let panel, let world = panel.bridgeWorld else {
            // 어느 전제가 깨졌는지 남긴다. 이 probe는 저장 성공 뒤 한 번만 돌기 때문에, 조용히 false로
            // 떨어지면 스모크가 무엇을 못 재고 있는지 알 수 없다.
            let reason = epoch != navigationEpoch ? "stale-epoch"
                : editorEpoch <= 0 ? "no-editor-epoch"
                : mermaidNavigationStarted ? "already-started"
                : panel == nil ? "no-panel" : "no-bridge-world"
            mermaidNavigationInFlight = "false(\(reason))"
            mermaidNavigationCancelled = "false(\(reason))"
            return
        }
        mermaidNavigationStarted = true
        // Mermaid는 읽기 모드에서만 렌더한다(소스 모드는 생 Markdown 편집이라 admission이 거부한다).
        // 편집·저장을 마쳤으므로 읽기로 되돌린 뒤 hang job을 넣는다 — 실제 사용 흐름(편집 후 결과 확인)과 같다.
        if let session = panel.controller?.bridgeSession(for: panel.surfaceId) {
            _ = maru_macos_app_session_set_file_panel_mode(
                session, panel.surfaceId, UInt32(MARU_FILE_PANEL_MODE_READ))
        }
        panel.webView.callAsyncJavaScript(
            """
            void window.maru.file.renderMermaid({
              editor_epoch: editorEpoch,
              document_revision: 9001,
              projection_generation: 9001,
              widget_id: 9001,
              widget_generation: 1,
              renderer_instance: 9001,
              fence_id: 9001,
              source_hash: "1b6fbbe23d2b88f55acfe0fbdf8823b240e7693a7eb9ac978bf76f2d1934714d",
              source: "__MARU_TEST_HANG__"
            }).catch(() => {});
            return true;
            """,
            arguments: ["editorEpoch": editorEpoch],
            in: nil,
            in: world
        ) { [weak self] result in
            guard let self, epoch == self.navigationEpoch,
                  case .success(let value) = result, value as? Bool == true else {
                self?.mermaidNavigationInFlight = "false"
                self?.mermaidNavigationCancelled = "false"
                return
            }
            self.waitForMermaidInFlight(epoch: epoch, attemptsRemaining: 40)
        }
    }

    private func waitForMermaidInFlight(epoch: UInt64, attemptsRemaining: Int) {
        guard epoch == navigationEpoch, let panel else { return }
        var snapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&snapshot)
        if snapshot.in_flight != 0 {
            mermaidNavigationInFlight = "true"
            panel.webView.reload()
            return
        }
        guard attemptsRemaining > 1 else {
            mermaidNavigationInFlight = "false"
            mermaidNavigationCancelled = "false"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForMermaidInFlight(epoch: epoch, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    func observeMermaidNavigationCancellation(inFlight: Bool, cancelledReplies: Int) {
        guard mermaidNavigationStarted, mermaidNavigationCancelled == "pending" else { return }
        mermaidNavigationInFlight = String(inFlight)
        // 취소 건수는 그 시점 pending 수에 따라 다르다 — 읽기 프리뷰가 자기 펜스를 렌더 중이면 hang job과
        // 함께 2건이 된다. 계약은 "reload가 pending reply를 남기지 않는다"이고, 남은 0은 별도
        // `mermaid_pending_replies` 단언이 본다.
        mermaidNavigationCancelled = cancelledReplies >= 1 ? "true" : "false-\(cancelledReplies)"
    }

    private func startEditingSave(epoch: UInt64) {
        guard epoch == navigationEpoch, saveStartedEpoch != epoch, let panel else { return }
        saveStartedEpoch = epoch
        guard let window = panel.webView.window, window.makeFirstResponder(panel.webView) else {
            edit = "false"
            return
        }
        panel.webView.callAsyncJavaScript(
            """
            const content = document.querySelector('.cm-content');
            if (!(content instanceof HTMLElement)) return false;
            content.focus();
            const selection = window.getSelection();
            if (selection === null) return false;
            const range = document.createRange();
            range.selectNodeContents(content);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, epoch == self.navigationEpoch else { return }
            guard case .success(let value) = result, value as? Bool == true else {
                self.edit = "false"
                return
            }
            self.postEditorText(epoch: epoch)
        }
    }

    private func postEditorText(epoch: UInt64) {
        guard epoch == navigationEpoch, let panel, let window = panel.webView.window else {
            edit = "false"
            return
        }
        for character in "\n\n\(Self.marker)\n" {
            let text = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: text,
                charactersIgnoringModifiers: text,
                isARepeat: false,
                keyCode: character == "\n" ? 36 : 0
            ) else {
                edit = "false"
                return
            }
            window.firstResponder?.keyDown(with: event)
        }
        captureEdit(epoch: epoch, attemptsRemaining: 20)
    }

    private func captureEdit(epoch: UInt64, attemptsRemaining: Int) {
        guard epoch == navigationEpoch, let panel else { return }
        panel.webView.callAsyncJavaScript(
            "return document.querySelector('.cm-content')?.textContent?.includes(marker) === true;",
            arguments: ["marker": Self.marker],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, epoch == self.navigationEpoch else { return }
            if case .success(let value) = result, value as? Bool == true {
                self.edit = "true"
                self.postSaveShortcut(epoch: epoch)
                return
            }
            guard attemptsRemaining > 1 else {
                self.edit = "false"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.captureEdit(epoch: epoch, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func postSaveShortcut(epoch: UInt64) {
        guard epoch == navigationEpoch, let panel, let controller = panel.controller,
              let window = panel.webView.window,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [.command],
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: "s",
                  charactersIgnoringModifiers: "s",
                  isARepeat: false,
                  keyCode: 1
              ) else {
            cmdSRoute = "unavailable"
            return
        }
        cmdSRoute = controller.webPanelKeyRoute(panel, event) == MARU_WEB_KEY_ROUTE_WEB_EDITOR
            ? "web-editor" : "wrong-route"
        window.sendEvent(event)
        captureDisk(epoch: epoch, attemptsRemaining: 30)
    }

    private func captureDisk(epoch: UInt64, attemptsRemaining: Int) {
        guard epoch == navigationEpoch,
              let path = ProcessInfo.processInfo.environment["MARU_FILE_PANEL"] else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved = Self.diskTailContainsMarker(path: path)
            DispatchQueue.main.async {
                guard let self, epoch == self.navigationEpoch else { return }
                if saved {
                    self.diskSaved = "true"
                    self.write = "true"
                    self.startMermaidNavigationProbe(epoch: epoch, editorEpoch: self.observedEditorEpoch)
                    return
                }
                guard attemptsRemaining > 1 else {
                    self.diskSaved = "false"
                    self.write = "false"
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.captureDisk(epoch: epoch, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    nonisolated private static func diskTailContainsMarker(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(diskProbeTailBytes) ? size - UInt64(diskProbeTailBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: diskProbeTailBytes) ?? Data()
            return data.range(of: Data(marker.utf8)) != nil
        } catch {
            return false
        }
    }
}

@MainActor
final class MaruWebPanelView: NSView {
    // FP14b(실험 — WebKit 위임): 이미지 문서에 **표시 조작을 얹지 않는다**. 팬/줌은 WebKit ImageDocument가
    // 이미 갖고 있고(뷰포트보다 큰 이미지의 맞춤↔실제크기 클릭 토글 + 스크롤) 핀치는 `allowsMagnification`이
    // 처리한다. 우리 JS로 그 위에 팬/줌을 다시 구현하니 네이티브 토글과 충돌해 "드래그를 끝낼 때 확대/축소되는"
    // 증상이 남았다(제보 3회) — 내장 동작은 C++ 레이어라 `preventDefault`로 막히지 않는다.
    // 그래서 주입은 **투명 이미지용 체커 배경 CSS 하나**로 줄인다. 자가 게이트(document.contentType)는 그대로다.
    static let imageDocumentViewerScript = """
    (function () {
      if (!String(document.contentType || "").startsWith("image/")) return;
      var dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
      var a = dark ? "#2a2a2e" : "#f2f2f4", b = dark ? "#232327" : "#e6e6ea";
      var css = document.createElement("style");
      css.textContent =
        "html,body{background-color:" + a + ";" +
        "background-image:linear-gradient(45deg," + b + " 25%,transparent 25%,transparent 75%," + b + " 75%)," +
        "linear-gradient(45deg," + b + " 25%,transparent 25%,transparent 75%," + b + " 75%);" +
        "background-size:16px 16px;background-position:0 0,8px 8px;}";
      document.head.appendChild(css);
    })();
    """

    let webView: WKWebView
    // Zig 전이(surface_id)와 매칭해 create/destroy/reframe이 옳은 웹뷰를 대상으로 하게 한다(§6 안정 키).
    let surfaceId: UInt64
    // 패널 종류(ABI panel_kind: 0=markdown=신뢰, 1=browser=비신뢰). 신뢰만 maru-app:// 스킴 핸들러를 등록하고 신뢰 UI를
    // 로드한다(5c-2c). 비신뢰는 인라인 placeholder + maru-app:// 네비 차단(외부 URL 로딩은 5d).
    let panelKind: UInt32
    // FP5 도크 파일 종류: 0=워크스페이스 browser, 1=도크 markdown, 2=도크 html. panelKind은 기존 trust ABI를
    // 유지하고, 이 값이 browser와 같은 untrusted panelKind을 쓰는 로컬 HTML을 구별한다.
    let filePanelKind: UInt32
    // FP12: text kind면 CM6 소스 문법 wire 토큰("json"·"python"…), svg면 "xml", markdown/html은 nil. 신뢰 shell URL에
    // `?lang=`으로 실려 web bootShell이 소스 편집기 문법을 고르게 한다(§2.2). 토큰은 Zig enum @tagName이라 [a-z] ASCII다.
    let filePanelLanguage: String?
    // svg면 "svg"(FP13 read 프리뷰+xml 소스), image면 "image"(FP14 panzoom 프리뷰), 그 외 nil. shell URL `?kind=`로 실림(§2.3).
    let filePanelShellKind: String?
    let pinnedFileHTMLURL: URL?
    private(set) var fileHTMLReadAccessURL: URL?
    // 5b: 신뢰 패널의 브리지 isolated world(page-world와 격리, window.maru 주입처). 비신뢰=nil. 스모크 격리 probe에 쓴다.
    var bridgeWorld: WKContentWorld?
    // 5b 격리 E2E probe 결과(스모크, MARU_WEB_PANEL): isolated world의 typeof window.maru("object" 기대) / page-world("undefined" 기대).
    var bridgeIsolatedProbe: String?
    var bridgePageWorldProbe: String?
    // 5b round-trip probe: isolated world에서 await maru.hello()의 server_version(핸들러 도달 + Zig dispatch 증명, "0.1.0" 기대).
    var bridgeHelloProbe: String?
    // FP4 실제 viewer probe: shell page가 sandboxed renderer의 bounded report를 dataset에 기록하고 smoke가 되읽는다.
    var fileViewerReadyProbe: String?
    var fileViewerRendererLoadedProbe: String?
    var fileViewerRendererScriptProbe: String?
    var fileViewerReadProbe: String?
    var fileViewerTextProbe: String?
    var fileViewerImagesProbe: String?
    var fileViewerLoadedImagesProbe: String?
    private(set) lazy var fileEditingSmokeProbe = FilePanelEditingSmokeProbe(panel: self)
    var fileViewerCriticalStyleProbe: String?
    var rendererBridgeProbe: String?
    var rendererHandlerProbe: String?
    var rendererParentAccessProbe: String?
    var fileHTMLScriptProbe: String?
    var fileHTMLAssetProbe: String?
    var fileHTMLOutsideAssetProbe: String?
    var fileHTMLAboutAttemptProbe: String?
    var fileHTMLPinnedProbe: String?
    private var fileHTMLProbeStarted = false
    private var requestedFileMode: Int32 = 0 // 0=read, 1=source-edit. Zig가 권위이고 여기 값은 마지막 적용본이다.
    // 신뢰 shell 문서가 로드를 마쳤는가. 같은 URL의 reload/programmatic navigation을 fresh document id로
    // 치환할지 판단하는 데 쓴다(서로 다른 WebContent document가 editor epoch를 공유하지 못하게).
    private var documentPageReady = false
    // 일반 탭 이탈 dirty snapshot은 close request와 달리 request_id가 없다. 소비한 Zig one-shot을 WebKit hydration
    // 사이에서 잃지 않도록 view가 한 개의 pending intent와 epoch만 보존하고, 성공한 page→native ACK 뒤에만 내린다.
    private var fileDirtySyncPending = false
    private var fileDirtySyncEpoch: UInt64 = 0
    private var fileDirtySyncInFlight = false
    private var fileDirtySyncSmokeArmed = false
    var fileDirtySyncRecoveryProbe: String?
    // 5d BrowserControl fixture E2E(스모크, browser 패널): 0=초기 로드 대기, 1=data: URL navigate 완료 대기, 2=probe 완료.
    var browserFixtureStage = 0
    // executeScript 시작 뒤 top-level navigation/reload가 시작되면 callback의 WebKit error를 execution이 아니라
    // navigation으로 분류한다. didStartProvisionalNavigation마다 증가하므로 같은 URL reload도 잡힌다.
    private(set) var navigationGeneration: UInt64 = 0
    var browserFixtureUrl: String? // BrowserControl.currentUrl 결과(navigate한 data: URL 기대).
    var browserFixtureScript: String? // BrowserControl.executeScript 결과(data: 문서의 #t 텍스트="maru5d" 기대).
    var browserFixtureCookies: String? // 5f-4c: 쿠키 seed 후 BrowserControl.getCookies JSON(seed한 sid=5f4c 포함 기대).
    // 5d fixture가 navigate하는 무-네트워크 data: URL(외부 로드 없이 navigate/getUrl/executeScript를 검증). **percent-encode**
    // 필수(리뷰12 [0]): 공백·`<`·`>`가 raw면 macOS 11-13의 legacy CFURL 파서가 URL(string:)=nil로 거부해 navigate 실패·
    // fixture silent false-green. 인코딩하면 전 지원 OS에서 파싱된다. 디코드 결과=`<h1 id=t>maru5d</h1>`(id=t라 getElementById('t') 매칭).
    nonisolated static let browserFixtureURL = "data:text/html,%3Cmeta%20http-equiv=Content-Security-Policy%20content=%22default-src%20%27none%27%3B%20script-src%20%27none%27%22%3E%3Ch1%20id=t%3Emaru5d%3C/h1%3E"
    // 7e-0: 비신뢰(browser) 패널이 **공유**하는 ephemeral(비영속) 웹사이트 데이터스토어. 쿠키·localStorage·캐시가 디스크에
    // 안 남고(비영속, 종료 시 소멸) 신뢰 콘텐츠(maru-app://, 기본 persistent store)와 **격리**된다(§7 untrusted 격리). browser
    // 탭들끼리는 공유(브라우저 세션 시맨틱 — 탭 간 로그인 유지). 앱 전역 1개(static lazy). 임의 웹 로드(7e-2) 전 안전 확보.
    static let browserDataStore = WKWebsiteDataStore.nonPersistent()
    // 로컬 HTML은 살아있는 스크립트+CSP 없음이므로 browser 탭의 쿠키 세션과 공유하지 않는다. 도크 HTML끼리만
    // 공유하는 별도 ephemeral store라 디스크 영속도 없고 browser credential도 보이지 않는다.
    static let filePanelDataStore = WKWebsiteDataStore.nonPersistent()
    // 4d 입력 라우팅용(약참조 — controller가 이 뷰를 강참조하는 surface.webPanels dict를 소유하므로 retain cycle 방지).
    weak var controller: MaruAppHostController?
    // 이 web 본문 rect가 split/dock divider에 맞닿는 가장자리 비트마스크(Zig seam_edges: left=1·right=2·bottom=4). create/reframe/
    // show 전이가 갱신한다. hitTest가 그 가장자리 margin 안 클릭/hover를 통과시켜 아래 터미널 뷰의 divider 드래그·resize
    // 커서가 잡게 한다(작은 시각 gap과 넓은 grab 폭 분리 — 4e review 0 후속). 0이면 통과 없음(모든 가장자리 바깥 경계).
    var seamEdges: UInt32 = 0
    // Zig가 최종 padded frame과 실제 resize target의 교집합에서 계산해 내린 edge별 logical-point 폭.
    // 0이면 해당 edge pass-through를 끈다.
    var dividerGrabLeftPt: CGFloat = 0
    var dividerGrabRightPt: CGFloat = 0
    var dividerGrabBottomPt: CGFloat = 0

    // Phase 7e-1a: browser(비신뢰, panelKind==1) 패널의 WKWebView nav 상태 — block-based KVO 관측값. url/canGoBack/
    // canGoForward 변화 시 여기 저장 + navStateDirty=true. tick drain(drainWebSurfaceTransition)이 dirty면 Zig
    // (set_web_nav_state)로 push 후 clear한다(핫패스 — dirty만 push). 7e-1b 주소창이 소비. 신뢰 패널은 주소창이
    // 없어 관측하지 않는다(navStateDirty는 늘 false 유지).
    var navUrl: String?
    var navCanGoBack = false
    var navCanGoForward = false
    var navStateDirty = false
    private var initialTrustedURL: URL?
    // Markdown shell URL의 query에 싣는 surface-local document identity. WebContent reload마다 증가하고 Zig의
    // beginDocument가 idempotent bind하므로 이전 page의 늦은 begin/read가 현재 hash baseline을 바꾸지 못한다.
    private var trustedDocumentId: UInt64 = 1
    private static let maxTrustedDocumentId: UInt64 = 9_007_199_254_740_991 // JavaScript Number.MAX_SAFE_INTEGER
    // KVO 관측 토큰 — deinit(뷰 dealloc)까지 프로퍼티로 붙잡아 관측을 유지한다(NSKeyValueObservation은 해제 시
    // 자동 invalidate). browser 패널만 등록한다.
    private var navObservers: [NSKeyValueObservation] = []

    // §9.5.9 console: 서버측 콘솔 버퍼(앱 프로세스 소유 — 페이지 문서와 별개라 **네비게이션에도 보존**). page-world override가
    // 쌓는 `window.__maruConsole`를 host가 proactive drain해 여기 누적하고, `browser.console` pull이 회수한다.
    static let serverConsoleCap = 500 // bounded ring(oldest drop) — §9.5.9 server_console_cap
    static let consoleDrainInterval: TimeInterval = 0.3 // proactive drain throttle(§9.5.9 console_drain_interval_ms=300)
    var consoleBuffer: [(level: String, text: String)] = []
    // capture-active=첫 `browser.console` pull에서 true(surface close까지 유지) → 그 전엔 proactive drain 0비용(미사용 패널
    // 에 매 tick eval 안 검). override 주입 자체는 항상 있어 페이지 ring은 쌓이므로 첫 pull이 그간 로그도 회수한다.
    var consoleCaptureActive = false
    var lastConsoleDrainAt: TimeInterval = 0

    // proactive drain / pull이 얻은 `[{level,text},...]`(evaluateJavaScript `[[String:Any]]`)를 서버 버퍼에 append(cap 초과=oldest drop).
    func appendDrainedConsole(_ value: Any?) {
        guard let arr = value as? [Any] else { return }
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            let level = (d["level"] as? String) ?? "log"
            let text = (d["text"] as? String) ?? ""
            consoleBuffer.append((level: level, text: text))
        }
        if consoleBuffer.count > Self.serverConsoleCap {
            consoleBuffer.removeFirst(consoleBuffer.count - Self.serverConsoleCap)
        }
    }

    // §9.5.10 통일-2: 서버 버퍼(cap 500 entries)를 **시간순 전량** `[{level,text}]` JSON으로 반환한다. 예전엔 콘솔 응답이
    // 단일 프레임(≤ 1 MiB)으로만 나가 서버 버퍼가 이를 넘으면 CLI Framer가 `payload_too_large`로 연결을 깼기에 512 KiB로 wire
    // 절단(최신 우선)했으나, 이제 snapshot과 같은 bounded-result transfer(inline ≤512 KiB·초과 chunk·>16 MiB clean 에러)로 나가므로
    // wire 절단을 없앤다 — bounded ring(500 entries)은 **메모리 상한**이지 더는 wire 절단이 아니다.
    func consoleBufferJSON() -> String {
        let ordered = consoleBuffer.map { ["level": $0.level, "text": $0.text] }
        if let data = try? JSONSerialization.data(withJSONObject: ordered), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }

    func clearConsoleBuffer() { consoleBuffer.removeAll() }

    init(frame frameRect: NSRect, surfaceId: UInt64, panelKind: UInt32, filePanelKind: UInt32, filePanelPath: String?, filePanelLanguage: String?, filePanelShellKind: String?, controller: MaruAppHostController) {
        self.surfaceId = surfaceId
        self.panelKind = panelKind
        self.filePanelKind = filePanelKind
        self.filePanelLanguage = filePanelLanguage
        self.filePanelShellKind = filePanelShellKind
        self.pinnedFileHTMLURL = filePanelKind == 2 ? filePanelPath.map { URL(fileURLWithPath: $0) } : nil
        // 트러스트 분기(5c-2c): markdown(0)=신뢰만 maru-app:// 스킴 핸들러를 config에 등록하고 신뢰 UI를 로드한다.
        // browser(1)=비신뢰엔 스킴 핸들러를 **애초에 등록하지 않는다**(origin 위장 탈취 1차 차단, §7 ④). 핸들러는
        // WKWebView 생성 **전에** config에 심어야 하므로 여기서 결정한다.
        let config = WKWebViewConfiguration()
        if filePanelKind == 2 {
            // FP14b: 격리 파일 문서(image/pdf/media/로컬 HTML) 중 **이미지 문서에만** 뷰어 조작을 얹는다.
            // 스크립트가 스스로 `document.contentType`을 보고 이미지가 아니면 no-op이라 새 ABI 힌트가 없다.
            // 브리지·메시지 핸들러를 쓰지 않는 순수 표시 조작이라 §8.1(c)(메시지 핸들러 0)를 유지한다.
            config.userContentController.addUserScript(WKUserScript(
                source: Self.imageDocumentViewerScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .page))
        }
        if filePanelKind != 2 {
            config.userContentController.addUserScript(WKUserScript(
                source: BrowserResultTransferRegistry.boundedPageBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
            // §9.5.9 console: page-world console.*/onerror override(bounded ring `window.__maruConsole`). 메시지 핸들러 없음
            // (§8.1(c) 유지). 로컬 HTML에는 제품 페이지 변형을 피하려고 이 browser-control script를 주입하지 않는다.
            config.userContentController.addUserScript(WKUserScript(
                source: BrowserControl.consoleCaptureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
        }
        let trusted = (panelKind == 0)
        var appURL: URL?
        var bridgeWorldLocal: WKContentWorld?
        if filePanelKind == 2 {
            config.websiteDataStore = Self.filePanelDataStore
        } else if !trusted {
            // 7e-0: 비신뢰(browser) 패널은 ephemeral 데이터스토어로 격리(비영속 + 신뢰 persistent store와 분리). 스킴
            // 핸들러·브리지는 미등록(신뢰 전용). 임의 웹 로딩은 7e-2, 스킴 화이트리스트는 그때 navigate 경로(Zig)에.
            config.websiteDataStore = Self.browserDataStore
        } else if let root = MaruAppSchemeHandler.webAssetRoot() {
            config.setURLSchemeHandler(MaruAppSchemeHandler(assetRoot: root), forURLScheme: MaruAppSchemeHandler.scheme)
            // 5b: 신뢰 브리지 — page-world와 격리된 named isolated world에만 window.maru 메시지 핸들러 + shim을 주입한다.
            // 핸들러(WKScriptMessageHandlerWithReply)는 진입서 isMainFrame+origin을 검사하고 통과분만 Zig로 넘긴다.
            let world = WKContentWorld.world(name: "MaruBridge")
            config.userContentController.addScriptMessageHandler(MaruBridgeHandler(surfaceId: surfaceId, controller: controller), contentWorld: world, name: "maru")
            config.userContentController.addUserScript(WKUserScript(source: MaruBridgeHandler.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            bridgeWorldLocal = world
            appURL = Self.trustedShellURL(document: 1, language: filePanelLanguage, shellKind: filePanelShellKind) // query는 origin을 바꾸지 않는다.
        }
        self.webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: config)
        // MARU_DEBUG일 때만 Safari 웹 인스펙터를 연다. 파일 패널 콘텐츠는 WKWebView 임베딩이라 Playwright로
        // 재현되지 않는 계층이 있다(레이아웃·주입 CSS·번들 신선도). 그 계층을 눈으로 볼 유일한 창구다.
        if #available(macOS 13.3, *), ProcessInfo.processInfo.environment["MARU_DEBUG"] != nil {
            self.webView.isInspectable = true
        }
        if filePanelKind == 2 {
            // 격리 파일 문서(image/pdf/media)는 네이티브 뷰어라 확대를 OS에 맡긴다(기본값이 false라 명시 활성화).
            self.webView.allowsMagnification = true
        }
        if filePanelKind == 1, #available(macOS 12.0, *) {
            // 빈 WKWebView가 view hierarchy에 들어간 뒤 첫 document paint가 오기 전에도 Markdown의
            // CSS Canvas와 같은 light/dark semantic 배경을 보여 기본 흰 backing frame을 노출하지 않는다.
            self.webView.underPageBackgroundColor = NSColor.textBackgroundColor
        }
        self.bridgeWorld = bridgeWorldLocal
        self.initialTrustedURL = appURL
        super.init(frame: frameRect)
        self.controller = controller
        webView.autoresizingMask = [.width, .height] // 래퍼 frame 갱신(reframe) 시 웹뷰가 꽉 채워 따라간다.
        // 네비게이션 정책은 신뢰·비신뢰 **양쪽** 모두 건다(리뷰11 [2]). 신뢰 패널은 maru-app:// 안으로만 top-level
        // 네비를 허용해 origin을 pin하고(신뢰 문서가 외부 URL로 top-level 이동하는 것 차단 — CSP는 sub-resource·form만
        // 막고 top-level 네비는 안 막음), 비신뢰 패널은 maru-app:// 네비를 cancel한다(origin 위장 방지). 분기는 아래 확장.
        webView.navigationDelegate = self
        // Phase 7f-1: browser(비신뢰) 패널만 팝업(target=_blank·window.open)을 연다 — uiDelegate로 createWebViewWith를
        // 받는다. 신뢰(maru-app UI) 패널은 uiDelegate 미설정이라 WKWebView 기본 동작(새 창 안 열림)으로 창 생성이 막힌다.
        if trusted == false && filePanelKind == 0 { webView.uiDelegate = self }
        if appURL == nil && pinnedFileHTMLURL == nil {
            // 비신뢰(browser) 또는 asset root 부재: 인라인 흰 HTML placeholder(외부 URL 로딩은 5d). **about:blank를 쓰지
            // 않는 이유**: WKWebView는 배경 미지정 문서(about:blank)를 시스템 appearance로 렌더해 macOS 다크 모드에선
            // 다크가 되어 아래 다크 터미널과 구분되지 않는다("흰 화면 안 뜸"의 루트 코즈). CSS로 배경을 명시 흰색으로
            // 못박아 appearance 무관하게 흰 rect를 보장한다.
            webView.loadHTMLString(MaruAppSchemeHandler.errorPageHTML(""), baseURL: nil)
        }
        addSubview(webView)
        // Phase 7e-1a: browser(비신뢰) 패널만 nav 상태를 관측한다(신뢰 패널은 주소창이 없음). WKWebView의 url·
        // canGoBack·canGoForward는 KVO 준수 프로퍼티라 block-based KVO로 변화를 잡아 패널 프로퍼티에 저장 + dirty를
        // 세운다(tick drain이 Zig로 push). 관측 자체가 어댑터 책임(정책·저장은 Zig).
        // KVO changeHandler는 @Sendable이라 main-actor 상태를 직접 못 건드린다. WKWebView의 이 세 프로퍼티는 WebKit
        // 네비게이션(메인 스레드)에서만 바뀌므로 assumeIsolated로 동기 진입한다(NSColorSampler/애니메이션 콜백과 같은
        // 코드베이스 공통 패턴). wv도 @MainActor라 assumeIsolated 안에서 읽는다.
        installNavObservers()
    }

    /// 소유 surface dict 등록 뒤 호출한다. 브리지 handler가 surface→session을 해소하기 전에 document-start 요청이
    /// 달리는 race를 막기 위해 신뢰 문서 load를 init에서 분리한다. reparent 때는 다시 부르지 않는다.
    func startInitialLoad() {
        if let url = initialTrustedURL {
            initialTrustedURL = nil
            webView.load(URLRequest(url: url))
            return
        }
        guard let url = pinnedFileHTMLURL else { return }
        // 정적 HTML만 보고 상대 resource 유무를 완전 판정할 수 없다(JS 동적 import/fetch 포함). 문서 계약대로 부모
        // 디렉터리를 read scope로 주고, WebKit이 그 밖의 file: 접근을 차단하게 한다.
        let access = url.deletingLastPathComponent()
        fileHTMLReadAccessURL = access
        webView.loadFileURL(url, allowingReadAccessTo: access)
    }

    // 신뢰 shell(markdown·text·svg·image) 문서 URL. `&lang=`은 소스 편집기 문법, `&kind=svg|image`는 svg read
    // 프리뷰+소스 / image panzoom 프리뷰를 고르게 한다(§2.2·§2.3). 토큰은 Zig enum @tagName([a-z] ASCII)라 query
    // 인코딩이 불필요하고, `document` 파서(trustedDocumentId)는 name 필터라 무영향.
    private static func trustedShellURL(document: UInt64, language: String?, shellKind: String?) -> URL? {
        var query = "document=\(document)"
        if let language { query += "&lang=\(language)" }
        if let shellKind { query += "&kind=\(shellKind)" }
        return URL(string: "\(MaruAppSchemeHandler.scheme)://app/index.html?\(query)")
    }

    private func loadFreshTrustedDocument() -> Bool {
        guard filePanelKind == 1, trustedDocumentId < Self.maxTrustedDocumentId,
              let url = Self.trustedShellURL(document: trustedDocumentId + 1, language: filePanelLanguage, shellKind: filePanelShellKind)
        else { return false }
        trustedDocumentId += 1
        webView.load(URLRequest(url: url))
        return true
    }

    private func trustedDocumentId(in url: URL) -> UInt64? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).filter { $0.name == "document" }
        guard values.count == 1, let raw = values[0].value, let value = UInt64(raw),
              value > 0, value <= Self.maxTrustedDocumentId else { return nil }
        return value
    }

    // §2.3: 현재 터미널 색상 테마에서 파생한 text 소스 편집기 syntax 색을 `--maru-syntax-*` CSS 변수로 shell에 주입한다.
    // 신뢰 shell(text/markdown)에만 적용하고, CSS 변수라 이미 마운트된 CM6 span도 즉시 재도색된다(app.css 폴백 위에 override).
    func applySyntaxThemeStyle() {
        guard filePanelKind == 1, let session = controller?.bridgeSession(for: surfaceId) else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            maru_macos_app_session_syntax_style_js(session, p.baseAddress, p.count)
        }
        guard n > 0, n <= buf.count else { return }
        let js = String(decoding: buf[0 ..< n], as: UTF8.self)
        webView.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    // §2.3: ⌘+/− 폰트 줌을 파일 패널 콘텐츠에도 적용한다(사용자 결정 2026-07-23). 배율은 Zig가 현재 폰트/base로
    // 계산한 milli(1000=1.0). **kind별로 자연스러운 수단**: 신뢰 shell(1)은 편집기가 이미 `--maru-editor-font-size`
    // (pt, applySyntaxThemeStyle)로 스케일되므로, 여기선 읽기 프리뷰 iframe만 `maru:file-zoom` 이벤트로 페이지 줌한다
    // (shell이 받아 render iframe에 `documentElement.zoom`을 전달 — cross-origin이라 직접 못 건드림). HTML/PDF
    // browser(2)는 콘텐츠 전체가 한 문서라 WKWebView `pageZoom`으로 브라우저식 페이지 줌한다.
    func applyFilePanelZoom(_ zoomMilli: UInt32) {
        let zoom = Double(zoomMilli) / 1000.0
        if filePanelKind == 2 {
            webView.pageZoom = CGFloat(zoom)
            return
        }
        guard filePanelKind == 1 else { return }
        // zoom은 Zig가 [0.1,10]으로 클램프한 값이라 안전한 숫자 리터럴이다(주입 위험 0).
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('maru:file-zoom',{detail:{zoom:\(zoom)}}))",
            in: nil,
            in: .page
        ) { _ in }
    }

    func applyFilePanelMode(_ rawMode: Int32) {
        guard filePanelKind == 1 else { return }
        guard Self.isKnownFilePanelMode(rawMode) else { return }
        requestedFileMode = rawMode
        guard webView.url?.scheme == MaruAppSchemeHandler.scheme, webView.url?.host == "app" else { return }
        let mode = requestedFileMode == Int32(MARU_FILE_PANEL_MODE_SOURCE_EDIT) ? "source-edit"
            : (requestedFileMode == Int32(MARU_FILE_PANEL_MODE_RICH) ? "rich" : "read")
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('maru:file-mode',{detail:{mode:'\(mode)'}}))",
            completionHandler: nil
        )
    }

    // §2.6: 본문 우클릭 메뉴에서 고른 항목 중 **선택에 붙은 것**만 여기로 온다.
    //
    // **키보드 단축키와 같은 일을 해야 한다** — 그래서 web에 흉내를 시키지 않고 표준 편집 명령을 responder
    // chain으로 그대로 보낸다. web에서 텍스트로 주고받으면 붙여넣기가 서식(HTML)을 잃고, 잘라내기도 편집기
    // 자신의 되돌리기 기록과 다른 경로로 들어간다(제보: 리치에서 원본이 안 붙고 ⌘Z로 안 살아났다).
    func applyFileMenuAction(_ rawAction: UInt32) {
        guard filePanelKind == 1 else { return }
        // 편집 명령은 first responder를 대상으로 한다. 메뉴 클릭은 오버레이 통과 경로라 터미널 뷰가 받았으므로
        // 여기서 그 문서로 되돌린다(Zig도 같은 tick에 focus를 요청하지만, 이 명령은 지금 실행된다).
        if let window = webView.window, window.firstResponder !== webView {
            window.makeFirstResponder(webView)
        }
        let selector: Selector
        switch rawAction {
        case 1: selector = #selector(NSText.copy(_:))
        case 2: selector = #selector(NSText.cut(_:))
        case 3: selector = #selector(NSText.paste(_:))
        case 4: selector = #selector(NSText.selectAll(_:))
        default: return
        }
        // **그 웹뷰를 직접 대상으로 보낸다.** `to: nil`은 responder chain을 타는데, 메뉴 클릭은 오버레이 통과
        // 경로라 그 순간 first responder가 터미널 뷰다 — 명령이 웹뷰까지 안 가서 메뉴만 무반응이었다
        // (같은 selector를 쓰는 키보드 단축키는 웹뷰가 first responder라 잘 됐다).
        //
        // 포커스 전이는 같은 이벤트 루프 안에서 끝나지 않을 수 있으므로 한 턴 뒤에 보낸다 — 그래야 WebKit이
        // 명령을 받을 때 그 프레임이 이미 focus를 쥐고 있다(선택은 우클릭 때 되살려 둔 그대로다).
        // **문서 안의 편집 포커스를 먼저 되돌린다.** 명령이 responder chain에 닿아도(로그: chain=true) 그 시점에
        // 문서의 편집 대상이 focus를 안 쥐고 있으면 WebKit은 아무것도 하지 않는다 — 메뉴만 무반응이던 원인이다.
        // 우클릭 때 붙잡아 둔 선택을 되살리고 그 편집기에 focus를 준 **뒤에** 명령을 보낸다(완료 콜백 순서).
        // **명령을 보내기 직전에 문서 안의 편집 대상과 선택을 되살린다.** 문서가 그 상태가 아니면 WebKit은
        // 명령을 받고도(responder chain은 처리했다고 답한다) 아무 일도 하지 않는다 — 메뉴만 무반응이던 원인이다.
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('maru:file-menu-focus'))",
            in: nil,
            in: .page
        ) { [weak self] _ in
            guard let self else { return }
            if let window = self.webView.window, window.firstResponder !== self.webView {
                window.makeFirstResponder(self.webView)
            }
            _ = NSApp.sendAction(selector, to: nil, from: self)
        }
    }

    static func isKnownFilePanelMode(_ rawMode: Int32) -> Bool {
        rawMode == Int32(MARU_FILE_PANEL_MODE_READ)
            || rawMode == Int32(MARU_FILE_PANEL_MODE_SOURCE_EDIT)
            || rawMode == Int32(MARU_FILE_PANEL_MODE_RICH)
    }

    func requestFileDirtySync(requestId: UInt64 = 0) {
        if requestId == 0 {
            guard filePanelKind == 1 else { return }
            // Zig가 이미 꺼낸 one-shot은 provisional navigation 동안 URL이 nil/about:blank여도 잃으면 안 된다.
            // pending 하나가 surface의 모든 반복 tab-leave를 합치고 didFinish가 exact origin에서 재개한다.
            guard !fileDirtySyncPending else { return }
            fileDirtySyncPending = true
            if webView.url?.scheme == MaruAppSchemeHandler.scheme, webView.url?.host == "app" {
                resumeFileDirtySyncIfPending()
            }
            return
        }

        guard filePanelKind == 1, webView.url?.scheme == MaruAppSchemeHandler.scheme,
              webView.url?.host == "app" else {
            if let session = controller?.bridgeSession(for: surfaceId) {
                maru_macos_app_session_fail_file_panel_dirty_sync(session, surfaceId, requestId)
            }
            return
        }
        guard let session = controller?.bridgeSession(for: surfaceId) else { return }
        webView.callAsyncJavaScript(
            "return await window.__maruSyncDirtyForClose?.(requestId) === true",
            arguments: ["requestId": requestId],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, let current = self.controller?.bridgeSession(for: self.surfaceId), current == session else { return }
            guard case .success(let value) = result, value as? Bool == true else {
                maru_macos_app_session_fail_file_panel_dirty_sync(current, self.surfaceId, requestId)
                return
            }
        }
    }

    private func resumeFileDirtySyncIfPending() {
        guard fileDirtySyncPending, !fileDirtySyncInFlight else { return }
        fileDirtySyncEpoch &+= 1
        fileDirtySyncInFlight = true
        attemptFileDirtySync(epoch: fileDirtySyncEpoch, attemptsRemaining: 40)
    }

    private func attemptFileDirtySync(epoch: UInt64, attemptsRemaining: Int) {
        guard fileDirtySyncPending, epoch == fileDirtySyncEpoch else { return }
        webView.callAsyncJavaScript(
            """
            if (typeof window.__maruSyncDirty !== 'function') return 'missing';
            return await window.__maruSyncDirty() === true ? 'success' : 'failed';
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, self.fileDirtySyncPending, epoch == self.fileDirtySyncEpoch else { return }
            if case .success(let value) = result, value as? String == "success" {
                // page 함수는 setDirty bridge ACK를 await한 뒤에만 true다. native pending도 이미 내려간 시점이다.
                self.fileDirtySyncInFlight = false
                self.fileDirtySyncPending = false
                if self.fileDirtySyncSmokeArmed {
                    self.fileDirtySyncSmokeArmed = false
                    self.fileDirtySyncRecoveryProbe = "true"
                }
                return
            }
            // hook 설치 전만 100ms×40회 재시도한다. 설치된 hook/bridge 자체가 실패했거나 WebContent가 종료된
            // 경우에는 반복 I/O를 만들지 않고 fail-close하고, 다음 navigation didFinish가 같은 intent를 재개한다.
            guard case .success(let value) = result, value as? String == "missing",
                  attemptsRemaining > 1 else {
                self.fileDirtySyncInFlight = false
                if self.fileDirtySyncSmokeArmed {
                    self.fileDirtySyncSmokeArmed = false
                    if case .success(let value) = result {
                        self.fileDirtySyncRecoveryProbe = "failed-\(value as? String ?? "value")"
                    } else {
                        self.fileDirtySyncRecoveryProbe = "failed-eval"
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attemptFileDirtySync(epoch: epoch, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    func requestFileSaveForClose(requestId: UInt64) {
        guard filePanelKind == 1,
              webView.url?.scheme == MaruAppSchemeHandler.scheme,
              webView.url?.host == "app",
              let session = controller?.bridgeSession(for: surfaceId)
        else {
            if let session = controller?.bridgeSession(for: surfaceId) {
                maru_macos_app_session_complete_file_panel_save_close(session, surfaceId, requestId, 0, 0)
            }
            return
        }
        webView.callAsyncJavaScript(
            "return await window.__maruSaveForClose?.(requestId)",
            arguments: ["requestId": requestId],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, let current = self.controller?.bridgeSession(for: self.surfaceId), current == session else { return }
            guard case .success(let value) = result, let report = value as? [String: Any],
                  report["success"] as? Bool == true, report["dirty"] as? Bool == false,
                  let revisionNumber = report["revision"] as? NSNumber
            else {
                maru_macos_app_session_complete_file_panel_save_close(current, self.surfaceId, requestId, 0, 0)
                return
            }
            maru_macos_app_session_complete_file_panel_save_close(current, self.surfaceId, requestId, revisionNumber.uint64Value, 1)
        }
    }

    func unlockFileClose(requestId: UInt64) {
        guard filePanelKind == 1, let session = controller?.bridgeSession(for: surfaceId) else { return }
        webView.callAsyncJavaScript(
            "return await window.__maruUnlockFileClose?.(requestId) === true",
            arguments: ["requestId": requestId],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, let current = self.controller?.bridgeSession(for: self.surfaceId), current == session else { return }
            guard case .success(let value) = result, value as? Bool == true else {
                maru_macos_app_session_fail_file_panel_close_unlock(current, self.surfaceId, requestId)
                return
            }
        }
    }

    func requestFileReload(conflict: Bool) {
        if filePanelKind == 2 {
            // 핀된 local HTML의 clean 외부 변경. navigation delegate가 같은 top-level URL의 reload만 허용한다.
            webView.reload()
            return
        }
        guard filePanelKind == 1, webView.url?.scheme == MaruAppSchemeHandler.scheme,
              webView.url?.host == "app" else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('maru:file-reload', {detail:{conflict:\(conflict ? "true" : "false")}}))",
            completionHandler: nil
        )
    }

    /// 실제 viewer의 비동기 단계(iframe load→read→render→asset)를 최대 4초 동안 250ms 간격으로 관측한다. 제품
    /// 동작에는 영향을 주지 않고 smokeMode의 didFinish에서만 호출한다. ready면 즉시 끝내고 실패면 마지막 단계값을 남긴다.
    private func captureFileViewerProbe(attemptsRemaining: Int) {
        let script = """
        (() => {
          const s = document.getElementById('viewer-status');
          const critical = document.querySelector('style[data-maru-critical-background]');
          const external = document.querySelector('link[rel="stylesheet"][href="app.css"]');
          const criticalStyle = critical instanceof HTMLStyleElement
            && critical.sheet !== null
            && external !== null
            && Boolean(critical.compareDocumentPosition(external) & Node.DOCUMENT_POSITION_FOLLOWING);
          return JSON.stringify({
            rendererLoaded: s?.dataset.rendererLoaded || 'pending',
            rendererScript: s?.dataset.rendererScriptReady || 'pending',
            fileRead: s?.dataset.fileRead || 'pending',
            ready: s?.dataset.viewerReady || 'pending',
            text: s?.dataset.viewerText || 'pending',
            images: s?.dataset.viewerImages || 'pending',
            loaded: s?.dataset.viewerLoadedImages || 'pending',
            bridge: s?.dataset.rendererBridgeType || 'pending',
            handler: s?.dataset.rendererHandlerType || 'pending',
            parentAccess: s?.dataset.rendererParentAccessible || 'pending',
            criticalStyle: String(criticalStyle)
          });
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let raw = value as? String, let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            self.fileViewerRendererLoadedProbe = obj["rendererLoaded"]
            self.fileViewerRendererScriptProbe = obj["rendererScript"]
            self.fileViewerReadProbe = obj["fileRead"]
            self.fileViewerReadyProbe = obj["ready"]
            self.fileViewerTextProbe = obj["text"]?.replacingOccurrences(of: "\n", with: " ")
            self.fileViewerImagesProbe = obj["images"]
            self.fileViewerLoadedImagesProbe = obj["loaded"]
            self.rendererBridgeProbe = obj["bridge"]
            self.rendererHandlerProbe = obj["handler"]
            self.rendererParentAccessProbe = obj["parentAccess"]
            self.fileViewerCriticalStyleProbe = obj["criticalStyle"]
            if obj["ready"] == "true" {
                self.startFileEditingProbe()
                return
            }
            guard attemptsRemaining > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.captureFileViewerProbe(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    /// Zig entry가 정한 mode를 그대로 넘긴다. ready/edit/save/disk orchestration은 전용 smoke coordinator 책임이다.
    private func startFileEditingProbe() {
        guard controller?.isFileEditingSmokeMode == true else { return }
        fileEditingSmokeProbe.start(requestedMode: requestedFileMode)
    }
    // Phase 7f-1: 팝업 adopt init — `WKUIDelegate.createWebViewWith`가 넘긴 configuration으로 새 WKWebView를 만들어
    // 채택한다. `window.opener`·named window·`postMessage` 링크는 **그 config로 만든 webview**로만 성립하므로(WebKit
    // 계약 — 넘어온 config를 그대로 써야 하고 수정 금지), 자기 config를 짓는 위 init과 갈라진다. 팝업은 임의 외부
    // 콘텐츠라 항상 browser(untrusted, panelKind==1). frame은 호출처(`adoptPopupWebView`)가 컨테이너 bounds로 주고,
    // drain의 `.create`가 다음 tick에 정확한 pane rect로 보정한다(그 전 ~1프레임은 placeholder frame).
    init(adoptingConfiguration configuration: WKWebViewConfiguration, surfaceId: UInt64, frame frameRect: NSRect) {
        self.surfaceId = surfaceId
        self.panelKind = 1
        self.filePanelKind = 0
        self.filePanelLanguage = nil // 팝업 browser는 신뢰 shell/text가 아니다.
        self.filePanelShellKind = nil
        self.pinnedFileHTMLURL = nil
        self.bridgeWorld = nil // browser=브리지 없음(신뢰 전용)
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserResultTransferRegistry.boundedPageBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page))
        // §9.5.9 console: 팝업(untrusted browser 패널)도 console override를 받아야 `browser.console` pull이 동작한다
        // (adopt된 config는 부모의 user script를 안 물려받아 위 bootstrap처럼 재주입 필요 — 안 넣으면 팝업 콘솔이 항상 빔).
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserControl.consoleCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page))
        self.webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: configuration)
        super.init(frame: frameRect)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self // 팝업이 또 팝업을 열 수 있게(중첩 창)
        addSubview(webView)
        installNavObservers()
    }

    // Phase 7e-1a/7f-1: browser(panelKind==1) 패널의 WKWebView nav 상태 block-based KVO 등록(url·canGoBack·canGoForward
    // → 프로퍼티 저장 + navStateDirty). config init·adopt init이 공유한다(DRY). 신뢰 패널은 주소창이 없어 no-op.
    // changeHandler는 @Sendable이라 main-actor 상태를 직접 못 건드리므로 assumeIsolated로 동기 진입한다(이 세 프로퍼티는
    // WebKit 네비게이션=메인 스레드에서만 바뀜). 토큰은 navObservers 프로퍼티가 deinit까지 붙잡아 관측을 유지한다.
    // **13차 리뷰 [7](PLAUSIBLE) 판단**: assumeIsolated는 off-main 전달 시 trap한다는 지적. 유지 결정 — ⑴ WKWebView url/
    // canGoBack/canGoForward는 WebKit UI-side(메인 스레드) 네비게이션에서만 갱신되고(off-main 전달 사례 미관측), ⑵
    // assumeIsolated는 이 코드베이스의 **확립된 패턴**(NSColorSampler·애니메이션·기타 KVO 콜백 등 여러 곳 동일)이라 여기만
    // dispatch(main)로 바꾸면 이질적, ⑶ 근거 없는 방어 코드 지양([[no-defensive-code-without-consult]]). 실제 off-main
    // 크래시가 관측되면 그때 dispatch로 전환한다(그 시점엔 증거 있음).
    private func installNavObservers() {
        guard panelKind == 1, filePanelKind == 0 else { return }
        navObservers = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.navUrl = wv.url?.absoluteString
                    self.navStateDirty = true
                    // 5f-0b-3c: URL 변경 → browser.navigated 이벤트를 그 surface 구독자에게 push(구독 없으면 Zig서 조기 반환).
                    // KVO=메인 스레드라 registry(leaf-mutex) 접근 안전. url 바이트는 이 호출 중만 유효(Zig가 프레임에 복사).
                    let urlBytes = Array((wv.url?.absoluteString ?? "").utf8)
                    urlBytes.withUnsafeBufferPointer { p in
                        maru_macos_control_push_browser_navigated(self.surfaceId, p.baseAddress, p.count)
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.navCanGoBack = wv.canGoBack
                    self?.navStateDirty = true
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.navCanGoForward = wv.canGoForward
                    self?.navStateDirty = true
                }
            },
            // 5f-3a: isLoading 변경 → browser.loadState 이벤트(구독자에 push, navigated와 동형 coalescible KVO). 무구독=무비용.
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    maru_macos_control_push_browser_load_state(self.surfaceId, wv.isLoading ? 1 : 0)
                }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MaruWebPanelView는 coder 초기화 미지원") }

    // 4d 마우스: 모달 닫힘=웹뷰가 클릭 받아 포커스(super.hitTest), 모달 열림=nil로 아래 터미널에 통과(모달 dismiss·
    // 요소 클릭이 Zig로). **이 웹 패널이 속한 창의 모달 상태**로 판정한다(활성 창 anyOverlayOpen 아님 — 배경 창을
    // 클릭하면 다른 창의 모달 상태를 반영하던 오라우팅 방지, code-review [9]). (웹 패널 존재 자체가 MARU_WEB_PANEL
    // 훅 뒤라 평시 무영향.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        if controller?.isOverlayOpenForWebPanel(self) == true { return nil }
        // divider grab 분리(4e review 0 후속): seam 가장자리(Zig seam_edges) margin 안 클릭/hover는 nil로 통과시켜, 아래
        // 터미널 뷰가 event를 받아 dividerAtPoint로 드래그·resize 커서를 처리하게 한다 — WKWebView는 native라 자기 frame
        // 클릭을 삼키므로, 이걸로 시각 gap은 작게(Zig seam inset) 두고 grab 폭만 넓힌다. AppKit hitTest 입력은
        // **superview 좌표**이므로 같은 좌표계의 frame과 비교한다. bounds와 섞으면 origin이 0이 아닌 도크에서 본문 전체가
        // seam으로 오판돼 클릭·휠이 아래 Metal view로 샌다. top은 탭 바라 seam_edges에 없다.
        if WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: point,
            frameInSuperview: frame,
            seamEdges: seamEdges,
            leftBand: dividerGrabLeftPt,
            rightBand: dividerGrabRightPt,
            bottomBand: dividerGrabBottomPt
        ) {
            return nil
        }
        // firstResponder identity가 이미 이 WKWebView인 재클릭도 새 사용자 intent다. passive tick reconcile로는
        // 구분할 수 없으므로 실제 primary-down hit-test에서만 Zig direct-focus를 통지한다. seam/overlay는 위에서
        // nil로 빠져 divider drag나 modal click이 dock focus를 훔치지 않는다.
        //
        // **결과가 우리 것일 때만 통지한다.** `hitTest`는 이벤트 수신이 아니라 **조회** 함수라, AppKit이 목적지를
        // 찾는 동안 형제 뷰를 순회하며 이 패널의 frame **밖** 좌표로도, 숨긴 패널에도 호출한다. 좌표를 보지 않고
        // 통지하면 탭 바나 사이드바 클릭이 web surface를 활성화해 **터미널 탭을 눌러도 브라우저로 되튄다**(사용자
        // 제보 → MARU_DEBUG 로그에서 클릭마다 `activate_surface id=4`로 확정). `super.hitTest`가 nil이면 이 패널도
        // 그 자손도 그 클릭을 받지 않는다는 뜻이므로 통지하지 않는다 — drop-zone 드래그 중 `isHidden` 패널도 같다.
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown {
            controller?.webPanelPrimaryDown(self)
        }
        return hit
    }

    private func pinnedFileURLMatches(_ candidate: URL) -> Bool {
        guard let pinned = pinnedFileHTMLURL, candidate.isFileURL else { return false }
        return candidate.standardizedFileURL.path == pinned.standardizedFileURL.path
    }

    // FP5 HTML 스모크: 페이지 script 실행, 부모 read scope 안 asset 성공, scope 밖 asset 차단을 읽은 뒤 로컬 링크와
    // programmatic about:blank 이동을 차례로 시도한다. delegate가 둘 다 취소해 URL이 pinned 파일에 남는지 확인한다.
    private func captureFileHTMLProbe() {
        let script = """
        (() => {
          const inside = document.getElementById('inside');
          const outside = document.getElementById('outside');
          const link = document.getElementById('local-nav');
          const result = JSON.stringify({
            script: document.documentElement.dataset.fp5Script || 'false',
            inside: String(Boolean(inside && inside.complete && inside.naturalWidth > 0)),
            outside: String(Boolean(outside && outside.complete && outside.naturalWidth > 0))
          });
          link?.click();
          return result;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let raw = value as? String, let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            self.fileHTMLScriptProbe = obj["script"]
            self.fileHTMLAssetProbe = obj["inside"]
            self.fileHTMLOutsideAssetProbe = obj["outside"]
            // local link 취소와 page timer를 경합시키면 간헐적으로 timer가 아직 안 돈 채 smoke summary가 false를
            // 관측한다. 첫 navigation 취소 뒤 native가 두 번째 script 시도를 명시적으로 순서화하고, 같은 evaluation의
            // 반환값으로 "시도함"을 확정한 다음 별도 지연에서 URL pin을 확인한다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                let aboutAttempt = """
                (() => {
                  window.__fp5AboutAttempt = true;
                  window.location.href = 'about:blank';
                  return String(window.__fp5AboutAttempt === true);
                })()
                """
                self.webView.evaluateJavaScript(aboutAttempt) { [weak self] value, _ in
                    guard let self else { return }
                    self.fileHTMLAboutAttemptProbe = value as? String
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, let current = self.webView.url else { return }
                        self.fileHTMLPinnedProbe = String(self.pinnedFileURLMatches(current))
                    }
                }
            }
        }
    }

    // 웹 포커스 중에는 Zig typed WebKeyRoute만 소비한다. app action은 전용 direct dispatch, editable Markdown 기본과
    // pass-through는 WebKit/메뉴, unbind·terminal macro와 unknown raw는 consume이다. Swift가 별도 키 목록을 갖지 않으며
    // direct dispatch는 범용 terminal 전처리와 PTY write를 우회한다. 웹 포커스가 아니면 false라 터미널 IME/keyDown은 불변.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Phase 7e-4(+후속): browser nav 단축키(⌘←=back·⌘→=forward·⌘R=reload)는 **이 패널이 활성 pane의 browser 탭일
        // 때** 처리한다 — WKWebView 키보드 포커스(isWebPanelFocused) 유무와 무관하게. 브라우저 탭을 활성화해도 webView에
        // 자동 포커스를 안 주므로 isWebPanelFocused만 보면 "탭 열어 보기만 하면 ⌘R 안 됨" 버그가 난다(제보). 배경 탭
        // 패널은 hidden이라 애초에 performKeyEquivalent 순회에서 빠지고, split의 비활성 pane 브라우저는 activeWebSurfaceId
        // 가 걸러낸다(활성 pane이 아니면 0/다른 id라 매칭 실패). R은 레이아웃 무관하게 keyCode 15로(⌘←/→와 동일 방식 —
        // charactersIgnoringModifiers 의존 제거). 실행은 dispatchBrowserNav → Zig setBrowserNavAction(클릭 ①b와 공유하는
        // 활성 판정) → take_web_nav_action drain → BrowserControl. 소비(true)해 WKWebView 기본 ⌘R/히스토리 동작 차단.
        // **정확히 Cmd만**(Shift/Option/Control 동반 아님)일 때로 게이트한다 — `.contains(.command)`은 ⌘⇧R(Reset
        // Terminal keyEquivalent, keyCode 15)·⌘⌥←/→까지 back/forward/reload로 삼켜 그 조합들을 가로챈다(리뷰 [8]). Cmd+C/V
        // 등 다른 exact-cmd 게이트(chordMods)와 같은 intersection 규약.
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           panelKind == 1, filePanelKind == 0, surfaceId != 0,
           controller?.focusedFilePanelSurfaceId() == 0,
           controller?.activeWebSurfaceId() == surfaceId {
            switch event.keyCode {
            case 123: controller?.dispatchBrowserNav(surfaceId, 0); return true // ← back
            case 124: controller?.dispatchBrowserNav(surfaceId, 1); return true // → forward
            case 15: controller?.dispatchBrowserNav(surfaceId, 2); return true // R reload
            default: break
            }
        }
        // 그 외 key equivalent는 웹 포커스일 때 Zig typed route가 단독 판정한다. 사용자 app rebind/unbind와
        // Markdown 편집 기본키의 우선순위를 Swift keyCode 목록으로 복제하지 않는다.
        guard controller?.isWebPanelFocused(self) == true else { return false }
        switch controller?.webPanelKeyRoute(self, event) ?? MARU_WEB_KEY_ROUTE_PASS_THROUGH {
        case MARU_WEB_KEY_ROUTE_PASS_THROUGH, MARU_WEB_KEY_ROUTE_WEB_EDITOR:
            return false
        case MARU_WEB_KEY_ROUTE_APP_ACTION:
            controller?.dispatchWebPanelAppAction(self, event)
            return true
        case MARU_WEB_KEY_ROUTE_CONSUME_UNBOUND:
            return true
        default: // future/invalid raw route: fail closed
            return true
        }
    }
}

// Phase 5c-2c: 웹 패널 top-level 네비게이션 정책(신뢰·비신뢰 대칭 — 리뷰11 [2]). CSP는 sub-resource·form만 막고
// **top-level 네비게이션은 안 막으므로**, 여기서 스킴으로 pin한다:
//   - **신뢰(markdown)**: maru-app:// 안으로만 top-level 네비 허용, 외부(http/https 등)는 cancel → 신뢰 UI가 코드
//     버그·손상 asset으로 외부 URL로 튀어 신뢰 표면에 임의 원격 콘텐츠가 뜨는 것 차단(origin pin, exact-origin은 5b).
//   - **비신뢰(browser)**: maru-app:// 네비를 cancel(핸들러 미등록이 1차, 이 cancel이 2차 — 신뢰 origin 위장 방지),
//     그 외는 허용(외부 http(s) URL 로딩·링크 감지 정책은 5d에서 확장).
extension MaruWebPanelView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration &+= 1
        if filePanelKind == 1 {
            // 새 document에서는 이전 page Promise와 retry callback을 무효화한다. pending intent 자체는 보존해
            // didFinish exact-origin에서 한 번만 재개한다.
            var mermaidSnapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&mermaidSnapshot)
            let cancelledReplies = controller?.cancelMermaidReplies(
                surfaceId: surfaceId,
                error: "file panel navigated"
            ) ?? 0
            if controller?.isFileEditingSmokeMode == true {
                fileEditingSmokeProbe.observeMermaidNavigationCancellation(
                    inFlight: mermaidSnapshot.in_flight != 0,
                    cancelledReplies: cancelledReplies
                )
            }
            fileDirtySyncEpoch &+= 1
            fileDirtySyncInFlight = false
            if controller?.isFileEditingSmokeMode == true { fileEditingSmokeProbe.invalidateNavigation() }
        }
        if panelKind == 1, filePanelKind == 0 {
            controller?.browserDidStartNavigation(surfaceId)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased()
        // FP5 로컬 HTML은 최초 pinned 파일과 같은 URL의 top-level 로드/새로고침만 허용한다. iframe·이미지·CSS 등
        // subframe/subresource는 loadFileURL read scope 안에서 WebKit이 판정한다. 문서의 http(s) 링크는 시스템
        // 브라우저로 넘기고, 다른 file:·about:·data:·javascript: top-level 이동은 취소한다. 이 분기는 공통
        // about:blank placeholder 허용보다 먼저여야 로컬 HTML script/meta refresh가 핀을 우회하지 못한다.
        if filePanelKind == 2 {
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            if let url, pinnedFileURLMatches(url) {
                decisionHandler(.allow)
                return
            }
            // 로컬 script/redirect가 앱 실행 직후 외부 브라우저를 강제로 띄우지 못하게 실제 링크 활성화만 넘긴다.
            if let url, (scheme == "http" || scheme == "https"), navigationAction.navigationType == .linkActivated {
                let forceSystem = navigationAction.modifierFlags.contains([.command, .shift])
                _ = controller?.openFilePanelLink(surfaceId, url: url.absoluteString, forceSystem: forceSystem)
            }
            decisionHandler(.cancel)
            return
        }
        // about:blank/nil = loadHTMLString 인라인 폴백(신뢰·비신뢰 공통, 실제 네비 아님) → 항상 허용(리뷰12 [1]). 이게
        // 없으면 신뢰 패널(trusted)의 흰 placeholder 폴백(about:blank)이 `trusted != isMaruApp`으로 cancel돼 다크로 떠
        // 다크모드 blank 회귀가 재발한다(비대칭 정정). 로컬 HTML은 위 전용 분기에서 top-level about을 막는다.
        if scheme == nil || scheme == "about" {
            decisionHandler(.allow)
            return
        }
        let trusted = (panelKind == 0)
        guard trusted else {
            decisionHandler(scheme == MaruAppSchemeHandler.scheme ? .cancel : .allow)
            return
        }
        // 신뢰 main frame은 app shell만, subframe은 render host만 허용한다. 둘 다 명시 port가 없어야 한다.
        // targetFrame=nil(새 browsing context)은 main-frame 취급으로 shell 외 전부 막는다.
        guard let url else { decisionHandler(.cancel); return }
        let isSubframe = navigationAction.targetFrame?.isMainFrame == false
        let role: UInt32 = isSubframe ? 1 : 0
        guard MaruAppSchemeHandler.originAllowed(url, role: role) else {
            decisionHandler(.cancel)
            return
        }
        if isSubframe {
            // renderer의 최초 iframe src는 app shell이 시작한 render.html navigation만 허용한다. renderer
            // page가 link/redirect/location으로 시작한 후속 navigation은 source origin이 render이므로 모두 취소한다.
            let source = navigationAction.sourceFrame.securityOrigin
            let initialFromShell = source.protocol.lowercased() == MaruAppSchemeHandler.scheme
                && source.host.lowercased() == "app"
                && source.port == 0
            decisionHandler(initialFromShell ? .allow : .cancel)
            return
        }
        if filePanelKind == 1 {
            // Markdown main document id는 host만 발급한다. 이미 준비된 document의 reload/programmatic same-URL
            // navigation도 fresh id URL로 치환해 서로 다른 WebContent document가 epoch를 공유하지 않게 한다.
            guard trustedDocumentId(in: url) == trustedDocumentId else {
                decisionHandler(.cancel)
                return
            }
            if documentPageReady {
                documentPageReady = false
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self] in _ = self?.loadFreshTrustedDocument() }
                return
            }
        }
        decisionHandler(.allow)
    }

    // 5b/5d E2E probe(스모크 전용): 로드 완료 후 패널 종류별로 자동 단언 데이터를 저장한다. **분기는 panelKind 기준**
    // (리뷰12 [3] — bridgeWorld nil-ness가 아니라): 신뢰(0)=브리지 격리 probe, 비신뢰(1)=5d BrowserControl fixture.
    // asset root 부재로 신뢰 패널에 bridgeWorld가 없어도 5d fixture로 오구동하지 않는다. 정상 런은 안 돈다(isSmokeMode 게이트).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // §2.3: 새로 로드된 파일 패널을 현재 ⌘+/− 줌 배율로 즉시 착지시킨다(줌 상태에서 새 파일을 열어도 바로 반영).
        // kind 1=프리뷰 iframe 이벤트/편집기 pt, kind 2=HTML/PDF pageZoom. 이후 배율 변화는 drainFilePanelZoom이 밀어준다.
        if filePanelKind != 0, let session = controller?.bridgeSession(for: surfaceId) {
            applyFilePanelZoom(maru_macos_app_session_file_panel_zoom_milli(session))
        }
        if filePanelKind == 1 {
            documentPageReady = true
            applySyntaxThemeStyle()
            applyFilePanelMode(requestedFileMode)
            resumeFileDirtySyncIfPending()
        }
        guard controller?.isSmokeMode == true else { return }
        // Navigation cancellation probe는 정상 viewer/edit/save 증거를 얻은 뒤 마지막에 의도적으로 editable
        // document를 reload한다. 새 document는 recovery latch로 read를 거부하는 것이 계약이므로 두 번째 probe가
        // 첫 성공값을 덮지 않게 한다. didStart 취소·Zig revoke·helper deadline은 그대로 실제 경로를 지난다.
        if filePanelKind == 1, fileEditingSmokeProbe.mermaidNavigationCancelled != "pending" { return }
        if filePanelKind == 1, fileDirtySyncRecoveryProbe == nil {
            // didFinish 직후 file read/CM6 hydration과 경쟁시켜, 일반 tab-leave sync가 page hook 준비 전에도
            // completion형 retry를 거쳐 clean ACK로 회복하는 실제 WKWebView 경로를 고정한다.
            fileDirtySyncSmokeArmed = true
            fileDirtySyncRecoveryProbe = "pending"
            requestFileDirtySync()
        }
        if filePanelKind == 2 {
            guard fileHTMLProbeStarted == false else { return }
            fileHTMLProbeStarted = true
            captureFileHTMLProbe()
        } else if panelKind == 0 {
            // 5b 신뢰 브리지 격리 probe. 브리지가 등록됐을 때만(asset root 부재면 bridgeWorld=nil=브리지 미등록 → probe 스킵).
            guard let world = bridgeWorld else { return }
            webView.evaluateJavaScript("typeof window.maru", in: nil, in: world) { [weak self] result in
                if case .success(let v) = result { self?.bridgeIsolatedProbe = v as? String }
            }
            webView.evaluateJavaScript("typeof window.maru", in: nil, in: .page) { [weak self] result in
                if case .success(let v) = result { self?.bridgePageWorldProbe = v as? String }
            }
            // round-trip: isolated world에서 maru.hello()를 await(callAsyncJavaScript는 Promise를 기다림)해 server_version을
            // 얻는다 → 핸들러 도달 + origin 통과 + Zig dispatchBridge 응답까지 자동 증명("0.1.0" 기대).
            webView.callAsyncJavaScript("return (await window.maru.hello()).result.server_version", arguments: [:], in: nil, in: world) { [weak self] result in
                if case .success(let v) = result { self?.bridgeHelloProbe = v as? String }
            }
            captureFileViewerProbe(attemptsRemaining: 16)
        } else {
            // 5d BrowserControl fixture E2E(browser/untrusted 패널). 2단계: ① 초기 흰 HTML 로드 완료 → data: URL navigate,
            // ② 그 data: 로드 완료 → getUrl/executeScript로 navigate·읽기·스크립트 실행을 자동 증명(무-네트워크).
            if browserFixtureStage == 0 {
                browserFixtureStage = 1
                _ = BrowserControl.navigate(webView, url: Self.browserFixtureURL)
            } else if browserFixtureStage == 1 {
                browserFixtureStage = 2
                browserFixtureUrl = BrowserControl.currentUrl(webView) // navigate한 data: URL이어야 함(getUrl 검증).
                BrowserControl.executeScript(webView, "document.getElementById('t').textContent") { [weak self] result in
                    if case .success(let v) = result { self?.browserFixtureScript = v as? String } // "maru5d" 기대.
                    // 22차 [0]: getCookies는 현재 문서 host로 필터하므로, host 있는 문서를 로드해 쿠키 필터를 실증한다.
                    // data:는 opaque origin(host nil)이라, loadHTMLString(baseURL: https://maru.test/)로 host 문서를 만든다
                    // (무-네트워크 — baseURL은 origin만 지정, fetch 안 함). executeScript 완료 후라 data: 문서와 레이스 없음.
                    webView.loadHTMLString("<h1>maru cookie fixture</h1>", baseURL: URL(string: "https://maru.test/"))
                }
            } else if browserFixtureStage == 2 {
                browserFixtureStage = 3
                // 5f-4c/22차 [0] getCookies fixture: maru.test 문서 로드 완료 → 쿠키 2개 seed(maru.test=현재 host,
                // other.test=타 host) → getCookies가 현재 문서 host(maru.test)로 **필터**해 되읽는다. 결과에 sid(maru.test)는
                // 포함, other(other.test)는 **제외**되어야 host 필터=교차-surface 격리를 실증한다(실 getAllCookies+필터+serialize).
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let g = DispatchGroup()
                for (dom, nm, val) in [("maru.test", "sid", "5f4c"), ("other.test", "other", "leak")] {
                    if let cookie = HTTPCookie(properties: [.domain: dom, .path: "/", .name: nm, .value: val, .secure: "TRUE"]) {
                        g.enter()
                        store.setCookie(cookie) { g.leave() }
                    }
                }
                g.notify(queue: .main) { [weak self] in
                    BrowserControl.getCookies(webView) { json in self?.browserFixtureCookies = json } // sid 포함·other 제외 기대.
                }
            }
        }
    }

    // 5f-3c: WebContent 프로세스 크래시 → browser.crashed 이벤트를 구독자에 push(추가 payload 없음). 실 크래시는
    // 결정적 트리거 불가라 헤드리스/손 테스트 대상(§9.5.5). 메인 스레드(델리게이트 콜백).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if filePanelKind == 1 {
            documentPageReady = false
            if controller?.filePanelDidTerminateWebContent(surfaceId, panel: self) == true {
                _ = loadFreshTrustedDocument()
            }
            return
        }
        guard panelKind == 1, filePanelKind == 0 else { return }
        maru_macos_control_push_browser_crashed(surfaceId)
        controller?.browserDidTerminateWebContent(surfaceId)
    }
}

// Phase 7f-1: 새 창/팝업(target=_blank·window.open) adopt.
extension MaruWebPanelView: WKUIDelegate {
    // 페이지가 새 창을 요청하면 WebKit이 이 메서드를 **동기 호출**하고 새 WKWebView 반환을 기대한다(같은 뷰 내 top-level
    // 이동은 decidePolicyForNavigationAction 담당 — 이건 별개 경로). browser(비신뢰) 패널만 팝업을 연다(uiDelegate를
    // browser에만 걸지만, adopt된 중첩 팝업도 panelKind==1이라 방어적으로 재확인). 넘어온 configuration으로 새 webview를
    // 만들어야 window.opener·named window·postMessage 링크가 성립하므로, controller가 그 config로 adopt 패널을 만들어
    // webview를 돌려준다. nil이면 WebKit이 새 창 생성을 취소한다. 스킴·user-gesture 정책 게이트는 7f-2.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard panelKind == 1, filePanelKind == 0 else { return nil } // 신뢰/로컬 HTML 패널은 창 생성 차단
        // Phase 7f-2: 팝업 대상 스킴 정책(정책 단일 출처=Zig app_scheme.popupTargetAllowed) — about/http/https/빈만
        // 허용, javascript:/file:/data:/blob:/maru-app: 등 위험 스킴 팝업은 차단(nil이면 WebKit이 창 생성 취소).
        // 빈 target(window.open() 빈 팝업)은 허용이라 ABI 호출을 건너뛴다(빈 배열 baseAddress=nil 회피).
        let target = navigationAction.request.url?.absoluteString ?? ""
        if !target.isEmpty {
            let allowed = Array(target.utf8).withUnsafeBufferPointer { p in
                maru_macos_app_popup_target_allowed(p.baseAddress, p.count) == 1
            }
            guard allowed else { return nil }
        }
        return controller?.adoptPopupWebView(configuration: configuration, openerSurfaceId: surfaceId)
    }

    // 5f-3b: JS 다이얼로그(alert/confirm/prompt) → browser.dialog 이벤트 push + **안전 기본값으로 즉시 dismiss**(비-블로킹).
    // uiDelegate 미구현 시 WebKit이 다이얼로그를 조용히 억제(완료 즉시 호출)하던 현 동작을 유지하며 **관측만 추가**한다 —
    // 즉 UX 회귀 없음(alert=무시·confirm=false·prompt=nil). 실 다이얼로그 표시/에이전트 응답(browser.dialog.respond)은 후속.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        pushDialogEvent(kind: 0, message: message)
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        pushDialogEvent(kind: 1, message: message)
        completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        pushDialogEvent(kind: 2, message: prompt)
        completionHandler(nil)
    }
    private func pushDialogEvent(kind: UInt8, message: String) {
        let bytes = Array(message.utf8)
        bytes.withUnsafeBufferPointer { p in
            maru_macos_control_push_browser_dialog(surfaceId, kind, p.baseAddress, p.count)
        }
    }
}

// MARK: - Phase 4b-2: contentView 컨테이너 뷰 (3겹 합성 호스트)
//
// window.contentView를 단일 터미널 뷰에서 **컨테이너**로 재편한다. 자식: 터미널 뷰(맨 아래, layer isOpaque는
// window.opacity 따라감) + 모달 오버레이 뷰(맨 위, 투명). **4c WKWebView(insertWebPanel)가 그 사이**에 본문 rect로 낀다.
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
        addSubview(overlayView)  // 맨 위(모달 오버레이 — WKWebView는 이 둘 사이, insertWebPanel 4c)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MaruTerminalContainerView는 coder 초기화 미지원") }

    // Phase 4e-3: 웹 패널 래퍼를 터미널(맨 아래)과 오버레이(맨 위) **사이**에 삽입한다 — z-order: 터미널 < 웹뷰들 <
    // 오버레이(모달이 웹뷰 위). NSView는 UIKit식 insertSubview(at:)가 없어 positioned:.below relativeTo:로 오버레이
    // 바로 아래(=터미널 위)에 넣는다. web Term마다 하나씩 이 사이 밴드에 쌓인다 — subviews == [terminalView, ...웹뷰들, overlayView].
    func insertWebPanel(_ v: NSView) {
        addSubview(v, positioned: .below, relativeTo: overlayView)
    }
}

// 한 터미널 세션의 per-session 상태 — 창/PTY(appSession)/Metal 렌더러 + 렌더 캐시 메트릭을 묶는다.
// 컨트롤러가 메인 창을 `primary`로 들고, quick terminal(후속)이 두 번째 인스턴스가 된다. 세션별 로직은
// 컨트롤러 메서드가 이 surface의 상태를 읽고 쓰며 수행한다(상태만 여기 — 두 세션이 같은 메서드를 공유).
private let maruFileTreeFSEventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
    guard let info else { return }
    let watcher = Unmanaged<MaruFileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
    let array = unsafeBitCast(eventPaths, to: NSArray.self)
    let paths = array.compactMap { $0 as? String }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
    let ids = Array(UnsafeBufferPointer(start: eventIds, count: count))
    DispatchQueue.main.async { watcher.handle(paths, flags: flags, eventIds: ids) }
}

/// FP7 native FSEvents adapter. root set 변경 때만 stream을 재구성하고 200ms latency로 file-level 이벤트를
/// main queue에 coalesce한다. 디렉터리 열거는 하지 않고 Zig에 변경 path만 알린다.
@MainActor
final class MaruFileTreeWatcher {
    private weak var surface: TerminalSurface?
    private var roots: Set<String> = []
    private var stream: FSEventStreamRef?
    private var lastEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    private var pathBuffer = [UInt8](repeating: 0, count: 4096)

    init(surface: TerminalSurface) { self.surface = surface }

    func drain(_ session: OpaquePointer) {
        var changed = false
        if maru_macos_app_session_take_file_tree_watch_reset(session) != 0 {
            roots.removeAll(keepingCapacity: true)
            changed = true
        }
        while true {
            let len = pathBuffer.withUnsafeMutableBufferPointer {
                maru_macos_app_session_take_file_tree_watch_root(session, $0.baseAddress, $0.count)
            }
            guard len > 0 else { break }
            guard len <= pathBuffer.count else { break } // ABI required-length 응답; oversized one-shot은 소비하지 않는다.
            let root = String(decoding: pathBuffer[0 ..< len], as: UTF8.self)
            if roots.insert(root).inserted { changed = true }
        }
        if changed {
            // 새 root의 최초 scan은 Zig recordOpened가 이미 예약했다. 기존 root의 stop/start 사이 event는 아래
            // lastEventID 재생이 회수하므로 synthetic content-change를 보내 dirty buffer를 오탐하지 않는다.
            rebuild()
        }
    }

    func handle(
        _ paths: [String],
        flags: [FSEventStreamEventFlags],
        eventIds: [FSEventStreamEventId]
    ) {
        guard let session = surface?.appSession else { return }
        if let newest = eventIds.max() {
            lastEventID = lastEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                ? newest
                : max(lastEventID, newest)
        }
        let coarseMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagEventIdsWrapped |
                kFSEventStreamEventFlagRootChanged
        )
        let coarse = flags.contains { ($0 & coarseMask) != 0 }
        if flags.contains(where: { ($0 & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0 }) {
            lastEventID = FSEventsGetCurrentEventId()
        }
        let changedPaths = coarse ? Array(roots) : paths
        for path in changedPaths {
            let bytes = Array(path.utf8)
            bytes.withUnsafeBufferPointer {
                maru_macos_app_session_file_tree_changed(session, $0.baseAddress, $0.count)
            }
        }
        if flags.contains(where: { ($0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 }) {
            rebuild()
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots.removeAll(keepingCapacity: false)
    }

    private func rebuild() {
        if lastEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            // 최초 stream도 stop/start 경계 전에 global journal checkpoint를 잡아 SinceNow의 유실 창을 없앤다.
            lastEventID = FSEventsGetCurrentEventId()
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            maruFileTreeFSEventCallback,
            &context,
            Array(roots).sorted() as CFArray,
            lastEventID,
            0.2,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }
}

@MainActor
final class TerminalSurface {
    var window: NSWindow?
    var appSession: OpaquePointer?
    var metalRenderer: OpaquePointer?
    // construction/restore가 성공해 app-global checkpoint inventory에 들어간 normal Window인가.
    var workspaceCheckpointPublished = false

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
    var protectedTickFaultLatch = FilePanelProtectedTickFaultLatch()

    // Metal terminal view = 창 컨테이너(contentView)의 터미널 자식 뷰(Phase 4b-2). window가 살아 있는 동안 유효.
    var view: MaruMetalTerminalView? {
        return (window?.contentView as? MaruTerminalContainerView)?.terminalView
    }

    // 모달 오버레이 자식 뷰(컨테이너 맨 위, 투명). 렌더러 draw가 터미널 layer와 함께 이 layer에 그린다.
    var overlayView: MaruMetalOverlayView? {
        return (window?.contentView as? MaruTerminalContainerView)?.overlayView
    }

    // Phase 4e-3: 이 창(세션)의 web Term별 WKWebView 래퍼 dict(surface_id → view). 한 pane에 여러 web Term이
    // 가로 탭으로 섞일 수 있고 split이면 여러 pane이 동시에 web을 보일 수 있어(§6), **web Term마다 하나**를 든다.
    // Zig batch 전이(surface_id)로 create/destroy/reframe/hide/show를 이 dict에 적용한다(컨테이너 z-order 중간 삽입).
    // 컨테이너 서브뷰로도 살아 있지만, 빠른 조회·전이 매칭을 위해 세션별로 강참조를 든다(창이 닫히면 함께 해제).
    var webPanels: [UInt64: MaruWebPanelView] = [:]

    // FP6 도크는 workspace pane 활성축과 직교한다. 클릭한 도크 WKWebView를 별도 입력 소유자로 기억해 pane D1이
    // 즉시 포커스를 회수하지 않게 하고, 모달 override 뒤에는 같은 도크로 복원한다.
    var focusedFilePanelSurfaceId: UInt64?
    var filePanelFocusOverridden = false
    // surface-less dock drop의 create batch가 같은 tick에 아직 publish되지 않았거나 transition marshal이
    // 재시도될 때 mode/focus one-shot을 잃지 않는다. entry가 사라지면 Zig mode lookup으로 stale 폐기한다.
    var pendingFilePanelModeAction: (surfaceId: UInt64, mode: Int32)?
    // Mode refresh와 분리된 typed dock-focus retry. 아직 publish되지 않은 B의 focus intent가
    // 무관한 A mode refresh에 덮이지 않도록 서로 다른 retained slot을 쓴다.
    var pendingDockFocusActionSurfaceId: UInt64?
    // Trash adapter ownership is session/surface-local. An active-window change must not redirect an
    // asynchronous recycle completion to a different Zig AppSession.
    var fileTreeTrashInFlight = false
    lazy var fileTreeWatcher = MaruFileTreeWatcher(surface: self)
}

// quick terminal용 떠 있는 패널. borderless NSWindow/NSPanel은 기본적으로 key가 될 수 없어 타이핑을 못
// 받는다 — quick terminal은 입력을 받아야 하므로 canBecomeKey/Main을 강제한다.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private func selfTestRelease<T: AnyObject>(_ value: inout T?) { value = nil }

/// `.app`으로 실행돼 저장소 상대 경로(`zig-out/...`)에 쓸 수 없을 때 종료 요약이 대신 남는 자리.
/// macOS 관례대로 `~/Library/Logs` 아래에 두어 Console.app이나 Finder로 바로 열 수 있게 한다.
private func maruFallbackSummaryFileURL() -> URL? {
    guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
        return nil
    }
    return logs.appendingPathComponent("Logs/maru/app.summary.txt")
}

/// `body`가 실제로 걸린 시간을 ns로 돌려준다. 종료 경로 계측 전용의 얇은 래퍼로, 각 단계마다 시작/끝 시각을
/// 손으로 적는 대신 측정 대상을 블록으로 묶어 "무엇을 쟀는지"가 코드에서 바로 보이게 한다. 모노토닉 시계라
/// (`uptimeNanoseconds`) 시스템 시간 변경에 흔들리지 않는다.
private func measureElapsedNs(_ body: () -> Void) -> UInt64 {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let end = DispatchTime.now().uptimeNanoseconds
    // 모노토닉 시계라 end < start는 나오지 않아야 하지만, 그 가정이 깨지면 뺄셈이 wrap해 UInt64 최대치에 가까운
    // 값이 되고 요약에 `18446744073.7ms` 같은 헛수가 실린다. 진단용 숫자가 헛것을 말하느니 0이 낫다.
    return end >= start ? end - start : 0
}

private func maruWorkspaceFileURL() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    return support.appendingPathComponent("maru/workspace.v1")
}

/// AppKit process/Dock 등록보다 먼저 canonical workspace sibling lease를 획득한다. parent/leaf 생성은
/// fresh profile에서 lease 자체를 만들기 위한 유일한 startup loser filesystem effect다.
private func acquireAppInstanceWriterLeaseBeforeAppKit() -> UInt32 {
    guard let workspace = maruWorkspaceFileURL() else {
        return UInt32(MARU_APP_INSTANCE_LEASE_INVALID_PATH)
    }
    let parent = workspace.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        return UInt32(MARU_APP_INSTANCE_LEASE_IO_FAILURE)
    }
    let lock = workspace.appendingPathExtension("lock")
    let bytes = Array(lock.path.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        maru_macos_app_instance_lease_acquire(buffer.baseAddress, buffer.count)
    }
}

/// OS가 고른 언어를 Zig에 넘긴다.
///
/// **Swift는 읽어서 전달만 하고 해석하지 않는다**(docs/i18n.md §5.1). `ko-KR`을 한국어로 읽는 규칙은
/// 중립 층(`src/i18n.zig`)이 소유한다 — 여기서 판정하면 Windows 호스트가 같은 규칙을 다시 쓰게 되고
/// 둘이 조용히 갈린다. `preferredLanguages`는 사용자가 시스템 설정에서 **정렬한** 목록이라 첫 항목이
/// 곧 "이 사람이 읽고 싶은 언어"다(`Locale.current`는 지역 서식이라 언어와 다를 수 있다).
///
/// 세션을 만들기 전마다 부른다 — 값이 같으면 무해하고, 시스템 언어가 바뀐 뒤 연 창은 새 값을 받는다.
private func publishUiLocale() {
    guard let tag = Locale.preferredLanguages.first else { return } // 못 읽으면 무동작 → auto는 영어로 떨어진다
    let bytes = Array(tag.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        maru_macos_app_set_ui_locale(buffer.baseAddress, buffer.count)
    }
}

private func appInstanceLeaseFailureReason(_ status: UInt32) -> (code: Int32, reason: String) {
    switch status {
    case UInt32(MARU_APP_INSTANCE_LEASE_HELD):
        return (2, "second instance unsupported: workspace writer lease held")
    case UInt32(MARU_APP_INSTANCE_LEASE_UNSAFE):
        return (1, "unsafe workspace writer lock")
    case UInt32(MARU_APP_INSTANCE_LEASE_IO_FAILURE):
        return (1, "workspace writer lease I/O failure")
    default:
        return (1, "invalid workspace writer lock path")
    }
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
    // 이 controller는 pre-AppKit lease 획득 성공 뒤에만 생성된다. startup loser는 이 상태에 도달하지 않는다.
    private let appInstanceLeaseStatus = UInt32(MARU_APP_INSTANCE_LEASE_ACQUIRED)
    // "Browser Grants" 서브메뉴(§9.2 per-grant revoke UX) — 열릴 때마다 menuNeedsUpdate가 Zig grant store를 조회해
    // 항목을 재생성한다(활성 grant 1개=1항목 + Revoke All). delegate=self·이 참조로 menuNeedsUpdate에서 식별한다.
    private let browserGrantsMenu = NSMenu(title: "Browser Grants")
    // 일반 터미널 창들의 per-session 상태(단일 출처). 현재는 launch에 1개만 만들지만(동작 불변), New Window가
    // 여기에 append한다 — W1은 `primary` 단일 필드를 컬렉션으로 일반화하는 소유권 seam이다(split PR2a의
    // "Tab→tree seam, 단일 leaf, 동작 불변"과 같은 결). 창별 라우팅(surfaceForView/activeSurface)은 이
    // 컬렉션에서 view/key 창으로 고른다. quick terminal이 별도(특수) surface다. 아래 계산 프로퍼티들은
    // 기존 세션별 메서드가 코드 변경 없이 "활성 surface"의 상태를 읽고 쓰게 하는 forwarder다(상태만 분리).
    private var windows: [TerminalSurface] = []
    // restore 중 어느 saved Window라도 apply하지 못했으면 이번 실행의 default/fallback 창으로 마지막 완전
    // checkpoint를 덮지 않는다. 사용자가 새로 저장할 명시 UX가 생기기 전에는 데이터 보존을 우선한다.
    private var workspaceRestoreIncomplete = false
    private let workspaceCheckpointWriter = DispatchQueue(label: "dev.maru.workspace-checkpoint", qos: .utility)
    private var workspaceCheckpointArmed = false
    private var workspaceCheckpointFailureNotice: UInt32 = UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE)
    private var workspaceCheckpointActiveWindow: ObjectIdentifier?
    private var workspaceCheckpointFrames: [ObjectIdentifier: NSRect] = [:]
    private var workspaceCheckpointMoveTasks: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var workspaceFinalQuitPending = false
    private weak var workspaceFinalQuitSurface: TerminalSurface?
    private var workspaceFinalQuitWasDeferred = false
    private var workspaceFinalQuitAllowsFailure = false
    private var workspaceFinalQuitApproved = false
    // FP10c1: 앱 전역 Zig mermaid_queue action을 실행할 유일한 native adapter. Mermaid fence admission과
    // frame-tick pump는 FP10c2의 pending-work/perf gate 전까지 배선하지 않는다.
    private let mermaidRenderCoordinator = MermaidRenderCoordinator()
    // 제품 display tick과 native perf smoke가 공유하는 유일한 has-work/pump/drain 순서 경계다.
    // 이 타입에는 FS/WebView/process/pipe/wait capability가 없어서 hot path의 허용 책임이 좁게 고정된다.
    private let mermaidProductTick = MermaidProductTickAdapter()
    private let mermaidAcceptedDrainer = MermaidAcceptedResultDrainer()
    private static let maxMermaidPendingReplies = Int(MARU_MERMAID_MAX_PENDING_JOBS) + 1
    private lazy var mermaidReplyDelivery = MermaidReplyDeliveryAdapter(
        maxPending: Self.maxMermaidPendingReplies
    )
    // 알림 클릭 라우팅 토큰 채번기(makeTerminalSurface가 단조 증가로 부여 — 창마다 유일). 0은 미설정 sentinel이라 1부터.
    private var nextSurfaceToken: UInt64 = 1
    private struct StableNotificationRoute: Equatable, Sendable {
        let hostIdHi: UInt64
        let hostIdLo: UInt64
        let runtimeIdHi: UInt64
        let runtimeIdLo: UInt64
        let eventId: UInt64
    }
    // Notification Center can deliver the launch response before AppSession/recovery publication.
    // Keep only typed scalars, deduplicate the OS callback key, and never let persisted userInfo grow
    // an unbounded launch queue. MainActor owns both this queue and all AppSession mutation.
    private static let maxPendingStableNotificationRoutes = 8
    private var pendingStableNotificationRoutes: [StableNotificationRoute] = []
    private var stableNotificationRoutingReady = false
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
    // 주소창 navigate(⏎) URL을 Zig에서 받는 재사용 버퍼 — drainWebSurfaceTransition이 매 tick 부르는데 navigate는 Enter
    // 시에만이라, tick마다 4KB 새로 할당·zero-fill하지 않고 이 버퍼를 재사용한다(리뷰 [9]). Zig가 navLen만 쓰고 반환 길이로
    // 슬라이스하므로 zero-fill 불필요. addr_nav_url_cap(4096, app_scheme)과 정합.
    private var webNavigateUrlBuf = [UInt8](repeating: 0, count: 4096)
    // 페이지 찾기 질의 버퍼(Zig web_find_query_cap=512와 짝). 넘치면 Zig가 아예 제출하지 않는다.
    private var webFindQueryBuf = [UInt8](repeating: 0, count: 512)
    private var fileTreePathBuf = [UInt8](repeating: 0, count: Int(MARU_FILE_TREE_PATH_CAPACITY))
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
    private var sessionHostR2aCheckpointPreflightCount: Int64 = 0
    private var sessionHostRecoverySmokeStage: UInt32 = 0
    private var sessionHostRecoverySmokeRowPresent = false
    private var sessionHostRecoverySmokeClickDispatched = false
    private var sessionHostRecoverySmokeRemotePublished = false
    private var sessionHostRecoverySmokeMarkerPresent = false
    private var sessionHostRecoverySmokeBeforeCapture = false
    private var sessionHostRecoverySmokeAfterCapture = false
    private var sessionHostRecoverySmokeFailure = ""
    private var sessionHostRecoverySmokePrepareOutcome: UInt32 = 0
    private var sessionHostRecoverySmokeKeepAliveEnabled = false
    private var sessionHostRecoverySmokeDiscoveredCandidates: UInt32 = 0
    private var sessionHostRecoverySmokeReadyAdapters: UInt32 = 0
    private var sessionHostRecoverySmokeInventoryRuntimes: UInt32 = 0
    private var sessionHostRecoverySmokeConfiguredKeepAlive = false
    private var sessionHostRecoverySmokeLiveSessionCount: UInt32 = 0
    private var sessionHostRecoverySmokeTargetActivationDispatched = false
    private var sessionHostRecoverySmokeTargetRows: UInt32 = 0
    private var sessionHostRecoverySmokeTabs: UInt32 = 0
    private var sessionHostRecoverySmokeSurfaceInitialized = false
    private var sessionHostRecoverySmokeActiveRemoteObserved = false
    private var sessionHostRecoverySmokeMarkerObserved = false
    private var sessionHostRecoverySmokeCaptureRetries: UInt32 = 0
    private var sessionHostRecoverySmokeLaunchNs = DispatchTime.now().uptimeNanoseconds
    private var sessionHostRecoverySmokeRowNs: UInt64 = 0
    private var sessionHostRecoverySmokeClickNs: UInt64 = 0
    private var sessionHostRecoverySmokeRemoteVisibleNs: UInt64 = 0
    private var sessionHostRecoverySmokeSummaryNs: UInt64 = 0
    private var sessionHostInputSmokeStage: UInt32 = 0
    private var sessionHostInputSmokeHistoricalCount: UInt32 = 0
    private var sessionHostInputSmokeImeCount: UInt32 = 0
    private var sessionHostInputSmokeClipboardCount: UInt32 = 0
    private var sessionHostInputSmokeMarkedCallbacks: UInt32 = 0
    private var sessionHostInputSmokeInsertCallbacks: UInt32 = 0
    private var sessionHostInputSmokeHistoricalClipboardPreserved = false
    private var sessionHostInputSmokeViewSourceRestored = false
    private var sessionHostInputSmokeFailure = ""
    private var sessionHostInputSmokeRetries: UInt32 = 0
    private var sessionHostInputSmokeKeyIndex: Int = 0
    private var sessionHostInputSmokeOriginalSource: String?
    private var sessionHostInputSmokeOriginalGlobalSource: String?
    private var sessionHostInputSmokeSourceRecordURL: URL?
    private var sessionHostInputSmokeGlobalSourceSelected = false
    private var sessionHostInputSmokeGlobalSourceRestored = false
    private var sessionHostInputSmokePostEventAccess = false
    private var sessionHostInputSmokeSourceRecordCleared = false
    private var sessionHostInputSmokeAppActive = false
    private var sessionHostInputSmokeFirstResponder = false
    private var sessionHostInputSmokeFrontmostPID: pid_t = 0
    private var sessionHostInputSmokeOriginalPasteboard: [[NSPasteboard.PasteboardType: Data]]?
    private var sessionHostInputSmokePasteboardPrepared = false
    private var sessionHostInputSmokePasteboardRestored = false
    private var launchSummaryWritten = false
    private var isSessionHostRecoverySmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6C_APPKIT_SMOKE"] == "1"
    }
    private var isSessionHostR2aCheckpointSmokeMode: Bool {
        ProcessInfo.processInfo.environment["MARU_SESSION_HOST_R2A_CHECKPOINT_SMOKE"] == "maru-test-only-v1"
    }
    private var isSessionHostR1TombstoneSmokeMode: Bool {
        ProcessInfo.processInfo.environment["MARU_SESSION_HOST_R1_TOMBSTONE_SMOKE"] == "maru-test-only-v1"
    }
    private var isSessionHostC4QuitCancelSmokeMode: Bool {
        ProcessInfo.processInfo.environment["MARU_SESSION_HOST_C4_QUIT_CANCEL_SMOKE"] == "maru-test-only-v1"
    }
    private var isSessionHostInputContinuitySmokeMode: Bool {
        isSessionHostRecoverySmokeMode &&
            ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6D_INPUT_CONTINUITY_SMOKE"] == "1"
    }
    private var isSessionHostRecoveryBaselineMode: Bool {
        isSessionHostRecoverySmokeMode &&
            ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6E_RECOVERY_BASELINE_ARTIFACT"] != nil
    }
    private var sessionHostRecoveryBaselineIteration: UInt32? {
        guard isSessionHostRecoveryBaselineMode,
              let raw = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION"]
        else { return nil }
        return UInt32(raw)
    }
    /// 종료 경로 단계별 비용. 종료는 메인 스레드를 동기로 붙잡으므로 어느 단계가 그 시간을 쓰는지 남겨야
    /// 추측 없이 고칠 수 있다. 값은 종료 요약의 `quit_*` 필드로 나간다(docs/macos-app-host-boundary.md).
    private var terminationTiming = TerminationTiming()
    /// `applicationWillTerminate` 진입 시각. 요약을 쓰는 시점에 total을 계산해, 단계로 나누지 않은 잔여
    /// 시간까지 total과 단계 합의 차이로 드러나게 한다.
    private var terminationStartNs: UInt64 = 0
    /// 종료 중 창을 숨기기 **전**의 key 창. `orderOut`은 창을 화면에서 내리면서 `isKeyWindow`를 false로 만드는데,
    /// workspace의 `active-window` 마커(M3e — 다음 실행이 그 창을 다시 focus)는 그 값으로 정해진다. 미리 붙잡아
    /// 두지 않으면 종료할 때마다 활성 창 정보가 사라져 복원이 항상 첫 창을 고른다.
    private weak var terminationKeyWindow: NSWindow?
    /// AS4-c uses its own explicit env gate so the ordinary PTY/file-panel smoke never gains
    /// fixture worker controls or synthetic archive input.
    private var agentSessionArchiveSmokeDriver: AgentSessionArchiveSmokeDriver?
    // These counters are only a host-side receipt for the fixture's normal one-shot consumer.
    // They never cross the Zig ABI and deliberately contain no source path or provider payload.
    private var agentSessionArchiveSmokeRevealAllowedCount: UInt32 = 0
    private var agentSessionArchiveSmokeRevealRejectedCount: UInt32 = 0
    private var agentSessionArchiveSmokeStaleRevealCount: UInt32 = 0
    private var agentSessionArchiveSmokeClaudeModelPresent: UInt32 = 0
    private var agentSessionArchiveSmokeTerminalInvariant = false
    private var agentSessionArchiveSmokeScrollDispatched = false
    private var agentSessionArchiveSmokeAnchorBeforePresent = false
    private var agentSessionArchiveSmokeAnchorAfterPresent = false
    private var agentSessionArchiveSmokeAnchorRawTopPreserved = false
    private var agentSessionArchiveSmokeAnchorSnapshotReordered = false
    private var agentSessionArchiveSmokeAnchorNewGenerationPublished = false
    private var agentSessionArchiveSmokeCaptureList = false
    private var agentSessionArchiveSmokeCaptureLoading = false
    private var agentSessionArchiveSmokeCaptureReady = false
    private var agentSessionArchiveSmokeCaptureStale = false
    private var agentSessionArchiveSmokeCaptureScrollAnchorBefore = false
    private var agentSessionArchiveSmokeCaptureScrollAnchorAfter = false
    private var agentSessionArchiveSmokeCaptureListArtifact = ""
    private var agentSessionArchiveSmokeCaptureLoadingArtifact = ""
    private var agentSessionArchiveSmokeCaptureReadyArtifact = ""
    private var agentSessionArchiveSmokeCaptureStaleArtifact = ""
    private var agentSessionArchiveSmokeCaptureScrollAnchorBeforeArtifact = ""
    private var agentSessionArchiveSmokeCaptureScrollAnchorAfterArtifact = ""
    private var isAgentSessionArchiveSmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE"] == "1"
    }

    /// CIM2 divider E2E. 이 모드는 실제 `NSEvent`를 `MaruMetalTerminalView`에 흘려 제품 pointer
    /// 경로를 그대로 탄다 — Zig 도메인 메서드를 직접 부르면 검증 대상인 capture 라우팅을 건너뛴다.
    private var isDividerSmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_DIVIDER_SMOKE"] == "1"
    }
    private enum DividerSmokeStage { case idle, split, drag, done }
    private var dividerSmokeStage: DividerSmokeStage = .idle
    private var dividerSmokeRatioBefore: UInt32 = 0
    private var dividerSmokeRatioAfter: UInt32 = 0
    private var dividerSmokeMoveEvents: UInt64 = 0
    private var dividerSmokeResizeApplications: UInt64 = 0
    private var dividerSmokeCaptureDuringDrag = false
    private var dividerSmokeCaptureAfterUp = true
    private var dividerSmokeBandPresent = false
    private var dividerSmokeTicks = 0
    private var dividerSmokeTermCount: UInt32 = 0
    private var dividerSmokeProbeStatusOK = false
    private var dividerSmokeSplitRetries = 0
    // CIM2d: 웹 패널이 divider에 맞닿았을 때 seam 밴드 클릭이 아래 터미널 뷰로 통과하는지.
    private var webDividerSmokeStage = 0
    private var webDividerSmokeRetries = 0
    private var webDividerSeamEdges: UInt32 = 0
    private var webDividerPanelPresent = false
    private var webDividerHitTestPassedThrough = false
    private var webDividerHitTestOverPanel = false
    private var webDividerCaptureAfterDown = false
    private var webDividerPadding = ""
    private var webDividerCovered: UInt32 = 0
    // CIM3d: file tree scrollbar thumb을 실제 NSEvent로 끌어 tick coalescing을 제품 경로에서 본다.
    private var scrollSmokeStage = 0
    private var scrollSmokeOffsetBefore: UInt64 = 0
    private var scrollSmokeOffsetAfter: UInt64 = 0
    private var scrollSmokeMoveEvents: UInt64 = 0
    private var scrollSmokeApplications: UInt64 = 0
    private var scrollSmokeCaptureDuringDrag = false
    private var scrollSmokeCaptureAfterUp = true
    private var scrollSmokeThumbPresent = false
    private var scrollSmokeOpenRetries = 0
    private var webDividerBands = ""
    private var webDividerFrame = ""
    // CIM4b: 탭을 실제 NSEvent로 끌어 provisional live reorder를 제품 경로에서 본다. headless fixture는
    // "model이 안 바뀐다"까지만 증명하고, 끄는 동안 **보이는 순서가 실제로 움직였는지**는 여기서만 본다.
    private var tabDragSmokeStage = 0
    private var tabDragSmokeSpawnRetries = 0
    private var tabDragSmokeTabCount: UInt32 = 0
    private var tabDragSmokeBarPresent = false
    private var tabDragSmokeCaptureDuringDrag = false
    private var tabDragSmokeCaptureAfterUp = true
    private var tabDragSmokePreviewDivergedDuringDrag = false
    private var tabDragSmokeModelFirstBefore: UInt64 = 0
    private var tabDragSmokeModelFirstDuringDrag: UInt64 = 0
    private var tabDragSmokeModelFirstAfterCommit: UInt64 = 0
    private var tabDragSmokeVisibleFirstDuringDrag: UInt64 = 0
    private var tabDragSmokeEscapeModelFirst: UInt64 = 0
    private var tabDragSmokeEscapeVisibleFirst: UInt64 = 0
    private var tabDragSmokeEscapeCaptureCleared = false
    private var tabDragSmokeCaptures: [String] = []

    // 5b: 웹 패널이 격리 E2E probe(evaluateJavaScript)를 스모크에서만 돌리게 노출(정상 런은 probe 안 함 — 오버헤드 0).
    var isSmokeMode: Bool { smokeMode }
    // 실제 Markdown bytes를 변경하는 probe는 일반 smoke duration과 분리한 명시 opt-in이다. 공식 build target만
    // 복사 fixture와 함께 켜며, 사용자가 임의 MARU_FILE_PANEL 경로로 smoke를 띄워도 문서를 수정하지 않는다.
    var isFileEditingSmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_FILE_PANEL_EDIT_SMOKE"] == "1"
    }
    // 5e-2b-2 테스트 전용(MARU_TEST_BROWSER_CAP): 소켓 browser.* E2E를 딱 1회 kick하는 one-shot 가드 + 결과 저장.
    // 배경 스레드(소켓 클라이언트)가 채우고 메인(writeSummary)이 읽으므로 lock으로 보호한다(nonisolated(unsafe) — lock이
    // 안전 보장). 기본 "pending"(kick 전/미완). didKick은 메인(tick)만 만져 main-actor 유지.
    private var didKickBrowserCtlSmoke = false
    private let browserCtlLock = NSLock()
    private nonisolated(unsafe) var browserCtlNavigateOkStore = "pending" // 소켓 browser.navigate 응답에 "ok":true 포함 여부.
    private nonisolated(unsafe) var browserCtlGetUrlStore = "pending" // 소켓 browser.getUrl 응답의 url(navigate한 data: URL 기대).
    private nonisolated(unsafe) var browserCtlEventsStore = "pending" // 5f-3: 구독 후 navigate+alert가 유발한 browser.* 이벤트 종류 집합(navigated/loadState/dialog).
    private nonisolated(unsafe) var browserCtlWaitSelectorStore = "pending"
    private nonisolated(unsafe) var browserCtlWaitLoadStore = "pending"
    private nonisolated(unsafe) var browserCtlWaitTimeoutStore = "pending"
    private nonisolated(unsafe) var browserCtlWaitInvalidSelectorStore = "pending"
    private nonisolated(unsafe) var browserCtlWaitElapsedStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedStructuredStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedAwaitArgsStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedStrictCspStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedNavigationStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedTamperStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedByteBoundaryStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedTooLargeStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedExecutionErrorStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedSerializationErrorStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedDepthStore = "pending"
    private nonisolated(unsafe) var browserCtlBoundedStreamStore = "pending"
    private nonisolated(unsafe) var browserCtlConsoleCaptureStore = "pending" // §9.5.9: console.log/error 발화 후 browser.console pull이 [log]/[error] 회수.
    private nonisolated(unsafe) var browserCtlConsoleClearStore = "pending" // §9.5.9: clear=true pull 후 재-pull이 빈 배열(버퍼 비움 검증).
    // callback이 navigation에서 영원히 오지 않을 수 있으므로 surface별 running executeScript를 Swift에서도 추적한다.
    // didStartProvisionalNavigation이 선제 terminal을 보내고, 늦은 callback은 set 부재로 폐기해 중복 완료를 막는다.
    private var runningBrowserScripts: [UInt64: Set<UInt64>] = [:]
    /// executeScript 외 WebKit async callback도 surface close 뒤 성공/비밀 결과를 되살리지 않게 surface 수명에 묶는다.
    /// WebContent realm op만 close/crash를 backend terminal로 보며, data-store op은 NetworkProcess의 실제 callback까지 슬롯을
    /// 유지한다. 둘 다 Zig client terminal 뒤 결과는 폐기한다.
    private enum BrowserCallbackLifetime {
        case webContentRealm // crash/close가 backend terminal: snapshot/evaluateJavaScript
        case dataStore // NetworkProcess/data-store op: 실제 callback 전에는 backend terminal 아님
    }
    private var runningBrowserCallbacks: [UInt64: [UInt64: BrowserCallbackLifetime]] = [:]
    // ReleaseSafe bounded smoke에서만 채우는 pump 기여 시간. 제품 실행은 배열 append조차 하지 않는다.
    private var browserResultPumpSamplesMs: [Double] = []
    // 1e-confirm-1c-2(MARU_TEST_GRANT_DECISION): **무-cap** browser.navigate가 pane confirm-grant 흐름(needs_grant→env approve→grant→op)으로 성공하는지("true"/진단).
    private var didKickGrantSmoke = false
    private nonisolated(unsafe) var browserGrantNavigateOkStore = "pending"
    // Cmd+Q 종료 확인 모달이 떠 결정을 기다리는 중(applicationShouldTerminate가 .terminateLater 반환). 다음 tick
    // FrameSummary.quit_decision으로 결정이 오면 NSApp.reply로 종료를 진행/취소하고 false로 되돌린다. 중복 Cmd+Q 무시용.
    private var quitConfirmPending = false
    // 마지막 창 닫기·세션 종료·confirm 수락 경로가 **모든 일반 창+quick의 파일 보호를 재확인한 뒤** 세우는
    // 앱-전역 preflight 토큰. applicationShouldTerminate가 같은 종료 요청에 확인을 다시 띄우지 않게 한다.
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
        let leaseStatus = acquireAppInstanceWriterLeaseBeforeAppKit()
        guard leaseStatus == UInt32(MARU_APP_INSTANCE_LEASE_ACQUIRED) else {
            let failure = appInstanceLeaseFailureReason(leaseStatus)
            fputs("maru: \(failure.reason)\n", stderr)
            Darwin.exit(failure.code)
        }
        let configBootstrapStatus = maru_macos_session_config_bootstrap()
        guard configBootstrapStatus == UInt32(MARU_SESSION_CONFIG_BOOTSTRAP_READY) else {
            fputs("maru: session config bootstrap failed (status=\(configBootstrapStatus))\n", stderr)
            Darwin.exit(1)
        }
        if ProcessInfo.processInfo.environment["MARU_SESSION_CONFIG_BOOTSTRAP_DUPLICATE_SMOKE"] == "1" {
            let duplicateStatus = maru_macos_session_config_bootstrap()
            guard duplicateStatus == UInt32(MARU_SESSION_CONFIG_BOOTSTRAP_ALREADY_INITIALIZED) else {
                fputs("maru: duplicate session config bootstrap was not rejected (status=\(duplicateStatus))\n", stderr)
                Darwin.exit(1)
            }
            fputs("maru: duplicate session config bootstrap rejected\n", stderr)
        }
        if ProcessInfo.processInfo.environment["MARU_APP_INSTANCE_LEASE_SMOKE_READY"] == "1" {
            fputs("maru: session config bootstrap ready\n", stderr)
            fputs("maru: app instance writer lease acquired\n", stderr)
        }
        // 제품 스모크가 config scalar bootstrap까지 끝냈지만 AppKit/Window/AppSession/restore/runtime은 아직
        // 시작하지 않은 exact post-bootstrap 지점에서 winner를 붙잡는다. SIGKILL만 lease를 끝낸다.
        if ProcessInfo.processInfo.environment["MARU_APP_INSTANCE_LEASE_SMOKE_HOLD"] == "1" {
            while true { _ = Darwin.sleep(60) }
        }

        let app = NSApplication.shared
        let delegate = MaruAppHostController()

        // NSApplication의 delegate 수명은 제품 앱 전체 수명과 같아야 한다. 지역 변수만
        // 두면 future refactor에서 delegate가 일찍 해제될 수 있으므로 명시적으로 잡아 둔다.
        retainedDelegate = delegate
        app.delegate = delegate
        // Install before NSApplication.run so a notification-launched process cannot lose its first
        // response while applicationDidFinishLaunching is still creating recovery authority.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = delegate
        }
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

        cleanupPasteImages() // 이전 세션이 남긴 임시 paste 이미지 청소(누적 방지 — 정상/비정상 종료 모두 커버).
        mermaidRenderCoordinator.onRenderError = { [weak self] capability in
            self?.failMermaidReply(capability: capability, error: "mermaid render failed")
        }
        mermaidReplyDelivery.bindFallback(to: mermaidRenderCoordinator)

        // 라이브 프리뷰 admission은 dock visibility/focus transition에서 반복 호출된다. 평상시 후보 수를
        // 시작 시 한 번 확보해 해당 전환 경로가 배열 storage를 매번 만들지 않게 한다.

        // 메인 창의 per-session 상태를 담을 surface를 가장 먼저 만든다 — 아래 window/appSession/렌더러
        // 대입이 전부 이 첫 창(primary = windows.first)으로 forwarding되므로(forwarder setter), 창이 없으면
        // 그 대입이 사라진다. New Window(W2)는 같은 컬렉션에 surface를 추가한다.
        self.windows.append(makeTerminalSurface())

        let window = makePlaceholderWindow()
        self.window = window
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        focusTerminalView(window)
        NSApp.activate(ignoringOtherApps: true)

        // app session의 첫 tick(startAppSession 안)이 바로 그릴 수 있도록 renderer를 먼저 만든다.
        setupMetalRenderer()

        // workspace가 parse 가능한 실제 창을 하나 이상 가지면 첫 AppSession을 deferred surface 모드로 만든다.
        // Zig parser를 session=NULL preflight로 호출해 Swift가 wire를 따로 해석하지 않으면서 throwaway 셸 spawn을 막는다.
        let restoreDisabled = ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] != nil
        let recoverySmoke = isSessionHostRecoverySmokeMode
        let r2aCheckpointSmoke = isSessionHostR2aCheckpointSmokeMode
        let r1TombstoneSmoke = isSessionHostR1TombstoneSmokeMode
        let preparedWorkspace = ((smokeMode && !recoverySmoke && !r2aCheckpointSmoke) || restoreDisabled) ? nil : loadWorkspaceText()
        let preparedWorkspaceWindowCount = preparedWorkspace.map { text -> Int64 in
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBufferPointer { buf in
                maru_macos_app_session_workspace_window_count(nil, buf.baseAddress, buf.count)
            }
        }
        if r2aCheckpointSmoke {
            sessionHostR2aCheckpointPreflightCount = preparedWorkspaceWindowCount ?? 0
        }
        // CR6a-2: 일반 launch는 저장 Workspace 유무와 무관하게 terminal publication을 잠깐 defer한다. secure
        // discovery/inventory가 먼저 끝난 뒤 저장 창을 apply하거나 아래에서 default surface를 명시적으로 finish해,
        // launch가 방금 만든 runtime을 자기 orphan으로 관측하지 않게 한다. smoke는 recovery 제품 범위 밖이다.
        let deferInitialSurface = !smokeMode || recoverySmoke || r2aCheckpointSmoke

        if !startAppSession(smokeMode: smokeMode, deferInitialSurface: deferInitialSurface) {
            writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }
        if let session = primary?.appSession {
            maru_macos_app_session_set_primary_window(session, 1)
            if !smokeMode || recoverySmoke {
                if let text = preparedWorkspace {
                    let bytes = Array(text.utf8)
                    _ = bytes.withUnsafeBufferPointer { buf in
                        maru_macos_app_session_prepare_recovered_sessions(session, buf.baseAddress, buf.count, 1)
                    }
                } else {
                    sessionHostRecoverySmokePrepareOutcome = maru_macos_app_session_prepare_recovered_sessions(session, nil, 0, 0)
                }
            }
            // parse 가능한 저장 Window가 없으면 recovery cut 뒤에만 기본 shell을 만든다. 실제 저장 Window가
            // 있으면 applyWorkspaceWindow가 deferred surface를 완성한다. R2a smoke는 discovery를 우회하고
            // null-session preflight 뒤의 제품 fallback만 허용한다.
            if (!smokeMode || recoverySmoke || r2aCheckpointSmoke), (preparedWorkspaceWindowCount ?? 0) <= 0 {
                guard maru_macos_app_session_finish_deferred_initial_surface(session) == Self.statusOK else {
                    exitCode = 1
                    writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
                    NSApp.terminate(nil)
                    return
                }
            }
        }

        // 저장된 workspace를 복원한다(R4b) — 첫 블록을 primary에 적용하고 나머지 블록마다 새 창. 저장 없음·복원
        // off·smoke·빈 블록이면 무동작(방금 만든 기본 단일 창 유지). startAppSession이 세션을 세운 '뒤'에.
        if !restoreWorkspace(
            preparedWorkspace,
            preparedWindowCount: preparedWorkspaceWindowCount,
            deferredInitialSurface: deferInitialSurface
        ) {
            exitCode = 1
            writeSummary(visibleUI: true, abiReady: true, smokeDurationMs: smokeDuration)
            NSApp.terminate(nil)
            return
        }

        // All restored Window bindings and the app-global recovered projection now exist. A response
        // received before this point is safe to consume exactly once through the same product path.
        stableNotificationRoutingReady = true
        drainPendingStableNotificationRoutes()

        // 표준 메뉴바를 세운다(커맨드 카탈로그에서 액션 항목·단축키를 읽어). smoke에서도 빌드해 구성 경로를
        // CI가 구동한다(메뉴는 OS-global 부수효과가 없어 hotkey 등록과 달리 게이트 불요).
        buildMainMenu()

        // 첫 tick(startAppSession 안)이 cell 메트릭을 캐시했으니, 창 크기에 맞춰 cols/rows를
        // 한 번 맞춘다(80×24 기본에서 실제 창 grid로). 일반 smoke는 자체 scripted resize를 쓰지만,
        // archive fixture는 첫 published pointer rect가 실제 view backing 좌표여야 하므로 같은 제품 resize를
        // 명시적으로 한 번 통과시킨다.
        if !smokeMode || isAgentSessionArchiveSmokeMode {
            resizeAppSessionFromWindow()
        }
        if !smokeMode {
            // 전역(OS) 단축키를 OS에 등록한다(앱이 비활성이어도 동작). smoke는 자동 종료라 등록하지 않는다.
            registerGlobalHotkeys()
        }

        // The first frame can already expose the cold dock launcher.  Install the fixture driver
        // before starting the loop so it cannot miss that frame and wait for a later redraw.
        if isAgentSessionArchiveSmokeMode {
            guard let scenario = AgentSessionArchiveSmokeDriver.Scenario() else {
                exitCode = 1
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            agentSessionArchiveSmokeDriver = AgentSessionArchiveSmokeDriver(scenario: scenario)
        }
        // R1's product fixture deliberately requests one real background capture. That makes the
        // generated checkpoint, rather than the input fixture, the authority for the second launch.
        // The exact test-only token prevents an arbitrary environment value from changing product
        // persistence behavior.
        let checkpointInitialDirty = (preparedWorkspaceWindowCount ?? 0) <= 0 || r1TombstoneSmoke
        armWorkspaceCheckpoint(initialDirty: checkpointInitialDirty)
        if isSessionHostC4QuitCancelSmokeMode {
            // The harness makes the existing checkpoint user-immutable. This seam only requests the
            // normal AppKit termination transaction; it cannot select a failure or an output path.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bypassQuitConfirm = true
                NSApp.terminate(nil)
            }
        }
        if r2aCheckpointSmoke {
            guard let markerPath = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_R2A_CHECKPOINT_MARKER"],
                  sessionHostR2aCheckpointPreflightCount == -1,
                  workspaceRestoreIncomplete,
                  workspaceCheckpointArmed
            else {
                exitCode = 1
                NSApp.terminate(nil)
                return
            }
            let marker = "preflight_count=-1\nrestore_incomplete=true\ncheckpoint_armed=true\n"
            do {
                try Data(marker.utf8).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            } catch {
                exitCode = 1
                NSApp.terminate(nil)
                return
            }
        }
        startFrameLoopTicks()

        // 세션 컨트롤 플레인 라이브 서버(A2b): 앱 전역 소켓 + accept 스레드를 띄운다. 이 뒤로 tickAppSession이 매
        // tick drain하고(살아있는 세션 목록), applicationWillTerminate가 stop한다. bind 실패는 비치명(컨트롤 플레인만
        // 꺼짐 — maru sessions list가 "인스턴스 없음"으로 접힌다). 소켓·스레드·collector·dispatch·auth는 전부 Zig.
        controlServerStarted = (maru_macos_control_server_start() == Self.statusOK)

        if smokeMode && !isAgentSessionArchiveSmokeMode && !recoverySmoke && ProcessInfo.processInfo.environment["MARU_APP_INSTANCE_LEASE_SMOKE_HOLD"] != "1" {
            if filePanelHookEnabled {
                // FP11f cold helper/WKWebView Mermaid와 iframe→read→render→edit→save가 끝나기 전에 controlled
                // PTY가 `a\n`을 받아 종료하지 않게 입력을 늦춘다. 일반 smoke는 기존 즉시 입력 동작을 유지한다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) { [weak self] in
                    self?.sendSmokeDevEvents()
                }
            } else {
                sendSmokeDevEvents()
            }
        }
        if let smokeDuration {
            smokeTimer = Timer.scheduledTimer(withTimeInterval: Double(smokeDuration) / 1000.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.expireSmokeTimer() }
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
        if bypassQuitConfirm {
            // 확인 생략 토큰은 checkpoint 생략 토큰이 아니다. 마지막 창/SessionEnded처럼 모달을 이미 통과했거나
            // 필요 없는 종료도 C4 final commit을 거친다. final success 뒤 재진입만 terminateNow다.
            if workspaceFinalQuitApproved || !workspaceCheckpointArmed || windows.isEmpty { return .terminateNow }
            quitConfirmPending = true
            beginFinalWorkspaceCheckpoint(surface: activeSurface, deferredAppKitQuit: true)
            return .terminateLater
        }
        if quitConfirmPending { return .terminateLater } // 이미 모달이 떠 결정 대기 중 — 중복 요청 무시
        // frame-loop tick이 아직 안 도는 런치 초기 에러(tickTimer==nil)거나 세션이 없으면, 모달을 띄워도 결정이
        // 돌아올 수 없으므로 즉시 종료한다. 일반 창이 0개여도 hidden quick은 살아 있을 수 있으므로 activeSurface를
        // 요구하기 전에 전 세션 보호를 찾고, clean quick도 일반 종료 confirm 대상으로 삼는다.
        guard tickTimer != nil else { return .terminateNow }
        guard let target = protectedFilePanelSurface() ?? activeSurface ?? quick else { return .terminateNow }
        guard let session = target.appSession else { return .terminateNow }
        quitConfirmPending = true
        maru_macos_app_session_request_app_quit(session) // dirty 파일이면 즉시 취소+notice, 아니면 일반 종료 confirm
        if target.window?.isKeyWindow != true { target.window?.makeKeyAndOrderFront(nil) }
        // ⌘Q는 시스템 메뉴 keyEquivalent 경로라 maru keyDown/performKeyEquivalent를 안 거친다 — 브라우저 web 패널이
        // firstResponder를 쥔 채면 첫 Enter가 아직 WKWebView로 샐 수 있으므로, 모달을 연 즉시 터미널로 포커스를 전이한다
        // (다음 renderTick의 self-heal reconcile까지 안 기다림 — dispatchWebPanelAppAction의 동기 reconcile과 같은 규율).
        withSurface(target) { reconcileWebFocus() }
        return .terminateLater
    }

    /// 앱 전체 종료는 활성 창 하나가 아니라 모든 일반 창과 quick session을 없앤다. Zig가 소유하는 파일 상태 getter로
    /// 전체를 순회해 첫 보호 세션을 돌려준다. 요청 시점뿐 아니라 confirm 확정 직전에도 다시 호출한다.
    private func protectedFilePanelSurface() -> TerminalSurface? {
        var surfaces = windows
        if let quick { surfaces.append(quick) }
        let protected = surfaces.map { surface in
            guard let session = surface.appSession else { return false }
            return maru_macos_app_session_has_protected_file_panels(session) != 0
        }
        guard let index = FilePanelTerminationPolicy.firstProtectedIndex(protected) else { return nil }
        return surfaces[index]
    }

    /// 이미 일반 창/session close gate를 통과한 경로라도 앱 전체를 종료한다면 quick을 포함한 전 세션 파일 보호를
    /// 다시 확인해야 한다. 보호 세션을 앞으로 가져오고 Zig의 공용 notice+cancel gate를 실행한다.
    @discardableResult
    private func blockGlobalTerminationForProtectedFilePanels() -> Bool {
        guard let protected = protectedFilePanelSurface(), let session = protected.appSession else { return false }
        protected.window?.makeKeyAndOrderFront(nil)
        maru_macos_app_session_request_app_quit(session)
        withSurface(protected) { reconcileWebFocus() }
        return true
    }

    /// renderTick fault/SessionEnded를 이유로 native surface를 파괴하기 직전의 마지막 fail-closed 게이트. 정상적인
    /// SessionEnded는 Zig가 이미 막지만, ABI/tick fault는 그 latch 바깥에서 올 수 있으므로 host도 Zig-owned predicate를
    /// 읽는다. 보호 중이면 세션과 마지막 정상 frame을 유지하고 공용 notice를 요청한다. 다음 tick을 재시도해 일시 fault가
    /// 풀리면 notice까지 렌더하고, 계속 실패해도 미저장 버퍼를 teardown하지 않는다.
    private func holdProtectedSurfaceAfterTickFailure(
        _ surface: TerminalSurface,
        persistentTickFault: Bool = false
    ) -> Bool {
        guard let session = surface.appSession else {
            _ = surface.protectedTickFaultLatch.record(tickSucceeded: true, currentProtected: false)
            return false
        }
        let protected = maru_macos_app_session_has_protected_file_panels(session) != 0
        guard FilePanelTerminationPolicy.shouldHoldCurrentSurface(
            tickSucceeded: false,
            currentProtected: protected
        ) else {
            _ = surface.protectedTickFaultLatch.record(tickSucceeded: true, currentProtected: false)
            return false
        }
        if persistentTickFault,
           !surface.protectedTickFaultLatch.record(tickSucceeded: false, currentProtected: true) { return true }
        surface.window?.makeKeyAndOrderFront(nil)
        maru_macos_app_session_request_app_quit(session)
        withSurface(surface) { reconcileWebFocus() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        terminationStartNs = DispatchTime.now().uptimeNanoseconds
        _ = restoreSessionHostInputSmokeInputSource()
        restoreSessionHostInputSmokePasteboard()
        tickTimer?.invalidate()
        tickTimer = nil
        smokeTimer?.invalidate()
        smokeTimer = nil
        // 아래 정리는 전부 메인 스레드에서 동기로 돌아 그동안 이벤트 루프가 멈춘다. 창이 그대로 떠 있으면 그 멈춤이
        // 사용자에게 모래시계(응답 없음)로 보이므로, **정리 전에** 창을 화면에서 내려 종료가 즉시 끝난 것처럼 보이게
        // 한다(iTerm2·Terminal.app도 같은 순서). `orderOut`은 창을 화면에서 뺄 뿐 객체를 해제하지 않으므로 뒤따르는
        // teardown·요약이 읽는 window 참조는 그대로 살아 있다. 실제 정리 비용은 아래 quit_* 계측이 남긴다.
        terminationTiming.record(.hideWindows, elapsedNs: measureElapsedNs {
            // 숨기면 `isKeyWindow`가 false가 되므로, workspace의 active-window 마커가 읽을 key 창을 **먼저** 붙잡는다.
            terminationKeyWindow = windows.first(where: { $0.window?.isKeyWindow == true })?.window
            // 전체화면(native `.fullScreen`) 창은 **숨기지 않는다**. 전체화면 창을 orderOut하면 macOS가 그 space를
            // 없애며 이전 space로 전환하는데, 종료 직전에 그 전환 애니메이션이 끼어들면 체감이 오히려 나빠진다
            // (숨김의 목적은 체감 개선이지 새 애니메이션 추가가 아니다). 전체화면은 그 창이 화면을 다 덮고 있어
            // 뒤에 드러날 다른 창도 없으므로 숨겨서 얻는 것도 없다. workspace 저장이 전체화면 frame을 건너뛰는
            // 것과 같은 이유의 예외다.
            for surface in windows where surface.window?.styleMask.contains(.fullScreen) == false {
                surface.window?.orderOut(nil)
            }
            if quick?.window?.styleMask.contains(.fullScreen) == false { quick?.window?.orderOut(nil) }
        })
        terminationTiming.record(.mermaid, elapsedNs: measureElapsedNs {
            cancelAllMermaidReplies(error: "application terminating")
            mermaidRenderCoordinator.shutdown()
            // physical control/I/O executor가 완전히 quiesce된 뒤 Zig app-global queue/latch/lease를
            // 최종 종료한다. 이 순서만 leased request frame의 pointer 수명을 안전하게 끝낸다.
            maru_macos_mermaid_shutdown()
        })
        // 컨트롤 플레인 서버를 세션 teardown '전에' 멈춘다 — accept 스레드를 join하고 대기 중 요청을 cancel해, 이후
        // shutdownAppSession이 세션을 해제할 때 accept 스레드가 (marshal 큐 밖에서) 세션을 만지지 않게 한다. tick은
        // 이미 멈춰(위) 더 이상 drain되지 않는다. idempotent(미시작이면 무동작).
        terminationTiming.record(.controlServer, elapsedNs: measureElapsedNs {
            if controlServerStarted {
                maru_macos_control_server_stop()
                BrowserResultTransferRegistry.shared.releaseAll() // ABI stop callback 실패까지 포함한 마지막 Data 소유권 backstop.
                controlServerStarted = false
            }
        })
        // C4가 terminateLater 보류 중 final generation을 C2로 commit한 뒤에만 reply(true)한다. 여기서는
        // 세션 teardown 뒤의 구형 best-effort writer를 다시 실행하지 않는다(이전 완전본 역행/이중 writer 방지).
        workspaceCheckpointArmed = false
        // 종료 중에는 추가 tick을 돌리지 않는다. tick은 session_ended에서 NSApp.terminate를
        // 부르므로, 여기서 다시 tick하면 재진입 terminate가 된다. 마지막 counter는
        // shutdownAppSession의 close()가 summary에 담는다.
        // 종료 요약 기준 surface(메인=첫 창)를 shutdown '전에' 잡는다 — shutdownAppSession이 컬렉션을 비우므로
        // 그 뒤엔 primary(=windows.first)가 nil이 된다. surface 객체는 캡처로 살아 있어 close가 채운 요약을 읽는다.
        let mainSurface = windows.first
        terminationTiming.record(.teardown, elapsedNs: measureElapsedNs {
            shutdownAppSession(preserveWebPanelsFor: mainSurface)
        })
        // 모든 AppSession이 자기 runtime을 remove/detach한 뒤 app-global backend/pool/client를 exact once 정산한다.
        // incident leaf도 이 전역들이 남아 있으면 latch를 소비하지 않아 source 순서 회귀를 fail-close한다.
        _ = maru_macos_remote_backend_settle()
        // 모든 AppSession과 remote backend close/detach settlement가 끝난 뒤에만 incident owner를 revoke한다.
        // ordinary Window close에서는 부르지 않으며 AppHost termination이 process-global writer를 exact 한 번 정산한다.
        _ = maru_macos_incident_owner_shutdown()
        if let mainSurface {
            // quick 패널이 key인 채 종료해도 forwarder가 quick으로 새지 않게 메인 창을 명시 대상으로.
            withSurface(mainSurface) {
                writeSummary(visibleUI: mainSurface.window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
            }
            // 기존 summary가 panel-derived 필드를 읽은 뒤 native view/dict를 해제한다. app session/control server는
            // 이미 종료되어 closed push는 no-op이고 ARC cleanup만 남는다.
            teardownWebPanels(mainSurface)
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
        // 빨간 닫기 버튼/창 단위 닫기 요청. session이 없으면(quick 창 등 delegate 미사용 경로) 평소대로 닫는다.
        guard let surface = surfaceForWindow(sender), let session = surface.appSession else { return true }
        // 마지막(유일) 일반 창의 빨간 버튼 = 앱 종료다. 창 하나 닫기(request_window_close, 실행 중 명령 게이트)가 아니라
        // Cmd+Q와 **동일한** 종료 확인을 띄운다 — NSApp.terminate가 applicationShouldTerminate→requestAppQuit로 모달을
        // 연다(마지막 창 닫기=모든 탭·세션 동시 소멸이라 재확인, 사용자 결정 2026-07). 이 창 닫기는 보류(false)하고, 모달
        // 확정 시 종료 경로(applicationWillTerminate→shutdownAppSession)가 창을 닫는다(취소면 창 유지). terminate는 다음
        // run loop로 미뤄 should-close 질의 중 재진입을 피한다. quick은 windows에 없어 이 브랜치에 안 온다.
        if windows.count <= 1 {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        // 멀티 창의 비-마지막 창: 실행 중인 명령이 있으면 Zig가 확인 모달을 열고 1을 돌려준다 → false로 보류(데이터 손실
        // 방지 — iTerm2/Terminal.app/Ghostty 관례). 모달 확정 시 tick의 session-ended가 closeWindowOrQuit으로 그 창만
        // 닫는다(프로그래밍적 close()라 이 델리게이트 재호출 없음). 실행 중 명령이 없으면 true(평소 닫기 → windowWillClose).
        return maru_macos_app_session_request_window_close(session) == 0
    }

    func windowWillClose(_ notification: Notification) {
        // 닫히는 창의 일반-창 surface(quick은 delegate를 안 써 여기 안 옴). 마지막 일반 창이면 앱 종료
        // (정리·요약은 applicationWillTerminate — primary가 살아 있어야 요약이 그 세션 기준. 원래 단일 창 동작
        // 보존). 마지막이 아니면 그 창 세션만 닫고 앱은 계속한다(window는 AppKit이 이미 닫는 중).
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        if windows.count <= 1 {
            if blockGlobalTerminationForProtectedFilePanels() {
                // 창은 AppKit이 이미 닫는 중이다. 이 일반 세션만 정리하고 protected quick session과 frame loop를
                // 유지한다. 보호가 해소된 뒤 quick이 종료될 때만 앱 전체 종료를 다시 시도한다.
                teardownWindowSurface(surface)
                return
            }
            bypassQuitConfirm = true // 모든 일반 창+quick 보호 preflight 완료
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
        // green-button zoom·프로그램적 resize는 live-resize 종료 콜백이 없을 수 있다. 드래그 중만 보류하고
        // 나머지는 actual frame dedup 경계로 즉시 기록한다.
        if surface.view?.inLiveResize != true, let window = notification.object as? NSWindow {
            markWorkspaceCheckpointFrameIfChanged(window)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 창 포커스 획득 → 그 창 surface에 focus reporting(DECSET 1004 켜졌으면 CSI I). 멀티 창에서 그 창만(notification.object).
        guard let window = notification.object as? NSWindow,
              let surface = surfaceForWindow(window), let session = surface.appSession else { return }
        _ = maru_macos_app_session_focus_changed(session, 1)
        if workspaceCheckpointArmed && surface.workspaceCheckpointPublished {
            let identity = ObjectIdentifier(window)
            if workspaceCheckpointActiveWindow != identity {
                workspaceCheckpointActiveWindow = identity
                maru_macos_workspace_checkpoint_mark_active_window()
            }
        }
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
        // follow-system이면 위 set_system_appearance가 테마 색을 바꿨을 수 있으므로 열린 소스 편집기 syntax 색도 갱신.
        refreshFilePanelSyntaxTheme()
    }

    // §2.3: 터미널 테마 변경 시 열린 모든 신뢰 shell(text/markdown)의 syntax 색을 다시 주입한다. CSS 변수라
    // 마운트된 CM6도 즉시 재도색된다. reload/reset/follow-system appearance 등 테마가 바뀌는 경로에서 호출한다.
    func refreshFilePanelSyntaxTheme() {
        for surface in windows {
            for panel in surface.webPanels.values where panel.filePanelKind == 1 {
                panel.applySyntaxThemeStyle()
            }
        }
        if let quick = quick {
            for panel in quick.webPanels.values where panel.filePanelKind == 1 {
                panel.applySyntaxThemeStyle()
            }
        }
    }

    // §2.3: 폰트 크기(⌘+/−·config)가 바뀌면 열린 모든 파일 패널(신뢰 shell·HTML/PDF browser)에 현재 줌 배율을
    // 적용한다. 편집기 폰트 pt는 refreshFilePanelSyntaxTheme가 재주입하므로 여기선 프리뷰 페이지 줌만 다룬다.
    // 배율은 활성 세션의 Zig 계산값(현재 폰트/base) — 창별로 폰트가 갈릴 수 있어 각 창의 세션에서 읽는다.
    func refreshFilePanelZoom() {
        for surface in windows {
            guard let session = surface.appSession else { continue }
            let zoom = maru_macos_app_session_file_panel_zoom_milli(session)
            for panel in surface.webPanels.values where panel.filePanelKind != 0 {
                panel.applyFilePanelZoom(zoom)
            }
        }
        if let quick = quick, let session = quick.appSession {
            let zoom = maru_macos_app_session_file_panel_zoom_milli(session)
            for panel in quick.webPanels.values where panel.filePanelKind != 0 {
                panel.applyFilePanelZoom(zoom)
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // 그 창(notification.object)의 surface를 명시 대상으로(위 windowDidResize와 같은 이유).
        guard let surface = surfaceForWindow(notification.object as? NSWindow) else { return }
        withSurface(surface) {
            metalTerminalView?.updateDrawableSize()
            resizeAppSessionFromWindow()
        }
        if let window = notification.object as? NSWindow { markWorkspaceCheckpointFrameIfChanged(window) }
    }

    func windowDidMove(_ notification: Notification) {
        guard workspaceCheckpointArmed, let window = notification.object as? NSWindow,
              surfaceForWindow(window) != nil else { return }
        let identity = ObjectIdentifier(window)
        workspaceCheckpointMoveTasks[identity]?.cancel()
        let task = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.workspaceCheckpointMoveTasks.removeValue(forKey: identity)
            self.markWorkspaceCheckpointFrameIfChanged(window)
        }
        workspaceCheckpointMoveTasks[identity] = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow { markWorkspaceCheckpointFrameIfChanged(window) }
    }

    private func validateZigBoundary() -> Bool {
        // Swift 제품 host가 시작할 때 Zig ABI version과 ownership capability를 먼저 본다.
        // 이 확인이 없으면 Swift 쪽 앱 lifecycle이 오래된 Zig static library를 링크해도
        // 조용히 실행되어 input/close event shape가 어긋날 수 있다.
        let status = maru_macos_app_host_capabilities(&capabilities)
        return status == Self.statusOK &&
            capabilities.abi_version == MARU_MACOS_APP_HOST_ABI_VERSION &&
            capabilities.swift_owns_ns_application == 1 &&
            capabilities.zig_owns_frame_loop == 1 &&
            MaruAssetLoadBudget.selfTest(limit: MaruAssetLoadBudget.capacity) &&
            MaruAssetLoadBudget.selfTest(limit: 3)
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
        // Archive fixture의 readback은 PR에서 실제 detail hierarchy를 검토하는 evidence다. 일반 창
        // 크기는 보존하되, fixture만 1920×1200 pt로 열어 button text/card와 오른쪽 세션 도크의 실제
        // typography·row divider를 PR에서 충분한 해상도로 검토할 수 있게 한다. 좁은 960×600 frame에서
        // 잘려 보이지 않게 한다. backing scale은 기존 제품 resize path가 그대로 정한다.
        let initialContentSize = isAgentSessionArchiveSmokeMode
            ? NSSize(width: 1920, height: 1200)
            : NSSize(width: 960, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
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

        // Phase 4b-2: contentView를 컨테이너로 재편한다 — 터미널 뷰(맨 아래) + 모달 오버레이 뷰(맨 위). 4c WKWebView(insertWebPanel)가 그 사이.
        let container = MaruTerminalContainerView(
            frame: window.contentView?.bounds ?? NSRect(origin: .zero, size: initialContentSize),
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

    // 창/패널 컨테이너의 터미널 자식 뷰를 firstResponder로 만든다(입력·IME는 터미널 뷰가 소유).
    private func focusTerminalView(_ window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder((window.contentView as? MaruTerminalContainerView)?.terminalView)
    }

    // MARK: - Phase 4d: 웹 패널 입력 responder 전이 (docs/web-panel.md §4)

    // 이 웹 패널이 지금 입력 포커스를 쥐고 있는가 — WKWebView가 포커스면 firstResponder는 그 내부 뷰(WKContentView
    // 등, wp의 자손)다. 웹 패널 hitTest·performKeyEquivalent override가 "웹 포커스일 때만" 동작하도록 이 판정을 쓴다.
    func isWebPanelFocused(_ wp: MaruWebPanelView) -> Bool {
        guard let fr = wp.window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: wp)
    }

    /// key window의 first responder가 웹 패널(도크 파일 뷰 또는 워크스페이스 브라우저) 안쪽이면 그 패널을 돌려준다.
    /// 메뉴바 편집 키(⌘C/⌘V/⌘A)는 keyEquivalent가 first responder와 무관하게 발화하므로, 웹 포커스 시 표준 편집
    /// 셀렉터를 WebKit responder chain으로 넘길지 판정하는 단일 소스다([web-panel.md] §4.2). 아니면 nil → 터미널 경로.
    private func firstResponderWebPanel() -> MaruWebPanelView? {
        guard let fr = NSApp.keyWindow?.firstResponder as? NSView else { return nil }
        var view: NSView? = fr
        while let current = view {
            if let panel = current as? MaruWebPanelView { return panel }
            view = current.superview
        }
        return nil
    }

    // WKWebView의 명시적 primary-down만 direct focus intent로 승격한다. A lazy focus가 retained된 동안 이미
    // responder인 file/browser B를 다시 클릭해도 이 event가 A token을 취소하므로, 늦은 A create가 focus를 되훔치지 못한다.
    func webPanelPrimaryDown(_ wp: MaruWebPanelView) {
        guard let surface = surfaceOwning(wp), let session = surface.appSession else { return }
        if wp.filePanelKind == 0 {
            // 이미 firstResponder인 workspace browser 재클릭도 A lazy dock focus보다 최신 intent다.
            // surface 활성화가 모델에서 성공한 경우에만 workspace owner로 승격하고 retained A를 폐기한다.
            guard maru_macos_app_session_activate_surface(session, wp.surfaceId) != 0 else { return }
            maru_macos_app_session_focus_workspace_input(session)
            surface.focusedFilePanelSurfaceId = nil
        } else {
            guard maru_macos_app_session_focus_file_panel_surface(session, wp.surfaceId) != 0 else { return }
            surface.focusedFilePanelSurfaceId = wp.surfaceId
        }
        surface.filePanelFocusOverridden = false
        surface.pendingDockFocusActionSurfaceId = nil
    }

    func filePanelDidTerminateWebContent(_ surfaceId: UInt64, panel: MaruWebPanelView) -> Bool {
        cancelMermaidReplies(surfaceId: surfaceId, error: "file panel terminated")
        // registry의 exact current panel일 때만 native document-loss latch를 보낸다 — 이미 교체된 패널의 뒤늦은
        // 종료가 새 문서의 편집 상태를 건드리면 안 된다. 반환값은 호출부의 reload 여부다.
        guard surfaceOwning(byId: surfaceId)?.webPanels[surfaceId] === panel,
              let session = bridgeSession(for: surfaceId) else { return false }
        return maru_macos_app_session_file_panel_document_terminated(session, surfaceId) != 0
    }

    private func surfaceOwning(_ wp: MaruWebPanelView) -> TerminalSurface? {
        if let s = windows.first(where: { $0.webPanels[wp.surfaceId] === wp }) { return s }
        if let quick, quick.webPanels[wp.surfaceId] === wp { return quick }
        return nil
    }

    // surface_id로 그 웹 패널을 소유한 창(일반 창·quick)을 찾는다 — dispatchBrowserNav·adoptPopupWebView가 공유하는
    // 단일 소스(위 identity 기반 surfaceOwning(_:)의 id 판). 못 찾으면 nil(호출처가 활성 세션 폴백).
    private func surfaceOwning(byId surfaceId: UInt64) -> TerminalSurface? {
        if let s = windows.first(where: { $0.webPanels[surfaceId] != nil }) { return s }
        if let quick, quick.webPanels[surfaceId] != nil { return quick }
        return nil
    }

    /// 신뢰 file bridge가 surface의 현재 소유 세션을 매 요청마다 해소한다. 창 간 reparent 뒤에도 handler가 옛 세션을
    /// 캡처하지 않으며, dict 등록 전에는 nil이라 load를 시작하지 않는 생성 순서와 함께 오라우팅을 막는다.
    func bridgeSession(for surfaceId: UInt64) -> OpaquePointer? {
        surfaceOwning(byId: surfaceId)?.appSession
    }

    /// Zig admission이 반환한 `job_id`와 WebKit reply closure를 같은 bounded table에 묶는다. helper 결과가
    /// 도착하기 전에는 page-world Promise를 해소하지 않으므로 별도 polling이나 frame별 JSON allocation이 없다.
    func registerMermaidReply(
        surfaceId: UInt64,
        jobId: UInt64,
        requestId: Any,
        params: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) -> Bool {
        guard surfaceId != 0, jobId != 0,
              let identity = mermaidIdentity(params) else { return false }
        let key = MermaidReplyKey(surfaceId: surfaceId, jobId: jobId)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishMermaidReply(key: key, svg: nil, error: "mermaid render timeout", revoke: true)
        }
        guard mermaidReplyDelivery.register(
            key: key,
            requestId: requestId,
            identity: identity,
            timeout: timeout,
            replyHandler: replyHandler
        ) else {
            // Zig admission already owns this job. A bounded Swift table rejection must revoke the exact widget
            // immediately instead of leaving an orphan helper action that can consume source/SVG capacity.
            revokeMermaidJob(key: key, identity: identity)
            return false
        }
        return true
    }

    private func mermaidIdentity(_ params: [String: Any]) -> MermaidReplyIdentity? {
        func number(_ key: String) -> UInt64? { (params[key] as? NSNumber)?.uint64Value }
        guard let editorEpoch = number("editor_epoch"), editorEpoch != 0,
              let documentRevision = number("document_revision"),
              let projectionGeneration = number("projection_generation"), projectionGeneration != 0,
              let widgetId = number("widget_id"), widgetId != 0,
              let widgetGeneration = number("widget_generation"), widgetGeneration != 0,
              let rendererInstance = number("renderer_instance"), rendererInstance != 0 else { return nil }
        return MermaidReplyIdentity(
            editorEpoch: editorEpoch,
            documentRevision: documentRevision,
            projectionGeneration: projectionGeneration,
            widgetId: widgetId,
            widgetGeneration: widgetGeneration,
            rendererInstance: rendererInstance
        )
    }

    private func revokeMermaidJob(key: MermaidReplyKey, identity: MermaidReplyIdentity) {
        var renderer = MaruMermaidRendererCapability(
            editor_epoch: identity.editorEpoch,
            document_revision: identity.documentRevision,
            projection_generation: identity.projectionGeneration,
            widget_id: identity.widgetId,
            widget_generation: identity.widgetGeneration,
            renderer_instance: identity.rendererInstance
        )
        maru_macos_mermaid_revoke_job(key.surfaceId, key.jobId, &renderer)
    }

    func revokeMermaidReply(surfaceId: UInt64, params: [String: Any]) {
        guard let identity = mermaidIdentity(params) else { return }
        mermaidReplyDelivery.finishMatching(
            surfaceId: surfaceId,
            identity: identity,
            error: "mermaid render revoked"
        ) { [weak self] key, targetIdentity in
            self?.revokeMermaidJob(key: key, identity: targetIdentity)
        }
    }

    private func deliverMermaidAcceptedResult(_ payload: MermaidAcceptedPayload) {
        mermaidReplyDelivery.deliver(payload) { [weak self] key, identity in
            self?.revokeMermaidJob(key: key, identity: identity)
        }
    }

    private func deliverMermaidTerminalResult(_ terminal: MaruMermaidTerminalResult) {
        let key = MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id)
        let error: String
        switch terminal.reason {
        case MARU_MERMAID_TERMINAL_SUPERSEDED: error = "mermaid render superseded"
        case MARU_MERMAID_TERMINAL_DEADLINE: error = "mermaid render deadline expired"
        case MARU_MERMAID_TERMINAL_TRANSIENT_FAILURE: error = "mermaid helper failed"
        case MARU_MERMAID_TERMINAL_INTEGRITY_FAILURE: error = "mermaid helper integrity failure"
        case MARU_MERMAID_TERMINAL_INVALID_RESULT: error = "invalid mermaid result"
        case MARU_MERMAID_TERMINAL_CAPACITY_EXCEEDED: error = "mermaid result capacity exceeded"
        case MARU_MERMAID_TERMINAL_FAILURE_LATCHED: error = "mermaid renderer disabled after repeated failures"
        default: error = "mermaid render failed"
        }
        mermaidReplyDelivery.finishExact(
            key: key,
            identity: MermaidReplyIdentity(renderer: terminal.renderer),
            error: error
        )
    }

    private func failMermaidReply(capability: MaruMermaidJobCapability, error: String) {
        mermaidReplyDelivery.fail(capability: capability, error: error) { [weak self] key, identity in
            self?.revokeMermaidJob(key: key, identity: identity)
        }
    }

    private func finishMermaidReply(
        key: MermaidReplyKey,
        svg: String?,
        error: String?,
        revoke: Bool
    ) {
        mermaidReplyDelivery.finish(
            key: key,
            svg: svg,
            error: error,
            revoke: revoke
        ) { [weak self] key, identity in
            self?.revokeMermaidJob(key: key, identity: identity)
        }
    }

    @discardableResult
    func cancelMermaidReplies(surfaceId: UInt64, error: String) -> Int {
        mermaidReplyDelivery.cancelSurface(surfaceId, error: error) { [weak self] key, identity in
            self?.revokeMermaidJob(key: key, identity: identity)
        }
    }

    private func cancelAllMermaidReplies(error: String) {
        mermaidReplyDelivery.cancelAll(error: error) { [weak self] key, identity in
            self?.revokeMermaidJob(key: key, identity: identity)
        }
    }

    // 4e-4(web-panel §10): 창 간 이동 시 대상 창의 create 전이가 다른 창의 기존 WKWebView를 훔쳐 재부모화한다. 어느 창(quick 포함)의
    // webPanels dict에 이 surface_id가 있으면 그 dict에서 **떼어내(dict만 제거)** 반환한다(호출처가 새 컨테이너에 insert+dict 등록).
    // 없으면 nil(=진짜 신규 → fresh 생성). superview 이동(removeFromSuperview→insertWebPanel)은 호출처가 한다.
    private func detachWebPanelForReparent(_ surfaceId: UInt64) -> MaruWebPanelView? {
        if let src = surfaceOwning(byId: surfaceId), let v = src.webPanels[surfaceId] {
            src.webPanels[surfaceId] = nil
            return v
        }
        return nil
    }

    // 4e-4: 이 창(except)을 떠나지만 **다른 창 모델에 아직 live**인 web surface의 소유 창을 찾는다(quick 포함) — 이동↔닫힘 판정.
    // has_web_surface ABI(세션 트리 조회)를 쓴다: webPanels dict가 아니라 **모델**을 봐야 워크스페이스 전환(같은 창 비활성 탭)과
    // 안 헷갈린다. **다른 창이 없으면 아래 루프가 0-FFI**(단일-창 탭 close 경로 = 흔한 경우, cleanup [3]). 없으면 nil=진짜 닫힘.
    // (count 가드는 안 둔다 — teardown 시점엔 닫히는 창이 `windows`서 이미 빠져 count==1이어도 대상 창이 있을 수 있어 오판됨.)
    private func windowOwningWebSurfaceModel(_ surfaceId: UInt64, except: TerminalSurface) -> TerminalSurface? {
        for w in windows where w !== except {
            if let s = w.appSession, maru_macos_app_session_has_web_surface(s, surfaceId) == 1 { return w }
        }
        if let q = quick, q !== except, let s = q.appSession, maru_macos_app_session_has_web_surface(s, surfaceId) == 1 { return q }
        return nil
    }

    // 4e-4: 이 창(from)을 떠나지만 다른 창 모델에 live인 web surface의 WKWebView를 그 대상 창 webPanels dict로 **이관**한다 —
    // 파괴·browser.closed 없이 상태 보존. removeFromSuperview로 from서 떼고 대상 dict에 등록(대상의 후속 create/show가 adopt
    // 브랜치로 컨테이너 insert+reframe). **merge는 옮긴 워크스페이스를 대상 *비활성* 탭으로 착지**시켜 create-steal이 안 도므로
    // (대상은 자기 활성 워크스페이스 유지), 원본 창 teardown·destroy 경로가 이 이관으로 상태를 보존한다(코드리뷰 [1] HIGH 수정).
    // 대상 창을 못 찾으면(=진짜 닫힘) false — 호출처가 파괴한다. from dict서는 제거하고 대상 dict에 넣는다.
    @discardableResult
    private func reparentWebPanelToOwningWindow(_ surfaceId: UInt64, _ panel: MaruWebPanelView, from: TerminalSurface) -> Bool {
        guard let dst = windowOwningWebSurfaceModel(surfaceId, except: from) else { return false }
        panel.removeFromSuperview()
        from.webPanels[surfaceId] = nil
        dst.webPanels[surfaceId] = panel
        return true
    }

    // 이 웹 패널이 속한 창의 chrome 오버레이(모달/녹음)가 열려 있는가 — hitTest가 열림이면 nil을 돌려 클릭을 아래
    // 터미널로 통과시킨다(모달 dismiss·요소 클릭이 Zig로). anyOverlayOpen(활성 창)과 달리 그 웹 패널의 **자기 창**
    // 세션을 조회한다(멀티 창 오라우팅 방지, code-review [9]). 소유 surface를 못 찾으면 false(통과 안 함=평소 focusable).
    func isOverlayOpenForWebPanel(_ wp: MaruWebPanelView) -> Bool {
        guard let session = surfaceOwning(wp)?.appSession else { return false }
        return maru_macos_app_session_any_overlay_open(session) != 0
    }

    // Zig resolver의 typed route를 그대로 전달한다. 정규화 실패·세션 없음은 pass-through(0), 알 수 없는 raw는
    // 호출부가 consume한다.
    func webPanelKeyRoute(_ wp: MaruWebPanelView, _ event: NSEvent) -> UInt32 {
        guard let session = surfaceOwning(wp)?.appSession ?? appSession,
              var keyEvent = normalizedKeyEvent(from: event) else { return 0 }
        return maru_macos_app_session_web_key_route(session, wp.surfaceId, &keyEvent)
    }

    // WebKeyRoute.app_action은 범용 handleKeyDown의 terminal 전처리(Cmd+C/V·scroll)를 우회하고, 같은 Zig resolver가
    // 확정한 Action을 직접 dispatch한다. 모달을 열었으면 같은 이벤트 루프에서 responder도 되돌린다.
    func dispatchWebPanelAppAction(_ wp: MaruWebPanelView, _ event: NSEvent) {
        let owner = surfaceOwning(wp)
        guard let session = owner?.appSession ?? appSession,
              var keyEvent = normalizedKeyEvent(from: event) else { return }
        syncLastWindowBeforeKeyDispatch(session, owner: owner ?? activeSurface)
        _ = maru_macos_app_session_dispatch_web_app_action(session, wp.surfaceId, &keyEvent)
        reconcileWebFocus()
    }

    // Phase 7e-4: browser 패널 nav 단축키(⌘←/→/R)를 Zig 코어로 전달한다(performKeyEquivalent에서 code 마샬링 후 호출).
    // 정책(활성 판정·pending)은 Zig setBrowserNavAction, 실행은 그 세션 tick의 take_web_nav_action drain(클릭 경로 재사용).
    // **소유 창(surface)의 세션**에 세운다 — drain이 그 세션 tick에서 돌기 때문(멀티 창 오라우팅 방지, surfaceOwning과
    // 같은 규율이되 surface_id 키로 조회). 못 찾으면 활성 세션 폴백(webPanelKeyRoute의 `?? appSession`과 대칭).
    func dispatchBrowserNav(_ surfaceId: UInt64, _ code: UInt32) {
        guard let session = surfaceOwning(byId: surfaceId)?.appSession ?? appSession else { return }
        _ = maru_macos_app_session_browser_nav(session, surfaceId, code)
    }

    /// 로컬 HTML delegate의 실제 사용자 클릭을 Markdown bridge와 같은 Zig 정책 경계로 보낸다. surface 소유 세션을
    /// 다시 해소하므로 창 이동 뒤에도 config와 새 browser Term이 올바른 창에 적용된다.
    func openFilePanelLink(_ surfaceId: UInt64, url: String, forceSystem: Bool) -> Bool {
        guard let session = surfaceOwning(byId: surfaceId)?.appSession ?? appSession else { return false }
        let bytes = Array(url.utf8)
        return bytes.withUnsafeBufferPointer { p in
            maru_macos_app_session_open_file_panel_link(
                session, surfaceId, p.baseAddress, p.count, forceSystem ? 1 : 0
            ) == 1
        }
    }

    // Phase 7e-4 후속: 활성 창의 활성 pane 활성 term이 browser web이면 그 surface_id, 아니면 0. web 패널
    // performKeyEquivalent가 browser nav 단축키(⌘←/→/R)를 "이 패널이 활성 browser 탭일 때만" 처리하도록 게이트한다
    // (WKWebView 키보드 포커스 유무와 무관). 정책·트리 판정은 Zig(activeWebSurfaceId), Swift는 read만.
    func activeWebSurfaceId() -> UInt64 {
        guard let session = appSession else { return 0 }
        return maru_macos_app_session_active_web_surface_id(session)
    }

    func focusedFilePanelSurfaceId() -> UInt64 {
        guard let surface = activeSurface else { return 0 }
        let actual = surface.webPanels.values.first(where: {
            $0.filePanelKind != 0 && isWebPanelFocused($0)
        })?.surfaceId
        // 모달/rename override가 TerminalView를 잠시 firstResponder로 바꾼 동안에도 retained 도크 입력 축을 돌려줘
        // workspace browser의 포커스-무관 Cmd+R/←/→ 특례가 역방향으로 발화하지 못하게 한다.
        return actual ?? (surface.filePanelFocusOverridden ? surface.focusedFilePanelSurfaceId ?? 0 : 0)
    }

    // Phase 7f-1: 팝업 adopt — MaruWebPanelView.createWebViewWith(WKUIDelegate)가 넘긴 config로 새 WKWebView를 만들어
    // 붙일 browser web Term을 Zig에 등록(7f-0 create_adopted_web_term)하고, adopt 패널로 감싸 **opener가 속한 창**의
    // 컨테이너에 즉시 삽입한 뒤 그 webview를 돌려준다. WebKit은 반환된 webview로 새 페이지를 로드하며, 이 webview가
    // 넘어온 config로 만들어졌기에 opener/named-window 링크가 성립한다. **즉시 삽입** 이유: window 없는 webview는
    // WebKit이 안 그리므로 반환 전에 뷰 하이어라키에 넣는다(정확한 pane rect는 다음 tick drain .create가 보정 —
    // 그 create는 webPanels[sid]가 이미 있어 중복 WKWebView 생성을 스킵한다). opener를 못 찾거나 term 생성 실패면 nil
    // (WebKit이 창 생성 취소). surfaceOwning 규율(dispatchBrowserNav)과 동일하게 openerSurfaceId로 창을 고른다.
    func adoptPopupWebView(configuration: WKWebViewConfiguration, openerSurfaceId: UInt64) -> WKWebView? {
        guard let surface = surfaceOwning(byId: openerSurfaceId), let session = surface.appSession,
              let container = surface.window?.contentView as? MaruTerminalContainerView else { return nil }
        let sid = maru_macos_app_session_create_adopted_web_term(session)
        guard sid != 0 else { return nil }
        let panel = MaruWebPanelView(adoptingConfiguration: configuration, surfaceId: sid, frame: container.bounds)
        panel.controller = self
        surface.webPanels[sid] = panel
        container.insertWebPanel(panel) // 반환 전 삽입(정확한 frame은 drain이 보정)
        return panel.webView
    }

    // 웹 패널 포커스 ↔ 터미널 responder 전이를 Zig terminalOwnsInput/활성 pane 기준으로 조정한다(renderTick 매 tick + 웹
    // 조합 직후 동기 호출). 웹 패널이 없으면 무동작이라 MARU_WEB_PANEL 훅이 없는 평시 빌드엔 영향이 없다. 터미널 IME/keyDown 코드는
    // 건드리지 않고 makeFirstResponder만 부른다 — 전이는 기존 becomeFirstResponder(imeFocus true)/resignFirstResponder
    // (commitComposition)를 그대로 태운다(새 IME 로직 없음). 단일 출처: docs/web-panel.md §4.
    // Phase 4g-1: 웹↔터미널 포커스 동기 불변식(§4.1) — **firstResponder ⟺ Zig 활성 pane**. 옛 reconcileWebModalFocus +
    // reconcileWebFocusActivation을 **하나로 통합·대체**(파편화된 포커스 패치를 근본 불변식으로). 매 tick + 웹 조합 직후·
    // ⌘Q 직후 동기 호출. 웹 패널 없으면 무동작(평시 무영향). 기존 터미널 IME/keyDown은 한 줄도 안 건드림(4d 규율 —
    // makeFirstResponder만).
    //
    // **override(우선순위 모달 > 터미널-라우팅 텍스트 입력)**: 모달(notice 제외) 또는 주소창 편집·rename·사이드바 검색 중엔
    // 입력이 Zig handleKeyEvent 경로(모달 Enter/Esc·편집 키·IME preedit)라 **터미널 뷰**가 firstResponder여야 한다 — 웹뷰가
    // 쥐면 샌다(제보: ⌘Q 종료 모달 Enter 무응답; web pane 위 rename/검색이 웹뷰로 새던 14차 리뷰 [0]). 판정은 Zig
    // terminalOwnsInput 단일 출처(anyModalOverlayOpen ∪ addr_edit ∪ rename ∪ sidebar_search). 열린 내내 self-heal.
    //
    // **override 없으면 단방향 reconcile**: explicit primary-down/typed completion이 먼저 Zig owner를 갱신하고,
    // 여기서는 그 모델만 읽어 firstResponder를 맞춘다. firstResponder 관측은 programmatic/accessibility 전이와 사용자
    // click을 구별할 수 없으므로 정책 mutation 권한이 없다.
    func reconcileWebFocus() {
        guard let surface = activeSurface, let window = surface.window, let session = surface.appSession,
              let tv = (window.contentView as? MaruTerminalContainerView)?.terminalView else { return }
        guard !surface.webPanels.isEmpty else { return }

        // override: 모달(notice 제외) 또는 터미널-라우팅 텍스트 입력(주소창 편집·rename·사이드바 검색) 중이면 터미널 뷰가
        // firstResponder여야 한다(그 키/IME가 Zig handleKeyEvent 경로) — Zig terminalOwnsInput 단일 출처. 옛 override는
        // rename·사이드바 검색을 빠뜨려 web pane 활성 중 그 편집이 웹뷰로 샜다(14차 리뷰 [0]) + notice까지 세었다([3]).
        if maru_macos_app_session_terminal_owns_input(session) != 0 {
            if window.firstResponder !== tv { window.makeFirstResponder(tv) } // tv 이미 바인딩(재downcast 회피, 리뷰 [8])
            if surface.focusedFilePanelSurfaceId != nil { surface.filePanelFocusOverridden = true }
            return
        }

        // FP16 §3.4: 파일 패널이 워크스페이스 pane 탭이 된 뒤로 "어느 파일 WebView가 focus인가"는 아래
        // `active_web_surface_id_any_kind`(활성 pane의 활성 Term)와 같은 답이다. 옛 dock 전용 분기는
        // 도크가 워크스페이스 밖에 있던 시절의 것이라 제거했다 — 두 경로가 갈리면 stale focus가 난다.
        // native liveness는 여전히 필요하다 — Zig가 돌려준 id의 WKWebView가 아직 안 붙었거나 숨겨진
        // 프레임에도 그대로 기록하면 그 프레임의 focus 판정이 실제 뷰 상태와 어긋난다(옛 dock 분기가
        // 하던 검사를 유지한다).
        let focusedFileId = maru_macos_app_session_focused_dock_surface(session)
        if focusedFileId != 0, let panel = surface.webPanels[focusedFileId],
           panel.superview != nil, !panel.isHidden {
            surface.focusedFilePanelSurfaceId = focusedFileId
        } else {
            surface.focusedFilePanelSurfaceId = nil
        }
        surface.filePanelFocusOverridden = false

        // firstResponder = Zig가 승인한 활성 pane/dock surface.
        let activeWeb = maru_macos_app_session_active_web_surface_id_any_kind(session)
        if activeWeb != 0 {
            // 활성 = web term → 그 webview가 firstResponder(아직 아니면 전이). 브라우저 탭 활성화·모달 닫힘 복원 커버.
            if let wp = surface.webPanels[activeWeb], wp.superview != nil, !wp.isHidden, !isWebPanelFocused(wp) {
                window.makeFirstResponder(wp.webView)
            }
        } else if window.firstResponder !== tv {
            // 활성 = terminal → 터미널 뷰(키보드로 웹→터미널 pane 전환 시 stale 웹뷰 포커스 회수 = 키보드 갭 닫음).
            window.makeFirstResponder(tv) // tv 이미 바인딩(재downcast 회피, 리뷰 [8])
        }
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
    /// 지연 스크린샷(`MARU_SCREENSHOT` + `MARU_SCREENSHOT_DELAY_MS`)이 아직 안 찍힌 상태인가.
    /// true면 위 tick 루프가 generation 변화 없이도 draw를 계속 요구해, renderer가 마감이 지난 draw에서
    /// 캡처할 기회를 얻는다. 캡처 직후 renderer가 프로세스를 끝내므로(하니스 계약) 이 플래그를 내릴 필요는 없다.
    /// env가 없으면 항상 false — 일반 실행에는 비용이 없다(값 한 번만 읽어 캐시).
    private static let screenshotDelayArmed: Bool = {
        guard ProcessInfo.processInfo.environment["MARU_SCREENSHOT"] != nil else { return false }
        guard let raw = ProcessInfo.processInfo.environment["MARU_SCREENSHOT_DELAY_MS"],
              let ms = Double(raw), ms > 0 else { return false }
        return true
    }()

    private var screenshotDelayPending: Bool { Self.screenshotDelayArmed }

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
        // 지연 스크린샷이 걸려 있으면 generation이 그대로여도 그린다 — 캡처는 renderer draw 안에서
        // 일어나므로(MARU_SCREENSHOT_DELAY_MS 게이트) 여기서 끊으면 마감이 지나도 찍을 기회가 없다.
        // **바깥 tick 게이트만 넓히면 부족하다**: 이 조기 반환이 두 번째 관문이다(실측: 그것만 고쳤을 때
        // metal_frames_drawn=1로 멈췄다).
        if !newFrame && !metalNeedsRedraw && !screenshotDelayPending {
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
            frame.cursor_cells,           // 커서 blink 페이드: 커서 overlay 구간 길이(본문서 제외·별도 pass; 패스스루)
            frame.cursor_fade_milli,      // 커서 overlay 불투명도 ×1000 — blink 페이드 위상(cursor.blink-fade-ms; 패스스루)
            frame.overlay_cells_present,  // ABI v131: overlay가 cell index 0에서 시작해도 명시적으로 구분
            frame.cursor_start,           // ABI v146: 커서 구간 시작 index — 커서가 버퍼 중간이어도 페이드(패스스루)
            frame.gpu_glyphs,             // B1: rich Chrome final pixel glyph placement(셀 grid와 분리)
            frame.gpu_glyph_count,
            frame.status_bar_height_px, // SB1: 사이드바 배경 strip을 상태바 위에서 끝낸다(strip 클리핑 전용)
            frame.sidebar_scissor_top_px,   // 셀 scissor 구간 — Zig가 게이트·클램프까지 끝낸 값(v168)
            frame.sidebar_scissor_bottom_px,
            frame.cell_clips,             // v169: 셀이 clip_index로 가리키는 사각형 표(패스스루 — 정책은 Zig가 소유)
            frame.cell_clip_count
        )
        if drew {
            lastDrawnGeneration = frame.generation
            metalNeedsRedraw = false
            metalFramesDrawn += 1
        } else {
            // 렌더러가 false(오버레이 drawable pool starvation으로 모달·닫힘 clear를 드롭 등)를 반환하면 재시도가
            // 필요하다. tick 게이트(tickAppSession)는 lastSeenMetalGeneration을 이미 전진시켜 두므로 generation
            // 불일치만으론 재호출되지 않는다 → metalNeedsRedraw를 세워 `|| metalNeedsRedraw` 경로로 다음 tick에
            // drawMetalFrame을 다시 부른다. 성공 draw면 위에서 다시 false로 내려가 재시도가 자동 종료된다.
            metalNeedsRedraw = true
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
    private func createSessionForActiveSurface(smokeMode: Bool, deferInitialSurface: Bool = false) -> Bool {
        // 셸 PTY를 처음부터 실제 창 크기로 띄우도록 backing px+scale을 넘긴다(80×24 기본 spawn→resize 핸드셰이크
        // 제거 → zsh 첫 프롬프트 PROMPT_EOL_MARK % 잔상 방지). 창이 아직 레이아웃 전이면 (0,0,0)이라 Zig가 cols/rows로
        // 폴백한다(smoke는 자체 scripted resize라 0으로 두고 80×24 유지). cols/rows는 0 폴백 시 winsize·grid 단일 출처.
        // Ordinary controlled smoke intentionally starts at 80×24 and scripts its own resize.  The
        // archive fixture instead needs the real Metal view geometry before its first published
        // probe: a zero backing size has no clickable titlebar launcher or dock view slot.
        let m = (smokeMode && !isAgentSessionArchiveSmokeMode)
            ? (widthPx: UInt32(0), heightPx: UInt32(0), scaleMilli: UInt32(0))
            : spawnMetricsForCurrentWindow()
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
            scale_milli: m.scaleMilli,
            defer_initial_surface: deferInitialSurface ? 1 : 0
        )
        // 세션이 config를 읽으며 UI 언어를 정하므로(`ui.language = auto` → 로케일 판정) **그 전에** 넘긴다.
        publishUiLocale()

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

    private func startAppSession(smokeMode: Bool, deferInitialSurface: Bool = false) -> Bool {
        guard createSessionForActiveSurface(smokeMode: smokeMode, deferInitialSurface: deferInitialSurface) else {
            exitCode = 1 // launch 경로의 세션 생성 실패는 비정상 종료(New Window 팩토리 실패는 exitCode를 더럽히지 않음)
            return false
        }
        // deferred session은 applyWorkspaceWindow가 첫 surface/frame loop를 완성하기 전이라 tick하지 않는다.
        if !deferInitialSurface { tickAppSession() }
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
            guard createSessionForActiveSurface(smokeMode: false, deferInitialSurface: ws != nil) else { return }
            if workspaceCheckpointFailureNotice != UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE),
               let session = surface.appSession {
                maru_macos_app_session_set_workspace_checkpoint_failure(session, workspaceCheckpointFailureNotice)
            }
            if let ws {
                // 복원 적용 실패인데 default 셸 창을 성공으로 등록하면 persistent runtime 단절을 숨기고 다음 Quit에서
                // 원래 checkpoint까지 덮는다. 실패 창은 즉시 teardown하고 caller가 incomplete로 기록한다.
                guard applyWorkspaceWindow(ws.text, ws.index) else { return }
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
        if workspaceCheckpointArmed, let session = surface.appSession {
            surface.workspaceCheckpointPublished = true
            maru_macos_app_session_enable_workspace_checkpoint_mutations(session)
            if let window = surface.window {
                workspaceCheckpointFrames[ObjectIdentifier(window)] = window.frame
                if window.isKeyWindow { workspaceCheckpointActiveWindow = ObjectIdentifier(window) }
            }
            maru_macos_workspace_checkpoint_mark_window_inventory()
        }
        return surface
    }

    /// 활성 surface(forwarder 대상)의 세션에 workspace **전체 텍스트**의 window_index번째 창을 적용한다 — 헤더
    /// 포함 전체를 그대로 ABI에 넘긴다(창 경계 분할은 Zig가 소유). 일반 live session은 실패해도 기존 모델을 보존하고,
    /// 시작 restore용 deferred session은 빈 상태로 남는다. **적용 성공 여부를 반환**해 호출자가 teardown/fallback과
    /// checkpoint 보존을 결정하게 한다(파싱은 됐어도 attach/spawn 실패 등).
    @discardableResult
    private func applyWorkspaceWindow(_ text: String, _ index: Int) -> Bool {
        guard let session = appSession else { return false }
        let bytes = Array(text.utf8)
        let status = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_apply_workspace_window(session, buf.baseAddress, buf.count, index)
        }
        guard status == Self.statusOK else { return false }
        // 복원은 손상된 파일 패널 entry·그 결과로 비워진 dock 그룹·접근 불가 explorer root를 **버리면서도 성공을
        // 반환**한다. 그 사실을 모르면 다음 Quit의 자동 checkpoint가 버려진 상태를 파일에 커밋해 사용자가 도크 배치와
        // explorer root를 영구히 잃는다. apply가 성공했어도 버린 것이 있으면 이번 실행의 저장을 막아 마지막 완전본을
        // 보존한다(v144, saveWorkspace의 guard와 같은 래치). 창마다 호출되므로 drain은 창별로 판정된다.
        if maru_macos_app_session_take_workspace_restore_dropped(session) != 0 {
            workspaceRestoreIncomplete = true
        }
        return true
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
    private func restoreWorkspace(
        _ preparedText: String? = nil,
        preparedWindowCount: Int64? = nil,
        deferredInitialSurface: Bool = false
    ) -> Bool {
        guard !smokeMode || isSessionHostR2aCheckpointSmokeMode else { return true }
        // 끄기(임시): config 토글은 후속. 기본은 ON. 이 플래그는 saveWorkspace도 막는다 — 복원을 끈 사용자의 저장
        // 파일을 종료 시 덮어쓰지 않게(persistence 자체 off).
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return true }
        guard let session = primary?.appSession, let text = preparedText ?? loadWorkspaceText() else { return true }
        let bytes = Array(text.utf8)
        // launch preflight 결과를 그대로 재사용한다. 같은 immutable text를 deferred session 생성 뒤 다시 parse하면
        // 두 번째 allocator 실패에서 기본 surface도 없는 빈 session을 남길 수 있다. 직접 호출한 경로만 session
        // allocator로 count를 계산한다.
        let count = preparedWindowCount ?? bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_workspace_window_count(session, buf.baseAddress, buf.count)
        }
        if count < 0 {
            // -1=파싱 실패(헤더 불일치·직렬화 포맷 변경·손상). 저장 파일을 복원할 수 없으니 **조용히 기본 단일 창으로
            // 시작**한다(notice 안 띄움 — 사용자 결정). 특히 직렬화 포맷이 바뀌면(하위호환 미고려 정책) 이전 버전의
            // 저장 파일이 이 경로로 떨어지는데, 이를 '손상' 모달로 알리면 업데이트 후 첫 실행마다 키를 막는 중앙
            // 팝업이 떠 UX가 나쁘다(복원 불가는 사용자 잘못이 아니다). 저장본은 종료 시 saveWorkspace가 새 포맷으로
            // 덮어쓸 때까지 보존된다(self-heal). 빈 workspace(count==0)와 동일하게 조용히 기본 창으로 시작한다.
            workspaceRestoreIncomplete = true
            return true
        }
        guard count > 0 else { return true } // 0=빈 workspace → 기본 단일 창(알림 없음)
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
        if !primaryApplied {
            workspaceRestoreIncomplete = true
            // deferred primary에는 fallback surface도 없다. 실패한 staged attach를 Zig가 rollback한 뒤 이 빈 세션을
            // 폐기하고 명시적인 default-shell 세션을 새로 만들어 사용자에게 usable 창을 남긴다.
            if deferredInitialSurface {
                var fallbackCreated = false
                withSurface(primary) {
                    if let failed = appSession {
                        maru_macos_app_session_destroy(failed)
                        appSession = nil
                    }
                    fallbackCreated = createSessionForActiveSurface(smokeMode: false)
                }
                // 복원도 실패했고 기본 shell 세션 생성도 실패했으면 빈 placeholder 창을 정상 launch로 남기지 않는다.
                // applicationDidFinishLaunching이 일반 startAppSession 실패와 같은 fatal startup 처리를 한다.
                if !fallbackCreated { return false }
            }
        }
        for i in 1..<Int(count) {
            if let created = createTerminalWindow(applyingWorkspace: (text, i)) {
                windowByBlock[i] = created
            } else {
                workspaceRestoreIncomplete = true
            }
        }
        // 복원으로 grid·레이아웃이 바뀌었으니 primary를 창에 다시 맞추고 즉시 repaint한다 — 추가 창은
        // createTerminalWindow가 renderTick하지만 primary는 안 그래서, 기본 레이아웃이 한 프레임 깜빡이는 걸 막는다.
        withSurface(primary) {
            // M3f: primary(창 0)도 저장된 창 frame으로 복원(없으면 현행 기본 위치). resize 전에 setFrame해 resize가
            // 복원 크기를 세션에 전달하게 한다(추가 창은 createTerminalWindow에서 동일 처리).
            if let w = primary?.window { applyRestoredWindowFrame(w, text: text, index: 0) }
            resizeAppSessionFromWindow()
            _ = renderTick()
        }
        // **첫 renderTick 뒤에** 띄운다. notice 버퍼는 세션당 하나뿐이고(showNotice가 dismissMessageOverlays로 교체)
        // 그 첫 tick이 §7 묘비 notice(showPendingEndedPlaceholderNotice)를 띄우므로, 예전처럼 먼저 띄우면 이 경고가
        // 즉시 덮여 사라졌다 — 복원이 무언가를 버리면서 묘비도 만든 경우(host 불통 시 가장 흔한 조합)에 사용자는
        // 체크포인트가 백업된다는 사실을 전혀 못 봤다(code-review). 둘 중 이쪽이 데이터 관련이라 우선하고, 묘비는
        // 화면 안내(writeEndedPlaceholderGuidance)로 pane에 계속 남으므로 토스트를 양보해도 정보가 사라지지 않는다.
        if workspaceRestoreIncomplete {
            // 문장은 Zig 가 고른다 — Swift 는 **상태만** 알린다(docs/i18n.md §7.2).
            if let session = primary?.appSession {
                maru_macos_app_session_notice_workspace_restore_incomplete(session)
            }
            withSurface(primary) { _ = renderTick() } // 위 renderTick은 이미 지나갔으므로 이 notice를 그릴 tick을 준다.
        }
        // M3e: 저장 시점 활성(key)이던 창을 다시 focus한다(docs/window-surface-mobility.md §8A.8). Zig가 active-window=1
        // 마커가 있는 창의 **블록 인덱스**를 주고(없으면 -1 → 무동작, 현행 동작 = 마지막 생성 창 key 유지),
        // windowByBlock으로 그 블록에 해당하는 실제 창을 골라 key로 올린다(라이브 windows 배열에 직접 인덱싱하지
        // 않는다 — 위 매핑 주석의 도메인 발산 방지). createTerminalWindow가 각자 makeKeyAndOrderFront하므로 복원 loop
        // **뒤**(마지막)에 호출해야 활성 창이 최종 key가 된다. 그 블록 창이 spawn 실패로 없으면 건너뛴다(best-effort).
        // primary apply 실패 시 위에서 deferred session을 폐기하고 fallback session으로 교체할 수 있다. launch 초기에
        // 잡아 둔 `session` 포인터를 재사용하면 use-after-free이므로 현재 primary handle을 다시 읽는다.
        let activeIndex = primary?.appSession.map { currentSession in
            bytes.withUnsafeBufferPointer { buf in
                maru_macos_app_session_workspace_active_window(currentSession, buf.baseAddress, buf.count)
            }
        } ?? -1
        if activeIndex >= 0, let keyWindowSurface = windowByBlock[Int(activeIndex)] {
            keyWindowSurface.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// chrome Notice 모달(손상 알림 등)을 primary 세션에 띄운다. 메시지는 UTF-8로 Zig에 넘긴다(세션이 복사 소유라
    /// 호출 뒤 bytes는 해제돼도 안전). 다음 renderTick이 최상위 오버레이로 그린다. 세션 없으면 무동작.
    /// workspace.v1 raw 텍스트를 읽는다(관대 UTF-8 디코드 — 깨진 바이트는 U+FFFD). 없으면 nil. 헤더 검증·창 분할은
    /// Zig ABI가 한다(파싱 권위 단일화) — 여기선 포맷을 파싱하지 않는다.
    private func loadWorkspaceText() -> String? {
        guard let url = workspaceFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 한 일반 창의 세션·렌더러를 닫고(요약은 surface.latestFrameSummary에 남긴다) 컬렉션에서 뺀다. NSWindow는
    /// 건드리지 않는다 — windowWillClose는 이미 닫히는 중이고, 그 외 경로(tick 셸 종료·팩토리 실패)는 호출자가
    /// delegate를 끊고 window를 닫는다(재진입 없이). 앱 quit에선 shutdownAppSession이 남은 창마다 순회 호출.
    private func teardownWindowSurface(
        _ surface: TerminalSurface,
        preserveWebPanelsForSummary: Bool = false,
        checkpointRemovalAlreadyCovered: Bool = false
    ) {
        let removedPublishedWindow = workspaceCheckpointArmed && surface.workspaceCheckpointPublished && !checkpointRemovalAlreadyCovered
        let removedWindowIdentity = surface.window.map(ObjectIdentifier.init)
        if !preserveWebPanelsForSummary { teardownWebPanels(surface) }
        surface.fileTreeWatcher.stop()
        if let session = surface.appSession {
            // Window removal의 app-global commit 하나만 dirty로 센다. session close 내부 teardown은
            // manifest에서 사라질 모델의 정리일 뿐 별도 사용자 mutation이 아니다.
            maru_macos_app_session_disable_workspace_checkpoint_mutations(session)
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
        if let identity = removedWindowIdentity {
            workspaceCheckpointFrames.removeValue(forKey: identity)
            workspaceCheckpointMoveTasks.removeValue(forKey: identity)?.cancel()
        }
        if removedPublishedWindow { maru_macos_workspace_checkpoint_mark_window_inventory() }
    }

    /// 창 전체 teardown은 다음 web-surface transition tick이 없으므로, 살아 있는 panel을 여기서 명시적으로 종료한다.
    /// 개별 destroy 전이와 같은 browser.closed → 실행 중 script terminal → view/dict 해제 순서를 창 단위로 적용한다.
    private func teardownWebPanels(_ surface: TerminalSurface) {
        // 키 스냅샷 — reparentWebPanelToOwningWindow가 dict를 변형(from서 제거)하므로 순회 중 변형 방지.
        for surfaceId in Array(surface.webPanels.keys) {
            guard let panel = surface.webPanels[surfaceId] else { continue }
            // 4e-4(코드리뷰 [1] HIGH): 이 창이 닫히지만 그 surface가 **다른 창으로 이동**했으면(merge 시 대상 *비활성* 탭 착지 →
            // create-steal 미발생), 파괴/browser.closed 대신 대상 창으로 이관해 상태를 보존한다(대상의 후속 create/show가 adopt로 재부모화).
            if reparentWebPanelToOwningWindow(surfaceId, panel, from: surface) { continue }
            if panel.panelKind == 1, panel.filePanelKind == 0 {
                maru_macos_control_push_browser_closed(surfaceId)
                browserDidCloseSurface(surfaceId)
            }
            cancelMermaidReplies(surfaceId: surfaceId, error: "file panel closed")
            // 패널은 여기서 곧바로 소유권을 놓는다 — 라이브 프리뷰 폐기로 worker 종료 ack를 기다릴 이유가 없다.
            panel.removeFromSuperview()
            panel.controller = nil
            surface.webPanels[surfaceId] = nil
        }
        surface.webPanels.removeAll()
        surface.focusedFilePanelSurfaceId = nil
        surface.filePanelFocusOverridden = false
    }

    /// 셸 종료/fault로 한 창을 닫는다(tick 경로). 마지막 일반 창이면 앱 종료(정리·요약은 applicationWillTerminate —
    /// 원래 단일 창 동작 보존), 아니면 그 창만 정리하고 닫는다(앱은 계속).
    private func closeWindowOrQuit(_ surface: TerminalSurface, checkpointRemovalAlreadyCovered: Bool = false) {
        // tick 결과 판정과 실제 teardown 사이에도 predicate를 다시 읽는다. 현재 source가 보호 대상이면 다중 창 여부와
        // 무관하게 이 surface 자체를 없애면 안 된다(다른 protected quick을 찾는 앱-전역 검사만으로는 부족).
        if holdProtectedSurfaceAfterTickFailure(surface) { return }
        if windows.count <= 1 {
            if blockGlobalTerminationForProtectedFilePanels() {
                // 종료된 마지막 일반 세션만 정리하고 protected quick session은 살린다. windows가 비어도 아래 tick은
                // quick을 계속 구동하며, quick이 해소·종료된 뒤에만 앱 종료를 다시 시도한다.
                teardownWindowSurface(surface, checkpointRemovalAlreadyCovered: checkpointRemovalAlreadyCovered)
                surface.window?.delegate = nil
                surface.window?.close()
                surface.window = nil
                return
            }
            // 마지막 창 → 앱 종료. 추가 tick이 재진입 terminate를 부르지 않게 타이머를 먼저 멈춘다(정리·요약은
            // applicationWillTerminate가 — primary가 살아 있어야 요약이 그 세션 기준. 원래 SessionEnded 경로의 안전장치).
            //
            // **이 종료는 흔적을 남긴다.** 여기는 확인 모달도 건너뛰고(`bypassQuitConfirm`) 크래시도 아니라,
            // 사용자 눈에는 앱이 그냥 사라진 것으로 보인다. 2026-08-27 에 복구 세션을 누르자 앱이 조용히
            // 종료됐는데 crash report·unified log·app.log 어디에도 단서가 없어, 이 경로에 도달했다는 사실조차
            // 소스를 읽고 추론해야 했다. 마지막 창이 닫히는 것 자체는 정상이지만 **왜 마지막이 됐는지**는 남겨야 한다.
            fputs("app: last window closed — terminating (windows=\(windows.count) token=\(surface.token) sessionNil=\(surface.appSession == nil))\n", stderr)
            bypassQuitConfirm = true // 창 닫기/세션 종료에 따른 종료 — applicationShouldTerminate가 재확인하지 않게
            tickTimer?.invalidate()
            tickTimer = nil
            smokeTimer?.invalidate()
            smokeTimer = nil
            NSApp.terminate(nil)
        } else {
            teardownWindowSurface(surface, checkpointRemovalAlreadyCovered: checkpointRemovalAlreadyCovered)
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
    // 웹 패널 생성 디버그 env 훅(MARU_WEB_PANEL — maybeDebugOpenWebPanel). 4e-5부터 web Term 생성은 command/메뉴
    // (new_web_tab)로 승격돼 drainWebSurfaceTransition 게이트는 Zig FrameSummary.web_surfaces_present(생성 신호)로
    // 판정한다(env 무관). 이 상수는 이제 **스모크 요약 경로**(writeSmokeSummary의 web 계층 단언 — env 훅으로 web Term을
    // 여는 디버그 시나리오에서만 web NSView 계층·개수·frame을 기록)에서만 쓴다(docs/plans/web-panel.md §10 4e-5·§11).
    private let webPanelHookEnabled = ProcessInfo.processInfo.environment["MARU_WEB_PANEL"] != nil
    private let filePanelHookEnabled = ProcessInfo.processInfo.environment["MARU_FILE_PANEL"] != nil

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
        guard !windows.isEmpty || quick != nil else { return }
        prepareSessionHostInputSmokePasteboard()

        // 일반 창들을 순회 tick(컬렉션 변형은 루프 뒤에서 — closeWindowOrQuit이 windows를 바꾸므로). 셸이 정상
        // 종료(SessionEnded)/fault면 그 창을 닫되, 마지막 일반 창이면 앱 종료(D4 — closeWindowOrQuit이 판정).
        let snapshot = windows
        var toClose: [TerminalSurface] = []
        for surface in snapshot {
            explicitSurface = surface
            // 마지막(유일) 일반 창 여부를 세션에 주입한다 — ⌘W/사이드바·탭바 ✕로 마지막 창 세션을 닫으면 Zig
            // requestClose가 창 하나 닫기 대신 Cmd+Q와 동일한 종료 확인을 띄운다(is_last_window 분기). 키 경로는
            // sendKeyEvent가 처리 직전 재주입해 창 생성 직후 프레임 갭까지 메우고, 마우스/메뉴 close는 이 tick 값을
            // 쓴다(창 개수 변경 후 다음 tick이 먼저 돌아 실무상 최신).
            if let s = surface.appSession {
                maru_macos_app_session_set_last_window(s, windows.count <= 1 ? 1 : 0)
                maru_macos_app_session_set_primary_window(s, surface === windows.first ? 1 : 0)
            }
            let status = renderTick()
            explicitSurface = nil
            if status == Self.statusOK {
                _ = surface.protectedTickFaultLatch.record(tickSucceeded: true, currentProtected: false)
                // 첫(메인) 창의 첫 tick에 launch 진단 요약을 한 번 남긴다.
                if surface === windows.first, !launchSummaryWritten {
                    launchSummaryWritten = true
                    withSurface(surface) {
                        writeSummary(visibleUI: surface.window != nil, abiReady: validateCachedCapabilities(), smokeDurationMs: smokeDurationMs())
                    }
                }
                continue
            }
            // SessionEnded는 우아한 종료(exitCode 0 유지), 그 외(tick_failed 등)는 세션 fault라 exitCode 1.
            // 어떤 non-OK라도 native teardown 전에 Zig-owned 파일 보호 predicate를 확인한다. faulted protected
            // surface는 유지해 일시 fault 회복을 재시도하고, clean surface만 아래 close 경로로 넘긴다.
            if status != Self.statusSessionEnded { exitCode = 1 }
            if holdProtectedSurfaceAfterTickFailure(surface, persistentTickFault: true) { continue }
            toClose.append(surface)
        }
        // 닫을 창 처리(마지막 창이면 앱 종료 — 그 경우 아래 quick tick은 건너뛴다).
        for surface in toClose { closeWindowOrQuit(surface) }
        maybeRunAgentSessionArchiveSmoke()
        maybeRunDividerSmoke()
        maybeRunScrollbarSmokeEntry()
        maybeRunTabDragSmokeEntry()
        maybeRunSessionHostRecoverySmoke()
        maybeRunSessionHostInputContinuitySmoke()
        // quick terminal — 보일 때만 tick. 그 셸이 종료/fault면 quick만 정리한다(앱은 계속 산다).
        if let quick, quick.window?.isVisible == true {
            explicitSurface = quick
            // quick(스크래치 오버레이)은 앱 종료 단위가 아니다 — 항상 비-마지막(0). quick의 마지막 탭을 닫으면 종료
            // 확인이 아니라 quick만 정리된다(tearDownQuickTerminal, 앱은 계속).
            if let s = quick.appSession { maru_macos_app_session_set_last_window(s, 0) }
            let quickStatus = renderTick()
            explicitSurface = nil
            if quickStatus == Self.statusOK {
                _ = quick.protectedTickFaultLatch.record(tickSucceeded: true, currentProtected: false)
            } else {
                if quickStatus != Self.statusSessionEnded { exitCode = 1 }
                if tearDownQuickTerminalIfUnprotected(persistentTickFault: true) {
                    if windows.isEmpty && !blockGlobalTerminationForProtectedFilePanels() {
                        bypassQuitConfirm = true
                        tickTimer?.invalidate()
                        tickTimer = nil
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        // 컨트롤 플레인 요청을 메인에서 drain한다(§5 단일 디스패치=메인 marshal). 살아있는 세션 목록(일반 창 + quick)을
        // 넘겨 Zig가 창마다 collectSessionInto로 스냅샷을 조립·auth·dispatch한다(§2 Swift는 열거만). 요청이 없으면 무동작.
        drainControlServer()
        let pumpStarted = ProcessInfo.processInfo.systemUptime
        let pumpAction = maru_macos_control_pump_browser_result() // 5f-5b: 앱 전체 tick당 progressive 결과 최대 1청크.
        if pumpAction != 0 && ProcessInfo.processInfo.environment["MARU_TEST_BROWSER_CAP"] != nil {
            browserResultPumpSamplesMs.append((ProcessInfo.processInfo.systemUptime - pumpStarted) * 1000.0)
        }
        drainBrowserOps() // 5e-2b-2: 인가된 browser op을 WKWebView로 실행 + 완료 콜백(reap 포함, 매 tick).
        drainConsoleBuffers() // §9.5.9: capture-active 패널의 page ring을 throttled로 서버 버퍼에 옮김(네비 넘어 보존).
        maybeRunBrowserControlSmoke() // 5e-2b-2 테스트 전용(MARU_TEST_BROWSER_CAP): 소켓 browser.* E2E를 1회 kick(무설정=무동작).
        maybeRunGrantSmoke() // 1e-confirm-1c-2 테스트 전용(MARU_TEST_GRANT_DECISION): 무-cap browser.navigate가 grant 흐름으로 성공하는지 1회 kick.
        // Mermaid native hot path는 allocation-free Zig gate 뒤에서만 helper completion 최대 8개와 action 하나를
        // 처리한다. process/signature/pipe I/O는 coordinator executor가 맡고 display tick은 accepted SVG를
        // 사전 할당 버퍼로 one-shot 이동해 대기 중 WebKit reply만 해소한다.
        mermaidProductTick.tick(
            coordinator: mermaidRenderCoordinator,
            drainer: mermaidAcceptedDrainer,
            consume: deliverMermaidAcceptedResult,
            consumeTerminal: deliverMermaidTerminalResult
        )
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

    func browserDidStartNavigation(_ surfaceId: UInt64) {
        finishRunningBrowserScriptsForRealmChange(surfaceId, code: 1)
        // snapshot/evaluateJavaScript 계열도 이전 document realm의 callback을 신뢰할 수 없다. navigation 시작 시 client에는
        // execution error를 보내고 registry에서 제거해, 새 문서가 뜬 뒤 늦은 success가 이전 요청을 완료하지 못하게 한다.
        finishRunningBrowserRealmCallbacks(surfaceId, result: "browser navigation interrupted operation")
    }

    func browserDidTerminateWebContent(_ surfaceId: UInt64) {
        // push_browser_crashed가 먼저 client process-exited를 commit한다. WebContent realm op만 process death를 실제 backend
        // terminal로 보며, cookie/data-store op은 NetworkProcess callback까지 슬롯을 유지해 max=8 backend bound를 지킨다.
        finishRunningBrowserScriptsForRealmChange(surfaceId, code: 3)
        finishRunningBrowserRealmCallbacks(surfaceId, result: "browser web content process terminated")
    }

    private func browserDidCloseSurface(_ surfaceId: UInt64) {
        // Zig는 먼저 client terminal=process_exited로 mark한다. 이 backend terminal은 abandoned execution의
        // reservation/slot만 회수하며, 이미 보낸 client 결과를 바꾸지 않는다.
        finishRunningBrowserScriptsForRealmChange(surfaceId, code: 2)
        finishRunningBrowserRealmCallbacks(surfaceId, result: "browser surface closed")
    }

    private func finishRunningBrowserRealmCallbacks(_ surfaceId: UInt64, result: String) {
        guard let entries = runningBrowserCallbacks[surfaceId] else { return }
        let ids = entries.compactMap { asyncId, lifetime in lifetime == .webContentRealm ? asyncId : nil }
        for asyncId in ids {
            runningBrowserCallbacks[surfaceId]?.removeValue(forKey: asyncId)
            completeBrowserOp(asyncId, status: 1, result: result)
        }
        if runningBrowserCallbacks[surfaceId]?.isEmpty == true { runningBrowserCallbacks.removeValue(forKey: surfaceId) }
    }

    private func registerRunningBrowserCallback(_ asyncId: UInt64, surfaceId: UInt64, lifetime: BrowserCallbackLifetime) {
        runningBrowserCallbacks[surfaceId, default: [:]][asyncId] = lifetime
    }

    private func takeRunningBrowserCallback(_ asyncId: UInt64, surfaceId: UInt64) -> Bool {
        guard runningBrowserCallbacks[surfaceId]?.removeValue(forKey: asyncId) != nil else { return false }
        if runningBrowserCallbacks[surfaceId]?.isEmpty == true { runningBrowserCallbacks.removeValue(forKey: surfaceId) }
        return true
    }

    private func finishRunningBrowserScriptsForRealmChange(_ surfaceId: UInt64, code: Int) {
        guard let ids = runningBrowserScripts.removeValue(forKey: surfaceId) else { return }
        let payload = BrowserResultTransferRegistry.nativeScriptErrorPayload(
            NSError(domain: "Maru.Browser.Navigation", code: code),
            kind: "navigation"
        )
        for asyncId in ids {
            completeBrowserScriptResult(asyncId, value: .scriptError(payload))
        }
    }

    private func registerRunningBrowserScript(_ asyncId: UInt64, surfaceId: UInt64) {
        runningBrowserScripts[surfaceId, default: []].insert(asyncId)
    }

    private func takeRunningBrowserScript(_ asyncId: UInt64, surfaceId: UInt64) -> Bool {
        guard runningBrowserScripts[surfaceId]?.remove(asyncId) != nil else { return false }
        if runningBrowserScripts[surfaceId]?.isEmpty == true { runningBrowserScripts.removeValue(forKey: surfaceId) }
        return true
    }

    private func hasRunningBrowserScript(_ asyncId: UInt64, surfaceId: UInt64) -> Bool {
        runningBrowserScripts[surfaceId]?.contains(asyncId) == true
    }

    /// 5e-2b-2: 컨트롤 플레인 browser op drain(매 tick). `take_browser_op`은 (1) hung op reap + (2) 큐에서 op 하나 pop을
    /// 하므로, 서버가 떠 있으면 요청 유무와 무관하게 매 tick 부른다(reap이 timeout op를 정리). op가 있으면 surface_id로
    /// 그 web 패널 WKWebView를 찾아 `BrowserControl`(op_kind)을 실행하고, 완료 시 `complete_browser_op`으로 결과를
    /// 되돌린다(navigate/getUrl은 동기 완료, executeScript는 async 콜백 — 늦은 콜백도 메인 스레드). 정책·인가·라우팅은
    /// 전부 Zig(dispatchAuthenticated→browserOpFromRequest), 여긴 op→WKWebView API 어댑터 + 완료 콜백만. 소유권:
    /// arg는 이 호출 중에만 유효(Zig 안정 슬롯)라 즉시 String으로 복사. surface 부재=status 1(error)로 완료(누설 없이).
    /// 큐가 남았을 수 있어 0 반환까지 loop drain(op ≤ max, 유한). 서버 미시작이면 첫 호출이 0 반환(무동작).
    private func drainBrowserOps() {
        guard controlServerStarted else { return }
        while true {
            var asyncId: UInt64 = 0
            var surfaceId: UInt64 = 0
            var opKind: UInt8 = 0
            var argPtr: UnsafePointer<UInt8>? = nil
            var argLen = 0
            guard maru_macos_control_take_browser_op(&asyncId, &surfaceId, &opKind, &argPtr, &argLen) == 1 else { return }
            // arg는 이 호출 중에만 유효(다음 take가 덮어씀) — 즉시 복사한다.
            let arg = (argPtr != nil && argLen > 0) ? String(decoding: UnsafeBufferPointer(start: argPtr, count: argLen), as: UTF8.self) : ""
            // surface_id로 그 web 패널을 소유한 창(일반 창·quick)을 찾는다. 없으면(패널이 닫힘 등) error로 완료.
            guard let surface = surfaceOwning(byId: surfaceId), let wp = surface.webPanels[surfaceId],
                  wp.panelKind == 1, wp.filePanelKind == 0 else {
                maru_macos_control_complete_browser_op(asyncId, opKind == 15 ? 4 : 1, nil, 0)
                continue
            }
            switch opKind {
            case 0: // navigate — 동기 완료(load 시작 여부만; 완료는 didFinish, 응답은 시작=ok).
                let ok = BrowserControl.navigate(wp.webView, url: arg)
                maru_macos_control_complete_browser_op(asyncId, ok ? 0 : 1, nil, 0)
            case 1: // getUrl — 동기(현재 문서 URL, 로드 전엔 빈).
                completeBrowserOp(asyncId, status: 0, result: BrowserControl.currentUrl(wp.webView) ?? "")
            case 4: // getCookies(5f-4c) — async 콜백(WKHTTPCookieStore.getAllCookies). result=쿠키 JSON 배열 문자열.
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .dataStore)
                BrowserControl.getCookies(wp.webView) { [weak self] json in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    self.completeBrowserOp(asyncId, status: 0, result: json)
                }
            case 2: // executeScript — page realm에서 bounded JSON을 만든 뒤 Swift registry가 Data를 소유한다.
                let navigationGeneration = wp.navigationGeneration
                registerRunningBrowserScript(asyncId, surfaceId: surfaceId)
                BrowserControl.executeScriptBounded(
                    wp.webView,
                    arg,
                    shouldStart: { [weak self] in
                        self?.hasRunningBrowserScript(asyncId, surfaceId: surfaceId) == true
                            && maru_macos_control_browser_execution_may_start(asyncId) == 1
                    }
                ) { [weak self, weak wp] result in
                    // navigation 시작이 선제 terminal을 보냈거나 다른 수명 경계가 이미 소비했으면 late callback을 버린다.
                    guard let self else { return }
                    guard self.takeRunningBrowserScript(asyncId, surfaceId: surfaceId) else { return }
                    if wp == nil || wp?.navigationGeneration != navigationGeneration {
                        let payload = BrowserResultTransferRegistry.nativeScriptErrorPayload(
                            NSError(domain: "Maru.Browser.Navigation", code: 1),
                            kind: "navigation"
                        )
                        self.completeBrowserScriptResult(asyncId, value: .scriptError(payload))
                        return
                    }
                    switch result {
                    case .success(let value):
                        self.completeBrowserScriptResult(asyncId, value: value)
                    case .failure(let error):
                        self.completeBrowserOp(asyncId, status: 1, result: error.localizedDescription)
                    }
                }
            case 5: // screenshot(5f-1) — async 콜백(takeSnapshot→PNG). arg={rect?,scale?}(§9.5.7). 성공=PNG 바이트(Zig completeScreenshotOp이 chunk-stream), 실패=status 1.
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .webContentRealm)
                BrowserControl.takeSnapshot(wp.webView, arg) { [weak self] png in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    if let png = png {
                        self.completeBrowserScreenshotResult(asyncId, data: png)
                    } else {
                        self.completeBrowserOp(asyncId, status: 1, result: "screenshot failed")
                    }
                }
            case 6: // setCookie(§9.4 D4) — async 콜백(WKHTTPCookieStore.setCookie). arg=쿠키 필드 JSON. 성공=ok, 실패=status 1.
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .dataStore)
                BrowserControl.setCookie(wp.webView, arg) { [weak self] ok in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    self.completeBrowserOp(asyncId, status: ok ? 0 : 1, result: ok ? "" : "setCookie failed")
                }
            case 7: // deleteCookie(§9.4 D4) — async 콜백(getAllCookies→delete). arg={name,domain?,path?}. 멱등(매치 0도 성공).
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .dataStore)
                BrowserControl.deleteCookie(wp.webView, arg) { [weak self] ok in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    self.completeBrowserOp(asyncId, status: ok ? 0 : 1, result: ok ? "" : "deleteCookie failed")
                }
            case 8, 9, 10: // localStorage get/set/remove(§9.4 D4) — eval 백엔드(executeScript). get 결과=value 문자열, set/remove={ok}.
                if let obj = BrowserControl.parseCookieArg(arg), let js = BrowserControl.localStorageScript(obj, op: opKind) {
                    registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .webContentRealm)
                    BrowserControl.executeScript(wp.webView, js) { [weak self] result in
                        guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                        switch result {
                        case .success(let value):
                            self.completeBrowserOp(asyncId, status: 0, result: BrowserControl.scriptResultString(value))
                        case .failure(let error):
                            self.completeBrowserOp(asyncId, status: 1, result: error.localizedDescription)
                        }
                    }
                } else {
                    self.completeBrowserOp(asyncId, status: 1, result: "localStorage bad params")
                }
            case 11: // clearStorage(§9.4 D4) — WKWebsiteDataStore로 대상 origin 데이터 삭제(멱등). {ok}.
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .dataStore)
                BrowserControl.clearStorage(wp.webView) { [weak self] ok in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    self.completeBrowserOp(asyncId, status: ok ? 0 : 1, result: ok ? "" : "clearStorage failed")
                }
            case 12, 13, 14: // click/type/scroll(act 5f-2) — eval(querySelector). result="true"(발견+동작)/"false"(미매치)→Zig {ok:bool}.
                if let obj = BrowserControl.parseCookieArg(arg), let js = BrowserControl.actScript(obj, op: opKind) {
                    registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .webContentRealm)
                    BrowserControl.executeScript(wp.webView, js) { [weak self] result in
                        guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                        switch result {
                        case .success(let value):
                            self.completeBrowserOp(asyncId, status: 0, result: BrowserControl.scriptResultString(value))
                        case .failure(let error):
                            self.completeBrowserOp(asyncId, status: 1, result: error.localizedDescription)
                        }
                    }
                } else {
                    self.completeBrowserOp(asyncId, status: 1, result: "act bad params")
                }
            case 15: // wait — selector visible 또는 현재 load idle까지 100ms 직렬 polling. status가 timeout/invalid/process-exited를 보존.
                BrowserControl.wait(wp.webView, asyncId: asyncId, argJson: arg) { status, message in
                    self.completeBrowserOp(asyncId, status: status, result: message)
                }
            case 16: // snapshot(§9.5.4·9.5.10 통일) — read-only accname DOM walk eval. snapshotScript는 JSON 문자열(tree)을 반환한다.
                // 결과를 **bounded-result transfer**(executeScript와 같은 기계)로 보낸다: registry에 raw 트리 JSON을 등록하면
                // complete_browser_result가 크기별로 inline(≤512 KiB, Zig serializeSnapshotResult가 {snapshot} embed)/chunk(초과,
                // browser.snapshotChunk 스트림) 자동 선택 → 대형 트리도 프레임 상한 안 넘김(옛 complete_browser_op inline-전용 결함 해소).
                // scriptResultString 우회 유지(JSON 이중 인코딩 방지). 실패는 complete_browser_op(status 1)로 예약 반환(executeScript 동형).
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .webContentRealm)
                BrowserControl.executeScript(wp.webView, BrowserControl.snapshotScript(arg)) { [weak self] result in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    switch result {
                    case .success(let value):
                        let treeJson = (value as? String) ?? "{\"tree\":[]}"
                        self.completeBrowserScriptResult(asyncId, value: .json(Data(treeJson.utf8)))
                    case .failure(let error):
                        self.completeBrowserOp(asyncId, status: 1, result: error.localizedDescription)
                    }
                }
            case 17: // console(§9.5.9) — 서버 버퍼 pull. capture-active로 전환(첫 pull, 이후 proactive drain 시작) + 페이지 ring
                // 최종 drain(pull 시점 최신 반영) 후 서버 버퍼를 `[{level,text}]` JSON으로 반환. arg.clear=true면 반환 뒤 비움.
                // drain eval 실패(네비 외 JS 오류)여도 이미 버퍼된 로그는 반환(로그 유실 방지) — 서버 버퍼가 값의 원천.
                wp.consoleCaptureActive = true
                let consoleClear = (BrowserControl.parseCookieArg(arg)?["clear"] as? Bool) ?? false
                registerRunningBrowserCallback(asyncId, surfaceId: surfaceId, lifetime: .webContentRealm)
                BrowserControl.executeScript(wp.webView, BrowserControl.consoleDrainScript) { [weak self, weak wp] result in
                    guard let self, self.takeRunningBrowserCallback(asyncId, surfaceId: surfaceId) else { return }
                    guard let wp = wp else { self.completeBrowserOp(asyncId, status: 0, result: "[]"); return }
                    if case .success(let value) = result { wp.appendDrainedConsole(value) }
                    let json = wp.consoleBufferJSON()
                    if consoleClear { wp.clearConsoleBuffer() }
                    // §9.5.10 통일-2: snapshot과 같은 bounded-result transfer로 반환한다. 원본 `[{level,text}]` 배열 JSON을
                    // registry에 넣으면 complete_browser_result가 크기별로 inline(≤512 KiB, serializeConsoleResult가 {console}
                    // embed)/chunk(초과, browser.consoleChunk)를 자동 선택 → 큰 로그도 프레임 상한을 안 넘김(옛 512 KiB 절단 제거).
                    self.completeBrowserScriptResult(asyncId, value: .json(Data(json.utf8)))
                }
            default: // 알 수 없는 op_kind(Zig BrowserMethod와 어긋남 — 방어) — error 완료.
                maru_macos_control_complete_browser_op(asyncId, 1, nil, 0)
            }
        }
    }

    /// §9.5.9: capture-active(첫 `browser.console` pull에서 켜짐) 웹 패널의 page-world console ring을 throttled(300ms)로
    /// read-and-clear해 서버 버퍼에 옮긴다(네비게이션이 페이지 문서를 리셋하기 전에 서버로 보존). 일반 창 + quick 전부 순회.
    /// capture-active 아닌 패널은 건너뛰어(0비용) 아무도 안 쓰는 패널에 매 tick eval을 걸지 않는다. drainBrowserOps 뒤 매 tick.
    private func drainConsoleBuffers() {
        guard controlServerStarted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for surface in windows {
            for (_, wp) in surface.webPanels { maybeDrainConsole(wp, now: now) }
        }
        if let quick {
            for (_, wp) in quick.webPanels { maybeDrainConsole(wp, now: now) }
        }
    }

    private func maybeDrainConsole(_ wp: MaruWebPanelView, now: TimeInterval) {
        guard wp.consoleCaptureActive else { return }
        guard now - wp.lastConsoleDrainAt >= MaruWebPanelView.consoleDrainInterval else { return }
        // eval 발행 전에 시각을 찍어(async 콜백을 기다리지 않고) 다음 tick의 중복 발행을 막는다 — 인플라이트 누적 방지.
        wp.lastConsoleDrainAt = now
        BrowserControl.executeScript(wp.webView, BrowserControl.consoleDrainScript) { [weak wp] result in
            guard let wp = wp else { return }
            if case .success(let value) = result { wp.appendDrainedConsole(value) }
        }
    }

    /// 5e-2b-2: `complete_browser_op`을 문자열 result 바이트로 부르는 얇은 헬퍼(getUrl/executeScript 공용). 빈 문자열도
    /// 유효(result_len=0). Zig가 status·method별로 응답을 직렬화(serializeBrowserResponse)한다.
    private func completeBrowserOp(_ asyncId: UInt64, status: UInt32, result: String) {
        let bytes = Array(result.utf8)
        bytes.withUnsafeBufferPointer { buf in
            maru_macos_control_complete_browser_op(asyncId, status, buf.baseAddress, buf.count)
        }
    }

    /// executeScript 성공 값은 fallback 문자열 없이 strict JSON으로 만들고 registry에 소유권을 둔다. Zig가 1을
    /// 반환하면 ID를 인수해 release까지 끝낸 상태다. ABI 거부 또는 release 미확인의 0 반환은 Swift가 직접 release한 뒤 실패로
    /// 마감해 pending request가 남지 않게 한다.
    private func completeBrowserScriptResult(_ asyncId: UInt64, value: BrowserPageScriptResult) {
        switch value {
        case .tooLarge(let observedAtLeast):
            maru_macos_control_complete_browser_result_too_large(asyncId, observedAtLeast)
        case .scriptError(let data):
            data.withUnsafeBytes { raw in
                maru_macos_control_complete_browser_script_error(
                    asyncId,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
        case .json(var data):
            let totalLen = data.count
            let registry = BrowserResultTransferRegistry.shared
            guard let transferId = registry.insert(data) else {
                completeBrowserOp(asyncId, status: 1, result: "browser result registry full")
                return
            }
            data = Data() // registry를 backing의 유일한 의도적 owner로 만든 뒤 Zig가 release/회계한다.
            let context = Unmanaged.passUnretained(registry).toOpaque()
            let consumed = maru_macos_control_complete_browser_result(
                asyncId,
                transferId,
                totalLen,
                context,
                browserResultCopyCallback,
                browserResultReleaseCallback
            )
            if consumed == 0 {
                registry.release(transferId)
                completeBrowserOp(asyncId, status: 1, result: "browser result transfer rejected")
            }
        }
    }

    /// 5f-1: `complete_browser_op`을 **raw 바이트**(screenshot PNG)로 부르는 헬퍼. String 헬퍼와 달리 UTF-8이 아닌 임의
    /// 바이너리 — Zig `completeScreenshotOp`이 status 0이면 이 PNG를 chunk-stream한다(§9.5.7). 빈 Data면 baseAddress nil·
    /// count 0(Zig가 비-PNG로 판정해 internal_error). `result:`(String)와 인자 레이블이 달라 오버로드 구분.
    private func completeBrowserOp(_ asyncId: UInt64, status: UInt32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            maru_macos_control_complete_browser_op(asyncId, status, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    private func completeBrowserScreenshotResult(_ asyncId: UInt64, data: Data) {
        let registry = BrowserResultTransferRegistry.shared
        guard let transferId = registry.insert(data) else {
            completeBrowserOp(asyncId, status: 1, result: "screenshot registry full")
            return
        }
        let context = Unmanaged.passUnretained(registry).toOpaque()
        let accepted = maru_macos_control_complete_browser_screenshot_result(
            asyncId,
            transferId,
            data.count,
            context,
            browserResultCopyCallback,
            browserResultReleaseCallback
        )
        if accepted == 0 {
            registry.release(transferId)
            completeBrowserOp(asyncId, status: 1, result: "screenshot transfer rejected")
        }
    }

    /// 5e-2b-2(**테스트 전용, MARU_TEST_BROWSER_CAP**): 소켓 browser.* E2E를 딱 1회 kick한다(one-shot). 스모크 + env
    /// 설정 + 서버 기동 + browser(비신뢰) web 패널 존재가 전부 충족될 때만 동작하고, 그 외(프로덕션 포함)는 즉시 반환한다.
    /// 순서: (메인) cap 발급(그 패널 surface에 묶인 browser cap nonce) + 소켓 경로 조회 → (배경 큐) 소켓 클라이언트가
    /// auth+navigate+getUrl 왕복 → 결과 저장. **배경 큐인 이유**: 소켓 read/write가 메인을 블로킹하면 tick의
    /// drainBrowserOps가 못 돌아 op이 영영 완료 안 됨(교착). cap 발급/store 접근은 §8.8대로 메인에서만 하고, 배경은
    /// 순수 소켓 I/O만 한다. env 미설정이면 test ABI가 0을 반환해 조용히 접힌다(이중 게이트).
    private func maybeRunBrowserControlSmoke() {
        guard smokeMode, !didKickBrowserCtlSmoke, controlServerStarted else { return }
        guard ProcessInfo.processInfo.environment["MARU_TEST_BROWSER_CAP"] != nil else { return }
        // browser(untrusted, panelKind==1) 활성 web 패널을 찾는다(5d fixture가 쓰는 그 패널 — cap을 이 surface에 묶는다).
        var target: (surfaceId: UInt64, url: String)?
        for surface in windows + (quick.map { [$0] } ?? []) {
            if let wp = surface.webPanels.values.first(where: { $0.panelKind == 1 && $0.filePanelKind == 0 }) {
                target = (wp.surfaceId, MaruWebPanelView.browserFixtureURL)
                break
            }
        }
        guard let t = target else { return } // 아직 패널이 안 붙음 — 다음 tick 재시도(가드는 여전히 false).
        didKickBrowserCtlSmoke = true

        // cap 발급(메인) — 그 surface에 묶인 browser cap nonce(raw 32B). env 미설정/실패면 0 → 진단 남기고 종료.
        var nonce = [UInt8](repeating: 0, count: 32)
        let issued = nonce.withUnsafeMutableBufferPointer { maru_macos_control_test_issue_browser_cap(t.surfaceId, $0.baseAddress, $0.count) }
        guard issued == 1 else { storeBrowserCtlResult(navigateOk: "error:cap-issue", getUrl: "error:cap-issue", events: "error:cap-issue"); return }
        let nonceHex = nonce.map { String(format: "%02x", $0) }.joined()

        // 소켓 경로 조회(메인).
        var pathBuf = [UInt8](repeating: 0, count: 512)
        let pathLen = pathBuf.withUnsafeMutableBufferPointer { maru_macos_control_socket_path($0.baseAddress, $0.count) }
        guard pathLen > 0 else { storeBrowserCtlResult(navigateOk: "error:socket-path", getUrl: "error:socket-path", events: "error:socket-path"); return }
        let socketPath = String(decoding: pathBuf[0 ..< pathLen], as: UTF8.self)

        // 배경 큐에서 소켓 왕복 — 메인 tick은 계속 돌며 marshal/complete한다. 결과는 lock으로 저장.
        DispatchQueue.global().async { [weak self] in
            // 각 스모크 결과를 **끝나는 즉시 저장**한다(옛 블록-끝 일괄 저장 폐기) — 뒤 스모크가 느리거나 smoke 시간이
            // 다 돼 앱이 종료돼도 이미 끝난 결과는 summary에 남는다(부분 완료 관측). console은 무거운 bounded(16 MiB)보다
            // **먼저** 돌려(navigate 직후) 부하 상황에서도 시간 예산에 굶지 않게 한다(§9.5.9).
            let r = runBrowserControlSmokeClient(socketPath: socketPath, sid: t.surfaceId, nonceHex: nonceHex, navigateURL: t.url)
            self?.storeBrowserConsoleResult(runBrowserConsoleSmokeClient(socketPath: socketPath, sid: t.surfaceId, nonceHex: nonceHex))
            self?.storeBrowserWaitResult(runBrowserWaitSmokeClient(socketPath: socketPath, sid: t.surfaceId, nonceHex: nonceHex))
            self?.storeBrowserBoundedResult(runBrowserBoundedResultSmokeClient(socketPath: socketPath, sid: t.surfaceId, nonceHex: nonceHex))
            // 5f-0b-3c: navigate 뒤(패널이 data: URL 커밋됨), 지속 연결로 subscribe→새 URL navigate→browser.navigated 수신 검증.
            let evt = runBrowserEventSmokeClient(socketPath: socketPath, sid: t.surfaceId, nonceHex: nonceHex)
            self?.storeBrowserCtlResult(navigateOk: r.navigateOk, getUrl: r.getUrl, events: evt)
        }
    }

    private nonisolated func storeBrowserConsoleResult(_ result: (capture: String, clear: String)) {
        browserCtlLock.lock()
        browserCtlConsoleCaptureStore = result.capture
        browserCtlConsoleClearStore = result.clear
        browserCtlLock.unlock()
    }

    private func browserConsoleResults() -> (capture: String, clear: String) {
        browserCtlLock.lock(); defer { browserCtlLock.unlock() }
        return (browserCtlConsoleCaptureStore, browserCtlConsoleClearStore)
    }

    /// 5e-2b-2: 배경 소켓 클라이언트가 결과를 저장(lock 보호). nonisolated — 배경 큐에서 호출.
    private nonisolated func storeBrowserCtlResult(navigateOk: String, getUrl: String, events: String) {
        browserCtlLock.lock()
        browserCtlNavigateOkStore = navigateOk
        browserCtlGetUrlStore = getUrl
        browserCtlEventsStore = events
        browserCtlLock.unlock()
    }

    /// 5e-2b-2: writeSummary(메인)가 결과를 읽는다(lock 보호). 미완이면 "pending".
    private func browserCtlResults() -> (navigateOk: String, getUrl: String, events: String) {
        browserCtlLock.lock(); defer { browserCtlLock.unlock() }
        return (browserCtlNavigateOkStore, browserCtlGetUrlStore, browserCtlEventsStore)
    }

    private nonisolated func storeBrowserWaitResult(_ result: (selector: String, load: String, timeout: String, invalidSelector: String, selectorElapsedMs: String)) {
        browserCtlLock.lock()
        browserCtlWaitSelectorStore = result.selector
        browserCtlWaitLoadStore = result.load
        browserCtlWaitTimeoutStore = result.timeout
        browserCtlWaitInvalidSelectorStore = result.invalidSelector
        browserCtlWaitElapsedStore = result.selectorElapsedMs
        browserCtlLock.unlock()
    }

    private func browserWaitResults() -> (selector: String, load: String, timeout: String, invalidSelector: String, elapsed: String) {
        browserCtlLock.lock(); defer { browserCtlLock.unlock() }
        return (browserCtlWaitSelectorStore, browserCtlWaitLoadStore, browserCtlWaitTimeoutStore, browserCtlWaitInvalidSelectorStore, browserCtlWaitElapsedStore)
    }

    private nonisolated func storeBrowserBoundedResult(_ result: (structured: String, awaitArgs: String, strictCsp: String, navigation: String, tamper: String, byteBoundary: String, tooLarge: String, executionError: String, serializationError: String, depth: String, stream: String)) {
        browserCtlLock.lock()
        browserCtlBoundedStructuredStore = result.structured
        browserCtlBoundedAwaitArgsStore = result.awaitArgs
        browserCtlBoundedStrictCspStore = result.strictCsp
        browserCtlBoundedNavigationStore = result.navigation
        browserCtlBoundedTamperStore = result.tamper
        browserCtlBoundedByteBoundaryStore = result.byteBoundary
        browserCtlBoundedTooLargeStore = result.tooLarge
        browserCtlBoundedExecutionErrorStore = result.executionError
        browserCtlBoundedSerializationErrorStore = result.serializationError
        browserCtlBoundedDepthStore = result.depth
        browserCtlBoundedStreamStore = result.stream
        browserCtlLock.unlock()
    }

    private func browserBoundedResults() -> (structured: String, awaitArgs: String, strictCsp: String, navigation: String, tamper: String, byteBoundary: String, tooLarge: String, executionError: String, serializationError: String, depth: String, stream: String) {
        browserCtlLock.lock(); defer { browserCtlLock.unlock() }
        return (browserCtlBoundedStructuredStore, browserCtlBoundedAwaitArgsStore, browserCtlBoundedStrictCspStore, browserCtlBoundedNavigationStore, browserCtlBoundedTamperStore, browserCtlBoundedByteBoundaryStore, browserCtlBoundedTooLargeStore, browserCtlBoundedExecutionErrorStore, browserCtlBoundedSerializationErrorStore, browserCtlBoundedDepthStore, browserCtlBoundedStreamStore)
    }

    /// 1e-confirm-1c-2(**테스트 전용, MARU_TEST_GRANT_DECISION**): **무-cap** browser.navigate가 pane confirm-grant 흐름으로
    /// 성공하는지 1회 kick한다. cap 발급 없이 auth.self(selector만)+navigate → 서버가 needs_grant → env 결정(approve면
    /// grant 기록+재구동→op→ok / deny면 unauthorized). 배경 큐(메인 tick이 계속 돌며 drainBrowserOps로 op 완료). env
    /// 미설정=무동작(프로덕션 무영향). MARU_TEST_BROWSER_CAP과 독립 — grant 스모크는 그 env 없이 이것만 켜고 돌린다.
    private func maybeRunGrantSmoke() {
        guard !didKickGrantSmoke, controlServerStarted else { return }
        // 무-cap navigate를 보내 grant 흐름을 유발한다. MARU_TEST_GRANT_DECISION(스텁 auto 결정 — 스모크 게이트) 또는
        // MARU_TEST_GRANT_PROMPT(**결정 env 없이 실 확인 모달**을 띄우는 손 테스트 트리거) 중 하나면 kick. 둘 다 없으면
        // 무동작(프로덕션). PROMPT는 **일반 모드도 허용**(창이 떠 있는 채로 모달을 띄워 사용자가 클릭 — 스모크 60초 auto-quit 불필요).
        let env = ProcessInfo.processInfo.environment
        let hasDecision = env["MARU_TEST_GRANT_DECISION"] != nil
        let hasPrompt = env["MARU_TEST_GRANT_PROMPT"] != nil
        guard hasDecision || hasPrompt else { return }
        guard smokeMode || hasPrompt else { return } // DECISION(auto)은 스모크 전용, PROMPT(모달 손테)는 일반 모드도
        var target: (surfaceId: UInt64, url: String)?
        for surface in windows + (quick.map { [$0] } ?? []) {
            if let wp = surface.webPanels.values.first(where: { $0.panelKind == 1 && $0.filePanelKind == 0 }) {
                target = (wp.surfaceId, MaruWebPanelView.browserFixtureURL)
                break
            }
        }
        guard let t = target else { return } // 패널 아직 — 다음 tick 재시도.
        didKickGrantSmoke = true
        var pathBuf = [UInt8](repeating: 0, count: 512)
        let pathLen = pathBuf.withUnsafeMutableBufferPointer { maru_macos_control_socket_path($0.baseAddress, $0.count) }
        guard pathLen > 0 else { storeGrantSmokeResult("error:socket-path"); return }
        let socketPath = String(decoding: pathBuf[0 ..< pathLen], as: UTF8.self)
        DispatchQueue.global().async { [weak self] in
            let r = runBrowserGrantSmokeClient(socketPath: socketPath, sid: t.surfaceId, navigateURL: t.url)
            self?.storeGrantSmokeResult(r)
        }
    }

    private nonisolated func storeGrantSmokeResult(_ v: String) {
        browserCtlLock.lock(); browserGrantNavigateOkStore = v; browserCtlLock.unlock()
    }

    private func grantSmokeResult() -> String {
        browserCtlLock.lock(); defer { browserCtlLock.unlock() }
        return browserGrantNavigateOkStore
    }

    // 현재 activeSurface(= explicitSurface)를 한 번 tick하고 그린다. 세션별 forwarder만 쓰므로 호출자가
    // explicitSurface로 대상을 정한다. 앱-전역 정책(SessionEnded 종료·summary)은 호출자(tickAppSession)가 한다.
    private func renderTick() -> Int32 {
        guard let appSession else { return Self.statusOK }
        updateDiagnosticTitle()
        updateWindowTitle() // 비-debug일 때 OSC 0/2 제목 또는 cwd basename을 제목줄에 반영

        // backing scale이 런치 후 늦게 정착/변경되면 device_scale이 옛 값에 머문다. 변했을 때만 resize.
        if (!smokeMode || isSessionHostRecoverySmokeMode), let window {
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
            // **지연 스크린샷이 걸려 있으면 매 tick 그린다.** 캡처는 renderer의 draw 안에서 일어나는데
            // (MARU_SCREENSHOT_DELAY_MS 게이트), 유휴 셸은 generation이 안 바뀌어 여기서 draw가 끊긴다 —
            // 그러면 마감이 지나도 찍을 기회 자체가 없어 프로세스가 영영 안 끝난다(실측: 2500ms 지연에
            // 5분 뒤에도 artifact 없음). 하니스 전용 경로이므로 env 미설정 일반 실행에는 분기가 없다.
            if summary.metal_generation != lastSeenMetalGeneration || metalNeedsRedraw || screenshotDelayPending {
                lastSeenMetalGeneration = summary.metal_generation
                drawMetalFrame()
            }
            drainWebSurfaceTransition() // Phase 4e-3: 이번 tick의 웹 surface 전이 batch(생성/파괴/reframe/hide/show)를 컨테이너 NSView에 적용.
            reconcileWebFocus() // Phase 4g-1: 웹↔터미널 포커스 동기 불변식(firstResponder ⟺ Zig 활성 pane). 웹 패널 없으면 무동작.
            drainOsc52Clipboard() // OSC 52: 이번 tick에 셸이 보낸 클립보드 쓰기를 NSPasteboard에 반영(정책 gate는 Zig).
            drainNotificationAuthorizationRequest() // 세팅에서 데스크톱 알림 토글을 켰으면 macOS 알림 권한을 요청한다.
            drainNotification() // OSC 9/777: 이번 tick에 셸이 보낸 데스크톱 알림을 네이티브 알림으로 띄운다.
            drainBell() // G12 BEL: 이번 tick에 셸이 보낸 벨(0x07)을 시스템 벨로 울린다.
            drainBellBadge() // BEL이 언포커스 시 울렸으면 Dock 배지를 띄운다(config bell.dock-badge).
            drainMouseHide() // 타이핑(글자 입력) 중이면 마우스 커서를 숨긴다(config input.mouse-hide-while-typing).
            drainClipboardAction() // 우클릭(input.right-click=paste·menu)이 요청한 OS 클립보드 복사/붙여넣기를 실행한다.
            drainClipboardRead() // OSC 52 읽기(osc52.read=allow): 셸 프로그램의 `?` 쿼리에 시스템 클립보드를 base64로 응답.
            drainFilePick() // 세팅 window.background-image 행 활성: NSOpenPanel(PNG)을 열어 고른 경로를 config에 적용.
            drainFilePanelPick() // open_file_panel(Cmd+O/메뉴/팔릿): Markdown/HTML을 현재 창 도크에 연다(FP5).
            drainFileTreeRootPick() // Explorer 폴더 열기/작업공간 추가: directory-only picker, 정책 검증은 Zig worker.
            drainFileTreeActions() // FP7 FSEvents roots + clean reload + unsupported external open.
            drainColorSample() // HSV picker `i`(스포이드): NSColorSampler로 화면 색을 추출해 picker에 반영(비동기).
            drainSidebarConfig() // view options(⚙) 토글이 바뀌었으면 config 파일에 반영(persist).
            drainGlobalHotkeys() // 글로벌 핫키가 라이브로 바뀌었으면(녹음/해제·reload·reset) OS에 재등록(unregister 후 register).
            drainMenuDirty() // 커맨드 카탈로그가 재빌드됐으면(rebind/unbind·reload·reset 확정) 메뉴바 keyEquivalent 다시 빌드.
            drainFilePanelZoom() // 폰트 크기(⌘+/−·config)가 바뀌었으면 열린 파일 패널 콘텐츠(편집기·프리뷰·HTML/PDF)를 같은 배율로 재적용(§2.3).
            drainQuitDecision(summary) // Cmd+Q 종료 확인 모달이 확정/취소됐으면 NSApp.reply로 종료를 진행/취소한다.
            driveWorkspaceCheckpoint()
        }
        return status
    }

    // 종료 확인 모달의 결정을 host로 한 번 전달받아 처리한다(one-shot). 두 진입점이 같은 quit_decision을 공유한다:
    //  (1) Cmd+Q/메뉴 Quit/Dock: applicationShouldTerminate가 .terminateLater로 종료를 보류(quitConfirmPending) →
    //      결정이 오면 NSApp.reply로 그 보류를 마무리한다.
    //  (2) 인앱 마지막 창 닫기(⌘W/사이드바·탭바 ✕): requestClose가 requestAppQuit으로 같은 모달을 띄웠지만 **보류된
    //      terminate가 없다**(quitConfirmPending=false) → accept면 여기서 NSApp.terminate를 시작한다(이미 확정했으므로
    //      bypassQuitConfirm으로 applicationShouldTerminate가 재확인 없이 .terminateNow). cancel이면 세션을 안 건드려 유지.
    // quit_decision(1=accepted·2=cancelled)은 모달이 떠 있던 활성 세션의 tick만 비-0을 싣는다(다른 세션은 0=대기).
    private func drainQuitDecision(_ summary: MaruAppHostFrameSummary) {
        switch summary.quit_decision {
        case 1: // accepted — 종료 진행
            // custom confirm이 열린 뒤 다른 창에서 편집이 시작될 수 있으므로 실제 AppKit 종료 승인 직전에 전 세션을
            // 다시 검사한다. 발견하면 일반 quit 결정을 폐기하고 해당 창에 notice를 띄운 뒤 fail-closed한다.
            if let protected = protectedFilePanelSurface(), let session = protected.appSession {
                protected.window?.makeKeyAndOrderFront(nil)
                // accepted Quit이 이미 Zig의 app-global detach/end-all latch를 세웠다. 앱을 계속 실행하기 전에 반드시
                // 되돌린 뒤 새 confirm을 열어 다음 close/Quit이 stale 정책을 쓰지 않게 한다.
                maru_macos_app_session_cancel_app_quit(session)
                maru_macos_app_session_request_app_quit(session)
                if quitConfirmPending {
                    quitConfirmPending = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                return
            }
            beginFinalWorkspaceCheckpoint(surface: activeSurface, deferredAppKitQuit: quitConfirmPending)
        case 2: // cancelled — 종료 취소, 앱 유지
            if quitConfirmPending {
                quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
            }
            // 인앱 경로 취소: reply할 보류가 없다(Zig가 pending_quit만 내려놓고 세션은 그대로 — 앱·창 유지).
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
    // MARK: - 접근성 어댑터 (CIM §3)
    //
    // **투영은 여기서만 한다.** Zig 는 뜻(role/label/state/집합 위치)만 싣고 `NSAccessibility` 어휘를
    // 하나도 갖지 않는다 — 그 경계는 `tests/boundary/imports.zig` 가 잠근다. 이 함수가 하는 일은 셋이다:
    // 역할 번역, 좌표계 뒤집기(Zig 는 좌상단 원점 backing px, AppKit 은 좌하단 원점 점), 그리고
    // 라벨/값 복사.
    //
    // 매 질의마다 새로 만든다. 스크린 리더는 자기 리듬으로 묻고 그 사이 프레임이 여러 번 지나가므로,
    // element 를 캐시하면 화면에 없는 줄을 읽게 된다. Zig 쪽 스냅숏이 이미 발행 시점에 굳어 있어
    // 여기서 다시 굳힐 것이 없다.
    @MainActor func accessibilityElements(in view: NSView) -> [Any] {
        guard let session = appSession else { return [] }
        let count = maru_macos_app_session_accessibility_count(session)
        if count == 0 { return [] }
        let scale = archiveSmokeRenderScale(window)
        var elements: [Any] = []
        elements.reserveCapacity(Int(count))
        for index in 0..<count {
            var record = MaruAppHostAccessibilityElement()
            guard maru_macos_app_session_accessibility_element(session, index, &record) == 0 else { continue }

            let element = NSAccessibilityElement()
            element.setAccessibilityParent(view)
            element.setAccessibilityRole(accessibilityRole(record.role))
            element.setAccessibilityLabel(accessibilityString(session, index, isValue: false))
            let value = accessibilityString(session, index, isValue: true)
            if !value.isEmpty { element.setAccessibilityValue(value) }
            element.setAccessibilityEnabled((record.flags & UInt32(MARU_APP_HOST_A11Y_FLAG_ENABLED)) != 0)
            if (record.flags & UInt32(MARU_APP_HOST_A11Y_FLAG_SELECTED)) != 0 {
                element.setAccessibilitySelected(true)
            }
            // **펼침은 개념이 있을 때만 싣는다.** 없는 줄에 `false` 를 실으면 VoiceOver 가 "접힘"이라고
            // 읽어 열 수 있는 것처럼 들린다(Zig 가 두 비트로 가르는 이유 — chrome/ui/semantics.zig).
            if (record.flags & UInt32(MARU_APP_HOST_A11Y_FLAG_EXPANDABLE)) != 0 {
                element.setAccessibilityDisclosed((record.flags & UInt32(MARU_APP_HOST_A11Y_FLAG_EXPANDED)) != 0)
            }
            if record.level > 0 { element.setAccessibilityDisclosureLevel(Int(record.level) - 1) }
            // 집합 정보 0 은 "모른다"라서 안 싣는다 — 지어내면 "1 / 1" 같은 틀린 사실을 읽는다.
            if record.set_size > 0 {
                element.setAccessibilityIndex(Int(record.position_in_set) - 1)
            }

            // 좌표: Zig 는 좌상단 원점 backing px, AppKit element frame 은 **화면 좌표(좌하단 원점 점)**다.
            let widthPt = CGFloat(record.width) / scale
            let heightPt = CGFloat(record.height) / scale
            let localX = CGFloat(record.x) / scale
            let localTop = CGFloat(record.y) / scale
            let localRect = NSRect(x: localX, y: view.bounds.height - localTop - heightPt, width: widthPt, height: heightPt)
            if let window = view.window {
                element.setAccessibilityFrame(window.convertToScreen(view.convert(localRect, to: nil)))
            } else {
                element.setAccessibilityFrame(localRect)
            }
            elements.append(element)
        }
        return elements
    }

    /// 뜻 → `NSAccessibility.Role`. **여기가 유일한 번역 자리다.**
    private func accessibilityRole(_ role: UInt32) -> NSAccessibility.Role {
        switch Int(role) {
        case MARU_APP_HOST_A11Y_ROLE_BUTTON: return .button
        // 트리·목록의 줄은 둘 다 AXRow 다. 트리라는 사실은 disclosure level 이 말한다.
        case MARU_APP_HOST_A11Y_ROLE_TREE_ITEM, MARU_APP_HOST_A11Y_ROLE_LIST_ITEM: return .row
        case MARU_APP_HOST_A11Y_ROLE_TAB: return .radioButton
        case MARU_APP_HOST_A11Y_ROLE_SCROLL_VIEW: return .scrollArea
        case MARU_APP_HOST_A11Y_ROLE_TEXT: return .staticText
        default: return .group
        }
    }

    /// 라벨·값을 Zig 저장소에서 복사해 온다. 길이를 먼저 묻고 그 크기로만 받는다 — 잘라 받으면
    /// UTF-8 경계 가운데가 잘려 리더가 깨진 글자를 읽는다(Zig 쪽이 모자란 버퍼에 아무것도 안 쓰는 이유).
    private func accessibilityString(_ session: OpaquePointer, _ index: UInt32, isValue: Bool) -> String {
        let needed = isValue
            ? maru_macos_app_session_accessibility_value(session, index, nil, 0)
            : maru_macos_app_session_accessibility_label(session, index, nil, 0)
        if needed == 0 { return "" }
        var bytes = [UInt8](repeating: 0, count: needed)
        let written = bytes.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return isValue
                ? maru_macos_app_session_accessibility_value(session, index, base, needed)
                : maru_macos_app_session_accessibility_label(session, index, base, needed)
        }
        guard written == needed else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func backingPx(_ local: NSPoint, in view: NSView) -> (x: Double, y: Double) {
        let scale = archiveSmokeRenderScale(window)
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
        // FP5: 파일 경로 중 .md/.html은 현재 창 도크로 라우팅한다. Zig가 확장자·regular-file·중복 활성화를 단일
        // 출처로 판정한다. 1=열림, 2=지원 형식이지만 실패(외부 앱 우회 금지)라 둘 다 클릭을 소비한다.
        if kind == 1 {
            let pathBytes = Array(text.utf8)
            let result = pathBytes.withUnsafeBufferPointer { p in
                maru_macos_app_session_open_file_panel_path(session, p.baseAddress, p.count)
            }
            if result != 0 {
                if result == 2 { NSSound.beep() }
                return true
            }
        }
        // v147: 웹 링크(kind==0)는 Zig 정책(config input.link-open-target)에 먼저 물어본다. 1이면 인앱 browser
        // 패널로 열기로 하고 pending action을 세웠으므로(다음 tick take_external_link_action drain이 navigate를
        // 실행한다 — 새 패널이면 그 tick의 surface 전이 batch가 WKWebView를 먼저 만든다) 클릭을 여기서 소비한다.
        // 0이면 아래 시스템 브라우저 경로로 흐른다. 정책은 Zig 단일 출처이고 Swift는 실행만 한다.
        if kind == 0 {
            let urlBytes = Array(text.utf8)
            let handled = urlBytes.withUnsafeBufferPointer { p in
                maru_macos_app_session_open_terminal_web_link(session, p.baseAddress, p.count)
            }
            if handled == 1 { return true }
        }
        // 나머지 파일 경로는 기존 기본 앱, 웹/스킴 URL은 기본 브라우저로 연다.
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

    /// 드롭을 처리한다 — 뷰(MaruMetalTerminalView.performDragOperation)가 위임한다. **드롭이 일어난 뷰의 창**
    /// surface로 스코프해서(withSurface + surfaceForView) ① pane 라우팅과 ② 내용 삽입이 같은 세션을 대상으로 하게
    /// 한다. 스코프가 없으면 forwarder(appSession)가 **key 창**을 가리키므로, 백그라운드 창에 떨어뜨린 드롭이 key
    /// 창의 pane 트리에 좌표를 hit-test하고 그 창에 붙여넣는다(quick 터미널이 key인 상태가 대표 — code-review).
    func handleDrop(_ pb: NSPasteboard, at windowPoint: NSPoint, in view: NSView) -> Bool {
        // 삽입할 내용이 아예 없으면 포커스도 건드리지 않는다 — 빈 드롭이 pane 포커스만 훔치던 것(code-review).
        guard dropHasPayload(pb) else { return false }
        var inserted = false
        withSurface(surfaceForView(view)) {
            guard let session = appSession else { return }
            // **삽입 전에** 드롭 지점의 pane/Term으로 포커스를 옮긴다(v115) — 안 그러면 어느 pane에 떨어뜨리든
            // 활성 pane에만 들어간다. 좌표는 창 좌표(draggingLocation)를 마우스 경로와 같은 backingPx로 환산해
            // 넘기고, pane 판정·가드는 좌표계 권위를 가진 Zig가 한다(routeDropAtPoint).
            let (xPx, yPx) = backingPx(view.convert(windowPoint, from: nil), in: view)
            let route = maru_macos_app_session_route_drop(session, xPx, yPx)
            // **-1 = 거부**(모달/오버레이 열림·대상이 web pane): 내용을 삽입하지 **않는다**. 거부를 무시하고
            // 삽입하면 활성 pane에 들어가 — 애초에 막으려던 오삽입이 그대로 일어난다(code-review).
            guard route >= 0 else { return }
            if route > 0 { markMetalNeedsRedraw() } // 포커스가 실제로 옮겨졌을 때만 다시 그린다
            inserted = handleDrop(pb)
        }
        return inserted
    }

    /// 이 pasteboard에 **삽입할 내용이 있는가** — 포커스를 옮기기 전에 값싸게 판정한다(빈 드롭이 pane 포커스만
    /// 훔치던 것). 비트맵은 **타입 존재만** 본다: clipboardImagePng를 부르면 TIFF/JPEG→PNG 디코드+인코드가
    /// 메인 스레드에서 돌고, 삽입 경로(pasteboardDropPayload)가 곧바로 **또 한 번** 같은 변환을 한다(code-review).
    /// 타입은 있는데 디코드가 실패하는 극단(손상 비트맵)에선 삽입이 no-op이 되고 포커스만 옮겨지지만, 그건
    /// 드롭 자체가 실패한 경우라 무해하다 — 중복 변환(멀티MB 이미지에서 수백 ms)이 더 나쁘다.
    private func dropHasPayload(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty { return true }
        if let url = pb.string(forType: .URL), !url.isEmpty { return true }
        if let text = pb.string(forType: .string), !text.isEmpty { return true }
        return pb.availableType(from: [.png, .tiff]) != nil // 디코드 없이 타입만(위 주석)
    }

    /// 드롭된 pasteboard 내용(경로/URL/텍스트)을 삽입한다 — 위 오버로드가 창 스코프 안에서 부른다.
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

    // 세팅 GUI에서 notifications.osc를 켠 경우, 사용자가 지금 데스크톱 알림을 원한다고 명시한 것이다.
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

    // OSC 9/777: 코어가 모은 데스크톱 알림(title/body/surface_id)을 활성 세션에서 drain해 네이티브
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
        var routePresent: UInt32 = 0
        var hostIdHi: UInt64 = 0
        var hostIdLo: UInt64 = 0
        var runtimeIdHi: UInt64 = 0
        var runtimeIdLo: UInt64 = 0
        var eventId: UInt64 = 0
        guard maru_macos_app_session_pending_notification(
            session,
            &has,
            &titlePtr,
            &titleLen,
            &bodyPtr,
            &bodyLen,
            &surfaceId,
            &foreground,
            &routePresent,
            &hostIdHi,
            &hostIdLo,
            &runtimeIdHi,
            &runtimeIdLo,
            &eventId
        ) == Self.statusOK,
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
        var userInfo: [String: Any] = ["wt": activeSurface?.token ?? 0, "sid": surfaceId, "fg": foreground]
        let identifier: String
        if routePresent != 0 {
            let stableHostId = String(format: "%016llx%016llx", hostIdHi, hostIdLo)
            let stableRuntimeId = String(format: "%016llx%016llx", runtimeIdHi, runtimeIdLo)
            let stableRouteInfo: [String: Any] = [
                "hid": stableHostId,
                "rid": stableRuntimeId,
                "eid": eventId,
            ]
            userInfo.merge(stableRouteInfo) { _, new in new }
            guard let stableIdentifier = Self.hostNotificationIdentifier(
                hostIdHi: hostIdHi,
                hostIdLo: hostIdLo,
                runtimeIdHi: runtimeIdHi,
                runtimeIdLo: runtimeIdLo,
                eventId: eventId
            ) else { return }
            identifier = stableIdentifier
        } else {
            // In-process, hook, and app-owned notifications have no host event identity. UUID keeps
            // consecutive notifications from one local surface distinct, as before N2b3.
            identifier = UUID().uuidString
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Shared C leaf also used by the daemon Objective-C adapter. Keeping the canonical identifier
    /// formatter below both callers prevents one side from silently creating a second OS row.
    private nonisolated static func hostNotificationIdentifier(
        hostIdHi: UInt64,
        hostIdLo: UInt64,
        runtimeIdHi: UInt64,
        runtimeIdLo: UInt64,
        eventId: UInt64
    ) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MARU_SESSION_HOST_NOTIFICATION_IDENTIFIER_CAP))
        let length = bytes.withUnsafeMutableBufferPointer { buffer in
            maru_session_host_notification_format_identifier(
                hostIdHi,
                hostIdLo,
                runtimeIdHi,
                runtimeIdLo,
                eventId,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard length > 0 else { return nil }
        return String(cString: bytes)
    }

    /// 알림 userInfo에서 (창 토큰, surface_id)를 꺼낸다(drainNotification이 실은 ["wt","sid"]를 역으로 읽는다).
    /// token이 양수일 때만 유효 — 0(미설정 sentinel)이거나 외부/레거시 알림이면 nil이라 클릭이 무시된다. 순수 함수라
    /// AppKit 의존이 없어 라우팅 파싱을 단위로 검증할 수 있다(세션 내 역조회는 Zig activate_surface가 소유 — 네이티브 최소).
    nonisolated static func parseNotificationRoute(_ userInfo: [AnyHashable: Any]) -> (token: UInt64, surfaceId: UInt64)? {
        guard let wt = (userInfo["wt"] as? NSNumber)?.uint64Value, wt != 0,
              let sid = (userInfo["sid"] as? NSNumber)?.uint64Value else { return nil }
        return (token: wt, surfaceId: sid)
    }

    /// Persisted Notification Center userInfo is untrusted input, not attach authority. Accept only
    /// the exact N2b3 scalar representation and require the request identifier to be the canonical
    /// shared-C rendering of those scalars. Display text and process-local wt/sid are never parsed as
    /// a stable handle.
    private nonisolated static func parseStableNotificationRoute(
        _ userInfo: [AnyHashable: Any],
        requestIdentifier: String
    ) -> StableNotificationRoute? {
        guard let hostText = userInfo["hid"] as? String,
              let runtimeText = userInfo["rid"] as? String,
              let eventNumber = userInfo["eid"] as? NSNumber,
              CFGetTypeID(eventNumber) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(eventNumber),
              UInt64(eventNumber.stringValue) != nil else { return nil }
        var hostIdHi: UInt64 = 0
        var hostIdLo: UInt64 = 0
        var runtimeIdHi: UInt64 = 0
        var runtimeIdLo: UInt64 = 0
        var eventId: UInt64 = 0
        let accepted = hostText.withCString { hid in
            runtimeText.withCString { rid in
                eventNumber.stringValue.withCString { eid in
                    requestIdentifier.withCString { identifier in
                        maru_session_host_notification_parse_route(
                            hid, hostText.utf8.count,
                            rid, runtimeText.utf8.count,
                            eid, eventNumber.stringValue.utf8.count,
                            identifier, requestIdentifier.utf8.count,
                            &hostIdHi, &hostIdLo,
                            &runtimeIdHi, &runtimeIdLo,
                            &eventId
                        )
                    }
                }
            }
        }
        guard accepted != 0 else { return nil }
        return StableNotificationRoute(
            hostIdHi: hostIdHi,
            hostIdLo: hostIdLo,
            runtimeIdHi: runtimeIdHi,
            runtimeIdLo: runtimeIdLo,
            eventId: eventId
        )
    }

    private func handleStableNotificationRoute(_ route: StableNotificationRoute) {
        guard stableNotificationRoutingReady else {
            if pendingStableNotificationRoutes.contains(route) { return }
            guard pendingStableNotificationRoutes.count < Self.maxPendingStableNotificationRoutes else { return }
            pendingStableNotificationRoutes.append(route)
            return
        }

        // Pass 1 probes every normal Window without mutation. Exactly one live binding may win; two
        // matches are an invalid cross-Window duplicate and fail closed before focus/topology changes.
        // The route itself is stable; eventId is identity/dedup, not capability.
        var boundSurface: TerminalSurface?
        for surface in windows {
            guard let session = surface.appSession else { continue }
            let matched = maru_macos_app_session_activate_notification_runtime(
                session,
                route.hostIdHi,
                route.hostIdLo,
                route.runtimeIdHi,
                route.runtimeIdLo,
                0
            )
            if matched == 2 { return }
            guard matched == 1 else { continue }
            if boundSurface != nil { return }
            boundSurface = surface
        }
        if let surface = boundSurface, let session = surface.appSession {
            guard maru_macos_app_session_activate_notification_runtime(
                session,
                route.hostIdHi,
                route.hostIdLo,
                route.runtimeIdHi,
                route.runtimeIdLo,
                1
            ) == 1 else { return }
            surface.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Pass 2 is primary-only and may consume one current Recovered Sessions row. Zig performs
        // fresh host.info/runtime.get validation and fails closed; there is deliberately no default
        // shell fallback for an unknown, stale, duplicate, or failed notification route.
        guard let surface = primary, let session = surface.appSession,
              maru_macos_app_session_activate_notification_runtime(
                  session,
                  route.hostIdHi,
                  route.hostIdLo,
                  route.runtimeIdHi,
                  route.runtimeIdLo,
                  2
              ) == 1 else { return }
        surface.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        withSurface(surface) { _ = renderTick() }
    }

    private func drainPendingStableNotificationRoutes() {
        guard stableNotificationRoutingReady else { return }
        let pending = pendingStableNotificationRoutes
        pendingStableNotificationRoutes.removeAll(keepingCapacity: true)
        for route in pending { handleStableNotificationRoute(route) }
    }

    // 알림 클릭 → 발신 터미널로 점프. userInfo의 (token, surface_id)에서 token으로 정확한 창(세션)을 고르고(surface.id는
    // 세션-로컬이라 token 없이 id만으론 창 간 오활성화가 난다), 창을 키로 올린 뒤 surface_id를 activate_surface로 넘겨
    // Zig가 탭/pane/Term을 활성화한다(경계: 창 활성화=Swift AppKit, 세션 내 역조회/포커스=Zig). 창/Term이 이미 닫혔으면
    // 무동작(창만 활성화). completionHandler는 모든 경로에서 호출한다(누락 시 OS 경고).
    // UNUserNotificationCenterDelegate 요구사항은 nonisolated이고 Apple 계약은 callback queue를 main으로
    // 고정하지 않는다. persisted payload를 값 타입으로 먼저 파싱한 뒤 UI/AppSession mutation을 MainActor로
    // 명시적으로 hop한다. completionHandler도 그 작업이 끝난 모든 경로에서 정확히 한 번 호출한다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let userInfo = request.content.userInfo
        let stableRoute = Self.parseStableNotificationRoute(
            userInfo,
            requestIdentifier: request.identifier
        )
        let hasStableKey = userInfo["hid"] != nil || userInfo["rid"] != nil || userInfo["eid"] != nil
        let localRoute = hasStableKey ? nil : Self.parseNotificationRoute(userInfo)
        Task { @MainActor [weak self] in
            defer { completionHandler() } // 누락 시 OS 경고 — 모든 경로에서 보장.
            guard let self else { return }
            if let stableRoute {
                self.handleStableNotificationRoute(stableRoute)
                return
            }
            // Any stable-key-shaped response that failed strict parsing is malformed persisted input.
            // Never reinterpret its possibly stale wt/sid as a local route in a new process.
            guard !hasStableKey, let route = localRoute else { return }
            guard let surface = self.surfaceForToken(route.token) else { return } // 창이 닫혔으면 무동작.
            if surface === self.quick, let panel = surface.window {
                // quick 패널은 숨김 시 화면 밖(frames.hidden)에 있어, 그냥 makeKeyAndOrderFront하면 보이지 않는 창이
                // 키를 가져간다. 숨김 상태면 정식 show 경로(슬라이드/페이드 + grid + 상태)를 태우고, 이미 보이면 키만 올린다.
                if panel.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    self.showQuickTerminalAnimated(panel) // 내부에서 makeKeyAndOrderFront + NSApp.activate 수행
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

    // 앱이 전면일 때 배너를 띄울지 결정한다. fg(Zig foreground_banner): 1=현재 보고 있지 않은 surface의 OSC라
    // 전면에서도 배너+소리로 알림 / 0=현재 보고 있는 surface의 OSC라 배너 없이 알림 센터 목록에만(.list) —
    // 자기 화면 알림 노이즈 억제. fg 누락(외부/레거시 알림)은 보수적으로 배너.
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

    // Phase 4e-3: 이번 tick의 웹 surface 전이 **batch**를 컨테이너 NSView에 적용한다. Zig가 활성 워크스페이스 탭 pane
    // 트리를 walk해 web Term 집합을 4a 순수 계산(contentRect·pxTopLeftToPtBottomLeft·surfaceDiff)으로 diff한 op들만
    // 받아 기계적으로 실행한다 — 각 웹뷰를 z-order 중간(터미널<웹뷰들<오버레이)에 삽입하고 **자기 pane 본문 rect**
    // (pt·좌하단·컨테이너 좌표)에 고정한다(4c의 활성 pane 추종 완전 제거). 창(surface)마다 web Term별 webPanels dict를
    // 들고, tick 중엔 activeSurface=explicitSurface라 대상 창이 정확하다. 콘텐츠·입력은 범위 밖(4d/Phase 5).
    private func drainWebSurfaceTransition() {
        guard let surface = activeSurface, let session = surface.appSession,
              let container = surface.window?.contentView as? MaruTerminalContainerView else { return }
        // 값싼 게이트(4e-5): env 훅(MARU_WEB_PANEL)뿐 아니라 command(new_web_tab)로 만든 web Term(env 없음)도 그려야 하므로,
        // Zig가 매 tick 실은 web_surfaces_present(살아 있는 web Term 존재 = 생성 신호) **OR** webPanels 비어있지 않음
        // (마지막 web Term이 닫힌 뒤 destroy 전이를 처리해 뷰를 제거할 때까지 지속)으로 판정한다. 둘 다 false면 batch가 늘
        // 비므로 FFI(count)+pane 트리 walk를 통째로 건너뛴다(평시 렌더 핫패스 0-FFI). 한 tick 지연(직전 tick summary)은
        // 무해하다(web Term은 여러 tick 지속, create 전이는 다음 tick 처리). — docs/plans/web-panel.md §10 4e-5 "게이트 정정".
        guard surface.latestFrameSummary.web_surfaces_present != 0 || !surface.webPanels.isEmpty else { return }
        // count가 이번 tick batch를 계산(prev 전진 = tick당 1회)한다. 이어서 at(i)로 각 전이를 읽어 적용한다.
        let count = maru_macos_app_session_web_surface_transitions_count(session)
        var i: UInt32 = 0
        while i < count {
            defer { i += 1 }
            var t = MaruAppHostWebSurfaceTransition()
            guard maru_macos_app_session_web_surface_transition_at(session, i, &t) == Self.statusOK else { continue }
            let frame = NSRect(x: t.frame_pt_x, y: t.frame_pt_y, width: t.frame_pt_w, height: t.frame_pt_h)
            switch Int(t.op) {
            case Int(MaruAppHostWebSurfaceOpCreate.rawValue):
                if let adopted = surface.webPanels[t.surface_id] {
                    // Phase 7f-1: 팝업 adopt 패널 — 이미 Swift(createWebViewWith→adoptPopupWebView)가 넘어온 config로
                    // WKWebView를 만들어 webPanels에 키잉·삽입했다(소유·시점 역전). 중복 WKWebView를 만들면 opener 링크가
                    // 끊기므로, 여기선 생성하지 않고 이 tick의 rect/seam/가시성만 반영한다(id는 앱 전역 비재사용이라 else는
                    // 항상 신규).
                    if adopted.superview == nil { container.insertWebPanel(adopted) }
                    adopted.frame = frame
                    adopted.seamEdges = t.seam_edges
                    adopted.dividerGrabLeftPt = CGFloat(t.divider_grab_left_pt)
                    adopted.dividerGrabRightPt = CGFloat(t.divider_grab_right_pt)
                    adopted.dividerGrabBottomPt = CGFloat(t.divider_grab_bottom_pt)
                    adopted.isHidden = (t.visible == 0)
                } else if let moved = detachWebPanelForReparent(t.surface_id) {
                    // 4e-4(web-panel §10): 다른 창에 살아있던 WKWebView를 훔쳐 **재부모화**(destroy+recreate 대신 = 스크롤·페이지·폼
                    // 상태 보존). 같은 view라 controller·navObservers·delegate 불변, 컨테이너·frame·가시성만 이 창 것으로 옮긴다.
                    moved.removeFromSuperview()
                    container.insertWebPanel(moved)
                    moved.frame = frame
                    moved.seamEdges = t.seam_edges
                    moved.dividerGrabLeftPt = CGFloat(t.divider_grab_left_pt)
                    moved.dividerGrabRightPt = CGFloat(t.divider_grab_right_pt)
                    moved.dividerGrabBottomPt = CGFloat(t.divider_grab_bottom_pt)
                    moved.isHidden = (t.visible == 0)
                    surface.webPanels[t.surface_id] = moved
                } else {
                    var filePathPtr: UnsafePointer<UInt8>? = nil
                    var filePathLen: size_t = 0
                    let filePanelKind = maru_macos_app_session_file_panel_entry(
                        session, t.surface_id, &filePathPtr, &filePathLen
                    )
                    let filePanelPath = filePathPtr.map {
                        String(decoding: UnsafeBufferPointer(start: $0, count: filePathLen), as: UTF8.self)
                    }
                    var langPtr: UnsafePointer<UInt8>? = nil
                    var langLen: size_t = 0
                    let hasLang = maru_macos_app_session_file_panel_language(
                        session, t.surface_id, &langPtr, &langLen
                    )
                    let filePanelLanguage: String? = (hasLang == 1) ? langPtr.map {
                        String(decoding: UnsafeBufferPointer(start: $0, count: langLen), as: UTF8.self)
                    } : nil
                    var shellKindPtr: UnsafePointer<UInt8>? = nil
                    var shellKindLen: size_t = 0
                    let hasShellKind = maru_macos_app_session_file_panel_shell_kind(
                        session, t.surface_id, &shellKindPtr, &shellKindLen
                    )
                    let filePanelShellKind: String? = (hasShellKind == 1) ? shellKindPtr.map {
                        String(decoding: UnsafeBufferPointer(start: $0, count: shellKindLen), as: UTF8.self)
                    } : nil
                    let v = MaruWebPanelView(
                        frame: frame,
                        surfaceId: t.surface_id,
                        panelKind: t.panel_kind,
                        filePanelKind: filePanelKind,
                        filePanelPath: filePanelPath,
                        filePanelLanguage: filePanelLanguage,
                        filePanelShellKind: filePanelShellKind,
                        controller: self
                    )
                    v.seamEdges = t.seam_edges // divider grab 통과용(hitTest) — 어느 가장자리가 divider에 맞닿나.
                    v.dividerGrabLeftPt = CGFloat(t.divider_grab_left_pt)
                    v.dividerGrabRightPt = CGFloat(t.divider_grab_right_pt)
                    v.dividerGrabBottomPt = CGFloat(t.divider_grab_bottom_pt)
                    container.insertWebPanel(v)
                    v.isHidden = (t.visible == 0) // 같은 pane 비활성 탭으로 만들어진 web Term은 hidden 생성(상태만 유지).
                    surface.webPanels[t.surface_id] = v
                    v.applyFilePanelMode(maru_macos_app_session_file_panel_mode(session, t.surface_id))
                    v.startInitialLoad() // dict 등록 뒤 load — bridge surface→session lookup race 차단(FP4), HTML pin 적용(FP5).
                }
            case Int(MaruAppHostWebSurfaceOpDestroy.rawValue):
                if let v = surface.webPanels[t.surface_id] {
                    if reparentWebPanelToOwningWindow(t.surface_id, v, from: surface) {
                        // 4e-4: 창 간 이동 — 파괴 않고 **대상 창 dict로 이관**(대상의 후속 create/show가 adopt로 재부모화). 원본 dict서 제거돼
                        // nav-state 루프가 이 패널을 원본 세션에 push하지 않는다(코드리뷰 [2] 오라우팅 회피). browser.closed 억제(닫힘 아님).
                        // create-steal이 안 먼저 도는 경로(미래 drag M5)를 위한 순서 독립 안전장치 — 주 경로는 대상 create-steal/teardown 이관.
                    } else {
                        // 5f-3d: 진짜 닫힘 — 소멸 직전 browser.closed 이벤트를 구독자에 push한 뒤 그 surface 구독을 정리(ABI 내부서 제거 전 push).
                        if v.panelKind == 1, v.filePanelKind == 0 {
                            maru_macos_control_push_browser_closed(t.surface_id)
                            browserDidCloseSurface(t.surface_id)
                        }
                        cancelMermaidReplies(surfaceId: t.surface_id, error: "file panel closed")
                        // 패널은 여기서 곧바로 소유권을 놓는다 — 라이브 프리뷰 폐기로 worker 종료 ack를 기다릴 이유가 없다.
                        v.removeFromSuperview()
                        v.controller = nil
                        surface.webPanels[t.surface_id] = nil
                    }
                }
            case Int(MaruAppHostWebSurfaceOpReframe.rawValue):
                if let v = surface.webPanels[t.surface_id] {
                    v.frame = frame
                    v.seamEdges = t.seam_edges // split 변화로 맞닿는 divider 가장자리가 바뀔 수 있어 reframe서 갱신.
                    v.dividerGrabLeftPt = CGFloat(t.divider_grab_left_pt)
                    v.dividerGrabRightPt = CGFloat(t.divider_grab_right_pt)
                    v.dividerGrabBottomPt = CGFloat(t.divider_grab_bottom_pt)
                }
            case Int(MaruAppHostWebSurfaceOpHide.rawValue):
                if let v = surface.webPanels[t.surface_id] {
                    v.isHidden = true
                }
            case Int(MaruAppHostWebSurfaceOpShow.rawValue):
                if let v = surface.webPanels[t.surface_id] {
                    v.isHidden = false
                    v.frame = frame
                    v.seamEdges = t.seam_edges
                    v.dividerGrabLeftPt = CGFloat(t.divider_grab_left_pt)
                    v.dividerGrabRightPt = CGFloat(t.divider_grab_right_pt)
                    v.dividerGrabBottomPt = CGFloat(t.divider_grab_bottom_pt)
                }
            default: break // None — 무동작
            }
        }
        // v125: 외부 링크 정책 결과(파일 패널 문서 안 링크 + v147부터 터미널 화면 링크가 공유하는 실행 경로).
        // in-app은 위 transition batch가 방금 생성했거나 이미 살아 있는 browser surface에 load하고, system은 사용자
        // click one-shot만 NSWorkspace로 넘긴다. **전이 batch보다 뒤**에 두는 순서가 계약이다 — 새로 만든 browser
        // Term의 WKWebView는 이 batch에서 생기므로 앞에 두면 방금 만든 패널에 load가 유실된다.
        // script/meta redirect는 delegate/renderer에서 이 경계에 도달하지 않으며 Zig도 literal HTTP(S)를 재검증한다.
        var externalLinkSid: UInt64 = 0
        var externalLinkKind: UInt32 = 0
        let externalLinkLen = webNavigateUrlBuf.withUnsafeMutableBufferPointer { p in
            maru_macos_app_session_take_external_link_action(
                session, p.baseAddress, p.count, &externalLinkSid, &externalLinkKind
            )
        }
        if externalLinkLen > 0 {
            let target = String(decoding: webNavigateUrlBuf[0 ..< Int(externalLinkLen)], as: UTF8.self)
            var delivered = false
            if externalLinkKind == 1, let wp = surface.webPanels[externalLinkSid] {
                delivered = BrowserControl.navigate(wp.webView, url: target)
            }
            // in-app 대상이 사라졌거나(요청과 drain 사이에 그 Term이 닫힘) load가 거부되면 시스템 브라우저로
            // 폴백한다 — 사용자가 누른 링크를 조용히 삼키지 않는다. kind==2(system)는 원래 이 경로다.
            if !delivered, let url = URL(string: target) {
                NSWorkspace.shared.open(url)
            }
        }
        // Phase 7e-1a: dirty한 browser 패널의 nav 상태(KVO 관측값)를 Zig에 push한다 — 핫패스라 navStateDirty만 push하고
        // 전량 push는 하지 않는다(변화 없는 tick은 FFI 0). url은 UTF-8 바이트로 marshaling(빈 문자열이면 baseAddress=nil,
        // len 0 → Zig가 빈 url로 저장). 저장 후 dirty를 내린다. 저장·prune·정책은 Zig(setWebNavState/collectWebSurfaces).
        for panel in surface.webPanels.values where panel.navStateDirty {
            let urlBytes = Array((panel.navUrl ?? "").utf8)
            urlBytes.withUnsafeBufferPointer { buf in
                _ = maru_macos_app_session_set_web_nav_state(
                    session,
                    panel.surfaceId,
                    panel.navCanGoBack ? 1 : 0,
                    panel.navCanGoForward ? 1 : 0,
                    buf.baseAddress,
                    buf.count
                )
            }
            panel.navStateDirty = false
        }

        // Phase 7e-2b: 주소창 편집 신호 drain(7e-2a Zig 코어가 세운 1회성 pending). 정책·상태는 Zig, 여기는 WebKit
        // 포커스·load 어댑터만. (1) focus-pull: 밴드 클릭 편집 진입 → 키보드 포커스를 터미널 뷰로(편집 keyDown이 Zig
        // handleKeyEvent로 흐르게; 클릭이 이미 터미널 뷰를 firstResponder로 만들지만 확정). (2) navigate: Enter →
        // BrowserControl.navigate(그 web 패널 webView, resolved url). (3) focus-restore: commit/cancel 후 웹뷰로 복원.
        if maru_macos_app_session_take_web_addr_focus_pull(session) == 1 {
            focusTerminalView(surface.window)
        }
        var navSid: UInt64 = 0
        let navLen = webNavigateUrlBuf.withUnsafeMutableBufferPointer { p in
            maru_macos_app_session_take_web_addr_navigate(session, p.baseAddress, p.count, &navSid)
        }
        if navLen > 0, let wp = surface.webPanels[navSid] {
            _ = BrowserControl.navigate(wp.webView, url: String(decoding: webNavigateUrlBuf[0 ..< Int(navLen)], as: UTF8.self))
        }
        var restoreSid: UInt64 = 0
        if maru_macos_app_session_take_web_addr_focus_restore(session, &restoreSid) == 1, let wp = surface.webPanels[restoreSid] {
            surface.window?.makeFirstResponder(wp.webView)
        }

        // Phase 7e-3: 주소창 nav 버튼 클릭 신호 drain — 밴드 좌측 버튼 존(back/forward/reload) 클릭이 활성 버튼일 때
        // Zig 코어가 세운 1회성 pending. code(0=back·1=forward·2=reload)에 따라 그 web 패널 WKWebView 히스토리 API를 호출한다.
        // 정책·surface 매핑은 Zig, 여기는 WebKit 어댑터만. -1=이번 tick 없음.
        var navActionSid: UInt64 = 0
        let navActionCode = maru_macos_app_session_take_web_nav_action(session, &navActionSid)
        if navActionCode >= 0, let wp = surface.webPanels[navActionSid] {
            switch navActionCode {
            case 0: BrowserControl.goBack(wp.webView)
            case 1: BrowserControl.goForward(wp.webView)
            case 2: BrowserControl.reload(wp.webView)
            default: break
            }
        }

        // §8 슬라이스 ②: 페이지 찾기 질의 drain. 오버레이·검색어·라우팅은 Zig, 여긴 WKWebView.find 어댑터만.
        // 결과는 completion에서 seq와 함께 돌려주고, 늦은 회신은 Zig가 버린다(우리는 판단하지 않는다).
        var findSid: UInt64 = 0
        var findBackwards: UInt32 = 0
        var findLen = 0
        let findSeq = webFindQueryBuf.withUnsafeMutableBufferPointer { p in
            maru_macos_app_session_take_web_find_query(
                session, p.baseAddress, p.count, &findLen, &findSid, &findBackwards
            )
        }
        if findSeq != 0, surface.webPanels[findSid] == nil {
            // 아직 WKWebView가 없다(방금 만든 탭). 그냥 버리면 Zig가 "보냈다"로 남겨 재시도하지 않으므로 신고한다.
            maru_macos_app_session_web_find_undeliverable(session, findSeq)
        }
        if findSeq != 0, let wp = surface.webPanels[findSid] {
            let query = String(decoding: webFindQueryBuf[0 ..< findLen], as: UTF8.self)
            // **제출한 그 surface의 세션**으로만 돌려준다(weak surface). 활성 창이 바뀐 뒤 `activeSurface`로 다시
            // 찾으면 남의 세션에 결과를 주게 되고, seq는 세션마다 0에서 시작하므로 우연히 맞아떨어질 수 있다.
            BrowserControl.find(wp.webView, query: query, backwards: findBackwards != 0) { [weak surface] found in
                MainActor.assumeIsolated {
                    guard let s = surface?.appSession else { return }
                    maru_macos_app_session_provide_web_find_result(s, findSeq, found ? 1 : 0)
                }
            }
        }

        // Focus intent는 mode/focus retry보다 먼저 drain한다. surface-less create를 기다리던 오래된 dock request와
        // 그 뒤 사용자가 누른 workspace/tree 전환이 같은 tick에 만나면 최신 구조 focus가 이긴다.
        let workspaceFocus = maru_macos_app_session_take_workspace_focus_action(session) != 0
        let treeFocus = maru_macos_app_session_take_file_tree_focus_action(session) != 0
        let treeRestoreSid = maru_macos_app_session_take_file_tree_restore_surface_action(session)
        let supersedesPendingDockFocus = workspaceFocus || treeFocus || treeRestoreSid != 0
        if supersedesPendingDockFocus { surface.pendingDockFocusActionSurfaceId = nil }

        var fileModeSid: UInt64 = 0
        let fileMode = maru_macos_app_session_take_file_panel_mode_action(session, &fileModeSid)
        if MaruWebPanelView.isKnownFilePanelMode(fileMode) {
            surface.pendingFilePanelModeAction = (fileModeSid, fileMode)
        }
        if let pending = surface.pendingFilePanelModeAction {
            let currentMode = maru_macos_app_session_file_panel_mode(session, pending.surfaceId)
            if !MaruWebPanelView.isKnownFilePanelMode(currentMode) {
                surface.pendingFilePanelModeAction = nil
            } else if let wp = surface.webPanels[pending.surfaceId] {
                wp.applyFilePanelMode(currentMode)
                surface.pendingFilePanelModeAction = nil
            }
        }

        var menuActionSid: UInt64 = 0
        let menuAction = maru_macos_app_session_take_file_menu_action(session, &menuActionSid)
        if menuAction != 0 {
            surface.webPanels[menuActionSid]?.applyFileMenuAction(menuAction)
        }

        let dockFocusSid = maru_macos_app_session_take_pending_dock_focus_action(session)
        if dockFocusSid != 0, !supersedesPendingDockFocus {
            surface.pendingDockFocusActionSurfaceId = dockFocusSid
        }
        if !supersedesPendingDockFocus, let pendingSurfaceId = surface.pendingDockFocusActionSurfaceId {
            if maru_macos_app_session_pending_dock_focus_surface(session) != pendingSurfaceId {
                surface.pendingDockFocusActionSurfaceId = nil
            } else if let wp = surface.webPanels[pendingSurfaceId], !wp.isHidden, let window = surface.window {
                    let accepted = isWebPanelFocused(wp) || window.makeFirstResponder(wp.webView)
                    if accepted {
                        let committed = maru_macos_app_session_complete_pending_dock_focus(session, pendingSurfaceId) != 0
                        if committed {
                            surface.focusedFilePanelSurfaceId = pendingSurfaceId
                            surface.filePanelFocusOverridden = false
                        } else {
                            // A newer Zig focus intent or restore/merge barrier made this native
                            // responder request stale. Return AppKit focus to the Metal view too.
                            surface.focusedFilePanelSurfaceId = nil
                            surface.filePanelFocusOverridden = false
                            focusTerminalView(window)
                        }
                        surface.pendingDockFocusActionSurfaceId = nil
                    }
            }
        }
        if workspaceFocus {
            surface.focusedFilePanelSurfaceId = nil
            surface.filePanelFocusOverridden = false
            focusTerminalView(surface.window)
        }
        // ABI v127: tree 정책/restore target은 Zig FocusOwner가 소유한다. Swift는 AppKit responder 전이만 실행한다.
        if treeFocus {
            surface.focusedFilePanelSurfaceId = nil
            surface.filePanelFocusOverridden = false
            focusTerminalView(surface.window)
        }
        if treeRestoreSid != 0 {
            if let panel = surface.webPanels[treeRestoreSid], !panel.isHidden, panel.superview != nil {
                surface.window?.makeFirstResponder(panel.webView)
                surface.focusedFilePanelSurfaceId = treeRestoreSid
                surface.filePanelFocusOverridden = false
            } else {
                // entry는 남았지만 native surface가 이미 retire된 stale restore면 workspace로 fail-closed한다.
                maru_macos_app_session_focus_workspace_input(session)
                surface.focusedFilePanelSurfaceId = nil
                surface.filePanelFocusOverridden = false
                focusTerminalView(surface.window)
            }
        }
        for _ in 0 ..< 4 {
            var requestId: UInt64 = 0
            let dirtySyncSid = maru_macos_app_session_take_file_panel_dirty_sync_action_v2(session, &requestId)
            guard dirtySyncSid != 0 else { break }
            if let panel = surface.webPanels[dirtySyncSid] {
                panel.requestFileDirtySync(requestId: requestId)
            } else if requestId != 0 {
                maru_macos_app_session_fail_file_panel_dirty_sync(session, dirtySyncSid, requestId)
            }
        }
        while true {
            var requestId: UInt64 = 0
            let saveCloseSid = maru_macos_app_session_take_file_panel_save_close_action(session, &requestId)
            guard saveCloseSid != 0 else { break }
            if let panel = surface.webPanels[saveCloseSid] {
                panel.requestFileSaveForClose(requestId: requestId)
            } else {
                maru_macos_app_session_complete_file_panel_save_close(session, saveCloseSid, requestId, 0, 0)
            }
        }
        for _ in 0 ..< 4 {
            var requestId: UInt64 = 0
            let unlockSid = maru_macos_app_session_take_file_panel_close_unlock_action(session, &requestId)
            guard unlockSid != 0 else { break }
            if let panel = surface.webPanels[unlockSid] {
                panel.unlockFileClose(requestId: requestId)
            } else {
                maru_macos_app_session_fail_file_panel_close_unlock(session, unlockSid, requestId)
            }
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
        panel.message = String(cString: maru_macos_file_pick_message(UInt32(MARU_FILE_PICK_MESSAGE_BACKGROUND_PNG)))
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let bytes = Array(path.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_provide_picked_file(session, buf.baseAddress, buf.count)
        }
    }

    // open_file_panel 액션과 완전히 빈 도크의 우상단 launcher가 공유하는 AppKit 어댑터. 확장자 필터는
    // UX용이고 최종 허용·파일 종류 판정은 Zig open_file_panel_path가 맡는다. 취소는 one-shot을 이미
    // 비웠으므로 무동작이다.
    private func drainFilePanelPick() {
        guard let session = appSession else { return }
        guard maru_macos_app_session_take_file_panel_pick_request(session) != 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // openKindForPath(file_panel_bridge.zig)의 지원 확장자를 미러한다(§2.2·§6). picker는 편의 필터일 뿐이고
        // ABI 경계가 kind·regular-file·용량을 다시 검증하므로 여기가 다소 관대해도 안전하다. 미러가 드리프트하면
        // 지원 파일이 picker에서 회색으로 보일 뿐이다.
        panel.allowedContentTypes = [
            "md", "html", "svg", // markdown·html·svg
            "txt", "text", "log", "json", // text: plain·json
            "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", // text: javascript/typescript
            "py", "css", "scss", "sass", "less", "xml", "yaml", "yml", // text: python·css·xml·yaml
            "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "avif", "heic", "heif", "tif", "tiff", // image(FP14)
            "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", // media(FP15 — OS 코덱 allowlist)
            "pdf", // pdf(FP15)
        ].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(cString: maru_macos_file_pick_message(UInt32(MARU_FILE_PICK_MESSAGE_DOCK_FILE)))
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let bytes = Array(path.utf8)
        let result = bytes.withUnsafeBufferPointer { p in
            maru_macos_app_session_open_file_panel_path(session, p.baseAddress, p.count)
        }
        if result != 1 { NSSound.beep() }
    }

    private func drainFileTreeRootPick() {
        guard let session = appSession else { return }
        let operation = maru_macos_app_session_take_file_tree_root_pick_request(session)
        guard operation == MARU_FILE_TREE_ROOT_PICK_REPLACE || operation == MARU_FILE_TREE_ROOT_PICK_ADD else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        // 문장은 Zig 가 고른다 — Swift 는 종류만 넘긴다(docs/i18n.md §7.2).
        panel.message = String(cString: maru_macos_file_pick_message(UInt32(
            operation == MARU_FILE_TREE_ROOT_PICK_REPLACE
                ? MARU_FILE_PICK_MESSAGE_EXPLORER_FOLDER
                : MARU_FILE_PICK_MESSAGE_WORKSPACE_FOLDER)))
        guard panel.runModal() == .OK, let path = panel.url?.path else {
            _ = maru_macos_app_session_provide_file_tree_root_pick(session, nil, 0)
            return
        }
        let bytes = Array(path.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_provide_file_tree_root_pick(session, buf.baseAddress, buf.count)
        }
    }

    private func drainFileTreeActions() {
        guard let session = appSession, let surface = activeSurface else { return }
        surface.fileTreeWatcher.drain(session)
        while true {
            var conflict: UInt32 = 0
            let sid = maru_macos_app_session_take_file_tree_reload_action(session, &conflict)
            guard sid != 0 else { break }
            surface.webPanels[sid]?.requestFileReload(conflict: conflict != 0)
        }
        let len = fileTreePathBuf.withUnsafeMutableBufferPointer {
            maru_macos_app_session_take_file_tree_external_open(session, $0.baseAddress, $0.count)
        }
        if len > 0, len <= fileTreePathBuf.count {
            let path = String(decoding: fileTreePathBuf[0 ..< len], as: UTF8.self)
            if isAgentSessionArchiveSmokeMode {
                // Fixture reveal must run the exact same one-shot ABI consumer, but it must not
                // open Finder or expose a local path.  The build harness passes the one synthetic
                // path only as a private allowlist comparison; summary stores counts, never it.
                if path == ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_REVEAL_PATH"] {
                    agentSessionArchiveSmokeRevealAllowedCount &+= 1
                } else {
                    agentSessionArchiveSmokeRevealRejectedCount &+= 1
                }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        if !surface.fileTreeTrashInFlight {
            var requestId: UInt64 = 0
            var expectedDevice: UInt64 = 0
            var expectedInode: UInt64 = 0
            var expectedKind: UInt32 = 0
            let trashLen = fileTreePathBuf.withUnsafeMutableBufferPointer {
                maru_macos_app_session_take_file_tree_trash_action(
                    session,
                    $0.baseAddress,
                    $0.count,
                    &requestId,
                    &expectedDevice,
                    &expectedInode,
                    &expectedKind
                )
            }
            if trashLen > 0, trashLen <= fileTreePathBuf.count {
                let stagedPath = String(decoding: fileTreePathBuf[0 ..< trashLen], as: UTF8.self)
                let requestSessionBits = UInt(bitPattern: session)
                surface.fileTreeTrashInFlight = true
                DispatchQueue.global(qos: .utility).async { [weak surface] in
                    let stagedURL = URL(fileURLWithPath: stagedPath)
                    // Foundation may return the same path URL instead of a true file-reference URL on APFS.
                    // The worker already moved the selected identity to an unpredictable, visible staging
                    // sibling, so this adapter may use that staged capability path and verifies both ends.
                    let referenceCandidate = (stagedURL as NSURL).fileReferenceURL()
                    let trashURL = referenceCandidate.map { ($0 as NSURL).isFileReferenceURL() ? $0 : stagedURL } ?? stagedURL
                    let identityMatches = fileTreeTrashIdentityMatches(
                        trashURL,
                        expectedDevice: expectedDevice,
                        expectedInode: expectedInode,
                        expectedKind: expectedKind
                    )
                    Task { @MainActor [weak surface] in
                        guard let surface else { return }
                        guard let currentSession = surface.appSession,
                              UInt(bitPattern: currentSession) == requestSessionBits,
                              let requestSession = OpaquePointer(bitPattern: requestSessionBits)
                        else {
                            surface.fileTreeTrashInFlight = false
                            return
                        }
                        guard identityMatches else {
                            surface.fileTreeTrashInFlight = false
                            reportFileTreeTrashOutcome(requestSession, requestId: requestId, outcome: .notMoved)
                            return
                        }
                        NSWorkspace.shared.recycle([trashURL]) { [weak surface] destinationURLs, _ in
                            DispatchQueue.global(qos: .utility).async {
                                // The destination mapping proves per-input success; the destination identity
                                // additionally prevents a path replacement from being committed as our item.
                                let outcome = fileTreeTrashMoveOutcome(
                                    destinationURLs,
                                    stagedURL: stagedURL,
                                    expectedDevice: expectedDevice,
                                    expectedInode: expectedInode,
                                    expectedKind: expectedKind
                                )
                                Task { @MainActor [weak surface] in
                                    guard let surface else { return }
                                    surface.fileTreeTrashInFlight = false
                                    guard let currentSession = surface.appSession,
                                          UInt(bitPattern: currentSession) == requestSessionBits,
                                          let requestSession = OpaquePointer(bitPattern: requestSessionBits)
                                    else { return }
                                    reportFileTreeTrashOutcome(requestSession, requestId: requestId, outcome: outcome)
                                }
                            }
                        }
                    }
                }
            }
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

    // 폰트 크기(⌘+/−·config)가 바뀌면(Zig applyMetricsPipeline이 file_panel_zoom_dirty를 세움) tick마다 drain해
    // 1이면 열린 파일 패널 webview 크기를 재적용한다 — 편집기 폰트 pt 재주입(refreshFilePanelSyntaxTheme) + 프리뷰
    // iframe·HTML/PDF 페이지 줌(refreshFilePanelZoom). take_command_catalog_dirty(drainMenuDirty)와 같은 1회성 신호(§2.3).
    private func drainFilePanelZoom() {
        guard let session = appSession else { return }
        if maru_macos_app_session_take_file_panel_zoom_dirty(session) != 0 {
            refreshFilePanelSyntaxTheme()
            refreshFilePanelZoom()
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
        // Browser Grants ▸(§9.2 per-grant revoke UX) — 에이전트에게 부여한 브라우저 제어 권한(pane-bound confirm-grant)을
        // **개별로** 나열·취소한다. 서브메뉴는 열릴 때마다 menuNeedsUpdate가 Zig grant store를 조회해 재생성한다(항목=활성
        // grant 1건 + "Revoke All"). 단축키 없음(메뉴 클릭 — 사용자가 신뢰를 물릴 때만).
        browserGrantsMenu.delegate = self
        browserGrantsMenu.autoenablesItems = false // 명시 isEnabled 존중(빈 상태 disabled 항목·"Revoke All" 비활성)
        let browserGrantsItem = NSMenuItem(title: "Browser Grants", action: nil, keyEquivalent: "")
        browserGrantsItem.submenu = browserGrantsMenu
        app.addItem(browserGrantsItem)
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
        file.addItem(catalogMenuItem("new_web_tab", catalog)) // 4e-5: 활성 pane에 브라우저 Term(발견성 — 기본 키바인딩 없음)
        file.addItem(.separator())
        file.addItem(catalogMenuItem("close_term", catalog))
        attachSubmenu(mainMenu, "File", file)

        // Edit — Select All/Clear은 Zig 액션(카탈로그), Copy/Paste는 네이티브(NSPasteboard 소유).
        let edit = NSMenu()
        edit.addItem(catalogMenuItem("select_all", catalog))
        // Clear(⌘K) — 화면+스크롤백 비우기. 카탈로그 항목이라 catalogMenuItem이 ⌘K chord를 그대로 표시·dispatch한다.
        edit.addItem(catalogMenuItem("clear_screen", catalog))
        edit.addItem(.separator())
        // **Cut이 없으면 ⌘X가 아무 데서도 안 먹는다.** WKWebView의 편집 단축키는 앱 Edit 메뉴 항목을 거쳐 responder
        // chain으로 오는데, 항목이 없으면 그 키는 어디에도 닿지 않는다(제보: 리치·소스 편집기에서 ⌘X 무반응).
        edit.addItem(nativeMenuItem("Cut", #selector(menuCut(_:)), key: "x", target: self))
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
        // Select All(⌘A)은 keyEquivalent가 first responder와 무관하게 발화하므로, 웹 패널 포커스면 터미널 전체 선택
        // 대신 WebKit selectAll:을 responder chain으로 넘긴다([web-panel.md] §4.2). 다른 카탈로그 액션은 불변.
        if key == "select_all", let panel = firstResponderWebPanel() {
            // 파일 패널 편집기(CM6, filePanelKind==1)는 문서를 가상화해(보이는 줄만 DOM) native selectAll:이
            // 긴 문서에서 일부만 고른다. 메뉴 Edit>Select All 클릭 경로는 DOM keydown을 안 거치므로, CM6 문서
            // 전체 선택 명령을 직접 실행하고 편집기가 없으면(읽기 프리뷰) native selectAll:로 폴백한다. (키보드
            // ⌘A는 web_editor route로 CM6가 capture 단계에서 직접 처리한다 — viewer.ts.) 브라우저/기타 패널은
            // 종전대로 native selectAll:.
            if panel.filePanelKind == 1 {
                panel.webView.callAsyncJavaScript(
                    "return window.__maruSelectAll?.() === true",
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { [weak self] result in
                    if case .success(let value) = result, value as? Bool == true { return }
                    guard let self else { return }
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                }
            } else {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            }
            return
        }
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
        if menu === browserGrantsMenu {
            rebuildBrowserGrantsMenu(menu) // §9.2 per-grant revoke — 열 때마다 grant store 스냅샷으로 재생성
            return
        }
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
            closeWindowOrQuit(src, checkpointRemovalAlreadyCovered: true)
        }
        maru_macos_workspace_checkpoint_mark_cross_window_commit()
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

    @objc private func menuCut(_ sender: Any?) {
        _ = sender
        // 웹 패널이 first responder면 WebKit이 자기 편집 영역에서 잘라낸다(표준 cut: — 편집기 자신의 되돌리기
        // 기록에 남는다). 터미널에는 잘라내기가 없다(읽기 전용 화면) — 복사만 하고 지우지 않는다.
        if firstResponderWebPanel() != nil {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            return
        }
        copySelectionToPasteboard()
    }

    @objc private func menuCopy(_ sender: Any?) {
        _ = sender
        // 웹 패널(도크·브라우저)이 first responder면 WebKit이 자기 DOM 선택을 복사하도록 표준 copy:를 responder
        // chain으로 넘긴다([web-panel.md] §4.2). 아니면 터미널/주소창 선택 복사.
        if firstResponderWebPanel() != nil {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            return
        }
        copySelectionToPasteboard()
    }

    @objc private func menuPaste(_ sender: Any?) {
        _ = sender
        // 웹 포커스면 WebKit이 편집 영역(CM6 등)에 붙여넣도록 표준 paste:를 넘긴다(read·HTML은 삽입 대상이 없어
        // no-op). 아니면 터미널 PTY 붙여넣기.
        if firstResponderWebPanel() != nil {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            return
        }
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
        refreshFilePanelSyntaxTheme() // 테마·palette가 바뀌었을 수 있으므로 열린 소스 편집기 syntax 색 갱신(§2.3).
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

    /// 서브메뉴 항목의 representedObject로 실을 grant 식별자(pane, target, scope wire). menuRevokeOneBrowserGrant가
    /// 이걸 꺼내 그 grant 하나만 취소한다(값 기반 — 인덱스 시프트에 안전).
    private struct GrantRef { let pane: UInt64; let target: UInt64; let scope: UInt8 }

    /// "Revoke All"(§9.2 revoke UX) — 부여한 **모든** pane-bound 브라우저 제어 권한을 취소한다(앱-전역 grant store, 세션
    /// 무관). 이후 browser 요청은 다시 확인 모달을 거친다. Zig가 단일 출처(control_pane_grant_store).
    @objc private func menuRevokeBrowserGrants(_ sender: Any?) {
        _ = sender
        _ = maru_macos_control_revoke_all_browser_grants()
    }

    /// 서브메뉴에서 grant **한 건**을 취소(§9.2 per-grant revoke). representedObject=GrantRef. 값 기반 revoke라 이미
    /// 없어도(예: 그 사이 surface close로 무효화) 무해(0 반환). Zig가 단일 출처.
    @objc private func menuRevokeOneBrowserGrant(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let ref = item.representedObject as? GrantRef else { return }
        _ = maru_macos_control_revoke_browser_grant(ref.pane, ref.target, ref.scope)
    }

    /// "Browser Grants" 서브메뉴 재생성(menuNeedsUpdate가 열릴 때 호출) — Zig grant store를 조회해 항목을 새로 만든다.
    /// count→grant_at으로 스냅샷을 읽어(revoke의 swap-remove로 인덱스가 바뀌므로 열 때마다 새로 읽음) 각 grant를 사람이
    /// 읽을 레이블(pane→대상 URL·scope)로 나열하고, 비면 disabled "No active grants", 끝에 separator + "Revoke All".
    private func rebuildBrowserGrantsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let count = maru_macos_control_browser_grant_count()
        if count == 0 {
            let empty = NSMenuItem(title: "No active grants", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            var i: UInt32 = 0
            while i < count {
                var pane: UInt64 = 0
                var target: UInt64 = 0
                var scope: UInt8 = 0
                guard maru_macos_control_browser_grant_at(i, &pane, &target, &scope) == 1 else { i += 1; continue }
                let item = NSMenuItem(title: grantLabel(pane: pane, target: target, scope: scope), action: #selector(menuRevokeOneBrowserGrant(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = GrantRef(pane: pane, target: target, scope: scope)
                menu.addItem(item)
                i += 1
            }
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Revoke All", action: #selector(menuRevokeBrowserGrants(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = count > 0
        menu.addItem(all)
    }

    /// grant 한 건의 메뉴 레이블. 대상 web 패널 URL host(있으면)로 "무엇을 제어 중"인지 보이고, scope를 사람 말로
    /// (browser=제어·browser_storage=쿠키·스토리지). pane은 요청 에이전트 pane surface_id(터미널이라 title 조회 없음=id).
    private func grantLabel(pane: UInt64, target: UInt64, scope: UInt8) -> String {
        let targetDesc: String
        if let host = surfaceOwning(byId: target)?.webPanels[target]?.webView.url?.host, !host.isEmpty {
            targetDesc = "\(host) (#\(target))"
        } else {
            targetDesc = "surface #\(target)"
        }
        // **영어 고정**(계약 §2) — 메뉴바는 찾아서 실행하는 자리라 번역하지 않는다. 이 항목만 한국어면
        // 같은 메뉴 안에서 언어가 섞인다(다른 항목은 전부 영어다).
        let scopeDesc = scope == 1 ? "cookies & storage" : "control"
        return "Revoke pane #\(pane) → \(targetDesc) · \(scopeDesc)"
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
        //
        // **실 창 크기로 resize**(예전엔 하드코딩 1200×720이었다): web 패널이 붙으면서 WKWebView frame이 Zig 표면(=이
        // resize가 정한 grid)의 pane rect를 따라가는데, 창은 960×600이라 1200×720 표면은 web 패널을 창 밖으로 밀어냈다
        // (런치 시 삐져나옴 — 리사이즈해야 맞던 증상). 실 창 콘텐츠 크기(makeKeyAndOrderFront 뒤라 레이아웃 완료)를 보내면
        // Zig 표면 == 창이라 web 패널이 창 안에 정확히 맞는다. resize E2E 신호(Zig까지 내려감) 목적은 그대로 유지된다.
        resizeAppSessionFromWindow()
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


    /// Drives the CIM2 divider fixture through `MaruMetalTerminalView.mouseDown/Dragged/Up`.
    /// The only ABI reads are the read-only divider probe and the split shortcut goes through the
    /// normal key path, so nothing here bypasses the capture routing this fixture is meant to prove.
    private func maybeRunDividerSmoke() {
        // `.done`에서도 계속 들어온다 — 그 뒤를 CIM2d(웹 seam pass-through)가 이어받기 때문이다.
        guard isDividerSmokeMode,
              let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }

        func probe() -> MaruAppHostDividerSmokeProbe? {
            var out = MaruAppHostDividerSmokeProbe()
            return maru_macos_app_session_divider_smoke_probe(session, &out) == Self.statusOK ? out : nil
        }

        dividerSmokeTicks += 1
        switch dividerSmokeStage {
        case .idle:
            // ⌘D — 제품 단축키 경로로 split한다.
            withSurface(surface) {
                sendKeyEvent(MaruAppHostKeyEvent(
                    codepoint: UInt32(UnicodeScalar("d").value),
                    base_codepoint: UInt32(UnicodeScalar("d").value),
                    key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
                    modifier_shift: 0,
                    modifier_control: 0,
                    modifier_option: 0,
                    modifier_command: 1,
                    is_repeat: 0,
                    raw_key_code: 2
                ))
            }
            dividerSmokeStage = .split
        case .split:
            dividerSmokeTermCount = maru_macos_app_session_agent_session_archive_smoke_term_count(session)
            guard let current = probe() else { return }
            dividerSmokeProbeStatusOK = true
            // 시작 직후 첫 ⌘D는 surface가 아직 입력을 받을 준비 전이라 삼켜질 수 있다. divider가
            // 나타날 때까지 몇 tick 간격으로 다시 보낸다(무한 재시도는 아니다 — 실패는 실패로 남는다).
            if current.present == 0 {
                dividerSmokeSplitRetries += 1
                if dividerSmokeSplitRetries % 30 == 0 && dividerSmokeSplitRetries <= 300 {
                    withSurface(surface) {
                        sendKeyEvent(MaruAppHostKeyEvent(
                            codepoint: UInt32(UnicodeScalar("d").value),
                            base_codepoint: UInt32(UnicodeScalar("d").value),
                            key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
                            modifier_shift: 0,
                            modifier_control: 0,
                            modifier_option: 0,
                            modifier_command: 1,
                            is_repeat: 0,
                            raw_key_code: 2
                        ))
                    }
                }
                return
            }
            dividerSmokeBandPresent = true
            dividerSmokeRatioBefore = current.ratio_milli
            dividerSmokeStage = .drag
        case .drag:
            guard let current = probe(), current.present != 0 else { return }
            let scale = window.backingScaleFactor
            guard scale > 0 else { return }
            let centerX = CGFloat(current.x_px) + CGFloat(current.width_px) / 2
            let centerY = CGFloat(current.y_px) + CGFloat(current.height_px) / 2

            func event(_ type: NSEvent.EventType, _ backingX: CGFloat) -> NSEvent? {
                let local = NSPoint(x: backingX / scale, y: view.bounds.height - (centerY / scale))
                return NSEvent.mouseEvent(
                    with: type,
                    location: view.convert(local, to: nil),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            }

            guard let down = event(.leftMouseDown, centerX) else { return }
            view.mouseDown(with: down)
            // 한 tick 안에서 여러 move를 흘린다. 그 수와 실제 resize 횟수가 달라야 §4.3이 지켜진 것이다.
            for step in 1...4 {
                guard let dragged = event(.leftMouseDragged, centerX - CGFloat(step) * 30) else { continue }
                view.mouseDragged(with: dragged)
            }
            if let during = probe() {
                dividerSmokeCaptureDuringDrag = during.capture_active != 0
                dividerSmokeMoveEvents = during.move_events
            }
            guard let up = event(.leftMouseUp, centerX - 120) else { return }
            view.mouseUp(with: up)

            if let after = probe() {
                dividerSmokeRatioAfter = after.ratio_milli
                dividerSmokeResizeApplications = after.resize_applications
                dividerSmokeCaptureAfterUp = after.capture_active != 0
            }
            dividerSmokeStage = .done
        case .done:
            maybeRunWebDividerSmoke(surface: surface, session: session, view: view, window: window)
        }
    }


    /// 스크롤 E2E는 divider 모드와 독립이다 — 자기 env 게이트로만 돈다.
    private func maybeRunScrollbarSmokeEntry() {
        guard isScrollbarSmokeMode, let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }
        withSurface(surface) {
            maybeRunScrollbarSmoke(session: session, view: view, window: window)
        }
    }

    private var isScrollbarSmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_SCROLLBAR_SMOKE"] == "1"
    }

    /// CIM3d — file tree scrollbar thumb을 `MaruMetalTerminalView`로 끌어 스크롤이 **tick당 1회**
    /// 적용되는지 제품 경로에서 본다. 행 값만 보는 headless fixture는 한 프레임에 몇 번 적용됐는지를
    /// 구분하지 못하므로, move 수와 재투영 수를 함께 읽는다.
    private func maybeRunScrollbarSmoke(session: OpaquePointer, view: MaruMetalTerminalView, window: NSWindow) {
        // divider/web E2E와 **같은 실행에서 돌리지 않는다**. 파일 탐색기 도크를 여는 키가 창
        // 상태를 바꿔 그쪽 단언을 깨뜨린다(실제로 `capture_after_down`이 false로 뒤집혔다) —
        // 파일 패널 스모크를 divider 스모크에서 떼어낸 것과 같은 이유다.
        guard ProcessInfo.processInfo.environment["MARU_SCROLLBAR_SMOKE"] == "1" else { return }
        guard scrollSmokeStage < 2 else { return }
        func probe() -> MaruAppHostDividerSmokeProbe? {
            var out = MaruAppHostDividerSmokeProbe()
            return maru_macos_app_session_divider_smoke_probe(session, &out) == Self.statusOK ? out : nil
        }
        guard let current = probe(), current.scrollbar_present != 0, current.scrollbar_thumb_h_px > 0 else {
            // 파일 탐색기 도크가 열려 있어야 scrollbar가 발행된다. ⌘⇧E로 열되, 첫 키는 surface가
            // 준비되기 전이라 삼켜질 수 있으므로 정해진 횟수만 다시 보낸다.
            scrollSmokeOpenRetries += 1
            if scrollSmokeOpenRetries % 30 == 1 && scrollSmokeOpenRetries <= 300, let surface = primary {
                withSurface(surface) {
                    sendKeyEvent(MaruAppHostKeyEvent(
                        codepoint: UInt32(UnicodeScalar("e").value),
                        base_codepoint: UInt32(UnicodeScalar("e").value),
                        key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
                        modifier_shift: 1,
                        modifier_control: 0,
                        modifier_option: 0,
                        modifier_command: 1,
                        is_repeat: 0,
                        raw_key_code: 14
                    ))
                }
            }
            return
        }
        scrollSmokeThumbPresent = true
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }

        scrollSmokeOffsetBefore = current.scrollbar_offset_px
        let x = CGFloat(current.scrollbar_thumb_x_px) + CGFloat(current.scrollbar_thumb_w_px) / 2
        let startY = CGFloat(current.scrollbar_thumb_y_px) + CGFloat(current.scrollbar_thumb_h_px) / 2

        func event(_ type: NSEvent.EventType, _ backingY: CGFloat) -> NSEvent? {
            let local = NSPoint(x: x / scale, y: view.bounds.height - (backingY / scale))
            return NSEvent.mouseEvent(
                with: type,
                location: view.convert(local, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        guard let down = event(.leftMouseDown, startY) else { return }
        view.mouseDown(with: down)
        // 한 tick 안에서 여러 move를 흘린다. 그 수와 실제 재투영 수가 달라야 §4.3이 지켜진 것이다.
        for step in 1...4 {
            guard let dragged = event(.leftMouseDragged, startY + CGFloat(step) * 20) else { continue }
            view.mouseDragged(with: dragged)
        }
        if let during = probe() {
            scrollSmokeCaptureDuringDrag = during.scrollbar_capture_active != 0
            scrollSmokeMoveEvents = during.scrollbar_move_events
        }
        guard let up = event(.leftMouseUp, startY + 80) else { return }
        view.mouseUp(with: up)

        if let after = probe() {
            scrollSmokeOffsetAfter = after.scrollbar_offset_px
            scrollSmokeApplications = after.scrollbar_scroll_applications
            scrollSmokeCaptureAfterUp = after.scrollbar_capture_active != 0
        }
        scrollSmokeStage = 2
    }

    /// 탭 드래그 E2E도 자기 env 게이트로만 돈다 — divider/scrollbar 스모크와 **같은 실행에 얹지 않는다**
    /// (그쪽은 split·도크로 창 상태를 바꾸고, 이쪽은 탭 바 세그먼트 좌표를 그 상태에서 읽는다).
    private func maybeRunTabDragSmokeEntry() {
        guard isTabDragSmokeMode, let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }
        withSurface(surface) {
            maybeRunTabDragSmoke(surface: surface, session: session, view: view, window: window)
        }
    }

    /// CR6c는 실제 제품 launch와 sidebar mouse 경계를 통과한다. ABI probe는 이미
    /// 발행된 rect/aggregate만 읽고, action은 이 NSEvent가 유일하게 시작한다.
    private func maybeRunSessionHostRecoverySmoke() {
        guard isSessionHostRecoverySmokeMode, sessionHostRecoverySmokeStage < 3,
              let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }
        var probe = MaruAppHostRecoveredSessionSmokeProbe()
        guard maru_macos_app_session_recovered_session_smoke_probe(session, &probe) == Self.statusOK else {
            sessionHostRecoverySmokeFailure = "probe"
            sessionHostRecoverySmokeStage = 3
            return
        }
        sessionHostRecoverySmokeKeepAliveEnabled = probe.keep_alive_enabled != 0
        sessionHostRecoverySmokeDiscoveredCandidates = probe.discovered_candidates
        sessionHostRecoverySmokeReadyAdapters = probe.ready_adapters
        sessionHostRecoverySmokeInventoryRuntimes = probe.inventory_runtimes
        sessionHostRecoverySmokeConfiguredKeepAlive = probe.configured_keep_alive != 0
        sessionHostRecoverySmokeLiveSessionCount = probe.live_session_count
        sessionHostRecoverySmokeTargetActivationDispatched = probe.target_activation_dispatched != 0
        sessionHostRecoverySmokeTargetRows = probe.recovered_count
        sessionHostRecoverySmokeTabs = probe.tab_count
        sessionHostRecoverySmokeSurfaceInitialized = probe.surface_initialized != 0
        sessionHostRecoverySmokeActiveRemoteObserved = probe.active_remote != 0
        sessionHostRecoverySmokeMarkerObserved = probe.marker_present != 0
        switch sessionHostRecoverySmokeStage {
        case 0:
            guard probe.row_present != 0, probe.recovered_count == 1,
                  probe.row_width_px > 0, probe.row_height_px > 0 else { return }
            let scale = window.backingScaleFactor
            guard scale > 0 else {
                sessionHostRecoverySmokeFailure = "scale"
                sessionHostRecoverySmokeStage = 3
                return
            }
            // 다른 실제 host가 함께 존재하는 개발 머신에서도 target row가 viewport 밖인 좌표를 직접
            // 주입해 통과시키지 않는다. 실제 NSView scroll 경로로 target을 화면 안에 들인 뒤에만 캡처와
            // click을 진행해, before artifact가 사용자가 누를 수 있는 행을 증명하게 한다.
            let viewportHeightPx = max(CGFloat(0), view.bounds.height * scale)
            let targetTopPx = CGFloat(probe.row_y_px)
            let targetBottomPx = targetTopPx + CGFloat(probe.row_height_px)
            if targetTopPx < 0 || targetTopPx >= viewportHeightPx || targetBottomPx > viewportHeightPx {
                guard dispatchSessionHostRecoveryScroll(probe, in: view, window: window, downward: true) else {
                    failSessionHostRecoverySmoke("scroll-target")
                    return
                }
                return
            }
            sessionHostRecoverySmokeRowPresent = true
            sessionHostRecoverySmokeBeforeCapture = captureSessionHostRecoverySmokeFrame("before", in: surface)
            guard sessionHostRecoverySmokeBeforeCapture else {
                sessionHostRecoverySmokeCaptureRetries += 1
                if sessionHostRecoverySmokeCaptureRetries >= 300 {
                    failSessionHostRecoverySmoke("capture-before")
                }
                return
            }
            if sessionHostRecoverySmokeRowNs == 0 {
                sessionHostRecoverySmokeRowNs = DispatchTime.now().uptimeNanoseconds
            }
            sessionHostRecoverySmokeCaptureRetries = 0
            let centerX = CGFloat(probe.row_x_px) + CGFloat(probe.row_width_px) / 2
            let centerY = CGFloat(probe.row_y_px) + CGFloat(probe.row_height_px) / 2
            let local = NSPoint(x: centerX / scale, y: view.bounds.height - centerY / scale)
            let windowPoint = view.convert(local, to: nil)
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0
            ) else {
                sessionHostRecoverySmokeFailure = "event"
                sessionHostRecoverySmokeStage = 3
                return
            }
            view.mouseDown(with: down)
            view.mouseUp(with: up)
            sessionHostRecoverySmokeClickDispatched = true
            sessionHostRecoverySmokeClickNs = DispatchTime.now().uptimeNanoseconds
            sessionHostRecoverySmokeStage = 1
        case 1:
            guard probe.recovered_count == 0, probe.tab_count >= 1,
                  probe.surface_initialized != 0, probe.active_remote != 0,
                  probe.marker_present != 0 else { return }
            sessionHostRecoverySmokeRemotePublished = true
            sessionHostRecoverySmokeMarkerPresent = true
            if sessionHostRecoverySmokeRemoteVisibleNs == 0 {
                sessionHostRecoverySmokeRemoteVisibleNs = DispatchTime.now().uptimeNanoseconds
            }
            sessionHostRecoverySmokeAfterCapture = captureSessionHostRecoverySmokeFrame("after", in: surface)
            if !sessionHostRecoverySmokeAfterCapture {
                sessionHostRecoverySmokeCaptureRetries += 1
                if sessionHostRecoverySmokeCaptureRetries >= 300 {
                    failSessionHostRecoverySmoke("capture-after")
                }
                return
            }
            sessionHostRecoverySmokeCaptureRetries = 0
            sessionHostRecoverySmokeStage = 2
            if isSessionHostInputContinuitySmokeMode { return }
            // 자동 종료도 실제 제품 Quit state machine을 통과시킨다. smokeMode의 즉시
            // NSApp.terminate만 쓰면 Zig의 app-global detach snapshot이 게시되지 않아, 테스트가
            // 방금 복구한 host runtime을 명시 close처럼 종료해 버린다. confirm을 제품 key path로
            // 수락하면 다음 tick의 drainQuitDecision이 terminate를 시작하고 remote Term은 detach된다.
            maru_macos_app_session_request_app_quit(session)
            sendKeyEvent(MaruAppHostKeyEvent(
                codepoint: 0,
                base_codepoint: 0,
                key_code: UInt32(MaruAppHostKeyCodeEnter.rawValue),
                modifier_shift: 0,
                modifier_control: 0,
                modifier_option: 0,
                modifier_command: 0,
                is_repeat: 0,
                raw_key_code: 36
            ))
        default:
            break
        }
    }

    /// Scrolls the real sidebar input route until the exact recovered target is visible. The
    /// probe supplies geometry only; scroll ownership and clamping remain in Zig's normal mouse
    /// path, so this cannot select or activate a row by itself.
    private func dispatchSessionHostRecoveryScroll(
        _ probe: MaruAppHostRecoveredSessionSmokeProbe,
        in view: MaruMetalTerminalView,
        window: NSWindow,
        downward: Bool
    ) -> Bool {
        let scale = window.backingScaleFactor
        guard scale > 0, let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: downward ? -96 : 96,
                wheel2: 0,
                wheel3: 0
              ) else { return false }
        let x = CGFloat(probe.row_x_px) + CGFloat(probe.row_width_px) / 2
        let y = max(CGFloat(1), min(view.bounds.height * scale - 1, view.bounds.height * scale / 2))
        let local = NSPoint(x: x / scale, y: view.bounds.height - y / scale)
        event.location = view.convert(local, to: nil)
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        view.scrollWheel(with: nsEvent)
        return true
    }

    @discardableResult
    private func captureSessionHostRecoverySmokeFrame(_ label: String, in surface: TerminalSurface) -> Bool {
        guard isSessionHostRecoverySmokeMode, let renderer = surface.metalRenderer else { return false }
        guard let rawRoot = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT"] else { return false }
        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
        let expectedRoot = if isSessionHostInputContinuitySmokeMode {
            "session-host-cr6d-home"
        } else if isSessionHostRecoveryBaselineMode {
            "session-host-cr6e-home"
        } else {
            "session-host-cr6c-home"
        }
        guard root.lastPathComponent == expectedRoot,
              root.deletingLastPathComponent().lastPathComponent == "maru-macos-app" else { return false }
        let dir = root.appendingPathComponent("captures", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let path = dir.appendingPathComponent(
            "session-host-recovery-\(sessionHostRecoverySmokeCaptureLabel(label)).ppm"
        ).standardizedFileURL
        guard path.deletingLastPathComponent() == dir else { return false }
        if FileManager.default.fileExists(atPath: path.path) { return true }
        guard maru_metal_renderer_request_test_capture(renderer, path.path) else { return false }
        withSurface(surface) {
            metalNeedsRedraw = true
            _ = renderTick()
        }
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func sessionHostRecoverySmokeCaptureLabel(_ label: String) -> String {
        guard let iteration = sessionHostRecoveryBaselineIteration else { return label }
        return "\(label)-\(iteration)"
    }

    /// CR6d may legitimately spend most of its deadline waiting for the user to foreground the
    /// test window. A generic smoke termination here would bypass the keep-alive detach snapshot
    /// and replace the primary focus/TCC timeout with a misleading dead-runtime failure.
    private func expireSmokeTimer() {
        if isSessionHostInputContinuitySmokeMode, sessionHostInputSmokeStage < 4 {
            failSessionHostInputSmoke("smoke-timeout")
            return
        }
        NSApp.terminate(nil)
    }

    private func failSessionHostRecoverySmoke(_ reason: String) {
        sessionHostRecoverySmokeFailure = reason
        sessionHostRecoverySmokeStage = 3
        exitCode = 1
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// CR6d의 pasteboard sentinel은 첫 session tick보다 먼저 설치한다. 그래야 복구 시 historical
    /// screen에 남아 있던 OSC 52가 재실행돼도 이 값이 바뀌는 것으로 관측할 수 있다.
    private func prepareSessionHostInputSmokePasteboard() {
        guard isSessionHostInputContinuitySmokeMode, !sessionHostInputSmokePasteboardPrepared else { return }
        let pasteboard = NSPasteboard.general
        sessionHostInputSmokeOriginalPasteboard = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        pasteboard.clearContents()
        guard pasteboard.setString("CR6D-PASTEBOARD-SENTINEL", forType: .string) else {
            failSessionHostInputSmoke("pasteboard-sentinel")
            return
        }
        sessionHostInputSmokePasteboardPrepared = true
    }

    private func restoreSessionHostInputSmokePasteboard() {
        guard isSessionHostInputContinuitySmokeMode, sessionHostInputSmokePasteboardPrepared,
              !sessionHostInputSmokePasteboardRestored,
              let snapshot = sessionHostInputSmokeOriginalPasteboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.map { fields -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in fields { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        sessionHostInputSmokePasteboardRestored = true
    }

    /// 시스템 전역 source를 바꾸는 유일한 제품-process 지점이다. CR6d opt-in과 격리된
    /// artifact root를 모두 확인한 뒤 record를 먼저 쓰므로 SIGKILL 뒤에도 부모가 복원할 수 있다.
    private func prepareSessionHostInputSmokeInputSource() -> Bool {
        guard isSessionHostInputContinuitySmokeMode,
              let rawRoot = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT"]
        else { return false }
        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
        guard root.lastPathComponent == "session-host-cr6d-home",
              root.deletingLastPathComponent().lastPathComponent == "maru-macos-app" else { return false }
        let recordURL = root.appendingPathComponent("input-source-restore.json", isDirectory: false).standardizedFileURL
        guard recordURL.deletingLastPathComponent() == root else { return false }
        do {
            let original = try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL: recordURL)
            sessionHostInputSmokeOriginalGlobalSource = original
            sessionHostInputSmokeSourceRecordURL = recordURL
            sessionHostInputSmokeGlobalSourceSelected = true
            return true
        } catch {
            sessionHostInputSmokeSourceRecordURL = recordURL
            return false
        }
    }

    /// current가 smoke-selected source일 때만 original을 복원한다. 제3 source는 사용자가 바꾼
    /// 것으로 간주해 덮지 않으며, 남은 record를 부모 helper가 같은 규칙으로 판정하게 둔다.
    @discardableResult
    private func restoreSessionHostInputSmokeInputSource() -> Bool {
        guard isSessionHostInputContinuitySmokeMode,
              sessionHostInputSmokeGlobalSourceSelected,
              let original = sessionHostInputSmokeOriginalGlobalSource,
              let recordURL = sessionHostInputSmokeSourceRecordURL else { return true }
        let outcome = SessionHostInputSourcePolicy.restore(recordURL: recordURL)
        guard outcome == .restored || outcome == .noRecord,
              SessionHostInputSourcePolicy.currentSourceID() == original,
              !FileManager.default.fileExists(atPath: recordURL.path) else { return false }
        sessionHostInputSmokeGlobalSourceRestored = true
        sessionHostInputSmokeSourceRecordCleared = true
        return true
    }

    func recordSessionHostInputSmokeMarked() {
        guard isSessionHostInputContinuitySmokeMode else { return }
        if sessionHostInputSmokeMarkedCallbacks == UInt32.max {
            failSessionHostInputSmoke("marked-overflow")
        } else {
            sessionHostInputSmokeMarkedCallbacks += 1
        }
    }

    func recordSessionHostInputSmokeInsert() {
        guard isSessionHostInputContinuitySmokeMode else { return }
        if sessionHostInputSmokeInsertCallbacks == UInt32.max {
            failSessionHostInputSmoke("insert-overflow")
        } else {
            sessionHostInputSmokeInsertCallbacks += 1
        }
    }

    /// CR6d는 CR6c가 실제 sidebar click으로 복구한 바로 그 AppKit view를 사용한다. 한글은
    /// view-local NSTextInputContext와 물리 keyCode로, paste는 실제 Cmd+V keyDown으로 넣는다.
    private func maybeRunSessionHostInputContinuitySmoke() {
        guard isSessionHostInputContinuitySmokeMode, sessionHostRecoverySmokeStage == 2,
              sessionHostInputSmokeStage < 4, let surface = primary,
              let session = surface.appSession, let view = surface.view,
              let window = surface.window else { return }
        var probe = MaruAppHostSessionHostInputSmokeProbe()
        guard maru_macos_app_session_input_smoke_probe(session, &probe) == Self.statusOK,
              probe.active_remote != 0 else {
            retrySessionHostInputSmoke("probe")
            return
        }
        sessionHostInputSmokeHistoricalCount = probe.historical_count
        sessionHostInputSmokeImeCount = probe.ime_count
        sessionHostInputSmokeClipboardCount = probe.clipboard_count
        guard probe.historical_count == 1, probe.ime_count <= 1, probe.clipboard_count <= 1 else {
            failSessionHostInputSmoke("screen-count")
            return
        }

        switch sessionHostInputSmokeStage {
        case 0:
            guard sessionHostInputSmokePasteboardPrepared else {
                failSessionHostInputSmoke("pasteboard-sentinel")
                return
            }
            let currentPasteboard = NSPasteboard.general.string(forType: .string)
            if currentPasteboard == "CR6D-HISTORICAL.OSC52" {
                failSessionHostInputSmoke("historical-osc52-replayed")
                return
            }
            let expectedPasteboard = sessionHostInputSmokeKeyIndex == 0
                ? "CR6D-PASTEBOARD-SENTINEL"
                : "CR6D-CLIPBOARD-ONCE"
            if currentPasteboard != expectedPasteboard {
                // Re-arming would erase evidence. Before Cmd+V only the historical sentinel is
                // valid; after dispatch the marker written by this smoke must remain exact.
                failSessionHostInputSmoke("pasteboard-sentinel-drift")
                return
            }
            // Recovery click publication and AppKit first-responder transfer are separate run-loop
            // effects. Do not send the real shortcut while a recovery overlay still owns input or
            // before this exact recovered view is the key responder; that would test a race rather
            // than Cmd+V continuity.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard !anyOverlayOpen, window.makeFirstResponder(view), window.firstResponder === view else {
                retrySessionHostInputSmoke("clipboard-focus")
                return
            }
            sessionHostInputSmokeHistoricalClipboardPreserved = true
            let pasteboard = NSPasteboard.general
            if sessionHostInputSmokeKeyIndex == 0 {
                pasteboard.clearContents()
                guard pasteboard.setString("CR6D-CLIPBOARD-ONCE", forType: .string),
                      dispatchSessionHostInputKey(
                        keyCode: 9, characters: "v", modifiers: .command, view: view, window: window
                      ) else {
                    failSessionHostInputSmoke("clipboard-event")
                    return
                }
                // Paste dispatch can enqueue ownership work. Return belongs to the next AppKit
                // owner turn so it cannot overtake the actual pasteboard read.
                sessionHostInputSmokeKeyIndex = 1
                return
            }
            guard dispatchSessionHostInputKey(
                keyCode: 36, characters: "\r", modifiers: [], view: view, window: window
            ) else {
                failSessionHostInputSmoke("clipboard-event")
                return
            }
            sessionHostInputSmokeKeyIndex = 0
            sessionHostInputSmokeStage = 1
            sessionHostInputSmokeRetries = 0
        case 1:
            guard probe.clipboard_count == 1 else {
                retrySessionHostInputSmoke("clipboard-timeout")
                return
            }
            guard let context = view.inputContext else {
                failSessionHostInputSmoke("input-context")
                return
            }
            sessionHostInputSmokeOriginalSource = context.selectedKeyboardInputSource
            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            guard window.makeFirstResponder(view), sessionHostInputSmokeOwnsGlobalKeyboardFocus(view: view) else {
                retrySessionHostInputSmoke("global-keyboard-focus")
                return
            }
            // Only the explicit CR6d smoke posts system HID events. Check TCC before changing the
            // system-global source so a machine without the opt-in permission is mutation-free.
            guard CGPreflightPostEventAccess() else {
                failSessionHostInputSmoke("accessibility-unavailable")
                return
            }
            sessionHostInputSmokePostEventAccess = true
            guard prepareSessionHostInputSmokeInputSource() else {
                failSessionHostInputSmoke("global-input-source")
                return
            }
            context.deactivate()
            context.selectedKeyboardInputSource = SessionHostInputSourcePolicy.korean2SetSourceID
            context.activate()
            guard context.selectedKeyboardInputSource == SessionHostInputSourcePolicy.korean2SetSourceID,
                  SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID else {
                failSessionHostInputSmoke("input-source")
                return
            }
            sessionHostInputSmokeKeyIndex = 0
            sessionHostInputSmokeStage = 3
            sessionHostInputSmokeRetries = 0
        case 3:
            // InputContext activation and each composition callback get their own AppKit run-loop
            // turn. A pre-filled NSEvent.characters string would bypass the selected IME and merely
            // insert six Latin letters, so the IME row uses HID-derived CGEvents instead.
            let keys: [UInt16] = [5, 40, 1, 15, 46, 3]
            guard let context = view.inputContext else {
                failSessionHostInputSmoke("input-context")
                return
            }
            if context.selectedKeyboardInputSource != SessionHostInputSourcePolicy.korean2SetSourceID ||
                SessionHostInputSourcePolicy.currentSourceID() != SessionHostInputSourcePolicy.korean2SetSourceID {
                context.deactivate()
                context.selectedKeyboardInputSource = SessionHostInputSourcePolicy.korean2SetSourceID
                context.activate()
                retrySessionHostInputSmoke("input-source-drift")
                return
            }
            guard sessionHostInputSmokeOwnsGlobalKeyboardFocus(view: view) else {
                NSApp.activate(ignoringOtherApps: true)
                _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
                view.window?.makeKeyAndOrderFront(nil)
                retrySessionHostInputSmoke("global-keyboard-focus-drift")
                return
            }
            if sessionHostInputSmokeKeyIndex < keys.count {
                guard dispatchSessionHostInputPhysicalKey(
                    keyCode: keys[sessionHostInputSmokeKeyIndex], view: view
                ) else {
                    failSessionHostInputSmoke("ime-event")
                    return
                }
                sessionHostInputSmokeKeyIndex += 1
                return
            }
            guard dispatchSessionHostInputPhysicalKey(keyCode: 36, view: view) else {
                failSessionHostInputSmoke("ime-enter")
                return
            }
            sessionHostInputSmokeStage = 2
            sessionHostInputSmokeRetries = 0
        case 2:
            guard probe.ime_count == 1 else {
                retrySessionHostInputSmoke("ime-timeout")
                return
            }
            guard sessionHostInputSmokeMarkedCallbacks > 0,
                  sessionHostInputSmokeInsertCallbacks > 0,
                  !view.hasMarkedText(), view.inputContext != nil else {
                failSessionHostInputSmoke("ime-callback")
                return
            }
            guard restoreSessionHostInputSmokeViewSource() else {
                failSessionHostInputSmoke("input-source-restore")
                return
            }
            guard restoreSessionHostInputSmokeInputSource() else {
                failSessionHostInputSmoke("global-input-source-restore")
                return
            }
            restoreSessionHostInputSmokePasteboard()
            sessionHostInputSmokeStage = 4
            sessionHostInputSmokeRetries = 0
            maru_macos_app_session_request_app_quit(session)
            sendKeyEvent(MaruAppHostKeyEvent(
                codepoint: 0, base_codepoint: 0,
                key_code: UInt32(MaruAppHostKeyCodeEnter.rawValue),
                modifier_shift: 0, modifier_control: 0, modifier_option: 0, modifier_command: 0,
                is_repeat: 0, raw_key_code: 36
            ))
        default:
            break
        }
    }

    private func dispatchSessionHostInputKey(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return false }
        view.keyDown(with: event)
        return true
    }

    private func dispatchSessionHostInputPhysicalKey(
        keyCode: UInt16,
        view: MaruMetalTerminalView
    ) -> Bool {
        guard view.window?.firstResponder === view else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        guard let down = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false
        ) else { return false }
        // Process-targeted or AppKit-created events bypass TSM. Posting at the HID tap is the
        // public route that makes the selected system input source produce marked/insert callbacks.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func sessionHostInputSmokeOwnsGlobalKeyboardFocus(view: MaruMetalTerminalView) -> Bool {
        sessionHostInputSmokeAppActive = NSApp.isActive
        sessionHostInputSmokeFirstResponder = view.window?.firstResponder === view
        sessionHostInputSmokeFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return sessionHostInputSmokeAppActive && sessionHostInputSmokeFirstResponder &&
            sessionHostInputSmokeFrontmostPID == getpid()
    }

    /// View-local TSM selection must be restored before the system-global source. AppKit may
    /// publish the view selection while tearing down its context; reversing this order can turn
    /// a smoke RED into a late global source drift that the parent correctly refuses to overwrite.
    @discardableResult
    private func restoreSessionHostInputSmokeViewSource() -> Bool {
        guard let original = sessionHostInputSmokeOriginalSource else { return true }
        guard let view = primary?.view, let context = view.inputContext else { return false }
        context.discardMarkedText()
        context.deactivate()
        context.selectedKeyboardInputSource = original
        context.activate()
        guard context.selectedKeyboardInputSource == original else { return false }
        sessionHostInputSmokeViewSourceRestored = true
        return true
    }

    private func retrySessionHostInputSmoke(_ reason: String) {
        if sessionHostInputSmokeRetries == UInt32.max || sessionHostInputSmokeRetries >= 600 {
            failSessionHostInputSmoke(reason)
        } else {
            sessionHostInputSmokeRetries += 1
        }
    }

    private func failSessionHostInputSmoke(_ reason: String) {
        guard sessionHostInputSmokeFailure.isEmpty else { return }
        sessionHostInputSmokeFailure = reason
        _ = restoreSessionHostInputSmokeViewSource()
        _ = restoreSessionHostInputSmokeInputSource()
        restoreSessionHostInputSmokePasteboard()
        exitCode = 1
        sessionHostInputSmokeStage = 4
        if let session = primary?.appSession {
            // A RED must still leave the recovered runtime under the same detach contract as a
            // GREEN run. Direct NSApp termination would bypass the product quit decision and can
            // turn a smoke assertion failure into an unrelated runtime-termination failure.
            maru_macos_app_session_request_app_quit(session)
            sendKeyEvent(MaruAppHostKeyEvent(
                codepoint: 0, base_codepoint: 0,
                key_code: UInt32(MaruAppHostKeyCodeEnter.rawValue),
                modifier_shift: 0, modifier_control: 0, modifier_option: 0, modifier_command: 0,
                is_repeat: 0, raw_key_code: 36
            ))
        } else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private var isTabDragSmokeMode: Bool {
        smokeMode && ProcessInfo.processInfo.environment["MARU_TAB_DRAG_SMOKE"] == "1"
    }

    /// 지금 화면(제품 Metal 합성 결과)을 fixture 디렉터리에 PPM 한 장으로 떨어뜨린다. **끄는 도중**을 찍어야
    /// 하므로 `MARU_SCREENSHOT`(내용 있는 첫 frame 한 장 뒤 종료)으로는 얻을 수 없고, renderer의 one-shot
    /// test-capture seam을 쓴다. 경로는 격리된 스모크 HOME 아래로 고정한다 — env 값이 임의 쓰기 경로가 되지
    /// 않도록 AS4-c와 같은 규율이다. 실패해도 스모크 단언에 영향을 주지 않는다(시각 증거는 부가 artifact).
    @discardableResult
    private func captureTabDragSmokeFrame(_ label: String, in surface: TerminalSurface) -> Bool {
        guard isTabDragSmokeMode, let renderer = surface.metalRenderer else { return false }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        guard home.lastPathComponent == "tab-drag-home" else { return false }
        // **쓰기 루트는 셸 하네스가 소유한다**(AS4-c와 같은 규율) — 여기서 디렉터리를 만들면 test-only 값이
        // 임의 쓰기 경로가 될 여지를 이쪽이 도로 열게 된다. 없으면 캡처를 건너뛴다.
        let dir = home.appendingPathComponent("captures", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        let path = dir.appendingPathComponent("tab-drag-\(label).ppm").standardizedFileURL
        guard path.deletingLastPathComponent() == dir,
              !FileManager.default.fileExists(atPath: path.path),
              maru_metal_renderer_request_test_capture(renderer, path.path)
        else { return false }
        withSurface(surface) {
            // 평소 frame 구성·renderer 호출 그대로다. drawMetalFrame이 세대가 같으면 건너뛰므로 한 번 깨운다.
            metalNeedsRedraw = true
            _ = renderTick()
        }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        tabDragSmokeCaptures.append("captures/tab-drag-\(label).ppm")
        return true
    }

    /// CIM4b — 탭을 실제 `NSEvent`로 끌어 §4.4 provisional live reorder를 제품 경로에서 본다.
    /// 두 가지를 본다: ① 끄는 **동안** 보이는 순서가 움직였는데 model은 그대로다(둘이 갈린다),
    /// 손을 떼면 그제서야 model이 따라온다. ② 두 번째 드래그를 Escape로 끊으면 model이 그대로다.
    /// 겨냥 좌표는 전부 probe가 돌려준 **발행 rect**에서 만든다 — 자기 산수로 겨냥하면 제품이 잡는
    /// 지점과 갈릴 수 있다(CIM2에서 실제로 밴드 중앙을 눌러 웹뷰 밖을 찍은 적이 있다).
    private func maybeRunTabDragSmoke(
        surface: TerminalSurface,
        session: OpaquePointer,
        view: MaruMetalTerminalView,
        window: NSWindow
    ) {
        guard tabDragSmokeStage < 2 else { return }
        func probe() -> MaruAppHostDividerSmokeProbe? {
            var out = MaruAppHostDividerSmokeProbe()
            return maru_macos_app_session_divider_smoke_probe(session, &out) == Self.statusOK ? out : nil
        }
        guard let current = probe() else { return }
        // 탭 3개가 필요하다(가운데를 지나 끝으로 끄는 경로라야 preview 회전이 눈에 보인다). ⌘T를 정해진
        // 횟수만 다시 보낸다 — 첫 키는 surface가 준비되기 전이라 삼켜질 수 있다.
        guard current.tab_count >= 3, current.tab_bar_present != 0, current.tab_slot_w_px > 0 else {
            tabDragSmokeSpawnRetries += 1
            if tabDragSmokeSpawnRetries % 20 == 1 && tabDragSmokeSpawnRetries <= 400 {
                sendKeyEvent(MaruAppHostKeyEvent(
                    codepoint: UInt32(UnicodeScalar("t").value),
                    base_codepoint: UInt32(UnicodeScalar("t").value),
                    key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
                    modifier_shift: 0,
                    modifier_control: 0,
                    modifier_option: 0,
                    modifier_command: 1,
                    is_repeat: 0,
                    raw_key_code: 17
                ))
            }
            return
        }
        tabDragSmokeBarPresent = true
        tabDragSmokeTabCount = current.tab_count
        // **여기서 latch한다.** 아래 시퀀스에는 `guard ... else { return }` 출구가 여럿인데, 그때 stage가
        // 미완이면 다음 tick이 down/drag/up을 이미 바뀐 상태 위에 통째로 재생한다 — 캡처는 파일이 있어 실패하고
        // (count가 4에 못 미친다) 두 번째 down이 드래그를 재-arm해, CIM4b 계약과 무관한 이유로 빨강이 된다.
        // 중간에 끊기면 요약 필드가 초기값으로 남아 그대로 빨강이 되는 편이 정직하다.
        tabDragSmokeStage = 2
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }

        let slot = CGFloat(current.tab_slot_w_px)
        let firstX = CGFloat(current.tab_first_x_px)
        let lastX = firstX + slot * CGFloat(current.tab_count - 1)
        let barY = CGFloat(current.tab_bar_y_px)

        func event(_ type: NSEvent.EventType, _ backingX: CGFloat) -> NSEvent? {
            let local = NSPoint(x: backingX / scale, y: view.bounds.height - (barY / scale))
            return NSEvent.mouseEvent(
                with: type,
                location: view.convert(local, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        // ① 끌고 있는 동안: 보이는 첫 탭은 바뀌고 model 첫 탭은 그대로여야 한다.
        tabDragSmokeModelFirstBefore = current.tab_model_first_id
        captureTabDragSmokeFrame("before", in: surface) // 드래그 전 탭 바(비교 기준)
        guard let down = event(.leftMouseDown, firstX) else { return }
        view.mouseDown(with: down)
        for step in 1...3 {
            let x = firstX + (lastX - firstX) * CGFloat(step) / 3
            guard let dragged = event(.leftMouseDragged, x) else { continue }
            view.mouseDragged(with: dragged)
        }
        // **끄는 도중**의 실제 제품 프레임 — provisional preview가 화면에 보인다는 유일한 픽셀 증거다
        // (probe는 identity만 본다). floating 고스트와 재배치된 탭 제목이 여기 들어 있다.
        captureTabDragSmokeFrame("during", in: surface)
        if let during = probe() {
            tabDragSmokeCaptureDuringDrag = during.tab_drag_active != 0
            tabDragSmokeModelFirstDuringDrag = during.tab_model_first_id
            tabDragSmokeVisibleFirstDuringDrag = during.tab_visible_first_id
            tabDragSmokePreviewDivergedDuringDrag = during.tab_visible_first_id != during.tab_model_first_id
        }
        guard let up = event(.leftMouseUp, lastX) else { return }
        view.mouseUp(with: up)
        if let after = probe() {
            tabDragSmokeCaptureAfterUp = after.tab_drag_active != 0
            tabDragSmokeModelFirstAfterCommit = after.tab_model_first_id
        }
        // commit 직후 — 고스트·drop 하이라이트가 걷히고 탭이 새 자리에 앉았는지(잔상 회귀 가드).
        captureTabDragSmokeFrame("after-commit", in: surface)

        // ② 두 번째 드래그를 Escape로 끊는다 — model은 ①의 commit 결과에서 더 움직이지 않아야 한다.
        if let down2 = event(.leftMouseDown, firstX) {
            view.mouseDown(with: down2)
            for step in 1...3 {
                let x = firstX + (lastX - firstX) * CGFloat(step) / 3
                if let dragged = event(.leftMouseDragged, x) { view.mouseDragged(with: dragged) }
            }
            sendKeyEvent(MaruAppHostKeyEvent(
                codepoint: 0,
                base_codepoint: 0,
                key_code: UInt32(MaruAppHostKeyCodeEscape.rawValue),
                modifier_shift: 0,
                modifier_control: 0,
                modifier_option: 0,
                modifier_command: 0,
                is_repeat: 0,
                raw_key_code: 53
            ))
            if let escaped = probe() {
                tabDragSmokeEscapeCaptureCleared = escaped.tab_drag_active == 0
                tabDragSmokeEscapeModelFirst = escaped.tab_model_first_id
                tabDragSmokeEscapeVisibleFirst = escaped.tab_visible_first_id
            }
            // Escape 복원 직후 — 화면이 `after-commit`과 같아야 한다(되돌아왔다는 픽셀 증거).
            captureTabDragSmokeFrame("after-escape", in: surface)
        }
    }

    /// CIM2d — 웹 패널이 divider에 맞닿은 배치에서 seam 밴드 클릭이 **아래 터미널 뷰로 통과**하는지.
    /// WKWebView는 native라 자기 frame 클릭을 삼키므로, 이 통과가 없으면 divider를 잡을 수 없다.
    /// 통과 판정은 `hitTest` 조회 결과로 하고, 그 뒤 같은 좌표의 실제 down이 capture를 만드는지 본다.
    private func maybeRunWebDividerSmoke(
        surface: TerminalSurface,
        session: OpaquePointer,
        view: MaruMetalTerminalView,
        window: NSWindow
    ) {
        guard webDividerSmokeStage < 2 else { return }

        if webDividerSmokeStage == 0 {
            // ⌘⌥T — 활성 pane에 브라우저 Term. divider 스모크가 이미 split해 뒀으므로 이 pane은
            // 반드시 한쪽 divider에 맞닿는다.
            webDividerSmokeRetries += 1
            if surface.webPanels.isEmpty {
                if webDividerSmokeRetries % 30 == 1 && webDividerSmokeRetries <= 300 {
                    withSurface(surface) {
                        sendKeyEvent(MaruAppHostKeyEvent(
                            codepoint: UInt32(UnicodeScalar("t").value),
                            base_codepoint: UInt32(UnicodeScalar("t").value),
                            key_code: UInt32(MaruAppHostKeyCodeUnknown.rawValue),
                            modifier_shift: 0,
                            modifier_control: 0,
                            modifier_option: 1,
                            modifier_command: 1,
                            is_repeat: 0,
                            raw_key_code: 17
                        ))
                    }
                }
                return
            }
            webDividerSmokeStage = 1
            return
        }

        guard let panel = surface.webPanels.values.first, let contentView = window.contentView else { return }
        webDividerPanelPresent = true
        webDividerSeamEdges = panel.seamEdges
        guard panel.seamEdges != 0 else { return }

        // 겨냥할 좌표는 **divider가 실제로 있는 자리**다 — 웹 패널 frame에서 유추하지 않는다. CIM2c의
        // probe가 발행된 밴드를 그대로 주므로 그 중앙을 쓴다.
        var probe = MaruAppHostDividerSmokeProbe()
        guard maru_macos_app_session_divider_smoke_probe(session, &probe) == Self.statusOK, probe.present != 0 else { return }
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }
        // 밴드 **중앙**은 divider 선 자체라 웹뷰가 seam만큼 물러난 그 자리에는 웹뷰가 없다. 덮인
        // 구간은 밴드의 한쪽 끝(패널이 있는 쪽)이므로 양 끝을 후보로 두고 실제로 패널 안에 드는
        // 쪽을 고른다 — 그 점이라야 `isInDividerGrabBand`의 통과가 시험된다.
        let bandY = CGFloat(probe.y_px) + CGFloat(probe.height_px) / 2
        func toLocal(_ backingX: CGFloat) -> NSPoint {
            NSPoint(x: backingX / scale, y: view.bounds.height - (bandY / scale))
        }
        var local = toLocal(CGFloat(probe.x_px) + CGFloat(probe.width_px) / 2)
        for candidate in [CGFloat(probe.x_px) + 1, CGFloat(probe.x_px) + CGFloat(probe.width_px) - 1] {
            let point = toLocal(candidate)
            if panel.bounds.contains(panel.convert(point, from: view)) {
                local = point
                break
            }
        }

        // 이 fixture는 window padding 0으로 돈다. 그래야 WKWebView가 seam까지 차올라 divider를 덮고,
        // `isInDividerGrabBand`의 통과가 **실제로 시험된다** — padding이 divider를 노출하는 기본
        // 구성에서는 애초에 웹뷰가 그 자리에 없어 아무것도 증명하지 못한다.
        let inPanel = panel.convert(local, from: view)
        webDividerHitTestOverPanel = panel.bounds.contains(inPanel)

        // hitTest가 웹 패널(또는 그 자손)을 돌려주면 divider는 영영 잡히지 않는다.
        let hit = contentView.hitTest(contentView.convert(local, from: view))
        var isWebPanelHit = false
        var walk: NSView? = hit
        while let candidate = walk {
            if candidate === panel { isWebPanelHit = true; break }
            walk = candidate.superview
        }
        webDividerHitTestPassedThrough = !isWebPanelHit
        webDividerPadding = "l=\(probe.padding_left_px) r=\(probe.padding_right_px)"
        webDividerCovered = probe.web_covered_dividers

        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(local, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            view.mouseDown(with: down)
            var after = MaruAppHostDividerSmokeProbe()
            if maru_macos_app_session_divider_smoke_probe(session, &after) == Self.statusOK {
                webDividerCaptureAfterDown = after.capture_active != 0
            }
            if let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: view.convert(local, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) {
                view.mouseUp(with: up)
            }
        }
        webDividerSmokeStage = 2
    }

    /// Drives the archive fixture through `MaruMetalTerminalView.mouseDown/up`, never by calling
    /// a Zig domain method directly. The only ABI reads are read-only published probes and the
    /// gate is one-way worker synchronization; opening the dock/disclosure remains normal pointer input.
    private func maybeRunAgentSessionArchiveSmoke() {
        guard let driver = agentSessionArchiveSmokeDriver, let surface = primary,
              let session = surface.appSession, let view = surface.view, let window = surface.window else { return }
        withSurface(surface) {
            driver.tick(
                probe: { target in
                    var out = MaruAppHostAgentSessionArchiveSmokeProbe()
                    let status = maru_macos_app_session_agent_session_archive_smoke_probe(session, target, &out)
                    return status == Self.statusOK ? out : nil
                },
                sessionInvariant: {
                    let activeSurfaceId = maru_macos_app_session_agent_session_archive_smoke_active_surface_id(session)
                    let termCount = maru_macos_app_session_agent_session_archive_smoke_term_count(session)
                    guard activeSurfaceId != 0, termCount != 0 else { return nil }
                    return .init(activeSurfaceId: activeSurfaceId, termCount: termCount)
                },
                setGate: { blocked in
                    maru_macos_app_session_set_agent_session_archive_detail_smoke_gate(session, blocked ? 1 : 0) == Self.statusOK
                },
                gateReached: {
                    maru_macos_app_session_agent_session_archive_detail_smoke_gate_reached(session) != 0
                },
                setScanGate: { blocked in
                    maru_macos_app_session_set_agent_session_archive_smoke_gate(session, blocked ? 1 : 0) == Self.statusOK
                },
                scanGateReached: {
                    maru_macos_app_session_agent_session_archive_smoke_gate_reached(session) != 0
                },
                click: { probe in
                    self.dispatchArchiveSmokeClick(probe, in: view, window: window)
                },
                pointerDown: { probe in
                    self.dispatchArchiveSmokePointerDown(probe, in: view, window: window)
                },
                pointerUp: { probe in
                    self.dispatchArchiveSmokePointerUp(probe, in: view, window: window)
                },
                preciseScroll: { probe in
                    self.dispatchArchiveSmokePreciseScroll(probe, in: view, window: window)
                },
                shortcut: { shortcut in
                    self.dispatchArchiveSmokeShortcut(shortcut, in: view, window: window)
                },
                fakeResumeVerdict: {
                    self.archiveSmokeFakeResumeVerdict()
                },
                revealAllowedCount: {
                    self.agentSessionArchiveSmokeRevealAllowedCount
                },
                revealRejectedCount: {
                    self.agentSessionArchiveSmokeRevealRejectedCount
                },
                staleRevealCount: {
                    let count = maru_macos_app_session_agent_session_archive_smoke_stale_reveal_count(session)
                    self.agentSessionArchiveSmokeStaleRevealCount = count
                    return count
                },
                claudeModelMetadataPresent: {
                    let present = maru_macos_app_session_agent_session_archive_smoke_claude_model_present(session) != 0
                    self.agentSessionArchiveSmokeClaudeModelPresent = present ? 1 : 0
                    return present
                },
                replaceRevealSource: {
                    self.replaceArchiveSmokeRevealSource()
                },
                reorderArchiveSnapshot: {
                    self.reorderArchiveSmokeSnapshot()
                },
                captureGeometry: {
                    self.writeArchiveSmokeFontScaleGeometry(session: session, window: window)
                },
                capture: { state in
                    self.captureAgentSessionArchiveSmokeFrame(state, in: surface)
                }
            )
            // Mouse down/up has just traversed the regular product handler, after the outer
            // frame tick. Render once through that same host path so a following read-only probe
            // observes the newly published loading/ready tree instead of an idle old frame.
            if driver.takePaintRequest() {
                _ = self.renderTick()
            }
        }
        agentSessionArchiveSmokeTerminalInvariant = driver.terminalInvariantSatisfied
        agentSessionArchiveSmokeScrollDispatched = driver.scrollDispatched
        agentSessionArchiveSmokeAnchorBeforePresent = driver.anchorBeforePresent
        agentSessionArchiveSmokeAnchorAfterPresent = driver.anchorAfterPresent
        agentSessionArchiveSmokeAnchorRawTopPreserved = driver.anchorRawTopPreserved
        agentSessionArchiveSmokeAnchorSnapshotReordered = driver.anchorSnapshotReordered
        agentSessionArchiveSmokeAnchorNewGenerationPublished = driver.anchorNewGenerationPublished
        guard driver.finished else { return }
        agentSessionArchiveSmokeDriver = driver
        smokeTimer?.invalidate()
        smokeTimer = nil
        if driver.stage != .succeeded { exitCode = 1 }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Serializes only the already-published SessionDock border/action geometry for the four-way
    /// terminal-font × render-scale fixture. This is a closed observer, never a second layout or
    /// an input path: every rect originates in the same UiRectTree painted by the normal frame.
    private func writeArchiveSmokeFontScaleGeometry(session: OpaquePointer, window: NSWindow) -> Bool {
        guard isAgentSessionArchiveSmokeMode,
              ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] == "font-scale-rects",
              let rawRoot = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR"],
              let rawScale = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_RENDER_SCALE_MILLI"],
              let renderScaleMilli = UInt32(rawScale), renderScaleMilli == 1_000 || renderScaleMilli == 2_000
        else { return false }

        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        guard root == home.deletingLastPathComponent(),
              root.lastPathComponent == "maru-agent-session-archive-smoke",
              root.deletingLastPathComponent().lastPathComponent == "zig-out"
        else { return false }
        let path = root.appendingPathComponent("font-scale-rects.geometry.json").standardizedFileURL
        guard path.deletingLastPathComponent() == root, !FileManager.default.fileExists(atPath: path.path) else { return false }

        let targets: [(String, UInt32)] = [
            ("header", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH),
            ("scope_row", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW),
            ("search", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH),
            ("first_card", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD),
            ("expanded_card", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_CARD),
            ("resume", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
            ("reveal", MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
        ]
        var generation: UInt64?
        var rects: [String: Any] = [:]
        for (name, target) in targets {
            var probe = MaruAppHostAgentSessionArchiveSmokeProbe()
            guard maru_macos_app_session_agent_session_archive_smoke_probe(session, target, &probe) == Self.statusOK,
                  probe.present != 0, probe.width_px > 0, probe.height_px > 0, probe.generation != 0
            else { return false }
            if let generation {
                guard generation == probe.generation else { return false }
            } else {
                generation = probe.generation
            }
            let raw: [String: Double] = [
                "x": Double(probe.x_px), "y": Double(probe.y_px),
                "width": Double(probe.width_px), "height": Double(probe.height_px),
            ]
            let factor = 1_000.0 / Double(renderScaleMilli)
            let logical = raw.mapValues { $0 * factor }
            rects[name] = ["raw_px": raw, "logical": logical, "enabled": probe.enabled != 0]
        }
        let actualWindowScaleMilli = UInt32((window.backingScaleFactor * 1_000).rounded())
        let document: [String: Any] = [
            "schema": "maru.agent-session.font-scale-rects.v1",
            "render_scale_milli": renderScaleMilli,
            "actual_window_scale_milli": actualWindowScaleMilli,
            "snapshot_generation": generation ?? 0,
            "rects": rects,
        ]
        guard JSONSerialization.isValidJSONObject(document) else { return false }
        do {
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// AS4-c의 one-shot Metal readback sink. The driver reaches this only after a read-only probe
    /// has observed an already-published list/loading/ready/stale frame. This method neither changes
    /// Zig archive state nor replays an input; it asks the current renderer to copy the next
    /// ordinary redraw of that same frame into the isolated fixture root.
    private func captureAgentSessionArchiveSmokeFrame(
        _ state: AgentSessionArchiveSmokeDriver.CaptureState,
        in surface: TerminalSurface
    ) -> Bool {
        guard isAgentSessionArchiveSmokeMode,
              let scenario = agentSessionArchiveSmokeDriver?.scenarioName,
              let rawRoot = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR"],
              !rawRoot.isEmpty,
              let renderer = surface.metalRenderer
        else { return false }

        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let expectedRoot = home.deletingLastPathComponent()
        // The shell fixture owns `.../maru-agent-session-archive-smoke/home`; accepting only its
        // direct parent prevents a test-only environment value from becoming an arbitrary-write
        // path. The nested capture directory must already be made by the shell harness.
        guard root == expectedRoot,
              root.lastPathComponent == "maru-agent-session-archive-smoke",
              root.deletingLastPathComponent().lastPathComponent == "zig-out"
        else { return false }

        let stateName: String = switch state {
        case .list: "list"
        case .loading: "loading"
        case .ready: "ready"
        case .stale: "stale"
        case .scrollAnchorBefore: "scroll-anchor-before"
        case .scrollAnchorAfter: "scroll-anchor-after"
        }
        let captureDir = root.appendingPathComponent("captures", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: captureDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let path = captureDir.appendingPathComponent("\(scenario)-\(stateName).ppm").standardizedFileURL
        guard path.deletingLastPathComponent() == captureDir,
              !FileManager.default.fileExists(atPath: path.path),
              maru_metal_renderer_request_test_capture(renderer, path.path)
        else { return false }

        withSurface(surface) {
            // `drawMetalFrame` otherwise skips an unchanged generation. This is still the normal
            // frame construction and renderer call; only the fixture-only copy request differs.
            metalNeedsRedraw = true
            _ = renderTick()
        }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let artifact = "captures/\(scenario)-\(stateName).ppm"
        switch state {
        case .list:
            agentSessionArchiveSmokeCaptureList = true
            agentSessionArchiveSmokeCaptureListArtifact = artifact
        case .loading:
            agentSessionArchiveSmokeCaptureLoading = true
            agentSessionArchiveSmokeCaptureLoadingArtifact = artifact
        case .ready:
            agentSessionArchiveSmokeCaptureReady = true
            agentSessionArchiveSmokeCaptureReadyArtifact = artifact
        case .stale:
            agentSessionArchiveSmokeCaptureStale = true
            agentSessionArchiveSmokeCaptureStaleArtifact = artifact
        case .scrollAnchorBefore:
            agentSessionArchiveSmokeCaptureScrollAnchorBefore = true
            agentSessionArchiveSmokeCaptureScrollAnchorBeforeArtifact = artifact
        case .scrollAnchorAfter:
            agentSessionArchiveSmokeCaptureScrollAnchorAfter = true
            agentSessionArchiveSmokeCaptureScrollAnchorAfterArtifact = artifact
        }
        return true
    }

    /// Converts an already-published backing-pixel rect to an AppKit window point and sends the
    /// full NSView pointer lifecycle. `handleMouse` performs the usual y/scale conversion back to
    /// Zig, making this exercise precisely the product event route.
    private func dispatchArchiveSmokeClick(
        _ probe: MaruAppHostAgentSessionArchiveSmokeProbe,
        in view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        dispatchArchiveSmokePointerDown(probe, in: view, window: window) &&
        dispatchArchiveSmokePointerUp(probe, in: view, window: window)
    }

    /// The snapshot-replace fixture deliberately separates the ordinary mouse lifecycle. The
    /// probe is copied from a published tree before replacement; this method still routes its
    /// down through the same view handler that a user click uses.
    private func dispatchArchiveSmokePointerDown(
        _ probe: MaruAppHostAgentSessionArchiveSmokeProbe,
        in view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        guard probe.present != 0, probe.enabled != 0, probe.width_px > 0, probe.height_px > 0 else { return false }
        let scale = archiveSmokeRenderScale(window)
        guard scale > 0 else { return false }
        let backingX = CGFloat(probe.x_px + probe.width_px / 2)
        let backingY = CGFloat(probe.y_px + probe.height_px / 2)
        let local = NSPoint(x: backingX / scale, y: view.bounds.height - (backingY / scale))
        let location = view.convert(local, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return false }
        view.mouseDown(with: down)
        return true
    }

    /// Completes an already-started fixture pointer lifecycle at the same backing coordinate.
    /// It intentionally does not re-probe: a fresh capability here would hide the stale-up race
    /// instead of exercising the product's capture reconciliation.
    private func dispatchArchiveSmokePointerUp(
        _ probe: MaruAppHostAgentSessionArchiveSmokeProbe,
        in view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        guard probe.present != 0, probe.enabled != 0, probe.width_px > 0, probe.height_px > 0 else { return false }
        let scale = archiveSmokeRenderScale(window)
        guard scale > 0 else { return false }
        let backingX = CGFloat(probe.x_px + probe.width_px / 2)
        let backingY = CGFloat(probe.y_px + probe.height_px / 2)
        let local = NSPoint(x: backingX / scale, y: view.bounds.height - (backingY / scale))
        let location = view.convert(local, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return false }
        view.mouseUp(with: up)
        return true
    }

    /// Sends a precise scroll event through the exact `NSView.scrollWheel → handleScroll → Zig`
    /// route. The event is intentionally created at a published card coordinate rather than
    /// calling the controller directly, so AppKit's point/backing conversion remains part of
    /// the AS3-c product gate.
    private func dispatchArchiveSmokePreciseScroll(
        _ probe: MaruAppHostAgentSessionArchiveSmokeProbe,
        in view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        guard probe.present != 0, probe.width_px > 0, probe.height_px > 0 else { return false }
        let scale = archiveSmokeRenderScale(window)
        guard scale > 0 else { return false }
        let backingX = CGFloat(probe.x_px + probe.width_px / 2)
        let backingY = CGFloat(probe.y_px + probe.height_px / 2)
        let local = NSPoint(x: backingX / scale, y: view.bounds.height - (backingY / scale))
        let location = view.convert(local, to: nil)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: -96,
                wheel2: 0,
                wheel3: 0
              )
        else { return false }
        event.location = location
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        view.scrollWheel(with: nsEvent)
        return true
    }

    /// Uses the same `MaruMetalTerminalView.keyDown` route as a physical shortcut.  The driver
    /// chooses only documented shortcuts; Zig still resolves every event through the normal
    /// keybinding path. Archive actions remain generation-bound, and the font cases prove the
    /// physical Cmd zoom route without a test-only AppSession mutation.
    private func dispatchArchiveSmokeShortcut(
        _ shortcut: AgentSessionArchiveSmokeDriver.Shortcut,
        in view: MaruMetalTerminalView,
        window: NSWindow
    ) -> Bool {
        let input: (characters: String, keyCode: UInt16) = switch shortcut {
        case .resume: ("\r", 36)
        case .reveal: ("l", 37)
        case .increaseFont: ("=", 24)
        case .decreaseFont: ("-", 27)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: input.characters,
            charactersIgnoringModifiers: input.characters,
            isARepeat: false,
            keyCode: input.keyCode
        ) else { return false }
        view.keyDown(with: event)
        return true
    }

    /// Fixture-only provider executables write a constant verdict only after seeing the expected
    /// direct argv. The host reads only that boolean, so no provider id or user content enters the
    /// smoke summary or Swift state.
    private func archiveSmokeFakeResumeVerdict() -> Bool {
        guard isAgentSessionArchiveSmokeMode else { return false }
        let marker = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".maru-agent-session-archive-marker").path
        guard let value = try? String(contentsOfFile: marker, encoding: .utf8) else { return false }
        switch ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] {
        case "resume-pointer", "resume-keyboard":
            return value == "codex-resume-direct-argv\n"
        case "claude-resume-pointer":
            return value == "claude-resume-direct-argv\n"
        default:
            return false
        }
    }

    /// Replaces only the synthetic source for the stale-reveal scenario. This is deliberately
    /// narrower than a generic smoke filesystem API: both paths must remain in the isolated
    /// HOME's same directory, and a normal app run never satisfies the scenario gate. `rename`
    /// is atomic on this one fixture volume, so the published `(device,inode)` is now stale.
    private func replaceArchiveSmokeRevealSource() -> Bool {
        guard isAgentSessionArchiveSmokeMode,
              let scenario = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"],
              scenario == "reveal-recheck-pointer" || scenario == "detail-stale" || scenario == "snapshot-replace-pointer",
              let source = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_REVEAL_PATH"],
              let replacement = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_REPLACEMENT_PATH"]
        else { return false }
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
        let replacementURL = URL(fileURLWithPath: replacement).standardizedFileURL
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        guard sourceURL.path != replacementURL.path,
              sourceURL.deletingLastPathComponent() == replacementURL.deletingLastPathComponent(),
              sourceURL.path.hasPrefix(homeURL.path + "/"),
              replacementURL.path.hasPrefix(homeURL.path + "/")
        else { return false }
        return Darwin.rename(replacementURL.path, sourceURL.path) == 0
    }

    /// The scroll-anchor fixture reorders a *different* synthetic archive record without
    /// replacing either file. The expanded detail therefore retains its exact device/inode
    /// identity; only the next completed projection changes order. This remains a closed smoke
    /// seam: no caller-provided path is accepted and normal app runs cannot enter this branch.
    private func reorderArchiveSmokeSnapshot() -> Bool {
        guard isAgentSessionArchiveSmokeMode,
              ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] == "expanded-scroll-anchor",
              let raw = ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_REORDER_PATH"]
        else { return false }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        guard candidate.path.hasPrefix(home.path + "/"),
              candidate.deletingLastPathComponent() == home.appendingPathComponent(".codex/sessions/2026/08/03", isDirectory: true),
              candidate.lastPathComponent == "rollout-fixture-scroll-anchor.jsonl",
              FileManager.default.fileExists(atPath: candidate.path)
        else { return false }
        do {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: candidate.path)
            return true
        } catch {
            return false
        }
    }

    private func sendKeyEvent(_ event: MaruAppHostKeyEvent) {
        guard let appSession else {
            return
        }

        syncLastWindowBeforeKeyDispatch(appSession, owner: activeSurface)
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

    // ⌘W가 세션(창)을 닫는 판정은 동기다 — terminal 입력과 WebKeyRoute.app_action 모두 실제 dispatch 직전에
    // 마지막 창 여부를 같은 규칙으로 갱신한다. 두 번째 창을 갓 연 직후 다음 tick 전의 stale=true와, quick을
    // 앱 종료 단위로 오인하는 일을 함께 막는다.
    private func syncLastWindowBeforeKeyDispatch(_ session: OpaquePointer, owner: TerminalSurface?) {
        maru_macos_app_session_set_last_window(session, (owner !== quick && windows.count <= 1) ? 1 : 0)
    }

    /// 현재 창의 backing 픽셀 + scale(천분율) — 세션 생성 시 셸을 처음부터 실제 크기로 spawn하는 데 쓴다
    /// (resizeAppSessionFromWindow와 같은 contentView×backingScale 계산). 창이 없거나 아직 레이아웃 전(0)이면
    /// (0,0,0)을 줘 Zig가 cols/rows로 폴백하게 한다(잘못된 0칸 grid 방지).
    private func spawnMetricsForCurrentWindow() -> (widthPx: UInt32, heightPx: UInt32, scaleMilli: UInt32) {
        guard let window, let contentView = window.contentView else { return (0, 0, 0) }
        let bounds = contentView.bounds
        let scale = archiveSmokeRenderScale(window)
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
        let scale = archiveSmokeRenderScale(window)
        // grid(cols/rows)는 Zig app session이 backing 픽셀 + 자기 cell 메트릭으로 직접 계산한다.
        // Swift는 창의 backing 픽셀만 모아 넘긴다(cell 크기·floor·placeholder 계산을 들고 있지
        // 않으므로, 메트릭이 준비되기 전 placeholder로 grid를 잘못 잡는 일이 없다).
        let widthPx = clampedUInt32(bounds.width * scale)
        let heightPx = clampedUInt32(bounds.height * scale)
        resizeAppSession(widthPx: widthPx, heightPx: heightPx, scale: scale)
    }

    private func resizeAppSession(widthPx: UInt32, heightPx: UInt32, scale: CGFloat) {
        guard let appSession else {
            return
        }

        let scaleMilli = clampedUInt32(scale * 1_000)
        // 같은 size+scale 중복 resize 방지(SIGWINCH storm)와 grid 계산 모두 Zig app session이
        // 한 곳에서 처리한다. Swift는 매번 backing 픽셀+scale만 보내고, app session이 변화 없으면
        // 비싼 재작업을 건너뛴다. tick의 scale-변화 감지용으로 보낸 backing scale만 기록한다.
        lastSentBackingScale = scale

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

    // 진행 중 IME 조합을 확정한다(IME 우회 특수키/단축키 직전). Surface preedit를 커밋·비운다.
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
                // chrome shape는 세션 재생성이 필요하지만 dirty/source-edit 파일을 버리면서 라이브 적용할 수는 없다.
                // 공용 보호 notice를 띄우고 현재 세션을 유지한다. 파일 상태가 해소된 다음 토글에서 재생성된다.
                _ = tearDownQuickTerminalIfUnprotected()
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
            // quick은 full chrome도 가능하므로 chrome_minimal이 아닌 command kind로 lifecycle identity를 넘긴다.
            // workspace manifest가 quick을 저장하기 전에는 Zig가 local backend를 골라 Quit orphan을 막는다.
            command_kind: UInt32(MaruAppHostCommandQuickInteractiveShell.rawValue),
            chrome_minimal: chromeMinimal,
            minimal_tabs: minimalTabs,
            // quick 패널은 크기·배치가 특수(슬라이드 패널)라 0으로 두고 생성 직후 resize에 맡긴다(80×24→실제). 메인 창
            // 첫 프롬프트 % 잔상이 보고된 케이스라 거기만 spawn-크기를 채운다(quick은 회귀 없이 기존 동작 유지).
            width_px: 0,
            height_px: 0,
            scale_milli: 0,
            defer_initial_surface: 0
        )
        // 메인 창 경로와 **같은 이유**로 여기서도 넘긴다 — quick 패널만 먼저 뜨면 그 창이 로케일 없이
        // 언어를 정하게 되어 `auto` 가 영어로 떨어진다(세션 생성 경로가 둘이라는 것이 함정이다).
        publishUiLocale()

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

    /// 일반 실행 중 quick teardown의 유일한 진입점. 설정 재생성·tick fault/종료 모두 여기서 현재 session의
    /// Zig-owned 파일 보호를 다시 읽는다. 보호 중이면 공용 notice만 요청하고 session/WKWebView/buffer를 유지한다.
    @discardableResult
    private func tearDownQuickTerminalIfUnprotected(persistentTickFault: Bool = false) -> Bool {
        guard let quick else { return true }
        guard let session = quick.appSession else {
            tearDownQuickTerminalAfterGlobalPreflight()
            return true
        }
        let protected = maru_macos_app_session_has_protected_file_panels(session) != 0
        guard FilePanelTerminationPolicy.mayRecreateQuickSurface(currentProtected: protected) else {
            _ = holdProtectedSurfaceAfterTickFailure(quick, persistentTickFault: persistentTickFault)
            return false
        }
        tearDownQuickTerminalAfterGlobalPreflight()
        return true
    }

    /// quick terminal을 실제로 파괴한다. 제품 실행 중에는 위 보호 wrapper만 호출하고, 앱 종료에서는
    /// applicationShouldTerminate/drainQuitDecision의 all-session preflight를 통과한 뒤에만 직접 호출한다.
    private func tearDownQuickTerminalAfterGlobalPreflight() {
        guard let surface = quick else { return }
        self.quick = nil
        quickAnimating = false
        quickHideFrame = nil // 재생성 시 stale 숨김 사각형이 새 패널에 새지 않게
        if let panel = surface.window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        }
        surface.window?.orderOut(nil)
        teardownWebPanels(surface)
        surface.fileTreeWatcher.stop()
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
        maruWorkspaceFileURL()
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

    /// Restore-incomplete 실행도 mutation generation은 추적하되 background publication만 막는다. 그래야 C4 final
    /// Quit이 secure `.bak` 보존 뒤 현재 전체 모델을 게시해 다음 실행의 자기영속 restore drop을 끊을 수 있다.
    private func armWorkspaceCheckpoint(initialDirty: Bool) {
        guard !workspaceCheckpointArmed, !smokeMode else { return }
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return }
        // staged Window가 하나라도 남아 있으면 아무 세션도 publish하지 않는다. 일부만 enable한 뒤
        // arm 실패/조기 return하면 배경 inventory와 mutation forwarding의 transaction 경계가 갈린다.
        guard windows.allSatisfy({ $0.appSession != nil }) else { return }
        guard maru_macos_workspace_checkpoint_arm(initialDirty ? 1 : 0) == Self.statusOK else { return }
        workspaceCheckpointArmed = true
        for surface in windows {
            guard let session = surface.appSession else { preconditionFailure("preflighted session disappeared") }
            surface.workspaceCheckpointPublished = true
            maru_macos_app_session_enable_workspace_checkpoint_mutations(session)
        }
        if let key = windows.first(where: { $0.window?.isKeyWindow == true })?.window {
            workspaceCheckpointActiveWindow = ObjectIdentifier(key)
        }
        workspaceCheckpointFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { surface in
            surface.window.map { (ObjectIdentifier($0), $0.frame) }
        })
    }

    private func markWorkspaceCheckpointFrameIfChanged(_ window: NSWindow) {
        guard workspaceCheckpointArmed,
              windows.contains(where: { $0.window === window && $0.workspaceCheckpointPublished }),
              !window.styleMask.contains(.fullScreen) else { return }
        let identity = ObjectIdentifier(window)
        guard workspaceCheckpointFrames[identity] != window.frame else { return }
        workspaceCheckpointFrames[identity] = window.frame
        maru_macos_workspace_checkpoint_mark_window_frame()
    }

    private func driveWorkspaceCheckpoint() {
        guard workspaceCheckpointArmed else { return }
        // 복원이 불완전한 실행에서는 **평상시 저장을 하지 않는다.** 화면에 일부만 복원된 상태를 그대로
        // 커밋하면 저장 파일에서 나머지가 영구히 사라진다. 대신 종료 저장(`workspaceFinalQuitPending`)은
        // 통과시키고, 그 경로가 아래 `preservePrevious` 로 마지막 완전본을 `workspace.v1.bak` 에 남긴 뒤
        // 쓴다 — 이 둘이 한 쌍이다(ec5a6cf3 "gate quit on final checkpoint").
        //
        // 저장이 왜 안 됐는지는 지금까지 어디에도 남지 않아 "체크포인트 저장 실패" 한 문장만 보였다.
        // tick 마다 불리므로 사유가 바뀔 때만 찍는다.
        guard !workspaceRestoreIncomplete || workspaceFinalQuitPending else {
            logWorkspaceCheckpointDiagnosticOnce("skipped: restore_incomplete latch is set (final-quit save still runs)")
            return
        }
        var effect = MaruWorkspaceCheckpointEffect()
        let now = DispatchTime.now().uptimeNanoseconds
        guard maru_macos_workspace_checkpoint_tick(now, &effect) == Self.statusOK else {
            logWorkspaceCheckpointDiagnosticOnce("capture failed: checkpoint_tick returned non-OK")
            setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_CAPTURE_FAILED))
            return
        }
        // 여기서 "ok" 를 찍지 않는다. tick 통과는 **저장이 아니라 통과**일 뿐이고, 정상 상태가 매 tick 찍히면
        // 진단이 아니라 소음이다 — 실제로 `app.log` 가 28MB 까지 불어 4MB 캡을 무의미하게 만들었다.
        // 남길 가치가 있는 것은 정상에서 벗어난 순간뿐이다.
        handleWorkspaceCheckpointEffect(effect, snapshot: nil)
    }

    /// checkpoint 진단의 마지막 사유. 같은 사유를 tick 마다 반복해 찍지 않는다.
    private var workspaceCheckpointDiagnostic: String = ""

    /// 사유가 바뀔 때만 stderr 로 남긴다. GUI 실행에서는 `<cache>/maru/app.log` 로 들어간다.
    private func logWorkspaceCheckpointDiagnosticOnce(_ reason: String) {
        guard workspaceCheckpointDiagnostic != reason else { return }
        workspaceCheckpointDiagnostic = reason
        fputs("workspace checkpoint: \(reason)\n", stderr)
    }

    private func setWorkspaceCheckpointFailure(_ failure: UInt32) {
        guard workspaceCheckpointFailureNotice != failure else { return }
        workspaceCheckpointFailureNotice = failure
        for surface in windows {
            if let session = surface.appSession {
                maru_macos_app_session_set_workspace_checkpoint_failure(session, failure)
            }
        }
    }

    private func handleWorkspaceCheckpointEffect(_ effect: MaruWorkspaceCheckpointEffect, snapshot: Data?) {
        // tick 이 OK 여도 파일이 안 바뀌는 구간이 여기다 — 실제 쓰기는 effect 를 따라가야 도달한다.
        // 다만 **아무 일도 없는 tick**(kind=0·notice=0)은 남기지 않는다. 그게 대다수라 그대로 두면 로그가
        // 정상 상태로 가득 차 정작 이상한 순간을 덮는다.
        if effect.kind != 0 || effect.notice != UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE) {
            logWorkspaceCheckpointDiagnosticOnce("effect kind=\(effect.kind) notice=\(effect.notice) reason=\(effect.reason) snapshot=\(snapshot?.count ?? -1)")
        }
        if effect.notice != UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE) {
            setWorkspaceCheckpointFailure(effect.notice)
        }
        switch effect.kind {
        case UInt32(MARU_WORKSPACE_CHECKPOINT_EFFECT_CAPTURE):
            let captured = captureWorkspaceSnapshot(useTerminationKeyWindow: false, publishedOnly: true)
            if captured == nil {
                logWorkspaceCheckpointDiagnosticOnce("capture result=nil")
            }
            var next = MaruWorkspaceCheckpointEffect()
            let now = DispatchTime.now().uptimeNanoseconds
            guard maru_macos_workspace_checkpoint_capture_completed(
                effect.generation,
                captured == nil ? 0 : 1,
                now,
                &next
            ) == Self.statusOK else {
                setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_CAPTURE_FAILED))
                return
            }
            handleWorkspaceCheckpointEffect(next, snapshot: captured)
        case UInt32(MARU_WORKSPACE_CHECKPOINT_EFFECT_WRITE):
            if snapshot == nil || workspaceFileURL == nil {
                logWorkspaceCheckpointDiagnosticOnce("write blocked: snapshot_nil=\(snapshot == nil) url_nil=\(workspaceFileURL == nil)")
            }
            guard let snapshot, let workspaceURL = workspaceFileURL else {
                var next = MaruWorkspaceCheckpointEffect()
                guard maru_macos_workspace_checkpoint_write_completed(
                    effect.generation,
                    0,
                    DispatchTime.now().uptimeNanoseconds,
                    &next
                ) == Self.statusOK else {
                    setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_WRITE_FAILED))
                    return
                }
                handleWorkspaceCheckpointEffect(next, snapshot: nil)
                return
            }
            let parent = Data(workspaceURL.deletingLastPathComponent().path.utf8)
            let generation = effect.generation
            let preservePrevious = workspaceRestoreIncomplete
            logWorkspaceCheckpointDiagnosticOnce("write dispatched: bytes=\(snapshot.count) preserve_previous=\(preservePrevious) reason=\(effect.reason)")
            workspaceCheckpointWriter.async { [weak self] in
                let result = parent.withUnsafeBytes { parentRaw in
                    snapshot.withUnsafeBytes { snapshotRaw in
                        if effect.reason == UInt32(MARU_WORKSPACE_CHECKPOINT_REASON_FINAL_QUIT) {
                            maru_macos_workspace_checkpoint_publish_final(
                                parentRaw.bindMemory(to: UInt8.self).baseAddress,
                                parentRaw.count,
                                snapshotRaw.bindMemory(to: UInt8.self).baseAddress,
                                snapshotRaw.count,
                                preservePrevious ? 1 : 0
                            )
                        } else {
                            maru_macos_workspace_checkpoint_publish(
                                parentRaw.bindMemory(to: UInt8.self).baseAddress,
                                parentRaw.count,
                                snapshotRaw.bindMemory(to: UInt8.self).baseAddress,
                                snapshotRaw.count
                            )
                        }
                    }
                }
                // `applicationShouldTerminate`가 `.terminateLater`를 반환하면 AppKit은
                // `NSApplication.terminate` 안에서 중첩 run loop를 돈다. 그 loop는 timer/event는
                // 처리하지만 main dispatch queue를 drain하지 않으므로 `DispatchQueue.main.async`로
                // 완료를 돌려보내면 final checkpoint가 성공하든 실패하든 Quit이 영원히 pending에
                // 남는다. `.common` run-loop source는 그 중첩 loop에서도 실행되어 AppKit reply와
                // checkpoint state machine을 같은 main-thread owner에게 되돌린다.
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        var next = MaruWorkspaceCheckpointEffect()
                        let committed = result == UInt32(MARU_WORKSPACE_CHECKPOINT_PUBLISH_COMMITTED)
                        guard maru_macos_workspace_checkpoint_write_completed(
                            generation,
                            committed ? 1 : 0,
                            DispatchTime.now().uptimeNanoseconds,
                            &next
                        ) == Self.statusOK else {
                            self.setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_WRITE_FAILED))
                            return
                        }
                        if committed {
                            self.setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE))
                        }
                        self.handleWorkspaceCheckpointEffect(next, snapshot: nil)
                    }
                }
            }
        default:
            if effect.kind == UInt32(MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT) {
                cancelFinalWorkspaceCheckpoint()
            } else if effect.kind == UInt32(MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH) {
                finishFinalWorkspaceCheckpoint()
            }
        }
    }

    private func beginFinalWorkspaceCheckpoint(surface: TerminalSurface?, deferredAppKitQuit: Bool) {
        guard !workspaceFinalQuitPending else { return }
        guard workspaceCheckpointArmed, !windows.isEmpty else {
            bypassQuitConfirm = true
            if deferredAppKitQuit {
                quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else { NSApp.terminate(nil) }
            return
        }
        workspaceFinalQuitPending = true
        workspaceFinalQuitSurface = surface
        workspaceFinalQuitWasDeferred = deferredAppKitQuit
        workspaceFinalQuitAllowsFailure = maru_macos_app_quit_end_all() != 0
        var effect = MaruWorkspaceCheckpointEffect()
        // 종료 저장이 실패하면 keep-alive 종료는 **취소된다**(allowsFailure=false). 사용자에게는
        // "체크포인트 저장 실패"와 함께 앱이 안 닫히는 것으로만 보이고, 그 status 가 무엇이었는지는
        // 지금까지 어디에도 남지 않았다. 이 한 줄이 그 마지막 공백이다 — 여기서 실패하면 평상시 저장도
        // 이미 skip 상태라 manifest 가 영원히 갱신되지 않는다.
        let finalStatus = maru_macos_workspace_checkpoint_quit_requested(DispatchTime.now().uptimeNanoseconds, &effect)
        fputs("workspace checkpoint: final-quit requested status=\(finalStatus) allows_failure=\(workspaceFinalQuitAllowsFailure) restore_incomplete=\(workspaceRestoreIncomplete)\n", stderr)
        guard finalStatus == Self.statusOK else {
            setWorkspaceCheckpointFailure(UInt32(MARU_WORKSPACE_CHECKPOINT_NOTICE_CAPTURE_FAILED))
            cancelFinalWorkspaceCheckpoint()
            return
        }
        handleWorkspaceCheckpointEffect(effect, snapshot: nil)
    }

    private func cancelFinalWorkspaceCheckpoint() {
        guard workspaceFinalQuitPending else { return }
        fputs("workspace checkpoint: final-quit cancelled (allows_failure=\(workspaceFinalQuitAllowsFailure))\n", stderr)
        if workspaceFinalQuitAllowsFailure {
            finishFinalWorkspaceCheckpoint()
            return
        }
        workspaceFinalQuitPending = false
        if let session = workspaceFinalQuitSurface?.appSession {
            maru_macos_app_session_cancel_app_quit(session)
        }
        workspaceFinalQuitSurface = nil
        bypassQuitConfirm = false
        if workspaceFinalQuitWasDeferred {
            quitConfirmPending = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        workspaceFinalQuitWasDeferred = false
        workspaceFinalQuitAllowsFailure = false
    }

    private func finishFinalWorkspaceCheckpoint() {
        guard workspaceFinalQuitPending else { return }
        fputs("workspace checkpoint: final-quit finished — quit proceeds\n", stderr)
        workspaceFinalQuitPending = false
        workspaceFinalQuitSurface = nil
        workspaceFinalQuitAllowsFailure = false
        workspaceFinalQuitApproved = true
        bypassQuitConfirm = true
        if workspaceFinalQuitWasDeferred {
            workspaceFinalQuitWasDeferred = false
            quitConfirmPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func captureWorkspaceSnapshot(useTerminationKeyWindow: Bool, publishedOnly: Bool) -> Data? {
        let checkpointWindows = publishedOnly ? windows.filter(\.workspaceCheckpointPublished) : windows
        guard !smokeMode, !checkpointWindows.isEmpty else { return nil }
        // 복원을 끈 사용자(MARU_NO_WORKSPACE_RESTORE)는 저장도 막는다 — 안 그러면 복원 안 한 기본 단일 창이 종료 시
        // 저장 파일을 덮어써 사용자가 보존하려던 멀티 창 레이아웃이 사라진다(데이터 손실). 플래그=persistence 자체 off.
        guard ProcessInfo.processInfo.environment["MARU_NO_WORKSPACE_RESTORE"] == nil else { return nil }
        var blocks = ""
        var blockCount: Int64 = 0
        // 저장 시점 key(활성) 창을 active-window=1 마커로 기록한다 — 재시작 복원이 그 창을 다시 focus(M3e).
        // 최대 하나의 창만 isKeyWindow라 마커도 최대 하나. 옵션-키라 비활성 창은 키가 생략된다(옛 파일 flat 동일).
        // 종료 경로는 정리 전에 창을 숨겨(체감 지연 제거) 이 시점 `isKeyWindow`가 이미 전부 false이므로, 숨기기
        // 직전에 붙잡아 둔 창을 우선 본다(판정 규칙과 그 이유는 `TerminationWindowPolicy`).
        let capturedKeyIndex = (useTerminationKeyWindow ? terminationKeyWindow : nil).flatMap { captured in
            checkpointWindows.firstIndex(where: { $0.window === captured })
        }
        let currentKeyIndex = checkpointWindows.firstIndex(where: { $0.window?.isKeyWindow == true })
        for (windowIndex, surface) in checkpointWindows.enumerated() {
            // workspace.v1은 모든 normal Window가 한 atomic snapshot이다. 한 창이라도 캡처할 수 없으면 성공한 창만으로
            // 기존 완전본을 덮어쓰지 않는다(다음 실행에서 실패 창이 영구 삭제되는 partial checkpoint 방지).
            guard let session = surface.appSession else { return nil }
            let isActive: UInt32 = TerminationWindowPolicy.isActive(
                index: windowIndex,
                capturedKeyIndex: capturedKeyIndex,
                currentKeyIndex: currentKeyIndex
            ) ? 1 : 0
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
                  let bytes = ptr, len > 0 else { return nil } // 하나라도 실패하면 이전 전체 checkpoint 보존
            blocks += String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
            blockCount += 1
        }
        guard !blocks.isEmpty else { return nil }
        let snapshot = MARU_WORKSPACE_HEADER + "\n" + blocks
        // R2a: per-window writer만으로는 창을 가로지른 runtime-handle 중복을 볼 수 없다. 실제 publish할 전체 문자열을
        // Zig parser/semantic validator에 다시 넣어, 어떤 파일 write/backup보다 먼저 global owner uniqueness를 확인한다.
        // 실패하면 write 0으로 마지막 완전본을 보존한다. Swift는 binding 문법이나 창 경계를 해석하지 않는다.
        let snapshotBytes = Array(snapshot.utf8)
        let validatedWindowCount = snapshotBytes.withUnsafeBufferPointer { buf in
            maru_macos_app_session_workspace_window_count(nil, buf.baseAddress, buf.count)
        }
        guard validatedWindowCount == blockCount else { return nil }
        return Data(snapshot.utf8)
    }

    private func shutdownAppSession(preserveWebPanelsFor summarySurface: TerminalSurface? = nil) {
        // 전역 단축키를 먼저 OS에서 해제한다(세션이 사라져도 stale hot-key가 남지 않게). 이미 비었으면 no-op.
        unregisterGlobalHotkeys()
        // quick terminal(있으면)도 함께 정리한다.
        tearDownQuickTerminalAfterGlobalPreflight()

        // 남은 모든 일반 창 세션·렌더러를 닫고 파괴한다(앱 종료 경로). 보통 비-마지막 창은 이미 닫혔고 마지막
        // 창/앱 종료에서 여기로 온다 — 멀티 창이면 한 번에 전부 정리한다(leak 방지). teardownWindowSurface가
        // 각 close/destroy + 컬렉션에서 제거(요약은 surface.latestFrameSummary에). 변형 중 순회를 피해 snapshot으로.
        let snapshot = windows
        for surface in snapshot {
            teardownWindowSurface(surface, preserveWebPanelsForSummary: surface === summarySurface)
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
        sessionHostRecoverySmokeSummaryNs = DispatchTime.now().uptimeNanoseconds
        // 요약을 쓰는 이 시점이 종료 경로의 사실상 마지막이라, 여기서 total을 확정하면 단계로 나누지 않은
        // 잔여 시간까지 total에 들어온다. 종료가 아닌 경로로 불리면(start==0) total은 0으로 남는다.
        if terminationStartNs != 0 {
            // 단계 측정(`measureElapsedNs`)과 같은 규칙으로 음의 경과를 0으로 접는다 — 한쪽만 wrap을 허용하면
            // total만 헛수가 되어 단계 합과의 차이를 잔여 시간으로 읽을 수 없다.
            let now = DispatchTime.now().uptimeNanoseconds
            terminationTiming.recordTotal(elapsedNs: now >= terminationStartNs ? now - terminationStartNs : 0)
        }
        let smokeMode = smokeDurationMs != nil
        let duration = smokeDurationMs ?? 0
        let terminalSurface = latestFrameSummary.terminal_surface != 0
        let framePrepared = latestFrameSummary.frame_prepared != 0
        let frameConsistent = latestFrameSummary.frame_consistent != 0
        let glyphUvReady = latestFrameSummary.glyph_uv_ready != 0
        let glyphRasterReady = latestFrameSummary.glyph_raster_ready != 0
        let frameEnded = latestFrameSummary.ended != 0
        let archiveSmokeStage = agentSessionArchiveSmokeDriver?.stage.rawValue ?? (isAgentSessionArchiveSmokeMode ? "not_started" : "disabled")
        let archiveSmokeFailure = agentSessionArchiveSmokeDriver?.failure ?? ""
        let archiveSmokeScenario = agentSessionArchiveSmokeDriver?.scenarioName ?? (isAgentSessionArchiveSmokeMode ? "invalid" : "disabled")
        let sortedPumpMs = browserResultPumpSamplesMs.sorted()
        let pumpP95Ms = sortedPumpMs.isEmpty ? 0 : sortedPumpMs[max(0, Int(ceil(Double(sortedPumpMs.count) * 0.95)) - 1)]
        let pumpMaxMs = sortedPumpMs.last ?? 0
        let mermaidDiagnostics = mermaidRenderCoordinator.diagnostics()
        var mermaidSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&mermaidSnapshot)
        var summary = """
        maru.macos-app.v1
        visible_ui=\(visibleUI)
        swift_host=true
        abi_ready=\(abiReady)
        app_instance_lease_status=\(appInstanceLeaseStatus)
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
        session_host_r2a_checkpoint_smoke=\(isSessionHostR2aCheckpointSmokeMode)
        session_host_r2a_checkpoint_preflight_count=\(sessionHostR2aCheckpointPreflightCount)
        session_host_r2a_checkpoint_restore_incomplete=\(workspaceRestoreIncomplete)
        session_host_recovery_smoke_stage=\(sessionHostRecoverySmokeStage)
        session_host_recovery_smoke_row_present=\(sessionHostRecoverySmokeRowPresent)
        session_host_recovery_smoke_click_dispatched=\(sessionHostRecoverySmokeClickDispatched)
        session_host_recovery_smoke_remote_published=\(sessionHostRecoverySmokeRemotePublished)
        session_host_recovery_smoke_marker_present=\(sessionHostRecoverySmokeMarkerPresent)
        session_host_recovery_smoke_before_capture=\(sessionHostRecoverySmokeBeforeCapture)
        session_host_recovery_smoke_after_capture=\(sessionHostRecoverySmokeAfterCapture)
        session_host_recovery_smoke_failure=\(sessionHostRecoverySmokeFailure)
        session_host_recovery_smoke_prepare_outcome=\(sessionHostRecoverySmokePrepareOutcome)
        session_host_recovery_smoke_keep_alive_enabled=\(sessionHostRecoverySmokeKeepAliveEnabled)
        session_host_recovery_smoke_discovered_candidates=\(sessionHostRecoverySmokeDiscoveredCandidates)
        session_host_recovery_smoke_ready_adapters=\(sessionHostRecoverySmokeReadyAdapters)
        session_host_recovery_smoke_inventory_runtimes=\(sessionHostRecoverySmokeInventoryRuntimes)
        session_host_recovery_smoke_configured_keep_alive=\(sessionHostRecoverySmokeConfiguredKeepAlive)
        session_host_recovery_smoke_live_session_count=\(sessionHostRecoverySmokeLiveSessionCount)
        session_host_recovery_smoke_target_activation_dispatched=\(sessionHostRecoverySmokeTargetActivationDispatched)
        session_host_recovery_smoke_target_rows=\(sessionHostRecoverySmokeTargetRows)
        session_host_recovery_smoke_tabs=\(sessionHostRecoverySmokeTabs)
        session_host_recovery_smoke_surface_initialized=\(sessionHostRecoverySmokeSurfaceInitialized)
        session_host_recovery_smoke_active_remote_observed=\(sessionHostRecoverySmokeActiveRemoteObserved)
        session_host_recovery_smoke_marker_observed=\(sessionHostRecoverySmokeMarkerObserved)
        session_host_recovery_smoke_launch_ns=\(sessionHostRecoverySmokeLaunchNs)
        session_host_recovery_smoke_row_ns=\(sessionHostRecoverySmokeRowNs)
        session_host_recovery_smoke_click_ns=\(sessionHostRecoverySmokeClickNs)
        session_host_recovery_smoke_remote_visible_ns=\(sessionHostRecoverySmokeRemoteVisibleNs)
        session_host_recovery_smoke_summary_ns=\(sessionHostRecoverySmokeSummaryNs)
        session_host_recovery_smoke_baseline_iteration=\(sessionHostRecoveryBaselineIteration.map(String.init) ?? "disabled")
        session_host_input_smoke_stage=\(sessionHostInputSmokeStage)
        session_host_input_smoke_historical_count=\(sessionHostInputSmokeHistoricalCount)
        session_host_input_smoke_ime_count=\(sessionHostInputSmokeImeCount)
        session_host_input_smoke_clipboard_count=\(sessionHostInputSmokeClipboardCount)
        session_host_input_smoke_marked_callbacks=\(sessionHostInputSmokeMarkedCallbacks)
        session_host_input_smoke_insert_callbacks=\(sessionHostInputSmokeInsertCallbacks)
        session_host_input_smoke_historical_clipboard_preserved=\(sessionHostInputSmokeHistoricalClipboardPreserved)
        session_host_input_smoke_view_source_restored=\(sessionHostInputSmokeViewSourceRestored)
        session_host_input_smoke_global_source_selected=\(sessionHostInputSmokeGlobalSourceSelected)
        session_host_input_smoke_global_source_restored=\(sessionHostInputSmokeGlobalSourceRestored)
        session_host_input_smoke_post_event_access=\(sessionHostInputSmokePostEventAccess)
        session_host_input_smoke_source_record_cleared=\(sessionHostInputSmokeSourceRecordCleared)
        session_host_input_smoke_app_active=\(sessionHostInputSmokeAppActive)
        session_host_input_smoke_first_responder=\(sessionHostInputSmokeFirstResponder)
        session_host_input_smoke_frontmost_pid=\(sessionHostInputSmokeFrontmostPID)
        session_host_input_smoke_failure=\(sessionHostInputSmokeFailure)
        agent_session_archive_smoke_stage=\(archiveSmokeStage)
        agent_session_archive_smoke_failure=\(archiveSmokeFailure)
        agent_session_archive_smoke_scenario=\(archiveSmokeScenario)
        agent_session_archive_smoke_fake_resume_verdict=\(archiveSmokeFakeResumeVerdict())
        agent_session_archive_smoke_reveal_allowed_count=\(agentSessionArchiveSmokeRevealAllowedCount)
        agent_session_archive_smoke_reveal_rejected_count=\(agentSessionArchiveSmokeRevealRejectedCount)
        agent_session_archive_smoke_stale_reveal_count=\(agentSessionArchiveSmokeStaleRevealCount)
        agent_session_archive_smoke_claude_model_present=\(agentSessionArchiveSmokeClaudeModelPresent)
        agent_session_archive_smoke_terminal_invariant=\(agentSessionArchiveSmokeTerminalInvariant)
        agent_session_archive_smoke_scroll_dispatched=\(agentSessionArchiveSmokeScrollDispatched)
        agent_session_archive_smoke_anchor_before_present=\(agentSessionArchiveSmokeAnchorBeforePresent)
        agent_session_archive_smoke_anchor_after_present=\(agentSessionArchiveSmokeAnchorAfterPresent)
        agent_session_archive_smoke_anchor_raw_top_preserved=\(agentSessionArchiveSmokeAnchorRawTopPreserved)
        agent_session_archive_smoke_anchor_snapshot_reordered=\(agentSessionArchiveSmokeAnchorSnapshotReordered)
        agent_session_archive_smoke_anchor_new_generation_published=\(agentSessionArchiveSmokeAnchorNewGenerationPublished)
        agent_session_archive_smoke_capture_list=\(agentSessionArchiveSmokeCaptureList)
        agent_session_archive_smoke_capture_loading=\(agentSessionArchiveSmokeCaptureLoading)
        agent_session_archive_smoke_capture_ready=\(agentSessionArchiveSmokeCaptureReady)
        agent_session_archive_smoke_capture_stale=\(agentSessionArchiveSmokeCaptureStale)
        agent_session_archive_smoke_capture_scroll_anchor_before=\(agentSessionArchiveSmokeCaptureScrollAnchorBefore)
        agent_session_archive_smoke_capture_scroll_anchor_after=\(agentSessionArchiveSmokeCaptureScrollAnchorAfter)
        agent_session_archive_smoke_capture_list_artifact=\(agentSessionArchiveSmokeCaptureListArtifact)
        agent_session_archive_smoke_capture_loading_artifact=\(agentSessionArchiveSmokeCaptureLoadingArtifact)
        agent_session_archive_smoke_capture_ready_artifact=\(agentSessionArchiveSmokeCaptureReadyArtifact)
        agent_session_archive_smoke_capture_stale_artifact=\(agentSessionArchiveSmokeCaptureStaleArtifact)
        agent_session_archive_smoke_capture_scroll_anchor_before_artifact=\(agentSessionArchiveSmokeCaptureScrollAnchorBeforeArtifact)
        agent_session_archive_smoke_capture_scroll_anchor_after_artifact=\(agentSessionArchiveSmokeCaptureScrollAnchorAfterArtifact)
        mermaid_pending_replies=\(mermaidReplyDelivery.count)
        mermaid_product_tick_calls=\(mermaidProductTick.tickCalls)
        mermaid_product_work_ticks=\(mermaidProductTick.workTicks)
        mermaid_product_tick_pump_calls=\(mermaidProductTick.pumpCalls)
        mermaid_product_tick_drain_calls=\(mermaidProductTick.acceptedDrainCalls)
        mermaid_product_completion_drain_max=\(mermaidProductTick.maxCompletionDrain)
        mermaid_product_tick_max_elapsed_us=\(mermaidProductTick.maxElapsedMicroseconds)
        mermaid_product_accepted_svg_bytes_max=\(mermaidAcceptedDrainer.acceptedBytesMax)
        mermaid_pump_calls=\(mermaidDiagnostics.pumpCalls)
        mermaid_helper_starts=\(mermaidDiagnostics.physicalStarts)
        mermaid_hello_frames=\(mermaidDiagnostics.helloFrames)
        mermaid_request_frames=\(mermaidDiagnostics.requestFrames)
        mermaid_terminal_results=\(mermaidRenderCoordinator.terminalResultCount)
        mermaid_stale_results=\(mermaidRenderCoordinator.staleResultCount)
        mermaid_accepted_results=\(mermaidSnapshot.accepted_results)
        mermaid_deadline_expirations=\(mermaidSnapshot.deadline_expirations)
        \(terminationTiming.summaryBlock())

        """

        // Phase 4e-3: MARU_WEB_PANEL=1이면 활성 web Term의 WKWebView가 컨테이너에 붙었는지(계층 순서·개수) + 4d 입력
        // 라우팅 상태를 값으로 남긴다(GUI 손 테스트의 자동 보조 — z-order 골든·실제 포커스 전이·IME·흰 화면은 여전히 손
        // 테스트). 디버그 훅은 web Term 하나를 만들어 활성화하므로 컨테이너 subviews == [터미널, 웹뷰, 오버레이]다. 웹뷰가
        // 터미널과 오버레이 **사이**(z-order 중간)에 있고 개수가 dict와 맞는지 단언 + webview.frame(pt) + 4d 계약(모달
        // 닫힘 시 웹 focusable·시작 시 터미널 포커스 유지)을 기록한다. **스모크는 backing=0이라 frame·hitTest 좌표가
        // degenerate**라 hard 단언이 아니라 값 기록이다(실제 전이는 GUI 손 테스트). env 미설정이면 무동작(요약 계약 불변).
        // docs/plans/web-panel.md §10 4e-3·4d·§11. (4e-5: 이 스모크 web 계층 단언이 webPanelHookEnabled 상수의 유일 소비처다.)
        if webPanelHookEnabled || filePanelHookEnabled {
            let container = activeSurface?.window?.contentView as? MaruTerminalContainerView
            let panels = activeSurface?.webPanels ?? [:]
            let wp = panels.values.first // 디버그 훅은 정확히 하나(활성 web Term).
            let subs = container?.subviews ?? []
            // 웹뷰들이 터미널(맨 아래)과 오버레이(맨 위) 사이에 있는가 — 순서 index로 단언(멀티 웹뷰 일반화).
            var orderOk = false
            if let container, !panels.isEmpty,
               let termIdx = subs.firstIndex(where: { $0 === container.terminalView }),
               let ovIdx = subs.firstIndex(where: { $0 === container.overlayView }) {
                orderOk = panels.values.allSatisfy { v in
                    guard let wi = subs.firstIndex(where: { $0 === v }) else { return false }
                    return wi > termIdx && wi < ovIdx
                }
            }
            let f = wp?.frame ?? .zero
            // 4d: 모달이 닫혀 있으면 웹뷰가 클릭/포커스를 받아야 한다(hitTest가 wp 자손을 돌려줌 = focusable). 시작 직후엔
            // 모달이 없고 터미널 뷰가 firstResponder라 web_panel_focused는 false여야 한다(웹이 포커스를 안 훔침).
            // NSView.hitTest는 **superview 좌표**를 받는다(뷰 자기 bounds가 아님). wp.frame 중심을 superview
            // 좌표(midX/midY)로 줘야 origin>0(하단 split·사이드바 옆)에서도 진단이 옳다(code-review [0]).
            let hit = wp?.hitTest(NSPoint(x: f.midX, y: f.midY))
            let hitInWeb = (hit != nil) && (hit?.isDescendant(of: wp ?? NSView()) ?? false)
            let webFocused = wp.map { isWebPanelFocused($0) } ?? false
            // 5c-2c 트러스트 분기 단언: 신뢰(markdown, panelKind==0) 패널만 maru-app:// 스킴 핸들러가 config에 등록돼야
            // 한다. 비신뢰(browser)면 미등록(nil). MARU_WEB_PANEL_MARKDOWN=1이면 markdown 패널이라 registered=true 기대.
            let schemeRegistered = wp?.webView.configuration.urlSchemeHandler(forURLScheme: MaruAppSchemeHandler.scheme) != nil
            let fileHTMLDataStoreIsolated = wp.map {
                $0.filePanelKind != 2 || $0.webView.configuration.websiteDataStore !== MaruWebPanelView.browserDataStore
            } ?? false
            let fileViewerUnderPageBackground: Bool
            if let panel = wp, panel.filePanelKind == 1 {
                if #available(macOS 12.0, *) {
                    // Keep the availability check and property access in the same lexical scope.
                    // Swift does not carry this refinement into Optional.map or the appearance callback
                    // when compiling for the supported macOS 11 deployment target.
                    let underPageBackgroundColor = panel.webView.underPageBackgroundColor
                    var matches = false
                    panel.webView.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard
                            let actual = underPageBackgroundColor?.usingColorSpace(.sRGB),
                            let expected = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                        else { return }
                        let tolerance = CGFloat(1.0 / 255.0)
                        matches = abs(actual.redComponent - expected.redComponent) <= tolerance
                            && abs(actual.greenComponent - expected.greenComponent) <= tolerance
                            && abs(actual.blueComponent - expected.blueComponent) <= tolerance
                            && abs(actual.alphaComponent - expected.alphaComponent) <= tolerance
                    }
                    fileViewerUnderPageBackground = matches
                } else {
                    fileViewerUnderPageBackground = false
                }
            } else {
                fileViewerUnderPageBackground = false
            }
            // Phase 7e-1a: browser 패널 nav 상태 왕복 검증 — Swift KVO 관측값(navUrl)과 Zig 저장 getter 결과가
            // 5d fixture의 data: URL로 채워지는지(url KVO → tick push(set_web_nav_state) → Zig 저장 → web_nav_url_at
            // 왕복). 세션 핸들=activeSurface.appSession, out 버퍼 4096. len>0이면 문자열, 아니면 "pending"(아직 push 전).
            var navUrlZig = "pending"
            if let wp, let session = activeSurface?.appSession {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = buf.withUnsafeMutableBufferPointer { p in
                    maru_macos_app_session_web_nav_url_at(session, wp.surfaceId, p.baseAddress, p.count)
                }
                if n > 0 { navUrlZig = String(decoding: buf[0..<Int(n)], as: UTF8.self) }
            }
            summary += """
            web_panel_present=\(wp != nil)
            web_panel_count=\(panels.count)
            web_panel_subview_order_ok=\(orderOk)
            web_panel_subview_count=\(subs.count)
            web_panel_surface_id=\(wp?.surfaceId ?? 0)
            web_panel_kind=\(wp?.panelKind ?? 99)
            web_panel_scheme_handler_registered=\(schemeRegistered)
            web_panel_data_store_persistent=\(wp?.webView.configuration.websiteDataStore.isPersistent ?? true)
            web_nav_url_swift=\(wp?.navUrl ?? "pending")
            web_nav_url_zig=\(navUrlZig)
            bridge_world_registered=\(wp?.bridgeWorld != nil)
            bridge_isolated_probe=\(wp?.bridgeIsolatedProbe ?? "pending")
            bridge_pageworld_probe=\(wp?.bridgePageWorldProbe ?? "pending")
            bridge_hello_version=\(wp?.bridgeHelloProbe ?? "pending")
            file_viewer_ready=\(wp?.fileViewerReadyProbe ?? "pending")
            file_viewer_renderer_loaded=\(wp?.fileViewerRendererLoadedProbe ?? "pending")
            file_viewer_renderer_script=\(wp?.fileViewerRendererScriptProbe ?? "pending")
            file_viewer_read=\(wp?.fileViewerReadProbe ?? "pending")
            file_viewer_text=\(wp?.fileViewerTextProbe ?? "pending")
            file_viewer_images=\(wp?.fileViewerImagesProbe ?? "pending")
            file_viewer_loaded_images=\(wp?.fileViewerLoadedImagesProbe ?? "pending")
            file_viewer_editor_hydrated=\(wp?.fileEditingSmokeProbe.editor ?? "pending")
            file_viewer_mermaid_request=\(wp?.fileEditingSmokeProbe.mermaidRequestState ?? "pending")
            file_viewer_syntax_keyword=\(wp?.fileEditingSmokeProbe.syntaxKeyword ?? "pending")
            file_viewer_editor_selection=\(wp?.fileEditingSmokeProbe.editorSelection ?? "pending")
            file_viewer_editor_font_size=\(wp?.fileEditingSmokeProbe.editorFontSize ?? "pending")
            file_viewer_mermaid_navigation_in_flight=\(wp?.fileEditingSmokeProbe.mermaidNavigationInFlight ?? "pending")
            file_viewer_mermaid_navigation_cancelled=\(wp?.fileEditingSmokeProbe.mermaidNavigationCancelled ?? "pending")
            file_viewer_default_mode=\(wp?.fileEditingSmokeProbe.defaultMode ?? "pending")
            file_viewer_edit=\(wp?.fileEditingSmokeProbe.edit ?? "pending")
            file_viewer_cmd_s_route=\(wp?.fileEditingSmokeProbe.cmdSRoute ?? "pending")
            file_viewer_disk_saved=\(wp?.fileEditingSmokeProbe.diskSaved ?? "pending")
            file_viewer_write=\(wp?.fileEditingSmokeProbe.write ?? "pending")
            file_viewer_dirty_sync_recovered=\(wp?.fileDirtySyncRecoveryProbe ?? "pending")
            file_viewer_under_page_background=\(fileViewerUnderPageBackground)
            file_viewer_critical_style=\(wp?.fileViewerCriticalStyleProbe ?? "pending")
            file_panel_mode_unknown_rejected=\(!MaruWebPanelView.isKnownFilePanelMode(3) && !MaruWebPanelView.isKnownFilePanelMode(Int32.max))
            renderer_bridge_type=\(wp?.rendererBridgeProbe ?? "pending")
            renderer_handler_type=\(wp?.rendererHandlerProbe ?? "pending")
            renderer_parent_accessible=\(wp?.rendererParentAccessProbe ?? "pending")
            file_html_kind=\(wp?.filePanelKind ?? 99)
            file_html_read_access=\(wp?.fileHTMLReadAccessURL?.path ?? "pending")
            file_html_data_store_isolated=\(fileHTMLDataStoreIsolated)
            file_html_script=\(wp?.fileHTMLScriptProbe ?? "pending")
            file_html_asset=\(wp?.fileHTMLAssetProbe ?? "pending")
            file_html_outside_asset=\(wp?.fileHTMLOutsideAssetProbe ?? "pending")
            file_html_about_attempt=\(wp?.fileHTMLAboutAttemptProbe ?? "pending")
            file_html_pinned=\(wp?.fileHTMLPinnedProbe ?? "pending")
            browser_fixture_url=\(wp?.browserFixtureUrl ?? "pending")
            browser_fixture_script=\(wp?.browserFixtureScript ?? "pending")
            browser_fixture_cookies=\(wp?.browserFixtureCookies ?? "pending")
            browser_grant_navigate_ok=\(grantSmokeResult())
            browser_ctl_navigate_ok=\(browserCtlResults().navigateOk)
            browser_ctl_get_url=\(browserCtlResults().getUrl)
            browser_ctl_events=\(browserCtlResults().events)
            browser_ctl_wait_selector=\(browserWaitResults().selector)
            browser_ctl_wait_load=\(browserWaitResults().load)
            browser_ctl_wait_timeout=\(browserWaitResults().timeout)
            browser_ctl_wait_invalid_selector=\(browserWaitResults().invalidSelector)
            browser_ctl_wait_selector_elapsed_ms=\(browserWaitResults().elapsed)
            browser_ctl_bounded_structured=\(browserBoundedResults().structured)
            browser_ctl_bounded_await_args=\(browserBoundedResults().awaitArgs)
            browser_ctl_bounded_strict_csp=\(browserBoundedResults().strictCsp)
            browser_ctl_bounded_navigation=\(browserBoundedResults().navigation)
            browser_ctl_bounded_tamper=\(browserBoundedResults().tamper)
            browser_ctl_bounded_byte_boundary=\(browserBoundedResults().byteBoundary)
            browser_ctl_bounded_too_large=\(browserBoundedResults().tooLarge)
            browser_ctl_bounded_execution_error=\(browserBoundedResults().executionError)
            browser_ctl_bounded_serialization_error=\(browserBoundedResults().serializationError)
            browser_ctl_bounded_depth=\(browserBoundedResults().depth)
            browser_ctl_bounded_stream=\(browserBoundedResults().stream)
            browser_ctl_console_capture=\(browserConsoleResults().capture)
            browser_ctl_console_clear=\(browserConsoleResults().clear)
            browser_result_pump_actions=\(sortedPumpMs.count)
            browser_result_pump_p95_ms=\(pumpP95Ms)
            browser_result_pump_max_ms=\(pumpMaxMs)
            web_panel_frame_x=\(f.origin.x)
            web_panel_frame_y=\(f.origin.y)
            web_panel_frame_w=\(f.size.width)
            web_panel_frame_h=\(f.size.height)
            web_panel_overlay_open=\(anyOverlayOpen)
            web_panel_hittest_in_web=\(hitInWeb)
            web_panel_focused=\(webFocused)

            """
        }

        // 5c-2c: maru-app:// resolve 정책 C-ABI(maru_macos_app_resolve_app_asset)가 빌드 바이너리에서 실 asset root를
        // 상대로 동작하는지 — 헤드리스 CI 신호(WKWebView 없이 결정적). 스모크 스텝이 MARU_WEB_APP_ROOT=src/platform/macos/web를
        // 준다. 정상=len>0, traversal=-1(Reject), 부재=-2(NotFound). 정책 로직 자체(symlink 탈출·whitelist)는 Zig
        // adversarial 테스트(5c-2a/2b)가 덮으므로 여기선 링크 + 3가지 대표 코드만 확인한다. root 없으면 스킵.
        if let root = MaruAppSchemeHandler.webAssetRoot() {
            // FFI 마샬링은 핸들러와 공유 헬퍼(callResolve) 단일 출처 — 스모크가 별도 복제하지 않는다(리뷰11 [6]).
            func smokeResolve(_ req: String) -> Int64 { MaruAppSchemeHandler.callResolve(root: root, req).code }
            summary += """
            web_app_asset_root=\(root)
            web_app_resolve_index=\(smokeResolve("/index.html"))
            web_app_resolve_traversal=\(smokeResolve("/../etc/passwd"))
            web_app_resolve_missing=\(smokeResolve("/nope.zzz"))

            """
        }
        if smokeMode, let webView = activeSurface?.webPanels.values.first?.webView,
           let roleSmoke = MaruAppSchemeHandler.roleSchemeSmoke(using: webView) {
            summary += """
            web_role_scheme_app_shell_status=\(roleSmoke.appShellStatus)
            web_role_scheme_app_worker_none=\(roleSmoke.appShellCSP.contains("worker-src 'none'"))
            web_role_scheme_app_mermaid_status=\(roleSmoke.appMermaidStatus)
            web_role_scheme_render_shell_status=\(roleSmoke.renderShellStatus)
            web_role_scheme_render_shell_csp=\(roleSmoke.renderShellCSP)
            web_role_scheme_render_document_status=\(roleSmoke.renderDocumentStatus)
            web_role_scheme_render_document_none=\(roleSmoke.renderDocumentCSP.contains("worker-src 'none'"))

            """
        }

        if isScrollbarSmokeMode {
            summary += """
            scroll_thumb_present=\(scrollSmokeThumbPresent)
            scroll_capture_during_drag=\(scrollSmokeCaptureDuringDrag)
            scroll_capture_after_up=\(scrollSmokeCaptureAfterUp)
            scroll_offset_before=\(scrollSmokeOffsetBefore)
            scroll_offset_after=\(scrollSmokeOffsetAfter)
            scroll_move_events=\(scrollSmokeMoveEvents)
            scroll_applications=\(scrollSmokeApplications)

            """
        }

        if isTabDragSmokeMode {
            summary += """
            tab_drag_stage=\(tabDragSmokeStage)
            tab_drag_bar_present=\(tabDragSmokeBarPresent)
            tab_drag_tab_count=\(tabDragSmokeTabCount)
            tab_drag_capture_during_drag=\(tabDragSmokeCaptureDuringDrag)
            tab_drag_capture_after_up=\(tabDragSmokeCaptureAfterUp)
            tab_drag_preview_diverged=\(tabDragSmokePreviewDivergedDuringDrag)
            tab_drag_model_first_before=\(tabDragSmokeModelFirstBefore)
            tab_drag_model_first_during=\(tabDragSmokeModelFirstDuringDrag)
            tab_drag_visible_first_during=\(tabDragSmokeVisibleFirstDuringDrag)
            tab_drag_model_first_after_commit=\(tabDragSmokeModelFirstAfterCommit)
            tab_drag_escape_capture_cleared=\(tabDragSmokeEscapeCaptureCleared)
            tab_drag_escape_model_first=\(tabDragSmokeEscapeModelFirst)
            tab_drag_escape_visible_first=\(tabDragSmokeEscapeVisibleFirst)
            tab_drag_capture_count=\(tabDragSmokeCaptures.count)
            tab_drag_captures=\(tabDragSmokeCaptures.joined(separator: ","))

            """
        }

        if isDividerSmokeMode {
            summary += """
            divider_stage=\(dividerSmokeStage)
            divider_key_status=\(appSessionStatus)
            divider_term_count=\(dividerSmokeTermCount)
            divider_probe_ok=\(dividerSmokeProbeStatusOK)
            divider_ticks=\(dividerSmokeTicks)
            divider_band_present=\(dividerSmokeBandPresent)
            divider_capture_during_drag=\(dividerSmokeCaptureDuringDrag)
            divider_capture_after_up=\(dividerSmokeCaptureAfterUp)
            divider_ratio_before=\(dividerSmokeRatioBefore)
            divider_ratio_after=\(dividerSmokeRatioAfter)
            web_divider_padding=\(webDividerPadding)
            web_divider_covered=\(webDividerCovered)
            web_divider_panel_present=\(webDividerPanelPresent)
            web_divider_seam_edges=\(webDividerSeamEdges)
            web_divider_bands=\(webDividerBands)
            web_divider_frame=\(webDividerFrame)
            web_divider_point_over_panel=\(webDividerHitTestOverPanel)
            web_divider_hittest_passthrough=\(webDividerHitTestPassedThrough)
            web_divider_capture_after_down=\(webDividerCaptureAfterDown)
            divider_move_events=\(dividerSmokeMoveEvents)
            divider_resize_applications=\(dividerSmokeResizeApplications)

            """
        }

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
            // `artifactDirectory`는 상대 경로라 개발/CI(저장소 cwd)에서만 쓸 수 있다. `.app`을 Finder/Dock으로
            // 실행하면 cwd가 "/"여서 쓰기가 실패하고, stdout/stderr도 보이지 않아 종료 요약이 통째로 사라진다.
            // 그 경로에서도 quit_* 계측을 되짚을 수 있어야 하므로 사용자 홈 아래로 폴백한다. 기존 경로가 성공하는
            // 개발/CI에서는 이 분기를 타지 않으므로 아티팩트 계약은 그대로다.
            if let fallback = maruFallbackSummaryFileURL(),
               (try? FileManager.default.createDirectory(
                   at: fallback.deletingLastPathComponent(),
                   withIntermediateDirectories: true
               )) != nil,
               (try? summary.write(to: fallback, atomically: true, encoding: .utf8)) != nil {
                // 저장소 밖 cwd에서 터미널로 직접 실행한 경우처럼 stdout은 살아 있을 수 있다. 성공 경로와 똑같이
                // 요약을 찍어야 파일을 찾아가지 않고도 바로 읽는다(파일 기록과 화면 출력은 서로 대체재가 아니다).
                print(summary, terminator: "")
                print("artifacts written to \(fallback.path)")
                return
            }
            exitCode = 1
            fputs("failed to write \(summaryPath): \(error)\n", stderr)
        }
    }
}

private enum FileTreeTrashMoveOutcome: Sendable {
    case notMoved
    case movedVerified
    case movedUnverified(String?)
}

/// `NSWorkspace.recycle` may move an item even when its destination cannot be verified. Keep that
/// state distinct from not-moved so Zig never attempts rollback against an already-consumed path.
private func fileTreeTrashMoveOutcome(
    _ destinationURLs: [URL: URL],
    stagedURL: URL,
    expectedDevice: UInt64,
    expectedInode: UInt64,
    expectedKind: UInt32
) -> FileTreeTrashMoveOutcome {
    guard destinationURLs.count == 1, let destination = destinationURLs.values.first else {
        return fileTreeTrashIdentityMatches(
            stagedURL,
            expectedDevice: expectedDevice,
            expectedInode: expectedInode,
            expectedKind: expectedKind
        ) ? .notMoved : .movedUnverified(nil)
    }
    return fileTreeTrashIdentityMatches(
        destination,
        expectedDevice: expectedDevice,
        expectedInode: expectedInode,
        expectedKind: expectedKind
    ) ? .movedVerified : .movedUnverified(destination.path)
}

private func fileTreeTrashIdentityMatches(
    _ url: URL,
    expectedDevice: UInt64,
    expectedInode: UInt64,
    expectedKind: UInt32
) -> Bool {
    var destinationStat = Darwin.stat()
    guard url.path.withCString({ Darwin.lstat($0, &destinationStat) }) == 0 else { return false }
    let actualKind: UInt32
    switch destinationStat.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG): actualKind = UInt32(MARU_FILE_TREE_TRASH_KIND_REGULAR)
    case mode_t(S_IFDIR): actualKind = UInt32(MARU_FILE_TREE_TRASH_KIND_DIRECTORY)
    case mode_t(S_IFLNK): actualKind = UInt32(MARU_FILE_TREE_TRASH_KIND_SYMLINK)
    default: actualKind = UInt32(MARU_FILE_TREE_TRASH_KIND_OTHER)
    }
    return UInt64(destinationStat.st_dev) == expectedDevice
        && UInt64(destinationStat.st_ino) == expectedInode
        && actualKind == expectedKind
}

private func reportFileTreeTrashOutcome(
    _ session: OpaquePointer,
    requestId: UInt64,
    outcome: FileTreeTrashMoveOutcome
) {
    switch outcome {
    case .notMoved:
        maru_macos_app_session_complete_file_tree_trash(
            session, requestId, UInt32(MARU_FILE_TREE_TRASH_OUTCOME_NOT_MOVED), nil, 0
        )
    case .movedVerified:
        maru_macos_app_session_complete_file_tree_trash(
            session, requestId, UInt32(MARU_FILE_TREE_TRASH_OUTCOME_MOVED_VERIFIED), nil, 0
        )
    case let .movedUnverified(path):
        let bytes = Array((path ?? "").utf8)
        bytes.withUnsafeBufferPointer { buffer in
            maru_macos_app_session_complete_file_tree_trash(
                session,
                requestId,
                UInt32(MARU_FILE_TREE_TRASH_OUTCOME_MOVED_UNVERIFIED),
                buffer.baseAddress,
                buffer.count
            )
        }
    }
}
