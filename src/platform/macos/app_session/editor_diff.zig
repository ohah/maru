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
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const dock_panel = maru.session.dock_panel;
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
    /// 요청을 건 시각. 재시도 창(6초)을 여기서 잰다.
    requested_ms: u64 = 0,
    /// 판정이 끝났는가. **끝난 판정을 매 tick 다시 계산하지 않는다** — 2,000줄 대응을 프레임마다
    /// 돌리면 화면이 멈춘다. 내용이 갈리면 `invalidate`가 이 래치를 푼다.
    settled: bool = false,
};

/// 이 Term이 네이티브 diff인가. 편집기 Term이면서 dock entry가 비교인 것.
pub fn isDiffTerm(term: *const Term) bool {
    if (term.kind != .editor) return false;
    const entry = term.file_entry orelse return false;
    return entry.kind == .diff;
}

/// 비교를 **네이티브 편집기로** 열까. 지금은 훅으로만 켠다 — 기본 경로는 CM6 그대로다(§7의 이관은
/// 슬라이스 c에서 화면이 서고 골든이 붙은 뒤에 뒤집는다).
pub fn nativeDiffEnabled() bool {
    const raw = std.c.getenv("MARU_NATIVE_DIFF") orelse return false;
    const v = std.mem.span(raw);
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
    st.left_lines = &.{};
    st.right_lines = &.{};
    st.settled = false;
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
    if (st.settled) return;

    const now = nowMs(self);
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
