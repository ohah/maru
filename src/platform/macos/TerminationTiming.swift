/// 앱 종료(`applicationWillTerminate`) 각 단계가 실제로 얼마나 걸렸는지를 모아 종료 요약의 `quit_*` 필드로
/// 만든다. 종료 경로는 전부 메인 스레드에서 동기로 도는데, 그동안 이벤트 루프가 멈춰 사용자에게는 모래시계로
/// 보인다. 어느 단계가 그 시간을 쓰는지는 관측 없이는 추측밖에 할 수 없어서, 단계별 경과를 남기는 것이 종료
/// 지연을 고치기 위한 첫 단계다(docs/macos-app-host-boundary.md "앱 전체 종료").
///
/// 시계를 직접 읽지 않고 **이미 측정된 경과 ns를 받기만** 한다. 그래야 AppKit도 실제 시간도 없이 순수하게
/// 테스트할 수 있다(`FilePanelTerminationPolicy`와 같은 규율 — host 배선은 수동 E2E, 판정은 단위 테스트).
struct TerminationTiming {
    /// 종료 경로의 단계. 순서는 `applicationWillTerminate`의 실제 실행 순서이며, 요약 출력 순서이기도 하다.
    /// mermaid → control server 순서는 host 경계 계약이라(docs/macos-app-host-boundary.md §mermaid) 여기서도
    /// 그 순서를 그대로 반영한다.
    enum Stage: Int, CaseIterable {
        /// 창을 화면에서 내리는 단계. 정리보다 먼저 해서 체감 지연을 없앤다.
        case hideWindows
        /// mermaid reply 취소 + coordinator/Zig 회수.
        case mermaid
        /// 컨트롤 플레인 서버 정지(accept 스레드 join + 살아있는 연결 스레드 대기).
        case controlServer
        /// workspace 스냅샷 직렬화와 atomic write.
        case saveWorkspace
        /// 세션·PTY·렌더러 teardown.
        case teardown

        /// 요약 필드 이름(`quit_<key>_ms`). 값 자체가 계약이므로 rawValue 순번과 분리해 둔다.
        var key: String {
            switch self {
            case .hideWindows: return "hide_windows"
            case .mermaid: return "mermaid"
            case .controlServer: return "control_stop"
            case .saveWorkspace: return "save_workspace"
            case .teardown: return "teardown"
            }
        }
    }

    /// 단계별 경과 ns. 실행되지 않은 단계(예: 컨트롤 서버 미시작)는 0으로 남아 "시간을 쓰지 않았다"는 뜻이
    /// 되므로, 요약 필드 집합은 실행 경로와 무관하게 항상 같은 모양이다.
    private var elapsedNs = [UInt64](repeating: 0, count: Stage.allCases.count)
    private var totalNs: UInt64 = 0

    init() {}

    /// 한 단계의 경과를 기록한다. 같은 단계를 여러 번 기록하면 **누적**한다 — 한 단계가 호출부에서 여러
    /// 조각으로 나뉘어도(예: mermaid 취소와 회수) 합계가 그 단계의 비용이 되게 하기 위해서다.
    mutating func record(_ stage: Stage, elapsedNs ns: UInt64) {
        elapsedNs[stage.rawValue] &+= ns
    }

    /// 종료 경로 전체의 경과. 단계 합과 따로 두는 이유는, 단계로 나누지 않은 잔여 시간(AppKit 자체 처리 등)이
    /// 있으면 total과 단계 합의 차이로 드러나기 때문이다.
    mutating func recordTotal(elapsedNs ns: UInt64) {
        totalNs = ns
    }

    func elapsed(_ stage: Stage) -> UInt64 {
        elapsedNs[stage.rawValue]
    }

    /// ns를 0.1ms 단위로 반올림해 `12.3` 같은 문자열로 만든다. Foundation의 `String(format:)`을 쓰지 않는 것은
    /// 이 타입을 의존성 없이 테스트 바이너리로 링크하기 위해서다(로케일 영향도 받지 않는다).
    ///
    /// 반올림 덧셈은 **반드시 wrapping(`&+`)이어야 한다**. 경과 시간은 두 시각의 뺄셈으로 오는데, 어떤 이유로든
    /// 끝 시각이 시작보다 작게 잡히면 그 뺄셈이 wrap해 UInt64 최대치에 가까운 값이 된다. 그 값에 일반 `+`를 쓰면
    /// Swift가 오버플로로 **프로세스를 trap**시킨다 — 종료 지연을 진단하려고 넣은 계측이 종료 자체를 크래시로
    /// 바꾸는 최악의 형태다. 값이 이상해도 숫자가 이상하게 보일 뿐 앱은 정상적으로 끝나야 한다.
    static func millisText(_ ns: UInt64) -> String {
        let tenths = (ns &+ 50_000) / 100_000 // 0.05ms 반올림 후 0.1ms 단위
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// 종료 요약에 실을 `key=value` 라인들. 순서는 Stage 선언 순서(=실행 순서) 뒤에 total이다.
    func summaryLines() -> [String] {
        var lines = Stage.allCases.map { "quit_\($0.key)_ms=\(Self.millisText(elapsedNs[$0.rawValue]))" }
        lines.append("quit_total_ms=\(Self.millisText(totalNs))")
        return lines
    }

    /// 요약 본문에 그대로 끼워 넣을 수 있는 개행 구분 블록.
    func summaryBlock() -> String {
        summaryLines().joined(separator: "\n")
    }
}
