//! Runtime-owned source-change token for P4 E3b.
//!
//! The sampler owns no terminal, stream, allocator, or wire revision. Its only job is to fold one
//! bounded runtime source projection into a checked token. A connection may use that token as a
//! delivery gate, but it cannot mutate this owner.

const std = @import("std");

pub const Token = struct {
    incarnation: u64,
    revision: u64,
};

pub const Source = struct {
    observer_generation: u64,
    title_generation: u32,
    foreground_generation: u64,
    cwd_generation: u64,
};

pub const Outcome = enum {
    stale,
    unchanged,
    changed,
};

pub const Record = struct {
    token: Token = .{ .incarnation = 1, .revision = 1 },
    source: Source,
    last_epoch_ns: u64,
    terminal: bool = false,

    pub fn init(source: Source, epoch_ns: u64) Record {
        return .{ .source = source, .last_epoch_ns = epoch_ns };
    }

    pub fn sample(
        self: *Record,
        source: Source,
        epoch_ns: u64,
    ) error{TokenExhausted}!Outcome {
        if (self.terminal) return error.TokenExhausted;
        if (epoch_ns < self.last_epoch_ns) return .stale;
        if (std.meta.eql(self.source, source)) {
            self.last_epoch_ns = epoch_ns;
            return .unchanged;
        }
        const next = advance(self.token) catch return error.TokenExhausted;
        self.source = source;
        self.token = next;
        self.last_epoch_ns = epoch_ns;
        return .changed;
    }

    fn advance(current: Token) error{TokenExhausted}!Token {
        return .{
            .incarnation = current.incarnation,
            .revision = std.math.add(u64, current.revision, 1) catch return .{
                .incarnation = std.math.add(u64, current.incarnation, 1) catch
                    return error.TokenExhausted,
                .revision = 1,
            },
        };
    }
};

fn testSource(observer: u64, title: u32, foreground_generation: u64, cwd_generation: u64) Source {
    return .{
        .observer_generation = observer,
        .title_generation = title,
        .foreground_generation = foreground_generation,
        .cwd_generation = cwd_generation,
    };
}

test "P4 E3b sampler is runtime-scoped, stale-safe, and checked across rollover" {
    var record = Record.init(testSource(1, 2, 3, 4), 100);
    try std.testing.expectEqual(Token{ .incarnation = 1, .revision = 1 }, record.token);
    try std.testing.expectEqual(Outcome.unchanged, try record.sample(testSource(1, 2, 3, 4), 101));
    try std.testing.expectEqual(Outcome.stale, try record.sample(testSource(9, 9, 9, 9), 100));
    try std.testing.expectEqual(Token{ .incarnation = 1, .revision = 1 }, record.token);

    try std.testing.expectEqual(Outcome.changed, try record.sample(testSource(2, 2, 3, 4), 101));
    try std.testing.expectEqual(Token{ .incarnation = 1, .revision = 2 }, record.token);

    try std.testing.expectEqual(Outcome.changed, try record.sample(testSource(2, 2, 3, 5), 102));
    try std.testing.expectEqual(Token{ .incarnation = 1, .revision = 3 }, record.token);

    record.token = .{ .incarnation = 4, .revision = std.math.maxInt(u64) };
    try std.testing.expectEqual(Outcome.changed, try record.sample(testSource(2, 3, 3, 5), 103));
    try std.testing.expectEqual(Token{ .incarnation = 5, .revision = 1 }, record.token);

    record.token = .{ .incarnation = std.math.maxInt(u64), .revision = std.math.maxInt(u64) };
    const before = record;
    try std.testing.expectError(error.TokenExhausted, record.sample(testSource(2, 3, 4, 5), 104));
    try std.testing.expectEqualDeep(before, record);
}

test "K2 cwd generation alone advances the runtime metadata token" {
    var record = Record.init(testSource(1, 2, 3, 4), 100);
    try std.testing.expectEqual(Outcome.changed, try record.sample(testSource(1, 2, 3, 5), 101));
    try std.testing.expectEqual(Token{ .incarnation = 1, .revision = 2 }, record.token);
    try std.testing.expectEqual(Outcome.unchanged, try record.sample(testSource(1, 2, 3, 5), 102));
}
