//! Pure, non-owning stable-compaction plan for one ended-stream queue.
//!
//! This leaf deliberately knows no Client, allocator, callback, quarantine, permit, or receipt.
//! It turns an already-validated target map plus scalar totals into a pointer-free plan. The later
//! owning transaction must revalidate its own authority before it mutates a queue.

const std = @import("std");

pub const max_supported_items: usize = 4096;

/// Scalar evidence copied from the sealed preparation. This DTO deliberately carries no seal:
/// the owning b3b transaction must validate that authority before and after using this plan.
pub const QueueInput = struct {
    source_count: usize,
    claimed_target_count: usize,
    source_bytes: usize,
    target_bytes: usize,
};

/// Checked result only; none of these values can release memory or identify a queue owner.
pub const QueueScalars = struct {
    source_count: usize,
    target_count: usize,
    survivor_count: usize,
    source_bytes: usize,
    target_bytes: usize,
    survivor_bytes: usize,

    const zero: QueueScalars = .{
        .source_count = 0,
        .target_count = 0,
        .survivor_count = 0,
        .source_bytes = 0,
        .target_bytes = 0,
        .survivor_bytes = 0,
    };
};

/// Raw state makes callback-corrupted preparation safe to inspect in ReleaseFast. A tagged union
/// would require interpreting an untrusted tag before the finalizer could reject it.
pub const QueuePlan = struct {
    pub const pristine_state: u8 = 0;
    pub const planned_state: u8 = 1;

    state: u8 = pristine_state,
    scalars: QueueScalars = .zero,

    pub fn isPristine(self: QueuePlan) bool {
        return self.state == pristine_state;
    }

    /// Validates only the raw publication state. The owning caller must still dry-run a
    /// `DispositionCursor` against the sealed target map before trusting these scalars.
    pub fn rawPlannedScalars(self: QueuePlan) PlanError!QueueScalars {
        if (self.state != planned_state) return error.InvalidState;
        return self.scalars;
    }
};

pub const PlanError = error{
    InvalidCount,
    InvalidTargetMap,
    ArithmeticOverflow,
    DestinationOccupied,
    InvalidState,
};

/// Stable destination ordinal for one source item. It is an index projection, not an owner handle.
pub const Disposition = union(enum) {
    target: usize,
    survivor: usize,
};

pub const Step = struct {
    source_ordinal: usize,
    disposition: Disposition,
};

/// Validates the active target-map extent and publishes `out` only after every checked subtraction.
pub fn buildQueuePlan(
    comptime max_items: usize,
    targets: *const std.StaticBitSet(max_items),
    input: QueueInput,
    out: *QueuePlan,
) PlanError!void {
    comptime assertSupportedMaximum(max_items);
    if (out.state != QueuePlan.pristine_state) {
        if (out.state != QueuePlan.planned_state) return error.InvalidState;
        return error.DestinationOccupied;
    }
    if (input.source_count > max_items or
        input.claimed_target_count > input.source_count)
        return error.InvalidCount;
    const target_count = try validateTargetMap(
        max_items,
        targets,
        input.source_count,
    );
    if (target_count != input.claimed_target_count)
        return error.InvalidTargetMap;
    const survivor_count = std.math.sub(
        usize,
        input.source_count,
        target_count,
    ) catch return error.ArithmeticOverflow;
    const survivor_bytes = std.math.sub(
        usize,
        input.source_bytes,
        input.target_bytes,
    ) catch return error.ArithmeticOverflow;
    out.* = .{ .state = QueuePlan.planned_state, .scalars = .{
        .source_count = input.source_count,
        .target_count = target_count,
        .survivor_count = survivor_count,
        .source_bytes = input.source_bytes,
        .target_bytes = input.target_bytes,
        .survivor_bytes = survivor_bytes,
    } };
}

fn validateTargetMap(
    comptime max_items: usize,
    targets: *const std.StaticBitSet(max_items),
    source_count: usize,
) PlanError!usize {
    comptime assertSupportedMaximum(max_items);
    if (source_count > max_items) return error.InvalidCount;
    var count: usize = 0;
    for (0..source_count) |index| count += @intFromBool(targets.isSet(index));
    if (targets.count() != count) return error.InvalidTargetMap;
    return count;
}

fn assertSupportedMaximum(comptime max_items: usize) void {
    if (max_items > max_supported_items)
        @compileError("ended purge queue maximum exceeds the supported bound");
}

/// Returns an ephemeral reader over `targets`; the cursor itself is never stored in `QueuePlan`.
pub fn DispositionCursor(comptime max_items: usize) type {
    return struct {
        const Self = @This();

        targets: *const std.StaticBitSet(max_items),
        source_count: usize,
        target_count: usize,
        survivor_count: usize,
        source_ordinal: usize = 0,
        target_ordinal: usize = 0,
        survivor_ordinal: usize = 0,

        pub fn init(
            plan: QueueScalars,
            targets: *const std.StaticBitSet(max_items),
        ) PlanError!Self {
            comptime assertSupportedMaximum(max_items);
            const count = try validateTargetMap(
                max_items,
                targets,
                plan.source_count,
            );
            const projected_count = std.math.add(
                usize,
                plan.target_count,
                plan.survivor_count,
            ) catch return error.ArithmeticOverflow;
            const projected_bytes = std.math.add(
                usize,
                plan.target_bytes,
                plan.survivor_bytes,
            ) catch return error.ArithmeticOverflow;
            if (count != plan.target_count or
                projected_count != plan.source_count or
                projected_bytes != plan.source_bytes)
                return error.InvalidTargetMap;
            return .{
                .targets = targets,
                .source_count = plan.source_count,
                .target_count = plan.target_count,
                .survivor_count = plan.survivor_count,
            };
        }

        /// Fails closed even if an untrusted caller forges the public cursor value.
        pub fn next(self: *Self) PlanError!?Step {
            if (self.source_ordinal == self.source_count) {
                try self.validateComplete();
                return null;
            }
            if (self.source_ordinal > self.source_count or
                self.source_ordinal >= max_items)
                return error.InvalidTargetMap;
            const source_ordinal = self.source_ordinal;
            const next_source_ordinal = std.math.add(
                usize,
                self.source_ordinal,
                1,
            ) catch return error.ArithmeticOverflow;
            if (self.targets.isSet(source_ordinal)) {
                if (self.target_ordinal >= self.target_count)
                    return error.InvalidTargetMap;
                const target_ordinal = self.target_ordinal;
                const next_target_ordinal = std.math.add(
                    usize,
                    self.target_ordinal,
                    1,
                ) catch return error.ArithmeticOverflow;
                self.source_ordinal = next_source_ordinal;
                self.target_ordinal = next_target_ordinal;
                return .{
                    .source_ordinal = source_ordinal,
                    .disposition = .{ .target = target_ordinal },
                };
            }
            if (self.survivor_ordinal >= self.survivor_count)
                return error.InvalidTargetMap;
            const survivor_ordinal = self.survivor_ordinal;
            const next_survivor_ordinal = std.math.add(
                usize,
                self.survivor_ordinal,
                1,
            ) catch return error.ArithmeticOverflow;
            self.source_ordinal = next_source_ordinal;
            self.survivor_ordinal = next_survivor_ordinal;
            return .{
                .source_ordinal = source_ordinal,
                .disposition = .{ .survivor = survivor_ordinal },
            };
        }

        /// Revalidates the complete projection instead of trusting mutable cursor ordinals.
        pub fn validateComplete(self: *const Self) PlanError!void {
            const count = try validateTargetMap(
                max_items,
                self.targets,
                self.source_count,
            );
            const projected_count = std.math.add(
                usize,
                self.target_count,
                self.survivor_count,
            ) catch return error.ArithmeticOverflow;
            if (count != self.target_count or
                projected_count != self.source_count or
                self.source_ordinal != self.source_count or
                self.target_ordinal != self.target_count or
                self.survivor_ordinal != self.survivor_count)
                return error.InvalidTargetMap;
        }
    };
}

fn expectStep(
    cursor: anytype,
    source_ordinal: usize,
    expected: Disposition,
) !void {
    const step = (try cursor.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(source_ordinal, step.source_ordinal);
    try std.testing.expect(std.meta.eql(expected, step.disposition));
}

test "CR3a-2c2b3a empty input publishes a planned empty result" {
    const Bits = std.StaticBitSet(1);
    const targets: Bits = .initEmpty();
    var out: QueuePlan = .{};
    try buildQueuePlan(1, &targets, .{
        .source_count = 0,
        .claimed_target_count = 0,
        .source_bytes = 0,
        .target_bytes = 0,
    }, &out);
    const plan = try out.rawPlannedScalars();
    try std.testing.expectEqual(@as(usize, 0), plan.source_count);
    try std.testing.expectEqual(@as(usize, 0), plan.target_count);
    try std.testing.expectEqual(@as(usize, 0), plan.survivor_count);
    try std.testing.expectEqual(@as(usize, 0), plan.survivor_bytes);
    var cursor = try DispositionCursor(1).init(plan, &targets);
    try std.testing.expectEqual(@as(?Step, null), try cursor.next());
    try cursor.validateComplete();
}

test "CR3a-2c2b3a stable projection covers none all edges and alternating targets" {
    const Bits = std.StaticBitSet(8);
    const inputs = [_]struct {
        targets: Bits,
        claimed: usize,
        target_bytes: usize,
    }{
        .{ .targets = .initEmpty(), .claimed = 0, .target_bytes = 0 },
        .{ .targets = .initFull(), .claimed = 8, .target_bytes = 36 },
        .{ .targets = blk: {
            var bits: Bits = .initEmpty();
            bits.set(0);
            bits.set(3);
            bits.set(7);
            break :blk bits;
        }, .claimed = 3, .target_bytes = 12 },
        .{ .targets = blk: {
            var bits: Bits = .initEmpty();
            inline for (.{ 0, 2, 4, 6 }) |index| bits.set(index);
            break :blk bits;
        }, .claimed = 4, .target_bytes = 16 },
    };
    for (inputs) |input| {
        var out: QueuePlan = .{};
        try buildQueuePlan(8, &input.targets, .{
            .source_count = 8,
            .claimed_target_count = input.claimed,
            .source_bytes = 36,
            .target_bytes = input.target_bytes,
        }, &out);
        const plan = try out.rawPlannedScalars();
        try std.testing.expectEqual(8 - input.claimed, plan.survivor_count);
        try std.testing.expectEqual(36 - input.target_bytes, plan.survivor_bytes);
        var cursor = try DispositionCursor(8).init(plan, &input.targets);
        var target_ordinal: usize = 0;
        var survivor_ordinal: usize = 0;
        for (0..8) |source_ordinal| {
            if (input.targets.isSet(source_ordinal)) {
                try expectStep(&cursor, source_ordinal, .{ .target = target_ordinal });
                target_ordinal += 1;
            } else {
                try expectStep(&cursor, source_ordinal, .{ .survivor = survivor_ordinal });
                survivor_ordinal += 1;
            }
        }
        try std.testing.expectEqual(@as(?Step, null), try cursor.next());
        try cursor.validateComplete();
    }
}

test "CR3a-2c2b3a invalid inputs preserve the pristine destination" {
    const Bits = std.StaticBitSet(4);
    var outside: Bits = .initEmpty();
    outside.set(3);
    const cases = [_]struct {
        bits: Bits,
        input: QueueInput,
        expected: PlanError,
    }{
        .{ .bits = .initEmpty(), .input = .{
            .source_count = 5,
            .claimed_target_count = 0,
            .source_bytes = 0,
            .target_bytes = 0,
        }, .expected = error.InvalidCount },
        .{ .bits = .initEmpty(), .input = .{
            .source_count = 3,
            .claimed_target_count = 4,
            .source_bytes = 0,
            .target_bytes = 0,
        }, .expected = error.InvalidCount },
        .{ .bits = outside, .input = .{
            .source_count = 3,
            .claimed_target_count = 1,
            .source_bytes = 3,
            .target_bytes = 1,
        }, .expected = error.InvalidTargetMap },
        .{ .bits = .initEmpty(), .input = .{
            .source_count = 4,
            .claimed_target_count = 1,
            .source_bytes = 4,
            .target_bytes = 1,
        }, .expected = error.InvalidTargetMap },
        .{ .bits = .initEmpty(), .input = .{
            .source_count = 4,
            .claimed_target_count = 0,
            .source_bytes = 3,
            .target_bytes = 4,
        }, .expected = error.ArithmeticOverflow },
    };
    for (cases) |case| {
        var out: QueuePlan = .{};
        try std.testing.expectError(
            case.expected,
            buildQueuePlan(4, &case.bits, case.input, &out),
        );
        try std.testing.expect(out.isPristine());
    }
}

test "CR3a-2c2b3a occupied destination rejects without replacement" {
    const Bits = std.StaticBitSet(1);
    const targets: Bits = .initEmpty();
    const original = QueueScalars{
        .source_count = 1,
        .target_count = 0,
        .survivor_count = 1,
        .source_bytes = 7,
        .target_bytes = 0,
        .survivor_bytes = 7,
    };
    var out: QueuePlan = .{ .state = QueuePlan.planned_state, .scalars = original };
    try std.testing.expectError(error.DestinationOccupied, buildQueuePlan(
        1,
        &targets,
        .{ .source_count = 0, .claimed_target_count = 0, .source_bytes = 0, .target_bytes = 0 },
        &out,
    ));
    try std.testing.expect(std.meta.eql(original, try out.rawPlannedScalars()));
}

test "CR3a-2c2b3a maximum target map is linear and deterministic" {
    const max_items = 4096;
    const Bits = std.StaticBitSet(max_items);
    const targets: Bits = .initFull();
    var first: QueuePlan = .{};
    var second: QueuePlan = .{};
    const input: QueueInput = .{
        .source_count = max_items,
        .claimed_target_count = max_items,
        .source_bytes = max_items,
        .target_bytes = max_items,
    };
    try buildQueuePlan(max_items, &targets, input, &first);
    try buildQueuePlan(max_items, &targets, input, &second);
    try std.testing.expect(std.meta.eql(first, second));

    var left = try DispositionCursor(max_items).init(try first.rawPlannedScalars(), &targets);
    var right = left;
    for (0..max_items) |source_ordinal| {
        const expected: Disposition = .{ .target = source_ordinal };
        try expectStep(&left, source_ordinal, expected);
        try expectStep(&right, source_ordinal, expected);
    }
    try std.testing.expectEqual(@as(?Step, null), try left.next());
    try std.testing.expectEqual(@as(?Step, null), try right.next());
    try left.validateComplete();
    try right.validateComplete();
}

test "CR3a-2c2b3a forged cursor arithmetic overflow is rejected" {
    const Bits = std.StaticBitSet(1);
    const targets: Bits = .initEmpty();
    const count_overflow = QueueScalars{
        .source_count = 1,
        .target_count = std.math.maxInt(usize),
        .survivor_count = 1,
        .source_bytes = 0,
        .target_bytes = 0,
        .survivor_bytes = 0,
    };
    try std.testing.expectError(
        error.ArithmeticOverflow,
        DispositionCursor(1).init(count_overflow, &targets),
    );
    const byte_overflow = QueueScalars{
        .source_count = 0,
        .target_count = 0,
        .survivor_count = 0,
        .source_bytes = 1,
        .target_bytes = std.math.maxInt(usize),
        .survivor_bytes = 1,
    };
    try std.testing.expectError(
        error.ArithmeticOverflow,
        DispositionCursor(1).init(byte_overflow, &targets),
    );
}

test "CR3a-2c2b3a forged cursor state fails closed before indexing or wrapping" {
    const Bits = std.StaticBitSet(1);
    const targets: Bits = .initEmpty();
    const Cursor = DispositionCursor(1);
    var past_end = Cursor{
        .targets = &targets,
        .source_count = 0,
        .target_count = 0,
        .survivor_count = 0,
        .source_ordinal = 1,
    };
    try std.testing.expectError(error.InvalidTargetMap, past_end.next());

    var wrapped_survivor = Cursor{
        .targets = &targets,
        .source_count = 1,
        .target_count = 0,
        .survivor_count = 1,
        .survivor_ordinal = std.math.maxInt(usize),
    };
    try std.testing.expectError(error.InvalidTargetMap, wrapped_survivor.next());
    try std.testing.expectEqual(@as(usize, 0), wrapped_survivor.source_ordinal);

    var forged_complete = Cursor{
        .targets = &targets,
        .source_count = 1,
        .target_count = 0,
        .survivor_count = 0,
        .source_ordinal = 1,
    };
    try std.testing.expectError(error.InvalidTargetMap, forged_complete.next());

    var over_cap_complete = Cursor{
        .targets = &targets,
        .source_count = 2,
        .target_count = 0,
        .survivor_count = 0,
        .source_ordinal = 2,
    };
    try std.testing.expectError(error.InvalidCount, over_cap_complete.next());
}

test "CR3a-2c2b3a validation error precedence is deterministic" {
    const Bits = std.StaticBitSet(2);
    var outside: Bits = .initEmpty();
    outside.set(1);
    var occupied: QueuePlan = .{ .state = QueuePlan.planned_state, .scalars = .{
        .source_count = 0,
        .target_count = 0,
        .survivor_count = 0,
        .source_bytes = 0,
        .target_bytes = 0,
        .survivor_bytes = 0,
    } };
    try std.testing.expectError(error.DestinationOccupied, buildQueuePlan(
        2,
        &outside,
        .{ .source_count = 3, .claimed_target_count = 3, .source_bytes = 0, .target_bytes = 1 },
        &occupied,
    ));
    var out: QueuePlan = .{};
    try std.testing.expectError(error.InvalidCount, buildQueuePlan(
        2,
        &outside,
        .{ .source_count = 3, .claimed_target_count = 3, .source_bytes = 0, .target_bytes = 1 },
        &out,
    ));
    try std.testing.expectError(error.InvalidTargetMap, buildQueuePlan(
        2,
        &outside,
        .{ .source_count = 1, .claimed_target_count = 1, .source_bytes = 0, .target_bytes = 1 },
        &out,
    ));
    const empty: Bits = .initEmpty();
    try std.testing.expectError(error.ArithmeticOverflow, buildQueuePlan(
        2,
        &empty,
        .{ .source_count = 1, .claimed_target_count = 0, .source_bytes = 0, .target_bytes = 1 },
        &out,
    ));
}

test "CR3a-2c2b3a unknown raw plan states fail before scalar interpretation" {
    var state: u16 = 0;
    while (state <= std.math.maxInt(u8)) : (state += 1) {
        const raw: u8 = @intCast(state);
        if (raw == QueuePlan.planned_state) continue;
        const plan = QueuePlan{
            .state = raw,
            .scalars = .{
                .source_count = std.math.maxInt(usize),
                .target_count = std.math.maxInt(usize),
                .survivor_count = std.math.maxInt(usize),
                .source_bytes = std.math.maxInt(usize),
                .target_bytes = std.math.maxInt(usize),
                .survivor_bytes = std.math.maxInt(usize),
            },
        };
        try std.testing.expectError(error.InvalidState, plan.rawPlannedScalars());
    }

    const targets = std.StaticBitSet(1).initEmpty();
    var destination = QueuePlan{ .state = 2 };
    try std.testing.expectError(error.InvalidState, buildQueuePlan(
        1,
        &targets,
        .{ .source_count = 0, .claimed_target_count = 0, .source_bytes = 0, .target_bytes = 0 },
        &destination,
    ));
    try std.testing.expectEqual(@as(u8, 2), destination.state);
}

fn typeContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| typeContainsPointer(array.child),
        .optional => |optional| typeContainsPointer(optional.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (typeContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (typeContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "CR3a-2c2b3a published plan DTOs contain no pointer authority" {
    try std.testing.expect(!typeContainsPointer(QueueInput));
    try std.testing.expect(!typeContainsPointer(QueueScalars));
    try std.testing.expect(!typeContainsPointer(QueuePlan));
    try std.testing.expect(!typeContainsPointer(Disposition));
    try std.testing.expect(!typeContainsPointer(Step));
}
