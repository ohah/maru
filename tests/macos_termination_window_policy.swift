// 종료 중 창을 미리 숨겨도 workspace의 활성 창 마커가 살아남는다는 것을 증명한다.
//
// 왜 터미널에서 중요한가: 종료 경로는 모래시계를 없애려고 정리 전에 모든 창을 숨기는데, 숨겨진 창은
// `isKeyWindow`가 false다. 그 상태로 workspace를 저장하면 "다시 열 때 어느 창을 focus할지"(M3e)가 **매 종료마다
// 사라져** 여러 창을 쓰는 사용자가 항상 엉뚱한 창을 마주한다. 실제 창 숨김은 앱을 죽여야 재현되므로, 판정 규칙만
// 떼어 여기서 고정한다 — 이 테스트가 없으면 같은 회귀가 조용히 돌아온다.
@main
struct TerminationWindowPolicyTests {
    static func main() {
        // 종료 경로: 숨기기 직전에 붙잡은 창이 이긴다. 숨김 탓에 현재 key가 없어져도(nil) 마커는 유지된다.
        precondition(TerminationWindowPolicy.activeWindowIndex(capturedKeyIndex: 2, currentKeyIndex: nil) == 2)
        precondition(TerminationWindowPolicy.isActive(index: 2, capturedKeyIndex: 2, currentKeyIndex: nil))
        precondition(!TerminationWindowPolicy.isActive(index: 0, capturedKeyIndex: 2, currentKeyIndex: nil))

        // 붙잡은 값이 현재 key와 다르면 붙잡은 쪽이 이긴다 — 종료 중 현재 key는 숨김 때문에 신뢰할 수 없다.
        precondition(TerminationWindowPolicy.activeWindowIndex(capturedKeyIndex: 1, currentKeyIndex: 0) == 1)

        // 종료가 아닌 경로(붙잡은 값 없음)는 기존대로 현재 key로 판정한다.
        precondition(TerminationWindowPolicy.activeWindowIndex(capturedKeyIndex: nil, currentKeyIndex: 3) == 3)
        precondition(TerminationWindowPolicy.isActive(index: 3, capturedKeyIndex: nil, currentKeyIndex: 3))

        // 활성 창이 없으면 마커를 붙이지 않는다 — 옛 파일과 같은 모양이라 복원이 기본 규칙(첫 창)으로 떨어진다.
        precondition(TerminationWindowPolicy.activeWindowIndex(capturedKeyIndex: nil, currentKeyIndex: nil) == nil)
        precondition(!TerminationWindowPolicy.isActive(index: 0, capturedKeyIndex: nil, currentKeyIndex: nil))

        // 마커는 최대 하나여야 한다 — 창 목록 전체에 대해 참이 되는 인덱스가 둘 이상이면 복원이 모호해진다.
        let windowCount = 5
        let activeFlags = (0..<windowCount).map {
            TerminationWindowPolicy.isActive(index: $0, capturedKeyIndex: 4, currentKeyIndex: 1)
        }
        precondition(activeFlags.filter { $0 }.count == 1)
        precondition(activeFlags[4])
    }
}
