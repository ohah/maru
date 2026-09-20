//! `Client` 의 poll 프레임 캐시가 **제품 자리에 걸려 있는지** 센다.
//!
//! 캐시는 두 조각이 맞물려야 산다 — (1) 프레임 루프가 tick 마다 도장을 올린다(`advanceUiFrameStamp`),
//! (2) `pumpScreen` 의 polling 읽기가 `pollReadableThisFrame` 을 쓴다. (1) 이 빠지면 도장이 0 에 머물러 캐시가
//! 영영 안 켜지고(안전하지만 이득 0), (2) 가 빠지면 도장만 올라간다. 둘 다 판정자는 초록인 채 실측만 원래대로다.
//! 그리고 (3) `pollReadableOrTerminal`(peer 종료를 먼저 봐야 하는 자리)은 캐시를 쓰면 안 된다.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 << 20));
}

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

fn functionBody(text: []const u8, signature: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, signature) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, end_marker) orelse return null;
    return text[start..end];
}

test "backend 의 maintenanceEventTick 이 프레임 도장을 tick 마다 한 번 올린다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "pub fn maintenanceEventTick(self: *RemoteTermBackend) void {", "\n    }\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "client_mod.advanceUiFrameStamp();"));
    // 도장은 이 자리 하나에서만 오른다 — 둘이면 한 tick 이 두 프레임으로 보여 캐시가 헛돈다.
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "advanceUiFrameStamp();"));
}

test "polling 읽기는 캐시를 쓰고, peer 종료를 보는 자리는 날것 poll 을 쓴다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/session_host/client.zig");
    defer std.testing.allocator.free(src);
    // 제품 polling 읽기 자리: 캐시 1, 날것 0.
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "if (!pollReadableThisFrame(self)) return null;"));
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "if (!pollReadable(self.fd)) return null;"));
    // peer 종료 자리는 그대로.
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(src, "if (!pollReadableOrTerminal(self.fd)) return;"));
    // 캐시 함수 안에서 «있음» 을 기록하는 줄이 없다(있음을 캐시하면 읽고 난 뒤 빈 소켓을 «있음» 으로 본다).
    const body = functionBody(src, "fn pollReadableThisFrame(self: *Client) bool {", "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "if (pollReadable(self.fd)) return true;"));
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "if (frame != 0 and self.socket_empty_at_frame == frame) return false;"));
}
