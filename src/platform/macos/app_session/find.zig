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
const Term = @import("../app_session.zig").Term;
const term_ops = @import("term.zig");
const editor_ops = @import("editor.zig");
const pane_ops = @import("pane.zig");
const maru = @import("maru");
const terminal = maru.terminal;

/// ⌘F가 지금 **무엇을** 검색하는가 — 활성 Term이 네이티브 편집기면 그 Term(아니면 `null`).
///
/// **이 함수가 이 슬라이스의 핵심이다.** 그전까지 ⌘F는 갈래 없이 `activeSurface().core`를 검색했고,
/// 편집기 Term의 코어는 **1×1 sentinel**이다(`createEditorTerm` — 텍스트는 `rt.editor_lines`에 있다).
/// 그래서 편집기 pane에서 ⌘F는 "기능이 없다"가 아니라 **매치 0을 조용히 답하고** 있었다.
///
/// **비교 뷰도 검색한다**(2026-09-01, §5.1 「비교 뷰 검색」). 이 주석은 오래 *"아직 아니다 — 좌우
/// 판정이 선행한다"* 로 막고 있었는데, **그 선행은 이미 서 있었다**: 열 히트테스트(`isRightColumn`)는
/// 2026-08-17 에 섰고, 그보다 중요하게 **선택이 이미 자기 열을 기억한다**(`editor_diff_selection`).
/// 어느 열인지는 `editor_ops.diffSearchSide` 가 답한다 — 선택이 있는 열, 없으면 왼쪽.
fn activeEditorTerm(self: *AppSession) ?*Term {
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return null;
    // **비교 뷰도 검색한다**(§5.1 「비교 뷰 검색」 — 2026-09-01). 어느 열인지는
    // `editor_diff.diffSearchSide` 가 답한다(선택이 있는 열, 없으면 왼쪽).
    if (editor_ops.findLines(self, term).len == 0) return null; // 아직 안 열렸다(비교면 그 열이 비었다)
    return term;
}

/// 활성 Term이 네이티브 편집기 문서인가 — tick이 `find.target`을 세울 때 묻는다.
///
/// **`activeEditorTerm`과 같은 판정이어야 한다.** 둘이 갈리면 target은 `.editor`인데 검색은
/// 스크롤백으로 가는(또는 그 반대) 상태가 나고, 그것은 화면이 말하는 것과 실제가 다른 부류다.
pub fn activeTermIsEditor(self: *AppSession) bool {
    return activeEditorTerm(self) != null;
}

/// 지금 편집기 매치가 **어느 Term의 것이어야 하는가**(0 = 편집기가 아니거나 검색이 꺼져 있다).
///
/// **tick이 매 프레임 이 값과 `editor_find_source`를 대조한다.** `target` 값만 비교하던 초판은
/// 편집기 A → 편집기 B 전환에서 **둘 다 `.editor`라 분기가 안 열렸고**, 그래서
///   - B가 재검색되지 않아 **강조가 하나도 안 그려지고**(출처 id가 A라 `isFindTarget`이 막는다),
///   - 카운터는 A의 수를 계속 말하고,
///   - Enter는 A의 줄 번호로 B를 굴리려 했다(그쪽은 `revealCurrentFindMatch`의 출처 검사가 막는다).
///
/// 같은 게이트가 **Term 닫기**(다음 활성이 다른 편집기)와 **웹으로 이동**(target이 `.page`라
/// 재검색 갈래를 건너뛰는데 렌더는 모든 leaf를 돈다)도 함께 닫는다 — 셋이 한 뿌리였다.
/// 전환 경로마다 세우지 않고 **매 tick 대조**하는 것이 이 파일 이웃(`target` 동기화)의 규율이다.
pub fn wantedEditorFindSource(self: *AppSession) u64 {
    if (!(self.chrome_host.find.open or self.find_nav)) return 0;
    const term = activeEditorTerm(self) orelse return 0;
    return term.surfaceId();
}

/// 편집기 문서를 다시 검색한다. 매치가 **어느 Term의 것인지** 함께 싣는다(`editor_find_source`) —
/// 그 표식이 없으면 pane을 바꾼 다음 프레임이 남의 좌표를 이 문서에 칠한다.
fn recomputeEditorFind(self: *AppSession, term: *Term) void {
    maru.session.editor.find.findMatches(
        self.allocator,
        editor_ops.findLines(self, term),
        self.chrome_host.find.input.query.items,
        // 토글은 **편집기 타깃에만** 산다(§5.1) — 스크롤백·웹은 이 값을 안 읽는다.
        .{ .match_case = self.chrome_host.find.match_case, .whole_word = self.chrome_host.find.whole_word },
        &self.editor_find_matches,
    ) catch self.editor_find_matches.clearRetainingCapacity();
    // **매치가 0이어도 출처를 세운다.** 이 값의 뜻은 "몇 개 찾았나"가 아니라 **"이 목록이 어느
    // 문서의 것인가"**다. 0일 때 비워 두면 tick의 대조가 매 프레임 "안 맞는다"고 답해 재검색이
    // 무한히 돈다. 매치가 없으면 `buildFindMarks`가 `null`을 주므로 강조는 어차피 안 그려진다.
    // **「선택 영역 내에서만」은 여기 한 곳에서 거른다**(§5.1). 카운터·막대 마커·Enter 이동·
    // 「전부 바꾸기」가 모두 이 목록을 읽으므로, 소비처마다 범위를 다시 보게 하면 **한 곳만
    // 빠뜨려도 그 자리가 조용히 문서 전체를 건드린다** — 특히 「전부 바꾸기」가 그렇다.
    if (self.chrome_host.find.in_selection) |sel| blk: {
        const doc = term.rt.editor_doc orelse break :blk;
        var kept: usize = 0;
        for (self.editor_find_matches.items) |m| {
            // 매치는 `(줄, 줄 안 byte)` 이고 범위는 문서 offset 이라 축이 다르다 — `matchRange` 가
            // 이미 그 변환을 갖고 있으므로 두 번째 변환을 만들지 않는다.
            const r = editor_ops.matchRangePublic(doc, m) orelse continue;
            if (r.start >= sel.start and r.end <= sel.end) {
                self.editor_find_matches.items[kept] = m;
                kept += 1;
            }
        }
        self.editor_find_matches.shrinkRetainingCapacity(kept);
    }

    self.editor_find_source = term.surfaceId();
    self.chrome_host.find.setMatchCount(self.editor_find_matches.items.len);
}

/// 찾기 줄에 **적을 열** — 활성 편집기가 없거나 비교 뷰가 아니면 `null`(§5.1).
///
/// **이 값을 쓰는 자리는 tick 대조 하나다.** 재검색에도 같은 줄을 두었다가 적대적 검증에서
/// 지워도 아무 판정자가 안 빨개졌다(변이 M10) — tick 이 이미 매 프레임 덮고, 화면은 그 tick 안에서
/// 그려지기 때문이다. 두 자리에서 쓰면 **두 번째 출처**가 되고, 갈리는 날 「그린 열과 센 열이
/// 다르다」가 된다. 그래서 죽은 쪽을 지우고 답하는 자리를 하나로 뒀다.
pub fn activeFindDiffSideShown(self: *AppSession) ?editor_ops.DiffSide {
    const term = activeEditorTerm(self) orelse return null;
    if (term.rt.editor_diff == null) return null;
    return editor_ops.diffSearchSide(self, term);
}

/// 편집기 매치를 버린다 — 검색을 닫거나 대상이 편집기가 아니게 됐을 때.
/// `recomputeEditorFind`를 그룹 밖(편집기 연산)에서 부르기 위한 자리. **바꾸기가 문서를 고친
/// 직후 매치 목록은 낡는다** — 낡은 목록으로 다음 자리를 고르면 엉뚱한 offset을 집는다.
pub fn recomputeEditorFindPublic(self: *AppSession, term: *Term) void {
    recomputeEditorFind(self, term);
}

pub fn clearEditorFind(self: *AppSession) void {
    self.editor_find_matches.clearRetainingCapacity();
    self.editor_find_source = 0;
}

/// **검색 하이라이트를 멈춘다** — 매치 목록 둘과 ⌘G 닫힘-네비 세션까지.
///
/// **왜 헬퍼인가.** 목록이 둘이라는 사실이 호출자마다 흩어지면 반드시 한쪽만 비우는 자리가
/// 남는다 — 실제로 남았다. 초판은 `toggleFind`와 `.find_close` 둘만 짝을 맞췄고, 같은 성질의
/// 나머지 자리들(커맨드 팔레트·설정 화면·모달 정리·인라인 rename)은 `find_matches`만 비웠다.
/// 터미널에서는 목록이 비어 증상이 안 보이지만, 편집기는 `find_nav`가 살아 있어 **오버레이가
/// 사라졌는데 강조가 남았다**(적대적 검증 2026-08-23).
///
/// **`find_nav`까지 내리는 것이 핵심이다.** 목록만 비우면 tick의 출처 대조가 `find_nav` 참을
/// 보고 **한 프레임 뒤에 되살린다** — 게다가 `recomputeFind`가 `current = 0`으로 리셋하고
/// `scrollToCurrentMatch`까지 부르므로 **편집기가 팔레트 뒤에서 맨 위로 튄다**(2라운드 검증이
/// 283 → 0을 실측). 1라운드 R7이 잡았던 실패가 그 문으로 다시 열렸던 것이다.
///
/// **부르는 자리의 규칙**: 오버레이를 `hide()`**하거나 `show()`하는** 곳은 전부 이것을 함께 부른다.
/// `toggleFind`도 예외가 아니다 — 그 함수가 두 줄을 손으로 펴 두었던 것이 "흩어지면 안 된다"는
/// 이 헬퍼의 이유를 스스로 어긴 자리였다.
///
/// **`show()`가 규칙에 든 이유**: 그 함수는 컴포넌트 상태(검색어·현재·카운트)만 비우고 목록은
/// 세션 소유라 안 건드린다. 초판 규칙이 `hide()`만 말해서, ⌘G 네비 중 ⌘F를 다시 열면 **빈
/// 검색 상자에 옛 강조가 그대로 칠해져 있었다**(카운터는 0을 말하면서). 편집기와 터미널 양쪽에서
/// 같은 모양이었다.
pub fn clearAllFindMatches(self: *AppSession) void {
    self.find_matches.clearRetainingCapacity();
    clearEditorFind(self);
    self.find_nav = false;
}

/// ⌥⌘F: 찾기를 **바꾸기 줄과 함께** 연다(§5.1).
///
/// **이미 열려 있으면 닫지 않고 바꾸기 줄만 켠다.** ⌘F로 검색어를 친 뒤 "바꿔야겠다"고 생각하는
/// 것이 흔한 순서인데, 여기서 닫아 버리면 방금 친 검색어가 사라진다.
pub fn toggleFindReplace(self: *AppSession) void {
    if (!self.chrome_host.find.open) toggleFind(self);
    if (!self.chrome_host.find.open) return; // 토글이 닫는 쪽이었다면 그대로 둔다
    self.chrome_host.find.replace_open = true;
    self.chrome_host.find.focus = .replace; // 바꿀 문자열을 치러 온 것이다
    self.metal_dirty = true;
}

/// 찾기가 **열려 있는 동안** 규칙 토글 chord 를 가로챈다(§5.1).
///
/// **왜 사전 가로채기가 필요한가.** 오버레이가 열리면 `handleKeyEvent` 가 *"모든 키를 소비한다
/// (모달이라 터미널엔 안 내려간다)"* 로 라우팅해 `chrome_host.handleInput` 에 넘긴다 — 그래서
/// 키바인딩 해석에 **도달하지 못한다**. 그런데 이 두 토글은 **찾기가 떠 있을 때 쓰는 것**이라
/// 닫고 눌러야 한다면 있으나 마나다. 설정 팔레트의 ←→ 가 같은 이유로 같은 자리를 쓴다
/// (`settingsPaletteArrowIntercept`).
///
/// 사용자 바인딩을 존중한다 — 빌트인 chord 모양을 직접 보지 않고 `resolve` 가 낸 액션으로 판정한다.
pub fn findRuleChordIntercept(self: *AppSession, event: terminal.KeyEvent) bool {
    if (!isEditorFindTarget(self)) return false;
    var buf: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolved = self.loaded_config.keyBindingResolver().resolve(event, &buf, .{}) catch return false;
    const action = switch (resolved) {
        .app_action => |a| a,
        else => return false,
    };
    switch (action) {
        .toggle_find_match_case => toggleFindMatchCase(self),
        .toggle_find_whole_word => toggleFindWholeWord(self),
        .toggle_find_in_selection => toggleFindInSelection(self),
        .toggle_find_diff_side => toggleFindDiffSide(self),
        else => return false,
    }
    return true;
}

/// ⌥⌘C: 대소문자를 가릴지 토글한다(§5.1). **편집기 문서에서만** 뜻이 있다.
///
/// **오버레이를 열지 않는다.** 찾기가 안 떠 있으면 토글해도 사용자가 그 사실을 볼 자리가 없고,
/// 다음에 ⌘F 를 눌렀을 때 **켠 기억이 없는 규칙**으로 검색되어 결과가 틀린 것처럼 보인다.
pub fn toggleFindMatchCase(self: *AppSession) void {
    if (!isEditorFindTarget(self)) return;
    self.chrome_host.find.match_case = !self.chrome_host.find.match_case;
    refilterAfterRuleChange(self);
}

/// ⌥⌘W: 낱말 단위로만 셀지 토글한다(§5.1). 낱말 판정의 소유자는 `selection.wordRangeAt` 이다.
pub fn toggleFindWholeWord(self: *AppSession) void {
    if (!isEditorFindTarget(self)) return;
    self.chrome_host.find.whole_word = !self.chrome_host.find.whole_word;
    refilterAfterRuleChange(self);
}

/// ⌥⌘D: 비교 뷰에서 **검색할 열**을 왼쪽↔오른쪽으로 넘긴다(§5.1).
///
/// **비교 Term 이 아니면 무동작이다** — 단일 편집기에는 열이 없다(`Aa`·`W` 가 스크롤백·웹에서
/// 조용히 무시되는 것과 같은 규칙).
///
/// **지금 보고 있는 열에서 뒤집는다 — 명시값에서 뒤집지 않는다.** 아직 안 골랐으면 명시값이
/// `null` 이라 그것을 기준으로 삼으면 첫 누름이 늘 같은 쪽으로 가고, 폴백이 이미 그 쪽이면
/// **화면이 한 번 안 바뀐다** — 사용자는 눌렀는데 아무 일도 안 일어난 것으로 본다.
pub fn toggleFindDiffSide(self: *AppSession) void {
    if (!isEditorFindTarget(self)) return;
    const term = activeEditorTerm(self) orelse return;
    if (term.rt.editor_diff == null) return;
    self.chrome_host.find.diff_side = switch (editor_ops.diffSearchSide(self, term)) {
        .left => .right,
        .right => .left,
    };
    refilterAfterRuleChange(self);
}

/// ⌥⌘L: 「선택 영역 내에서만」을 토글한다(§5.1).
///
/// **범위는 켤 때 뜬 사본이다.** 살아 있는 선택을 읽으면 첫 Enter 가 선택을 매치로 옮기는 순간
/// 범위가 그 매치 하나로 쪼그라든다 — §5.1 의 *"현재 일치는 primary selection 을 옮긴다"* 와
/// 같은 필드를 두 뜻으로 쓰게 되기 때문이다.
pub fn toggleFindInSelection(self: *AppSession) void {
    if (!isEditorFindTarget(self)) return;
    if (self.chrome_host.find.in_selection != null) {
        self.chrome_host.find.in_selection = null;
        refilterAfterRuleChange(self);
        return;
    }
    // **비교 뷰에서는 안 켜진다**(§5.1). 이 토글은 **문서 offset 축**을 전제하는데 비교 뷰의 매치는
    // 정렬된 행 배열 축이라 `matchRange` 가 성립하지 않는다 — 켜 두면 거르기가 엉뚱한 수를 낸다.
    if (activeEditorTerm(self)) |t| {
        if (t.rt.editor_diff != null) return;
    }
    // **찾기를 열 때 떠 둔 선택을 쓴다** — 지금의 선택은 이미 첫 매치로 옮겨져 있다(§5.1).
    // **빈 범위면 켜지지 않는다.** 「그 안에서만」이 문서 전체와 같은 말이 되는데, 그때 토글이
    // 켜져 보이면 사용자는 좁혀진 줄 안다.
    const at_open = self.find_selection_at_open orelse return;
    if (at_open.start >= at_open.end) return;
    self.chrome_host.find.in_selection = .{ .start = at_open.start, .end = at_open.end };
    refilterAfterRuleChange(self);
}

/// 문서가 바뀌면 굳혀 둔 범위를 버린다(§5.1) — offset 이 다른 글자를 가리키게 되므로, 따라가게
/// 만들면 마커·매치·범위 셋이 각각 다른 시점을 말한다. 끄면 카운터가 전체로 돌아온 것을 보여 준다.
pub fn dropFindSelectionRange(self: *AppSession) void {
    self.chrome_host.find.in_selection = null;
    // **떠 둔 값도 함께 버린다.** 이것만 남기면 편집 뒤 `⌥⌘L` 이 **편집 전 offset** 으로 켜져,
    // 사용자가 고른 적 없는 자리에 검색이 갇힌다(변이 G6 이 그것을 보였다).
    self.find_selection_at_open = null;
}

/// 토글이 뜻을 갖는 상태인가 — **떠 있는 찾기가 편집기 문서를 보고 있을 때**뿐이다.
fn isEditorFindTarget(self: *AppSession) bool {
    return self.chrome_host.find.open and self.chrome_host.find.target == .editor;
}

/// 규칙이 바뀌었으니 목록을 다시 세운다.
///
/// **`current` 를 0 으로 되돌린다.** 규칙이 바뀌면 매치 자체가 달라져 옛 인덱스가 가리키던 자리가
/// 아예 없을 수 있다 — 그대로 두면 「3/2」 같은 카운터나 엉뚱한 자리로의 이동이 나온다(§5.1).
fn refilterAfterRuleChange(self: *AppSession) void {
    const term = activeEditorTerm(self) orelse return;
    // **첫 매치로 되돌린다.** `setMatchCount` 는 범위를 벗어난 `current` 를 **끝으로 clamp** 할 뿐이라
    // 규칙을 좁히면 사용자가 보던 자리가 아니라 «마지막»으로 튄다. 증분 검색이 글자마다 0 으로
    // 되돌리는 것과 같은 규칙을 쓴다 — 규칙 변경도 「목록이 통째로 달라지는」 사건이다.
    self.chrome_host.find.current = 0;
    // `recomputeEditorFind` 가 `setMatchCount` 까지 한다 — 여기서 `match_count` 를 또 쓰면
    // 죽은 코드다(변이 M8 이 그것을 보였다).
    recomputeEditorFind(self, term);
    self.metal_dirty = true;
}

/// ⌘F: Find 오버레이를 토글한다. 열려 있으면 닫고(매치 하이라이트·⌘G 닫힘-네비 세션 종료),
/// 닫혀 있으면 다른 배타 오버레이(notice·palette)를 먼저 닫고 연다(검색어 초기화는 컴포넌트의 show가).
pub fn toggleFind(self: *AppSession) void {
    if (self.chrome_host.find.open) {
        self.chrome_host.find.hide();
        self.chrome_host.find.in_selection = null;
        self.find_selection_at_open = null;
        clearAllFindMatches(self); // 닫힘 — 목록 둘 + ⌘G 닫힘-네비 세션까지 한 곳에서
    } else {
        // **여는 순간의 선택을 떠 둔다**(§5.1 「선택 영역 내에서만」). 검색어를 한 글자 치면
        // `revealCurrentFindMatch` 가 선택을 첫 매치로 옮기므로, `⌥⌘L` 을 누를 때는 **이미 늦다**.
        self.find_selection_at_open = null;
        if (activeEditorTerm(self)) |t| {
            if (t.rt.editor_selection) |sel| {
                if (sel.start() < sel.end()) self.find_selection_at_open = .{ .start = sel.start(), .end = sel.end() };
            }
        }
        // alt screen(vim/less/Claude/Codex)에서도 연다 — alt에선 findMatches가 현재 화면만 검색해 매치를
        // 하이라이트한다(스크롤백 매치 제외, 스크롤 네비는 무의미·무동작). 과거엔 iTerm2 관례로 막았으나,
        // 자체 검색이 없는 TUI(Claude/Codex)를 위해 연다. 베이스: Ghostty(alt에서 active area 검색).
        self.chrome_host.notice.dismiss(); // 배타적 — notice 위에 열지 않는다
        self.chrome_host.palette.hide();
        self.chrome_host.find.show(); // show가 검색어/현재/카운트를 비운다(새 검색)
        // **여는 쪽도 목록을 비운다.** `show()`는 컴포넌트 상태(검색어·현재·카운트)만 비우고
        // 매치 목록은 세션 소유라 안 건드린다 — 그래서 ⌘G로 닫힘-네비를 하다 ⌘F를 다시 열면
        // **빈 검색 상자에 옛 강조가 그대로 칠해져 있었다**(카운터는 0을 말하면서. 적대적 검증
        // 2026-08-24가 `editor_find_matches=200`으로 실측). 헬퍼가 `hide()` 자리만 덮고 `show()`
        // 자리를 안 덮은 것이 그 구멍이다 — 이 줄이 `find_nav` 해제도 함께 한다.
        clearAllFindMatches(self);
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
    if (activeEditorTerm(self)) |term| {
        // 닫은 뒤 ⌘G로 돌아온 경우 목록이 비어 있다 — 보존된 검색어로 다시 채운다(스크롤백과 같은
        // 규칙이고, 현재 인덱스는 `setMatchCount`가 범위로 clamp해 닫기 전 위치를 지킨다).
        //
        // **출처가 다르면 비어 있지 않아도 다시 찾는다.** pane을 옮겨 온 경우가 그것이고, 남의
        // 문서 좌표로 네비게이션하면 엉뚱한 줄로 간다.
        if (self.editor_find_matches.items.len == 0 or self.editor_find_source != term.surfaceId()) {
            recomputeEditorFind(self, term);
        }
        if (self.editor_find_matches.items.len == 0) return;
        self.find_nav = true;
        if (forward) self.chrome_host.find.next() else self.chrome_host.find.prev();
        scrollToCurrentMatch(self);
        self.metal_dirty = true;
        return;
    }
    clearEditorFind(self);
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
/// 현재 매치 하나를 바꾼다 — 편집기가 아니면 무동작(스크롤백·웹은 읽기 전용이다).
pub fn replaceOne(self: *AppSession) void {
    const term = activeEditorTerm(self) orelse return;
    if (!editor_ops.replaceCurrentMatch(self, term)) return;
    self.metal_dirty = true;
}

/// 전부 바꾼다 — 되돌리기 하나(§3.3).
pub fn replaceAll(self: *AppSession) void {
    const term = activeEditorTerm(self) orelse return;
    if (!editor_ops.replaceAllMatches(self, term)) return;
    self.metal_dirty = true;
}

pub fn recomputeFind(self: *AppSession) void {
    if (!self.surface_initialized) return;
    if (activeEditorTerm(self)) |term| {
        // **스크롤백 목록을 비운다.** 대상이 편집기로 넘어왔으므로 그쪽 매치는 이 화면 것이 아니다 —
        // 웹으로 넘어갈 때 tick이 같은 이유로 비우는 그 자리와 짝이다(R5 실측).
        self.find_matches.clearRetainingCapacity();
        recomputeEditorFind(self, term);
        self.chrome_host.find.current = 0; // 재검색은 첫 매치로(스크롤백과 같은 규칙)
        scrollToCurrentMatch(self);
        self.metal_dirty = true; // 하이라이트가 바뀐다 — 편집기는 출력이 없어 아무도 안 깨운다
        return;
    }
    // 편집기가 아니면 스크롤백이다. **편집기 매치를 여기서 버린다** — 남겨 두면 pane을 옮긴 뒤에도
    // 옛 문서의 강조가 남고, `isFindTarget`이 id로 막아 주는 것은 *다른* 편집기일 때뿐이다.
    clearEditorFind(self);
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
    if (activeEditorTerm(self)) |term| {
        editor_ops.revealCurrentFindMatch(self, term);
        return;
    }
    if (builtin.os.tag == .macos and term_ops.activeSurface(self).remote != null) {
        self.remote_find_scroll_pending = true;
        self.remote_find_dirty = true;
        return;
    }
    const cur = self.chrome_host.find.current;
    if (cur >= self.find_matches.items.len) return;
    const surface = term_ops.activeSurface(self);
    // scrollToAbs는 코어 mutate라 reader로 위임(full (a), docs/plans/io-render-threading.md §9 P3-4).
    self.enqueueCoreCommandForSurface(surface.id, .{ .scroll_to_abs = self.find_matches.items[cur].start.row }) catch {};
}
