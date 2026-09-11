//! N1.5 슬라이스 b — **네이티브 diff Term의 배선**(docs/plans/native-editor.md).
//!
//! git 호출은 하나도 바꾸지 않는다. 이미 있는 `submitDiff` → `takeDiffResult` → dock entry 경로가
//! 두 쪽 전문을 채워 주고(CM6 화면이 쓰던 그 경로다), 여기서는 **그 플래그를 화면 네 상태로 옮기고**
//! 두 쪽이 오면 줄 대응을 한 번 계산해 Term에 든다.
//!
//! **판단은 L2가 한다.** 어떤 상태인지는 `session.editor.diff_state.step`이, 줄 대응은
//! `session.editor.diff.compute`가 정한다 — 이 파일은 그 결과를 Term 수명에 맞춰 들고 있을 뿐이다.
//! 그래야 규칙이 화면 없이 검사된다(둘 다 순수 모듈이고 테스트가 붙어 있다).

const std = @import("std");
const maru = @import("maru");

const diff = maru.session.editor.diff;
const diff_state = maru.session.editor.diff_state;
const intraline = maru.session.editor.intraline;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const dock_panel = maru.session.dock_panel;
const chrome_editor = maru.chrome.components.editor_view;
// 테스트 픽스처가 쓰는 형제 모듈. `editor.zig`가 이 파일을 부르고 이쪽이 그쪽을 부르지만, 파일 단위
// 순환 import는 Zig에서 문제가 없다(타입이 서로를 comptime으로 품지 않는다).
const editor_ops = @import("editor.zig");
const term_ops = @import("term.zig");
const pane_ops = @import("pane.zig");
const find_ops = @import("find.zig");
const scroll_ops = @import("scroll.zig");
const settings_ops = @import("settings.zig");

/// diff Term 하나가 드는 것. **행들은 줄 배열을 빌리고, 줄 배열은 entry의 두 쪽 버퍼를 빌린다** —
/// 그래서 entry 내용이 갈릴 때 `invalidate`가 먼저 불려야 한다(호출자 계약).
pub const State = struct {
    /// 화면이 그릴 네 상태(§7).
    view: diff.View = .loading,
    /// 왼쪽/오른쪽 줄 배열(우리가 할당, entry 버퍼를 빌린다).
    left_lines: []const []const u8 = &.{},
    right_lines: []const []const u8 = &.{},
    /// 화면이 그릴 것. **행마다 한 칸**이라 좌우 인덱스가 같은 높이다(§3.5).
    ///
    /// 왜 미리 만드는가: `frame.build`는 `[]const []const u8`을 받는데 우리 행은 구조체 배열이다.
    /// 매 프레임 옮겨 담으면 프레임마다 할당이 생긴다(N1이 `editor_lines`를 미리 만든 것과 같은 이유).
    ///
    /// **줄 끝 문자는 여기서 뗀다.** 대응은 그것을 포함해 계산해야 목록과 맞고(끝 개행·CRLF 변경),
    /// 화면에 남기면 §3.8 가시화가 제어 문자로 그린다 — 계산과 표시의 요구가 갈리는 자리다.
    left_texts: []const []const u8 = &.{},
    right_texts: []const []const u8 = &.{},
    /// 각 행이 **원본에서 무엇으로 끝났는가**(`"\n"` / `"\r\n"` / `""`). 위에서 뗀 그것이다.
    /// 짝맞춤 빈 행은 `null`이다 — 그 자리에 줄이 **없으므로** 줄 끝도 없다.
    ///
    /// **복사가 되돌려 붙인다** — 안 되돌리면 CRLF 문서가 LF로 바뀌어 클립보드에 나간다. 뗄 때
    /// 같은 자리에서 함께 굳히는 것이 요점이다: 나중에 줄 번호로 원본 배열을 되짚으면 그 인덱스
    /// 산술이 맞다는 것을 **런타임 단언에 기대야** 하는데, 출하 빌드(ReleaseFast)에는 단언도 경계
    /// 검사도 없어서 어긋나는 순간 남의 메모리가 클립보드로 나간다.
    ///
    /// **길이가 같다는 것은 타입이 아니라 이 파일의 불변식이다** — `materialize`가 `*_texts`와
    /// 같은 문장에서 같은 `rows.*.len`으로 잡는다. 읽는 쪽은 그 불변식을 **확인하고 거절한다**
    /// (`copyDiffSelection`) — 어긋난 채로 이어 붙이면 틀린 바이트가 조용히 클립보드로 간다.
    ///
    /// **`""`와 `null`을 가른 이유**: 둘 다 "붙일 것이 없다"지만 뜻이 다르다. `""`는 *끝 개행이 없는
    /// 마지막 줄*이고 `null`은 *줄이 아예 없다*이다. 한 값이 둘을 겸하면, 나중에 짝맞춤 행을 다르게
    /// 다루기로 할 때 그 겸침이 두 줄을 분리자 없이 붙인다.
    left_endings: []const ?[]const u8 = &.{},
    right_endings: []const ?[]const u8 = &.{},
    /// 각 행이 달 줄 번호. 짝을 맞추려 넣은 빈 행은 `null`이다(없는 줄에 번호를 붙이면 거짓이다).
    left_numbers: []const ?u32 = &.{},
    right_numbers: []const ?u32 = &.{},
    /// 행마다 바뀐 글자 범위(없으면 빈 슬라이스). §3.5의 "바뀐 글자만 진하게"가 이것이다.
    left_marks: []const []const chrome_editor.frame.Mark = &.{},
    right_marks: []const []const chrome_editor.frame.Mark = &.{},
    /// 각 행의 밴드. **왼쪽은 삭제만, 오른쪽은 추가만** 칠한다 — 좌우를 나눈 이유가 그것이고,
    /// 빈 행은 `none`이다(색을 칠하면 "그 자리에 무언가 있다"고 말하게 된다).
    left_bands: []const chrome_editor.frame.RowBand = &.{},
    right_bands: []const chrome_editor.frame.RowBand = &.{},
    /// 요청을 건 시각. 재시도 창(6초)을 여기서 잰다.
    requested_ms: u64 = 0,
    /// 판정이 끝났는가. **끝난 판정을 매 tick 다시 계산하지 않는다** — 2,000줄 대응을 프레임마다
    /// 돌리면 화면이 멈춘다. 내용이 갈리면 `invalidate`가 이 래치를 푼다.
    settled: bool = false,
    /// 그 판정을 내릴 때 본 플래그. **래치를 플래그와 무관하게 두면 화면이 거짓말을 한다** —
    /// 파일이 바뀌어 비교를 다시 요청했는데 그 요청이 실패하면, 폴링이 곧바로 반환해 옛 비교가
    /// 그대로 남는다(사용자는 지금 파일과 다른 비교를 계속 읽는다).
    settled_on: Flags = .{},
};

/// 판정의 입력이 된 백엔드 플래그. 시간은 뺀다 — 시간은 늘 흐르므로 넣으면 래치가 무의미해진다.
pub const Flags = struct {
    ready: bool = false,
    failed: bool = false,
    truncated: bool = false,

    fn of(entry: *const dock_panel.Entry) Flags {
        return .{ .ready = entry.diff_ready, .failed = entry.diff_failed, .truncated = entry.diff_truncated };
    }

    fn eql(a: Flags, b: Flags) bool {
        return a.ready == b.ready and a.failed == b.failed and a.truncated == b.truncated;
    }
};

/// 이 Term이 네이티브 diff인가. 편집기 Term이면서 dock entry가 비교인 것.
pub fn isDiffTerm(term: *const Term) bool {
    if (term.kind != .editor) return false;
    const entry = term.file_entry orelse return false;
    return entry.kind == .diff;
}

/// 비교를 **네이티브 편집기로** 열까. **기본이 네이티브다**(2026-08-18 — N1.5 기본 경로 전환).
///
/// **전환 전에 실제 클릭 경로를 확인했다**(계획이 정한 조건). 소스 컨트롤 도크 행을 클릭한 것과 같은
/// 경로(`MARU_OPEN_SCM_DIFF` 훅 → `openDiffForScmRow`)로 열어 좌우 배치·색·줄 번호·가로 막대가 실제
/// 제품 화면에 뜨는 것을 캡처로 봤다. 그때 CM6 대비 유일한 후퇴였던 **가로 막대**를 같은 슬라이스에서
/// 채웠다(§4.1a — CM6는 WebKit이 그려 주던 것이라 네이티브에서는 직접 그려야 한다).
///
/// **`MARU_NATIVE_DIFF=0`으로 되돌릴 수 있다.** 전환 직후 회귀가 나오면 사용자가 CM6로 돌아갈 길을
/// 남긴다 — 훅을 지우는 것은 그 경로를 실제로 안 쓰게 된 뒤의 일이다.
///
/// **세션이 init에서 한 번 읽어 든다**(`AppSession.native_diff`). 분기가 프로세스 전역 환경을 직접
/// 읽으면 그 분기를 확인하려는 테스트가 env를 건드려야 하고, 그것이 같은 프로세스의 다른 테스트로
/// 샌다 — 실제로 이 테스트를 쓰다가 그 문제를 만났다.
pub fn nativeDiffFromEnv() bool {
    const raw = std.c.getenv("MARU_NATIVE_DIFF") orelse return true;
    return valueEnables(std.mem.span(raw));
}

/// 훅 값 하나를 판정한다(순수). 빈 값과 `"0"`은 끈 것으로 본다 — 다른 훅과 같은 관례다.
pub fn valueEnables(v: []const u8) bool {
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// 요청을 건 직후 부른다. 시계를 여기서 잡아야 재시도 창이 **요청 시점**부터 흐른다.
pub fn markRequested(self: *AppSession, term: *Term) void {
    if (!isDiffTerm(term)) return;
    invalidate(self, term);
    term.rt.editor_diff = .{ .requested_ms = nowMs(self) };
}

/// `materialize`가 잡은 **행 배열 전부**를 푼다(`view`는 안 건드린다 — 소유가 다르다).
///
/// **한 곳에 모아 둔 이유가 있다.** 예전에는 `invalidate`와 할당 실패 주입 테스트가 이 목록을 각자
/// 손으로 들고 있었는데, 필드를 하나 더하면 **두 곳을 고쳐야** 했다. `*_endings`를 더하며 테스트
/// 쪽을 빠뜨려 `MemoryLeakDetected`가 났다 — 이 파일이 이미 겪은 부류다(가드만 베끼고 해제를 안
/// 베끼는 것). 새 배열은 여기 한 줄만 더하면 된다.
fn freeRowArrays(allocator: std.mem.Allocator, st: *State) void {
    if (st.left_lines.len > 0) allocator.free(st.left_lines);
    if (st.right_lines.len > 0) allocator.free(st.right_lines);
    if (st.left_texts.len > 0) allocator.free(st.left_texts);
    if (st.right_texts.len > 0) allocator.free(st.right_texts);
    if (st.left_endings.len > 0) allocator.free(st.left_endings);
    if (st.right_endings.len > 0) allocator.free(st.right_endings);
    if (st.left_numbers.len > 0) allocator.free(st.left_numbers);
    if (st.right_numbers.len > 0) allocator.free(st.right_numbers);
    if (st.left_bands.len > 0) allocator.free(st.left_bands);
    if (st.right_bands.len > 0) allocator.free(st.right_bands);
    freeMarks(allocator, st.left_marks);
    freeMarks(allocator, st.right_marks);
}

/// **entry의 두 쪽 버퍼가 갈리기 전에** 부른다. 우리 줄 배열이 그 버퍼를 빌리므로, 순서가 뒤집히면
/// 해제된 메모리를 가리키는 행이 남는다.
pub fn invalidate(self: *AppSession, term: *Term) void {
    // **포인터 캡처로 받는다.** `&(opt orelse return)`은 값을 먼저 풀어 임시를 만들 수 있어, 아래 대입이
    // 저장된 상태가 아니라 그 임시에 들어갈 여지를 남긴다 — 여기서 그런 모호함을 두지 않는다.
    const st: *State = if (term.rt.editor_diff) |*p| p else return;
    if (st.view == .compare) st.view.compare.deinit(self.allocator);
    st.view = .loading;
    freeRowArrays(self.allocator, st);
    st.left_lines = &.{};
    st.right_lines = &.{};
    st.left_texts = &.{};
    st.right_texts = &.{};
    st.left_endings = &.{};
    st.right_endings = &.{};
    st.left_numbers = &.{};
    st.right_numbers = &.{};
    st.left_bands = &.{};
    st.right_bands = &.{};
    st.left_marks = &.{};
    st.right_marks = &.{};
    st.settled = false;
    // **세로 위치도 처음으로 돌린다.** 800행짜리 비교를 끝까지 굴려 둔 뒤 파일이 바뀌어 10행짜리로
    // 다시 계산되면, 옛 위치가 남아 본문이 한 행도 안 나오고 배경만 남는다 — "읽는 중" 문구조차
    // 못 본다(그 상태의 문서는 한 줄이다). 새 내용은 처음부터 보는 것이 맞다.
    term.rt.editor_first_line = 0;
    // **렌더가 센 시각 행 수도 함께 버린다.** 그 값은 옛 내용의 것이고, 스크롤 상한이 그것을 읽는다 —
    // 남겨 두면 다시 그리기 전 한 번의 휠에서 짧아진 문서가 옛 길이만큼 굴러간다.
    term.rt.editor_total_visual_rows = 0;
    // **가로도 같은 이유로 되돌린다.** 긴 줄을 오른쪽 끝까지 굴려 둔 뒤 짧은 내용으로 바뀌면 화면에
    // 아무 글자도 안 남는다. 최대 열 캐시는 옛 내용의 것이라 함께 버린다(다음 가로 휠이 다시 센다).
    term.rt.editor_first_col = 0;
    term.rt.editor_max_cols = 0;
    term.rt.editor_first_col_right = 0;
    term.rt.editor_max_cols_right = 0;
    // 조각 오프셋과 렌더가 실어 둔 상한도 옛 내용의 것이다(§4.1d).
    term.rt.editor_first_piece = 0;
    term.rt.editor_max_top_line = 0;
    term.rt.editor_max_top_piece = 0;
    // **줄별 행 수 캐시도 옛 내용의 것이다**(§2.1). 새 줄 배열이 우연히 같은 주소·길이로 잡히면
    // 주소·길이 키만으로는 못 걸러지므로, 내용이 갈리는 이 자리에서 버린다.
    term.rt.editor_row_cache.filled = false;
    // **선택도 옛 내용의 것이다.** 행 인덱스가 새 배열을 가리키지 않으므로 그대로 두면 다음 프레임이
    // 범위 밖 행을 훑는다 — 실측으로 40행 선택을 든 채 1행짜리로 다시 계산하면 `integer overflow`로
    // **죽었다**(파일 감시가 `requestDiffContent`를 걸면 제품에서 그 경로가 열린다). 위 일곱 축과
    // 같은 이유·같은 자리다.
    term.rt.editor_diff_selection = null;
}

/// Term이 죽을 때. `releaseEditorTerm`이 부른다.
pub fn release(self: *AppSession, term: *Term) void {
    invalidate(self, term);
    term.rt.editor_diff = null;
}

/// tick이 부르는 폴링 지점. 판정이 끝나 있으면 아무것도 하지 않는다.
pub fn poll(self: *AppSession, term: *Term) void {
    if (!isDiffTerm(term)) return;
    const entry = term.file_entry orelse return;
    if (term.rt.editor_diff == null) term.rt.editor_diff = .{ .requested_ms = nowMs(self) };
    const st = &term.rt.editor_diff.?;
    const now = nowMs(self);
    const flags = Flags.of(entry);
    if (st.settled) {
        // 입력이 그대로면 판정을 재사용한다(대응을 프레임마다 다시 돌리지 않는다).
        if (Flags.eql(flags, st.settled_on)) return;
        // **플래그가 바뀌었다 = 새 요청이 시작됐다.** 옛 행을 놓고 시계도 다시 잡는다 — 옛 요청
        // 시각을 두면 재시도 창이 이미 지나 있어 새 요청이 첫 폴링에서 곧바로 접힌다.
        invalidate(self, term);
        st.requested_ms = now;
    }

    switch (diff_state.step(.{
        .ready = entry.diff_ready,
        .failed = entry.diff_failed,
        .truncated = entry.diff_truncated,
        .waited_ms = now -| st.requested_ms,
    })) {
        .wait => return,
        .give_up => |reason| {
            st.view = .{ .unavailable = reason };
            st.settled = true;
        },
        .compare => computeRows(self, term, entry, st),
    }
    st.settled_on = flags;
    self.metal_dirty = true;
}

/// 두 쪽이 왔다 — 줄로 자르고 대응을 만든다. **여기서만 할당한다.**
///
/// **끝에서 좌우 가장 긴 줄을 센다** — 가로 막대가 첫 프레임부터 서야 사용자가 그 축이 있다는 것을
/// 안다(§4.1a, 2026-08-18 사용자 지적으로 단일 편집기에 붙은 그 규칙과 같은 자리다). 여는 경로가
/// 문서 편집기에 `ensureMaxCols`를 부르는 것과 같은 시점이고, 비교는 그 자리가 여기다.
fn computeRows(self: *AppSession, term: *Term, entry: *dock_panel.Entry, st: *State) void {
    st.settled = true;
    // **한쪽만 바이너리여도 비교하지 않는다.** 한쪽을 글자로 읽어 대응을 만들면 뜻 없는 줄 짝이 화면에 뜬다.
    if (diff_state.isBinary(entry.diff_original) or diff_state.isBinary(entry.diff_modified)) {
        st.view = .{ .unavailable = .binary };
        return;
    }
    const left = diff_state.splitLines(self.allocator, entry.diff_original) catch {
        st.view = .{ .unavailable = .unknown };
        return;
    };
    const right = diff_state.splitLines(self.allocator, entry.diff_modified) catch {
        if (left.len > 0) self.allocator.free(left);
        st.view = .{ .unavailable = .unknown };
        return;
    };
    st.left_lines = left;
    st.right_lines = right;
    st.view = diff.compute(self.allocator, left, right, .{}) catch {
        // 메모리가 모자란 것은 "너무 크다"가 아니다 — 이유를 지어내지 않는다(§7).
        st.view = .{ .unavailable = .unknown };
        return;
    };
    if (st.view != .compare) return;
    materialize(self.allocator, st) catch {
        st.view.compare.deinit(self.allocator);
        st.view = .{ .unavailable = .unknown };
        return;
    };
    // **탭 폭을 config에서 받는다**(§9). 비교 Term은 `pane.zig`가 `prepared == null`로 만들어
    // **`finishAttach`를 안 타므로**, 그쪽 배선이 여기까지 오지 않는다 — 그대로 두면 같은 파일이
    // 텍스트로는 8칸, 비교로는 구조체 기본값 4칸으로 그려진다. 아래 계수와 렌더가 이 값을 쓰므로
    // **세기 전에** 넣는다.
    term.rt.editor_tab_width = editor_ops.editorTabWidth(self);

    // **행 배열이 선 뒤에 센다** — `ensureMaxCols`가 그 배열(`left_texts`/`right_texts`)을 읽으므로
    // `materialize` 앞에서 부르면 빈 것을 세고 0으로 굳는다(캐시는 0을 "안 셌다"로 읽어 다음 프레임에
    // 다시 세지만, 그때는 이미 막대 없이 한 프레임이 나간 뒤다).
    editor_ops.ensureMaxColsForDiff(term);

    // **caret 을 세운다**([키 입력과 단축키](../../../../docs/key-input-and-shortcuts.md)
    // 「비교 뷰에 caret 을 세운다」). `invalidate`가 옛 선택을 버린 뒤라 여기가 되세우는 자리다 —
    // **`invalidate` 안에서는 안 된다**: 그 함수는 Term 이 죽을 때도 불리므로(`release`) 죽는
    // Term 에 caret 을 심는다.
    //
    // **오른쪽이다.** 왼쪽은 git 이 준 HEAD 판이라 열려 있는 문서가 아니고, JetBrains 도 편집
    // 가능한 쪽을 오른쪽에 둔다. 행 배열이 비면 세울 자리가 없다.
    //
    // **이 게이트는 방어일 뿐 판정할 수 없다**(변이 4·5회차 C52·C46). 짝맞춤 빈 행이 들어차므로
    // 좌우 길이가 늘 같고, 비교가 선 상태에서 `right_texts.len > 0` 은 항상 참이다 — 조건을
    // `left_texts` 로 바꾸거나 아예 없애도 답이 같다. 조건부 단언을 두면 한 번도 안 도는 항진
    // 판정자가 되므로(DCARET13 에서 그렇게 썼다가 걷어냈다) 여기 근거만 남긴다.
    //
    // **`invalidate` 가 먼저 선택을 버린다**(그래서 C65 — `if (== null)` 가드도 동치다). 그럼에도
    // 무조건 덮는 형태로 두는 이유는 이 자리가 「비교가 설 때마다 caret 이 선다」를 말해야 하고,
    // 그 성질이 앞 함수의 구현에 기대면 안 되기 때문이다.
    if (st.right_texts.len > 0) {
        term.rt.editor_diff_selection = .{
            .side = .right,
            .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }),
        };
    }
}

/// 행 배열을 **화면이 받는 모양**으로 한 번 옮겨 담는다.
fn materialize(allocator: std.mem.Allocator, st: *State) error{OutOfMemory}!void {
    const rows = st.view.compare;
    // **잡자마자 `st`에 넘기고 errdefer를 두지 않는다.** 넘긴 뒤에도 errdefer가 살아 있으면, 뒤에서
    // 실패했을 때 여기서 한 번 풀고 `invalidate`가 또 푼다 — **이중 해제**다. 아래 `computeMarks`가
    // 실패하는 경우가 정확히 그것이고, 할당 실패 주입 테스트가 `Double free detected`로 잡았다.
    // 실패해도 `st`가 들고 있으므로 `invalidate`가 정확히 한 번 푼다.
    const lt = try allocator.alloc([]const u8, rows.left.len);
    st.left_texts = lt;
    const rt = try allocator.alloc([]const u8, rows.right.len);
    st.right_texts = rt;
    const le = try allocator.alloc(?[]const u8, rows.left.len);
    st.left_endings = le;
    const re = try allocator.alloc(?[]const u8, rows.right.len);
    st.right_endings = re;
    const ln = try allocator.alloc(?u32, rows.left.len);
    st.left_numbers = ln;
    const rn = try allocator.alloc(?u32, rows.right.len);
    st.right_numbers = rn;
    const lb = try allocator.alloc(chrome_editor.frame.RowBand, rows.left.len);
    st.left_bands = lb;
    const rb = try allocator.alloc(chrome_editor.frame.RowBand, rows.right.len);
    st.right_bands = rb;
    // **여기서부터 내용을 채운다.** 위 배열은 아직 쓰레기값이지만 길이가 맞고, 실패 경로에서는
    // 해제만 하므로(내용을 읽지 않는다) 안전하다.
    for (rows.left, 0..) |r, i| {
        lt[i] = displayText(r.text);
        // **뗀 것을 같은 자리에서 든다.** `displayText`는 뒤에서 자르기만 하므로 나머지가 곧 줄 끝이다.
        // 짝맞춤 행은 `r.text`가 비어 있는데, 그것을 `""`로 두면 "끝 개행 없는 마지막 줄"과 겸친다.
        le[i] = if (r.line == null) null else r.text[lt[i].len..];
        ln[i] = r.line;
        // **왼쪽은 삭제만 칠한다.** context와 빈 행은 색이 없다.
        lb[i] = if (r.kind == .removed) .removed else .none;
    }
    for (rows.right, 0..) |r, i| {
        rt[i] = displayText(r.text);
        re[i] = if (r.line == null) null else r.text[rt[i].len..];
        rn[i] = r.line;
        rb[i] = if (r.kind == .added) .added else .none;
    }
    // 문자 단위 강조는 **줄 대응이 끝난 뒤**에 온다(§7 경계 규칙 — 이 계산이 대응을 바꾸지 않는다).
    try computeMarks(allocator, st);
}

fn freeMarks(allocator: std.mem.Allocator, marks: []const []const chrome_editor.frame.Mark) void {
    if (marks.len == 0) return;
    for (marks) |row| if (row.len > 0) allocator.free(row);
    allocator.free(marks);
}

/// 짝이 된 줄 쌍마다 **바뀐 글자**를 계산한다(§3.5). 실패는 조용히 넘긴다 — 강조가 없으면 밴드만
/// 남고, 그것은 정보가 적을 뿐 틀리지 않는다.
///
/// **allocator를 인자로 받는다**(세션에서 꺼내지 않는다) — 그래야 할당 실패를 전 지점에 주입해
/// 누수를 확인할 수 있다. 세션 allocator는 init에 고정돼 있어 그 방법이 통하지 않는다.
///
/// **무엇이 한 글자인지 여기서 정한다.** L2(`intraline`)는 chrome을 몰라 토큰 경계를 받는데, 그 규칙
/// (grapheme cluster)이 chrome의 `text_layout`에 있고 이 층은 chrome을 안다. 코드포인트로 자르면
/// 이모지 ZWJ 시퀀스가 반으로 갈린다.
fn computeMarks(allocator: std.mem.Allocator, st: *State) error{OutOfMemory}!void {
    const rows = st.view.compare;
    // **주인이 하나여야 한다.** 배열을 `st`에 넘긴 뒤에도 `errdefer`로 해제하면, 뒤에서 실패했을 때
    // 여기서 한 번 풀고 `invalidate`가 또 푼다 — **이중 해제**다(할당 실패 주입 테스트가 잡았다).
    // 그래서 잡자마자 넘기고 errdefer를 두지 않는다. 뒤에서 실패해도 `st`가 들고 있으므로
    // `invalidate`가 정확히 한 번 푼다.
    const left = try allocator.alloc([]const chrome_editor.frame.Mark, rows.left.len);
    @memset(left, &.{});
    st.left_marks = left;
    const right = try allocator.alloc([]const chrome_editor.frame.Mark, rows.right.len);
    @memset(right, &.{});
    st.right_marks = right;

    for (rows.left, rows.right, 0..) |lrow, rrow, i| {
        // **짝이 된 쌍에서만 본다**(§7 경계 규칙). 한쪽이 빈 행이면 순수 추가·삭제라 줄 전체가 밴드다.
        if (lrow.kind != .removed or rrow.kind != .added) continue;
        // **상한은 한 곳에서 온다** — 토큰을 만드는 쪽과 접는 쪽이 갈리면 다시 잡았다 버린다.
        const opts: intraline.Options = .{};
        const lt = (try clusterTokens(allocator, st.left_texts[i], opts.max_tokens)) orelse continue;
        defer allocator.free(lt);
        const rt = (try clusterTokens(allocator, st.right_texts[i], opts.max_tokens)) orelse continue;
        defer allocator.free(rt);
        var result = (try intraline.compute(allocator, lt, st.left_texts[i], rt, st.right_texts[i], opts)) orelse continue;
        defer result.deinit(allocator);
        left[i] = try copyMarks(allocator, result.left);
        right[i] = try copyMarks(allocator, result.right);
    }
}

fn copyMarks(allocator: std.mem.Allocator, spans: []const intraline.Span) error{OutOfMemory}![]const chrome_editor.frame.Mark {
    if (spans.len == 0) return &.{};
    const out = try allocator.alloc(chrome_editor.frame.Mark, spans.len);
    for (spans, 0..) |s, i| out[i] = .{ .start = s.start, .len = s.len };
    return out;
}

/// grapheme cluster 경계. **표시가 한 글자로 보는 단위**여야 강조가 글자를 반으로 자르지 않는다.
/// 줄을 cluster 단위 토큰으로 자른다. **`cap`을 넘으면 `null`** — 그 줄은 `intraline.compute`가
/// 어차피 접는데(`max_tokens`), 여기서 끝까지 만들면 잡았다 버리는 양이 줄 길이에 비례한다.
/// 200 KB짜리 한 줄(minified JS — `content.zig`가 실제 사례로 부르는 그 입력)이 바뀌면 그것만으로
/// 12.3 MB를 잡았다 놓았다(측정, 아래 테스트). 상한을 **만드는 자리**로 옮겨 `cap + 1`에서 멈춘다.
fn clusterTokens(allocator: std.mem.Allocator, line: []const u8, cap: usize) error{OutOfMemory}!?[]intraline.Token {
    var out: std.ArrayList(intraline.Token) = .empty;
    errdefer out.deinit(allocator);
    // 넘칠 줄은 `cap + 1`번째에서 접으므로 그 이상 자라지 않는다.
    try out.ensureTotalCapacity(allocator, @min(cap + 1, line.len + 1));
    var i: usize = 0;
    while (i < line.len) {
        if (out.items.len > cap) {
            out.deinit(allocator);
            return null;
        }
        const base = maru.chrome.text_layout.decodeCodepoint(line, i);
        const end = @min(maru.chrome.text_layout.clusterEndAfter(line, i, base.advance), line.len);
        const n = @max(1, end - i);
        try out.append(allocator, .{ .start = @intCast(i), .len = @intCast(n) });
        i += n;
    }
    return try out.toOwnedSlice(allocator);
}

/// 줄 끝 문자를 뗀 표시용 슬라이스. **입력을 빌린다**(복사하지 않는다).
///
/// CRLF의 `\r`도 함께 뗀다 — 남기면 화면에 제어 문자 표기가 뜨는데, 그 줄이 실제로 바뀌었다는
/// 사실은 이미 대응(계산은 `\r`를 포함해 했다)이 말해 준다.
fn displayText(text: []const u8) []const u8 {
    if (text.len == 0 or text[text.len - 1] != '\n') return text;
    var out = text[0 .. text.len - 1];
    // **CR은 개행과 함께 올 때만 줄 끝 표시다.** 끝 개행이 없는 파일의 마지막 바이트가 CR이면 그것은
    // 내용이라, 떼면 화면이 파일과 달라진다(§3.8 — 가시화가 그것을 드러내야 한다).
    if (out.len > 0 and out[out.len - 1] == '\r') out = out[0 .. out.len - 1];
    return out;
}

/// 이 편집기 Term이 컨트롤 플레인에 말할 것(`EditorMeta`, docs/control-plane.md §3).
///
/// **비교 Term이 여기서 갈린다.** 문서를 여는 편집기는 `rt.editor_path`·`rt.editor_doc`에서 나오지만,
/// 비교는 그 둘이 비어 있고 파일은 dock entry가 안다 — 그대로 두면 밖에서 보기에 *"파일이 안 붙은,
/// 편집 가능한 편집기"*가 된다(둘 다 사실이 아니다).
///
/// `read_only`가 참인 이유는 파일 권한이 아니라 **비교 자체가 읽기 전용**이라서다(§3.5가 v1에서
/// stage 버튼을 숨기는 것과 같은 사실). 소비자가 보는 것은 "이 화면은 편집할 수 없다"이므로,
/// 이유가 달라도 값은 참이어야 한다.
pub fn editorMeta(term: *const Term) struct { path: ?[]const u8, read_only: bool, dirty: bool } {
    if (isDiffTerm(term)) {
        const entry = term.file_entry.?;
        // 비교 뷰는 **읽기 전용 결과**라 저장할 것이 없다 — dirty 축이 아예 없다(§7).
        return .{ .path = if (entry.path.len == 0) null else entry.path, .read_only = true, .dirty = false };
    }
    return .{
        .path = if (term.rt.editor_path) |p| p else null,
        .read_only = if (term.rt.editor_doc) |d| d.file.read_only else false,
        .dirty = if (term.rt.editor_doc) |d| d.isDirty() else false,
    };
}

/// 화면이 말할 문장. **내부 값을 노출하지 않는다**(§7) — 세 이유를 사람 문장으로만 옮긴다.
pub fn statusText(view: diff.View) []const u8 {
    return switch (view) {
        .loading => maru.i18n.t(.diff_loading),
        .unchanged => maru.i18n.t(.diff_no_changes),
        .unavailable => |reason| switch (reason) {
            .too_large => maru.i18n.t(.diff_too_large),
            .binary => maru.i18n.t(.diff_not_text),
            .unknown => maru.i18n.t(.diff_read_failed),
        },
        // 좌우 배치는 슬라이스 c가 그린다. 그때까지 이 줄이 **판정이 섰다는 사실**을 말한다.
        .compare => maru.i18n.t(.diff_ready),
    };
}

fn nowMs(self: *AppSession) u64 {
    const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(@divFloor(ns, std.time.ns_per_ms));
}

const testing = std.testing;

test "판정이 서기 전에는 읽는 중이다" {
    try testing.expectEqualStrings(maru.i18n.t(.diff_loading), statusText(.loading));
}

test "세 거절 이유가 각각 다른 문장이다 — 하나로 뭉개면 계약을 확인할 수 없다" {
    const too_large = statusText(.{ .unavailable = .too_large });
    const binary = statusText(.{ .unavailable = .binary });
    const unknown = statusText(.{ .unavailable = .unknown });
    try testing.expect(!std.mem.eql(u8, too_large, binary));
    try testing.expect(!std.mem.eql(u8, binary, unknown));
    try testing.expect(!std.mem.eql(u8, too_large, unknown));
}

test "변경 없음은 빈 화면이 아니라 문장이다" {
    try testing.expect(statusText(.unchanged).len > 0);
}

// ── 배선 계약 ────────────────────────────────────────────────────────────────────────────────
//
// **이 테스트들이 증명하는 것**: 백엔드 플래그가 화면 네 상태로 정확히 옮겨지고, 두 쪽이 왔을 때
// 대응이 **git과 같은 줄 분할**로 계산된다는 것. 둘 다 조용히 틀린다 — 잘린 내용으로 비교를 그려도,
// 개행을 떼고 잘라도 화면은 멀쩡해 보이고 숫자만 목록과 어긋난다.

const Fixture = struct {
    session: *AppSession,
    term: *Term,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const session = try allocator.create(AppSession);
        errdefer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = app_session_mod.abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
        });
        errdefer session.deinit();
        session.cell_width_px = 8;
        session.cell_height_px = 16;
        const term = try editor_ops.createEditorTerm(session);
        errdefer term_ops.destroyTerm(session, term);
        try pane_ops.activePane(session).terms.append(allocator, term);
        return .{ .session = session, .term = term };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        // entry는 테스트 스택에 있다 — Term이 그것을 해제하지 않게 먼저 뗀다.
        self.term.file_entry = null;
        self.session.deinit();
        allocator.destroy(self.session);
    }
};

/// 테스트용 비교 entry. 두 쪽 버퍼는 **정적 문자열**이라 세션이 해제해선 안 된다(위 `deinit` 참고).
fn testEntry(original: []const u8, modified: []const u8) dock_panel.Entry {
    return .{
        .id = 1,
        .path = @constCast("/tmp/t.txt"),
        .kind = .diff,
        .mode = dock_panel.Mode.defaultFor(.diff),
        .diff_ready = true,
        .diff_original = @constCast(original),
        .diff_modified = @constCast(modified),
    };
}

test "두 쪽이 오면 대응이 서고 줄 끝 문자가 보존된다 — 목록과 어긋나지 않는 분할" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);
    try testing.expectEqual(@as(usize, 1), st.view.compare.changed);
    // **줄 끝 문자가 줄에 남아 있다.** 떼고 자르면 끝 개행·CRLF 변경이 본문에서 사라진다.
    try testing.expectEqualStrings("a\n", st.left_lines[0]);
}

test "끝 개행만 사라져도 비교가 선다 — git이 +1 -1이라 말하는 그 변경이다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nb");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    // 개행을 떼고 자르는 구현이면 여기가 `.unchanged`가 된다 — 목록은 숫자를 그리는데 본문만 "변경 없음"이다.
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);
}

test "잘린 내용은 비교하지 않는다 — 뒤가 통째로 삭제된 것처럼 보인다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\n");
    entry.diff_truncated = true;
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    try testing.expectEqual(diff.Unavailable.too_large, fx.term.rt.editor_diff.?.view.unavailable);
}

test "바이너리는 이유를 말한다 — 한쪽만 그래도 비교하지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\n", "a\x00b\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    try testing.expectEqual(diff.Unavailable.binary, fx.term.rt.editor_diff.?.view.unavailable);
}

test "실패한 요청은 조용한 빈 화면이 아니라 문장이다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("", "");
    entry.diff_ready = false;
    entry.diff_failed = true;
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    try testing.expectEqual(diff.Unavailable.unknown, fx.term.rt.editor_diff.?.view.unavailable);
}

test "내용이 갈리면 행을 먼저 놓는다 — 안 그러면 해제된 버퍼를 가리키는 행이 남는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);

    // 새 결과가 오기 직전의 그 자리다(git.zig의 배수가 `freeDiffContent` 전에 부른다).
    invalidate(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .loading);
    try testing.expectEqual(@as(usize, 0), st.left_lines.len);
    try testing.expect(!st.settled);

    // 다시 채우면 새 내용으로 판정이 선다(래치가 풀렸다는 뜻).
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);
}

test "판정이 서면 다시 계산하지 않는다 — 매 프레임 2,000줄 대응을 돌리면 화면이 멈춘다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\n", "b\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const first = fx.term.rt.editor_diff.?.view.compare.left.ptr;
    poll(fx.session, fx.term);
    poll(fx.session, fx.term);
    // 같은 배열이 그대로다 — 다시 계산했다면 주소가 달라진다(그리고 옛 것이 샌다).
    try testing.expectEqual(first, fx.term.rt.editor_diff.?.view.compare.left.ptr);
}

test "새로 고침이 실패하면 옛 비교가 화면에 남지 않는다" {
    // **래치가 플래그와 무관하면 화면이 거짓말을 한다.** 파일이 바뀌면 세션이 비교를 다시 요청하는데
    // (`requestDiffContent`), 그 요청이 실패해도 판정이 이미 서 있으면 폴링이 곧바로 반환해 **옛 비교가
    // 그대로 남는다** — 사용자는 지금 파일과 다른 비교를 계속 읽는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);

    // 파일이 바뀌어 다시 요청했고, 그 요청이 실패했다.
    entry.diff_ready = false;
    entry.diff_failed = true;
    poll(fx.session, fx.term);

    try testing.expectEqual(diff.Unavailable.unknown, fx.term.rt.editor_diff.?.view.unavailable);
}

test "새로 고침이 떠 있는 동안은 읽는 중이다 — 재시도 창도 그 요청부터 다시 센다" {
    // 위 수정의 이면이다. 플래그가 바뀌면 **새 요청이 시작된 것**이므로 시계도 다시 잡아야 한다 —
    // 옛 요청 시각을 그대로 두면 6초가 이미 지나 있어 새 요청이 첫 폴링에서 곧바로 접힌다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);

    // 요청이 떠 있는 상태(결과 전)로 되돌린다. 시계를 6초 전으로 밀어 두어도 접히면 안 된다.
    fx.term.rt.editor_diff.?.requested_ms -|= diff_state.retry_window_ms + 1;
    entry.diff_ready = false;
    entry.diff_failed = false;
    poll(fx.session, fx.term);

    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .loading);
    // 옛 행을 놓았는지도 본다 — 새 내용이 오면 그 버퍼가 풀리므로, 들고 있으면 해제된 메모리를 가리킨다.
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff.?.left_texts.len);
}

test "줄 끝 CR은 개행과 함께 올 때만 뗀다 — 홀로 남은 CR은 파일 내용이다" {
    // §3.8: 보이는 것과 파일 내용이 달라지면 안 된다. 끝 개행이 없는 파일의 마지막 바이트가 CR이면
    // 그것은 줄 끝 표시가 아니라 **내용**이라, 떼면 화면이 파일과 달라진다(가시화가 그것을 그려야 한다).
    try testing.expectEqualStrings("abc", displayText("abc\n"));
    try testing.expectEqualStrings("abc", displayText("abc\r\n"));
    try testing.expectEqualStrings("abc\r", displayText("abc\r"));
    try testing.expectEqualStrings("", displayText("\n"));
    try testing.expectEqualStrings("", displayText("\r\n"));
    try testing.expectEqualStrings("\r", displayText("\r"));
}

test "비교 Term은 파일이 붙어 있고 읽기 전용이라고 말한다 — 컨트롤 플레인이 거짓말하지 않게" {
    // 그대로 두면 밖에서 보기에 "파일이 안 붙은, 편집 가능한 편집기"다. 둘 다 사실이 아니다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 비교가 붙기 전(문서 편집기)에는 지금까지대로 문서 쪽에서 나온다.
    const before = editorMeta(fx.term);
    try testing.expect(before.path == null);
    try testing.expect(!before.read_only);

    var entry = testEntry("a\n", "b\n");
    fx.term.file_entry = &entry;
    const meta = editorMeta(fx.term);
    try testing.expectEqualStrings("/tmp/t.txt", meta.path.?);
    try testing.expect(meta.read_only);
}

test "네 상태가 모두 화면에 op을 낸다 — 조용한 빈 화면이 남지 않는다" {
    // **§7의 요구는 '말한다'이지 '판정을 든다'가 아니다.** 판정이 서도 렌더 분기가 그것을 안 그리면
    // 사용자에게는 빈 pane이다 — 이 저장소에서 편집기 본문이 실제로 그렇게 비어 있었고, 층 하나가
    // 뒤집혀 있어도 op·좌표는 정상이라 단위 테스트가 전부 통과했다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;

    // ① 읽는 중 — 결과가 아직 없다.
    entry.diff_ready = false;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .loading);
    {
        var draw_result = editor_ops.appendPaneFrame(fx.session, leaf, fx.term);
        try testing.expect(draw_result != null);
        defer draw_result.?.dl.deinit(allocator);
        try testing.expect(draw_result.?.dl.cells.len > 0); // 문구가 셀로 내려갔다
    }

    // ② 보여 줄 수 없음.
    entry.diff_failed = true;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .unavailable);
    {
        var draw_result = editor_ops.appendPaneFrame(fx.session, leaf, fx.term);
        try testing.expect(draw_result != null);
        defer draw_result.?.dl.deinit(allocator);
        try testing.expect(draw_result.?.dl.cells.len > 0);
    }

    // ③ 변경 없음 — 빈 화면이 아니라 문장이다.
    entry.diff_failed = false;
    entry.diff_ready = true;
    invalidate(fx.session, fx.term);
    entry.diff_modified = @constCast("a\nb\n");
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .unchanged);
    {
        var draw_result = editor_ops.appendPaneFrame(fx.session, leaf, fx.term);
        try testing.expect(draw_result != null);
        defer draw_result.?.dl.deinit(allocator);
        try testing.expect(draw_result.?.dl.cells.len > 0);
    }

    // ④ 비교. **내용을 바꿀 때는 배수가 하는 순서를 그대로 따른다** — `invalidate` → 내용 교체.
    // 플래그가 그대로면 래치가 판정을 재사용하므로(그것이 계약이다), 이 순서를 어기면 옛 판정이 남는다.
    invalidate(fx.session, fx.term);
    entry.diff_modified = @constCast("a\nB\n");
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);
    {
        var draw_result = editor_ops.appendPaneFrame(fx.session, leaf, fx.term);
        try testing.expect(draw_result != null);
        defer draw_result.?.dl.deinit(allocator);
        // **"셀이 있다"로는 부족하다** — 한 열만 그려도 통과한다. 셀이 분할선 양쪽에 모두 있어야
        // 비교가 화면에 선 것이다(제품 경로에서 그것을 본다 — 컴포넌트 테스트는 op 좌표만 본다).
        const cell_w: i32 = @intCast(fx.session.cell_width_px);
        const inner_w: u32 = draw_result.?.rect.w -| maru.chrome.components.editor_view.frame.content_inset_px * 2;
        const split_cell = @divTrunc(maru.chrome.components.editor_view.diff_frame.columns(
            .{ .x = 0, .y = 0, .w = inner_w, .h = 1 },
            @intCast(fx.session.cell_width_px),
        ).right.x, cell_w);
        var left_cells: usize = 0;
        var right_cells: usize = 0;
        for (draw_result.?.dl.cells) |cell| {
            if (@as(i32, @intCast(cell.col)) < split_cell) left_cells += 1 else right_cells += 1;
        }
        try testing.expect(left_cells > 0);
        try testing.expect(right_cells > 0);
    }
}

test "내용만 바뀌고 플래그가 같으면 판정을 유지한다 — 그래서 배수가 invalidate를 부른다" {
    // 래치의 계약을 **밖에서 보이게** 못 박는다. 이것이 참이기 때문에 `git.drainGitStatus`가 내용을
    // 풀기 전에 `invalidate`를 부른다 — 그 호출이 사라지면 화면이 옛 비교를 그대로 그린다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const before = fx.term.rt.editor_diff.?.view.compare.changed;

    // 플래그는 그대로 두고 내용만 바꾼다(배수를 흉내내지 않은 경로).
    entry.diff_modified = @constCast("X\nY\nZ\n");
    poll(fx.session, fx.term);
    try testing.expectEqual(before, fx.term.rt.editor_diff.?.view.compare.changed); // 판정 그대로

    // 배수가 하는 대로 하면 새 내용이 반영된다.
    invalidate(fx.session, fx.term);
    poll(fx.session, fx.term);
    try testing.expect(fx.term.rt.editor_diff.?.view.compare.changed != before);
}

test "긴 비교가 스크롤된다 — 좌우가 함께 움직이고 끝에서 멈춘다" {
    // **비교의 문서는 행 배열이다**(줄 배열이 아니다). 그 둘을 헷갈리면 스크롤 상한이 문서 줄 수로
    // 잡혀, 짝을 맞추려 넣은 빈 행만큼 화면이 일찍 멈추거나 끝을 넘어간다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };
    // **제품과 같은 것을 넘긴다 — leaf 사각이다**(`paneTargetAt`이 그것을 준다). `body`를 넘기면
    // 탭 바가 두 번 빠져 보이는 행 수가 실제보다 적게 나오고, 상한이 그만큼 커진다.
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    // 왼쪽에만 있는 줄이 잔뜩 — 오른쪽은 그만큼 빈 행이라 **행 수 > 오른쪽 문서 줄 수**다.
    var left_buf: std.ArrayList(u8) = .empty;
    defer left_buf.deinit(allocator);
    for (0..300) |i| {
        var num: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&num, "line {d}\n", .{i});
        try left_buf.appendSlice(allocator, line);
    }
    var entry = testEntry(left_buf.items, "line 0\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);

    const rows = fx.term.rt.editor_diff.?.left_texts.len;
    try testing.expect(rows > 200);

    try testing.expect(editor_ops.scrollLines(fx.session, fx.term, leaf, -5));
    try testing.expectEqual(@as(usize, 5), fx.term.rt.editor_first_line);

    _ = editor_ops.scrollLines(fx.session, fx.term, leaf, -10_000);
    // **제품과 같은 사각을 쓴다** — 파일 Term은 헤더 밴드 한 줄을 더 뺀다(`editorBodyRect`).
    // `paneGeometry(...).body`로 재면 밴드만큼 더 보인다고 계산해 상한이 어긋난다.
    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const visible = (body.h -| chrome_editor.frame.content_inset_px * 2) / fx.session.cell_height_px;
    // **행 수** 기준으로 멈춘다(오른쪽 문서 줄 수(1)로 잡으면 곧바로 0이 된다).
    try testing.expectEqual(rows - visible, fx.term.rt.editor_first_line);

    // 그 자리에서 그려도 좌우가 함께 그 행부터다 — 두 열이 같은 `first_line`을 쓴다.
    var draw_result = editor_ops.appendPaneFrame(fx.session, leaf, fx.term);
    try testing.expect(draw_result != null);
    defer draw_result.?.dl.deinit(allocator);
    try testing.expect(draw_result.?.dl.cells.len > 0);
}

test "훅이 켜지면 비교가 편집기 Term으로 열린다 — 꺼져 있으면 지금까지대로다" {
    // **이 분기에 테스트가 없었다.** 훅·kind 조합이 어긋나도 단위 테스트는 전부 통과하고, 화면에서만
    // (그것도 훅을 켠 사람에게만) 드러난다. 기본이 CM6 그대로인 것도 함께 고정한다 — 이 작업이
    // "기본 경로를 바꾸지 않는다"고 말하는 근거가 이 단언이다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 꺼진 상태(기본) — 웹 Term이다.
    session.native_diff = false;
    const off = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-diff-off.txt", .diff);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.web, off.term.kind);

    // 켜진 상태 — 편집기 Term이다.
    session.native_diff = true;
    const on = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-diff-on.txt", .diff);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.editor, on.term.kind);
    // entry는 두 경우 모두 붙는다 — 결과를 흘리는 배관(`takeDiffResult` → entry)이 같기 때문이다.
    try testing.expect(on.term.file_entry != null);
    try testing.expectEqual(on.term.surfaceId(), on.term.file_entry.?.surface_id);

    // **비교가 아닌 종류는 훅과 무관하다** — 훅이 켜져 있어도 마크다운은 웹이다.
    const md = try pane_ops.openFileTermInActivePane(session, "/tmp/maru-test-diff.md", .markdown);
    try testing.expectEqual(maru.session.control_surface.SurfaceKind.web, md.term.kind);
}

/// 테스트 전용 libc 바인딩. Zig 0.16 std에는 `setenv`가 없고, 이 확인은 **환경을 실제로 켜야만**
/// 성립한다(끈 상태로 비교하면 양쪽 다 false라 아무것도 증명하지 못한다 — 실제로 그렇게 써서
/// 뮤턴트가 살아남았다). 켠 값은 곧바로 되돌린다.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "init이 훅을 읽는다 — 안 읽으면 MARU_NATIVE_DIFF가 아무 일도 안 한다" {
    // **실제로 그 상태로 커밋됐다.** 훅 읽기를 `init`이 아니라 `deinit`에 넣었고, 그래서 `native_diff`가
    // 영영 false였다 — 기능을 켤 방법이 없는데 단위 테스트는 전부 통과했다(테스트가 필드를 직접
    // 세우기 때문이다).
    //
    // **환경을 실제로 켜고 확인한다.** 끈 상태로 "init 뒤 값 == 환경 값"만 보면 양쪽이 false라 공허하다
    // (그렇게 썼다가 뮤턴트가 살아남았다). 켠 값은 이 테스트 안에서만 살고 곧바로 되돌린다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    const had = std.c.getenv("MARU_NATIVE_DIFF");
    defer if (had) |old_value| {
        _ = setenv("MARU_NATIVE_DIFF", old_value, 1);
    } else {
        _ = unsetenv("MARU_NATIVE_DIFF");
    };
    _ = setenv("MARU_NATIVE_DIFF", "1", 1);
    try testing.expect(nativeDiffFromEnv()); // 전제: 환경이 켜졌다

    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // init이 그것을 읽어 들었는가. 안 읽으면 여기서 false다.
    try testing.expect(session.native_diff);
}

test "훅 값 판정: 빈 값과 0은 끈 것이다" {
    try testing.expect(valueEnables("1"));
    try testing.expect(valueEnables("true"));
    try testing.expect(!valueEnables(""));
    try testing.expect(!valueEnables("0"));
}

test "내용이 갈리면 렌더가 센 행 수도 버린다 — 다시 그리기 전 한 번의 휠이 옛 길이로 굴러가면 안 된다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    // 긴 비교를 한 번 그려 시각 행 수를 싣는다.
    var long_buf: std.ArrayList(u8) = .empty;
    defer long_buf.deinit(allocator);
    for (0..300) |i| {
        var num: [32]u8 = undefined;
        try long_buf.appendSlice(allocator, try std.fmt.bufPrint(&num, "line {d}\n", .{i}));
    }
    var entry = testEntry(long_buf.items, "line 0\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_total_visual_rows > 100);

    // 내용이 갈린다(배수가 하는 순서 그대로).
    invalidate(fx.session, fx.term);
    try testing.expectEqual(@as(u32, 0), fx.term.rt.editor_total_visual_rows);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);

    // 짧은 비교로 다시 계산한 뒤 **그리기 전에** 굴려도 옛 길이만큼 가지 않는다.
    entry.diff_original = @constCast("a\nb\n");
    entry.diff_modified = @constCast("a\nB\n");
    poll(fx.session, fx.term);
    _ = editor_ops.scrollLines(fx.session, fx.term, leaf, -10_000);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line); // 두 행짜리 문서는 다 보인다
}

test "스크롤해도 컨트롤 플레인은 같은 사실을 말한다 — 위치는 메타가 아니다" {
    // 세로 위치는 **뷰 상태**이지 문서의 사실이 아니다. 메타(경로·읽기 전용)가 스크롤에 따라
    // 흔들리면 밖에서 보는 쪽이 "다른 파일이 열렸다"고 오해한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    fx.session.window_padding_px = .{ .left = 6, .top = 4, .right = 6, .bottom = 4 };
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    var long_buf: std.ArrayList(u8) = .empty;
    defer long_buf.deinit(allocator);
    for (0..300) |i| {
        var num: [32]u8 = undefined;
        try long_buf.appendSlice(allocator, try std.fmt.bufPrint(&num, "line {d}\n", .{i}));
    }
    var entry = testEntry(long_buf.items, "line 0\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    const before = editorMeta(fx.term);
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    _ = editor_ops.scrollLines(fx.session, fx.term, leaf, -50);
    try testing.expect(fx.term.rt.editor_first_line > 0); // 실제로 움직였다

    const after = editorMeta(fx.term);
    try testing.expectEqualStrings(before.path.?, after.path.?);
    try testing.expectEqual(before.read_only, after.read_only);
    try testing.expect(after.read_only); // 비교는 여전히 읽기 전용이다
}

test "짝이 된 줄에서 바뀐 글자만 강조한다 — 제품 경로" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("const a = 1;\n", "const b = 1;\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);

    // 한 행(자리에서 바뀐 줄)이고, 양쪽에 한 글자씩 강조가 선다.
    try testing.expectEqual(@as(usize, 1), st.left_marks.len);
    try testing.expectEqual(@as(usize, 1), st.left_marks[0].len);
    try testing.expectEqual(@as(u32, 6), st.left_marks[0][0].start); // "a"
    try testing.expectEqual(@as(u32, 1), st.left_marks[0][0].len);
    try testing.expectEqual(@as(u32, 6), st.right_marks[0][0].start); // "b"
}

test "순수 추가·삭제 행에는 강조가 없다 — 줄 전체가 이미 밴드다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("keep\n", "keep\nadded\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);
    for (st.left_marks) |m| try testing.expectEqual(@as(usize, 0), m.len);
    for (st.right_marks) |m| try testing.expectEqual(@as(usize, 0), m.len);
}

test "이모지가 반으로 잘리지 않는다 — cluster 경계로 자른다" {
    // 코드포인트로 자르면 ZWJ 시퀀스의 일부만 강조돼 **글자 하나가 두 색**이 된다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("x👨‍👩‍👧y\n", "x👍y\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);
    // 강조 범위가 cluster 경계에 정확히 맞는다(가족 이모지 전체 / 👍 전체).
    const left_line = st.left_texts[0];
    for (st.left_marks[0]) |m| {
        const s = left_line[m.start .. m.start + m.len];
        try testing.expect(std.unicode.utf8ValidateSlice(s)); // 반토막이면 여기서 깨진다
    }
    const right_line = st.right_texts[0];
    for (st.right_marks[0]) |m| {
        const s = right_line[m.start .. m.start + m.len];
        try testing.expect(std.unicode.utf8ValidateSlice(s));
    }
}

test "비교 Term의 본문이 헤더 밴드와 겹치지 않는다" {
    // **`file_entry`가 있으면 chrome이 그 pane에 헤더 밴드를 그린다**(§3.1 — breadcrumb·모드 선택기).
    // 웹 Term은 `inset.top = bar_h + addr_h`로 본문이 밴드 아래로 내려가는데, 편집기에는 그 보정이
    // 없어 본문 첫 행이 밴드와 같은 자리에 선다. 둘 중 하나가 다른 하나를 덮는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    // **이 Term을 활성으로 만든다** — 밴드는 pane의 **활성** Term이 파일일 때만 나온다.
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, i| {
        if (t == fx.term) pane.active_term = i;
    }
    const band = pane_ops.fileHeaderBandForPane(fx.session, pane, leaf) orelse return error.NoHeaderBand;
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    const band_bottom: u32 = band.band.y + band.band.h;
    // 본문은 밴드 **아래**에서 시작해야 한다.
    try testing.expect(drawn.rect.y >= band_bottom);
}

test "CRUMB1 비교의 breadcrumb는 그 비교를 읽은 저장소 기준이다" {
    // **접두는 빠른 고리에서 돌기 위한 것이다.** 이름에 등록된 접두가 없어 `test-editor` 필터가
    // 안 골랐고, 그래서 `bandPathFor` 를 파일 이름·절대경로로 되돌리는 변이가 **셋 다 살아남았다**
    // (적대적 검증 2026-09-09 — P1b·P2b·P3b). 판정자가 있는 것과 그것이 도는 것은 다르다.
    // **활성 저장소가 아니다.** 사용자가 다른 폴더로 옮겨 가도, 열려 있는 비교는 자기 저장소 기준
    // 위치를 말해야 한다 — 그러지 않으면 같은 화면이 창 상태에 따라 다른 경로를 보인다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("a\n", "b\n");
    entry.path = @constCast("/repo/one/src/app.zig");
    entry.diff_repo = @constCast("/repo/one");
    fx.term.file_entry = &entry;

    // **밴드가 실제로 그리는 문자열**을 본다(이음매 `bandPathFor`) — 루트 선택만 검사하면 제품이
    // 절대경로로 되돌아가도 아무 테스트가 안 깨진다.
    try testing.expectEqualStrings("src/app.zig", app_session_mod.bandPathFor(fx.session, &entry));
    const root = app_session_mod.breadcrumbRootFor(fx.session, &entry);
    try testing.expectEqualStrings("/repo/one", root);
    try testing.expectEqualStrings(
        "src/app.zig",
        maru.session.repo_path.displayRelative(entry.path, root),
    );

    // 저장소를 모르면 절대경로 그대로다 — 지어내지 않는다.
    entry.diff_repo = @constCast("");
    try testing.expectEqualStrings("", app_session_mod.breadcrumbRootFor(fx.session, &entry));
    try testing.expectEqualStrings("/repo/one/src/app.zig", app_session_mod.bandPathFor(fx.session, &entry));
    try testing.expectEqualStrings(
        "/repo/one/src/app.zig",
        maru.session.repo_path.displayRelative(entry.path, app_session_mod.breadcrumbRootFor(fx.session, &entry)),
    );

    // **`diff_repo` 는 비교 항목의 것이다.** 종류 가드를 지우면 비교가 아닌 파일도 그 값을 루트로
    // 삼는데, 그 필드는 그때 남의 저장소(마지막 비교)일 수 있다 — 그러면 밴드가 **틀린 경로**를
    // 그린다. 그 변이가 살아남아 이 단언을 세웠다(적대적 검증 2026-09-09 P14).
    entry.kind = .text;
    entry.diff_repo = @constCast("/repo/other");
    try testing.expectEqualStrings("", app_session_mod.breadcrumbRootFor(fx.session, &entry));
    entry.kind = .diff;

    // **원격 미러는 저쪽 경로를 그린다**(RF6e). 미러의 실제 자리는 로컬 캐시라, 그것을 그리면
    // 화면이 거짓말을 한다 — 사용자가 연 것은 저 기계의 파일이다. 그 우선순위를 지우는 변이가
    // 살아남아 여기서 잰다(P6).
    entry.remote_origin_label = @constCast("me@box:/srv/app/README.md");
    try testing.expectEqualStrings("me@box:/srv/app/README.md", app_session_mod.bandPathFor(fx.session, &entry));
}

test "강조 계산이 어디서 할당에 실패해도 새지 않는다 — 실패 지점을 전부 주입한다" {
    // L2(`intraline`)는 이미 이 검사를 통과했지만, **이 층이 그 위에 배열 셋을 더 잡는다**
    // (행별 마크 배열 둘 + cluster 토큰 둘 + 복사본). 부분 실패에서 앞서 잡은 것이 주인을 잃기 쉬운
    // 모양이라 여기도 같은 방법으로 본다.
    const Case = struct {
        fn run(allocator: std.mem.Allocator, left_src: []const u8, right_src: []const u8) !void {
            const left_lines = try diff_state.splitLines(allocator, left_src);
            defer if (left_lines.len > 0) allocator.free(left_lines);
            const right_lines = try diff_state.splitLines(allocator, right_src);
            defer if (right_lines.len > 0) allocator.free(right_lines);

            var view = try diff.compute(allocator, left_lines, right_lines, .{});
            defer if (view == .compare) view.compare.deinit(allocator);
            if (view != .compare) return;

            // `materialize`가 만드는 표시 텍스트를 같은 방식으로 세운다(줄 끝 문자를 뗀다).
            const rows = view.compare;
            const lt = try allocator.alloc([]const u8, rows.left.len);
            defer allocator.free(lt);
            const rt = try allocator.alloc([]const u8, rows.right.len);
            defer allocator.free(rt);
            for (rows.left, 0..) |r, i| lt[i] = displayText(r.text);
            for (rows.right, 0..) |r, i| rt[i] = displayText(r.text);

            var st: State = .{ .view = view, .left_texts = lt, .right_texts = rt };
            defer {
                freeMarks(allocator, st.left_marks);
                freeMarks(allocator, st.right_marks);
            }
            try computeMarks(allocator, &st);
            st.view = .loading; // 위 defer가 rows를 두 번 해제하지 않게 한다(소유는 이 함수에 있다)
        }
    };
    // 여러 줄이 짝을 이루고 각 줄에 강조가 여러 덩어리 — 할당 지점이 가장 많은 모양이다.
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{
        "a=1 and b=2\nkeep\nx=3 or y=4\n",
        "a=9 and b=8\nkeep\nx=7 or y=6\n",
    });
}

test "표시 배열 만들기가 어디서 할당에 실패해도 새지 않는다" {
    // **`computeMarks`에서 잡은 것과 같은 모양이 한 층 위에 있는지 본다.** 그쪽은 배열을 `st`에 넘긴
    // 뒤에도 `errdefer`가 살아 있어 실패 시 두 번 풀렸다. 여기도 여섯 개를 잡아 `st`에 넘기고 **그
    // 뒤에** `computeMarks`를 부르므로, 그 호출이 실패하면 같은 일이 일어난다.
    const Case = struct {
        fn run(allocator: std.mem.Allocator, left_src: []const u8, right_src: []const u8) !void {
            const left_lines = try diff_state.splitLines(allocator, left_src);
            defer if (left_lines.len > 0) allocator.free(left_lines);
            const right_lines = try diff_state.splitLines(allocator, right_src);
            defer if (right_lines.len > 0) allocator.free(right_lines);

            var view = try diff.compute(allocator, left_lines, right_lines, .{});
            defer if (view == .compare) view.compare.deinit(allocator);
            if (view != .compare) return;

            var st: State = .{ .view = view };
            // **제품과 같은 해제를 부른다** — 목록을 손으로 복제하면 새 배열이 늘 때 여기가 뒤처진다
            // (`invalidate`는 세션이 필요해 못 부르지만, 해제 자체는 이 함수가 소유한다).
            defer freeRowArrays(allocator, &st);
            try materialize(allocator, &st);
            st.view = .loading; // rows는 위 `view.compare.deinit` defer가 푼다(`freeRowArrays`는 배열만)
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{
        "a=1 and b=2\nkeep\nx=3\n",
        "a=9 and b=8\nkeep\nx=7\n",
    });
}

test "긴 줄 하나가 바뀌어도 마크 계산이 줄 길이만큼 잡지 않는다 — 상한은 만드는 자리에 있다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = fa.allocator();
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // minified JS 한 줄 — content.zig가 실제 사례로 이름을 부르는 그 입력이다.
    const n = 200_000;
    const a = try testing.allocator.alloc(u8, n + 1);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, n + 1);
    defer testing.allocator.free(b);
    @memset(a[0..n], 'x');
    @memset(b[0..n], 'x');
    b[n / 2] = 'y'; // 딱 한 글자 다르다
    a[n] = '\n';
    b[n] = '\n';

    var entry = testEntry(a, b);
    fx.term.file_entry = &entry;
    const before = fa.allocated_bytes;
    poll(fx.session, fx.term);
    const used = fa.allocated_bytes - before;

    // **측정값이다.** 상한을 `clusterTokens` 안으로 옮기기 전 12,321,655B → 옮긴 뒤 7,279B
    // (Debug, macOS arm64). 토큰 배열이 줄 길이에 비례해 자랐다가 `intraline`이 `max_tokens`로
    // 곧바로 버리던 것이다. 여유를 두되 **줄 길이(200 KB)보다 훨씬 작다**를 지킨다 — 상한을 다시
    // 소비하는 자리로 되돌리면 이 단언이 죽는다.
    try testing.expect(used < 64 * 1024);
}

test "비교 계산이 어디서 할당에 실패해도 새거나 두 번 풀지 않는다 — poll 전체를 흔든다" {
    // 지금까지는 `materialize`·`computeMarks`만 따로 주입했다(각각 이중 해제를 잡았다). 그 둘을
    // 부르는 **경로 전체**(줄 분할·대응·표시 배열·마크)를 한 번에 흔들어, 아직 안 본 자리에 같은
    // 모양이 남아 있는지 본다. 세션 allocator는 init에 고정이라 `checkAllAllocationFailures`를
    // 그대로 못 쓴다 — 세션을 실패 allocator로 만들고 **init이 끝난 뒤부터** 실패 지점을 민다
    // (`editor.zig`의 파일 열기 테스트와 같은 방법).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const backing = testing.allocator;

    var failed_steps: usize = 0;
    var ok_steps: usize = 0;
    // 실패 지점을 0부터 훑되, 한 스텝이 «실패를 못 주입한 채» 끝나면(할당 수를 넘어섰다) 그 뒤는 전부 같은
    // 성공이라 멈춘다. 120 스텝을 다 돌던 때는 이 테스트 하나가 14.5 초(CI)였다. 검증 범위는 그대로다.
    var diff_clean_pass = false;
    var step: usize = 0;
    while (step < 120) : (step += 1) {
        if (diff_clean_pass) break;
        var fa = std.testing.FailingAllocator.init(backing, .{});
        defer if (!fa.has_induced_failure) {
            diff_clean_pass = true;
        };
        const allocator = fa.allocator();
        var fx = try Fixture.init(allocator);
        defer fx.deinit(allocator);

        var entry = testEntry(
            "fn main() {\n  var a = 1;\n  log(a);\n}\n",
            "fn main() {\n  var b = 2;\n  var c = 3;\n  log(b);\n}\n",
        );
        fx.term.file_entry = &entry;

        fa.fail_index = fa.allocations + step; // 여기서부터 실패한다
        poll(fx.session, fx.term);
        if (fx.term.rt.editor_diff) |st| {
            if (std.meta.activeTag(st.view) == .compare and st.left_texts.len > 0) ok_steps += 1 else failed_steps += 1;
        } else failed_steps += 1;
        // 실패했든 아니든 **다시 한 번** 굴린다 — 반쯤 지어진 상태에서 이어 계산하는 자리가 있으면
        // 여기서 드러난다(정상 경로만 도는 테스트로는 절대 안 보인다).
        poll(fx.session, fx.term);
        invalidate(fx.session, fx.term);
    }
    // **공허해질 수 없게 센다** — 한 번도 실패하지 않으면 이 테스트는 아무것도 지키지 않는다.
    try testing.expect(failed_steps >= 5);
    try testing.expect(ok_steps >= 1);
}

test "알려진 구멍: 랩을 켠 비교는 좌우가 어긋난다 — 조각 단위 정렬 대기" {
    // §3.5는 **세로를 공유**한다 — 같은 행이 같은 높이에 서야 비교가 성립한다. 그런데 랩이 켜지면
    // 좌우가 **각자** 접히므로, 한쪽 줄이 3조각이고 반대쪽이 1조각이면 그 아래 행부터 어긋난다.
    // 조각 오프셋도 좌우가 공유하므로(§4.1d) 이 상태에서 스크롤하면 무엇이 보이는지가 갈린다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    // 왼쪽은 짧고 오른쪽은 아주 긴 줄 — 접힘 수가 확실히 갈린다.
    var long_buf: std.ArrayList(u8) = .empty;
    defer long_buf.deinit(allocator);
    try long_buf.appendSlice(allocator, "b");
    for (0..400) |_| try long_buf.appendSlice(allocator, "x");
    try long_buf.append(allocator, '\n');

    var entry = testEntry("a\nb\nc\n", try std.fmt.allocPrint(allocator, "a\n{s}c\n", .{long_buf.items}));
    defer allocator.free(entry.diff_modified);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = true;
    poll(fx.session, fx.term);

    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);

    // 좌우 열을 가르는 x를 구해 각 열의 마지막 행을 센다.
    const inner_w: u32 = @intCast(leaf.w -| chrome_editor.frame.content_inset_px * 2);
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = inner_w, .h = 100 }, 8);
    var left_rows: usize = 0;
    var right_rows: usize = 0;
    for (drawn.dl.cells) |c| {
        const x = @as(i32, c.col) * 8;
        if (x < cols.right.x) left_rows = @max(left_rows, @as(usize, c.row) + 1) else right_rows = @max(right_rows, @as(usize, c.row) + 1);
    }
    // **같은 내용이 같은 높이에 있는가** — 셋째 행의 'c'를 좌우에서 찾는다.
    var left_c: ?u16 = null;
    var right_c: ?u16 = null;
    for (drawn.dl.cells) |c| {
        if (c.codepoint != 'c') continue;
        const x = @as(i32, c.col) * 8;
        if (x < cols.right.x) left_c = c.row else right_c = c.row;
    }
    try testing.expect(left_c != null and right_c != null);

    // **이 단언은 "옳다"가 아니라 "지금 이렇다"이다.** §3.5는 같은 행이 같은 높이에 서기를 요구하는데
    // (그래야 비교가 성립한다), 랩이 켜지면 좌우가 **각자** 접혀 그 전제가 깨진다 — 실측: 왼쪽 3행 /
    // 오른쪽 13행, 같은 `c`가 2행 대 12행. **기본 상태는 아니다**(2026-09-08 재확인) — 이 주석을
    // 쓸 때는 `editor.wrap` 기본값이 `true`였지만 `99f79786`이 방침대로 `false`로 되돌렸고,
    // 지금 필드 기본값도 `false`다(`config/theme.zig`). 랩을 **켠** 비교에서만 남는 구멍이다
    // (visual-mapping §4.1d 가 같은 정정을 이미 적어 뒀는데 이 주석만 낡아 있었다).
    //
    // **Vim 선례를 따라 고치지 않고 적는다**(2026-08-16 사용자 결정 — visual-mapping §4.1d).
    // Vim 문서가 정렬이 깨지는 첫 조건으로 *"'wrap' is on"*을 명시하고 고치지 않았다. Monaco도 같은
    // 정렬 문제가 공개 이슈로 남아 있고, Zed가 해내는 것은 spacer가 **진단·인라인 어시스트와 공유하는
    // 범용 층**이기 때문이다 — 우리에겐 그 층이 없어 diff 전용 특수 코드가 된다.
    //
    // **실질적인 완화는 `editor.wrap` 기본값 되돌림**이고(비교 뷰 가로 스크롤과 한 슬라이스로 묶는다),
    // 그러면 비교는 기본적으로 랩이 아니게 되어 이 상태 자체가 드물어진다.
    try testing.expect(left_c.? != right_c.?);
}

test "비교는 열마다 따로 민다 — 포인터가 어느 열인지 정한다(§3.5)" {
    // 계약: *"각 편집기가 자기 안에서 스크롤한다"*. 공유하면 양쪽 줄 길이가 달라 한쪽을 따라갈 때
    // 다른 쪽이 엉뚱한 곳을 본다. 어느 열인지는 `diff_frame.columns()` 경계와 포인터가 정한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 400 };

    // 양쪽 모두 화면보다 긴 줄을 둔다 — 안 넘치면 축을 안 가져가 판정이 공허해진다.
    var left_buf: std.ArrayList(u8) = .empty;
    defer left_buf.deinit(allocator);
    var right_buf: std.ArrayList(u8) = .empty;
    defer right_buf.deinit(allocator);
    for (0..400) |_| try left_buf.append(allocator, 'L');
    for (0..400) |_| try right_buf.append(allocator, 'R');
    try left_buf.append(allocator, '\n');
    try right_buf.append(allocator, '\n');

    var entry = testEntry(left_buf.items, right_buf.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const inset = chrome_editor.frame.content_inset_px;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body.w -| inset * 2, .h = body.h -| inset * 2 }, 8);
    const origin: i32 = @as(i32, @intCast(body.x)) + @as(i32, @intCast(inset));
    const left_x: f64 = @floatFromInt(origin + cols.left.x + @as(i32, @intCast(cols.left.w / 2)));
    const right_x: f64 = @floatFromInt(origin + cols.right.x + 4);

    // ① 왼쪽 위에서 굴리면 왼쪽만 움직인다.
    try testing.expect(editor_ops.scrollCols(fx.session, fx.term, leaf, -20, left_x));
    try testing.expect(fx.term.rt.editor_first_col > 0);
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col_right);

    // ② 오른쪽 위에서 굴리면 오른쪽만 움직인다.
    const left_after = fx.term.rt.editor_first_col;
    try testing.expect(editor_ops.scrollCols(fx.session, fx.term, leaf, -30, right_x));
    try testing.expect(fx.term.rt.editor_first_col_right > 0);
    try testing.expectEqual(left_after, fx.term.rt.editor_first_col); // 왼쪽은 그대로다

    // ③ 두 값이 실제로 다르다 — 같으면 공유하고 있는 것이다.
    try testing.expect(fx.term.rt.editor_first_col != fx.term.rt.editor_first_col_right);
}

test "창이 넓어지면 오른쪽 열의 가로 위치도 되돌린다" {
    // 왼쪽에는 `clampScrollToGeometry`가 있는데 오른쪽은 이 슬라이스에서 새로 생긴 상태다.
    // 안 되돌리면 창을 넓혔을 때 **오른쪽 열만** 빈다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var right_buf: std.ArrayList(u8) = .empty;
    defer right_buf.deinit(allocator);
    for (0..400) |_| try right_buf.append(allocator, 'R');
    try right_buf.append(allocator, '\n');
    var entry = testEntry("a\n", right_buf.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    // 좁은 창에서 오른쪽 열을 끝까지 민다.
    const narrow: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 500, .h = 400 };
    const body_n = editor_ops.editorBodyRect(fx.session, narrow, fx.term);
    const inset = chrome_editor.frame.content_inset_px;
    const cols_n = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body_n.w -| inset * 2, .h = body_n.h -| inset * 2 }, 8);
    const rx: f64 = @floatFromInt(@as(i32, @intCast(body_n.x)) + @as(i32, @intCast(inset)) + cols_n.right.x + 4);
    _ = editor_ops.scrollCols(fx.session, fx.term, narrow, -1_000_000, rx);
    const at_end = fx.term.rt.editor_first_col_right;
    try testing.expect(at_end > 0);

    // 창이 아주 넓어졌다 — 다음 프레임이 되돌려야 한다.
    const wide: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 2400, .h = 400 };
    var drawn = editor_ops.appendPaneFrame(fx.session, wide, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_first_col_right < at_end); // 되돌아왔다
}

test "열 경계에서 어느 쪽으로 가는지가 정해져 있다 — 경계 바로 왼쪽·오른쪽" {
    // 열을 고르는 판정이 한 픽셀 어긋나면 경계 근처에서 **반대 열**이 밀린다. 사람 눈에는 "가끔
    // 엉뚱한 쪽이 움직인다"로 보인다. 경계 양옆을 콕 집어 본다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 400 };

    var lb: std.ArrayList(u8) = .empty;
    defer lb.deinit(allocator);
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    for (0..400) |_| try lb.append(allocator, 'L');
    for (0..400) |_| try rb.append(allocator, 'R');
    try lb.append(allocator, '\n');
    try rb.append(allocator, '\n');
    var entry = testEntry(lb.items, rb.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const inset = chrome_editor.frame.content_inset_px;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body.w -| inset * 2, .h = body.h -| inset * 2 }, 8);
    const origin: i32 = @as(i32, @intCast(body.x)) + @as(i32, @intCast(inset));

    // 경계 **바로 왼쪽**(1px 앞) → 왼쪽 열
    _ = editor_ops.scrollCols(fx.session, fx.term, leaf, -10, @floatFromInt(origin + cols.right.x - 1));
    try testing.expect(fx.term.rt.editor_first_col > 0);
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col_right);

    // 경계 **정확히 그 자리** → 오른쪽 열(반열림 구간 `[right.x, …)`)
    _ = editor_ops.scrollCols(fx.session, fx.term, leaf, -10, @floatFromInt(origin + cols.right.x));
    try testing.expect(fx.term.rt.editor_first_col_right > 0);
}

test "오른쪽 열이 왼쪽보다 넓어도 상한이 자기 폭을 따른다" {
    // `columns()`는 나머지 픽셀을 **오른쪽에 준다**(pane 오른쪽 끝에 안 칠한 띠가 남지 않게).
    // 그러면 오른쪽 열이 왼쪽보다 넓을 수 있는데, 상한을 왼쪽 폭으로 세면 오른쪽이 **한 열 덜**
    // 간다 — 마지막 글자에 못 닿는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    // 홀수 폭이라 나머지가 생긴다.
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 903, .h = 400 };

    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    for (0..300) |_| try rb.append(allocator, 'R');
    try rb.append(allocator, '\n');
    var entry = testEntry("a\n", rb.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const inset = chrome_editor.frame.content_inset_px;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body.w -| inset * 2, .h = body.h -| inset * 2 }, 8);
    try testing.expect(cols.right.w > cols.left.w); // 나머지가 오른쪽에 붙었다 — 아니면 이 판정이 공허하다

    const rx: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + @as(i32, @intCast(inset)) + cols.right.x + 4);
    _ = editor_ops.scrollCols(fx.session, fx.term, leaf, -1_000_000, rx);
    const first = fx.term.rt.editor_first_col_right;

    // 오른쪽 열이 실제로 쓰는 본문 폭으로 상한을 다시 계산해 대조한다.
    const m = chrome_editor.diff_frame.sideMetrics(cols.right.w, body.h -| inset * 2, 8, 16);
    const layout = chrome_editor.geometry.compute(m.total_cols, 1, .{});
    // **상한은 밀 수 있는 총 열 수에서 나온다** — 내용 폭 + 줄 끝 너머 몫
    // (`editor.scroll-beyond-last-column`. 열마다 **자기** 상한에 더한다 — §3.5 "가로는 각자다").
    const beyond = fx.session.loaded_config.config.editor.scroll_beyond_last_column;
    const expect_first: u32 = (fx.term.rt.editor_max_cols_right +| beyond) -| layout.content.width;
    // 고치기 전: 오른쪽 본문이 46열인데 pane 폭으로 102열을 잡아 198에서 멈췄다(실제 상한 254).
    try testing.expectEqual(layout.content.width, editor_ops.visibleColsForTest(fx.session, body, fx.term, true));
    try testing.expectEqual(expect_first, @as(u32, first));
}

test "비교의 본문 열 수는 한 열 폭으로 센다 — pane 폭을 쓰면 두 배가 된다" {
    // **이 테스트는 한 번 사라졌다.** 뮤테이션 스윕이 도는 동안 같은 파일을 고쳐, 스윕의 복원이
    // 수정과 이 테스트를 함께 덮어썼다(2026-08-16). 커밋 메시지는 "고쳤다"고 적혔는데 실제로는
    // 테스트만 들어갔고, 다음 라운드에서 오른쪽 열 상한이 어긋나며 드러났다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);

    const single = editor_ops.visibleColsForTest(fx.session, body, fx.term, false); // 편집기 하나

    var entry = testEntry("a\nb\n", "a\nB\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    const left_col = editor_ops.visibleColsForTest(fx.session, body, fx.term, false);
    const right_col = editor_ops.visibleColsForTest(fx.session, body, fx.term, true);
    try testing.expect(left_col < single); // 한 열은 pane 하나보다 좁다
    try testing.expect(right_col < single);
    try testing.expect(left_col > 0 and right_col > 0);
}

test "랩이 켜지면 두 열 모두 렌더에 0이 간다 — 오른쪽만 빠지면 안 된다" {
    // 컴포넌트가 `!wrap or first_col == 0`을 어서션으로 요구한다(§4.1d). 열이 둘이 되면서 그 규칙이
    // 오른쪽에 **인라인으로 다시 쓰여** 있었다 — 한 곳을 고치면 다른 쪽이 안 따라오는 상태였다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 400 };

    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    for (0..400) |_| try rb.append(allocator, 'R');
    try rb.append(allocator, '\n');
    var entry = testEntry("a\n", rb.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    // 오른쪽 열을 민 상태를 만든다.
    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const inset = chrome_editor.frame.content_inset_px;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body.w -| inset * 2, .h = body.h -| inset * 2 }, 8);
    const rx: f64 = @floatFromInt(@as(i32, @intCast(body.x)) + @as(i32, @intCast(inset)) + cols.right.x + 4);
    _ = editor_ops.scrollCols(fx.session, fx.term, leaf, -30, rx);
    try testing.expect(fx.term.rt.editor_first_col_right > 0);

    // 랩을 켜면 **저장된 값은 두고** 렌더에는 0이 간다 — 그리기가 어서션에 안 걸려야 한다.
    const stored = fx.term.rt.editor_first_col_right;
    fx.term.rt.editor_wrap = true;
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(drawn.dl.cells.len > 0);
    try testing.expectEqual(stored, fx.term.rt.editor_first_col_right); // 랩을 끄면 돌아갈 자리
}

test "gutter 자릿수는 렌더와 같은 출처로 센다 — 최소 자릿수가 가려도 같은 것은 아니다" {
    // 렌더는 `total_lines`에 **문서 줄 수**를 넘기는데(`st.left_lines.len`), 상한을 세는 쪽이
    // **행 수**(filler 포함)를 쓰면 갈린다. `min_line_number_cells`(Monaco `lineNumbersMinChars` = 5)가
    // 10만 줄까지 가려 주므로 **작은 문서로 쓴 테스트는 공허하다** — 실제로 9줄/12행으로 먼저 써 보고
    // 통과해서 알았다. 그래서 **가림막을 넘는 크기**로 본다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 600 };
    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);

    // 문서 99,999줄(5자리) 대 행 100,001개(6자리) — 내용은 안 보므로 길이만 맞춘다.
    const doc = try allocator.alloc([]const u8, 99_999);
    defer allocator.free(doc);
    @memset(doc, "");
    const rows = try allocator.alloc([]const u8, 100_001);
    defer allocator.free(rows);
    @memset(rows, "");

    fx.term.rt.editor_diff = .{ .requested_ms = 0 };
    fx.term.rt.editor_diff.?.view = .{ .compare = .{ .left = &.{}, .right = &.{}, .changed = 1 } };
    fx.term.rt.editor_diff.?.left_texts = rows;
    fx.term.rt.editor_diff.?.right_texts = rows;
    fx.term.rt.editor_diff.?.left_lines = doc;
    fx.term.rt.editor_diff.?.right_lines = doc;
    defer fx.term.rt.editor_diff = null;

    try testing.expect(chrome_editor.geometry.digitCount(rows.len) > chrome_editor.geometry.digitCount(doc.len));
    try testing.expect(chrome_editor.geometry.digitCount(doc.len) >= chrome_editor.geometry.min_line_number_cells); // 가림막 밖이다

    const inset = chrome_editor.frame.content_inset_px;
    const cols = chrome_editor.diff_frame.columns(.{ .x = 0, .y = 0, .w = body.w -| inset * 2, .h = body.h -| inset * 2 }, 8);
    const m = chrome_editor.diff_frame.sideMetrics(cols.left.w, body.h -| inset * 2, 8, 16);
    const want = chrome_editor.geometry.compute(m.total_cols, doc.len, .{}).content.width; // 렌더가 쓰는 출처
    try testing.expectEqual(want, editor_ops.visibleColsForTest(fx.session, body, fx.term, false));
}

test "비교가 서면 좌우 가장 긴 줄을 센다 — 가로 막대가 첫 프레임부터 뜬다 (§4.1a)" {
    // 단일 편집기는 **여는 경로**에서 센다(굴려 보기 전에 그 축이 있는지 알 수 있어야 한다 —
    // 2026-08-18 사용자 지적). 비교는 두 쪽이 비동기로 도착하므로 그 자리가 `computeRows`다.
    //
    // **좌우 각자다**(§3.5) — 원본과 수정본의 가장 긴 줄이 다르고, 막대 길이도 그래서 각자여야 한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 오른쪽을 훨씬 길게 준다 — 좌우 캐시가 **다른 값**이어야 각자 센 것이 증명된다.
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    for (0..300) |_| try rb.append(allocator, 'R');
    try rb.append(allocator, '\n');
    var entry = testEntry("short\n", rb.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_max_cols = 0;
    fx.term.rt.editor_max_cols_right = 0;

    poll(fx.session, fx.term);

    try testing.expect(fx.term.rt.editor_max_cols > 0); // 왼쪽도 셌다
    try testing.expect(fx.term.rt.editor_max_cols_right > fx.term.rt.editor_max_cols); // 오른쪽이 더 길다
}

test "비교의 가로 막대는 잡은 열만 민다 — 오른쪽을 끌면 오른쪽만 (§3.5)" {
    // §3.5가 *"가로는 각자다"*를 요구한다 — 좌우 줄 길이가 달라 한쪽을 따라가면 반대쪽이 엉뚱한 곳을
    // 본다. 막대도 각자이므로 **잡은 막대의 열만** 움직여야 한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 400 };

    // 양쪽 모두 넘치게 준다 — 그래야 막대가 좌우에 다 선다.
    var lb: std.ArrayList(u8) = .empty;
    defer lb.deinit(allocator);
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    for (0..300) |_| try lb.append(allocator, 'L');
    try lb.append(allocator, '\n');
    for (0..400) |_| try rb.append(allocator, 'R');
    try rb.append(allocator, '\n');
    var entry = testEntry(lb.items, rb.items);
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    // **Fixture는 Term을 pane에 붙이기만 한다** — 드래그 진입점이 `pane.activeTerm()`을 보므로
    // 여기서 활성으로 만든다(제품에서는 파일을 열면 그 Term이 활성이 된다).
    fx.session.focusTerm(pane_ops.activePane(fx.session).terms.items.len - 1);
    poll(fx.session, fx.term);

    var f = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    f.dl.deinit(allocator);

    const right_bar = fx.term.rt.editor_horizontal_scrollbar_right orelse return error.NoRightHorizontalScrollbar;
    const left_before = fx.term.rt.editor_first_col;

    // 오른쪽 막대를 끈다.
    try testing.expect(editor_ops.beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), @floatCast(right_bar.thumb_x), @floatCast(right_bar.track_y)));
    // **무엇을 잡았는지 못박는다.** 좌표가 세로 막대와 겹치면 판정 순서상 세로가 먼저 잡히는데, 그때는
    // 아래 단언이 "열이 안 움직였다"로 실패해 **왜 실패했는지 말하지 않는다**.
    try testing.expectEqual(@as(@TypeOf(fx.session.scrollbar_drag_target), .editor_horizontal), fx.session.scrollbar_drag_target);
    const mid_x: f64 = @as(f64, right_bar.track_x) + @as(f64, right_bar.track_w) / 2;
    _ = editor_ops.routeScrollbarCapture(fx.session, 2, mid_x, @floatCast(right_bar.track_y));
    scroll_ops.applyPendingEditorHScroll(fx.session);

    // **오른쪽만 움직였다** — 왼쪽까지 따라가면 §3.5가 깨진다.
    try testing.expect(fx.term.rt.editor_first_col_right > 0);
    try testing.expectEqual(left_before, fx.term.rt.editor_first_col);

    _ = editor_ops.routeScrollbarCapture(fx.session, 3, mid_x, @floatCast(right_bar.track_y));
    try testing.expect(!editor_ops.scrollbarCaptureActive(fx.session));

    // **반대쪽도 본다.** 오른쪽만 검증하면 "늘 오른쪽을 민다"는 뮤턴트가 살아남는다(실측으로 확인했다 —
    // 그 뮤턴트는 단일 편집기 테스트가 잡았지만, 비교 안에서 대칭이 깨지는 것은 여기서만 보인다).
    const left_bar = fx.term.rt.editor_horizontal_scrollbar orelse return error.NoLeftHorizontalScrollbar;
    const right_after = fx.term.rt.editor_first_col_right;
    try testing.expect(editor_ops.beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), @floatCast(left_bar.thumb_x), @floatCast(left_bar.track_y)));
    try testing.expectEqual(@as(@TypeOf(fx.session.scrollbar_drag_target), .editor_horizontal), fx.session.scrollbar_drag_target);
    const left_mid_x: f64 = @as(f64, left_bar.track_x) + @as(f64, left_bar.track_w) / 2;
    _ = editor_ops.routeScrollbarCapture(fx.session, 2, left_mid_x, @floatCast(left_bar.track_y));
    scroll_ops.applyPendingEditorHScroll(fx.session);

    try testing.expect(fx.term.rt.editor_first_col > 0); // 왼쪽이 움직였고
    try testing.expectEqual(right_after, fx.term.rt.editor_first_col_right); // 오른쪽은 그대로다

    _ = editor_ops.routeScrollbarCapture(fx.session, 3, left_mid_x, @floatCast(left_bar.track_y));
}

test "비교의 세로 막대는 좌우 어느 쪽을 잡아도 같은 곳으로 간다 — 세로는 공유다 (§3.5)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 900, .h = 400 };

    // 같은 문서를 두 번 세워 왼쪽 막대와 오른쪽 막대를 각각 끌고 결과를 비교한다.
    var results: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |use_right, idx| {
        var fx = try Fixture.init(allocator);
        defer fx.deinit(allocator);
        // **좌우가 달라야 비교가 선다** — 같은 내용을 주면 `view = unchanged`가 되어 상태 문구 한 줄만
        // 그리고 막대가 아예 없다(첫 시도가 그랬다).
        var left: std.ArrayList(u8) = .empty;
        defer left.deinit(allocator);
        var right: std.ArrayList(u8) = .empty;
        defer right.deinit(allocator);
        for (0..200) |_| try left.appendSlice(allocator, "line\n");
        for (0..200) |_| try right.appendSlice(allocator, "LINE\n");
        var entry = testEntry(left.items, right.items);
        fx.term.file_entry = &entry;
        fx.term.rt.editor_wrap = false;
        fx.session.focusTerm(pane_ops.activePane(fx.session).terms.items.len - 1);
        poll(fx.session, fx.term);
        var f = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
        f.dl.deinit(allocator);

        const bar = (if (use_right) fx.term.rt.editor_scrollbar_right else fx.term.rt.editor_scrollbar) orelse return error.NoScrollbar;
        try testing.expect(editor_ops.beginScrollbarGesture(fx.session, pane_ops.activePane(fx.session), @floatCast(bar.track_x), @floatCast(bar.thumb_y)));
        try testing.expectEqual(@as(@TypeOf(fx.session.scrollbar_drag_target), .editor_vertical), fx.session.scrollbar_drag_target);
        const mid_y: f64 = @as(f64, bar.track_y) + @as(f64, bar.track_h) / 2;
        _ = editor_ops.routeScrollbarCapture(fx.session, 2, @floatCast(bar.track_x), mid_y);
        scroll_ops.applyPendingScrollbarScroll(fx.session);
        results[idx] = fx.term.rt.editor_first_line;
        _ = editor_ops.routeScrollbarCapture(fx.session, 3, @floatCast(bar.track_x), mid_y);
    }
    try testing.expect(results[0] > 0); // 실제로 움직였다
    try testing.expectEqual(results[0], results[1]); // 좌우가 같은 곳으로 갔다
}

test "비교 뷰에서는 접기를 거절한다 — 성공을 돌려주고 아무 일도 안 하면 안 된다" {
    // `foldAll`은 `editorLines`를 쓰는데 비교에서는 **왼쪽 행 배열**이 나온다. 그러면 접힘 상태가
    // 만들어지지만 렌더는 diff 경로를 타므로 **화면은 그대로**다 — 성공을 돌려주고 아무 일도 안
    // 일어나면 사용자는 이유를 알 수 없다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };

    // **이 Term을 활성으로 만든다** — `foldAll`은 활성 Term에 작용한다. 안 그러면 엉뚱한 Term을 보고
    // `false`가 나와 "비교에서는 안 접힌다"고 오판한다(실제로 처음에 그렇게 읽었다).
    const pane = pane_ops.activePane(fx.session);
    fx.session.focusTerm(pane.terms.items.len - 1);

    var entry = testEntry("a\n  b\n  c\n", "a\n  b\n  C\n");
    fx.term.file_entry = &entry;
    fx.term.rt.editor_wrap = false;
    poll(fx.session, fx.term);

    var before = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    const cells_before = before.dl.cells.len;
    before.dl.deinit(allocator);

    const folded = editor_ops.foldAll(fx.session);
    var after = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    defer after.dl.deinit(allocator);

    // **거절해야 한다.** 초판은 `true`를 돌려주면서 화면은 그대로였다(셀 20 → 20) — 접힘 상태를
    // 만들지만 렌더가 비교 경로를 타서 무시했다. 이유는 랩과 같다: 좌우 행이 짝을 이뤄 같은 높이에
    // 서야 비교가 성립한다.
    try testing.expect(!folded);
    try testing.expectEqual(cells_before, after.dl.cells.len);
    try testing.expect(!editor_ops.unfoldAll(fx.session));
}

test "DSEL1 비교 뷰 좌표계: 좌우를 갈라 그 열의 행과 byte를 답한다 (§4.1g 비교 뷰)" {
    // **문서가 둘이면 offset 하나로 못 적는다.** 화면에 서는 것은 원본 줄이 아니라 짝을 맞춰
    // 정렬한 행 배열이고, 빈 행이 그 안에 섞여 있다 — 그래서 좌표를 `(어느 열, 행, 행 안 byte)`
    // 셋으로 적는다. 단일 편집기보다 두 단계 짧다(접힘 층·문서 offset 변환이 없다).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 왼쪽만 있는 줄·오른쪽만 있는 줄·양쪽 다 있는 줄이 섞이게 만든다.
    var entry = testEntry("keep\nremoved\ntail\n", "keep\nadded line\ntail\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn.dl.deinit(allocator);

    // **좌우 행이 굳었다.**
    try testing.expect(fx.term.rt.editor_diff_hit_len_left > 0);
    try testing.expect(fx.term.rt.editor_diff_hit_len_right > 0);

    const g = fx.term.rt.editor_diff_hit_geom;
    try testing.expect(g.right_x > g.left_x); // 오른쪽 열이 실제로 오른쪽에 있다

    const y0: f64 = @floatFromInt(g.body_y + 1);
    const left_text_x: f64 = @floatFromInt(g.left_x + @as(i32, @intCast(g.content_left_px)) + 1);
    const right_text_x: f64 = @floatFromInt(g.right_x + @as(i32, @intCast(g.content_left_px)) + 1);

    // ⑴ **왼쪽 열을 누르면 왼쪽이라 답한다.**
    const l = editor_ops.hitTestDiffBody(fx.term, left_text_x, y0, null) orelse return error.NoHit;
    try testing.expectEqual(editor_ops.DiffSide.left, l.side);
    try testing.expectEqual(@as(usize, 0), l.row);
    try testing.expectEqual(@as(usize, 0), l.byte);

    // ⑵ **오른쪽 열을 누르면 오른쪽이다.**
    const r = editor_ops.hitTestDiffBody(fx.term, right_text_x, y0, null) orelse return error.NoHit;
    try testing.expectEqual(editor_ops.DiffSide.right, r.side);
    try testing.expectEqual(@as(usize, 0), r.row);

    // ⑶ **열 안에서 x가 커지면 byte가 커진다** — `byteAtPoint`가 실제로 걸었다.
    const far_x: f64 = @floatFromInt(g.left_x + @as(i32, @intCast(g.content_left_px)) + @as(i32, @intCast(3 * @as(u32, g.cell_w_px))) + 1);
    const l3 = editor_ops.hitTestDiffBody(fx.term, far_x, y0, null) orelse return error.NoHit;
    try testing.expectEqual(@as(usize, 3), l3.byte);

    // ⑷ **아래로 가면 행이 는다.**
    const y1: f64 = @floatFromInt(g.body_y + @as(i32, @intCast(g.cell_h_px)) + 1);
    const l4 = editor_ops.hitTestDiffBody(fx.term, left_text_x, y1, null) orelse return error.NoHit;
    try testing.expectEqual(@as(usize, 1), l4.row);

    // ⑸ **gutter는 받지 않는다** — 줄 번호 자리다.
    const gutter_x: f64 = @floatFromInt(g.left_x + 1);
    try testing.expectEqual(@as(?editor_ops.DiffHit, null), editor_ops.hitTestDiffBody(fx.term, gutter_x, y0, null));

    // ⑹ **잡은 열을 강제하면 반대 열 좌표에도 그 열로 답한다** — 드래그가 열을 안 넘는다는 계약.
    const forced = editor_ops.hitTestDiffBody(fx.term, right_text_x, y0, .left) orelse return error.NoHit;
    try testing.expectEqual(editor_ops.DiffSide.left, forced.side);

    // ⑺ **세로 밖은 clamp한다**(드래그가 pane을 벗어나는 것은 정상이다).
    const far_below: f64 = @floatFromInt(g.body_y + 100000);
    const l7 = editor_ops.hitTestDiffBody(fx.term, left_text_x, far_below, null) orelse return error.NoHit;
    try testing.expectEqual(fx.term.rt.editor_diff_hit_len_left - 1, l7.row);

    // ⑻ **비교가 아니면 받지 않는다.** view를 바꾼 채 끝나면 `release`가 `compare` 자원을 안 놓아
    //    누수가 난다(그 함수가 `view == .compare`일 때만 `deinit`한다) — 반드시 되돌린다.
    const saved_view = fx.term.rt.editor_diff.?.view;
    fx.term.rt.editor_diff.?.view = .loading;
    try testing.expectEqual(@as(?editor_ops.DiffHit, null), editor_ops.hitTestDiffBody(fx.term, left_text_x, y0, null));
    fx.term.rt.editor_diff.?.view = saved_view;
}
// DSEL5: **복사가 줄 끝을 원본대로 낸다.**
//
// `*_texts`는 §3.8 가시화 때문에 줄 끝을 뗀 것이라, 그것만 이어 붙이면 CRLF 문서가 **LF로 바뀌어**
// 클립보드에 나간다. 단일 편집기(`copySelection`)는 문서 byte를 그대로 뜨므로 CRLF가 보존되는데,
// 그러면 **같은 `copy_editor_selection` 명령이 뷰에 따라 다른 바이트를 낸다** — DSEL2가 빈 줄
// 처리를 두고 이미 못박은 규율("같은 명령이 뷰에 따라 다르게 동작하면 안 된다")과 같은 자리다.
test "DSEL5: 비교 뷰 복사가 CRLF를 LF로 뭉개지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // CRLF 문서. 가운데 줄이 한쪽에만 있어 반대쪽에 짝맞춤 빈 행이 생긴다.
    var entry = testEntry("keep\r\ntail\r\n", "keep\r\nadded\r\ntail\r\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn.dl.deinit(allocator);

    // **편집기 Term을 활성으로 세운다** — `copyDiffSelection`이 `activeTerm()`으로 대상을 고른다
    // (제품 경로와 같다). Fixture는 추가만 하고 활성을 안 바꾼다.
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, i| {
        if (t == fx.term) pane.active_term = i;
    }

    // ⑴ **여러 줄을 걸쳐 복사하면 CRLF가 그대로 나간다.** 오른쪽 열의 세 줄 전부.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = .{
        .anchor_start = .{ .row = 0, .byte = 0 },
        .anchor_end = .{ .row = 0, .byte = 0 },
        .focus = .{ .row = 2, .byte = 4 },
    } };
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("keep\r\nadded\r\ntail", fx.session.chrome_clipboard_write);

    // ⑵ **왼쪽 열은 짝맞춤 빈 행을 건너뛰고도 CRLF를 지킨다.** 빈 행 자리에 줄이 없으므로
    //    `keep`과 `tail`이 이어지는데, 그 사이 분리자도 원본 줄 끝이어야 한다.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = .{
        .anchor_start = .{ .row = 0, .byte = 0 },
        .anchor_end = .{ .row = 0, .byte = 0 },
        .focus = .{ .row = 2, .byte = 4 },
    } };
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("keep\r\ntail", fx.session.chrome_clipboard_write);

    // ⑶ **짝맞춤 빈 행만 고르면 복사할 것이 없다.** 왼쪽 열의 행 1은 오른쪽의 `added`에 맞춰 넣은
    //    빈 행이라 그 자리에 줄이 **없다** — 개행을 내면 원본에 없던 빈 줄이 붙는다.
    //
    //    **이 단언이 filler 축을 지킨다.** 복사 루프가 `endings[i] == null`로 그 행을 거르는데,
    //    filler를 "빈 줄 끝을 가진 진짜 줄"로 취급해도 **이어 붙인 바이트는 똑같다**(filler는
    //    아무것도 안 붙이고 다음 줄 앞에 `""`를 붙일 뿐이다). 그래서 exact-string 단언들은 그
    //    축을 못 잡는다 — 갈리는 것은 **filler만 고른 선택의 반환값**뿐이고 그것이 여기다.
    //    (적대적 검증 2026-08-22: 이 자리가 없으면 `orelse continue` → `orelse ""` 뮤턴트가 산다.)
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = .{
        .anchor_start = .{ .row = 1, .byte = 0 },
        .anchor_end = .{ .row = 1, .byte = 0 },
        .focus = .{ .row = 1, .byte = 1 },
    } };
    try testing.expect(!editor_ops.copyDiffSelection(fx.session));

    // ⑷ **LF 문서는 LF 그대로다** — ⑴이 "항상 CRLF를 붙인다"가 아니다.
    var lf_entry = testEntry("keep\ntail\n", "keep\nadded\ntail\n");
    fx.term.file_entry = &lf_entry;
    invalidate(fx.session, fx.term);
    poll(fx.session, fx.term);
    var drawn2 = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn2.dl.deinit(allocator);
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = .{
        .anchor_start = .{ .row = 0, .byte = 0 },
        .anchor_end = .{ .row = 0, .byte = 0 },
        .focus = .{ .row = 2, .byte = 4 },
    } };
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("keep\nadded\ntail", fx.session.chrome_clipboard_write);

    // ⑸ **불변식이 깨지면 복사를 거절한다.** 길이가 같다는 것은 타입이 아니라 `materialize`가
    //    지키는 것이라, 어긋난 상태를 손으로 만들어 그 거절을 잰다 — 이 자리가 없으면 그 분기는
    //    제품 경로로 도달 불가라 아무도 재지 않는다(적대적 검증 2026-08-22가 `@panic`을 넣어도
    //    34/34가 통과하는 것을 실측했다). **틀린 바이트를 내느니 안 내는 편이 낫다.**
    {
        // **`st`가 아니라 지금 값을 읽는다** — `st`는 함수 앞에서 값 복사된 스냅숏이고, ⑷가
        // 재계산하며 그 배열은 이미 풀렸다. 그것을 되돌려 놓으면 다음 `invalidate`가 **두 번**
        // 푼다(실측: `Double free detected`).
        const live = &fx.term.rt.editor_diff.?;
        const saved = live.left_endings;
        defer live.left_endings = saved;
        live.left_endings = saved[0 .. saved.len - 1];
        fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = .{
            .anchor_start = .{ .row = 0, .byte = 0 },
            .anchor_end = .{ .row = 0, .byte = 0 },
            .focus = .{ .row = 1, .byte = 1 },
        } };
        try testing.expect(!editor_ops.copyDiffSelection(fx.session));
    }

    // ⑹ **끝 개행은 안 붙는다** — 지금 동작을 눈에 보이게 남긴다(§4.1g "아직 없는 것").
    //    `splitLines`는 마지막 줄 끝 뒤에 줄을 만들지 않는데 단일 편집기의 `line_index`는 빈 줄을
    //    하나 더 두므로(그 자리에 caret이 설 수 있어야 한다), 본문 끝까지 고르면 단일 쪽에만 그
    //    개행이 들어온다. **줄 배열의 정의가 갈린 결과**라 복사 쪽만 고쳐서는 안 닫힌다.
    //    (여기 클립보드는 ⑷가 남긴 **LF 문서**의 것이다 — CRLF로 재면 `keep\r\ntail\r\n` 12바이트
    //    vs `keep\r\ntail` 10이고, 축은 같다.)
    //
    //    **판정은 위 exact-string이 이미 한다** — 이 줄은 그것에 포섭된다(적대적 검증 2026-08-22가
    //    **이 단언만** 지우고 같은 뮤턴트를 넣어 ⑴이 잡는 것을 실측했다). 갈림을 **양쪽에서** 재려면
    //    `copySelection`을 같은 문서·같은 범위로 함께 불러 대조해야 하는데, 그러려면 단일 편집기
    //    Term이 필요해 이 픽스처 밖이다. 그 판정자는 갈림을 닫는 슬라이스가 함께 만든다.
    try testing.expect(!std.mem.endsWith(u8, fx.session.chrome_clipboard_write, "\n"));
}

// DSEL4: **더블·트리플 클릭 뒤 뒤로 끌어도 잡은 단위가 남는다.**
//
// 단일 편집기의 SEL4와 같은 계약인데 비교 뷰가 **점 anchor**로 따로 서 있어 갈렸다 — `"beta"`를
// 잡고 왼쪽으로 끌면 `"pha "`가 남았다(적대적 검증이 제품 경로로 재현). anchor를 범위로 만들고
// `kind`를 실은 뒤에도 그 갈림이 안 돌아오는지 **복사 결과**로 잰다(내부 필드가 아니라 사용자가
// 얻는 것으로 재야 한다).
test "DSEL4: 비교 뷰도 더블클릭 뒤 뒤로 끌면 잡은 단어가 안 잘린다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var entry = testEntry("alpha beta gamma\n", "alpha beta gamma\nx\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn.dl.deinit(allocator);

    const g = fx.term.rt.editor_diff_hit_geom;
    const y0: f64 = @floatFromInt(g.body_y + 1);
    const cw: i32 = @intCast(g.cell_w_px);
    const col_x = struct {
        fn at(geom: anytype, w: i32, col: i32) f64 {
            return @floatFromInt(geom.left_x + @as(i32, @intCast(geom.content_left_px)) + w * col + 1);
        }
    }.at;
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, i| {
        if (t == fx.term) pane.active_term = i;
    }

    // ⑴ `beta`(byte 6..10)를 더블클릭 — 그 단어만 잡힌다.
    //    **제품 진입점을 탄다**(`selectWordOrLineAt`) — 그래야 "비교 뷰로 갈리는가"까지 함께 잰다.
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, false, col_x(g, cw, 7), y0, 0));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("beta", fx.session.chrome_clipboard_write);

    // ⑵ **뒤로** 끌어 `alpha` 안(byte 2)으로 — `beta`의 끝이 남아 `alpha beta`가 된다.
    //    점 anchor였다면 `pha `만 남는다(그 회귀가 이 단언에서 죽는다).
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, col_x(g, cw, 2), y0));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("alpha beta", fx.session.chrome_clipboard_write);

    // ⑶ **앞으로** 끌어 `gamma` 안(byte 13)으로 — 지나가는 단어가 통째로 들어와 `beta gamma`다.
    //    `kind`가 없으면 글자 단위로 늘어 `beta ga`가 된다.
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, col_x(g, cw, 13), y0));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("beta gamma", fx.session.chrome_clipboard_write);
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 3, col_x(g, cw, 13), y0));

    // ⑷ **트리플클릭은 줄 단위**다 — 뒤로 끌어도 줄 전체가 남는다.
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, true, col_x(g, cw, 7), y0, 0));
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, col_x(g, cw, 2), y0));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("alpha beta gamma", fx.session.chrome_clipboard_write);
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 3, col_x(g, cw, 2), y0));

    // ⑸ **`⌥` 를 껴도 비교 뷰 갈래로 간다**(§3.2d). 비교 뷰에는 멀티 커서가 없으므로
    //    (`editor_diff_selection` 이 **단수**다) `⌥` 가 답을 바꿀 것이 없다 — 그런데 위 넷이 전부
    //    `mods = 0` 으로 부르는 탓에, `⌥` 에서만 이 갈래를 건너뛰어 **단일 편집기 경로로 떨어지는**
    //    변이가 살아남았다(§3.2d 슬라이스 4회차 `R24`). 그러면 비교 뷰 클릭이 뒤에 있는 문서에
    //    선택을 세운다.
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, false, col_x(g, cw, 7), y0, 8));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("beta", fx.session.chrome_clipboard_write);
}

test "DSEL2 비교 뷰 선택: 한 열에 머물고, 빈 행은 복사에서 빠진다 (§4.1g 비교 뷰)" {
    // **좌우를 걸치는 선택은 만들지 않는다**(계약). 두 파일의 조각을 이어 붙인 텍스트는 어느 쪽
    // 파일에도 없던 것이다. 그리고 **짝맞춤 빈 행은 복사에서 빠진다** — 그 자리에 줄이 없으므로
    // 개행을 내면 원본에 없던 빈 줄이 붙는다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 가운데 줄이 한쪽에만 있다 → 반대쪽에 짝맞춤 빈 행이 생긴다.
    var entry = testEntry("keep\ntail\n", "keep\nadded\ntail\n");
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    const st = fx.term.rt.editor_diff.?;
    try testing.expectEqual(std.meta.activeTag(st.view), .compare);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn.dl.deinit(allocator);

    const g = fx.term.rt.editor_diff_hit_geom;
    const y0: f64 = @floatFromInt(g.body_y + 1);
    const left_x: f64 = @floatFromInt(g.left_x + @as(i32, @intCast(g.content_left_px)) + 1);
    const right_x: f64 = @floatFromInt(g.right_x + @as(i32, @intCast(g.content_left_px)) + 1);
    const pane = pane_ops.activePane(fx.session);
    // **편집기 Term을 활성으로 세운다** — Fixture는 추가만 하고 활성을 안 바꾼다. 배선 함수들이
    // `pane.activeTerm()`으로 대상을 고르므로(제품 경로와 같다) 이것이 없으면 터미널을 본다.
    for (pane.terms.items, 0..) |t, i| {
        if (t == fx.term) pane.active_term = i;
    }
    try testing.expectEqual(fx.term, pane.activeTerm());

    // ⑴ **왼쪽 열을 눌러 선택을 연다.**
    try testing.expect(editor_ops.beginDiffBodySelection(fx.session, pane, left_x, y0));
    const s0 = fx.term.rt.editor_diff_selection orelse return error.NoSelection;
    try testing.expectEqual(editor_ops.DiffSide.left, s0.side);
    try testing.expect(s0.sel.isEmpty()); // 클릭만으로는 범위가 없다

    // ⑵ **오른쪽 열로 끌어도 왼쪽에 머문다** — 계약의 핵심.
    const last_y: f64 = @floatFromInt(g.body_y + @as(i32, @intCast(2 * @as(u32, g.cell_h_px))) + 1);
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, right_x, last_y));
    const s1 = fx.term.rt.editor_diff_selection orelse return error.NoSelection;
    try testing.expectEqual(editor_ops.DiffSide.left, s1.side);
    try testing.expect(s1.sel.focus.row > s0.sel.anchorLo().row); // 세로로는 따라갔다

    // ⑶ **선택 띠가 그 열에만 선다.**
    try testing.expect(editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .left) != null);
    try testing.expectEqual(
        @as(?[]const []const chrome_editor.frame.Mark, null),
        editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .right),
    );

    // ⑷ **복사가 빈 행을 건너뛴다.** 왼쪽은 "keep"·(빈 행)·"tail"이므로 빈 줄이 안 낀다.
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("keep\ntail", fx.session.chrome_clipboard_write);

    // ⑸ **뗌이 소유권을 놓는다.**
    try testing.expect(fx.session.pointerGestureIs(.editor_diff_selection_drag));
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 3, right_x, last_y));
    try testing.expect(!fx.session.pointerGestureIs(.editor_diff_selection_drag));

    // ⑹ **오른쪽 열도 같다** — ⑵가 항진명제가 아니라는 대조군.
    try testing.expect(editor_ops.beginDiffBodySelection(fx.session, pane, right_x, y0));
    const s2 = fx.term.rt.editor_diff_selection orelse return error.NoSelection;
    try testing.expectEqual(editor_ops.DiffSide.right, s2.side);
    // **행 끝까지 끈다.** 열 머리에 두면 마지막 행의 byte가 0이라 그 줄이 빈다 — ⑵는 반대 열
    //    좌표가 왼쪽 열로 clamp되면서 우연히 행 끝까지 갔던 것이고, 여기서는 명시해야 한다.
    const right_far_x: f64 = @floatFromInt(g.right_x + @as(i32, @intCast(g.content_left_px)) + @as(i32, @intCast(40 * @as(u32, g.cell_w_px))));
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, right_far_x, last_y));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("keep\nadded\ntail", fx.session.chrome_clipboard_write);
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 3, right_far_x, last_y));
}

test "DSEL3 그려진 것이 곧 클릭이 답한 것이다 — 스크롤·열별 가로 위치 (§4.1g 비교 뷰)" {
    // **DSEL1·DSEL2는 자기 자신하고만 대조한다.** 클릭 좌표를 굳힌 기하에서 되계산하므로 그 값이
    // 틀려도 답이 자기 정합이다 — 적대적 검증이 뮤턴트 넷으로 그것을 보였다: 행 축을 화면 행으로
    // 바꿔도, gutter 자릿수 출처를 10⁶배 해도, 열 원점을 999px 밀어도, 좌우 저장소를 뒤바꿔도
    // 열넷이 전부 통과했다. 이 테스트는 **렌더가 그린 것**을 기준선으로 삼는다(ADV3-A의 비교판).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // 좌우가 갈리는 내용 — 행마다 글자가 달라야 대조가 성립한다.
    var left_buf: std.ArrayList(u8) = .empty;
    defer left_buf.deinit(allocator);
    var right_buf: std.ArrayList(u8) = .empty;
    defer right_buf.deinit(allocator);
    for (0..40) |i| {
        var num: [40]u8 = undefined;
        try left_buf.appendSlice(allocator, std.fmt.bufPrint(&num, "L{d:0>3}aaaaaaaaaaaa\n", .{i}) catch unreachable);
        try right_buf.appendSlice(allocator, std.fmt.bufPrint(&num, "R{d:0>3}bbbbbbbbbbbb\n", .{i}) catch unreachable);
    }
    var entry = testEntry(left_buf.items, right_buf.items);
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);
    try testing.expectEqual(std.meta.activeTag(fx.term.rt.editor_diff.?.view), .compare);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 200 };

    // **랩 켬·끔을 둘 다 돈다.** 랩이 켜지면 한 논리 행이 여러 시각 행이 되고 `v.line`이 그 행들
    // 모두에서 같다 — 그 축을 안 재면 "마지막 시각 행 = 마지막 행"이라는 전제가 판정자에 숨는다
    // (적대적 검증이 지적한 자리다).
    for ([_]bool{ false, true }) |wrap| {
        fx.term.rt.editor_wrap = wrap;
        try runDsel3Pass(fx.session, fx.term, leaf, allocator, wrap);
    }
}

fn runDsel3Pass(
    session: *AppSession,
    term: *Term,
    leaf: maru.session.SplitRect,
    allocator: std.mem.Allocator,
    wrap: bool,
) !void {
    const fx = .{ .session = session, .term = term };

    // **세로로 굴리고 오른쪽 열만 가로로 민다.** 둘 다 축이 하나씩 더 붙는 자리다 —
    // 세로는 `first_line`(그것을 빠뜨려 클릭 7발이 전부 어긋났다), 가로는 열마다 각자다(§3.5).
    fx.term.rt.editor_first_line = 0; // 각 회차를 같은 자리에서 시작한다
    _ = editor_ops.scrollLines(fx.session, fx.term, leaf, -7);
    // 랩이면 가로 축이 없다(`effectiveFirstCol`) — 그때는 밀어도 그림이 같다.
    fx.term.rt.editor_first_col_right = 4;

    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    defer drawn.dl.deinit(allocator);
    try testing.expect(fx.term.rt.editor_first_line > 0); // 전제: 실제로 굴렀다
    const st_check = fx.term.rt.editor_diff.?;
    _ = st_check;

    const g = fx.term.rt.editor_diff_hit_geom;
    const st = fx.term.rt.editor_diff.?;

    // **그려진 글자를 기준선으로 삼는다.** 각 셀의 codepoint가 그 자리에서 클릭이 답한 byte의
    // 글자와 같아야 한다 — 스냅숏이 렌더와 갈리면 여기서 갈린다.
    var judged: usize = 0;
    var bad: usize = 0;
    for (drawn.dl.cells) |c| {
        if (c.codepoint == ' ' or c.codepoint == 0) continue;
        const cx: f64 = @floatFromInt(@as(i32, @intCast(drawn.rect.x)) + @as(i32, @intCast(c.col)) * @as(i32, @intCast(g.cell_w_px)) + 1);
        const cy: f64 = @floatFromInt(@as(i32, @intCast(drawn.rect.y)) + @as(i32, @intCast(c.row)) * @as(i32, @intCast(g.cell_h_px)) + 1);
        const hit = editor_ops.hitTestDiffBody(fx.term, cx, cy, null) orelse continue;
        const texts = if (hit.side == .right) st.right_texts else st.left_texts;
        if (hit.row >= texts.len) continue;
        const text = texts[hit.row];
        if (hit.byte >= text.len) continue;
        judged += 1;
        if (text[hit.byte] != c.codepoint) {
            if (bad == 0) std.debug.print(
                "\n[DSEL3] 어긋남 row={d} col={d} 그린='{u}' 답한='{c}' side={s} hit.row={d} byte={d}\n",
                .{ c.row, c.col, c.codepoint, text[hit.byte], @tagName(hit.side), hit.row, hit.byte },
            );
            bad += 1;
        }
    }
    std.debug.print("[DSEL3] wrap={} first_line={d} judged={d} bad={d}\n", .{ wrap, fx.term.rt.editor_first_line, judged, bad });
    try testing.expect(judged >= 40); // 판정할 것이 실제로 있다
    try testing.expectEqual(@as(usize, 0), bad);
}

test "DSEL4 선택을 든 채 문서가 짧아져도 죽지 않는다 (§4.1g 비교 뷰)" {
    // **다음 프레임이 앱을 죽였다.** 옛 선택의 행 인덱스가 새 배열 밖이면 `for (lo..hi)`가
    // `integer overflow`로 패닉한다 — `buildDiffSelectionMarks`는 매 프레임 불리므로 abort다.
    // 제품 경로가 실재한다: 파일 감시가 `requestDiffContent`를 걸면 그 tick에 다시 계산된다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var long_buf: std.ArrayList(u8) = .empty;
    defer long_buf.deinit(allocator);
    for (0..40) |i| {
        var num: [24]u8 = undefined;
        try long_buf.appendSlice(allocator, std.fmt.bufPrint(&num, "line{d}\n", .{i}) catch unreachable);
    }
    var entry = testEntry(long_buf.items, long_buf.items);
    fx.term.file_entry = &entry;
    poll(fx.session, fx.term);

    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    var d0 = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    d0.dl.deinit(allocator);

    // 뒤쪽 행을 고른다.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = .{
        .anchor_start = .{ .row = 30, .byte = 0 },
        .anchor_end = .{ .row = 30, .byte = 0 },
        .focus = .{ .row = 35, .byte = 3 },
    } };

    // **짧은 내용으로 다시 계산한다** — 파일 감시가 하는 일과 같다.
    entry.diff_ready = false;
    entry.diff_original = @constCast("only\n");
    entry.diff_modified = @constCast("only\n");
    poll(fx.session, fx.term); // invalidate → 재계산
    entry.diff_ready = true;
    poll(fx.session, fx.term);

    // ⑴ **선택이 버려졌다** — 옛 행을 가리키는 채로 두면 다음 프레임이 죽는다.
    try testing.expectEqual(@as(?@TypeOf(fx.term.rt.editor_diff_selection.?), null), fx.term.rt.editor_diff_selection);

    // ⑵ **그려도 안 죽는다.**
    var d1 = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    d1.dl.deinit(allocator);

    // ⑶ **선택이 남아 있어도 안 죽는다**(방어 가드) — invalidate를 못 타는 경로가 뒷날 생겨도.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = .{
        .anchor_start = .{ .row = 30, .byte = 0 },
        .anchor_end = .{ .row = 30, .byte = 0 },
        .focus = .{ .row = 35, .byte = 3 },
    } };
    var d2 = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    d2.dl.deinit(allocator);
    try testing.expect(!editor_ops.copyDiffSelection(fx.session)); // 복사도 안 죽는다
    fx.term.rt.editor_diff_selection = null;
}

// ── DCARET: 비교 뷰 caret ──────────────────────────────────────────────────────
//
// 계약은 [키 입력과 단축키](../../../../docs/key-input-and-shortcuts.md) 「비교 뷰에 caret 을
// 세운다」가 소유한다. **판정자 하나는 제품 입구(`handleKeyEvent`)로 들어간다** — resolver·ops 를
// 직접 부르는 판정자만 있으면 그 위 층이 키를 가로채도 전부 초록이다(⌘D·⌥⌘↑↓ 가 그렇게 죽어
// 있었다).

/// 비교 Term 을 세우고 **활성으로** 만든다 — 제품 경로가 `activeTerm()` 으로 대상을 고른다.
fn diffCaretFixture(fx: *Fixture, entry: *dock_panel.Entry, leaf: maru.session.SplitRect) !void {
    fx.term.file_entry = entry;
    poll(fx.session, fx.term);
    if (std.meta.activeTag(fx.term.rt.editor_diff.?.view) != .compare) return error.NotCompare;
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, i| {
        if (t == fx.term) pane.active_term = i;
    }
    fx.session.surface_initialized = true;
    // **렌더가 굳힌 행 수를 세운다** — `diffPageRows` 가 그 값을 읽고, 안 그리면 1 로 떨어져
    // PageDown 이 한 행만 간다(그 자체는 계약이지만 판정이 그 갈래에 갇힌다).
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    drawn.dl.deinit(testing.allocator);
}

test "DCARET1: 비교 뷰를 세우면 caret 이 오른쪽 (0,0) 에 선다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("a\nb\nc\n", "a\nB\nc\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const sel = fx.term.rt.editor_diff_selection orelse return error.NoCaret;
    try testing.expectEqual(editor_ops.DiffSide.right, sel.side);
    try testing.expectEqual(@as(usize, 0), sel.sel.focus.row);
    try testing.expectEqual(@as(usize, 0), sel.sel.focus.byte);
    // **빈 선택이다** — caret 뿐이라 그릴 띠가 없다(`buildDiffSelectionMarks` 가 그 상태를 안다).
    try testing.expect(sel.sel.isEmpty());
    try testing.expectEqual(@as(?[]const []const maru.chrome.components.editor_view.frame.Mark, null), editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .right));

    // **검색 기본 열이 오른쪽이 된다** — 계약이 「의도한 변경」으로 적어 둔 부수 결과다.
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term));
}

test "DCARET2: caret 은 활성 열에만 그려진다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **좌우 행 길이를 일부러 갈라 둔다.** 같은 길이면 "자기 열 길이로 자른다"와 "반대 열 길이로
    // 자른다"가 **같은 답**을 내 그 변이가 산다(1회차 C5 가 그렇게 살아남았다).
    var entry = testEntry("alpha\nbb\n", "alpha\nBBBBBBBB\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    // 픽스처가 정말 갈라졌는지 **먼저 확인한다** — 짝맞춤이 달라지면 아래 단언이 뜻을 잃는다.
    try testing.expect(st.left_texts[1].len != st.right_texts[1].len);

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = .{
        .anchor_start = .{ .row = 1, .byte = 2 },
        .anchor_end = .{ .row = 1, .byte = 2 },
        .focus = .{ .row = 1, .byte = 2 },
    } };
    const right = editor_ops.buildDiffCarets(fx.session, fx.term, .right) orelse return error.NoCarets;
    try testing.expectEqual(@as(usize, 1), right[1].len);
    try testing.expectEqual(@as(u32, 2), right[1][0]);
    try testing.expectEqual(@as(usize, 0), right[0].len);
    // **반대 열은 `null`** — 그것이 "이 열에는 커서가 없다"는 뜻이다.
    try testing.expectEqual(@as(?[]const []const u32, null), editor_ops.buildDiffCarets(fx.session, fx.term, .left));

    // **byte 는 그 행 길이로 잘린다 — 그리고 그 길이는 *자기* 열 것이다.**
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = 9999;
    const clamped = editor_ops.buildDiffCarets(fx.session, fx.term, .right) orelse return error.NoCarets;
    try testing.expectEqual(@as(u32, @intCast(st.right_texts[1].len)), clamped[1][0]);

    // **caret 을 옮기면 이전 행이 비워진다.** 행 배열은 프레임마다 재사용하므로 안 비우면 옛 자리에
    // 커서가 하나 더 남는다 — 갓 잡은 배열이 우연히 0이라 그냥은 안 드러난다.
    fx.term.rt.editor_diff_selection.?.sel.focus = .{ .row = 0, .byte = 1 };
    const moved = editor_ops.buildDiffCarets(fx.session, fx.term, .right) orelse return error.NoCarets;
    try testing.expectEqual(@as(usize, 1), moved[0].len);
    try testing.expectEqual(@as(usize, 0), moved[1].len);

    // **행 첨자는 배열 길이 바로 밖에서 이미 거절한다** — 9999 처럼 멀리 두면 느슨한 상한도 통과한다.
    fx.term.rt.editor_diff_selection.?.sel.focus.row = st.right_texts.len;
    try testing.expectEqual(@as(?[]const []const u32, null), editor_ops.buildDiffCarets(fx.session, fx.term, .right));
}

test "DCARET3: 제품 입구에서 화살표가 caret 을 옮긴다 (handleKeyEvent)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    // ⑴ 아래로 한 행.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // ⑵ 오른쪽으로 한 글자.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑶ **행 끝을 넘으면 다음 행 머리로** — 행 경계를 넘는 것이 계약이다.
    _ = try fx.session.handleKeyEvent(.{ .key = .end });
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑶ʹ **거꾸로도 넘는다** — 행 머리에서 `←` 는 앞 행 끝으로 간다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(fx.term.rt.editor_diff.?.right_texts[1].len, fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑷ **⌘↑ 는 맨 위로** — 전에는 이 키가 프롬프트로 튀거나 아무 일도 안 했다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑸ **⌘↓ 는 맨 아래 행 끝으로.**
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down, .modifiers = .{ .command = true } });
    const texts = fx.term.rt.editor_diff.?.right_texts;
    try testing.expectEqual(texts.len - 1, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(texts[texts.len - 1].len, fx.term.rt.editor_diff_selection.?.sel.focus.byte);
}

test "DCARET4: ⇧ 는 anchor 를 두고 focus 만 옮긴다 (선택 확장)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("alpha\nbeta\n", "alpha\nBETA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .shift = true } });
    const sel = fx.term.rt.editor_diff_selection.?.sel;
    try testing.expectEqual(@as(usize, 0), sel.anchor_start.row);
    try testing.expectEqual(@as(usize, 0), sel.anchor_start.byte);
    // **anchor 는 범위다 — 양 끝을 다 봐야 한다.** 끝만 focus 로 끌어오면 마우스로 잡은 낱말
    // 단위가 조용히 사라지는데, 시작만 재면 그 변이가 산다(4회차 C62).
    try testing.expectEqual(@as(usize, 0), sel.anchor_end.row);
    try testing.expectEqual(@as(usize, 0), sel.anchor_end.byte);
    try testing.expectEqual(@as(usize, 1), sel.focus.byte);
    try testing.expect(!sel.isEmpty());
    // **띠가 실제로 그려진다** — 빈 선택이 아니게 됐으므로 표식이 나온다.
    try testing.expect(editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .right) != null);

    // **⇧ 없이 움직이면 접힌다** — anchor 가 따라온다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expect(fx.term.rt.editor_diff_selection.?.sel.isEmpty());
}

test "DCARET5: 세로 이동이 목표 열을 유지한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 가운데 행이 짧다 — 목표 열을 안 들면 내려갔다 올 때 열이 잘린 채로 남는다.
    // **마지막 줄만 다르다** — 같은 파일이면 비교 뷰가 서지 않고, 다른 줄을 앞에 두면 짝맞춤
    // 빈 행이 끼어 앞 세 행의 첨자가 흔들린다.
    var entry = testEntry("aaaaaaaa\nbb\ncccccccc\nsame\n", "aaaaaaaa\nbb\ncccccccc\ndiff\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 6 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // "bb" 끝
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 6), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // 목표 열 복원

    // **가로로 움직이면 목표를 버린다** — 그러지 않으면 다음 ↓ 가 방금 선 자리가 아니라 옛 열로 간다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left });
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up });
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 5), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // **⇧ 로 늘릴 때도 목표 열을 든다.** 확장만 목표를 안 세우면 짧은 행을 지나며 열이 잘리고
    //    돌아오지 않는다 — 확장이 아닌 이동만 재는 판정자로는 안 잡힌다(9회차 C117).
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 6 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down, .modifiers = .{ .shift = true } });
    try testing.expectEqual(@as(usize, 2), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // "bb" 끝
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down, .modifiers = .{ .shift = true } });
    try testing.expectEqual(@as(usize, 6), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // 목표 열 복원
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.anchor_start.row); // anchor 는 그대로
}

test "DCARET6: caret 이 화면 밖으로 나가면 뷰가 따라간다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| {
        w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    }
    const text = buf[0..w];
    // **한 줄을 다르게 둔다** — 같은 파일이면 비교 뷰 자체가 서지 않는다. 마지막 줄이라
    // 앞쪽 행 첨자는 그대로다.
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
    // **caret 여백을 끈다 — 이 판정자의 주제가 아니다.** 여백(기본 5)이 켜져 있으면 여기 단언이
    // 재는 것이 「최소 스크롤」이 아니라 「최소 스크롤 + 여백」이 되어, 두 규칙 중 어느 것이
    // 깨져도 같은 자리에서 실패한다. 여백 자체는 `SOFF1`~`SOFF8` 이 소유한다(§4 「caret 여백」).
    fx.session.loaded_config.config.editor.cursor_surrounding_lines = 0;

    const visible = fx.term.rt.editor_diff_hit_len_right;
    try testing.expect(visible > 1); // 판정이 성립할 만큼은 그렸다

    // 보이는 마지막 행까지는 안 굴린다.
    for (0..visible - 1) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
    // 한 행 더 내려가면 한 행 굴린다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_first_line);

    // **⌘↑ 로 돌아오면 위로 따라온다.**
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
}

test "DCARET6b: 비교 뷰 세로도 caret 여백을 쓴다 — 좌우가 함께 구른다 (제품 경계)" {
    // **DCARET6 은 여백을 끄고 「최소 스크롤」만 잰다** — 그래서 비교 뷰가 여백을 통째로 무시해도
    // 초록이었다(적대적 검증 1회차 M11 이 살아남아 그 구멍을 가리켰다). 계약은 세로에서 두 뷰가
    // **같은 값**을 쓴다고 적는다(§4 「caret 여백」) — 비교 뷰는 좌우가 함께 구르므로 축이 하나다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| {
        w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    }
    const text = buf[0..w];
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);
    const visible = fx.term.rt.editor_diff_hit_len_right;
    const m: usize = fx.session.loaded_config.config.editor.cursor_surrounding_lines;
    // **픽스처가 두 뜻을 갈라야 한다** — 화면이 여백의 두 배보다 좁으면 절반 clamp 가 먼저 걸려
    // 「여백이 걸렸다」와 「가운데로 갔다」가 겹친다.
    if (visible <= m * 2 + 2) return error.FixtureViewport;

    // **여백이 딱 맞는 행까지는 안 굴린다** — 마지막 행이 아니라 그보다 `m` 행 위다.
    for (0..visible - 1 - m) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_first_line);

    // **한 행 더 내려가면 굴러간다.** 여백이 없으면 여기서 `m` 번 더 눌러야 움직인다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_first_line);

    // **위쪽도 같은 값을 쓴다.** 아래쪽만 재면 위 가지를 지운 변이가 산다.
    for (0..visible) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    const top = fx.term.rt.editor_first_line;
    if (top < m + 2 or visible < 3 * m + 2) return error.FixtureDidNotScroll;
    // 굴린 직후 caret 은 **아래 여백 자리**(`top + visible - 1 - m`)에 있다. 위 여백이 딱 맞는
    // 자리(`top + m`)까지 올라오려면 그만큼 눌러야 하고, 거기서는 아직 안 구른다.
    for (0..visible - 1 - 2 * m) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up });
    try testing.expectEqual(top, fx.term.rt.editor_first_line); // 아직 여백이 산다
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up });
    try testing.expectEqual(top - 1, fx.term.rt.editor_first_line);

    // **절반 clamp 의 기준은 «지금 그린 행 수» 다.** 고정 수로 묶으면 좁은 비교 뷰에서 여백이
    // 화면을 넘어 caret 이 밖으로 밀린다 — 픽스처의 화면이 늘 넉넉하면 두 답이 같아 변이가
    // 산다(적대적 검증 7회차 T4). 큰 값을 줘 **가운데**가 나오는지로 기준을 잰다.
    fx.session.loaded_config.config.editor.cursor_surrounding_lines = 1000;
    const half = (visible - 1) / 2;
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    // **caret 행은 세지 말고 읽는다.** 여기까지 오는 동안 몇 번을 눌렀는지 다시 세면 그 산수가
    // 판정자의 두 번째 출처가 되고, 실제로 한 번 어긋났다(계산 19 대 실제 16).
    const row = fx.term.rt.editor_diff_selection.?.sel.focus.row;
    try testing.expectEqual((row + 1 + half) -| visible, fx.term.rt.editor_first_line);
}

test "L2C4: 비교 뷰는 줄별 폭 캐시 축이 «성립하지 않는다» — 문서가 둘이다 (제품 경계)" {
    // **캐시의 첨자는 `editor_lines`(문서 하나)다.** 비교 뷰의 상한은 `left_texts`/`right_texts` 에서
    // 나오므로 그 축이 성립하지 않는다. `ensureMaxCols` 는 `editor_diff == null` 을 명시로 확인하는데,
    // **그 가드를 지운 변이는 살아남는다**(적대적 검증 L7) — 비교 뷰에서는 `editor_lines` 가 비어
    // `lineColsFresh` 가 이미 거짓이기 때문이다.
    //
    // **그래서 이 판정자는 가드가 아니라 «그 불변식» 을 못박는다.** 불변식이 깨지는 날(비교 뷰가
    // 문서 줄 배열을 함께 들게 되는 날) 여기가 먼저 울리고, 그때 그 가드가 진짜 일을 하기 시작한다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..40) |i| w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    const text = buf[0..w];
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const term = fx.term;
    const st = term.rt.editor_diff orelse return error.NoDiff;
    if (st.view != .compare) return error.NotCompare;

    // ⑴ **불변식**: 비교 뷰는 문서 줄 배열을 안 든다 — 그래서 캐시 축이 성립할 수 없다.
    try testing.expectEqual(@as(usize, 0), term.rt.editor_lines.len);
    try testing.expectEqual(@as(usize, 0), term.rt.editor_line_cols.len);

    // ⑵ 그리고 상한은 실제 왼쪽 본문에서 나온다 — `line0`~`line39` 라 여섯 열 남짓이다.
    term.rt.editor_max_cols = 0;
    editor_ops.ensureMaxColsForDiff(term);
    try testing.expect(term.rt.editor_max_cols > 0);
    try testing.expect(term.rt.editor_max_cols < 100);
}

test "DCARET7: PageDown 은 렌더가 굳힌 행 수만큼 간다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| {
        w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    }
    const text = buf[0..w];
    // **한 줄을 다르게 둔다** — 같은 파일이면 비교 뷰 자체가 서지 않는다. 마지막 줄이라
    // 앞쪽 행 첨자는 그대로다.
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const rows = fx.term.rt.editor_diff_hit_len_right;
    try testing.expect(rows > 1);
    _ = try fx.session.handleKeyEvent(.{ .key = .page_down });
    try testing.expectEqual(rows, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    _ = try fx.session.handleKeyEvent(.{ .key = .page_up });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);
}

test "DCARET8: caret 이 생겨도 비교 뷰는 읽기 전용이다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("alpha\n", "ALPHA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const before = fx.term.rt.editor_diff.?.right_texts[0];
    try testing.expect(!editor_ops.insertText(fx.session, fx.term, "x"));
    try testing.expectEqualStrings(before, fx.term.rt.editor_diff.?.right_texts[0]);

    // **단일 편집기 쪽 이동도 여전히 거절한다** — 심층 방어를 이 조각이 걷어내지 않았다.
    try testing.expect(!editor_ops.moveCarets(fx.session, fx.term, .line_down, false));
}

/// caret 이 없는 프레임과 **차이**를 낸다 — 모양으로 고르지 않는다. 막대 caret 은 2×셀높이인데
/// 그 모양을 가진 quad 가 이 화면에 셋 더 있어(테두리·띠) 모양만 보면 못 가른다.
const QuadKey = struct { x: f32, y: f32, w: f32, h: f32 };

fn snapshotQuads(allocator: std.mem.Allocator, self: *AppSession) ![]QuadKey {
    const out = try allocator.alloc(QuadKey, self.gpu_quads.items.len);
    for (self.gpu_quads.items, 0..) |q, i| out[i] = .{ .x = q.x, .y = q.y, .w = q.w, .h = q.h };
    return out;
}

/// 기준에 없던 quad 들. 기준에 같은 값이 있으면 **하나씩 소비한다**(같은 사각이 여럿일 수 있다).
fn extraQuads(allocator: std.mem.Allocator, base: []const QuadKey, self: *AppSession) ![]QuadKey {
    const used = try allocator.alloc(bool, base.len);
    defer allocator.free(used);
    @memset(used, false);
    var list: std.ArrayList(QuadKey) = .empty;
    errdefer list.deinit(allocator);
    for (self.gpu_quads.items) |q| {
        const k: QuadKey = .{ .x = q.x, .y = q.y, .w = q.w, .h = q.h };
        var matched = false;
        for (base, 0..) |b, i| {
            if (used[i]) continue;
            if (b.x == k.x and b.y == k.y and b.w == k.w and b.h == k.h) {
                used[i] = true;
                matched = true;
                break;
            }
        }
        if (!matched) try list.append(allocator, k);
    }
    return list.toOwnedSlice(allocator);
}

fn drawOnce(fx: *Fixture, leaf: maru.session.SplitRect) !void {
    fx.session.gpu_quads.clearRetainingCapacity();
    var d = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.NoDraw;
    d.dl.deinit(testing.allocator);
}

test "DCARET9: 그려진 caret 이 활성 열에 하나 선다 — 렌더 배선 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    var entry = testEntry("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n");
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);

    // **`buildDiffCarets` 를 직접 부르는 판정자만으로는 배선이 안 잡힌다** — 좌우를 맞바꾸거나
    // 아예 안 넘겨도(`Side.carets = null`) 그 함수는 여전히 옳은 답을 낸다. 1회차에서 그 변이
    // 셋(C9·C10·C11)이 전부 살아남았고, 이 판정자가 그 구멍이다.
    fx.session.blink_visible = true;
    fx.term.rt.editor_diff_selection = null;
    try drawOnce(&fx, leaf);
    const base = try snapshotQuads(allocator, fx.session);
    defer allocator.free(base);

    // ⑴ caret 은 오른쪽 열에 **하나** 는다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 2 }) };
    try drawOnce(&fx, leaf);
    const right = try extraQuads(allocator, base, fx.session);
    defer allocator.free(right);
    try testing.expectEqual(@as(usize, 1), right.len);

    // ⑵ 왼쪽 열로 옮기면 **그 자리가 왼쪽으로** 간다 — 좌우를 맞바꾼 배선이면 여기서 갈린다.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 2 }) };
    try drawOnce(&fx, leaf);
    const left = try extraQuads(allocator, base, fx.session);
    defer allocator.free(left);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expect(left[0].x < right[0].x);
    // 같은 행이므로 높이는 같다 — 자리만 갈린다.
    try testing.expectEqual(right[0].y, left[0].y);

    // ⑶ **깜빡임이 꺼진 순간에는 안 그린다** — `caret_visible` 배선이 죽으면 늘 켜진 커서가 된다.
    fx.session.blink_visible = false;
    try drawOnce(&fx, leaf);
    const blinked = try extraQuads(allocator, base, fx.session);
    defer allocator.free(blinked);
    try testing.expectEqual(@as(usize, 0), blinked.len);
}

test "DCARET10: 한 화면의 크기는 그 열이 그린 행 수다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    const text = buf[0..w];
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    // ⑴ **자기 열이 그린 행 수를 쓴다.** 랩이 꺼진 화면에서는 좌우가 같은 수라 그냥은 안 갈린다
    //    — 값을 **일부러 갈라** 두고 활성 열 것을 따라가는지 본다(1회차 C28 이 그래서 살았다).
    fx.term.rt.editor_diff_hit_len_right = 7;
    fx.term.rt.editor_diff_hit_len_left = 3;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .page_down, false));
    try testing.expectEqual(@as(usize, 7), fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // ⑵ 왼쪽 열이면 왼쪽 수를 쓴다.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .page_down, false));
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    // **열은 이동이 바꾸지 않는다.** 클릭으로 왼쪽을 고른 사용자가 키를 누르면 오른쪽으로 튀는
    //    변이(8회차 C109)는 행 번호만 재는 판정자로는 안 잡힌다 — 두 열의 행 수를 갈라 놨으니
    //    번호는 이미 갈리지만, 열 자체를 단언해야 그 뜻이 분명하다.
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .char_right, false));
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);

    // ⑶ **한 프레임도 안 그렸으면 한 행이다 — 죽은 키가 되지 않는다.** 편집 직후 이 값이 0으로
    //    비워지고 다음 프레임이 다시 채우는데, 그 사이에 PageDown 이 오면 0행 이동이 된다.
    fx.term.rt.editor_diff_hit_len_right = 0;
    fx.term.rt.editor_diff_hit_len_left = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .page_down, false));
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.row);
}

test "DCARET11: 행 안 이동은 낱말·첫 글자·행 끝을 안다 — 그리고 그 행은 자기 열 것이다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **좌우를 갈라 둔다.** 두 열의 행이 같은 모양이면 "자기 열을 읽는다"와 "반대 열을 읽는다"가
    // 같은 답을 내 그 변이가 산다(2회차 C41). 들여쓰기와 낱말 둘도 여기서 갈린다.
    var entry = testEntry("alpha\n  x\n", "alpha\n    beta gamma\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    try testing.expect(st.left_texts[1].len != st.right_texts[1].len); // 픽스처 자기 검증

    const row1 = st.right_texts[1]; // "    beta gamma"
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 0 }) };

    // ⑴ **행 끝은 자기 열의 행 끝이다** — 반대 열을 읽으면 훨씬 짧은 자리에 선다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .command = true } });
    try testing.expectEqual(row1.len, fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑵ **smart home** — 첫 글자와 행 머리를 오간다. 늘 0 으로 가면 여기서 갈린다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 4), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // "    " 뒤
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑶ **낱말 이동은 한 글자가 아니다.** 규칙은 `motion.wordRight` 가 소유한다 — 낱말을 먼저
    //    지나고 공백을 건너뛴다. 행 머리(공백 넷) 에서는 그 공백을 지나 첫 낱말 머리에 선다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .option = true } });
    const w1 = fx.term.rt.editor_diff_selection.?.sel.focus.byte;
    try testing.expect(w1 > 1); // 글자 하나였다면 1 이다
    try testing.expectEqual(@as(usize, 4), w1); // "    " 를 지난 자리

    // 한 번 더 누르면 "beta" 를 지나 공백까지 건너뛴다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .option = true } });
    try testing.expectEqual(@as(usize, 9), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑷ **거꾸로도 낱말이다** — 공백을 먼저 건너뛰고 낱말을 지난다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .option = true } });
    try testing.expectEqual(@as(usize, 4), fx.term.rt.editor_diff_selection.?.sel.focus.byte); // "beta" 머리
}

test "DCARET12: 옮기면 다시 그린다 — 그리고 범위 밖 자리에서도 안 죽는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("alpha\nbeta\n", "alpha\nBETA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;

    // ⑴ **옮기면 다시 그린다.** 안 세우면 caret 이 옮겨져도 화면은 그대로다 — 다른 무엇이 화면을
    //    더럽힐 때까지 커서가 옛 자리에 남는다.
    fx.session.metal_dirty = false;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_down, false));
    try testing.expect(fx.session.metal_dirty);

    // ⑵ **범위 밖 자리에서 시작해도 안 죽고, 배열 안으로 들어온다.** 비교 내용이 다시 계산되면
    //    행 배열이 짧아질 수 있는데(실측으로 선택을 든 채 40행 → 1행에서 죽은 적이 있다),
    //    그 사이에 키가 오면 여기가 첫 소비처다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 9999, .byte = 9999 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .char_right, false));
    const f = fx.term.rt.editor_diff_selection.?.sel.focus;
    try testing.expect(f.row < st.right_texts.len);
    try testing.expect(f.byte <= st.right_texts[f.row].len);

    // ⑶ **caret 이 없으면 만들지 않는다.** 이동이 스스로 커서를 세우면 씨앗이 두 출처가 되고,
    //    비교가 아직 안 선 프레임에서 키 하나로 커서가 생긴다.
    fx.term.rt.editor_diff_selection = null;
    try testing.expect(!editor_ops.diffMove(fx.session, fx.term, .line_down, false));
    try testing.expect(fx.term.rt.editor_diff_selection == null);

    // ⑷ **비교가 아니면 받지 않는다.** view 를 바꾼 채 끝나면 `release` 가 compare 자원을 안 놓아
    //    누수가 나므로(DSEL4 와 같은 규율) 반드시 되돌린다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    const saved_view = fx.term.rt.editor_diff.?.view;
    fx.term.rt.editor_diff.?.view = .loading;
    try testing.expect(!editor_ops.diffMove(fx.session, fx.term, .line_down, false));
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    fx.term.rt.editor_diff.?.view = saved_view;
}

test "DCARET13: 왼쪽이 빈 새 파일에서도 caret 이 선다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **새로 추가된 파일은 HEAD 판이 없다** — 왼쪽 배열이 빈다. 씨앗을 왼쪽 길이로 가르면
    // 그 화면에서만 caret 이 안 서고, 두 열이 다 찬 픽스처에서는 안 드러난다(2회차 C46).
    var entry = testEntry("", "added one\nadded two\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    try testing.expect(st.right_texts.len > 0);

    const sel = fx.term.rt.editor_diff_selection orelse return error.NoCaret;
    try testing.expectEqual(editor_ops.DiffSide.right, sel.side);
    try testing.expectEqual(@as(usize, 0), sel.sel.focus.row);
    // 키도 닿는다 — 씨앗만 서고 이동이 안 되면 반쪽이다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // **지워진 파일도 오른쪽 배열이 비지 않는다** — 짝맞춤 빈 행이 들어차므로 좌우 길이가 같다.
    //    그래서 씨앗의 `right_texts.len > 0` 게이트는 **비교가 선 상태에서 늘 참**이고, 그것을
    //    뒤집는 변이(4회차 C52·C46)는 원리상 잡을 수 없다 — 조건부 단언을 두면 한 번도 안 도는
    //    항진 판정자가 된다(실제로 그렇게 썼다가 걷어냈다). 게이트는 방어로 남긴다.
    var gone = testEntry("removed one\nremoved two\n", "");
    fx.term.file_entry = &gone;
    invalidate(fx.session, fx.term);
    poll(fx.session, fx.term);
    const st2 = fx.term.rt.editor_diff.?;
    try testing.expectEqual(st2.left_texts.len, st2.right_texts.len);
    try testing.expect(fx.term.rt.editor_diff_selection != null);
}

test "DCARET14: 문서 끝으로 가도 마지막 화면이 비지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    const text = buf[0..w];
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);

    // **상한은 `scrollLines` 가 쓰는 것과 같아야 한다.** 자동 스크롤이 상한을 안 지키면 끝에서
    // 배경만 남은 화면이 나오고, 사용자는 문서가 끝났는지 뷰가 깨졌는지 알 수 없다.
    const st = fx.term.rt.editor_diff.?;
    const rows = fx.term.rt.editor_diff_hit_len_right;
    try testing.expect(rows > 1);
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down, .modifiers = .{ .command = true } });
    try testing.expectEqual(st.right_texts.len - 1, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    // 맨 위 행 + 보이는 행 수가 문서를 넘지 않는다 — 넘으면 아래가 빈다.
    try testing.expect(fx.term.rt.editor_first_line + rows <= st.right_texts.len);
    // 그리고 caret 은 보인다(맨 아래 행이 화면 안이다).
    try testing.expect(fx.term.rt.editor_first_line <= st.right_texts.len - 1);
}

test "DCARET15: 낡은 스크롤 위치는 이동할 때 상한으로 되돌아온다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (0..200) |i| w += (try std.fmt.bufPrint(buf[w..], "line{d}\n", .{i})).len;
    const text = buf[0..w];
    var tail: [4096]u8 = undefined;
    @memcpy(tail[0..w], text);
    tail[w - 2] = 'X';
    var entry = testEntry(text, tail[0..w]);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const st = fx.term.rt.editor_diff.?;
    const rows = fx.term.rt.editor_diff_hit_len_right;
    try testing.expect(rows > 2);
    const total = st.right_texts.len;
    const max_first = total - rows;

    // **caret 이 화면 안에 있어도 상한은 지킨다.** 두 갈래(위로 나감·아래로 나감) 어느 쪽도 안
    // 걸리는 자리에 caret 을 두면, 남는 일은 상한 clamp 하나다 — 그것이 없으면 낡은 위치가
    // 그대로 남아 마지막 화면 아래가 빈다.
    const stale = max_first + 5;
    fx.term.rt.editor_first_line = stale;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = stale + 1, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .char_right, false));
    try testing.expect(fx.term.rt.editor_first_line <= max_first);
}

/// 그 열의 행 배열에서 내용으로 행을 찾는다 — 짝맞춤 빈 행이 끼면 첨자가 밀리므로 **번호를
/// 손으로 적지 않는다**.
fn rowIndexOf(rows: []const []const u8, want: []const u8) ?usize {
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r, want)) return i;
    }
    return null;
}

test "DCARET16: 목표 열은 byte 가 아니라 **표시 열**이다 — 탭과 CJK (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 탭이 든 행 · 순수 ASCII 행 · CJK 행을 **이웃**으로 둔다. byte 와 열이 갈리는 자리가
    // 그 둘뿐이라, ASCII 만으로 짠 픽스처에서는 목표 열을 byte 로 잡아도 답이 같다(6회차 C74·C75).
    var entry = testEntry(
        "keep\n\tAB\n11111111\n가나\nend\n",
        "keep\n\txy\n12345678\n가나다\nend\n",
    );
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const rows = fx.term.rt.editor_diff.?.right_texts;

    const i_tab = rowIndexOf(rows, "\txy") orelse return error.NoTabRow;
    const i_plain = rowIndexOf(rows, "12345678") orelse return error.NoPlainRow;
    const i_cjk = rowIndexOf(rows, "가나다") orelse return error.NoCjkRow;
    // 이웃이어야 한 번의 `↓`로 건너간다 — 짝맞춤이 끼면 여기서 크게 실패한다.
    try testing.expectEqual(i_tab + 1, i_plain);
    try testing.expectEqual(i_plain + 1, i_cjk);
    try testing.expectEqual(@as(u16, 4), fx.term.rt.editor_tab_width); // 아래 수의 전제

    // ⑴ **탭 뒤 자리는 열이 byte 보다 크다.** "\txy" 의 byte 2 는 탭(4열) + 'x' → 5열.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i_tab, .byte = 2 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(i_plain, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    // 순수 ASCII 행에서는 열 == byte 다 — byte 로 잡았다면 2 였다.
    try testing.expectEqual(@as(usize, 5), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // ⑵ **CJK 는 한 글자가 두 열이고 세 byte 다.** 5열은 '가'(2열) + '나'(2열) 뒤 5열째 —
    //    글자 가운데라 `byteAtPoint` 가 정하는 경계로 떨어진다. byte 로 잡았다면 5 였다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(i_cjk, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    const b = fx.term.rt.editor_diff_selection.?.sel.focus.byte;
    try testing.expect(b == 6 or b == 9); // '다' 앞이거나 뒤 — 어느 쪽이든 byte 5 는 아니다
    try testing.expect(b != 5);

    // ⑶ **되돌아오면 열이 복원된다.**
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up });
    try testing.expectEqual(@as(usize, 5), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
}

test "DCARET17: 가로 이동은 글자 경계다 — byte 하나가 아니다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\n간다\n", "keep\n가나다\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const rows = fx.term.rt.editor_diff.?.right_texts;
    const i = rowIndexOf(rows, "가나다") orelse return error.NoCjkRow;

    // **한 글자가 세 byte 다.** byte 하나씩 움직이면 깨진 UTF-8 자리에 서고, 그 자리를 렌더가
    // 열로 옮기면 화면과 어긋난다(6회차 C77·C78 이 그렇게 살아남았다).
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 0 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expectEqual(@as(usize, 6), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left });
    try testing.expectEqual(@as(usize, 3), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
}

test "DCARET18: 맨 위·맨 아래를 넘지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("a\nb\nc\n", "a\nB\nc\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const total = fx.term.rt.editor_diff.?.right_texts.len;

    // ⑴ **맨 위에서 위로 눌러도 안 넘친다.** 포화 뺄셈이 아니면 여기서 언더플로로 죽는다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_up });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    _ = try fx.session.handleKeyEvent(.{ .key = .page_up });
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // ⑵ **맨 아래에서 아래로 눌러도 안 넘친다.** 상한을 안 걸면 배열 밖 행을 읽는다.
    for (0..total + 3) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(total - 1, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    for (0..3) |_| _ = try fx.session.handleKeyEvent(.{ .key = .page_down });
    try testing.expectEqual(total - 1, fx.term.rt.editor_diff_selection.?.sel.focus.row);
}

test "DCARET19: 비교 갈래가 키를 삼킨다 — 아래로 흘리지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("a\nb\nc\n", "a\nB\nc\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    // **삼키지 않으면 같은 키가 아래 층에서 한 번 더 쓰인다.** caret 은 옮겨졌으니 상태만 보는
    // 판정자는 전부 초록이고(6회차 C81), 갈리는 것은 «앱이 이 키를 처리했다»는 회계뿐이다.
    const before = fx.session.total_app_key_events;
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(before + 1, fx.session.total_app_key_events);

    // **대조군** — 비교 뷰가 안 받는 키는 이 회계를 늘리지 않는다(그 키는 다른 층의 것이다).
    const mid = fx.session.total_app_key_events;
    _ = try fx.session.handleKeyEvent(.{ .key = .backspace });
    try testing.expectEqual(mid, fx.session.total_app_key_events);
}

test "DCARET20: caret 배열을 못 잡으면 안 그린다 — 옛 배열을 쓰지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\nbeta\ngamma\n", "keep\nBETA\ngamma\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 1 }) };
    // 저장소를 비워 **잡는 길**로 들어가게 한다(이미 잡혀 있으면 실패 주입이 뜻이 없다).
    if (fx.term.rt.editor_diff_caret_rows_right.len > 0) testing.allocator.free(fx.term.rt.editor_diff_caret_rows_right);
    fx.term.rt.editor_diff_caret_rows_right = &.{};

    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const saved = fx.session.allocator;
    fx.session.allocator = fa.allocator();
    const got = editor_ops.buildDiffCarets(fx.session, fx.term, .right);
    fx.session.allocator = saved;

    // **못 잡으면 `null`** — 옛(빈) 배열을 그대로 쓰면 길이 0 짜리를 훑어 아무 행에도 커서가 없고,
    // 더 나쁘게는 이미 놓은 배열을 가리킬 수 있다.
    try testing.expectEqual(@as(?[]const []const u32, null), got);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_caret_rows_right.len);
    try testing.expect(fa.has_induced_failure);

    // **그 뒤에도 정상으로 돌아온다** — 한 번의 실패가 상태를 망가뜨리지 않는다.
    const again = editor_ops.buildDiffCarets(fx.session, fx.term, .right) orelse return error.NoCarets;
    try testing.expectEqual(@as(usize, 1), again[1].len);
}

test "DCARET21: 사용자가 옮긴 caret 은 다음 tick 에 안 되돌아온다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("a\nb\nc\nd\n", "a\nB\nc\nd\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    const moved = fx.term.rt.editor_diff_selection.?.sel.focus;
    try testing.expectEqual(@as(usize, 2), moved.row);

    // **씨앗은 비교가 **다시 설 때**만 돈다.** 매 tick 돌면 사용자가 옮긴 caret 이 눈앞에서
    // 맨 위로 튄다 — 상태만 보는 판정자로는 한 번의 `poll` 뒤에도 값이 같아 안 드러난다.
    for (0..5) |_| poll(fx.session, fx.term);
    try testing.expectEqual(moved.row, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(moved.byte, fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // **거꾸로 — 내용이 다시 계산되면 되돌아온다.** 옛 행 첨자를 들고 있으면 안 되기 때문이다.
    invalidate(fx.session, fx.term);
    poll(fx.session, fx.term);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
}

test "DCARET22: ⇧이동이 마우스로 잡은 낱말 단위를 지킨다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\nalpha beta gamma\n", "keep\nalpha BETA gamma\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const rows = fx.term.rt.editor_diff.?.right_texts;
    const i = rowIndexOf(rows, "alpha BETA gamma") orelse return error.NoRow;

    // 마우스로 낱말을 잡은 상태 — anchor 가 **범위**이고 `kind` 가 `.word` 다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.fromAnchorRange(
        .{ .row = i, .byte = 6 },
        .{ .row = i, .byte = 10 },
        .{ .row = i, .byte = 10 },
        .word,
    ) };

    // ⑴ **범위 안에서 당기면 줄어든다.** focus 가 아직 anchor 범위의 시작보다 뒤면 고정단은
    //    그 시작이고, 사용자는 앞으로 뻗은 선택을 되감는 중이다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .shift = true } });
    {
        const sel = fx.term.rt.editor_diff_selection.?.sel;
        try testing.expectEqual(@as(usize, 6), sel.start().byte);
        try testing.expectEqual(@as(usize, 9), sel.end().byte);
    }

    // ⑵ **범위를 넘어 뒤로 가면 잡은 낱말이 통째로 남는다.** 고정단이 anchor 범위의 **끝**으로
    //    바뀐다 — anchor 를 점으로 두면 그 낱말이 사라진다(단일 편집기 §3.2 가 anchor 를 범위로
    //    둔 근거이고, 비교 뷰 쪽은 그것이 없어 더블클릭한 낱말을 잃은 적이 있다).
    for (0..4) |_| _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .shift = true } });
    const sel = fx.term.rt.editor_diff_selection.?.sel;
    try testing.expectEqual(@as(usize, 5), sel.start().byte);
    try testing.expectEqual(@as(usize, 10), sel.end().byte); // 잡은 낱말의 끝이 살아 있다
    try testing.expectEqual(maru.session.editor.selection.AnchorKind.word, sel.kind);

    // ⑶ **⇧ 없이 움직이면 단위가 풀린다** — 새 caret 은 점이다.
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right });
    try testing.expect(fx.term.rt.editor_diff_selection.?.sel.isEmpty());
    try testing.expectEqual(maru.session.editor.selection.AnchorKind.simple, fx.term.rt.editor_diff_selection.?.sel.kind);
}

test "DCARET23: caret 뿐이면 복사할 것이 없고, 검색은 caret 이 선 열에서 시작한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\nbeta\n", "keep\nBETA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    // ⑴ **caret 뿐인 선택은 복사하지 않는다.** 단일 편집기는 선택이 없으면 caret 줄 전체를
    //    담지만(COPY1), 비교 뷰는 그 계약이 없다 — 늘 서 있는 caret 이 줄 복사를 뜻하면
    //    `⌘C` 가 비교 뷰에서만 다른 일을 한다.
    try testing.expect(!editor_ops.copyDiffSelection(fx.session));

    // ⑵ **검색은 caret 이 선 열에서 시작한다.** 씨앗이 오른쪽이므로 기본이 오른쪽이고,
    //    caret 을 왼쪽으로 옮기면 검색도 따라간다.
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term));
    fx.term.rt.editor_diff_selection.?.side = .left;
    try testing.expectEqual(editor_ops.DiffSide.left, editor_ops.diffSearchSide(fx.session, fx.term));

    // ⑶ **명시값은 여전히 이긴다** — 검색 UI 가 열을 고르면 caret 보다 그쪽이 먼저다.
    fx.session.chrome_host.find.diff_side = .right;
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term));
    fx.session.chrome_host.find.diff_side = null;

    // ⑷ **선택이 생기면 복사된다** — ⑴ 이 "늘 false" 가 아니다.
    const rows = fx.term.rt.editor_diff.?.right_texts;
    const i = rowIndexOf(rows, "BETA") orelse return error.NoRow;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 0 }) };
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, k| {
        if (t == fx.term) pane.active_term = k;
    }
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .shift = true } });
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("B", fx.session.chrome_clipboard_write);

    // ⑸ **복사는 caret 이 선 열을 따른다 — 검색 열이 아니다.** 둘이 대개 같아서 검색 열로 골라도
    //    같은 바이트가 나온다(9회차 C122). 명시로 갈라 놓으면 그 갈래가 처음으로 갈린다.
    fx.session.chrome_host.find.diff_side = .left;
    defer fx.session.chrome_host.find.diff_side = null;
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("B", fx.session.chrome_clipboard_write); // 왼쪽이면 "b" 다
}

test "DCARET24: caret 은 **caret 이 선 열**에 그려진다 — 검색 열이 달라도 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    var entry = testEntry("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n");
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);

    fx.session.blink_visible = true;
    fx.term.rt.editor_diff_selection = null;
    try drawOnce(&fx, leaf);
    const base = try snapshotQuads(allocator, fx.session);
    defer allocator.free(base);

    // **caret 열과 검색 열은 다른 값이다.** 대개 같아서(검색 기본이 caret 열이다) 렌더가 검색
    // 열을 봐도 안 드러난다 — 명시로 갈라 놓아야 그 변이(8회차 C111)가 죽는다.
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 2 }) };
    fx.session.chrome_host.find.diff_side = .right;
    defer fx.session.chrome_host.find.diff_side = null;
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term)); // 픽스처 자기 검증
    try drawOnce(&fx, leaf);
    const left_caret = try extraQuads(allocator, base, fx.session);
    defer allocator.free(left_caret);
    try testing.expectEqual(@as(usize, 1), left_caret.len);

    // 오른쪽에 세운 caret 과 견주면 왼쪽이 더 앞이다 — 검색 열(오른쪽)을 따라갔다면 같은 자리다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 2 }) };
    try drawOnce(&fx, leaf);
    const right_caret = try extraQuads(allocator, base, fx.session);
    defer allocator.free(right_caret);
    try testing.expectEqual(@as(usize, 1), right_caret.len);
    try testing.expect(left_caret[0].x < right_caret[0].x);

    // **거울 경우도 재야 한다.** 위 둘은 검색 열이 늘 오른쪽이라, 렌더가 «검색 열일 때만
    //    오른쪽에 그린다»로 바뀌어도 답이 같다(9회차 C111 이 그렇게 살아남았다). 검색을 왼쪽으로
    //    돌리고 caret 을 오른쪽에 두면 그 갈래가 처음으로 갈린다.
    fx.session.chrome_host.find.diff_side = .left;
    try drawOnce(&fx, leaf);
    const mirrored = try extraQuads(allocator, base, fx.session);
    defer allocator.free(mirrored);
    try testing.expectEqual(@as(usize, 1), mirrored.len);
    try testing.expectEqual(right_caret[0].x, mirrored[0].x);
}

// ── DCOL: 비교 뷰 열 넘기기(`⌃⇧Tab`) ─────────────────────────────────────────
//
// 계약은 [키 입력과 단축키](../../../../docs/key-input-and-shortcuts.md) 「비교 뷰의 열을 키로
// 넘긴다」가 소유한다. **판정자 둘이 제품 입구를 지난다** — `handleKeyEvent` 와 렌더.

/// `⌃⇧Tab` 한 번.
fn pressSwitch(fx: *Fixture) !void {
    _ = try fx.session.handleKeyEvent(.{ .key = .tab, .modifiers = .{ .control = true, .shift = true } });
}

test "DCOL1: ⌃⇧Tab 이 열을 넘기고 행은 그대로다 (handleKeyEvent)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_down });
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    const row = fx.term.rt.editor_diff_selection.?.sel.focus.row;

    // ⑴ 오른쪽 → 왼쪽. **행은 그대로다** — 좌우가 짝을 맞춰 정렬돼 있어 같은 첨자가 같은 높이다.
    try pressSwitch(&fx);
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(row, fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // ⑵ 한 번 더 누르면 돌아온다 — 토글이다.
    try pressSwitch(&fx);
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(row, fx.term.rt.editor_diff_selection.?.sel.focus.row);

    // ⑶ **대조군** — `⇧Tab` 만으로는 안 넘어간다(그것은 단일 편집기의 내어쓰기다).
    _ = try fx.session.handleKeyEvent(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    // `⌃Tab` 도 아니다 — macOS 에서 그것은 Switcher 자리다.
    _ = try fx.session.handleKeyEvent(.{ .key = .tab, .modifiers = .{ .control = true } });
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);

    // ⑷ **키를 삼킨다.** 열은 이미 넘어갔으니 상태만 보는 단언은 전부 초록이고, 갈리는 것은
    //    「앱이 이 키를 처리했다」는 회계뿐이다 — 안 삼키면 같은 키가 아래 층에서 한 번 더 쓰인다.
    const before = fx.session.total_app_key_events;
    try pressSwitch(&fx);
    try testing.expectEqual(before + 1, fx.session.total_app_key_events);
    // **대조군** — 비교 갈래가 안 받는 조합은 이 회계를 안 늘린다.
    const mid = fx.session.total_app_key_events;
    _ = try fx.session.handleKeyEvent(.{ .key = .tab, .modifiers = .{ .control = true, .shift = true, .command = true } });
    try testing.expectEqual(mid, fx.session.total_app_key_events);
}

test "DCOL2: 넘어갈 때 **표시 열**을 유지한다 — 탭과 CJK (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 같은 행의 좌우가 **다른 폭 문자**로 시작한다 — byte 를 그대로 옮기면 보이는 자리가 튄다.
    var entry = testEntry("keep\n\tAB\n", "keep\n가나다\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "가나다") orelse return error.NoRow;
    try testing.expectEqualStrings("\tAB", st.left_texts[i]); // 픽스처 자기 검증
    try testing.expectEqual(@as(u16, 4), fx.term.rt.editor_tab_width);

    // 오른쪽 "가나다" 의 byte 6 = '다' 앞 = **4열**(가·나가 각 2열).
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 6 }) };
    try pressSwitch(&fx);
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    // 왼쪽 "\tAB" 에서 4열은 탭(0~3열) 바로 뒤 = **byte 1**. byte 를 그대로 옮겼다면 3(=len)이다.
    try testing.expectEqual(@as(usize, 1), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // 되돌아오면 다시 4열 — 왼쪽 byte 1 은 4열이고, 오른쪽에서 4열은 byte 6 이다.
    try pressSwitch(&fx);
    try testing.expectEqual(@as(usize, 6), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
}

test "DCOL3: 넘어가면 선택이 접힌다 — 좌우를 걸치지 않는다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\nbeta\n", "keep\nBETA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    const rows = fx.term.rt.editor_diff.?.right_texts;
    const i = rowIndexOf(rows, "BETA") orelse return error.NoRow;
    // **마우스로 낱말을 잡은 상태에서 넘긴다.** 넘기기 전이 이미 `.simple` 이면 「단위를 푼다」와
    //    「단위를 들고 간다」가 같은 답을 낸다(19·20회차 U14 가 그래서 살았다).
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.fromAnchorRange(
        .{ .row = i, .byte = 0 },
        .{ .row = i, .byte = 4 },
        .{ .row = i, .byte = 4 },
        .word,
    ) };
    try testing.expectEqual(maru.session.editor.selection.AnchorKind.word, fx.term.rt.editor_diff_selection.?.sel.kind);
    try testing.expect(!fx.term.rt.editor_diff_selection.?.sel.isEmpty()); // 픽스처 자기 검증

    try pressSwitch(&fx);
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expect(fx.term.rt.editor_diff_selection.?.sel.isEmpty());
    // 띠도 사라진다 — 한 열에만 있던 선택이 통째로 접혔다.
    try testing.expectEqual(@as(?[]const []const maru.chrome.components.editor_view.frame.Mark, null), editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .right));
    try testing.expectEqual(@as(?[]const []const maru.chrome.components.editor_view.frame.Mark, null), editor_ops.buildDiffSelectionMarksForTest(fx.session, fx.term, .left));
    // **단위도 풀린다.** `kind` 를 들고 넘어가면 그 뒤의 드래그가 글자가 아니라 낱말로 늘어난다
    //    — `isEmpty()` 는 그대로라 그것만 재는 단언으로는 안 갈린다(18회차 U14).
    try testing.expectEqual(maru.session.editor.selection.AnchorKind.simple, fx.term.rt.editor_diff_selection.?.sel.kind);
    // **목표 열도 안 들고 간다.** 넘어간 caret 은 **새로 선 점**이다 — 옛 목표를 들고 가면 그 뒤의
    //    `↓` 가 방금 선 자리가 아니라 건너오기 전의 열로 간다(19회차 U18).
    try testing.expect(fx.term.rt.editor_diff_selection.?.sel.goal.eql(.none));
}

test "DCOL4: 짝맞춤 빈 행으로도 넘어간다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 오른쪽에만 있는 줄 — 왼쪽 그 자리는 짝맞춤 빈 행이다.
    var entry = testEntry("keep\ntail\n", "keep\nadded\ntail\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "added") orelse return error.NoRow;
    try testing.expectEqual(@as(usize, 0), st.left_texts[i].len); // 그 자리가 빈 행이다

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 3 }) };
    try pressSwitch(&fx);
    // **거절하지 않는다** — 그 빈 행은 화면에 실제로 그려져 있다.
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(i, fx.term.rt.editor_diff_selection.?.sel.focus.row);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.byte);

    // 되돌아오면 그 행의 열 0 이다 — 빈 행에는 들고 갈 열이 없다.
    try pressSwitch(&fx);
    try testing.expectEqual(@as(usize, 0), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
}

test "DCOL5: caret 이 없거나 비교가 아니면 안 넘긴다 (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("keep\nbeta\n", "keep\nBETA\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });

    fx.term.rt.editor_diff_selection = null;
    try testing.expect(!editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expect(fx.term.rt.editor_diff_selection == null);

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 0, .byte = 0 }) };
    const saved_view = fx.term.rt.editor_diff.?.view;
    fx.term.rt.editor_diff.?.view = .loading;
    try testing.expect(!editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    fx.term.rt.editor_diff.?.view = saved_view;

    // **옮기면 다시 그린다** — 안 세우면 caret 이 열을 옮겨도 화면은 그대로다.
    fx.session.metal_dirty = false;
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expect(fx.session.metal_dirty);

    // **범위 밖 자리에서 넘겨도 안 죽고 배열 안으로 들어온다.** 비교가 다시 계산되면 행이 짧아질 수
    //    있는데, 그 사이에 키가 오면 여기가 첫 소비처다. 출발 행 길이로 안 자르면 `columnOf` 가 줄
    //    밖 byte 를 받는다(12회차 S18).
    const st = fx.term.rt.editor_diff.?;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 9999, .byte = 9999 }) };
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    const f = fx.term.rt.editor_diff_selection.?.sel.focus;
    try testing.expect(f.row < st.left_texts.len);
    try testing.expect(f.byte <= st.left_texts[f.row].len);
    // 그리고 **그 행의 끝**에 선다 — 잘린 열이 그 행에서 갈 수 있는 가장 먼 자리다.
    try testing.expectEqual(st.left_texts[f.row].len, f.byte);
}

test "DCOL6: 넘어간 열에 caret 이 그려지고 검색도 따라간다 (렌더 배선)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    var entry = testEntry("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n");
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);

    fx.session.blink_visible = true;
    fx.term.rt.editor_diff_selection = null;
    try drawOnce(&fx, leaf);
    const base = try snapshotQuads(allocator, fx.session);
    defer allocator.free(base);

    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 1, .byte = 2 }) };
    try drawOnce(&fx, leaf);
    const right = try extraQuads(allocator, base, fx.session);
    defer allocator.free(right);
    try testing.expectEqual(@as(usize, 1), right.len);
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term));

    try pressSwitch(&fx);
    try drawOnce(&fx, leaf);
    const left = try extraQuads(allocator, base, fx.session);
    defer allocator.free(left);
    try testing.expectEqual(@as(usize, 1), left.len);
    // **그려진 자리가 왼쪽으로 간다** — 상태만 보면 배선이 죽어도 초록이다.
    try testing.expect(left[0].x < right[0].x);
    // **검색 열도 따라간다** — 명시값이 없으면 caret 열을 본다.
    try testing.expectEqual(editor_ops.DiffSide.left, editor_ops.diffSearchSide(fx.session, fx.term));
}

test "DCOL7: 왕복은 ASCII 에서 제자리이고, 어디서나 **한 번 뒤에는 멈춘다** (§4.1g 비교 뷰)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 탭·CJK·빈 행·긴 행을 섞는다 — 열 산술이 갈리는 자리를 한 판정자가 다 지난다.
    var entry = testEntry("keep\n\tAB\nshort\n\nlonger left line\n", "keep\n가나다\nmuch longer right\nadded\nx\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const n = @min(st.left_texts.len, st.right_texts.len);
    try testing.expect(n >= 3);

    // **한 번 왕복한 뒤에는 멈춘다.** 좌우의 셀 폭이 다르면(탭 4열 · CJK 2열) 반대 열에 **그 열이
    // 없을 수 있고**, 그때 `byteAtPoint` 가 cluster 경계로 스냅한다 — 그래서 첫 왕복은 제자리가 아닐
    // 수 있다(실측: 오른쪽 `"가나다"` byte 3 = 2열 → 왼쪽 `"\tAB"` 에서 2열은 탭 **안**이라 byte 1(4열)
    // 로 스냅 → 돌아오면 byte 6). 지켜야 하는 것은 **그 뒤로는 안 흐른다**는 것이다 — 안 그러면 키를
    // 누를수록 caret 이 계속 밀린다.
    var checked: usize = 0;
    for (0..n) |row| {
        const text = st.right_texts[row];
        var b: usize = 0;
        while (true) {
            fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = row, .byte = b }) };
            for (0..2) |_| try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
            const after_one = fx.term.rt.editor_diff_selection.?.sel.focus;
            try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
            try testing.expectEqual(row, after_one.row);
            for (0..2) |_| try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
            const after_two = fx.term.rt.editor_diff_selection.?.sel.focus;
            try testing.expectEqual(after_one.row, after_two.row);
            try testing.expectEqual(after_one.byte, after_two.byte);
            checked += 1;
            if (b >= text.len) break;
            b = editor_ops.nextCharBoundaryForTest(text, b);
        }
    }
    try testing.expect(checked >= 12); // 공허해질 수 없게 센다

    // **셀 폭이 같으면 첫 왕복부터 제자리다.** 위 완화가 "아무 데서나 밀려도 된다"가 아니다.
    var plain = testEntry("keep\nalpha beta\ntail\n", "keep\nALPHA BETA!\ntail\n");
    fx.term.file_entry = &plain;
    invalidate(fx.session, fx.term);
    poll(fx.session, fx.term);
    const st2 = fx.term.rt.editor_diff.?;
    const plain_row = rowIndexOf(st2.right_texts, "ALPHA BETA!") orelse return error.NoRow;
    for (0..st2.left_texts[plain_row].len + 1) |b2| {
        fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = plain_row, .byte = b2 }) };
        for (0..2) |_| try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
        try testing.expectEqual(b2, fx.term.rt.editor_diff_selection.?.sel.focus.byte);
    }
}

test "DCOL8: 열을 넘기면 검색 목록도 그 열의 것이 된다 (§5.1 비교 뷰 검색)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **찾는 낱말이 좌우에 다른 수만큼 있다** — 같은 수면 목록이 안 바뀐 것을 못 가른다.
    var entry = testEntry("aa\nbb\n", "aa\naa\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, k| {
        if (t == fx.term) pane.active_term = k;
    }

    find_ops.toggleFind(fx.session);
    // **target 은 프레임 루프가 세운다** — 픽스처는 그 자리를 안 지나므로 손으로 세운다
    //    (`editor.zig` 의 기존 검색 판정자와 같은 관례다).
    fx.session.chrome_host.find.target = .editor;
    try fx.session.chrome_host.find.input.query.appendSlice(fx.session.allocator, "aa");
    find_ops.recomputeEditorFindPublic(fx.session, fx.term);

    // 씨앗이 오른쪽이므로 오른쪽에서 찾는다.
    try testing.expectEqual(editor_ops.DiffSide.right, editor_ops.diffSearchSide(fx.session, fx.term));
    const right_count = fx.session.chrome_host.find.match_count;
    try testing.expect(right_count >= 2); // 픽스처 자기 검증 — 오른쪽에 "aa" 가 둘이다

    // **열을 넘기면 목록이 그 열의 것이어야 한다.** §5.1 이 이미 경고한 자리다 — 「셋이 같은 답을
    //    읽는다: 줄 배열·강조·막대 마커. 한 곳에서만 반영하면 **화면은 왼쪽인데 결과는 오른쪽
    //    것**이 된다」. 강조는 live `diffSearchSide` 를 보는데 목록은 캐시라, 다시 세지 않으면
    //    정확히 그 상태가 된다.
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(editor_ops.DiffSide.left, editor_ops.diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.match_count); // 왼쪽에는 하나다

    // **되돌아와도 따라온다** — 한 방향만 고치면 반쪽이다.
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(right_count, fx.session.chrome_host.find.match_count);
}

test "DCOL9: 같은 열을 다시 고르면 검색 자리를 안 잃는다 (§5.1 비교 뷰 검색)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **넘어갈 열에도 매치가 둘 이상이어야 한다.** 한 개뿐이면 `setMatchCount` 의 clamp 가
    //    `current` 를 0 으로 끌어내려, 「첫 매치로 되돌린다」를 지웠는데도 답이 같다(14회차 T6).
    var entry = testEntry("aa\naa\ncc\n", "aa\naa\naa\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, k| {
        if (t == fx.term) pane.active_term = k;
    }

    find_ops.toggleFind(fx.session);
    fx.session.chrome_host.find.target = .editor;
    try fx.session.chrome_host.find.input.query.appendSlice(fx.session.allocator, "aa");
    find_ops.recomputeEditorFindPublic(fx.session, fx.term);
    try testing.expect(fx.session.chrome_host.find.match_count >= 3);

    // 사용자가 두 번째 매치를 보고 있다.
    fx.session.chrome_host.find.current = 1;

    // **같은 열 안에서 caret 을 옮겨도 그 자리를 안 잃는다.** 열이 안 바뀌었으므로 목록도 그대로다
    //    — 클릭마다 다시 세면 `current` 가 0 으로 튀어 보던 매치를 잃는다.
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_down, false));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.current);

    // **열을 넘기면 그때는 첫 매치로 되돌린다** — 목록이 통째로 달라지는 사건이다.
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 0), fx.session.chrome_host.find.current);
    try testing.expectEqual(@as(usize, 2), fx.session.chrome_host.find.match_count);

    // **명시로 고른 열이 있으면 caret 이 옮겨져도 검색은 안 흔들린다.**
    fx.session.chrome_host.find.diff_side = .right;
    find_ops.recomputeEditorFindPublic(fx.session, fx.term);
    fx.session.chrome_host.find.current = 1;
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.current);
    fx.session.chrome_host.find.diff_side = null;
}

test "DCOL10: 마우스로 열을 바꿔도 검색이 따라오고, 검색 대상이 아니면 안 건드린다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("aa\nbb\n", "aa\naa\n");
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, k| {
        if (t == fx.term) pane.active_term = k;
    }

    find_ops.toggleFind(fx.session);
    fx.session.chrome_host.find.target = .editor;
    try fx.session.chrome_host.find.input.query.appendSlice(fx.session.allocator, "aa");
    find_ops.recomputeEditorFindPublic(fx.session, fx.term);
    const right_count = fx.session.chrome_host.find.match_count;
    try testing.expect(right_count >= 2);

    // **마우스도 같은 자리를 지나야 한다.** 열이 바뀌는 길이 셋인데(마우스 둘·`⌃⇧Tab`) 키 경로만
    //    재면 마우스 쪽 배선이 죽어도 초록이다(14회차 T2).
    const g = fx.term.rt.editor_diff_hit_geom;
    try testing.expect(g.right_x > g.left_x); // 픽스처 자기 검증
    const y0: f64 = @floatFromInt(g.body_y + 1);
    const left_x: f64 = @floatFromInt(g.left_x + @as(i32, @intCast(g.content_left_px)) + 1);
    try testing.expect(editor_ops.beginDiffBodySelection(fx.session, pane, left_x, y0));
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.match_count);
    fx.session.clearPointerGesture();

    // **더블클릭도 같은 자리를 지난다.** 열이 바뀌는 마우스 길이 **둘**이라(누름·더블/트리플),
    //    한쪽만 재면 나머지 배선이 죽어도 초록이다(15회차 T2 가 그 자리였다).
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term)); // 오른쪽으로 돌려 놓는다
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(right_count, fx.session.chrome_host.find.match_count);
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, false, left_x, y0, 0));
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.match_count);
    fx.session.clearPointerGesture();

    // **검색 대상이 편집기가 아니면 안 건드린다.** 터미널을 검색하는 중에 비교 뷰를 클릭했다고
    //    편집기 매치를 다시 세면, 사용자가 보던 터미널 검색 결과가 통째로 갈린다.
    fx.session.chrome_host.find.target = .scrollback;
    const before = fx.session.chrome_host.find.match_count;
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(editor_ops.DiffSide.right, fx.term.rt.editor_diff_selection.?.side);
    try testing.expectEqual(before, fx.session.chrome_host.find.match_count);
    fx.session.chrome_host.find.target = .editor;
}

test "DCOL11: 오버레이를 닫아도(⌘G 항해 중) 열을 넘기면 목록이 따라온다 (§5.1)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var entry = testEntry("aa\nbb\n", "aa\naa\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const pane = pane_ops.activePane(fx.session);
    for (pane.terms.items, 0..) |t, k| {
        if (t == fx.term) pane.active_term = k;
    }

    find_ops.toggleFind(fx.session);
    fx.session.chrome_host.find.target = .editor;
    try fx.session.chrome_host.find.input.query.appendSlice(fx.session.allocator, "aa");
    find_ops.recomputeEditorFindPublic(fx.session, fx.term);
    try testing.expect(fx.session.chrome_host.find.match_count >= 2);

    // **오버레이를 닫아도 항해는 살아 있다.** `find_nav` 가 참이면 하이라이트와 `⌘G` 가 그대로
    //    매치 목록을 쓴다 — 그 상태에서 열을 넘기면 같은 어긋남이 난다. 가드를 `find.open` 으로만
    //    쓰면 이 자리를 놓친다(17회차가 그 자리를 열었다).
    find_ops.toggleFind(fx.session); // 닫는다
    fx.session.find_nav = true;
    try testing.expect(!fx.session.chrome_host.find.open);
    try testing.expect(fx.session.chrome_host.find.match_count >= 2);

    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(editor_ops.DiffSide.left, editor_ops.diffSearchSide(fx.session, fx.term));
    try testing.expectEqual(@as(usize, 1), fx.session.chrome_host.find.match_count);

    // **대조군** — 항해도 아니고 오버레이도 닫혔으면 아무 일도 안 한다(쓰는 사람이 없다).
    fx.session.find_nav = false;
    const idle = fx.session.chrome_host.find.match_count;
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(idle, fx.session.chrome_host.find.match_count);
}

// ── DSB: 비교 뷰의 상태바 커서 위치 ────────────────────────────────────────────
//
// 계약은 [상태바](../../../../docs/status-bar.md) 「비교 뷰의 커서 위치」가 소유한다.

test "DSB1: 줄은 gutter 가 그리는 파일 번호이고, 짝맞춤 빈 행에는 번호가 없다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 오른쪽에만 있는 줄 — 왼쪽 그 자리는 짝맞춤 빈 행이라 번호가 없다.
    var entry = testEntry("keep\ntail\n", "keep\nadded\ntail\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "added") orelse return error.NoRow;
    try testing.expectEqual(@as(?u32, null), st.left_numbers[i]); // 픽스처 자기 검증

    // ⑴ **줄은 행 첨자가 아니라 파일 번호다.** "added" 는 오른쪽 파일의 2번째 줄이다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 0 }) };
    const r = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expectEqual(editor_ops.DiffSide.right, r.side);
    try testing.expectEqual(st.right_numbers[i], r.line);
    try testing.expectEqual(@as(?u32, 2), r.line);
    try testing.expectEqual(@as(usize, 1), r.column);
    try testing.expect(!r.truncated);

    // ⑵ **짝맞춤 빈 행에는 번호가 없다** — 앞뒤 줄에서 빌려 오지 않는다.
    fx.term.rt.editor_diff_selection.?.side = .left;
    const l = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expectEqual(editor_ops.DiffSide.left, l.side);
    try testing.expectEqual(@as(?u32, null), l.line);
    try testing.expectEqual(@as(usize, 1), l.column);

    // ⑶ **행 첨자와 파일 번호는 실제로 다르다** — 그 둘이 같으면 이 판정자가 아무것도 안 지킨다.
    const tail = rowIndexOf(st.left_texts, "tail") orelse return error.NoRow;
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = tail, .byte = 0 }) };
    const t2 = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expectEqual(@as(?u32, 2), t2.line); // 왼쪽 파일에서는 2번째 줄
    try testing.expectEqual(@as(usize, 2), tail); // 그런데 행 첨자는 2다 → 1-based 라 갈린다
}

test "DSB2: 열은 그래핌 클러스터 1-based 이고 탭은 한 글자다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // 탭과 CJK — 렌더의 열(탭이 탭스톱까지, CJK 가 두 칸)을 쓰면 여기서 갈린다.
    var entry = testEntry("keep\nxx\n", "keep\n\t가나\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "\t가나") orelse return error.NoRow;

    // 탭(1글자) + '가'(1글자) 뒤 = **3번째 글자**. 표시 열이라면 탭 4 + 가 2 = 7 이다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 1 + 3 }) };
    const p = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expectEqual(@as(usize, 3), p.column);

    // 행 머리는 1 이다(1-based).
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = 0;
    try testing.expectEqual(@as(usize, 1), (editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos).column);

    // **caret 이 없거나 비교가 아니면 답하지 않는다.**
    fx.term.rt.editor_diff_selection = null;
    try testing.expectEqual(@as(?@TypeOf(p), null), editor_ops.diffCursorPosition(fx.term));
}

test "DSB4: 상태바 글자가 `R 2:1`·`L -:1`·`+` 를 그대로 낸다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var buf: [48]u8 = undefined;
    // **형식을 함수로 꺼내 두지 않으면 이 넷을 못 잰다** — 트리 항목은 id 와 사각만 든다.
    //    1회차에서 `L`/`R` 을 지우거나 맞바꾸거나 빈 행의 `-` 를 `0` 으로 바꾼 변이가 다 살았다.
    try testing.expectEqualStrings("R 2:1", editor_ops.formatDiffCursor(&buf, .{ .side = .right, .line = 2, .column = 1, .truncated = false }).?);
    try testing.expectEqualStrings("L 2:1", editor_ops.formatDiffCursor(&buf, .{ .side = .left, .line = 2, .column = 1, .truncated = false }).?);
    try testing.expectEqualStrings("L -:1", editor_ops.formatDiffCursor(&buf, .{ .side = .left, .line = null, .column = 1, .truncated = false }).?);
    try testing.expectEqualStrings("R 9:120+", editor_ops.formatDiffCursor(&buf, .{ .side = .right, .line = 9, .column = 120, .truncated = true }).?);
    try testing.expectEqualStrings("R -:3+", editor_ops.formatDiffCursor(&buf, .{ .side = .right, .line = null, .column = 3, .truncated = true }).?);

    // **ASCII 뿐이다** — 상태바의 잘림 가드가 «byte 수 = 셀 수» 를 전제한다.
    const s = editor_ops.formatDiffCursor(&buf, .{ .side = .right, .line = 12345, .column = 678, .truncated = false }).?;
    for (s) |c| try testing.expect(c < 0x80);
}

test "DSB5: 열 텍스트·행 첨자·view 를 자기 것으로 본다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **좌우 같은 행의 길이를 갈라 둔다** — 같으면 「자기 열을 읽는다」와 「반대 열을 읽는다」가
    //    같은 답을 낸다(1회차 V10 이 그래서 살았다).
    var entry = testEntry("keep\nab\n", "keep\nABCDEFGH\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "ABCDEFGH") orelse return error.NoRow;
    try testing.expect(st.left_texts[i].len != st.right_texts[i].len); // 픽스처 자기 검증

    // ⑴ **자기 열의 글자를 센다.** 반대 열을 읽으면 byte 5 가 그 행 길이(2)로 잘려 열이 3 이 된다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 5 }) };
    try testing.expectEqual(@as(usize, 6), (editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos).column);

    // ⑵ **행 첨자를 자른다.** 비교가 다시 계산되면 행이 짧아질 수 있고, 그 사이에 이 값을 읽는다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = 9999, .byte = 0 }) };
    const clamped = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expectEqual(st.right_numbers[st.right_texts.len - 1], clamped.line);

    // ⑶ **비교가 아니면 답하지 않는다.** view 를 바꾼 채 끝나면 `release` 가 compare 자원을 안 놓아
    //    누수가 나므로 반드시 되돌린다(DSEL4 와 같은 규율).
    const saved_view = fx.term.rt.editor_diff.?.view;
    fx.term.rt.editor_diff.?.view = .loading;
    try testing.expectEqual(@as(?editor_ops.DiffCursor, null), editor_ops.diffCursorPosition(fx.term));
    fx.term.rt.editor_diff.?.view = saved_view;
}

test "DSB7: 아주 긴 행에서 열을 상한까지만 세고 `+` 로 말한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // **상한을 넘는 행을 만든다.** 안 넘으면 「상한을 본다」와 「안 본다」가 같은 답을 낸다
    //    (3회차 V24·V25 가 그래서 살았다).
    const limit = editor_ops.max_status_column;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendNTimes(allocator, 'x', limit + 500);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "head\n");
    try mod.appendSlice(allocator, long.items);

    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len > limit) row = i;
    }
    const r = row orelse return error.NoLongRow;

    // ⑴ **행 끝에 서면 상한까지만 세고 `+` 를 붙인다.**
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = st.right_texts[r].len }) };
    const p = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expect(p.truncated);
    try testing.expect(p.column <= limit + 1);

    // ⑵ **상한 안이면 `+` 가 없다** — ⑴ 이 「늘 참」이 아니다.
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = 5;
    const q = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expect(!q.truncated);
    try testing.expectEqual(@as(usize, 6), q.column);

    // ⑶ **`truncated` 는 「남은 byte 가 있나」다 — 열이 상한을 넘었나가 아니다.** 정확히 상한만큼인
    //    자리는 끝까지 세고도 안 잘렸다(그 둘을 col 로 판정하면 여기서 갈린다).
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = limit;
    const e = editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos;
    try testing.expect(!e.truncated);
}

test "DSB8: 버퍼가 모자라면 글을 안 낸다 — 빈 글이 아니다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // **빈 글을 내면 상태바에 빈 항목이 선다** — 폭만 먹고 아무 말도 안 하는 자리가 된다.
    //    `null` 이어야 호출자가 항목 자체를 안 만든다.
    var tiny: [3]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), editor_ops.formatDiffCursor(&tiny, .{ .side = .right, .line = 12345, .column = 678, .truncated = true }));
    // 대조군 — 넉넉하면 낸다.
    var ok: [48]u8 = undefined;
    try testing.expect(editor_ops.formatDiffCursor(&ok, .{ .side = .right, .line = 12345, .column = 678, .truncated = true }) != null);
}

test "DSB9: 열은 **클러스터**를 센다 — 결합 문자가 한 글자다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    // **결합 문자**(e + U+0301)와 **국기**(두 regional indicator) — 코드포인트로 세면 갈린다.
    //    한글·탭만 쓰면 클러스터와 코드포인트가 같은 답을 낸다(4회차 V30 이 그래서 살았다).
    var entry = testEntry("keep\nplain\n", "keep\ne\u{0301}x\n");
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    const i = rowIndexOf(st.right_texts, "e\u{0301}x") orelse return error.NoRow;
    try testing.expectEqual(@as(usize, 4), st.right_texts[i].len); // 'e'(1) + U+0301(2) + 'x'(1)

    // 결합 문자 **뒤**(byte 3)는 **2번째 글자**다. 코드포인트로 세면 3 이다.
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = i, .byte = 3 }) };
    try testing.expectEqual(@as(usize, 2), (editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos).column);

    // 행 끝은 **3번째 글자**다(e\u{0301} · x 뒤).
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = 4;
    try testing.expectEqual(@as(usize, 3), (editor_ops.diffCursorPosition(fx.term) orelse return error.NoPos).column);
}

test "DSB10: 빈 행 갈래도 버퍼가 모자라면 글을 안 낸다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // **두 갈래를 다 재야 한다** — 한쪽만 재면 나머지에서 빈 글이 나가도 초록이다(4회차 V28).
    var tiny: [3]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), editor_ops.formatDiffCursor(&tiny, .{ .side = .left, .line = null, .column = 4567, .truncated = true }));
    var ok: [48]u8 = undefined;
    try testing.expectEqualStrings("L -:4567+", editor_ops.formatDiffCursor(&ok, .{ .side = .left, .line = null, .column = 4567, .truncated = true }).?);
}

// ── DHS: 가로도 caret 을 따라간다 ──────────────────────────────────────────────
//
// 계약은 [시각 매핑](../../../../docs/native-editor-visual-mapping.md) 「가로도 caret 을 따라간다」.

test "DHS1: 비교 뷰에서 ⌘→ 를 누르면 가로가 따라온다 (handleKeyEvent)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // **한 화면보다 긴 줄**이어야 한다 — 짧으면 「따라간다」와 「안 간다」가 같은 답을 낸다.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, "keep\n");
    try long.appendNTimes(allocator, 'x', 600);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', 600);
    try mod.append(allocator, '\n');

    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len == 600) row = i;
    }
    const r = row orelse return error.NoLongRow;
    const visible = fx.term.rt.editor_diff_hit_geom.content_width;
    try testing.expect(visible > 0 and visible < 600); // 픽스처 자기 검증 — 화면보다 길다

    fx.term.rt.editor_first_col_right = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };

    // ⑴ **행 끝으로 가면 가로가 따라온다.**
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(usize, 600), fx.term.rt.editor_diff_selection.?.sel.focus.byte);
    try testing.expect(fx.term.rt.editor_first_col_right > 0);
    // **최소 이동이되, caret 이 서는 칸까지다.** caret 은 마지막 글자보다 한 칸 뒤(600열)에 서므로
    //    그 칸이 화면 **마지막 칸**이 되는 자리가 답이다 — `600 + 1 - 폭`. 한때는 `600 - 폭` 에서
    //    멈췄고(상한이 내용 폭 기준이라) caret 이 화면 밖 한 칸에 남아 안 그려졌다 —
    //    `editor.scroll-beyond-last-column`(기본 5)이 그 몫을 연다. **두 뷰가 같은 규칙이다.**
    try testing.expectEqual(@as(u16, @intCast(600 + 1 - visible)), fx.term.rt.editor_first_col_right);

    // ⑵ **행 머리로 돌아오면 0 으로 돌아온다.**
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col_right);

    // ⑶ **반대 열은 안 밀린다** — §3.5 「가로는 각자다」.
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .command = true } });
    try testing.expect(fx.term.rt.editor_first_col_right > 0);
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);

    // ⑷ **열을 넘기면 그 열의 가로가 따라온다.**
    try testing.expect(editor_ops.diffSwitchSide(fx.session, fx.term));
    try testing.expectEqual(editor_ops.DiffSide.left, fx.term.rt.editor_diff_selection.?.side);
    try testing.expect(fx.term.rt.editor_first_col > 0);
}

test "DHS2: 랩이 켜지면 가로를 안 건드린다 (§4 가로 축이 없다)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, "keep\n");
    try long.appendNTimes(allocator, 'x', 600);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', 600);
    try mod.append(allocator, '\n');
    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len == 600) row = i;
    }
    const r = row orelse return error.NoLongRow;

    // **저장된 값은 랩을 다시 껐을 때 돌아갈 자리다** — 랩 중에는 건드리지 않는다.
    fx.term.rt.editor_wrap = true;
    fx.term.rt.editor_first_col_right = 7;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .command = true } });
    try testing.expectEqual(@as(u16, 7), fx.term.rt.editor_first_col_right);

    // **대조군** — 랩을 끄면 따라간다.
    fx.term.rt.editor_wrap = false;
    fx.term.rt.editor_diff_selection.?.sel.focus.byte = 0;
    _ = try fx.session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = .{ .command = true } });
    try testing.expect(fx.term.rt.editor_first_col_right != 7);
}

test "DHS4: 줄 가운데에서는 상한이 안 걸린다 — 최소 이동을 그대로 잰다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, "keep\n");
    try long.appendNTimes(allocator, 'x', 600);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', 600);
    try mod.append(allocator, '\n');
    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len == 600) row = i;
    }
    const r = row orelse return error.NoLongRow;
    const visible = fx.term.rt.editor_diff_hit_geom.content_width;
    try testing.expect(visible > 0 and visible < 300); // 픽스처 자기 검증

    // **줄 **가운데**로 간다.** 행 끝에서 재면 상한(`max_cols -| visible`)이 답을 덮어써
    //    「한 칸 어긋난 최소 이동」이 같은 값을 낸다(1회차 H7 이 그래서 살았다).
    fx.term.rt.editor_first_col_right = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 300 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .char_right, false)); // 301열로
    try testing.expectEqual(@as(u16, @intCast(301 + 1 - visible)), fx.term.rt.editor_first_col_right);

    // **이미 보이면 안 민다** — 한 글자 왼쪽으로 가도 화면 안이다(최소 이동의 뒷면).
    const held = fx.term.rt.editor_first_col_right;
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .char_left, false));
    try testing.expectEqual(held, fx.term.rt.editor_first_col_right);

    // **왼쪽으로 나가면 그 열이 첫 칸이 된다.**
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_start, false));
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col_right);
}

test "DHS14: 탭 폭을 바꾸면 **두 열** 다 상한을 다시 센다 — 오른쪽 막대가 안 사라진다" {
    // **비교는 두 문서라 두 번 세야 한다**(`ensureMaxColsForDiff`). 왼쪽만 세면 오른쪽 `max_cols` 가
    // 0 으로 남고, `maxColsForRender` 가 `null` 을 내 **오른쪽 가로 막대가 사라진다** — 그 자리는
    // 본문 아래 여백을 먹으므로 높이가 출렁인다(단일 편집기에서 같은 부류를 이미 고쳤다).
    // 그 재계산 짝이 왼쪽만 세도 아무도 안 잡았다(적대적 검증 T5).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var lb: std.ArrayList(u8) = .empty;
    defer lb.deinit(allocator);
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    // **양쪽 다 탭으로 시작한다** — 탭 폭이 바뀌면 두 열의 상한이 **둘 다** 달라져야 한다.
    for (0..3) |_| try lb.appendSlice(allocator, "\t\tleft side\n");
    for (0..3) |_| try rb.appendSlice(allocator, "\t\tright side is longer here\n");
    var entry = testEntry(lb.items, rb.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    try testing.expect(fx.term.rt.editor_max_cols > 0);
    try testing.expect(fx.term.rt.editor_max_cols_right > 0);
    const left_before = fx.term.rt.editor_max_cols;
    const right_before = fx.term.rt.editor_max_cols_right;

    // **제품 진입점을 탄다** — 세터를 직접 부르면 배선이 지워져도 통과한다(TAB1 이 같은 규율이다).
    fx.session.loaded_config.config.editor.tab_width = 8;
    settings_ops.applyLoadedConfig(fx.session, true);
    try testing.expectEqual(@as(u8, 8), fx.term.rt.editor_tab_width);
    if (fx.term.rt.editor_max_cols == 0) return error.LeftMaxColsLost;
    if (fx.term.rt.editor_max_cols_right == 0) return error.RightMaxColsLost;
    // 탭이 넓어졌으니 **둘 다** 늘어야 한다 — 한쪽만 보면 「안 버렸다」와 「다시 셌다」가 겹친다.
    try testing.expect(fx.term.rt.editor_max_cols > left_before);
    try testing.expect(fx.term.rt.editor_max_cols_right > right_before);
}

test "DHS15: 그리기 직전 clamp 는 **그 열의 폭**으로 되돌린다 (비교 뷰)" {
    // `columns()` 가 나머지 픽셀을 오른쪽에 주므로 오른쪽 열이 더 넓을 수 있다. 왼쪽을 되돌릴 때
    // 오른쪽 폭을 쓰면 **왼쪽이 자기 상한을 넘은 채 남아** 오른쪽 끝에 빈 칸이 생긴다 —
    // 휠 경로에는 그것을 재는 판정자가 있었지만 **그리기 직전 clamp 에는 없었다**(적대적 검증 T2).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // **좌우 길이를 갈라 둔다.** 같은 길이면 두 열의 상한이 같은 값이라 「자기 상한을 쓴다」와
    // 「반대 열 상한을 쓴다」가 **같은 답**을 낸다(실측: 변이 T9 가 그래서 살았다). 폭(픽셀)만
    // 갈라 두는 것으로는 부족하다 — **상한(내용 열 수)도** 갈라야 한다.
    var lb: std.ArrayList(u8) = .empty;
    defer lb.deinit(allocator);
    try lb.appendNTimes(allocator, 'L', 300);
    try lb.append(allocator, '\n');
    var rb: std.ArrayList(u8) = .empty;
    defer rb.deinit(allocator);
    try rb.appendNTimes(allocator, 'R', 500);
    try rb.append(allocator, '\n');
    var entry = testEntry(lb.items, rb.items);
    // 홀수 폭이라 나머지가 오른쪽에 붙는다 — 두 열의 폭이 갈린다.
    const leaf: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 903, .h = 400 };
    try diffCaretFixture(&fx, &entry, leaf);

    const body = editor_ops.editorBodyRect(fx.session, leaf, fx.term);
    const left_w = editor_ops.visibleColsForTest(fx.session, body, fx.term, false);
    const right_w = editor_ops.visibleColsForTest(fx.session, body, fx.term, true);
    try testing.expect(right_w > left_w); // 픽스처 자기 검증 — 아니면 두 뜻이 겹친다
    try testing.expect(fx.term.rt.editor_max_cols_right > fx.term.rt.editor_max_cols); // 상한도 갈렸다

    // **왼쪽을 자기 상한 밖으로 밀어 둔다.** 그리기 직전 clamp 가 왼쪽 폭으로 되돌려야 한다.
    const beyond = fx.session.loaded_config.config.editor.scroll_beyond_last_column;
    const left_max: u32 = (fx.term.rt.editor_max_cols +| beyond) -| left_w;
    fx.term.rt.editor_first_col = @intCast(left_max + 5);
    var drawn = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn.dl.deinit(allocator);
    try testing.expectEqual(@as(u16, @intCast(left_max)), fx.term.rt.editor_first_col);

    // **오른쪽도 자기 폭으로 되돌린다.** 왼쪽만 재면 반대 자리가 그대로 남는다 — 두 열이 갈리는
    // 규칙은 **양쪽에서** 재야 뜻이 있다(실측: T8 이 오른쪽만 어긋내고 살아남았다).
    const right_max: u32 = (fx.term.rt.editor_max_cols_right +| beyond) -| right_w;
    fx.term.rt.editor_first_col_right = @intCast(right_max + 5);
    var drawn2 = editor_ops.appendPaneFrame(fx.session, leaf, fx.term) orelse return error.EditorPaneDidNotDraw;
    drawn2.dl.deinit(allocator);
    try testing.expectEqual(@as(u16, @intCast(right_max)), fx.term.rt.editor_first_col_right);
}

test "DHS12: 오른쪽 열의 caret 도 자기 상한을 쓴다 — 비대칭을 뒤집어 잰다" {
    // **DHS5 는 왼쪽에만 caret 을 세운다.** 그래서 「늘 왼쪽 상한을 쓴다」로 바꾼 변이는 그
    // 픽스처에서 **같은 답**을 낸다(실측: G6 이 그렇게 살았다). 두 열이 갈리는 규칙(§3.5
    // *"가로는 각자다"*)은 **양쪽에서** 재야 뜻이 있다 — 여기서는 긴 쪽을 오른쪽에 둔다.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(allocator);
    try base.appendSlice(allocator, "keep\n");
    try base.appendNTimes(allocator, 'x', 40); // **왼쪽이 짧다** — 반대 열의 상한을 쓰면 못 간다
    try base.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', 600);
    try mod.append(allocator, '\n');
    var entry = testEntry(base.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len == 600) row = i;
    }
    const r = row orelse return error.NoLongRow;
    try testing.expect(fx.term.rt.editor_max_cols_right != fx.term.rt.editor_max_cols); // 픽스처 자기 검증

    fx.term.rt.editor_first_col_right = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false));
    // 반대 열(40열)의 상한을 쓰면 `max_col` 이 0 이라 **아예 안 민다**.
    try testing.expect(fx.term.rt.editor_first_col_right > 40);
    // **왼쪽은 그대로다** — 한쪽을 밀 때 다른 쪽이 따라가면 §3.5 가 깨진다.
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);
}

test "DHS5: 한 프레임도 안 그렸으면 가로를 안 건드리고, 반대 열의 폭·상한을 안 쓴다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, "keep\n");
    try long.appendNTimes(allocator, 'x', 600);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', 40); // **오른쪽은 짧다** — 좌우 상한이 갈린다
    try mod.append(allocator, '\n');
    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.left_texts, 0..) |t, i| {
        if (t.len == 600) row = i;
    }
    const r = row orelse return error.NoLongRow;
    try testing.expect(fx.term.rt.editor_max_cols != fx.term.rt.editor_max_cols_right); // 픽스처 자기 검증

    // ⑴ **폭이 0 이면 아무 일도 안 한다** — 「밖이다」를 판정할 기준이 없다(1회차 H3).
    const saved_w = fx.term.rt.editor_diff_hit_geom.content_width;
    fx.term.rt.editor_diff_hit_geom.content_width = 0;
    fx.term.rt.editor_first_col = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false));
    try testing.expectEqual(@as(u16, 0), fx.term.rt.editor_first_col);
    fx.term.rt.editor_diff_hit_geom.content_width = saved_w;

    // ⑵ **자기 열의 상한을 쓴다.** 반대 열(40열)의 상한을 쓰면 훨씬 못 간다(1회차 H15).
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false));
    try testing.expect(fx.term.rt.editor_first_col > 40);

    // ⑶ **옮기면 다시 그린다**(1회차 H11).
    fx.session.metal_dirty = false;
    fx.term.rt.editor_first_col = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .left, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false));
    try testing.expect(fx.session.metal_dirty);
}

test "DHS6: `max_first_col` 을 넘는 줄에서는 그 상한에서 멈춘다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator);
    defer fx.deinit(allocator);

    // **예전에는 10,000열을 넘겨야 했다** — `max_first_col` 이 거기서 걸려야 그것을 뺀 변이와 답이
    //    갈렸다(2회차 H10·H19). 그 상한은 열↔byte 인덱스가 없어서 있었고, 인덱스가 들어오며
    //    없어졌다(§4.1c). 지금은 상한이 **문서 폭** 이므로 긴 줄이기만 하면 된다.
    const len: usize = 50_000;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, "keep\n");
    try long.appendNTimes(allocator, 'x', len);
    try long.append(allocator, '\n');
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(allocator);
    try mod.appendSlice(allocator, "keep\n");
    try mod.appendNTimes(allocator, 'y', len);
    try mod.append(allocator, '\n');
    var entry = testEntry(long.items, mod.items);
    try diffCaretFixture(&fx, &entry, .{ .x = 0, .y = 0, .w = 800, .h = 400 });
    const st = fx.term.rt.editor_diff.?;
    var row: ?usize = null;
    for (st.right_texts, 0..) |t, i| {
        if (t.len == len) row = i;
    }
    const r = row orelse return error.NoLongRow;
    const visible = fx.term.rt.editor_diff_hit_geom.content_width;
    try testing.expect(visible > 0);
    // 픽스처 자기 검증 — 갈 수 있는 거리가 **옛 상한(10,000)보다 크다**(안 그러면 이 판정자가
    // 공허하다 — 그 상한이 없어진 것을 여기서 확인하는 셈이기도 하다).
    try testing.expect(fx.term.rt.editor_max_cols_right -| visible > 10_000);

    fx.term.rt.editor_first_col_right = 0;
    fx.term.rt.editor_diff_selection = .{ .side = .right, .sel = maru.session.editor.selection.RowSelection.at(.{ .row = r, .byte = 0 }) };
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false));

    // **줄 끝이 화면에 든다** — 예전에는 `max_first_col`(10,000)에서 멈춰 5만열 줄의 끝에 못 닿았다.
    //
    // **수식을 여기서 다시 쓰지 않는다.** `first_col` 의 정확한 값은 caret 여백·`scroll-beyond` 가
    // 함께 정하고, 그것들은 각자 판정자가 있다(`SOFF*`). 여기서 재는 것은 **닿는가**이다.
    const at_end = fx.term.rt.editor_first_col_right;
    try testing.expect(at_end > 10_000); // 옛 상한은 없어졌다
    try testing.expect(at_end + visible >= fx.term.rt.editor_max_cols_right); // 끝이 화면에 있다
    // 그리고 더 가려 해도 그 자리다.
    try testing.expect(editor_ops.diffMove(fx.session, fx.term, .line_end, false) or true);
    try testing.expectEqual(at_end, fx.term.rt.editor_first_col_right);
}
