//! 세션 host 데몬이 **std 의 `init.gpa` 가 아니라 `daemon_allocator` 가 고른 할당자**를 받고, 돌아온 뒤
//! 그것을 `deinit` 하는지 본다.
//!
//! `main.zig` 는 테스트 그래프 밖이라 모듈 안 판정자가 못 본다. 그래서 「쓰는가」를 원문에서 센다 — 헬퍼가
//! 있는지가 아니라, (1) 선택이 정확히 한 번 일어나고 (2) 그 결과가 `allocator` 로 묶이며 (3) `defer` 로
//! `deinit` 이 걸리는지. 셋 중 하나만 빠져도 조용히 예전으로 돌아간다: 선택이 없으면 포획이 돌아오고,
//! `deinit` 이 없으면 호스트의 누수 보고가 다시 사라진다.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 << 20));
}

/// 주석 줄은 뺀다 — 설명문 한 줄이 판정을 뒤집으면 안 된다.
fn countOutsideComments(text: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, needle)) |at| {
            total += 1;
            from = at + needle.len;
        }
    }
    return total;
}

/// `fn <name>(` 부터 다음 최상위 `}` 까지.
fn functionBody(text: []const u8, signature: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, signature) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, "\n}\n") orelse return null;
    return text[start..end];
}

test "데몬 진입은 daemon_allocator 로 고르고, 묶고, deinit 한다" {
    const src = try readSource(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "fn runSessionHostDaemon(") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "session_host.daemon_allocator.select(session_host.daemon_allocator.choiceFromEnvironment())"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "const allocator = selected.allocator;"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "defer _ = selected.deinit();"));
}

test "기본이 «조용»이고 켜는 이름이 문서와 같다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/daemon_allocator.zig");
    defer std.testing.allocator.free(src);
    // 기본 인스턴스가 포획 0 이어야 한다 — 이 리터럴이 사라지면 기본이 다시 6 프레임이 된다.
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "var quiet: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "pub const env_name: [:0]const u8 = \"MARU_ALLOC_TRACES\";"));
}
