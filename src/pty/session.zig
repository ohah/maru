const builtin = @import("builtin");
const std = @import("std");
const terminal = @import("../terminal.zig");
const types = @import("types.zig");

pub const PtySession = switch (builtin.os.tag) {
    .macos => @import("macos.zig").PtySession,
    else => UnsupportedPtySession,
};

// non-macOS에서도 public facade는 컴파일되어야 한다.
// 실제 backend가 없다는 사실을 런타임 오류로 노출해 Windows/ConPTY 추가 전까지 import 경계를 안정화한다.
const UnsupportedPtySession = struct {
    pub fn spawn(allocator: std.mem.Allocator, request: types.SpawnRequest) !UnsupportedPtySession {
        _ = allocator;
        _ = request;
        return error.UnsupportedPlatform;
    }

    pub fn deinit(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn readEvent(self: *UnsupportedPtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        _ = self;
        _ = allocator;
        return error.UnsupportedPlatform;
    }

    pub fn writeInput(self: *UnsupportedPtySession, bytes: []const u8) !void {
        _ = self;
        _ = bytes;
        return error.UnsupportedPlatform;
    }

    pub fn resize(self: *UnsupportedPtySession, size: terminal.Size) !void {
        _ = self;
        _ = size;
        return error.UnsupportedPlatform;
    }

    pub fn currentSize(self: *UnsupportedPtySession) !terminal.Size {
        _ = self;
        return error.UnsupportedPlatform;
    }
};

test "unsupported PtySession reports unsupported platform outside macOS" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    try std.testing.expectError(
        error.UnsupportedPlatform,
        PtySession.spawn(std.testing.allocator, .{ .command = "/bin/sh" }),
    );
}
