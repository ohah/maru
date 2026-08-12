/// 종료 경로가 정리 **전에** 창을 숨기기 때문에 생기는 창 판정 규칙을 모은다.
///
/// `applicationWillTerminate`는 모래시계를 없애려고 모든 창을 먼저 `orderOut`한다. 그런데 숨겨진 창은
/// `isKeyWindow`가 false여서, 그 뒤에 실행되는 workspace 저장이 "어느 창이 활성이었나"(M3e active-window 마커 —
/// 다음 실행이 그 창을 다시 focus)를 그대로 읽으면 **활성 창 정보가 매 종료마다 사라진다**. 그래서 숨기기 직전의
/// key 창을 붙잡아 두고, 저장은 그 값을 우선 본다.
///
/// AppKit 없이 실행 가능하도록 창을 인덱스로만 다룬다 — 판정 규칙만 떼어내면 실제 종료 없이도 증명할 수 있다
/// (`FilePanelTerminationPolicy`와 같은 규율).
enum TerminationWindowPolicy {
    /// workspace에 `active-window=1`로 표시할 창의 인덱스.
    ///
    /// - Parameters:
    ///   - capturedKeyIndex: 창을 숨기기 직전에 붙잡아 둔 key 창. 종료 경로에서만 채워진다.
    ///   - currentKeyIndex: 지금 `isKeyWindow`인 창. 종료가 아닌 경로의 판정 근거다.
    ///
    /// 붙잡아 둔 값이 있으면 그것이 이긴다 — 종료 중 현재 key 상태는 숨김 때문에 이미 신뢰할 수 없기 때문이다.
    static func activeWindowIndex(capturedKeyIndex: Int?, currentKeyIndex: Int?) -> Int? {
        capturedKeyIndex ?? currentKeyIndex
    }

    /// 활성 창이 아예 없을 수도 있다(모든 창이 비활성인 채 종료 등). 그때는 마커를 붙이지 않는 것이 옛 파일과
    /// 같은 모양이라, 복원은 기본 규칙(첫 창)으로 떨어진다.
    static func isActive(index: Int, capturedKeyIndex: Int?, currentKeyIndex: Int?) -> Bool {
        guard let active = activeWindowIndex(capturedKeyIndex: capturedKeyIndex, currentKeyIndex: currentKeyIndex) else {
            return false
        }
        return active == index
    }
}
