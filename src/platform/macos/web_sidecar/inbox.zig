//! maru → sidecar 명령을 그리기와 독립으로 받는다(W1b, docs/plans/web-osr-backend.md C2).
//!
//! 읽기 스레드가 명령 fd 를 막힘 읽기로 기다렸다가 바이트를 상자에 넣고 CEF UI 스레드에 task 를 올린다. UI 스레드는
//! task 에서 상자를 비워 decode 한다. 16ms 폴링은 정적 페이지 유휴에도 CPU 0.3~0.4 % 를 썼고(실측), PoC 처럼 그리기
//! 콜백에서 읽으면 숨긴 탭에 「다시 보여라」조차 못 전했다(§13.1 「남은 미해결」 3).

const std = @import("std");

/// 대기 바이트 상한. maru 의 명령은 작아서 UI 스레드가 이만큼 밀리면 이미 고장이다 — 넘치면 채널을 닫는다.
pub const capacity: usize = 1024 * 1024;

pub const Taken = struct {
    len: usize,
    /// 명령 fd 가 닫혔다(EOF — maru 가 사라졌다) 또는 읽기 오류.
    closed: bool,
    overflow: bool,
};

pub const Inbox = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    closed: bool = false,
    overflow: bool = false,

    pub fn push(self: *Inbox, data: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (data.len > capacity - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn close(self: *Inbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
    }

    /// 쌓인 바이트를 `out` 으로 옮긴다(앞에서부터, `out` 크기만큼).
    pub fn take(self: *Inbox, out: []u8) Taken {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.bytes[0..n]);
        std.mem.copyForwards(u8, self.bytes[0 .. self.len - n], self.bytes[n..self.len]);
        self.len -= n;
        return .{ .len = n, .closed = self.closed and self.len == 0, .overflow = self.overflow };
    }
};

/// 읽기 스레드 본문. `wake` 는 바이트가 들어오거나 fd 가 닫힐 때마다 부른다(CEF UI 스레드에 task 를 올린다).
pub fn readLoop(fd: c_int, inbox: *Inbox, wake: *const fn () void) void {
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n > 0) {
            inbox.push(chunk[0..@intCast(n)]);
            wake();
        } else if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {
            continue;
        } else {
            inbox.close();
            wake();
            return;
        }
    }
}

test "take drains in order, reports close only after the last byte" {
    var inbox: Inbox = .{ .io = std.testing.io };
    inbox.push("abc");
    inbox.push("de");
    inbox.close();
    var out: [4]u8 = undefined;
    const first = inbox.take(&out);
    try std.testing.expectEqual(@as(usize, 4), first.len);
    try std.testing.expectEqualStrings("abcd", out[0..4]);
    try std.testing.expect(!first.closed);
    const second = inbox.take(&out);
    try std.testing.expectEqualStrings("e", out[0..second.len]);
    try std.testing.expect(second.closed);
}

test "push beyond capacity marks overflow instead of dropping silently" {
    const inbox = try std.testing.allocator.create(Inbox);
    defer std.testing.allocator.destroy(inbox);
    inbox.* = .{ .io = std.testing.io };
    const big = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(big);
    inbox.push(big);
    inbox.push("x");
    var out: [1]u8 = undefined;
    try std.testing.expect(inbox.take(&out).overflow);
}
