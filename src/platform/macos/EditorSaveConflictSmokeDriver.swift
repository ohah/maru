import Foundation

/// **저장 충돌의 AppKit 경로를 실제로 밟는 스모크**(C0 — docs/native-editor-document-model.md §3.9d).
///
/// 헤드리스 판정자는 `dispatchAppAction(.editor_save)` 를 직접 불러 「이유가 오고 문구가 갈린다」까지
/// 잰다. 이 드라이버가 더하는 것은 **그 앞뒤 두 조각**이다: ⑴ 진짜 `⌘S` 키가 `NSView.keyDown` 의
/// 단축키 우회를 지나 그 디스패치에 닿는가 ⑵ 그 결과로 **디스크가 안 덮이는가**. 둘 다 앱
/// 프로세스 안에서만 관측된다.
///
/// **Zig 도메인 함수를 직접 부르지 않는다**(기존 아카이브 스모크와 같은 규율). 문서를 여는 것은
/// 제품의 유일한 진입점(`MARU_NATIVE_EDITOR`, N1 훅)이고, 글자는 입력기가 쓰는 그 자리
/// (`NSTextInputClient.insertText`), 저장은 **키 이벤트**, 판정은 read-only probe 다.
@MainActor
final class EditorSaveConflictSmokeDriver {
    enum Scenario: String {
        /// 연 뒤 밖에서 바뀐 파일에 `⌘S` — 아무것도 저장되지 않아야 한다.
        case externalConflict = "external-conflict"
        /// 밖에서 바뀌지 않은 파일에 `⌘S` — 조용히 저장되어야 한다(대조군).
        case cleanSave = "clean-save"

        init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard let raw = environment["MARU_EDITOR_SAVE_CONFLICT_SMOKE_SCENARIO"] else { return nil }
            self.init(rawValue: raw)
        }
    }

    /// 어디까지 갔나. 실패하면 **그 단계 이름이 곧 원인**이라 요약에 그대로 싣는다.
    enum Stage: String {
        case notStarted = "not_started"
        case awaitingEditor = "awaiting_editor"
        case typed = "typed"
        case awaitingExternalChange = "awaiting_external_change"
        case saved = "saved"
        case done = "done"
        case failed = "failed"
    }

    /// 드라이버가 누르는 키. **전부 chord 라 `keyDown` 의 IME 우회 갈래**(`!chord.isEmpty` →
    /// `handleKeyDown`)를 탄다 — 합성 `NSEvent` 로는 `interpretKeyEvents` 경로(평키·화살표)가 이
    /// 프로세스에서 재현되지 않기 때문이다.
    enum Key {
        /// `⌘A`. **문서를 연 직후에는 커서가 없다**(`openPathInActivePane` 은 선택을 안 만든다).
        /// 커서가 없으면 글자가 한 자도 안 들어가므로, 사용자가 클릭으로 하는 일을 키로 한다.
        case selectAll
        /// `⌘→`. 전체 선택을 **문서 끝 한 점으로 접는다** — 안 접으면 타이핑이 원문을 지워
        /// 「우리가 넣은 글자가 디스크에 있다」와 「원문이 그대로다」를 함께 못 센다.
        case caretToLineEnd
        /// `⌘S`.
        case save
    }

    /// 호스트가 Zig 에서 읽어 주는 세 사실. 「편집기가 붙었나 · 편집이 남았나 · 무언가 떠 있나」.
    struct Probe {
        let editorPresent: Bool
        let dirty: Bool
        let overlayOpen: Bool
    }

    private(set) var stage: Stage = .notStarted
    private(set) var failure: String = ""
    let scenario: Scenario
    var scenarioName: String { scenario.rawValue }

    /// 스모크가 여는 파일. 스크립트가 만들고, `external-conflict` 에서는 **스크립트가 다시 쓴다**.
    let documentPath: String
    /// 열었을 때 디스크에 있던 내용 — 「밖에서 바뀌었나」와 「덮였나」를 둘 다 이것으로 판정한다.
    private var contentOnDisk: String = ""
    /// 우리가 문서에 넣은 글자. 저장에 성공했다면 디스크에 이것이 있어야 한다.
    private static let typed_marker = "xyz"
    /// **「이제 밖에서 바꿔라」를 스크립트에 알리는 파일.** 고정 `sleep` 으로는 순서가 안 정해진다 —
    /// 편집기가 파일을 읽기 **전에** 스크립트가 다시 쓰면 그것은 충돌이 아니라 그냥 그 파일의 내용이라
    /// 저장이 성공하고, 스모크는 「덮었다」라고 엉뚱하게 실패한다.
    private let readyPath: String?
    private var readyAnnounced = false
    private var ticks: UInt32 = 0

    /// 한 단계가 기다릴 수 있는 tick 상한. 넘으면 **왜 못 갔는지**를 단계 이름으로 남기고 끝낸다 —
    /// 조용히 성공으로 끝나면 이 스모크가 아무것도 증명하지 않는다.
    private static let tick_budget: UInt32 = 900

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let scenario = Scenario(environment: environment) else { return nil }
        guard let path = environment["MARU_NATIVE_EDITOR"], !path.isEmpty else { return nil }
        self.scenario = scenario
        self.documentPath = path
        self.readyPath = environment["MARU_EDITOR_SAVE_CONFLICT_SMOKE_READY"]
    }

    /// 한 번만 쓴다. 두 번 쓰면 스크립트가 이미 바꾼 뒤에 또 신호를 봐 두 번 고칠 수 있다.
    private func announceReady() -> Bool {
        if readyAnnounced { return true }
        guard let readyPath else { return false }
        guard (try? Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)) != nil
        else { return false }
        readyAnnounced = true
        return true
    }

    private func fail(_ reason: String) {
        if stage == .failed { return }
        stage = .failed
        failure = reason
    }

    private func diskContent() -> String? {
        try? String(contentsOfFile: documentPath, encoding: .utf8)
    }

    /// 매 프레임 한 걸음. 입력은 전부 호스트가 주는 클로저다 — 이 타입은 좌표도 Zig 상태도 모른다.
    func tick(
        probe: () -> Probe?,
        typeText: (String) -> Bool,
        pressKey: (Key) -> Bool
    ) {
        if stage == .done || stage == .failed { return }
        ticks += 1
        if ticks > Self.tick_budget {
            fail("budget_exhausted_at_\(stage.rawValue)")
            return
        }

        switch stage {
        case .notStarted:
            guard let before = diskContent() else { return fail("document_missing") }
            contentOnDisk = before
            stage = .awaitingEditor

        case .awaitingEditor:
            // N1 훅이 여는 것을 기다린다. 「붙었나」는 probe 가 답한다.
            guard let p = probe(), p.editorPresent else { return }
            // 이미 dirty 면 우리가 넣은 글자와 남의 편집을 못 가른다 — 그 판은 쓰지 않는다.
            guard !p.dirty else { return fail("document_dirty_before_typing") }
            guard pressKey(.selectAll), pressKey(.caretToLineEnd) else { return fail("caret_key_refused") }
            guard typeText(Self.typed_marker) else { return fail("type_refused") }
            guard let after = probe(), after.dirty else { return fail("typing_left_document_clean") }
            stage = .typed

        case .typed:
            switch scenario {
            case .cleanSave:
                stage = .saved
                guard pressKey(.save) else { return fail("save_key_refused") }
            case .externalConflict:
                // 신호를 못 남기면 기다릴 상대가 없다 — budget 을 태우지 말고 바로 말한다.
                guard announceReady() else { return fail("ready_signal_unwritable") }
                stage = .awaitingExternalChange
            }

        case .awaitingExternalChange:
            // **스크립트가 다른 프로세스에서 다시 쓴다** — 우리가 쓰면 「밖에서」가 아니다.
            guard let now = diskContent() else { return fail("document_vanished") }
            if now == contentOnDisk { return } // 아직 안 바뀌었다
            contentOnDisk = now // 이제 이것이 「덮이지 않아야 하는 내용」이다
            stage = .saved
            guard pressKey(.save) else { return fail("save_key_refused") }

        case .saved:
            guard let now = diskContent() else { return fail("document_vanished_after_save") }
            guard let p = probe() else { return fail("probe_gone_after_save") }
            switch scenario {
            case .externalConflict:
                // ⑴ **디스크가 안 덮였다** — 이 스모크의 값이 여기 있다.
                if now != contentOnDisk { return fail("overwrote_external_change") }
                // ⑵ **말했다** — 알림이 떠 있다.
                guard p.overlayOpen else { return fail("no_notice_after_conflict") }
                // ⑶ **편집이 살아 있다** — dirty 로 남아야 한다.
                guard p.dirty else { return fail("conflict_left_document_clean") }
            case .cleanSave:
                // 대조군: 저장이 되고 **조용하다**. 이 갈래가 없으면 「전부 거절」도 통과한다.
                guard now.contains(Self.typed_marker) else { return fail("clean_save_did_not_write") }
                if p.overlayOpen { return fail("clean_save_showed_notice") }
                if p.dirty { return fail("clean_save_left_dirty") }
            }
            stage = .done

        case .done, .failed:
            return
        }
    }
}
