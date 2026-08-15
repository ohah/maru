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

/// 비교를 **네이티브 편집기로** 열까. 지금은 훅으로만 켠다 — 기본 경로는 CM6 그대로다(이관은 화면이
/// 서고 실제 클릭 경로를 확인한 뒤에 뒤집는다).
///
/// **세션이 init에서 한 번 읽어 든다**(`AppSession.native_diff`). 분기가 프로세스 전역 환경을 직접
/// 읽으면 그 분기를 확인하려는 테스트가 env를 건드려야 하고, 그것이 같은 프로세스의 다른 테스트로
/// 샌다 — 실제로 이 테스트를 쓰다가 그 문제를 만났다.
pub fn nativeDiffFromEnv() bool {
    const raw = std.c.getenv("MARU_NATIVE_DIFF") orelse return false;
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

/// **entry의 두 쪽 버퍼가 갈리기 전에** 부른다. 우리 줄 배열이 그 버퍼를 빌리므로, 순서가 뒤집히면
/// 해제된 메모리를 가리키는 행이 남는다.
pub fn invalidate(self: *AppSession, term: *Term) void {
    // **포인터 캡처로 받는다.** `&(opt orelse return)`은 값을 먼저 풀어 임시를 만들 수 있어, 아래 대입이
    // 저장된 상태가 아니라 그 임시에 들어갈 여지를 남긴다 — 여기서 그런 모호함을 두지 않는다.
    const st: *State = if (term.rt.editor_diff) |*p| p else return;
    if (st.view == .compare) st.view.compare.deinit(self.allocator);
    st.view = .loading;
    if (st.left_lines.len > 0) self.allocator.free(st.left_lines);
    if (st.right_lines.len > 0) self.allocator.free(st.right_lines);
    if (st.left_texts.len > 0) self.allocator.free(st.left_texts);
    if (st.right_texts.len > 0) self.allocator.free(st.right_texts);
    if (st.left_numbers.len > 0) self.allocator.free(st.left_numbers);
    if (st.right_numbers.len > 0) self.allocator.free(st.right_numbers);
    if (st.left_bands.len > 0) self.allocator.free(st.left_bands);
    if (st.right_bands.len > 0) self.allocator.free(st.right_bands);
    freeMarks(self.allocator, st.left_marks);
    freeMarks(self.allocator, st.right_marks);
    st.left_lines = &.{};
    st.right_lines = &.{};
    st.left_texts = &.{};
    st.right_texts = &.{};
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
        .compare => computeRows(self, entry, st),
    }
    st.settled_on = flags;
    self.metal_dirty = true;
}

/// 두 쪽이 왔다 — 줄로 자르고 대응을 만든다. **여기서만 할당한다.**
fn computeRows(self: *AppSession, entry: *dock_panel.Entry, st: *State) void {
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
    materialize(self, st) catch {
        st.view.compare.deinit(self.allocator);
        st.view = .{ .unavailable = .unknown };
    };
}

/// 행 배열을 **화면이 받는 모양**으로 한 번 옮겨 담는다.
fn materialize(self: *AppSession, st: *State) error{OutOfMemory}!void {
    const rows = st.view.compare;
    const lt = try self.allocator.alloc([]const u8, rows.left.len);
    errdefer self.allocator.free(lt);
    const rt = try self.allocator.alloc([]const u8, rows.right.len);
    errdefer self.allocator.free(rt);
    const ln = try self.allocator.alloc(?u32, rows.left.len);
    errdefer self.allocator.free(ln);
    const rn = try self.allocator.alloc(?u32, rows.right.len);
    errdefer self.allocator.free(rn);
    const lb = try self.allocator.alloc(chrome_editor.frame.RowBand, rows.left.len);
    errdefer self.allocator.free(lb);
    const rb = try self.allocator.alloc(chrome_editor.frame.RowBand, rows.right.len);
    errdefer self.allocator.free(rb);
    for (rows.left, 0..) |r, i| {
        lt[i] = displayText(r.text);
        ln[i] = r.line;
        // **왼쪽은 삭제만 칠한다.** context와 빈 행은 색이 없다.
        lb[i] = if (r.kind == .removed) .removed else .none;
    }
    for (rows.right, 0..) |r, i| {
        rt[i] = displayText(r.text);
        rn[i] = r.line;
        rb[i] = if (r.kind == .added) .added else .none;
    }
    st.left_texts = lt;
    st.right_texts = rt;
    st.left_numbers = ln;
    st.right_numbers = rn;
    st.left_bands = lb;
    st.right_bands = rb;

    // 문자 단위 강조는 **줄 대응이 끝난 뒤**에 온다(§7 경계 규칙 — 이 계산이 대응을 바꾸지 않는다).
    try computeMarks(self, st);
}

fn freeMarks(allocator: std.mem.Allocator, marks: []const []const chrome_editor.frame.Mark) void {
    if (marks.len == 0) return;
    for (marks) |row| if (row.len > 0) allocator.free(row);
    allocator.free(marks);
}

/// 짝이 된 줄 쌍마다 **바뀐 글자**를 계산한다(§3.5). 실패는 조용히 넘긴다 — 강조가 없으면 밴드만
/// 남고, 그것은 정보가 적을 뿐 틀리지 않는다.
///
/// **무엇이 한 글자인지 여기서 정한다.** L2(`intraline`)는 chrome을 몰라 토큰 경계를 받는데, 그 규칙
/// (grapheme cluster)이 chrome의 `text_layout`에 있고 이 층은 chrome을 안다. 코드포인트로 자르면
/// 이모지 ZWJ 시퀀스가 반으로 갈린다.
fn computeMarks(self: *AppSession, st: *State) error{OutOfMemory}!void {
    const rows = st.view.compare;
    const left = try self.allocator.alloc([]const chrome_editor.frame.Mark, rows.left.len);
    errdefer self.allocator.free(left);
    const right = try self.allocator.alloc([]const chrome_editor.frame.Mark, rows.right.len);
    errdefer self.allocator.free(right);
    @memset(left, &.{});
    @memset(right, &.{});
    st.left_marks = left;
    st.right_marks = right; // 여기서부터는 `invalidate`가 해제를 책임진다

    for (rows.left, rows.right, 0..) |lrow, rrow, i| {
        // **짝이 된 쌍에서만 본다**(§7 경계 규칙). 한쪽이 빈 행이면 순수 추가·삭제라 줄 전체가 밴드다.
        if (lrow.kind != .removed or rrow.kind != .added) continue;
        const lt = try clusterTokens(self.allocator, st.left_texts[i]);
        defer self.allocator.free(lt);
        const rt = try clusterTokens(self.allocator, st.right_texts[i]);
        defer self.allocator.free(rt);
        var result = (try intraline.compute(self.allocator, lt, st.left_texts[i], rt, st.right_texts[i], .{})) orelse continue;
        defer result.deinit(self.allocator);
        left[i] = try copyMarks(self.allocator, result.left);
        right[i] = try copyMarks(self.allocator, result.right);
    }
}

fn copyMarks(allocator: std.mem.Allocator, spans: []const intraline.Span) error{OutOfMemory}![]const chrome_editor.frame.Mark {
    if (spans.len == 0) return &.{};
    const out = try allocator.alloc(chrome_editor.frame.Mark, spans.len);
    for (spans, 0..) |s, i| out[i] = .{ .start = s.start, .len = s.len };
    return out;
}

/// grapheme cluster 경계. **표시가 한 글자로 보는 단위**여야 강조가 글자를 반으로 자르지 않는다.
fn clusterTokens(allocator: std.mem.Allocator, line: []const u8) error{OutOfMemory}![]intraline.Token {
    var out: std.ArrayList(intraline.Token) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        const base = maru.chrome.text_layout.decodeCodepoint(line, i);
        const end = @min(maru.chrome.text_layout.clusterEndAfter(line, i, base.advance), line.len);
        const n = @max(1, end - i);
        try out.append(allocator, .{ .start = @intCast(i), .len = @intCast(n) });
        i += n;
    }
    return out.toOwnedSlice(allocator);
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
pub fn editorMeta(term: *const Term) struct { path: ?[]const u8, read_only: bool } {
    if (isDiffTerm(term)) {
        const entry = term.file_entry.?;
        return .{ .path = if (entry.path.len == 0) null else entry.path, .read_only = true };
    }
    return .{
        .path = if (term.rt.editor_path) |p| p else null,
        .read_only = if (term.rt.editor_doc) |d| d.file.doc.read_only else false,
    };
}

/// 화면이 말할 문장. **내부 값을 노출하지 않는다**(§7) — 세 이유를 사람 문장으로만 옮긴다.
pub fn statusText(view: diff.View) []const u8 {
    return switch (view) {
        .loading => "비교를 읽는 중입니다…",
        .unchanged => "바뀐 곳이 없습니다.",
        .unavailable => |reason| switch (reason) {
            .too_large => "변경이 너무 커서 비교를 표시하지 않습니다.",
            .binary => "텍스트가 아니라 비교를 표시하지 않습니다.",
            .unknown => "비교를 읽지 못했습니다.",
        },
        // 좌우 배치는 슬라이스 c가 그린다. 그때까지 이 줄이 **판정이 섰다는 사실**을 말한다.
        .compare => "비교 준비됨",
    };
}

fn nowMs(self: *AppSession) u64 {
    const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(@divFloor(ns, std.time.ns_per_ms));
}

const testing = std.testing;

test "판정이 서기 전에는 읽는 중이다" {
    try testing.expectEqualStrings("비교를 읽는 중입니다…", statusText(.loading));
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
