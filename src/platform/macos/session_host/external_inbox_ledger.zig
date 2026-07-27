//! Stable semantic screen-inbox accounting for the external attachment pump.
//!
//! Tokens deliberately contain no ledger pointer. The final pump owner resolves them against its
//! still-live ledger, so copied/stale leases cannot retain a dangling callback target after owner
//! teardown.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const max_bytes: usize = protocol.max_client_screen_inbox;
pub const max_items: usize = protocol.max_client_screen_items;

comptime {
    if (max_items > @as(usize, std.math.maxInt(u16)) + 1)
        @compileError("external inbox token slot cannot represent max_items");
}

pub const Token = struct {
    slot: u16,
    generation: u64,
};

pub const BatchView = struct {
    is_snapshot: bool,
    stream_id: u64,
    bytes: []const u8,
};

const OwnedBatch = struct {
    allocator: std.mem.Allocator,
    is_snapshot: bool,
    stream_id: u64,
    bytes: []u8,
};

const Slot = struct {
    active: bool = false,
    generation: u64 = 0,
    charged_bytes: usize = 0,
    batch: ?OwnedBatch = null,
};

pub const ReserveError = error{
    ByteCapExceeded,
    ItemCapExceeded,
    GenerationExhausted,
};

pub const InvariantError = error{InvariantFailure};
pub const FinishError = error{ ActiveCharges, InvariantFailure };

pub const ExternalInboxLedger = struct {
    slots: [max_items]Slot = [_]Slot{.{}} ** max_items,
    charged_bytes: usize = 0,
    charged_items: usize = 0,
    next_slot_hint: usize = 0,
    next_generation: u64 = 1,
    generation_exhausted: bool = false,
    invariant_failed: bool = false,

    pub fn reserve(self: *ExternalInboxLedger, bytes: usize) ReserveError!Token {
        if (self.generation_exhausted) return error.GenerationExhausted;
        const next_bytes = std.math.add(usize, self.charged_bytes, bytes) catch
            return error.ByteCapExceeded;
        if (next_bytes > max_bytes) return error.ByteCapExceeded;
        if (self.charged_items >= max_items) return error.ItemCapExceeded;

        var slot_index: ?usize = null;
        for (0..self.slots.len) |offset| {
            const i = (self.next_slot_hint + offset) % self.slots.len;
            if (!self.slots[i].active) {
                slot_index = i;
                break;
            }
        }
        const index = slot_index orelse return error.ItemCapExceeded;
        const generation = self.next_generation;
        if (generation == std.math.maxInt(u64)) {
            self.generation_exhausted = true;
        } else {
            self.next_generation = generation + 1;
        }

        self.slots[index] = .{
            .active = true,
            .generation = generation,
            .charged_bytes = bytes,
        };
        self.charged_bytes = next_bytes;
        self.charged_items += 1;
        // The common append/release cadence remains O(1), while the bounded circular scan still
        // recovers holes created by out-of-order attachment cleanup without a second free-list
        // structure whose own corruption could disagree with slot authority.
        self.next_slot_hint = (index + 1) % self.slots.len;
        return .{ .slot = @intCast(index), .generation = generation };
    }

    /// Transfer payload ownership into a previously charged slot. On error the caller still owns
    /// `bytes`; no allocator/free authority has moved.
    pub fn adoptBatch(
        self: *ExternalInboxLedger,
        token: Token,
        allocator: std.mem.Allocator,
        is_snapshot: bool,
        stream_id: u64,
        bytes: []u8,
    ) InvariantError!void {
        const slot = try self.resolveActive(token);
        if (slot.batch != null or slot.charged_bytes != bytes.len) return self.failInvariant();
        slot.batch = .{
            .allocator = allocator,
            .is_snapshot = is_snapshot,
            .stream_id = stream_id,
            .bytes = bytes,
        };
    }

    pub fn borrowBatch(self: *ExternalInboxLedger, token: Token) InvariantError!BatchView {
        const slot = try self.resolveActive(token);
        const batch = slot.batch orelse return self.failInvariant();
        return .{
            .is_snapshot = batch.is_snapshot,
            .stream_id = batch.stream_id,
            .bytes = batch.bytes,
        };
    }

    /// Idempotent with respect to accounting/free: a stale copy reports an invariant failure but
    /// never decrements counters or frees payload a second time.
    pub fn release(self: *ExternalInboxLedger, token: Token) InvariantError!void {
        const slot = self.resolveActive(token) catch return error.InvariantFailure;
        if (slot.batch) |batch| batch.allocator.free(batch.bytes);
        self.charged_bytes -= slot.charged_bytes;
        self.charged_items -= 1;
        slot.* = .{ .generation = token.generation };
        self.next_slot_hint = token.slot;
    }

    pub fn finish(self: *ExternalInboxLedger) FinishError!void {
        if (self.invariant_failed) return error.InvariantFailure;
        if (self.charged_bytes != 0 or self.charged_items != 0) return error.ActiveCharges;
        for (self.slots) |slot| {
            if (slot.active or slot.batch != null or slot.charged_bytes != 0)
                return error.ActiveCharges;
        }
    }

    fn resolveActive(self: *ExternalInboxLedger, token: Token) InvariantError!*Slot {
        if (@as(usize, token.slot) >= self.slots.len) return self.failInvariant();
        const slot = &self.slots[token.slot];
        if (!slot.active or slot.generation != token.generation) return self.failInvariant();
        return slot;
    }

    fn failInvariant(self: *ExternalInboxLedger) InvariantError {
        self.invariant_failed = true;
        return error.InvariantFailure;
    }
};

test "external inbox ledger enforces exact byte and item caps" {
    var ledger: ExternalInboxLedger = .{};
    const exact = try ledger.reserve(max_bytes);
    try std.testing.expectError(error.ByteCapExceeded, ledger.reserve(1));
    try ledger.release(exact);

    var tokens: [max_items]Token = undefined;
    for (&tokens) |*token| token.* = try ledger.reserve(0);
    try std.testing.expectError(error.ItemCapExceeded, ledger.reserve(0));
    for (tokens) |token| try ledger.release(token);
    try ledger.finish();
}

test "external inbox ledger reuses an out-of-order free slot without reusing generation" {
    var ledger: ExternalInboxLedger = .{};
    const first = try ledger.reserve(0);
    const second = try ledger.reserve(0);
    try ledger.release(first);
    const replacement = try ledger.reserve(0);
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(replacement.generation > second.generation);
    try ledger.release(second);
    try ledger.release(replacement);
    try ledger.finish();
}

test "external inbox ledger stale token cannot double free or double release" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const token = try ledger.reserve(5);
    try ledger.adoptBatch(
        token,
        allocator,
        true,
        7,
        try allocator.dupe(u8, "owned"),
    );
    const view = try ledger.borrowBatch(token);
    try std.testing.expect(view.is_snapshot);
    try std.testing.expectEqual(@as(u64, 7), view.stream_id);
    try std.testing.expectEqualStrings("owned", view.bytes);
    try ledger.release(token);
    try std.testing.expectError(error.InvariantFailure, ledger.release(token));
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
}

test "external inbox ledger generation never wraps or reuses an exhausted id" {
    var ledger: ExternalInboxLedger = .{ .next_generation = std.math.maxInt(u64) };
    const last = try ledger.reserve(0);
    try std.testing.expectEqual(std.math.maxInt(u64), last.generation);
    try ledger.release(last);
    try std.testing.expectError(error.GenerationExhausted, ledger.reserve(0));
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
}

test "external inbox ledger rejects early finish and preserves caller ownership on bad adoption" {
    const allocator = std.testing.allocator;
    var ledger: ExternalInboxLedger = .{};
    const token = try ledger.reserve(4);
    try std.testing.expectError(error.ActiveCharges, ledger.finish());
    const bytes = try allocator.dupe(u8, "five!");
    defer allocator.free(bytes);
    try std.testing.expectError(
        error.InvariantFailure,
        ledger.adoptBatch(token, allocator, false, 3, bytes),
    );
    try ledger.release(token);
}
