//! 호스트의 **제품 경로**가 `unsetenv` 를 직접 부르지 않고 `std_environ_view` 를 거치는지 센다.
//!
//! `unsetenv` 를 날것으로 부르면 std 의 debug Io 가 붙잡은 환경 조각이 stale 이 되어 다음 `std.log`
//! 에서 프로세스가 죽는다(`std_environ_view.zig` 머리말). 판정은 「쓰는가」를 센다 — 헬퍼가 존재하는지가
//! 아니라 제품 자리가 그것을 **부르는지**. 정의만 있고 안 부르면 공허하게 통과하기 때문이다.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4 << 20));
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

test "startup_readiness 는 unsetenv 를 헬퍼로만 부른다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/startup_readiness.zig");
    defer std.testing.allocator.free(src);
    // 날것 호출 0, 헬퍼 호출 1. 날것이 다시 생기면 그 자리가 곧 크래시다.
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "= unsetenv("));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "std_environ_view.unsetenvKeepingStdView("));
}

/// `pub fn <name>(` 부터 다음 최상위 `}` 까지 — 한 함수의 본문.
fn functionBody(text: []const u8, signature: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, signature) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, "\n}\n") orelse return null;
    return text[start..end];
}

test "헬퍼는 지우기와 갱신을 한 함수에 묶어 둔다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/std_environ_view.zig");
    defer std.testing.allocator.free(src);
    // 지우기 뒤 갱신이 빠지면 헬퍼가 있어도 결함이 그대로다. 줄 단위 계수기는 두 줄짜리 needle 을
    // 못 보므로, 함수 본문을 잘라 한 줄 needle 둘을 각각 센다.
    const body = functionBody(src, "pub fn unsetenvKeepingStdView(") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "unsetenv(name)"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "refreshStdDebugView();"));
}
