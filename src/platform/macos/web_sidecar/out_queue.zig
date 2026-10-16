//! sidecar → maru 알림의 보내는 줄(W9d② — docs/plans/web-osr-backend.md 「W9d② 결정」, J7). CEF 를 모른다.
//!
//! 왜: 예전 쓰기(`events.Writer.send`)는 UI 스레드에서 막히는 `write` 였다. maru 가 잠시 읽지 않으면 관(64 KiB)이 차고 UI 스레드가 그동안
//! 통째로 섰다 — J7 실측: 16 KiB frame 셋(48 KiB) 뒤에 멈춘 읽는 쪽이 멈춘 만큼(3.0 s·1.0 s) 모든 탭의 UI 일이 멈췄다. 본문 기록은 큰 frame 을
//! 많이 보내므로 그대로 두면 maru 의 짧은 멈춤이 sidecar 전체를 세운다. 그래서 frame 을 이 줄에 넣고 **쓰는 스레드** 하나가 관에 쓴다:
//!   - 보통 frame(제어·알림)은 줄이 꽉 찰 때만(`capacity` — 8 MiB) 기다린다(예전보다 늘 덜 막힌다 — 같은 차례를 지킨다).
//!   - 본문 frame 은 본문 하나를 통째로 먼저 잡는다(`reserveBody` — 본문 몫 `body_capacity` 2 MiB 와 줄 전체 안). 자리가 없으면 거짓 — 부른
//!     쪽은 기다리지 않고 그 본문을 `busy` 로 끝낸다. 그래서 본문은 UI 스레드를 세우지 않고, 본문이 줄을 다 채워 제어 frame 을 막지도 않는다.
//!   - 차례는 한 줄이라 그대로다(`devtools_result_data` 앞의 `devtools_result`, 본문 조각 앞의 끝 같은 뒤바뀜이 없다).
//! 쓰는 스레드가 관이 닫힌 것을 보면(EPIPE) 줄을 비우고 닫힘을 기억한다 — 그 뒤의 넣기는 곧 `ChannelClosed`.
//!
//! 시험이 증명하는 것: 차례, 본문 몫(넘으면 거절 — 막지 않는다), 잡은 몫 안에서만 본문 frame, 줄이 꽉 차면 보통 frame 은 기다린다,
//! 멈춘 읽는 쪽 앞에서 본문 넣기는 곧 돌아온다(실제 pipe·스레드), 닫힌 관.

const std = @import("std");

/// 줄 전체의 바이트 상한.
pub const capacity: usize = 8 * 1024 * 1024;
/// 본문 frame 이 쓸 수 있는 몫(잡은 것 + 넣었으나 아직 쓰지 않은 것).
pub const body_capacity: usize = 2 * 1024 * 1024;

pub const Class = enum { control, body };

pub const Error = error{ChannelClosed};

const Frame = struct {
    class: Class,
    bytes: []u8,
};

pub const Queue = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    /// 넣을 자리가 났다·쓸 것이 생겼다.
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    frames: std.Deque(Frame) = .empty,
    /// 줄에 있는 바이트(쓰는 중인 frame 포함).
    used: usize = 0,
    /// 줄에 있는 본문 바이트와 잡아 둔(아직 넣지 않은) 본문 바이트.
    body_used: usize = 0,
    body_reserved: usize = 0,
    closed: bool = false,
    stopping: bool = false,
    /// 시험·관측: 본문 몫이 없어 거절한 수.
    body_refused: u64 = 0,

    fn lock(self: *Queue) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Queue) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// 본문 하나(`bytes` — 그 본문의 frame 들의 합)를 넣을 자리를 잡는다. 없으면 거짓(기다리지 않는다).
    pub fn reserveBody(self: *Queue, bytes: usize) bool {
        self.lock();
        defer self.unlock();
        if (self.closed) return false;
        if (self.body_used + self.body_reserved + bytes > body_capacity or self.used + self.body_reserved + bytes > capacity) {
            self.body_refused += 1;
            return false;
        }
        self.body_reserved += bytes;
        return true;
    }

    /// 잡은 몫 중 쓰지 않은 것을 돌려준다(본문을 다 넣었거나 그만뒀다).
    pub fn releaseBody(self: *Queue, bytes: usize) void {
        self.lock();
        defer self.unlock();
        self.body_reserved -|= bytes;
    }

    /// frame 하나를 넣는다(바이트를 복사한다). 본문 frame 은 잡은 몫에서 쓴다(몫이 모자라면 거짓 — 부른 쪽의 잘못이라 넣지 않는다). 보통
    /// frame 은 줄이 꽉 차 있으면 자리가 날 때까지 기다린다.
    pub fn push(self: *Queue, gpa: std.mem.Allocator, class: Class, bytes: []const u8) (Error || std.mem.Allocator.Error)!bool {
        const copy = try gpa.dupe(u8, bytes);
        errdefer gpa.free(copy);
        self.lock();
        defer self.unlock();
        if (self.closed) return error.ChannelClosed; // `copy` 는 errdefer 가 푼다
        switch (class) {
            .body => {
                if (self.body_reserved < bytes.len) {
                    gpa.free(copy);
                    return false;
                }
                self.body_reserved -= bytes.len;
                self.body_used += bytes.len;
            },
            .control => {
                // 잡아 둔 본문 몫까지 넣어 셈한다 — 본문이 다 들어올 자리를 보통 frame 이 빼앗지 않게.
                while (!self.closed and self.used > 0 and self.used + self.body_reserved + bytes.len > capacity) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
                if (self.closed) return error.ChannelClosed;
            },
        }
        self.frames.pushBack(gpa, .{ .class = class, .bytes = copy }) catch |e| {
            if (class == .body) self.body_used -= bytes.len;
            return e;
        };
        self.used += bytes.len;
        _ = std.c.pthread_cond_broadcast(&self.cond);
        return true;
    }

    /// 쓰는 스레드: 다음 frame 을 기다려 꺼낸다(줄에서는 쓴 뒤에 `done` 으로 뺀다 — 쓰는 동안도 바이트를 센다). 멈추라면 null.
    fn next(self: *Queue) ?Frame {
        self.lock();
        defer self.unlock();
        while (self.frames.len == 0 and !self.stopping and !self.closed) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        if (self.closed) return null;
        return self.frames.front();
    }

    fn done(self: *Queue, gpa: std.mem.Allocator, f: Frame) void {
        self.lock();
        defer self.unlock();
        _ = self.frames.popFront();
        self.used -= f.bytes.len;
        if (f.class == .body) self.body_used -= f.bytes.len;
        gpa.free(f.bytes);
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    /// 관이 닫혔다 — 남은 것을 버리고 기다리는 넣기를 깨운다.
    fn close(self: *Queue, gpa: std.mem.Allocator) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
        while (self.frames.popFront()) |f| gpa.free(f.bytes);
        self.frames.deinit(gpa);
        self.frames = .empty;
        self.used = 0;
        self.body_used = 0;
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    /// 쓰는 스레드 본문 — `fd` 에 차례로 쓴다. 관이 닫히면(EPIPE 등) 줄을 닫고 끝난다. `stop` 뒤에는 남은 것을 다 쓰고 끝난다.
    pub fn run(self: *Queue, gpa: std.mem.Allocator, fd: c_int) void {
        while (true) {
            const f = self.next() orelse return;
            var sent: usize = 0;
            var ok = true;
            while (sent < f.bytes.len) {
                const n = std.c.write(fd, f.bytes[sent..].ptr, f.bytes.len - sent);
                if (n > 0) {
                    sent += @intCast(n);
                } else if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) {
                    continue;
                } else {
                    ok = false;
                    break;
                }
            }
            if (!ok) return self.close(gpa);
            self.done(gpa, f);
            self.lock();
            const finished = self.stopping and self.frames.len == 0;
            self.unlock();
            if (finished) return;
        }
    }

    /// 쓰는 스레드를 깨워 남은 것을 다 쓰고 끝나게 한다.
    pub fn stop(self: *Queue) void {
        self.lock();
        defer self.unlock();
        self.stopping = true;
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    /// 줄이 빌 때까지(또는 닫힐 때까지) 기다린다 — 끝내기 전에(마지막 알림이 maru 에 닿게). `timeout_ms` 가 지나면 그만 기다린다.
    pub fn drain(self: *Queue, timeout_ms: u32) void {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 10) {
            self.lock();
            const empty = self.frames.len == 0 or self.closed;
            self.unlock();
            if (empty) return;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        while (self.frames.popFront()) |f| gpa.free(f.bytes);
        self.frames.deinit(gpa);
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
extern "c" fn signal(sig: c_int, handler: usize) usize;

fn pipePair() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

test "W9d②: 보내는 줄 — 차례를 지키고, 본문은 잡은 몫 안에서만, 본문 몫(2 MiB)을 넘으면 거절한다(기다리지 않는다)" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);
    try testing.expect(try q.push(testing.allocator, .control, "a"));
    try testing.expect(!(try q.push(testing.allocator, .body, "body-without-reserve")));
    try testing.expect(q.reserveBody(6));
    try testing.expect(try q.push(testing.allocator, .body, "bb"));
    try testing.expect(try q.push(testing.allocator, .control, "c"));
    try testing.expect(try q.push(testing.allocator, .body, "dddd"));
    try testing.expect(!(try q.push(testing.allocator, .body, "e"))); // 몫을 다 썼다
    var order: [4]u8 = undefined;
    var i: usize = 0;
    while (q.frames.len > 0) : (i += 1) {
        const f = q.frames.front().?;
        order[i] = f.bytes[0];
        q.done(testing.allocator, f);
    }
    try testing.expectEqualStrings("abcd", order[0..i]);
    try testing.expectEqual(@as(usize, 0), q.used);
    try testing.expectEqual(@as(usize, 0), q.body_used);
    // 본문 몫: 잡은 것 + 줄에 있는 것이 2 MiB 를 넘으면 거절.
    try testing.expect(q.reserveBody(body_capacity - 10));
    try testing.expect(!q.reserveBody(11));
    try testing.expect(q.reserveBody(10));
    q.releaseBody(body_capacity);
    try testing.expectEqual(@as(usize, 0), q.body_reserved);
    try testing.expectEqual(@as(u64, 1), q.body_refused);
}

test "W9d②: 멈춘 읽는 쪽 앞에서도 본문 넣기는 곧 돌아온다 — 쓰는 스레드가 막히고 UI 쪽은 거절(busy)로 안다, 읽기 시작하면 차례대로 다 닿는다" {
    const fds = try pipePair();
    defer _ = std.c.close(fds[0]);
    var q: Queue = .{};
    const gpa = std.heap.c_allocator;
    const t = try std.Thread.spawn(.{}, Queue.run, .{ &q, gpa, fds[1] });
    var chunk: [16 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    // 읽지 않는 관(64 KiB)에 본문 frame 을 2 MiB 넘게 — 막히지 않고 몫이 차면 거절.
    var t0: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t0);
    var pushed: usize = 0;
    var refused = false;
    for (0..200) |_| {
        if (!q.reserveBody(chunk.len)) {
            refused = true;
            break;
        }
        _ = try q.push(gpa, .body, &chunk);
        pushed += 1;
    }
    var t1: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t1);
    const ms = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
    try testing.expect(refused);
    try testing.expect(pushed * chunk.len <= body_capacity + 64 * 1024 + chunk.len);
    try testing.expect(ms < 500); // 예전 막히는 쓰기는 읽는 쪽이 멈춘 만큼 섰다(J7)
    // 보통 frame 은 그래도 넣을 수 있다(본문이 줄을 다 쓰지 않는다).
    try testing.expect(try q.push(gpa, .control, "END"));
    // 이제 읽는다 — 차례대로 다 닿고 마지막이 END.
    var total: usize = 0;
    var tail: [3]u8 = undefined;
    const want = pushed * chunk.len + 3;
    var buf: [64 * 1024]u8 = undefined;
    while (total < want) {
        const n = std.c.read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        const got: usize = @intCast(n);
        if (got >= 3) @memcpy(&tail, buf[got - 3 .. got]);
        total += got;
    }
    try testing.expectEqual(want, total);
    try testing.expectEqualStrings("END", &tail);
    q.stop();
    t.join();
    _ = std.c.close(fds[1]);
    q.deinit(gpa);
}

test "W9d②: 관이 닫히면 쓰는 스레드가 줄을 닫는다 — 그 뒤 넣기는 곧 ChannelClosed, 본문 몫도 잡히지 않는다" {
    _ = signal(13, 1); // SIGPIPE 무시 — sidecar 도 시작할 때 그렇게 둔다(`stdio.take`), 그래야 쓰기 오류로 안다
    const fds = try pipePair();
    _ = std.c.close(fds[0]);
    var q: Queue = .{};
    const gpa = std.heap.c_allocator;
    const t = try std.Thread.spawn(.{}, Queue.run, .{ &q, gpa, fds[1] });
    _ = try q.push(gpa, .control, "x"); // 읽는 쪽이 닫힌 관 — EPIPE
    t.join();
    try testing.expectError(error.ChannelClosed, q.push(gpa, .control, "y"));
    try testing.expect(!q.reserveBody(1));
    _ = std.c.close(fds[1]);
    q.deinit(gpa);
}

test "W9d②: 줄이 꽉 차면 보통 frame 은 자리가 날 때까지 기다린다(버리지 않는다)" {
    var q: Queue = .{};
    const gpa = std.heap.c_allocator;
    defer q.deinit(gpa);
    const big = try gpa.alloc(u8, capacity);
    defer gpa.free(big);
    @memset(big, 'y');
    try testing.expect(try q.push(gpa, .control, big)); // 빈 줄에는 상한보다 큰 것도 넣는다(쓰는 스레드가 다 쓴다)
    const Waiter = struct {
        fn go(qq: *Queue) void {
            _ = qq.push(std.heap.c_allocator, .control, "late") catch {};
        }
    };
    const w = try std.Thread.spawn(.{}, Waiter.go, .{&q});
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
    q.lock();
    const waiting = q.frames.len == 1;
    q.unlock();
    try testing.expect(waiting); // 아직 들어가지 못했다
    const f = q.frames.front().?;
    q.done(gpa, f); // 자리가 났다
    w.join();
    try testing.expectEqual(@as(usize, 1), q.frames.len);
    try testing.expectEqualStrings("late", q.frames.front().?.bytes);
}
