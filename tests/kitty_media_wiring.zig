//! kitty 매체 전송(`t=f/t/s`)의 **배선**이 제품 자리에 걸려 있는지 센다.
//!
//! 모듈 판정자는 «읽기 함수가 옳게 읽는가»·«코어가 job 을 만드는가» 를 본다. 그것을 리더가 **부르지 않으면**
//! 매체 job 은 큐에 남아 `EBADF` 로 닫히고 파서는 멈추지 않아 DA1 응답이 먼저 나간다 — 판정자는 초록인 채
//! kitten 은 «미지원» 을 읽는다. 그래서 「쓰는가」 를 센다: 리더가 `writeUntilMediaJob` 으로 쓰고 매체 job 을
//! `kitty_media_io` 로 읽는가, 파서의 멈춤이 APC dispatch 자리에 있는가.
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

fn functionBody(text: []const u8, signature: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, signature) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, end_marker) orelse return null;
    return text[start..end];
}

test "리더는 코어에 writeUntilMediaJob 으로 쓰고(멈춤을 받는다) 매체 job 은 kitty_media_io 로 읽는다" {
    const src = try readSource(std.testing.allocator, "src/app/pty_reader.zig");
    defer std.testing.allocator.free(src);
    const apply = functionBody(src, "fn applyToCore(", "\n    }\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(apply, "core.writeUntilMediaJob("));
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(apply, "core.write(")); // 멈추지 않는 write 가 다시 생기면 순서가 깨진다
    const drain = functionBody(src, "fn drainKittyJobs(", "\n    }\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(drain, "kitty_media_io.readAndDecode("));
}

test "파서의 멈춤은 APC dispatch 바로 뒤에 있고 매체 job 만 본다" {
    const src = try readSource(std.testing.allocator, "src/terminal/parser.zig");
    defer std.testing.allocator.free(src);
    const feed = functionBody(src, "pub fn feedUntil(", "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(feed, "kitty.hasQueuedMediaJob(self)) return index_;"));
    const kitty_src = try readSource(std.testing.allocator, "src/terminal/kitty.zig");
    defer std.testing.allocator.free(kitty_src);
    const has = functionBody(kitty_src, "pub fn hasQueuedMediaJob(", "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(has, "job.medium != 'd'"));
}

test "리더 없는 코어는 매체를 ENOTSUPP 로 거부한다 — 폴백 유도 계약" {
    const src = try readSource(std.testing.allocator, "src/terminal/kitty.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "fn kittyTransmitMedia(", "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "if (!self.kitty_defer_decode) return .enotsupp;"));
}
