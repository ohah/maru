//! 한 upgrade attempt의 모든 단계가 공유하는 absolute monotonic deadline.
//!
//! 각 하위 단계가 자기 budget을 새로 시작하면 전체 pause 상한이 단계 수만큼 늘어난다. Coordinator는 marker를
//! 소비할 때 하나를 만들고 quiesce/store/preflight/exec 직전까지 같은 값을 복사해 전달한다.

const std = @import("std");

pub const Error = error{InvalidBudget};

pub const Source = struct {
    ctx: *anyopaque,
    now_ns: *const fn (ctx: *anyopaque) i128,
};

const Clock = union(enum) {
    io: std.Io,
    injected: Source,
};

pub const Deadline = struct {
    clock: Clock,
    expires_at_ns: i128,

    pub fn after(io: std.Io, budget_ns: i128) Error!Deadline {
        if (budget_ns <= 0) return error.InvalidBudget;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        return .{
            .clock = .{ .io = io },
            .expires_at_ns = std.math.add(i128, now, budget_ns) catch return error.InvalidBudget,
        };
    }

    pub fn fromInjected(source: Source, expires_at_ns: i128) Deadline {
        return .{ .clock = .{ .injected = source }, .expires_at_ns = expires_at_ns };
    }

    /// Same-PID exec handoff record에 저장한 absolute monotonic expiry를 새
    /// image의 같은 awake clock에 다시 연결한다. 각 단계가 새 5초 budget을
    /// 시작하지 않게 하는 제품 restore 전용 constructor다.
    pub fn fromAbsolute(io: std.Io, expires_at_ns: i128) Error!Deadline {
        if (expires_at_ns <= 0) return error.InvalidBudget;
        return .{ .clock = .{ .io = io }, .expires_at_ns = expires_at_ns };
    }

    pub fn expiresAtNs(self: Deadline) i128 {
        return self.expires_at_ns;
    }

    pub fn testingNever() Deadline {
        if (!@import("builtin").is_test) @compileError("non-expiring upgrade deadline is test-only");
        return fromInjected(.{
            .ctx = @ptrFromInt(1),
            .now_ns = struct {
                fn now(_: *anyopaque) i128 {
                    return 0;
                }
            }.now,
        }, std.math.maxInt(i128));
    }

    pub fn nowNs(self: Deadline) i128 {
        return switch (self.clock) {
            .io => |io| std.Io.Clock.awake.now(io).nanoseconds,
            .injected => |source| source.now_ns(source.ctx),
        };
    }

    pub fn expired(self: Deadline) bool {
        return self.nowNs() >= self.expires_at_ns;
    }

    pub fn remainingNs(self: Deadline) i128 {
        const now = self.nowNs();
        if (now >= self.expires_at_ns) return 0;
        return std.math.sub(i128, self.expires_at_ns, now) catch std.math.maxInt(i128);
    }
};

test "upgrade deadline uses one absolute expiry across copied consumers" {
    const FakeClock = struct {
        now: i128,

        fn read(ctx: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.now;
        }
    };
    var fake: FakeClock = .{ .now = 100 };
    const deadline = Deadline.fromInjected(.{ .ctx = &fake, .now_ns = FakeClock.read }, 150);
    const copied = deadline;
    try std.testing.expectEqual(@as(i128, 50), deadline.remainingNs());
    fake.now = 149;
    try std.testing.expect(!deadline.expired());
    try std.testing.expectEqual(@as(i128, 1), copied.remainingNs());
    fake.now = 150;
    try std.testing.expect(deadline.expired());
    try std.testing.expect(copied.expired());
}

test "upgrade deadline restores the exact absolute expiry" {
    const deadline = try Deadline.fromAbsolute(std.testing.io, 123);
    try std.testing.expectEqual(@as(i128, 123), deadline.expiresAtNs());
}
