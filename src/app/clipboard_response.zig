//! OSC 52 read-reply bytes shared by native hosts. Policy gates and OS reads
//! stay in the host; never apply paste normalization to returned data.
//! Framing/base64 follow xterm OSC 52 / RFC 4648:
//! https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands
//! Empty Pc preserves Maru's existing macOS desktop default c, rather than
//! xterm's X11-specific s0 selection/cut-buffer default.
const std = @import("std");
pub const max_bytes = @import("../terminal.zig").clipboard_max_bytes;
pub const Error = std.mem.Allocator.Error || error{ ClipboardTooLarge, ResponseTooLarge };

pub fn format(a: std.mem.Allocator, target: []const u8, bytes: []const u8) Error![]u8 {
    if (bytes.len > max_bytes) return error.ClipboardTooLarge;
    const tgt = if (target.len == 0) "c" else target;
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(bytes.len);
    const header_len = std.math.add(usize, 8, tgt.len) catch return error.ResponseTooLarge;
    const total = std.math.add(usize, header_len, encoded_len) catch return error.ResponseTooLarge;
    const reply = try a.alloc(u8, total);
    @memcpy(reply[0..5], "\x1b]52;");
    @memcpy(reply[5..][0..tgt.len], tgt);
    reply[5 + tgt.len] = ';';
    _ = encoder.encode(reply[6 + tgt.len ..][0..encoded_len], bytes);
    @memcpy(reply[total - 2 ..], "\x1b\\");
    return reply;
}

fn expectReply(target: []const u8, bytes: []const u8, expected: []const u8) !void {
    const reply = try format(std.testing.allocator, target, bytes);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings(expected, reply);
}

test "OSC52 response preserves target defaults empty data and ST framing" {
    try expectReply("c", "hi", "\x1b]52;c;aGk=\x1b\\");
    try expectReply("", "hi", "\x1b]52;c;aGk=\x1b\\");
    try expectReply("p", "", "\x1b]52;p;\x1b\\");
    try expectReply("s012", "x", "\x1b]52;s012;eA==\x1b\\");
}

test "OSC52 response preserves raw newlines nul and arbitrary bytes" {
    try expectReply("c", "A\r\nB\nC\r", "\x1b]52;c;QQ0KQgpDDQ==\x1b\\");
    try expectReply("c", &.{ 0, 255, 254, 27 }, "\x1b]52;c;AP/+Gw==\x1b\\");
    try expectReply("c", "가", "\x1b]52;c;6rCA\x1b\\");
}

test "OSC52 response enforces shared payload cap before allocation or reading" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const inaccessible: [*]const u8 = @ptrFromInt(1);
    const over = inaccessible[0 .. max_bytes + 1];
    try std.testing.expectError(error.ClipboardTooLarge, format(failing.allocator(), "c", over));
    try std.testing.expect(!failing.has_induced_failure);
    const exact = inaccessible[0..max_bytes];
    try std.testing.expectError(error.OutOfMemory, format(failing.allocator(), "c", exact));
    try std.testing.expect(failing.has_induced_failure);
}

test "OSC52 response rejects target size overflow without accessing target" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const inaccessible: [*]const u8 = @ptrFromInt(1);
    const target = inaccessible[0..std.math.maxInt(usize)];
    try std.testing.expectError(error.ResponseTooLarge, format(failing.allocator(), target, "hi"));
    try std.testing.expect(!failing.has_induced_failure);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const result = try format(a, "p", "hello\r\nworld");
    defer a.free(result);
    try std.testing.expectEqualStrings("\x1b]52;p;aGVsbG8NCndvcmxk\x1b\\", result);
}

test "OSC52 response allocation failure returns no partial owned reply" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
