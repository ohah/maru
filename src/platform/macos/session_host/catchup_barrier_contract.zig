//! CR4 catch-up barrier의 pointer-free wire/host-state 계약.
//!
//! 화면 frontier 자체만으로는 connection-local stream 재사용이나 timeout retry를 구분할 수 없다. 따라서 host가
//! 소유하는 pending row와 wire payload는 host id, global subscription, runtime, daemon connection key와 client request nonce를 함께
//! 봉인한다. 이 모듈은 socket, allocator, RuntimeManager를 모르며 producer/server/client가 공유하는 값 계약만 소유한다.

const std = @import("std");
const connection_slot = @import("connection_slot.zig");
const subscription_identity = @import("subscription_identity.zig");
const wire = @import("catchup_barrier_wire.zig");

pub const capability = "runtime_catchup_barrier_v1";
pub const wire_version: u16 = wire.version;
pub const payload_size: usize = wire.payload_size;

pub const ScreenFrontier = struct {
    generation: u64,
    sequence: u64,

};

pub const CatchupIdentity = struct {
    subscription: subscription_identity.SubscriptionId,
    runtime_id: u128,
    connection: connection_slot.ConnectionKey,
    host_id: u128,
    request_nonce: u128,

    pub fn valid(self: CatchupIdentity) bool {
        return self.subscription.value != 0 and self.runtime_id != 0 and
            self.connection.valid() and self.host_id != 0 and self.request_nonce != 0;
    }
};

pub const Barrier = struct {
    identity: CatchupIdentity,
    target: ScreenFrontier,

    pub fn valid(self: Barrier) bool {
        return self.identity.valid();
    }

    pub fn encode(self: Barrier) error{InvalidBarrier}![payload_size]u8 {
        if (!self.valid()) return error.InvalidBarrier;
        var out: [payload_size]u8 = @splat(0);
        std.mem.writeInt(u16, out[0..2], wire_version, .big);
        std.mem.writeInt(u16, out[2..4], 0, .big);
        std.mem.writeInt(u32, out[4..8], payload_size, .big);
        std.mem.writeInt(u64, out[8..16], self.identity.subscription.value, .big);
        std.mem.writeInt(u128, out[16..32], self.identity.request_nonce, .big);
        std.mem.writeInt(u128, out[32..48], self.identity.runtime_id, .big);
        std.mem.writeInt(u128, out[48..64], self.identity.host_id, .big);
        std.mem.writeInt(u64, out[64..72], self.identity.connection.monotonic_id, .big);
        std.mem.writeInt(u64, out[72..80], self.identity.connection.slot_generation, .big);
        std.mem.writeInt(u64, out[80..88], self.target.generation, .big);
        std.mem.writeInt(u64, out[88..96], self.target.sequence, .big);
        return out;
    }

    pub fn decode(bytes: *const [payload_size]u8) error{InvalidBarrier}!Barrier {
        if (std.mem.readInt(u16, bytes[0..2], .big) != wire_version or
            std.mem.readInt(u16, bytes[2..4], .big) != 0 or
            std.mem.readInt(u32, bytes[4..8], .big) != payload_size)
            return error.InvalidBarrier;
        const result: Barrier = .{
            .identity = .{
                .subscription = .{ .value = std.mem.readInt(u64, bytes[8..16], .big) },
                .request_nonce = std.mem.readInt(u128, bytes[16..32], .big),
                .runtime_id = std.mem.readInt(u128, bytes[32..48], .big),
                .host_id = std.mem.readInt(u128, bytes[48..64], .big),
                .connection = .{
                    .monotonic_id = std.mem.readInt(u64, bytes[64..72], .big),
                    .slot_generation = std.mem.readInt(u64, bytes[72..80], .big),
                },
            },
            .target = .{
                .generation = std.mem.readInt(u64, bytes[80..88], .big),
                .sequence = std.mem.readInt(u64, bytes[88..96], .big),
            },
        };
        if (!result.valid()) return error.InvalidBarrier;
        return result;
    }
};

fn fixtureIdentity() CatchupIdentity {
    return .{
        .subscription = .{ .value = 9 },
        .runtime_id = 0x11112222333344445555666677778888,
        .connection = .{ .monotonic_id = 3, .slot_generation = 4 },
        .host_id = 0x55556666777788889999aaaabbbbcccc,
        .request_nonce = 0x9999aaaabbbbccccddddeeeeffff0001,
    };
}

test "CR4a dormant barrier 계약은 identity와 frontier를 fixed wire에 봉인한다" {
    const expected: Barrier = .{
        .identity = fixtureIdentity(),
        .target = .{ .generation = 0, .sequence = 11 },
    };
    const bytes = try expected.encode();
    try std.testing.expectEqual(@as(u16, 1), wire_version);
    try std.testing.expectEqual(@as(usize, 96), payload_size);
    try std.testing.expectEqual(payload_size, bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 0, 0, 0, 96 }, bytes[0..8]);
    // encode/decode가 같은 offset 오류를 공유해도 통과하지 않도록 released layout을 독립 offset으로 고정한다.
    try std.testing.expectEqual(wire_version, std.mem.readInt(u16, bytes[0..2], .big));
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, bytes[8..16], .big));
    try std.testing.expectEqual(expected.identity.request_nonce, std.mem.readInt(u128, bytes[16..32], .big));
    try std.testing.expectEqual(expected.identity.runtime_id, std.mem.readInt(u128, bytes[32..48], .big));
    try std.testing.expectEqual(expected.identity.host_id, std.mem.readInt(u128, bytes[48..64], .big));
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, bytes[64..72], .big));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, bytes[72..80], .big));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, bytes[80..88], .big));
    try std.testing.expectEqual(@as(u64, 11), std.mem.readInt(u64, bytes[88..96], .big));
    try std.testing.expectEqualDeep(expected, try Barrier.decode(&bytes));

    var hostile = bytes;
    hostile[3] = 1;
    try std.testing.expectError(error.InvalidBarrier, Barrier.decode(&hostile));
    hostile = bytes;
    @memset(hostile[16..32], 0);
    try std.testing.expectError(error.InvalidBarrier, Barrier.decode(&hostile));
}

test "CR4a dormant barrier identity는 host subscription connection nonce drift를 구분한다" {
    const identity = fixtureIdentity();
    try std.testing.expect(identity.valid());

    var foreign_rows: [6]CatchupIdentity = @splat(identity);
    foreign_rows[0].subscription.value += 1;
    foreign_rows[1].runtime_id += 1;
    foreign_rows[2].connection.monotonic_id += 1;
    foreign_rows[3].connection.slot_generation += 1;
    foreign_rows[4].host_id += 1;
    foreign_rows[5].request_nonce += 1;
    for (foreign_rows) |foreign| {
        try std.testing.expect(foreign.valid());
        try std.testing.expect(!std.meta.eql(identity, foreign));
    }

    var invalid_rows: [6]CatchupIdentity = @splat(identity);
    invalid_rows[0].subscription.value = 0;
    invalid_rows[1].runtime_id = 0;
    invalid_rows[2].connection.monotonic_id = 0;
    invalid_rows[3].connection.slot_generation = 0;
    invalid_rows[4].host_id = 0;
    invalid_rows[5].request_nonce = 0;
    for (invalid_rows) |invalid| try std.testing.expect(!invalid.valid());
}
