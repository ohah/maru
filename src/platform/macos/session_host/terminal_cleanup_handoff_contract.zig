//! Generation batch terminal handoff의 pointer-free 값 계약.
//!
//! 이 leaf는 실제 registry나 allocator를 알지 않는다. 상위 node owner가 만든 ordered token
//! transcript만 canonical 값으로 고정해 movable attachment가 teardown 권위를 소유하지 않게 한다.

const std = @import("std");

pub const Digest = [32]u8;

pub const Lifecycle = enum(u8) {
    pristine,
    prepared,
    published,
    draining,
    consumed,
    terminal,
};

pub const TerminalRowKind = enum(u8) {
    surviving_descriptor,
    quarantined_no_free,
};

pub const TerminalDrainLifecycle = enum(u8) {
    pristine,
    prepared,
    callback_active,
    callback_returned,
    consumed,
};

pub const TerminalDrainIdentity = struct {
    self_addr: u64,
    pid: u32,
    process_nonce: u64,
    thread_id: u64,
    node_addr: u64,
    node_incarnation: u64,
    registry_incarnation: u64,
    handoff_identity_seal: Digest,
    handoff_state_seal: Digest,
    handoff_state_generation: u64,
    row_slot: u16,
    row_kind_raw: u8,
    row_generation: u64,
    accounting_client_addr: u64,
    accounting_transfer_id: u64,
    accounting_byte_count: u64,
    payload_addr: u64,
    payload_len: u64,
    allocator_ptr: u64,
    allocator_vtable: u64,
    callback_ordinal: u32,
};

pub const TerminalDrainState = struct {
    identity_seal: Digest,
    lifecycle_raw: u8,
    state_generation: u64,
    state_seal: Digest,
};

pub const TerminalDrainCallbackBinding = struct {
    continuation_addr: u64,
    continuation_seal: Digest,
    node_addr: u64,
    row_slot: u16,
    callback_ordinal: u32,
};

pub const TokenProjection = struct {
    registry_incarnation: u64,
    entry_slot: u16,
    entry_generation: u64,
    stream_id: u64,
};

pub const Identity = struct {
    self_addr: u64,
    pid: u32,
    process_nonce: u64,
    thread_id: u64,
    node_addr: u64,
    node_incarnation: u64,
    registry_incarnation: u64,
    connection_generation: u64,
    stream_id: u64,
    token_count: u32,
    ordered_token_digest: Digest,
    surviving_descriptor_count: u32,
    quarantined_descriptor_count: u32,
    accounting_count: u32,
    accounting_bytes: u64,
    request_generation: u64,
};

pub const State = struct {
    identity_seal: Digest,
    lifecycle_raw: u8,
    state_generation: u64,
    state_seal: Digest,
};

pub const OrderedTokenHasher = struct {
    hasher: std.crypto.hash.sha2.Sha256,
    count: u32 = 0,

    pub fn init(expected_count: u32) OrderedTokenHasher {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&hasher, u32, expected_count);
        return .{ .hasher = hasher };
    }

    pub fn add(self: *OrderedTokenHasher, token: TokenProjection) error{CountOverflow}!void {
        if (self.count == std.math.maxInt(u32)) return error.CountOverflow;
        hashInt(&self.hasher, u32, self.count);
        hashInt(&self.hasher, u64, token.registry_incarnation);
        hashInt(&self.hasher, u16, token.entry_slot);
        hashInt(&self.hasher, u64, token.entry_generation);
        hashInt(&self.hasher, u64, token.stream_id);
        self.count += 1;
    }

    pub fn finish(self: *OrderedTokenHasher, expected_count: u32) error{CountMismatch}!Digest {
        if (self.count != expected_count) return error.CountMismatch;
        var digest: Digest = undefined;
        self.hasher.final(&digest);
        return digest;
    }
};

pub fn orderedTokenDigest(tokens: []const TokenProjection) Digest {
    var ordered = OrderedTokenHasher.init(@intCast(tokens.len));
    for (tokens) |token| ordered.add(token) catch unreachable;
    return ordered.finish(@intCast(tokens.len)) catch unreachable;
}

fn hashInt(hasher: anytype, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .error_union => |info| containsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field|
                if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "CR3a-2d2 terminal handoff schema는 재귀적으로 pointer-free다" {
    try std.testing.expect(!containsPointer(TokenProjection));
    try std.testing.expect(!containsPointer(Identity));
    try std.testing.expect(!containsPointer(State));
    try std.testing.expectEqual(@as(usize, 6), std.enums.values(Lifecycle).len);
    try std.testing.expectEqual(@as(usize, 2), std.enums.values(TerminalRowKind).len);
}

test "CR3a-2d2 terminal handoff identity는 final address와 exact owner scalar를 보존한다" {
    const identity = Identity{
        .self_addr = 11,
        .pid = 13,
        .process_nonce = 17,
        .thread_id = 19,
        .node_addr = 23,
        .node_incarnation = 29,
        .registry_incarnation = 31,
        .connection_generation = 37,
        .stream_id = 41,
        .token_count = 2,
        .ordered_token_digest = [_]u8{43} ** 32,
        .surviving_descriptor_count = 1,
        .quarantined_descriptor_count = 1,
        .accounting_count = 2,
        .accounting_bytes = 47,
        .request_generation = 53,
    };
    try std.testing.expectEqual(@as(u64, 11), identity.self_addr);
    try std.testing.expectEqual(@as(u64, 23), identity.node_addr);
    try std.testing.expectEqual(@as(u32, 2), identity.token_count);
    try std.testing.expectEqual(@as(u32, 2), identity.accounting_count);
}

test "CR3a-2d2 terminal handoff ordered token digest는 순서와 ordinal splice를 거부한다" {
    const first = TokenProjection{ .registry_incarnation = 3, .entry_slot = 1, .entry_generation = 5, .stream_id = 7 };
    const second = TokenProjection{ .registry_incarnation = 3, .entry_slot = 2, .entry_generation = 11, .stream_id = 7 };
    const ordered = [_]TokenProjection{ first, second };
    const reversed = [_]TokenProjection{ second, first };
    try std.testing.expect(!std.mem.eql(u8, &orderedTokenDigest(&ordered), &orderedTokenDigest(&reversed)));
    const duplicated = [_]TokenProjection{ first, first };
    try std.testing.expect(!std.mem.eql(u8, &orderedTokenDigest(&ordered), &orderedTokenDigest(&duplicated)));
}

test "CR3a-2d3 terminal drain continuation schema는 재귀적으로 pointer-free다" {
    try std.testing.expect(!containsPointer(TerminalDrainIdentity));
    try std.testing.expect(!containsPointer(TerminalDrainState));
    try std.testing.expect(!containsPointer(TerminalDrainCallbackBinding));
}

test "CR3a-2d3 terminal drain continuation은 final address와 row accounting identity를 보존한다" {
    const identity = TerminalDrainIdentity{
        .self_addr = 3,
        .pid = 5,
        .process_nonce = 7,
        .thread_id = 11,
        .node_addr = 13,
        .node_incarnation = 17,
        .registry_incarnation = 19,
        .handoff_identity_seal = [_]u8{23} ** 32,
        .handoff_state_seal = [_]u8{29} ** 32,
        .handoff_state_generation = 31,
        .row_slot = 37,
        .row_kind_raw = @intFromEnum(TerminalRowKind.surviving_descriptor),
        .row_generation = 41,
        .accounting_client_addr = 43,
        .accounting_transfer_id = 47,
        .accounting_byte_count = 53,
        .payload_addr = 59,
        .payload_len = 61,
        .allocator_ptr = 67,
        .allocator_vtable = 71,
        .callback_ordinal = 73,
    };
    try std.testing.expectEqual(@as(u64, 3), identity.self_addr);
    try std.testing.expectEqual(@as(u16, 37), identity.row_slot);
    try std.testing.expectEqual(@as(u64, 47), identity.accounting_transfer_id);
    try std.testing.expectEqual(@as(u32, 73), identity.callback_ordinal);
}

test "CR3a-2d3 terminal drain lifecycle은 callback 복귀와 consume 순서를 닫는다" {
    const values = std.enums.values(TerminalDrainLifecycle);
    try std.testing.expectEqual(@as(usize, 5), values.len);
    try std.testing.expectEqual(TerminalDrainLifecycle.pristine, values[0]);
    try std.testing.expectEqual(TerminalDrainLifecycle.prepared, values[1]);
    try std.testing.expectEqual(TerminalDrainLifecycle.callback_active, values[2]);
    try std.testing.expectEqual(TerminalDrainLifecycle.callback_returned, values[3]);
    try std.testing.expectEqual(TerminalDrainLifecycle.consumed, values[4]);
}
