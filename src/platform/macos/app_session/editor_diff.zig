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
const scroll_ops = @import("scroll.zig");

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

test "비교의 breadcrumb는 그 비교를 읽은 저장소 기준이다" {
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
    // 오른쪽 13행, 같은 `c`가 2행 대 12행. `editor.wrap` 기본값이 `true`라 **이것이 기본 상태**다.
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
    const expect_first: u32 = @min(fx.term.rt.editor_max_cols_right -| layout.content.width, @as(u32, chrome_editor.frame.max_first_col));
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
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, false, col_x(g, cw, 7), y0));
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
    try testing.expect(editor_ops.selectWordOrLineAt(fx.session, pane, true, col_x(g, cw, 7), y0));
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 2, col_x(g, cw, 2), y0));
    try testing.expect(editor_ops.copyDiffSelection(fx.session));
    try testing.expectEqualStrings("alpha beta gamma", fx.session.chrome_clipboard_write);
    try testing.expect(editor_ops.dragDiffBodySelection(fx.session, 3, col_x(g, cw, 2), y0));
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
