//! 스크롤백 Find(⌘F) orchestration — 토글·증분 재검색·매치 네비게이션·뷰 스크롤.
//!
//! `app_session.zig`(20k줄 단일 `AppSession` struct)에서 목적별로 떼어낸 첫 그룹이다
//! (E1, docs/app-session-decomposition.md). UI 상태(검색어/현재/카운트)는 chrome 컴포넌트
//! (`chrome_host.find`)가, 매치 리스트(`terminal.Match`)는 session(`find_matches`)이 소유하고,
//! 여긴 그 둘을 잇는 **platform orchestration**(코어 검색 락·뷰 스크롤·재렌더 신호)이다.
//! 순수 로직이 아니라 `chrome_host`·`activeSurface().core`·`runtime`에 결합하므로 L4(app_session)에
//! 남고 session(L2)으로 가지 않는다(이식 무관 — 가독성·탐색 목적의 분리).
//!
//! 패턴: `*AppSession`을 받는 free 함수(Zig는 필드 privacy가 없어 필드를 직접 접근)로 두고,
//! `app_session.zig`가 import해 얇은 facade로 위임한다 — `core.zig`가 `screen.zig`를 부르는
//! 방식과 동형(docs/terminal-core-decomposition.md). 그룹 내부 상호 호출은 free 함수 직접.

const builtin = @import("builtin");

const AppSession = @import("../app_session.zig").AppSession;
const term_ops = @import("term.zig");

/// ⌘F: Find 오버레이를 토글한다. 열려 있으면 닫고(매치 하이라이트·⌘G 닫힘-네비 세션 종료),
/// 닫혀 있으면 다른 배타 오버레이(notice·palette)를 먼저 닫고 연다(검색어 초기화는 컴포넌트의 show가).
pub fn toggleFind(self: *AppSession) void {
    if (self.chrome_host.find.open) {
        self.chrome_host.find.hide();
        self.find_matches.clearRetainingCapacity(); // 닫힘 — 하이라이트 중단
        self.find_nav = false; // ⌘G 닫힘-네비 세션도 종료
    } else {
        // alt screen(vim/less/Claude/Codex)에서도 연다 — alt에선 findMatches가 현재 화면만 검색해 매치를
        // 하이라이트한다(스크롤백 매치 제외, 스크롤 네비는 무의미·무동작). 과거엔 iTerm2 관례로 막았으나,
        // 자체 검색이 없는 TUI(Claude/Codex)를 위해 연다. 베이스: Ghostty(alt에서 active area 검색).
        self.chrome_host.notice.dismiss(); // 배타적 — notice 위에 열지 않는다
        self.chrome_host.palette.hide();
        self.chrome_host.find.show(); // show가 검색어/현재/카운트를 비운다(새 검색)
        self.find_nav = false; // 오버레이가 주도 — 닫힘-네비 플래그 해제
    }
}

/// ⌘G/⌘⇧G: chrome_host.find가 검색어를 보존하므로, 닫은 뒤에도 그 검색어로 재검색해 네비게이션한다
/// (macOS Find Next 관례). 검색 이력(검색어)이 없으면 무동작. 닫을 때 매치를 비웠으니 비어 있으면 보존
/// 검색어로 다시 채우고(현재 인덱스는 닫기 전 위치 유지 — setMatchCount가 범위 clamp), find_nav를 세워
/// 하이라이트(현재 매치)·출력 시 재검색을 닫힌 채로도 유지한다. 오버레이가 열려 있으면 모달 라우팅이 키를
/// 가로채 이 경로는 안 탄다.
pub fn findNavigate(self: *AppSession, forward: bool) void {
    if (!self.surface_initialized) return;
    if (self.chrome_host.find.input.query.items.len == 0) return; // 검색 이력 없음 — 무동작
    if (self.find_matches.items.len == 0) {
        // findMatches는 코어 mutate(스크롤백 rewrap)+읽기 — 락 아래(docs/io-render-threading.md PR3, 리더 경합 방지).
        const s = term_ops.activeSurface(self);
        s.lockCore(self.io);
        s.core.findMatches(self.allocator, self.chrome_host.find.input.query.items, &self.find_matches) catch self.find_matches.clearRetainingCapacity();
        s.unlockCore(self.io);
        self.chrome_host.find.setMatchCount(self.find_matches.items.len); // current를 범위로 clamp(닫기 전 위치 보존)
    }
    if (self.find_matches.items.len == 0) return; // 매치 없음
    self.find_nav = true;
    if (forward) self.chrome_host.find.next() else self.chrome_host.find.prev();
    scrollToCurrentMatch(self);
    self.metal_dirty = true;
}

/// 현재 검색어로 활성 surface를 다시 검색해 find_matches를 채우고, 현재 인덱스를 첫 매치로 리셋한 뒤 뷰로
/// 스크롤한다(증분 검색 — 타이핑·Backspace마다). 검색어가 비면 매치 0. OOM이면 매치를 비워 안전하게 둔다.
/// chrome_host.find.match_count를 동기화해(setMatchCount) 컴포넌트의 카운터·next/prev wrap이 맞게 한다.
pub fn recomputeFind(self: *AppSession) void {
    if (!self.surface_initialized) return;
    {
        // findMatches는 코어 mutate(ensureScrollbackRewrapped로 스크롤백 realloc)+읽기 — 락 아래
        // (docs/io-render-threading.md PR3 — 리더 core.write와 경합 시 UAF/크래시 방지).
        const s = term_ops.activeSurface(self);
        s.lockCore(self.io);
        defer s.unlockCore(self.io);
        s.core.findMatches(self.allocator, self.chrome_host.find.input.query.items, &self.find_matches) catch {
            self.find_matches.clearRetainingCapacity();
        };
    }
    self.chrome_host.find.setMatchCount(self.find_matches.items.len);
    self.chrome_host.find.current = 0; // 재검색은 첫 매치로 리셋(증분)
    scrollToCurrentMatch(self);
}

/// 현재(네비게이션) 매치를 뷰포트로 스크롤한다 — 없으면 무동작. 검색·네비게이션 후 호출(scrollToAbs가
/// 매치를 세로 중앙쯤에 둬 Find 오버레이(활성 pane 상단 한 줄)에 안 가린다). 현재 인덱스는 chrome_host.find.current.
///
/// §6c host-backed 분기가 **여기 한 곳**에 있다: 스크롤백 매치로의 스크롤은 host가 소유한 view를 움직여야
/// 하므로(placeholder는 미렌더) 다음 tick의 `refreshRemoteFind`가 scroll=true로 host를 현재 매치로 스크롤하도록
/// 표시만 한다(one-shot). 예전엔 이 분기가 app_session의 facade에만 있어, 그룹 내부에서 free 함수로 직접 부르는
/// `recomputeFind`(증분 검색)가 분기를 우회했다 — 원격에서만 타이핑 중 매치로 스크롤이 안 되던 원인이다.
pub fn scrollToCurrentMatch(self: *AppSession) void {
    if (!self.surface_initialized) return;
    if (builtin.os.tag == .macos and term_ops.activeSurface(self).remote != null) {
        self.remote_find_scroll_pending = true;
        self.remote_find_dirty = true;
        return;
    }
    const cur = self.chrome_host.find.current;
    if (cur >= self.find_matches.items.len) return;
    const surface = term_ops.activeSurface(self);
    // scrollToAbs는 코어 mutate라 reader로 위임(full (a), docs/io-render-threading.md §9 P3-4).
    self.runtime.enqueueCoreCommand(surface.id, .{ .scroll_to_abs = self.find_matches.items[cur].start.row }, self.io) catch {};
}
