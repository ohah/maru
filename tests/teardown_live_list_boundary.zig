//! 탭·pane·Term 을 풀 때 **푼 것을 살아 있는 목록에 남기지 않는지** 못 박는다(TAB-UAF·PANE-UAF).
//!
//! ## 무엇이 있었나
//!
//! 2026-10-06 15:03 — 창을 닫는 키 입력(IME 종료 → 닫기 확인) 중 앱이 SIGSEGV 로 죽었다. 크래시 리포트의 첫 프레임은
//! `destroyTerm` 안에 인라인된 `editor.conflict.invalidateCompareFor` 였다. 이 함수는 저장 충돌 비교를 정리하려고
//! **모든 탭·pane·Term 을 훑는다**(3489cf18d, 2026-09-22). 그런데 창 닫기(`destroyAllTabsForApprovedWindowClose`)와
//! 복원(`applyWorkspaceWindow`)은 `for (self.tabs.items) |tab| destroyTabStandalone(self, tab)` 으로 탭을 하나씩 풀면서
//! **목록에서는 안 뺐다** — 뒤 탭의 Term 을 풀 때 그 훑기가 앞 탭의 **해제된 메모리**를 읽었다. 그 자리를 JSON 문자열이
//! 차지하고 있어 `ion":1}}` 바이트가 포인터로 읽혔다(`0x7d7d313a226e6f69`). 같은 꼴이 Term 단계에서 이미 한 번
//! 터졌다(PANE-UAF, 6b0629f2f) — 그때는 한 단계만 고쳤다.
//!
//! ## 무엇을 재나
//!
//! ⑴ app_session 전체에서 `for (<목록>.items) |x| … destroy…(…)` 꼴(푼 것을 목록에 남기는 루프)이 **없다**. 아직
//!    게시되지 않은 목록을 실패 경로에서 푸는 `errdefer` 와 제자리 교체 한 곳만 (파일, 함수, 목록) 단위로 이유와 함께
//!    허용한다.
//! ⑵ 네 teardown 자리가 「목록에서 먼저 빼고 푼다」 꼴이다. 빼기 전에 풀거나, 풀고 나서 빼면 ⑴ 은 못 잡는다.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const destroy_calls = [_][]const u8{ "destroyTabStandalone(", "destroyPane(", "destroyTerm(", "destroyTermWithAbandonBackend(" };

/// 허용 — (파일, 함수, 목록) 마다 이유를 단다. 쓰이지 않는 항목이 생기면 실패한다(낡은 예외는 다음 구멍이 된다).
const allowed = [_]struct { file: []const u8, func: []const u8, list: []const u8, why: []const u8 }{
    .{ .file = "src/platform/macos/app_session/workspace.zig", .func = "applyWorkspaceWindow", .list = "new_tabs.items", .why = "errdefer — 새 탭은 아직 self.tabs 밖이라 아무도 훑지 않는다" },
    .{ .file = "src/platform/macos/app_session/tab.zig", .func = "buildWorkspaceTab", .list = "tab.panes.items", .why = "errdefer — 짓는 중인 탭은 아직 self.tabs 밖이다" },
    .{ .file = "src/platform/macos/app_session/file_panel.zig", .func = "transferRestoredFileEntries", .list = "pending.items", .why = "errdefer — 지역 목록, 아직 pane 에 붙지 않았다" },
    // 한 Term 을 같은 칸에서 새 Term 으로 갈아 끼우고 곧바로 return 한다. destroyTerm 안의 훑기가 만나는 것은 아직 살아
    // 있는 그 Term 자신(file_entry 를 먼저 null 로 뗐다)뿐이고, 해제 뒤 다른 훑기 전에 칸이 새 Term 으로 바뀐다.
    .{ .file = "src/platform/macos/app_session/file_panel.zig", .func = "rebuildFileTermSurface", .list = "self.tabs.items", .why = "제자리 교체 후 즉시 return" },
    .{ .file = "src/platform/macos/app_session/file_panel.zig", .func = "rebuildFileTermSurface", .list = "tab.panes.items", .why = "제자리 교체 후 즉시 return" },
    .{ .file = "src/platform/macos/app_session/file_panel.zig", .func = "rebuildFileTermSurface", .list = "pane.terms.items", .why = "제자리 교체 후 즉시 return" },
};

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

/// `open` 자리의 여는 괄호에 맞는 닫는 괄호 다음 위치. 문자열 안 괄호는 이 꼴의 루프에 나오지 않는다.
fn matchClose(src: []const u8, open: usize, comptime l: u8, comptime r: u8) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        if (src[i] == l) depth += 1;
        if (src[i] == r) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

const Loop = struct { iterable: []const u8, body: []const u8, at: usize };

/// `for (<iterable>) |…| <body>` 를 하나씩 꺼낸다. body 는 `{…}` 블록이거나 다음 `;` 까지의 문장이다.
fn nextLoop(src: []const u8, from: *usize) ?Loop {
    while (std.mem.indexOfPos(u8, src, from.*, "for (")) |at| {
        from.* = at + 5;
        // 식별자 꼬리(`inline for`·`errdefer for` 는 앞이 공백이라 통과, `xfor (` 같은 것은 건너뛴다).
        if (at > 0 and (std.ascii.isAlphanumeric(src[at - 1]) or src[at - 1] == '_')) continue;
        const close = matchClose(src, at + 4, '(', ')') orelse return null;
        const iterable = std.mem.trim(u8, src[at + 5 .. close - 1], " ");
        var i = close;
        while (i < src.len and src[i] == ' ') i += 1;
        if (i >= src.len or src[i] != '|') continue;
        const cap_end = std.mem.indexOfScalarPos(u8, src, i + 1, '|') orelse return null;
        i = cap_end + 1;
        while (i < src.len and src[i] == ' ') i += 1;
        const body_end = if (i < src.len and src[i] == '{')
            matchClose(src, i, '{', '}') orelse return null
        else
            (std.mem.indexOfScalarPos(u8, src, i, ';') orelse return null) + 1;
        return .{ .iterable = iterable, .body = src[i..body_end], .at = at };
    }
    return null;
}

/// 첫 iterable(`a.items, 0..` 의 `a.items`).
fn firstList(iterable: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, iterable, ',') orelse iterable.len;
    return std.mem.trim(u8, iterable[0..end], " ");
}

fn destroysInPlace(loop: Loop) bool {
    if (!std.mem.endsWith(u8, firstList(loop.iterable), ".items")) return false;
    for (destroy_calls) |call| if (std.mem.indexOf(u8, loop.body, call) != null) return true;
    return false;
}

/// 루프를 감싸는 함수 이름 — 앞쪽 마지막 `fn <name>(`.
fn enclosingFn(src: []const u8, at: usize) []const u8 {
    const f = std.mem.lastIndexOf(u8, src[0..at], "fn ") orelse return "";
    const open = std.mem.indexOfScalarPos(u8, src, f, '(') orelse return "";
    return src[f + 3 .. open];
}

fn allowedIndex(path: []const u8, func: []const u8, loop: Loop) ?usize {
    for (allowed, 0..) |a, i| {
        if (std.mem.eql(u8, a.file, path) and std.mem.eql(u8, a.func, func) and std.mem.eql(u8, a.list, firstList(loop.iterable))) return i;
    }
    return null;
}

/// 파일 하나에서 금지된 루프 수를 센다(허용분은 `used` 에 표시한다).
fn scanFile(allocator: std.mem.Allocator, path: []const u8, used: *[allowed.len]bool) !usize {
    const raw = try read(allocator, path);
    defer allocator.free(raw);
    const src = try normalize(allocator, raw);
    defer allocator.free(src);
    var bad: usize = 0;
    var from: usize = 0;
    while (nextLoop(src, &from)) |loop| {
        if (!destroysInPlace(loop)) continue;
        const func = enclosingFn(src, loop.at);
        if (allowedIndex(path, func, loop)) |i| {
            used[i] = true;
            continue;
        }
        std.debug.print("{s} {s}: 푼 것을 목록에 남기는 루프 — for ({s}) … {s}\n", .{ path, func, loop.iterable, loop.body[0..@min(loop.body.len, 120)] });
        bad += 1;
    }
    return bad;
}

test "TAB-UAF 탭·pane·Term 을 푸는 루프가 푼 것을 살아 있는 목록에 남기지 않는다" {
    const a = std.testing.allocator;
    var bad: usize = 0;
    var used = [_]bool{false} ** allowed.len;
    bad += try scanFile(a, "src/platform/macos/app_session.zig", &used);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src/platform/macos/app_session", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, a);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(a, "src/platform/macos/app_session/{s}", .{entry.path});
        defer a.free(path);
        bad += try scanFile(a, path, &used);
        files += 1;
    }
    // 디렉터리를 못 읽어 0 개를 훑고 초록이 되는 것을 막는다.
    if (files < 10) return error.ScanTooSmall;
    if (bad != 0) return error.DestroyLeavesFreedEntryInList;
    // 허용 목록이 낡으면(그 자리가 사라지거나 바뀌면) 목록도 지운다 — 쓰이지 않는 예외는 다음 구멍이 된다.
    for (allowed, used) |entry, u| if (!u) {
        std.debug.print("쓰이지 않는 허용 항목: {s} {s} {s}\n", .{ entry.file, entry.func, entry.list });
        return error.StaleAllowList;
    };
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

fn expectOnce(a: std.mem.Allocator, path: []const u8, comptime func: []const u8, needle: []const u8) !void {
    const raw = try read(a, path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);
    const body = try fnBody(src, func);
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, needle)) |f| : (at = f + needle.len) n += 1;
    if (n != 1) {
        std.debug.print("{s} {s}: «{s}» 가 {d} 번 — 1 번이어야 한다\n", .{ path, func, needle, n });
        return error.WiringChanged;
    }
}

test "TAB-UAF 창 닫기·복원·탭·pane teardown 은 목록에서 먼저 빼고 푼다" {
    const a = std.testing.allocator;
    const tab = "src/platform/macos/app_session/tab.zig";
    try expectOnce(a, tab, "destroyAllTabsForApprovedWindowClose", "while (self.tabs.items.len > 0) destroyTabStandalone(self, self.tabs.orderedRemove(0));");
    try expectOnce(a, tab, "destroyTabStandalone", "while (tab.panes.items.len > 0) pane_ops.destroyPane(self, tab.panes.orderedRemove(0));");
    try expectOnce(a, "src/platform/macos/app_session/workspace.zig", "applyWorkspaceWindow", "while (self.tabs.items.len > 0) tab_ops.destroyTabStandalone(self, self.tabs.orderedRemove(0));");
    try expectOnce(a, "src/platform/macos/app_session/pane.zig", "destroyPane", "while (pane.terms.items.len > 0) term_ops.destroyTerm(self, pane.terms.orderedRemove(0));");
}
