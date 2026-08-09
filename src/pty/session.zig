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

    pub fn close(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn readEvent(self: *UnsupportedPtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        _ = self;
        _ = allocator;
        return error.UnsupportedPlatform;
    }

    // 비-macOS 스텁 — macOS 백엔드의 단일 I/O 루프 프리미티브(waitIo/readChunk/reapAfterEof)와 구조
    // 동기(이식성 목표 + pty_reader.runProcessing이 모든 타깃에서 컴파일되게). 항상 UnsupportedPlatform.
    pub const IoReady = struct { readable: bool = false, writable: bool = false };
    pub const ReadOutcome = union(enum) { data: usize, eof, again };

    pub fn waitIo(self: *UnsupportedPtySession, want_write: bool) !IoReady {
        _ = self;
        _ = want_write;
        return error.UnsupportedPlatform;
    }

    pub fn readChunk(self: *UnsupportedPtySession, buf: []u8) !ReadOutcome {
        _ = self;
        _ = buf;
        return error.UnsupportedPlatform;
    }

    pub fn reapAfterEof(self: *UnsupportedPtySession) !?types.ExitStatus {
        _ = self;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS 백엔드의 reapIfExited(비차단 자식 생존 검증 — read_error 무검증 종료 방지)와 구조 동기.
    pub fn reapIfExited(self: *UnsupportedPtySession) !?types.ExitStatus {
        _ = self;
        return error.UnsupportedPlatform;
    }

    pub fn writeInput(self: *UnsupportedPtySession, bytes: []const u8) !void {
        _ = self;
        _ = bytes;
        return error.UnsupportedPlatform;
    }

    pub fn writeInputNonBlocking(self: *UnsupportedPtySession, bytes: []const u8) !usize {
        _ = self;
        _ = bytes;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS 백엔드의 signalWrite(I/O 스레드 wake)와 구조 동기. 백엔드 없어 no-op.
    pub fn signalWrite(self: *UnsupportedPtySession) void {
        _ = self;
    }

    pub fn resize(self: *UnsupportedPtySession, size: terminal.Size) !void {
        _ = self;
        _ = size;
        return error.UnsupportedPlatform;
    }

    /// 비-macOS 스텁 — macOS backend의 resourceSamples와 구조 동기. 지원 backend가 없어 표본이 없다.
    pub fn resourceSamples(self: *UnsupportedPtySession, out: []types.ProcessResourceSample) usize {
        _ = self;
        _ = out;
        return 0;
    }

    /// 비-macOS 스텁 — macOS backend의 foregroundProcessNames와 구조 동기. 지원 backend가 없어 빈 목록이다.
    pub fn foregroundProcessNames(self: *UnsupportedPtySession, out: []types.ForegroundProcessName) usize {
        _ = self;
        _ = out;
        return 0;
    }

    pub fn foregroundProcessGroup(self: *UnsupportedPtySession) ?i32 {
        _ = self;
        return null;
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
