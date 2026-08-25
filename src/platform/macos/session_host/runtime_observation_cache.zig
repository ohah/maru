//! Runtime-global canonical observation cache transaction.
//!
//! The product producer eventually has many subscriptions for one runtime.  A per-subscription
//! core snapshot would repeat locks, process inspection, JSON construction, and allocations for
//! identical state.  This leaf owns only the last canonical bytes and a checked change token; it
//! deliberately knows nothing about sockets, subscription revisions, cadence, or TerminalCore.

const std = @import("std");

pub const Cache = struct {
    allocator: std.mem.Allocator,
    bytes: []u8 = &.{},
    change_token: u64 = 0,
    max_bytes: usize,
    initialized: bool = false,
    prepared_count: u64 = 0,

    pub const View = struct {
        bytes: []const u8,
        change_token: u64,
    };

    pub const Prepared = union(enum) {
        unchanged: Unchanged,
        replacement: Replacement,

        pub const Unchanged = struct {
            owner: *Cache,
            expected_token: u64,
        };

        pub const Replacement = struct {
            owner: *Cache,
            allocator: std.mem.Allocator,
            expected_token: u64,
            next_token: u64,
            bytes: []u8,
        };

        pub fn discard(self: *Prepared) void {
            switch (self.*) {
                .unchanged => |unchanged| unchanged.owner.settlePrepared(),
                .replacement => |replacement| {
                    replacement.allocator.free(replacement.bytes);
                    replacement.owner.settlePrepared();
                },
            }
            self.* = undefined;
        }
    };

    pub const InitError = error{InvalidLimit};
    pub const PrepareError = error{ CandidateTooLarge, ChangeTokenExhausted, TooManyPrepared, OutOfMemory };
    pub const CommitError = error{ WrongOwner, StalePrepared };
    pub const DeinitError = error{PreparedOutstanding};

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) InitError!Cache {
        if (max_bytes == 0) return error.InvalidLimit;
        return .{ .allocator = allocator, .max_bytes = max_bytes };
    }

    pub fn view(self: *const Cache) ?View {
        if (!self.initialized) return null;
        return .{ .bytes = self.bytes, .change_token = self.change_token };
    }

    /// Candidate bytes are caller-owned.  Equal state is allocation-free; changed state is copied
    /// before publication so allocation failure leaves the visible cache byte-for-byte unchanged.
    pub fn prepare(
        self: *Cache,
        candidate: []const u8,
    ) PrepareError!Prepared {
        if (candidate.len > self.max_bytes) return error.CandidateTooLarge;
        const next_prepared_count = std.math.add(u64, self.prepared_count, 1) catch
            return error.TooManyPrepared;
        if (self.initialized and std.mem.eql(u8, self.bytes, candidate)) {
            self.prepared_count = next_prepared_count;
            return .{ .unchanged = .{ .owner = self, .expected_token = self.change_token } };
        }
        const next_token = std.math.add(u64, self.change_token, 1) catch
            return error.ChangeTokenExhausted;
        const owned = self.allocator.dupe(u8, candidate) catch return error.OutOfMemory;
        self.prepared_count = next_prepared_count;
        return .{ .replacement = .{
            .owner = self,
            .allocator = self.allocator,
            .expected_token = self.change_token,
            .next_token = next_token,
            .bytes = owned,
        } };
    }

    /// Only the owner that prepared from the current token may publish.  A stale prepare retains
    /// its allocation for explicit discard, avoiding hidden cleanup or accidental ABA acceptance.
    pub fn commit(
        self: *Cache,
        prepared: *Prepared,
    ) CommitError!bool {
        switch (prepared.*) {
            .unchanged => |unchanged| {
                if (unchanged.owner != self) return error.WrongOwner;
                if (unchanged.expected_token != self.change_token) return error.StalePrepared;
                self.settlePrepared();
                prepared.* = undefined;
                return false;
            },
            .replacement => |*replacement| {
                if (replacement.owner != self) return error.WrongOwner;
                if (replacement.expected_token != self.change_token) return error.StalePrepared;
                const old = self.bytes;
                self.bytes = replacement.bytes;
                self.change_token = replacement.next_token;
                self.initialized = true;
                replacement.bytes = &.{};
                self.settlePrepared();
                prepared.* = undefined;
                self.allocator.free(old);
                return true;
            },
        }
    }

    pub fn deinit(self: *Cache) DeinitError!void {
        if (self.prepared_count != 0) return error.PreparedOutstanding;
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn settlePrepared(self: *Cache) void {
        std.debug.assert(self.prepared_count != 0);
        self.prepared_count -= 1;
    }
};

test "P4 E2a unchanged observation reuses one cache token without allocation" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 1024);
    defer cache.deinit() catch unreachable;
    try std.testing.expect(cache.view() == null);

    var first = try cache.prepare("{\"cwd\":\"/tmp\"}");
    try std.testing.expect(try cache.commit(&first));
    const first_view = cache.view().?;
    try std.testing.expectEqual(@as(u64, 1), first_view.change_token);

    var unchanged = try cache.prepare("{\"cwd\":\"/tmp\"}");
    try std.testing.expect(!try cache.commit(&unchanged));
    try std.testing.expectEqual(first_view.bytes.ptr, cache.view().?.bytes.ptr);
    try std.testing.expectEqual(@as(u64, 1), cache.view().?.change_token);
}

test "P4 E2a replacement publishes bytes and token atomically" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 1024);
    defer cache.deinit() catch unreachable;

    var first = try cache.prepare("old");
    _ = try cache.commit(&first);
    var second = try cache.prepare("new");
    try std.testing.expectEqualStrings("old", cache.view().?.bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.view().?.change_token);
    try std.testing.expect(try cache.commit(&second));
    try std.testing.expectEqualStrings("new", cache.view().?.bytes);
    try std.testing.expectEqual(@as(u64, 2), cache.view().?.change_token);
}

test "P4 E2a stale prepared replacement cannot overwrite a newer publication" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 1024);
    defer cache.deinit() catch unreachable;

    var older = try cache.prepare("older");
    defer older.discard();
    var newer = try cache.prepare("newer");
    _ = try cache.commit(&newer);
    try std.testing.expectError(error.StalePrepared, cache.commit(&older));
    try std.testing.expectEqualStrings("newer", cache.view().?.bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.view().?.change_token);
}

test "P4 E2a invalid limit oversize allocation failure and token exhaustion preserve state" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidLimit, Cache.init(allocator, 0));
    var cache = try Cache.init(allocator, 7);
    defer cache.deinit() catch unreachable;
    var first = try cache.prepare("stable");
    _ = try cache.commit(&first);

    try std.testing.expectError(error.CandidateTooLarge, cache.prepare("12345678"));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_cache = try Cache.init(failing.allocator(), 7);
    defer failing_cache.deinit() catch unreachable;
    try std.testing.expectError(error.OutOfMemory, failing_cache.prepare("changed"));
    try std.testing.expectEqualStrings("stable", cache.view().?.bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.view().?.change_token);

    cache.change_token = std.math.maxInt(u64);
    try std.testing.expectError(error.ChangeTokenExhausted, cache.prepare("changed"));
    try std.testing.expectEqualStrings("stable", cache.view().?.bytes);
    try std.testing.expectEqual(std.math.maxInt(u64), cache.view().?.change_token);
}

test "P4 E2a first empty canonical value is distinct from unpublished state" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 1);
    defer cache.deinit() catch unreachable;
    try std.testing.expect(cache.view() == null);
    var empty = try cache.prepare("");
    try std.testing.expect(try cache.commit(&empty));
    try std.testing.expectEqual(@as(usize, 0), cache.view().?.bytes.len);
    try std.testing.expectEqual(@as(u64, 1), cache.view().?.change_token);
}

test "P4 E2a prepared replacement is bound to one final cache owner" {
    const allocator = std.testing.allocator;
    var source = try Cache.init(allocator, 16);
    defer source.deinit() catch unreachable;
    var foreign = try Cache.init(allocator, 16);
    defer foreign.deinit() catch unreachable;

    var prepared = try source.prepare("source");
    defer prepared.discard();
    try std.testing.expectError(error.WrongOwner, foreign.commit(&prepared));
    try std.testing.expect(source.view() == null);
    try std.testing.expect(foreign.view() == null);

    var source_first = try source.prepare("same");
    _ = try source.commit(&source_first);
    var foreign_first = try foreign.prepare("same");
    _ = try foreign.commit(&foreign_first);
    var unchanged = try source.prepare("same");
    defer unchanged.discard();
    try std.testing.expectError(error.WrongOwner, foreign.commit(&unchanged));
}

test "P4 E2a deinit refuses an outstanding prepared owner until explicit discard" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 16);
    var prepared = try cache.prepare("pending");
    try std.testing.expectError(error.PreparedOutstanding, cache.deinit());
    try std.testing.expect(cache.view() == null);
    prepared.discard();
    try cache.deinit();
}
