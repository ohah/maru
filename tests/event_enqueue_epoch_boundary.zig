//! **이벤트가 큐에 들어오는 모든 제품 자리가 enqueue 세대를 올린다.**
//!
//! `RemoteRuntime` 은 `client.generation_event_enqueue_epoch` 가 마지막 «없음» 때와 같으면 드레인의 lease
//! 의례를 건너뛴다(활성 32 세션에서 그 빈 확인이 앱 busy CPU 의 19 % 였다). 그 최적화가 틀릴 수 있는 방향은
//! 하나뿐이다 — **이벤트를 넣고 세대를 안 올린 자리**. 그러면 그 이벤트는 다음 추가가 올 때까지 안 읽힌다.
//! 동작 판정자(`ID1`)는 지금의 한 자리만 본다. 누가 두 번째 추가 경로를 만들면 그것은 여기서만 보인다.
//!
//! 규칙: session_host 의 모든 `.zig` 에서 `pending_events.append(` 를 찾아 **감싸는 함수**를 본다.
//!   - `test` 블록을 지운 소스에 그 함수 이름이 **정의 한 번만** 나오면 제품 코드가 부르지 않는 테스트
//!     픽스처다 — 허용.
//!   - 한 번이라도 더 나오면(호출·vtable·함수 값) 제품 경로다 — 그러면 `client.zig` 의 `appendBufferedEvent`
//!     여야 하고, 그 함수 안에서 append **뒤에** 세대를 올린다.
//!
//! **기준이 두 번 바뀌었다**(적대적 검증 2026-09-23). ① 이름 목록 — `test` 블록 밖 픽스처가 파일마다 흩어져
//! (`checkExternalModePreservesClientState`·`appendExternalTakeQueueFixture`·`checkPreparedScreenBacklogAllocation` …)
//! 돌릴 때마다 새 이름이 나왔다. ② «본문이 `std.testing` 을 쓰면 픽스처» — `appendTestEvent` 가 안 썼다.
//! 둘 다 **모양**을 봤다. 지금 기준은 **도달 가능성**(제품이 부르는가)을 본다 — 그게 물어야 할 것이었다.

const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;
const dir_path = "src/platform/macos/session_host";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// `test "…" { … }` 블록을 **들여쓰기와 무관하게** 지우고(구조체 안에 중첩된 test 도 있다 — 적대적 검증에서
/// `remote_term_backend.zig` 의 들여쓴 test 가 «함수 밖 append» 로 잡혔다), 줄마다 `//` 뒤를 지운 소스.
fn productOnly(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var no_tests: std.ArrayList(u8) = .empty;
    defer no_tests.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '\n' and testBlockStartsAfterIndent(src, i + 1)) {
            const open = std.mem.indexOfScalarPos(u8, src, i, '{') orelse break;
            var depth: usize = 0;
            var j = open;
            while (j < src.len) : (j += 1) {
                if (src[j] == '{') depth += 1;
                if (src[j] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            i = j + 1;
            continue;
        }
        try no_tests.append(allocator, src[i]);
        i += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, no_tests.items, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn testBlockStartsAfterIndent(src: []const u8, from: usize) bool {
    var k = from;
    while (k < src.len and src[k] == ' ') k += 1;
    return std.mem.startsWith(u8, src[k..], "test \"");
}

const FnSpan = struct { name: []const u8, body: []const u8 };

/// `offset` 을 감싸는 가장 가까운 `fn <이름>(` 과 그 본문(`{` 부터 짝 `}` 까지).
fn enclosingFn(src: []const u8, offset: usize) ?FnSpan {
    var i = offset;
    while (i > 0) : (i -= 1) {
        if (i + 3 <= src.len and std.mem.eql(u8, src[i .. i + 3], "fn ") and (src[i - 1] == ' ' or src[i - 1] == '\n')) {
            const name_start = i + 3;
            const paren = std.mem.indexOfScalarPos(u8, src, name_start, '(') orelse return null;
            const open = std.mem.indexOfScalarPos(u8, src, paren, '{') orelse return null;
            var depth: usize = 0;
            var j = open;
            while (j < src.len) : (j += 1) {
                if (src[j] == '{') depth += 1;
                if (src[j] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (j < offset) continue; // 이 fn 은 offset 앞에서 이미 끝났다 — 더 바깥을 찾는다
            return .{ .name = src[name_start..paren], .body = src[open..@min(j + 1, src.len)] };
        }
    }
    return null;
}

/// 식별자 경계를 지켜 센다(`appendTestEvent` 가 `appendTestEvents` 안에서 세지지 않게).
fn countWord(haystack: []const u8, word: []const u8) usize {
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, word)) |found| : (at = found + word.len) {
        const before_ok = found == 0 or !isIdent(haystack[found - 1]);
        const after = found + word.len;
        const after_ok = after >= haystack.len or !isIdent(haystack[after]);
        if (before_ok and after_ok) seen += 1;
    }
    return seen;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var seen: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| : (at = found + needle.len) seen += 1;
    return seen;
}

test "이벤트 큐에 추가하는 제품 자리는 하나이고 그 자리가 enqueue 세대를 올린다" {
    const a = std.testing.allocator;
    var product_sites: usize = 0;
    var bump_sites: usize = 0;

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = dir.iterate();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name });
        defer a.free(path);
        const raw = try read(a, path);
        defer a.free(raw);
        const src = try productOnly(a, raw);
        defer a.free(src);
        bump_sites += count(src, "generation_event_enqueue_epoch.fetchAdd(");

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, "pending_events.append(")) |found| : (at = found + 1) {
            const span = enclosingFn(src, found) orelse {
                std.debug.print("{s}: pending_events.append( 가 함수 밖에 있다\n", .{path});
                return error.EnqueueOutsideFunction;
            };
            if (countWord(src, span.name) == 1) continue; // 제품 코드가 부르지 않는 테스트 픽스처
            const is_product_site = std.mem.eql(u8, entry.name, "client.zig") and
                std.mem.eql(u8, span.name, "appendBufferedEvent");
            if (!is_product_site) {
                std.debug.print("{s} 의 `{s}` 가 제품 경로에서 pending_events 에 append 한다 — enqueue 세대를 올리는지 확인하라\n", .{ path, span.name });
                return error.UnreviewedEnqueueSite;
            }
            const append_at = std.mem.indexOf(u8, span.body, "pending_events.append(") orelse unreachable;
            const bump_at = std.mem.indexOf(u8, span.body, "generation_event_enqueue_epoch.fetchAdd(") orelse {
                std.debug.print("appendBufferedEvent 가 enqueue 세대를 안 올린다 — 빈 드레인 건너뛰기가 이벤트를 놓친다\n", .{});
                return error.EnqueueWithoutEpochBump;
            };
            try std.testing.expect(append_at < bump_at);
            product_sites += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), product_sites);
    try std.testing.expectEqual(@as(usize, 1), bump_sites);
}
