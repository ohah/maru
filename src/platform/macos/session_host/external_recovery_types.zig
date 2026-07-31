//! Pointer-free recovery authority shared by the pure pump policy, inbox ledger, and consumers.
//!
//! A recovery key crosses an ownership release boundary, so addresses cannot be its authority.
//! The process-unique owner incarnation prevents an old copied key from becoming valid again when
//! a storage object, stream id, epoch, and ledger generation are all reused at the same address.

const std = @import("std");

pub const Origin = enum {
    host,
    client,
};

pub const Intent = union(enum) {
    none,
    host: u64,
    client: u64,

    pub fn key(
        self: Intent,
        owner_incarnation: u64,
        token_generation: u64,
    ) ?Key {
        if (owner_incarnation == 0 or token_generation == 0) return null;
        return switch (self) {
            .none => null,
            .host => |epoch| if (epoch == 0) null else .{
                .owner_incarnation = owner_incarnation,
                .origin = .host,
                .recovery_epoch = epoch,
                .expected_token_generation = token_generation,
            },
            .client => |epoch| if (epoch == 0) null else .{
                .owner_incarnation = owner_incarnation,
                .origin = .client,
                .recovery_epoch = epoch,
                .expected_token_generation = token_generation,
            },
        };
    }
};

pub const Key = struct {
    owner_incarnation: u64,
    origin: Origin,
    recovery_epoch: u64,
    expected_token_generation: u64,

    pub fn isCanonical(self: Key) bool {
        return self.owner_incarnation != 0 and
            self.recovery_epoch != 0 and
            self.expected_token_generation != 0;
    }
};

/// Correlation authority available before a recovery snapshot owns a ledger token.
///
/// `expected_token_generation` deliberately does not belong here: only `borrowLease` can derive
/// that value from an actually committed token. Control admission must never predict the ledger's
/// future generation.
pub const ControlAuthority = struct {
    owner_incarnation: u64,
    origin: Origin,
    recovery_epoch: u64,

    pub fn isCanonical(self: ControlAuthority) bool {
        return self.owner_incarnation != 0 and self.recovery_epoch != 0;
    }
};

pub const MarkResult = enum {
    commit_pending,
    stale_invariant,
};

pub const BatchAuthority = enum {
    ordinary,
    recovery_exact,
    stale_invariant,
};

test "recovery intent projects only canonical incarnation-bound keys" {
    try std.testing.expectEqual(
        @as(?Key, null),
        (@as(Intent, .none)).key(7, 9),
    );
    try std.testing.expectEqual(
        @as(?Key, null),
        (Intent{ .host = 0 }).key(7, 9),
    );
    try std.testing.expectEqual(
        @as(?Key, null),
        (Intent{ .host = 3 }).key(0, 9),
    );
    try std.testing.expectEqual(
        @as(?Key, null),
        (Intent{ .client = 3 }).key(7, 0),
    );

    const host = (Intent{ .host = 3 }).key(7, 9).?;
    try std.testing.expect(host.isCanonical());
    try std.testing.expectEqual(Origin.host, host.origin);
    try std.testing.expectEqual(@as(u64, 7), host.owner_incarnation);
    try std.testing.expectEqual(@as(u64, 3), host.recovery_epoch);
    try std.testing.expectEqual(@as(u64, 9), host.expected_token_generation);
}

test "recovery integration contract excludes the future ledger token generation" {
    const authority = ControlAuthority{
        .owner_incarnation = 7,
        .origin = .client,
        .recovery_epoch = 3,
    };
    try std.testing.expect(authority.isCanonical());
    try std.testing.expectEqual(@as(u64, 7), authority.owner_incarnation);
    try std.testing.expectEqual(Origin.client, authority.origin);
    try std.testing.expectEqual(@as(u64, 3), authority.recovery_epoch);
}

test "copied key cannot cross owner incarnation or semantic authority" {
    const old = (Intent{ .client = 4 }).key(11, 13).?;
    const reinitialized = (Intent{ .client = 4 }).key(12, 13).?;
    const wrong_origin = (Intent{ .host = 4 }).key(11, 13).?;
    const wrong_epoch = (Intent{ .client = 5 }).key(11, 13).?;
    const reused_slot = (Intent{ .client = 4 }).key(11, 14).?;

    try std.testing.expect(!std.meta.eql(old, reinitialized));
    try std.testing.expect(!std.meta.eql(old, wrong_origin));
    try std.testing.expect(!std.meta.eql(old, wrong_epoch));
    try std.testing.expect(!std.meta.eql(old, reused_slot));
}
