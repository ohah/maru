// 앱 종료 단계 계측(`TerminationTiming`)이 종료 요약에 **안정된 모양**으로 실린다는 것을 증명한다.
//
// 왜 터미널에서 중요한가: 종료 경로는 메인 스레드에서 동기로 돌아 그동안 UI가 멈춘다. 사용자가 겪는 "종료할 때
// 몇 초 멈춤"을 고치려면 어느 단계가 그 시간을 쓰는지 먼저 보여야 하는데, 실제 종료는 앱을 죽여야만 재현되므로
// 자동 검증이 어렵다. 그래서 시간 측정 자체는 host가 하고, **모으고 표현하는 규칙**만 여기서 결정론적으로
// 고정한다. 필드가 빠지거나 이름이 흔들리면 요약을 비교하는 쪽이 조용히 깨지므로 그것을 막는 것이 이 테스트다.
@main
struct TerminationTimingTests {
    static func main() {
        // 실행 경로와 무관하게 필드 집합이 항상 같아야 한다 — 안 돈 단계도 0으로 남아야 비교가 가능하다.
        let empty = TerminationTiming()
        let emptyLines = empty.summaryLines()
        precondition(emptyLines == [
            "quit_hide_windows_ms=0.0",
            "quit_mermaid_ms=0.0",
            "quit_control_stop_ms=0.0",
            "quit_save_workspace_ms=0.0",
            "quit_teardown_ms=0.0",
            "quit_total_ms=0.0",
        ])

        // 요약 출력 순서는 실제 종료 실행 순서다(창 숨김 → mermaid → control server → workspace → teardown).
        // mermaid보다 control server가 먼저 나오면 host 경계 계약과 어긋난 배선을 읽는 사람이 오해한다.
        precondition(TerminationTiming.Stage.allCases.map(\.key) == [
            "hide_windows", "mermaid", "control_stop", "save_workspace", "teardown",
        ])

        // 같은 단계를 나눠 기록하면 누적된다 — 한 단계가 호출부에서 여러 조각으로 갈려도 합이 그 단계 비용이다.
        var timing = TerminationTiming()
        timing.record(.mermaid, elapsedNs: 200_000_000)
        timing.record(.mermaid, elapsedNs: 50_000_000)
        precondition(timing.elapsed(.mermaid) == 250_000_000)

        // 단계 합과 total은 따로다. 차이가 남으면 단계로 나누지 않은 잔여 시간이 있다는 신호여야 한다.
        timing.record(.teardown, elapsedNs: 96_000_000)
        timing.recordTotal(elapsedNs: 2_000_000_000)
        let lines = timing.summaryLines()
        precondition(lines.contains("quit_mermaid_ms=250.0"))
        precondition(lines.contains("quit_teardown_ms=96.0"))
        precondition(lines.contains("quit_total_ms=2000.0"))
        // 안 돈 단계는 여전히 0으로 실린다(필드 누락 없음).
        precondition(lines.contains("quit_control_stop_ms=0.0"))

        // 0.1ms 단위 반올림: 로케일이나 Foundation 포맷터에 기대지 않고 정수 연산만으로 안정적이어야 한다.
        precondition(TerminationTiming.millisText(0) == "0.0")
        precondition(TerminationTiming.millisText(49_999) == "0.0") // 0.05ms 미만은 내려간다
        precondition(TerminationTiming.millisText(50_000) == "0.1") // 경계에서 올라간다
        precondition(TerminationTiming.millisText(1_000_000) == "1.0")
        precondition(TerminationTiming.millisText(12_340_000) == "12.3")
        precondition(TerminationTiming.millisText(12_360_000) == "12.4")
        // 초 단위도 소수점이 한 자리로 유지된다(종료가 실제로 초 단위일 때가 관심 대상이다).
        precondition(TerminationTiming.millisText(2_500_000_000) == "2500.0")

        // 경과 시간은 두 시각의 뺄셈에서 오므로, 그 가정이 깨져 wrap된 거대값이 흘러들어올 수 있다. 그때 반올림
        // 덧셈이 오버플로로 trap하면 **종료 요약을 쓰다가 앱이 죽는다** — 지연을 진단하려는 계측이 종료 자체를
        // 크래시로 바꾸는 최악의 회귀다. 값이 헛되게 보일지언정 trap하지 않아야 한다는 것을 여기서 고정한다.
        _ = TerminationTiming.millisText(UInt64.max)
        _ = TerminationTiming.millisText(UInt64.max - 49_999)
        var wrapped = TerminationTiming()
        wrapped.record(.teardown, elapsedNs: UInt64.max)
        wrapped.recordTotal(elapsedNs: UInt64.max)
        _ = wrapped.summaryBlock()

        // 누적도 wrapping이라 포화 근처에서 trap하지 않는다(같은 이유 — 계측이 앱을 죽이면 안 된다).
        var saturating = TerminationTiming()
        saturating.record(.mermaid, elapsedNs: UInt64.max)
        saturating.record(.mermaid, elapsedNs: 2)
        _ = saturating.summaryLines()

        // 블록 형태는 라인들을 개행으로 이은 것과 같아야 한다 — 요약 본문에 그대로 끼워 넣기 때문이다.
        precondition(timing.summaryBlock() == timing.summaryLines().joined(separator: "\n"))
    }
}
